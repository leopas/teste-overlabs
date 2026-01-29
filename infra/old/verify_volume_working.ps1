# Script para verificar se o volume está funcionando corretamente

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Verificar Volume Funcionando ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se nao fornecido
if (-not $ResourceGroup -or -not $ApiAppName) {
    $stateFile = ".azure/deploy_state.json"
    if (-not (Test-Path $stateFile)) {
        Write-Host "[ERRO] Arquivo $stateFile nao encontrado." -ForegroundColor Red
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

# 1. Verificar volumes definidos
Write-Host "[INFO] Verificando volumes definidos no Container App..." -ForegroundColor Yellow
$volumes = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.volumes" -o json | ConvertFrom-Json

if ($volumes) {
    Write-Host "[OK] Volumes encontrados:" -ForegroundColor Green
    foreach ($vol in $volumes) {
        Write-Host "  - Nome: $($vol.name)" -ForegroundColor Gray
        Write-Host "    Tipo: $($vol.storageType)" -ForegroundColor Gray
        Write-Host "    Storage Name: $($vol.storageName)" -ForegroundColor Gray
    }
} else {
    Write-Host "[ERRO] Nenhum volume encontrado!" -ForegroundColor Red
    exit 1
}
Write-Host ""

# 2. Verificar volume mounts
Write-Host "[INFO] Verificando volume mounts no container..." -ForegroundColor Yellow
$volumeMounts = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].volumeMounts" -o json | ConvertFrom-Json

if ($volumeMounts) {
    Write-Host "[OK] Volume mounts encontrados:" -ForegroundColor Green
    foreach ($vm in $volumeMounts) {
        Write-Host "  - Volume: $($vm.volumeName)" -ForegroundColor Gray
        Write-Host "    Mount Path: $($vm.mountPath)" -ForegroundColor Gray
    }
} else {
    Write-Host "[ERRO] Nenhum volume mount encontrado!" -ForegroundColor Red
    exit 1
}
Write-Host ""

# 3. Verificar se o diretório está acessível no container
Write-Host "[INFO] Verificando se /app/DOC-IA está acessível no container..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"

# Aguardar um pouco para garantir que o container está rodando
Start-Sleep -Seconds 5

$checkCommand = "if test -d /app/DOC-IA; then echo 'EXISTS'; ls -la /app/DOC-IA | head -20; else echo 'NOT_FOUND'; fi"
$checkOutput = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command $checkCommand 2>&1

$ErrorActionPreference = "Stop"

if ($checkOutput -match "EXISTS") {
    Write-Host "[OK] Diretório /app/DOC-IA está acessível no container!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Conteúdo do diretório:" -ForegroundColor Cyan
    Write-Host $checkOutput
    Write-Host ""
    
    # Contar arquivos
    $fileCount = ($checkOutput | Select-String -Pattern "\.txt" -AllMatches).Matches.Count
    if ($fileCount -gt 0) {
        Write-Host "[OK] Encontrados aproximadamente $fileCount arquivo(s) no diretório" -ForegroundColor Green
    }
} elseif ($checkOutput -match "NOT_FOUND") {
    Write-Host "[ERRO] Diretório /app/DOC-IA NÃO está acessível no container!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Possíveis causas:" -ForegroundColor Yellow
    Write-Host "  1. Volume foi adicionado mas o container precisa ser reiniciado" -ForegroundColor Gray
    Write-Host "  2. Mount path está incorreto" -ForegroundColor Gray
    Write-Host "  3. Volume não está montado corretamente" -ForegroundColor Gray
    Write-Host ""
    Write-Host "[INFO] Tente reiniciar o Container App:" -ForegroundColor Cyan
    Write-Host "  az containerapp update --name $ApiAppName --resource-group $ResourceGroup --set-env-vars 'RESTART_TRIGGER=$(Get-Date -Format 'yyyyMMddHHmmss')'" -ForegroundColor Gray
    exit 1
} else {
    Write-Host "[AVISO] Não foi possível verificar (container pode estar iniciando)" -ForegroundColor Yellow
    Write-Host "Saída: $checkOutput" -ForegroundColor Gray
    exit 1
}

Write-Host ""
Write-Host "=== Resumo ===" -ForegroundColor Cyan
Write-Host "[OK] Volume configurado: OK" -ForegroundColor Green
Write-Host "[OK] Volume mount configurado: OK" -ForegroundColor Green
Write-Host "[OK] Diretorio acessivel: OK" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] Voce pode executar a ingestao agora:" -ForegroundColor Cyan
$ingestCmd = "  .\infra\run_ingest_in_container.ps1 -TruncateFirst"
Write-Host $ingestCmd -ForegroundColor Gray
Write-Host ""
