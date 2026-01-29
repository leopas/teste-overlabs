# Script para diagnosticar problemas com volume mount
# Verifica se o volume mount está configurado e se o diretório está acessível

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Diagnóstico de Volume Mount ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se não fornecido
if (-not $ResourceGroup -or -not $ApiAppName) {
    $stateFile = ".azure/deploy_state.json"
    if (-not (Test-Path $stateFile)) {
        Write-Host "[ERRO] Arquivo $stateFile não encontrado. Forneça -ResourceGroup e -ApiAppName." -ForegroundColor Red
        exit 1
    }
    $state = Get-Content $stateFile | ConvertFrom-Json
    if (-not $ResourceGroup) {
        $ResourceGroup = $state.resourceGroup
    }
    if (-not $ApiAppName) {
        $ApiAppName = $state.apiAppName
    }
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] API Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host ""

# 1. Verificar volumes definidos no Container App
Write-Host "=== 1. Volumes Definidos no Container App ===" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
$volumes = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.volumes" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = "Stop"

if ($volumes) {
    Write-Host "[OK] Volumes encontrados:" -ForegroundColor Green
    foreach ($vol in $volumes) {
        Write-Host "  - Nome: $($vol.name)" -ForegroundColor Gray
        Write-Host "    Tipo: $($vol.storageType)" -ForegroundColor Gray
        Write-Host "    Storage Name: $($vol.storageName)" -ForegroundColor Gray
    }
} else {
    Write-Host "[ERRO] Nenhum volume encontrado!" -ForegroundColor Red
}
Write-Host ""

# 2. Verificar volume mounts no container
Write-Host "=== 2. Volume Mounts no Container ===" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
$volumeMounts = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].volumeMounts" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = "Stop"

if ($volumeMounts) {
    Write-Host "[OK] Volume mounts encontrados:" -ForegroundColor Green
    foreach ($vm in $volumeMounts) {
        Write-Host "  - Volume: $($vm.volumeName)" -ForegroundColor Gray
        Write-Host "    Mount Path: $($vm.mountPath)" -ForegroundColor Gray
    }
} else {
    Write-Host "[ERRO] Nenhum volume mount encontrado!" -ForegroundColor Red
}
Write-Host ""

# 3. Verificar revision ativa
Write-Host "=== 3. Revision Ativa ===" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
$latestRevision = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.latestRevisionName" -o tsv 2>$null
$revisionStatus = az containerapp revision show --name $latestRevision --app $ApiAppName --resource-group $ResourceGroup --query "properties.provisioningState" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if ($latestRevision) {
    Write-Host "[INFO] Latest Revision: $latestRevision" -ForegroundColor Yellow
    Write-Host "[INFO] Status: $revisionStatus" -ForegroundColor Yellow
    
    # Verificar volume mounts na revision específica
    Write-Host "[INFO] Verificando volume mounts na revision..." -ForegroundColor Yellow
    $ErrorActionPreference = "Continue"
    $revisionMounts = az containerapp revision show --name $latestRevision --app $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].volumeMounts" -o json 2>$null | ConvertFrom-Json
    $ErrorActionPreference = "Stop"
    
    if ($revisionMounts) {
        Write-Host "[OK] Volume mounts na revision:" -ForegroundColor Green
        foreach ($vm in $revisionMounts) {
            Write-Host "  - Volume: $($vm.volumeName) -> $($vm.mountPath)" -ForegroundColor Gray
        }
    } else {
        Write-Host "[AVISO] Nenhum volume mount encontrado na revision!" -ForegroundColor Yellow
    }
} else {
    Write-Host "[ERRO] Não foi possível obter revision ativa" -ForegroundColor Red
}
Write-Host ""

# 4. Verificar se o diretório existe no container
Write-Host "=== 4. Acesso ao Diretório no Container ===" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
Write-Host "[INFO] Tentando acessar /app/DOC-IA no container..." -ForegroundColor Yellow

