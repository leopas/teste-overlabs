# Script simples para verificar OPENAI_API_KEY sem problemas de escape

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null
)

$ErrorActionPreference = "Stop"

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

Write-Host "=== Verificar OPENAI_API_KEY ===" -ForegroundColor Cyan
Write-Host ""

# 1. Verificar configuração no Container App
Write-Host "[1/3] Verificando configuração no Container App..." -ForegroundColor Yellow
$envVar = az containerapp show `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --query "properties.template.containers[0].env[?name=='OPENAI_API_KEY'].value" -o tsv 2>&1

if ($envVar -match "KeyVault") {
    Write-Host "[OK] Referência Key Vault configurada" -ForegroundColor Green
    Write-Host "[INFO] Referência: $envVar" -ForegroundColor Gray
} else {
    Write-Host "[ERRO] Referência Key Vault não encontrada!" -ForegroundColor Red
    exit 1
}
Write-Host ""

# 2. Verificar Managed Identity
Write-Host "[2/3] Verificando Managed Identity..." -ForegroundColor Yellow
$mi = az containerapp show `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --query "identity" -o json 2>&1 | ConvertFrom-Json

if ($mi.type -match "SystemAssigned") {
    Write-Host "[OK] Managed Identity habilitada" -ForegroundColor Green
    Write-Host "[INFO] Principal ID: $($mi.principalId)" -ForegroundColor Gray
} else {
    Write-Host "[ERRO] Managed Identity não habilitada!" -ForegroundColor Red
    exit 1
}
Write-Host ""

# 3. Verificar logs recentes para erros 401
Write-Host "[3/3] Verificando logs recentes para erros 401..." -ForegroundColor Yellow
$logs = az containerapp logs show `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --tail 50 `
    --type console 2>&1

$has401 = $logs | Select-String -Pattern "401|Unauthorized" -CaseSensitive:$false

if ($has401) {
    Write-Host "[ERRO] Encontrados erros 401 Unauthorized nos logs!" -ForegroundColor Red
    Write-Host "[INFO] Isso indica que a Key Vault reference NÃO está sendo resolvida." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "[INFO] Próximos passos:" -ForegroundColor Yellow
    Write-Host "  1. Aguardar mais 10-15 minutos para a resolução ser propagada" -ForegroundColor Gray
    Write-Host "  2. Reiniciar o Container App:" -ForegroundColor Gray
    Write-Host "     az containerapp revision restart --name $ApiAppName --resource-group $ResourceGroup --revision <latest>" -ForegroundColor Gray
    Write-Host "  3. Verificar permissões RBAC no Key Vault:" -ForegroundColor Gray
    Write-Host "     .\infra\diagnose_keyvault_resolution.ps1" -ForegroundColor Gray
} else {
    Write-Host "[INFO] Nenhum erro 401 encontrado nos logs recentes" -ForegroundColor Green
    Write-Host "[INFO] Isso pode indicar que a chave está funcionando, ou que não houve tentativas recentes." -ForegroundColor Gray
}

Write-Host ""
Write-Host "=== Resumo ===" -ForegroundColor Cyan
Write-Host "[OK] Configuração: Key Vault reference configurada" -ForegroundColor Green
Write-Host "[OK] Managed Identity: Habilitada" -ForegroundColor Green
if ($has401) {
    Write-Host "[ERRO] Status: Key Vault reference NÃO está sendo resolvida (erros 401)" -ForegroundColor Red
} else {
    Write-Host "[INFO] Status: Não foi possível determinar se está resolvida (sem erros 401 recentes)" -ForegroundColor Yellow
}
Write-Host ""
