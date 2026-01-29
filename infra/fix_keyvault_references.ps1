# Script para corrigir referências do Key Vault em Container Apps existentes
# Converte de sintaxe de App Service (@Microsoft.KeyVault) para sintaxe de Container Apps (keyvaultref + secretref)
#
# Uso: .\infra\fix_keyvault_references.ps1

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Corrigir Referências do Key Vault no Container App ===" -ForegroundColor Cyan
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
Write-Host "[INFO] Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host ""

# Obter Key Vault name
$KeyVault = $state.keyVaultName
if (-not $KeyVault) {
    Write-Host "[ERRO] Key Vault name não encontrado no deploy_state.json" -ForegroundColor Red
    exit 1
}

Write-Host "[INFO] Key Vault: $KeyVault" -ForegroundColor Yellow
Write-Host ""

# Verificar Container App
Write-Host "[INFO] Verificando Container App..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$appExists = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "name" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if (-not $appExists) {
    Write-Host "[ERRO] Container App '$ApiAppName' não encontrado" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Container App encontrado" -ForegroundColor Green
Write-Host ""

# Obter env vars atuais
Write-Host "[INFO] Analisando variáveis de ambiente atuais..." -ForegroundColor Yellow
$currentEnv = az containerapp show `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --query "properties.template.containers[0].env" -o json | ConvertFrom-Json

$secretsToAdd = @()
$envVarsToUpdate = @()
$needsUpdate = $false

foreach ($envVar in $currentEnv) {
    $name = $envVar.name
    $value = $envVar.value
    $secretRef = $envVar.secretRef
    
    # Verificar se está usando sintaxe errada (@Microsoft.KeyVault)
    if ($value -and $value -match '^@Microsoft\.KeyVault\(SecretUri=https://([^/]+)\.vault\.azure\.net/secrets/([^/]+)') {
        $vaultName = $matches[1]
        $secretName = $matches[2]
        
        Write-Host "  [AVISO] Encontrada sintaxe errada em $name : $value" -ForegroundColor Yellow
        
        # Extrair nome do secret do Key Vault (sem versão)
        $kvSecretName = $secretName -replace '/.*$', ''
        
        # Adicionar secret com keyvaultref
        $secretUri = "https://$vaultName.vault.azure.net/secrets/$kvSecretName"
        $secretsToAdd += "$kvSecretName=keyvaultref:$secretUri"
        
        # Adicionar env var com secretref
        $envVarsToUpdate += "$name=secretref:$kvSecretName"
        
        $needsUpdate = $true
        Write-Host "  [INFO] Será convertido para: secretRef=$kvSecretName" -ForegroundColor Cyan
    } elseif ($secretRef) {
        # Já está usando secretRef (correto)
        Write-Host "  [OK] $name já usa secretRef: $secretRef" -ForegroundColor Green
        $envVarsToUpdate += "$name=secretref:$secretRef"
    } elseif ($value) {
        # Variável normal (não é secret)
        Write-Host "  [OK] $name = $value (variável normal)" -ForegroundColor Gray
        $envVarsToUpdate += "$name=$value"
    }
}

if (-not $needsUpdate) {
    Write-Host "[OK] Nenhuma correção necessária. Todas as referências já estão corretas." -ForegroundColor Green
    exit 0
}

Write-Host ""
Write-Host "[INFO] Aplicando correções..." -ForegroundColor Yellow
Write-Host ""

# Aplicar correções
$ErrorActionPreference = "Continue"

# Primeiro, adicionar secrets com keyvaultref
if ($secretsToAdd.Count -gt 0) {
    Write-Host "[INFO] Adicionando secrets do Key Vault..." -ForegroundColor Cyan
    foreach ($secret in $secretsToAdd) {
        Write-Host "  - $secret" -ForegroundColor Gray
    }
    
    az containerapp update `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --set-secrets $secretsToAdd 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Secrets adicionados" -ForegroundColor Green
    } else {
        Write-Host "[ERRO] Falha ao adicionar secrets" -ForegroundColor Red
        exit 1
    }
    Write-Host ""
}

# Depois, atualizar env vars com secretref
Write-Host "[INFO] Atualizando variáveis de ambiente..." -ForegroundColor Cyan
az containerapp update `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --set-env-vars $envVarsToUpdate 2>&1 | Out-Null

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Variáveis de ambiente atualizadas" -ForegroundColor Green
} else {
    Write-Host "[ERRO] Falha ao atualizar variáveis de ambiente" -ForegroundColor Red
    exit 1
}

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== Correção Concluída ===" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] O Container App foi atualizado para usar a sintaxe correta do Container Apps:" -ForegroundColor Yellow
Write-Host "  - Secrets: keyvaultref:<SecretUri>" -ForegroundColor Gray
Write-Host "  - Env Vars: secretref:<SecretName>" -ForegroundColor Gray
Write-Host ""
Write-Host "[INFO] Aguarde alguns segundos para a nova revision ser criada..." -ForegroundColor Cyan
Write-Host ""
