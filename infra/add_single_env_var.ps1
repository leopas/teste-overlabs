# Script para adicionar uma única variável de ambiente ao Container App
# Uso: .\infra\add_single_env_var.ps1 -VarName "AUDIT_LOG_RAW_MAX_CHARS" -VarValue "2000"

param(
    [Parameter(Mandatory=$true)]
    [string]$VarName,
    
    [Parameter(Mandatory=$true)]
    [string]$VarValue,
    
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Adicionar Variável de Ambiente ===" -ForegroundColor Cyan
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
Write-Host "[INFO] Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host "[INFO] Variável: $VarName = $VarValue" -ForegroundColor Yellow
Write-Host ""

# Verificar se Container App existe
Write-Host "[INFO] Verificando Container App..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$appExists = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "name" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if (-not $appExists) {
    Write-Host "[ERRO] Container App '$ApiAppName' não encontrado no Resource Group '$ResourceGroup'" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Container App encontrado" -ForegroundColor Green
Write-Host ""

# Adicionar variável de ambiente
Write-Host "[INFO] Adicionando variável de ambiente..." -ForegroundColor Cyan

# Usar aspas duplas para evitar problemas com PowerShell interpretando o =
$envVarString = "${VarName}=${VarValue}"

$ErrorActionPreference = "Continue"
$result = az containerapp update `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --set-env-vars "$envVarString" 2>&1

$ErrorActionPreference = "Stop"

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Variável '$VarName' adicionada com sucesso!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Valor configurado: $VarName = $VarValue" -ForegroundColor Cyan
} else {
    Write-Host "[ERRO] Falha ao adicionar variável" -ForegroundColor Red
    Write-Host ""
    Write-Host "Saída do comando:" -ForegroundColor Yellow
    Write-Host $result
    exit 1
}

Write-Host ""
Write-Host "=== Concluído! ===" -ForegroundColor Green
