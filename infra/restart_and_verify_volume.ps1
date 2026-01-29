# Script para reiniciar o Container App e verificar se o volume está acessível

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Reiniciar Container App e Verificar Volume ===" -ForegroundColor Cyan
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

# Obter revision ativa atual
Write-Host "[INFO] Obtendo revision ativa atual..." -ForegroundColor Yellow
$activeRevision = az containerapp revision list `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --query "[?properties.active==\`true\`].name" -o tsv | Select-Object -First 1

if ($activeRevision) {
    Write-Host "[OK] Revision ativa: $activeRevision" -ForegroundColor Green
} else {
    Write-Host "[AVISO] Não foi possível obter revision ativa" -ForegroundColor Yellow
}
Write-Host ""

# Reiniciar Container App
Write-Host "[INFO] Reiniciando Container App..." -ForegroundColor Yellow
Write-Host "  Isso criará uma nova revision" -ForegroundColor Gray
Write-Host ""

az containerapp update `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --set-env-vars "RESTART_TRIGGER=$(Get-Date -Format 'yyyyMMddHHmmss')" 2>&1 | Out-Null

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Container App atualizado (nova revision será criada)" -ForegroundColor Green
} else {
    Write-Host "[ERRO] Falha ao atualizar Container App" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "[INFO] Aguardando nova revision ser criada e ficar pronta..." -ForegroundColor Yellow
Write-Host "  Isso pode levar 1-2 minutos..." -ForegroundColor Gray
Write-Host ""

# Aguardar nova revision ficar pronta
$maxWait = 120 # 2 minutos
$elapsed = 0
$ready = $false

while ($elapsed -lt $maxWait -and -not $ready) {
    Start-Sleep -Seconds 10
    $elapsed += 10
    
    $ErrorActionPreference = "Continue"
    $revisions = az containerapp revision list `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --query "sort_by(@, &properties.createdTime)[-1]" -o json 2>$null | ConvertFrom-Json
    $ErrorActionPreference = "Stop"
    
    if ($revisions) {
        $latestRevision = $revisions.name
        $provisioningState = $revisions.properties.provisioningState
        $active = $revisions.properties.active
        
        Write-Host "  [$elapsed s] Revision: $latestRevision | State: $provisioningState | Active: $active" -ForegroundColor Gray
        
        if ($provisioningState -eq "Succeeded" -and $active) {
            $ready = $true
            Write-Host "[OK] Nova revision está pronta!" -ForegroundColor Green
            break
        }
    }
}

if (-not $ready) {
    Write-Host "[AVISO] Timeout aguardando revision ficar pronta. Continuando mesmo assim..." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "[INFO] Aguardando mais 30s para o container iniciar completamente..." -ForegroundColor Yellow
Start-Sleep -Seconds 30
Write-Host ""

# Verificar se o volume está acessível
Write-Host "[INFO] Verificando se /app/DOC-IA está acessível no container..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"

$checkOutput = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "test -d /app/DOC-IA && echo 'EXISTS' && ls -la /app/DOC-IA | head -10 || echo 'NOT_FOUND'" 2>&1

if ($checkOutput -match "EXISTS") {
    Write-Host "[OK] Volume está acessível no container!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Conteúdo do diretório:" -ForegroundColor Cyan
    Write-Host $checkOutput
    Write-Host ""
    Write-Host "[INFO] Você pode executar a ingestão agora:" -ForegroundColor Cyan
    Write-Host "  .\infra\run_ingest_in_container.ps1 -TruncateFirst" -ForegroundColor Gray
} else {
    Write-Host "[AVISO] Volume ainda não está acessível" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "[INFO] Verifique:" -ForegroundColor Yellow
    Write-Host "  1. Se o volume está configurado no Container App: .\infra\check_volume_mount.ps1" -ForegroundColor Gray
    Write-Host "  2. Se há arquivos no File Share: .\infra\mount_docs_volume.ps1 -UploadDocs" -ForegroundColor Gray
    Write-Host "  3. Logs do Container App para ver erros de montagem" -ForegroundColor Gray
}

$ErrorActionPreference = "Stop"

Write-Host ""
