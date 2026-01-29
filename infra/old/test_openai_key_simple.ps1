# Script simples para testar se OPENAI_API_KEY está sendo resolvida

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null
)

$ErrorActionPreference = "Stop"

# Carregar deploy_state.json se não fornecido
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

Write-Host "=== Teste Simples: OPENAI_API_KEY ===" -ForegroundColor Cyan
Write-Host ""

# Teste 1: Verificar se a variável existe (usando módulo Python)
Write-Host "[TESTE 1] Verificando se OPENAI_API_KEY existe no container..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$test1 = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "python -c 'import os; key = os.getenv(\"OPENAI_API_KEY\"); print(\"EXISTS\" if key else \"NOT_SET\")'" 2>&1

Write-Host $test1
Write-Host ""

# Teste 2: Verificar formato da chave (primeiros caracteres)
Write-Host "[TESTE 2] Verificando formato da chave..." -ForegroundColor Yellow
$test2 = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "python -c 'import os; key = os.getenv(\"OPENAI_API_KEY\", \"\"); print(key[:10] + \"...\" if len(key) > 10 else \"EMPTY\")'" 2>&1

Write-Host $test2
Write-Host ""

# Teste 3: Verificar se começa com sk-
Write-Host "[TESTE 3] Verificando se chave começa com 'sk-'..." -ForegroundColor Yellow
$test3 = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "python -c 'import os; key = os.getenv(\"OPENAI_API_KEY\", \"\"); print(\"YES\" if key.startswith(\"sk-\") else \"NO\")'" 2>&1

Write-Host $test3
Write-Host ""

$ErrorActionPreference = "Stop"

Write-Host "=== Resumo ===" -ForegroundColor Cyan
if ($test1 -match "EXISTS" -and $test3 -match "YES") {
    Write-Host "[OK] OPENAI_API_KEY está configurada e no formato correto!" -ForegroundColor Green
} else {
    Write-Host "[ERRO] OPENAI_API_KEY não está sendo resolvida corretamente!" -ForegroundColor Red
    Write-Host "[INFO] Teste 1: $test1" -ForegroundColor Gray
    Write-Host "[INFO] Teste 2: $test2" -ForegroundColor Gray
    Write-Host "[INFO] Teste 3: $test3" -ForegroundColor Gray
}
