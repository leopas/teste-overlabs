# Script para comparar tamanho da OPENAI_API_KEY entre .env e Key Vault

param(
    [string]$ResourceGroup = $null,
    [string]$KeyVaultName = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Comparar OPENAI_API_KEY: .env vs Key Vault ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se necessário
if (-not $ResourceGroup -or -not $KeyVaultName) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoRoot = Split-Path -Parent $scriptDir
    $stateFile = Join-Path $repoRoot ".azure\deploy_state.json"
    
    if (Test-Path $stateFile) {
        $state = Get-Content $stateFile | ConvertFrom-Json
        if (-not $ResourceGroup) {
            $ResourceGroup = $state.resourceGroup
        }
        if (-not $KeyVaultName) {
            $KeyVaultName = $state.keyVaultName
        }
    }
}

if (-not $KeyVaultName) {
    Write-Host "[ERRO] Key Vault name não fornecido e não encontrado em deploy_state.json" -ForegroundColor Red
    exit 1
}

# 1. Ler chave do .env
Write-Host "[1/3] Lendo OPENAI_API_KEY do .env..." -ForegroundColor Yellow
$envFile = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) ".env"

if (-not (Test-Path $envFile)) {
    Write-Host "[ERRO] Arquivo .env não encontrado em: $envFile" -ForegroundColor Red
    exit 1
}

$envContent = Get-Content $envFile
$envKey = $null

foreach ($line in $envContent) {
    if ($line -match '^\s*OPENAI_API_KEY\s*=\s*(.+)$') {
        $envKey = $matches[1].Trim()
        # Remover aspas se houver
        $envKey = $envKey -replace '^["'']|["'']$', ''
        break
    }
}

if (-not $envKey) {
    Write-Host "[ERRO] OPENAI_API_KEY não encontrada no .env" -ForegroundColor Red
    exit 1
}

$envKeyLength = $envKey.Length
Write-Host "[OK] Chave encontrada no .env" -ForegroundColor Green
Write-Host "[INFO] Tamanho: $envKeyLength caracteres" -ForegroundColor Gray
Write-Host "[INFO] Primeiros 15 caracteres: $($envKey.Substring(0, [Math]::Min(15, $envKeyLength)))..." -ForegroundColor Gray
Write-Host ""

# 2. Ler chave do Key Vault
Write-Host "[2/3] Lendo openai-api-key do Key Vault..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$kvKey = az keyvault secret show `
    --vault-name $KeyVaultName `
    --name "openai-api-key" `
    --query "value" -o tsv 2>&1

if ($LASTEXITCODE -ne 0 -or -not $kvKey) {
    Write-Host "[ERRO] Falha ao ler secret do Key Vault: $kvKey" -ForegroundColor Red
    exit 1
}

$kvKeyLength = $kvKey.Length
Write-Host "[OK] Chave encontrada no Key Vault" -ForegroundColor Green
Write-Host "[INFO] Tamanho: $kvKeyLength caracteres" -ForegroundColor Gray
Write-Host "[INFO] Primeiros 15 caracteres: $($kvKey.Substring(0, [Math]::Min(15, $kvKeyLength)))..." -ForegroundColor Gray
Write-Host ""

$ErrorActionPreference = "Stop"

# 3. Comparar
Write-Host "[3/3] Comparando..." -ForegroundColor Yellow
Write-Host ""

if ($envKeyLength -eq $kvKeyLength) {
    Write-Host "[OK] Tamanhos são IGUAIS: $envKeyLength caracteres" -ForegroundColor Green
    
    # Verificar se são exatamente iguais (sem mostrar a chave completa)
    if ($envKey -eq $kvKey) {
        Write-Host "[OK] As chaves são IDÊNTICAS" -ForegroundColor Green
    } else {
        Write-Host "[AVISO] As chaves têm o mesmo tamanho mas são DIFERENTES" -ForegroundColor Yellow
        Write-Host "[INFO] Isso pode indicar que a chave no Key Vault foi atualizada" -ForegroundColor Gray
    }
} else {
    Write-Host "[ERRO] Tamanhos são DIFERENTES!" -ForegroundColor Red
    Write-Host "[INFO] .env: $envKeyLength caracteres" -ForegroundColor Gray
    Write-Host "[INFO] Key Vault: $kvKeyLength caracteres" -ForegroundColor Gray
    Write-Host ""
    Write-Host "[INFO] A chave no Key Vault precisa ser atualizada!" -ForegroundColor Yellow
    Write-Host "[INFO] Execute:" -ForegroundColor Yellow
    Write-Host "  az keyvault secret set --vault-name $KeyVaultName --name openai-api-key --value `"<chave-do-env>`"" -ForegroundColor Gray
}

Write-Host ""
Write-Host "=== Resumo ===" -ForegroundColor Cyan
Write-Host "Tamanho .env: $envKeyLength caracteres" -ForegroundColor Gray
Write-Host "Tamanho Key Vault: $kvKeyLength caracteres" -ForegroundColor Gray
if ($envKeyLength -eq $kvKeyLength) {
    Write-Host "Status: [OK] Tamanhos iguais" -ForegroundColor Green
} else {
    Write-Host "Status: [ERRO] Tamanhos diferentes" -ForegroundColor Red
}
Write-Host ""
