# Script para configurar OPENAI_API_KEY diretamente (temporário, para testar)
# ATENÇÃO: Isso expõe a chave como variável de ambiente, não é recomendado para produção

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

Write-Host "=== Configurar OPENAI_API_KEY Diretamente (TEMPORÁRIO) ===" -ForegroundColor Yellow
Write-Host "[AVISO] Isso expõe a chave como variável de ambiente!" -ForegroundColor Red
Write-Host "[AVISO] Use apenas para testar se o problema é a resolução do Key Vault." -ForegroundColor Yellow
Write-Host ""

if (-not $Force) {
    $confirm = Read-Host "Deseja continuar? (S/N)"
    if ($confirm -ne "S" -and $confirm -ne "s") {
        Write-Host "Operação cancelada." -ForegroundColor Yellow
        exit 0
    }
}

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
Write-Host "[INFO] Lendo OPENAI_API_KEY do .env..." -ForegroundColor Yellow
$envFile = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) ".env"

if (-not (Test-Path $envFile)) {
    Write-Host "[ERRO] Arquivo .env não encontrado!" -ForegroundColor Red
    exit 1
}

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

Write-Host "[OK] Chave encontrada no .env (${envKey.Length} caracteres)" -ForegroundColor Green
Write-Host ""

# Configurar diretamente no Container App
Write-Host "[INFO] Configurando OPENAI_API_KEY diretamente no Container App..." -ForegroundColor Yellow
Write-Host "[AVISO] A chave será visível como variável de ambiente!" -ForegroundColor Red
Write-Host ""

$ErrorActionPreference = "Continue"
$updateResult = az containerapp update `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --set-env-vars "OPENAI_API_KEY=$envKey" 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Container App atualizado com chave direta" -ForegroundColor Green
    Write-Host "[INFO] Aguardando nova revision ficar pronta..." -ForegroundColor Yellow
    
    Start-Sleep -Seconds 30
    
    Write-Host ""
    Write-Host "=== Configuração Concluída ===" -ForegroundColor Green
    Write-Host "[INFO] Teste a ingestão novamente:" -ForegroundColor Yellow
    Write-Host "  .\infra\run_ingest_in_container.ps1" -ForegroundColor Gray
    Write-Host ""
    Write-Host "[AVISO] Lembre-se de reverter para Key Vault reference depois do teste!" -ForegroundColor Red
    Write-Host "[INFO] Para reverter:" -ForegroundColor Yellow
    Write-Host "  .\infra\fix_keyvault_reference_with_version.ps1" -ForegroundColor Gray
} else {
    Write-Host "[ERRO] Falha ao atualizar Container App: $updateResult" -ForegroundColor Red
    exit 1
}

$ErrorActionPreference = "Stop"
