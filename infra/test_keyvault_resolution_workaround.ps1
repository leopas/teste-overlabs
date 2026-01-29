# Script para testar workaround: configurar chave diretamente temporariamente

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Workaround: Testar com Chave Direta ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "[INFO] Este script vai:" -ForegroundColor Yellow
Write-Host "  1. Configurar OPENAI_API_KEY diretamente (temporário)" -ForegroundColor Gray
Write-Host "  2. Testar se a ingestão funciona" -ForegroundColor Gray
Write-Host "  3. Se funcionar, sabemos que o problema é a resolução do Key Vault" -ForegroundColor Gray
Write-Host "  4. Depois, você pode reverter para Key Vault reference" -ForegroundColor Gray
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

# Ler chave do .env
$envFile = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) ".env"
$envContent = Get-Content $envFile
$envKey = $null

foreach ($line in $envContent) {
    if ($line -match '^\s*OPENAI_API_KEY\s*=\s*(.+)$') {
        $envKey = $matches[1].Trim()
        $envKey = $envKey -replace '^["'']|["'']$', ''
        break
    }
}

if (-not $envKey) {
    Write-Host "[ERRO] OPENAI_API_KEY não encontrada no .env" -ForegroundColor Red
    exit 1
}

Write-Host "[INFO] Configurando chave diretamente no Container App..." -ForegroundColor Yellow
Write-Host "[AVISO] Isso expõe a chave como variável de ambiente!" -ForegroundColor Red
Write-Host ""

$ErrorActionPreference = "Continue"
$updateResult = az containerapp update `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --set-env-vars "OPENAI_API_KEY=$envKey" 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Container App atualizado" -ForegroundColor Green
    Write-Host "[INFO] Aguardando 30s para revision ficar pronta..." -ForegroundColor Yellow
    Start-Sleep -Seconds 30
    
    Write-Host ""
    Write-Host "=== Teste Agora ===" -ForegroundColor Cyan
    Write-Host "[INFO] Execute a ingestão para testar:" -ForegroundColor Yellow
    Write-Host "  .\infra\run_ingest_in_container.ps1" -ForegroundColor Gray
    Write-Host ""
    Write-Host "[INFO] Se funcionar, o problema é a resolução do Key Vault." -ForegroundColor Yellow
    Write-Host "[INFO] Para reverter para Key Vault reference:" -ForegroundColor Yellow
    Write-Host "  .\infra\fix_keyvault_reference_with_version.ps1" -ForegroundColor Gray
} else {
    Write-Host "[ERRO] Falha ao atualizar: $updateResult" -ForegroundColor Red
    exit 1
}

$ErrorActionPreference = "Stop"
