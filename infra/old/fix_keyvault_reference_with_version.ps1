# Script para atualizar referência do Key Vault com versão específica

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Atualizar Key Vault Reference com Versão ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json
if (-not $ResourceGroup -or -not $ApiAppName) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoRoot = Split-Path -Parent $scriptDir
    $stateFile = Join-Path $repoRoot ".azure\deploy_state.json"
    
    if (-not (Test-Path $stateFile)) {
        Write-Host "[ERRO] Arquivo $stateFile não encontrado." -ForegroundColor Red
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

# Obter versão do secret
Write-Host "[INFO] Obtendo versão do secret..." -ForegroundColor Yellow
$kvName = $state.keyVaultName
$secretName = "openai-api-key"

$secretId = az keyvault secret show --vault-name $kvName --name $secretName --query "id" -o tsv 2>&1
if (-not $secretId) {
    Write-Host "[ERRO] Falha ao obter ID do secret!" -ForegroundColor Red
    exit 1
}

# Extrair versão do ID (último segmento após /)
$secretVersion = $secretId.Split('/')[-1]
Write-Host "[OK] Versão do secret: $secretVersion" -ForegroundColor Green
Write-Host ""

# Construir referência com versão
$kvReference = "@Microsoft.KeyVault(SecretUri=https://$kvName.vault.azure.net/secrets/$secretName/$secretVersion)"
Write-Host "[INFO] Nova referência: $kvReference" -ForegroundColor Gray
Write-Host ""

# Atualizar Container App
Write-Host "[INFO] Atualizando Container App com referência incluindo versão..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$updateResult = az containerapp update `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --set-env-vars "OPENAI_API_KEY=$kvReference" 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Container App atualizado com sucesso!" -ForegroundColor Green
} else {
    Write-Host "[ERRO] Falha ao atualizar Container App: $updateResult" -ForegroundColor Red
    exit 1
}
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "[INFO] Aguardando nova revision ficar pronta..." -ForegroundColor Yellow
Start-Sleep -Seconds 30

Write-Host ""
Write-Host "=== Atualização Concluída ===" -ForegroundColor Green
Write-Host "[INFO] Teste a ingestão novamente:" -ForegroundColor Yellow
Write-Host "  .\infra\run_ingest_in_container.ps1 -TruncateFirst" -ForegroundColor Gray
Write-Host ""
