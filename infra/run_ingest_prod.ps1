# Script PowerShell simples para executar ingestão de produção
# Usa o script Python dedicado com logs detalhados

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [switch]$TruncateFirst,
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"

Write-Host "=== Executar Ingestão de Produção ===" -ForegroundColor Cyan
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

# Verificar se Container App existe
Write-Host "[INFO] Verificando Container App..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$appExists = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "name" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if (-not $appExists) {
    Write-Host "[ERRO] Container App '$ApiAppName' não encontrado!" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Container App encontrado" -ForegroundColor Green
Write-Host ""

# Construir comando Python
# Usar caminho direto do arquivo (mais confiável que módulo)
$pythonCmd = "python /app/scripts/ingest_prod.py"

if ($TruncateFirst) {
    $pythonCmd += " --truncate"
    Write-Host "[INFO] Collection será truncada antes da ingestão" -ForegroundColor Yellow
}

if ($Verbose) {
    $pythonCmd += " --verbose"
    Write-Host "[INFO] Modo verboso ativado" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "[INFO] Executando ingestão..." -ForegroundColor Cyan
Write-Host "[INFO] Comando: $pythonCmd" -ForegroundColor Gray
Write-Host ""

# Executar comando no container
$ErrorActionPreference = "Continue"
az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command $pythonCmd 2>&1 | Out-Host

$exitCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"

Write-Host ""

if ($exitCode -eq 0) {
    Write-Host "=== Ingestão Concluída com Sucesso! ===" -ForegroundColor Green
} else {
    Write-Host "=== Ingestão Falhou (exit code: $exitCode) ===" -ForegroundColor Red
    Write-Host "[INFO] Verifique os logs acima para detalhes" -ForegroundColor Yellow
}

Write-Host ""
exit $exitCode
