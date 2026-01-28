# Script para verificar se a variável de ambiente do Container App está resolvendo o Key Vault corretamente

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$KeyVaultName = $null,
    [string]$SecretName = "openai-api-key"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Verificar Resolução do Key Vault no Container ===" -ForegroundColor Cyan
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
    if (-not $KeyVaultName) {
        $KeyVaultName = $state.keyVaultName
    }
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] API Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host "[INFO] Key Vault: $KeyVaultName" -ForegroundColor Yellow
Write-Host "[INFO] Secret: $SecretName" -ForegroundColor Yellow
Write-Host ""

# 1. Verificar configuração no Container App
Write-Host "[INFO] Verificando configuração no Container App..." -ForegroundColor Yellow
$appConfig = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].env" -o json | ConvertFrom-Json

$openAIKeyConfig = $null
foreach ($env in $appConfig) {
    if ($env.name -eq "OPENAI_API_KEY") {
        $openAIKeyConfig = $env
        break
    }
}

if (-not $openAIKeyConfig) {
    Write-Host "[ERRO] OPENAI_API_KEY não está configurada no Container App!" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] OPENAI_API_KEY está configurada" -ForegroundColor Green
Write-Host "  Configuração: $($openAIKeyConfig.value)" -ForegroundColor Gray
Write-Host ""

# Verificar se é referência ao Key Vault
if ($openAIKeyConfig.value -notmatch "KeyVault") {
    Write-Host "[AVISO] OPENAI_API_KEY não está usando referência ao Key Vault" -ForegroundColor Yellow
    Write-Host "  Valor atual parece ser um valor direto, não uma referência" -ForegroundColor Gray
} else {
    Write-Host "[OK] OPENAI_API_KEY está configurada com referência ao Key Vault" -ForegroundColor Green
}
Write-Host ""

# 2. Verificar Managed Identity
Write-Host "[INFO] Verificando Managed Identity do Container App..." -ForegroundColor Yellow
$identity = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "identity" -o json | ConvertFrom-Json

if (-not $identity -or -not $identity.type -or $identity.type -ne "SystemAssigned") {
    Write-Host "[AVISO] Managed Identity não está habilitada ou não é SystemAssigned" -ForegroundColor Yellow
    Write-Host "[INFO] Habilitando Managed Identity..." -ForegroundColor Cyan
    
    az containerapp identity assign `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --system-assigned | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Managed Identity habilitada" -ForegroundColor Green
        Start-Sleep -Seconds 5
    } else {
        Write-Host "[ERRO] Falha ao habilitar Managed Identity" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "[OK] Managed Identity está habilitada (SystemAssigned)" -ForegroundColor Green
    $principalId = $identity.principalId
    Write-Host "  Principal ID: $principalId" -ForegroundColor Gray
}
Write-Host ""

# 3. Verificar permissões no Key Vault
Write-Host "[INFO] Verificando permissões no Key Vault..." -ForegroundColor Yellow
$identity = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "identity.principalId" -o tsv

if ($identity) {
    $ErrorActionPreference = "Continue"
    $hasPermission = az keyvault show --name $KeyVaultName --query "properties.accessPolicies[?objectId=='$identity']" -o json 2>$null
    $ErrorActionPreference = "Stop"
    
    if ($hasPermission -and ($hasPermission | ConvertFrom-Json).Count -gt 0) {
        Write-Host "[OK] Container App tem permissões no Key Vault" -ForegroundColor Green
    } else {
        Write-Host "[AVISO] Container App pode não ter permissões no Key Vault" -ForegroundColor Yellow
        Write-Host "[INFO] Concedendo permissão 'Key Vault Secrets User'..." -ForegroundColor Cyan
        
        az role assignment create `
            --assignee $identity `
            --role "Key Vault Secrets User" `
            --scope "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$KeyVaultName" 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Permissão concedida" -ForegroundColor Green
        } else {
            Write-Host "[AVISO] Pode já ter permissão ou erro ao conceder. Continuando..." -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "[AVISO] Não foi possível obter Principal ID da Managed Identity" -ForegroundColor Yellow
}
Write-Host ""

# 4. Verificar valor no container (o que realmente está sendo resolvido)
Write-Host "[INFO] Verificando valor resolvido no container..." -ForegroundColor Yellow
Write-Host "  (Isso pode levar alguns segundos se o Key Vault precisar resolver)" -ForegroundColor Gray
Write-Host ""

$ErrorActionPreference = "Continue"

# Teste simples: verificar se a variável existe e tem valor
$checkScript = @'
import os
import sys

key = os.getenv('OPENAI_API_KEY', 'NOT_SET')

if key == 'NOT_SET':
    print('[ERRO] OPENAI_API_KEY não encontrada no container')
    sys.exit(1)

print(f'[OK] OPENAI_API_KEY encontrada no container')
print(f'[INFO] Tamanho: {len(key)} caracteres')
print(f'[INFO] Começa com sk-: {key.startswith("sk-")}')

# Mostrar primeiros e últimos caracteres (sem mostrar completo)
if len(key) > 20:
    preview = f'{key[:10]}...{key[-4:]}'
else:
    preview = key[:10] + '...'
print(f'[INFO] Preview: {preview}')

sys.exit(0)
'@

# Executar usando método mais simples
$checkOutput = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "python3 -c `"$($checkScript -replace '"', '\"')`"" 2>&1

Write-Host $checkOutput

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "[OK] Variável de ambiente está sendo resolvida no container!" -ForegroundColor Green
    
    # Verificar se o valor parece correto
    if ($checkOutput -match "Começa com sk-: True") {
        Write-Host "[OK] Valor parece estar no formato correto (começa com sk-)" -ForegroundColor Green
    } else {
        Write-Host "[AVISO] Valor não começa com 'sk-' - pode estar incorreto" -ForegroundColor Yellow
    }
} else {
    Write-Host ""
    Write-Host "[ERRO] Não foi possível verificar a variável no container" -ForegroundColor Red
    Write-Host "[INFO] Possíveis causas:" -ForegroundColor Yellow
    Write-Host "  1. Managed Identity não tem permissões no Key Vault" -ForegroundColor Gray
    Write-Host "  2. Key Vault reference está incorreta" -ForegroundColor Gray
    Write-Host "  3. Container App precisa ser reiniciado para pegar as mudanças" -ForegroundColor Gray
    exit 1
}

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== Verificação Concluída! ===" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] Se a variável está sendo resolvida corretamente, você pode executar:" -ForegroundColor Cyan
Write-Host "  .\infra\run_ingest_in_container.ps1 -TruncateFirst" -ForegroundColor Gray
Write-Host ""