# Verificar se o container está rodando
$replicas = az containerapp replica list --name $ApiAppName --resource-group $ResourceGroup --revision $latestRevision --query "[].name" -o tsv 2>$null
if ($replicas) {
    Write-Host "[OK] Container está rodando (replicas encontradas)" -ForegroundColor Green
    
    # Tentar executar comando no container
    $docsCheck = az containerapp exec `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --command "test -d /app/DOC-IA && echo 'EXISTS' || echo 'NOT_FOUND'" 2>&1
    
    if ($docsCheck -match "EXISTS") {
        Write-Host "[OK] Diretório /app/DOC-IA encontrado no container!" -ForegroundColor Green
        
        # Listar arquivos
        Write-Host "[INFO] Listando arquivos..." -ForegroundColor Yellow
        az containerapp exec `
            --name $ApiAppName `
            --resource-group $ResourceGroup `
            --command "ls -la /app/DOC-IA 2>&1 | head -20" 2>&1 | Out-Host
    } else {
        Write-Host "[ERRO] Diretório /app/DOC-IA NÃO encontrado no container!" -ForegroundColor Red
        Write-Host "[INFO] Saída do comando: $docsCheck" -ForegroundColor Gray
        
        # Tentar verificar se o mount point existe
        Write-Host "[INFO] Verificando se o mount point existe..." -ForegroundColor Yellow
        $mountCheck = az containerapp exec `
            --name $ApiAppName `
            --resource-group $ResourceGroup `
            --command "mount | grep DOC-IA || echo 'MOUNT_NOT_FOUND'" 2>&1
        Write-Host "[INFO] Mount check: $mountCheck" -ForegroundColor Gray
    }
} else {
    Write-Host "[AVISO] Nenhuma replica encontrada. Container pode não estar rodando." -ForegroundColor Yellow
}
Write-Host ""

# 5. Resumo e recomendações
Write-Host "=== Resumo e Recomendações ===" -ForegroundColor Cyan
Write-Host ""

$hasVolume = $volumes -and ($volumes | Where-Object { $_.name -eq "docs" })
$hasMount = $volumeMounts -and ($volumeMounts | Where-Object { $_.volumeName -eq "docs" -and $_.mountPath -eq "/app/DOC-IA" })
$hasAccess = $docsCheck -match "EXISTS"

if ($hasVolume -and $hasMount -and $hasAccess) {
    Write-Host "[OK] Tudo configurado corretamente!" -ForegroundColor Green
    Write-Host "[INFO] Você pode executar a ingestão agora:" -ForegroundColor Cyan
    Write-Host "  .\infra\run_ingest_in_container.ps1 -TruncateFirst" -ForegroundColor Gray
} else {
    Write-Host "[AVISO] Problemas encontrados:" -ForegroundColor Yellow
    if (-not $hasVolume) {
        Write-Host "  [ ] Volume 'docs' não está definido" -ForegroundColor Red
        Write-Host "      Execute: .\infra\bootstrap_container_apps.ps1" -ForegroundColor Gray
    }
    if (-not $hasMount) {
        Write-Host "  [ ] Volume mount não está configurado" -ForegroundColor Red
        Write-Host "      Execute: .\infra\add_volume_mount.ps1" -ForegroundColor Gray
    }
    if ($hasVolume -and $hasMount -and -not $hasAccess) {
        Write-Host "  [ ] Volume mount configurado mas diretório não acessível" -ForegroundColor Red
        Write-Host "      Possíveis causas:" -ForegroundColor Yellow
        Write-Host "      1. Nova revision ainda não foi aplicada (aguarde 1-2 minutos)" -ForegroundColor Gray
        Write-Host "      2. Container precisa ser reiniciado" -ForegroundColor Gray
        Write-Host "      3. Problema com permissões no Storage Account" -ForegroundColor Gray
        Write-Host "      Tente:" -ForegroundColor Yellow
        Write-Host "      az containerapp revision restart --name $ApiAppName --resource-group $ResourceGroup --revision $latestRevision" -ForegroundColor Gray
    }
}
Write-Host ""
