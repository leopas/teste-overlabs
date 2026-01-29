# Script para forçar refresh da resolução do Key Vault

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Forçar Refresh do Key Vault Reference ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se não fornecido
if (-not $ResourceGroup -or -not $ApiAppName) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoRoot = Split-Path -Parent $scriptDir
    $stateFile = Join-Path $repoRoot ".azure\deploy_state.json"
    
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

# Forçar nova revision atualizando uma variável dummy
Write-Host "[INFO] Forçando nova revision para aplicar Key Vault reference..." -ForegroundColor Yellow
$timestamp = Get-Date -Format "yyyyMMddHHmmss"
$ErrorActionPreference = "Continue"
$updateResult = az containerapp update `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --set-env-vars "KV_REFRESH=$timestamp" 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERRO] Falha ao atualizar Container App: $updateResult" -ForegroundColor Red
    exit 1
}
$ErrorActionPreference = "Stop"

Write-Host "[OK] Nova revision criada" -ForegroundColor Green
Write-Host "[INFO] Aguardando revision ficar pronta..." -ForegroundColor Yellow

# Aguardar revision ficar pronta
$maxWait = 120
$elapsed = 0
$interval = 5

while ($elapsed -lt $maxWait) {
    Start-Sleep -Seconds $interval
    $elapsed += $interval
    
    $revision = az containerapp revision list `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --query "[0].{name:name,active:properties.active,ready:properties.runningState}" -o json 2>&1 | ConvertFrom-Json
    
    if ($revision.ready -eq "Running") {
        Write-Host "[OK] Revision pronta!" -ForegroundColor Green
        break
    }
    
    Write-Host "  Aguardando... (${elapsed}s/${maxWait}s) - Status: $($revision.ready)" -ForegroundColor Gray
}

Write-Host ""
Write-Host "[INFO] Aguardando mais 10s para Key Vault reference ser resolvida..." -ForegroundColor Yellow
Start-Sleep -Seconds 10

Write-Host ""
Write-Host "=== Refresh Concluído ===" -ForegroundColor Green
Write-Host "[INFO] Teste a ingestão novamente:" -ForegroundColor Yellow
Write-Host "  .\infra\run_ingest_in_container.ps1 -TruncateFirst" -ForegroundColor Gray
Write-Host ""
