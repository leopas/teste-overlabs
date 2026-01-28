# Script para verificar secret no Key Vault

param(
    [string]$ResourceGroup = $null,
    [string]$KeyVaultName = $null,
    [string]$SecretName = "openai-api-key"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Verificar Secret no Key Vault ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se não fornecido
if (-not $ResourceGroup -or -not $KeyVaultName) {
    $stateFile = ".azure/deploy_state.json"
    if (-not (Test-Path $stateFile)) {
        Write-Host "[ERRO] Arquivo $stateFile não encontrado. Forneça -ResourceGroup e -KeyVaultName." -ForegroundColor Red
        exit 1
    }
    $state = Get-Content $stateFile | ConvertFrom-Json
    if (-not $ResourceGroup) {
        $ResourceGroup = $state.resourceGroup
    }
    if (-not $KeyVaultName) {
        $KeyVaultName = $state.keyVaultName
    }
}

Write-Host "[INFO] Key Vault: $KeyVaultName" -ForegroundColor Yellow
Write-Host "[INFO] Secret: $SecretName" -ForegroundColor Yellow
Write-Host ""

# Verificar se o secret existe
Write-Host "[INFO] Verificando secret no Key Vault..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$secretInfo = az keyvault secret show --vault-name $KeyVaultName --name $SecretName --query "{enabled:attributes.enabled,created:attributes.created,updated:attributes.updated,contentType:contentType}" -o json 2>$null
$ErrorActionPreference = "Stop"

if (-not $secretInfo) {
    Write-Host "[ERRO] Secret '$SecretName' não encontrado no Key Vault!" -ForegroundColor Red
    exit 1
}

$secretObj = $secretInfo | ConvertFrom-Json
Write-Host "[OK] Secret existe no Key Vault" -ForegroundColor Green
Write-Host "  Habilitado: $($secretObj.enabled)" -ForegroundColor Gray
Write-Host "  Criado: $($secretObj.created)" -ForegroundColor Gray
Write-Host "  Atualizado: $($secretObj.updated)" -ForegroundColor Gray
Write-Host ""

# Obter o valor (sem mostrar completo por segurança)
Write-Host "[INFO] Verificando valor do secret..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$secretValue = az keyvault secret show --vault-name $KeyVaultName --name $SecretName --query "value" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if (-not $secretValue) {
    Write-Host "[ERRO] Não foi possível obter o valor do secret!" -ForegroundColor Red
    exit 1
}

# Verificar características do valor (sem mostrar completo)
$valueLength = $secretValue.Length
$startsWithSk = $secretValue.StartsWith("sk-")
$hasValidLength = $valueLength -ge 20 -and $valueLength -le 200

Write-Host "[OK] Valor do secret obtido" -ForegroundColor Green
Write-Host "  Tamanho: $valueLength caracteres" -ForegroundColor Gray
Write-Host "  Começa com 'sk-': $startsWithSk" -ForegroundColor Gray
Write-Host "  Tamanho válido: $hasValidLength" -ForegroundColor Gray
Write-Host "  Primeiros 10 caracteres: $($secretValue.Substring(0, [Math]::Min(10, $valueLength)))..." -ForegroundColor Gray
Write-Host ""

# Validações
$issues = @()

if (-not $startsWithSk) {
    $issues += "Secret não começa com 'sk-' (formato esperado para OpenAI API key)"
}

if (-not $hasValidLength) {
    $issues += "Secret tem tamanho inválido (esperado entre 20-200 caracteres, encontrado: $valueLength)"
}

if ($issues.Count -eq 0) {
    Write-Host "[OK] Secret parece estar no formato correto!" -ForegroundColor Green
    Write-Host ""
    Write-Host "[INFO] Para testar se a chave funciona, execute:" -ForegroundColor Cyan
    Write-Host "  .\infra\verify_openai_key.ps1" -ForegroundColor Gray
} else {
    Write-Host "[AVISO] Problemas encontrados no secret:" -ForegroundColor Yellow
    foreach ($issue in $issues) {
        Write-Host "  - $issue" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "[INFO] Para atualizar o secret:" -ForegroundColor Cyan
    Write-Host "  az keyvault secret set --vault-name $KeyVaultName --name '$SecretName' --value 'sk-sua-chave-aqui'" -ForegroundColor Gray
}

Write-Host ""
