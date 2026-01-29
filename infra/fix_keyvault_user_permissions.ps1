# Script para verificar e conceder permissões ao usuário atual no Key Vault

param(
    [string]$ResourceGroup = $null,
    [string]$KeyVaultName = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Verificar/Conceder Permissoes no Key Vault ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se não fornecido
if (-not $ResourceGroup -or -not $KeyVaultName) {
    $stateFile = ".azure/deploy_state.json"
    if (-not (Test-Path $stateFile)) {
        Write-Host "[ERRO] Arquivo $stateFile nao encontrado." -ForegroundColor Red
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

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] Key Vault: $KeyVaultName" -ForegroundColor Yellow
Write-Host ""

# Obter informações do usuário atual
Write-Host "[INFO] Obtendo informacoes do usuario atual..." -ForegroundColor Yellow
$currentUser = az account show --query user.name -o tsv
$userObjectId = az ad signed-in-user show --query id -o tsv

Write-Host "  Usuario: $currentUser" -ForegroundColor Gray
Write-Host "  Object ID: $userObjectId" -ForegroundColor Gray
Write-Host ""

# Verificar se Key Vault usa RBAC ou Access Policies
Write-Host "[INFO] Verificando tipo de autorizacao do Key Vault..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$kvRbacEnabled = az keyvault show --name $KeyVaultName --resource-group $ResourceGroup --query "properties.enableRbacAuthorization" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if ($kvRbacEnabled -eq $true) {
    Write-Host "[INFO] Key Vault usa RBAC" -ForegroundColor Yellow
    Write-Host ""
    
    $subscriptionId = az account show --query id -o tsv
    $kvResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$KeyVaultName"
    
    # Verificar permissões atuais
    Write-Host "[INFO] Verificando suas permissoes RBAC..." -ForegroundColor Yellow
    $ErrorActionPreference = "Continue"
    $userRoles = az role assignment list --scope $kvResourceId --assignee $userObjectId --query "[].roleDefinitionName" -o tsv 2>$null
    $ErrorActionPreference = "Stop"
    
    if ($userRoles) {
        Write-Host "[OK] Voce tem as seguintes permissoes:" -ForegroundColor Green
        $userRoles | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
        
        $hasSecretOps = $userRoles | Where-Object { 
            $_ -like "*Key Vault Secrets Officer*" -or 
            $_ -like "*Key Vault Secrets User*" -or 
            $_ -like "*Contributor*" -or 
            $_ -like "*Owner*" 
        }
        
        if (-not $hasSecretOps) {
            Write-Host ""
            Write-Host "[AVISO] Voce nao tem permissao para criar/gerenciar secrets!" -ForegroundColor Yellow
            Write-Host "[INFO] Para conceder permissao, voce precisa de 'User Access Administrator' ou 'Owner'" -ForegroundColor Cyan
            Write-Host "[INFO] Ou peca a um administrador para executar:" -ForegroundColor Cyan
            Write-Host "  az role assignment create --assignee $userObjectId --role 'Key Vault Secrets Officer' --scope '$kvResourceId'" -ForegroundColor Gray
        } else {
            Write-Host ""
            Write-Host "[OK] Voce tem permissao suficiente para criar secrets!" -ForegroundColor Green
        }
    } else {
        Write-Host "[ERRO] Voce nao tem permissoes RBAC no Key Vault!" -ForegroundColor Red
        Write-Host "[INFO] Para conceder permissao, voce precisa de 'User Access Administrator' ou 'Owner'" -ForegroundColor Cyan
        Write-Host "[INFO] Ou peca a um administrador para executar:" -ForegroundColor Cyan
        Write-Host "  az role assignment create --assignee $userObjectId --role 'Key Vault Secrets Officer' --scope '$kvResourceId'" -ForegroundColor Gray
    }
} else {
    Write-Host "[INFO] Key Vault usa Access Policies (metodo antigo)" -ForegroundColor Yellow
    Write-Host ""
    
    # Verificar Access Policies
    $ErrorActionPreference = "Continue"
    $kvPermissions = az keyvault show --name $KeyVaultName --resource-group $ResourceGroup --query "properties.accessPolicies[?objectId=='$userObjectId'].permissions" -o json 2>$null | ConvertFrom-Json
    $ErrorActionPreference = "Stop"
    
    if ($kvPermissions) {
        Write-Host "[OK] Voce tem Access Policy configurada:" -ForegroundColor Green
        if ($kvPermissions.secrets) {
            Write-Host "  Secrets: $($kvPermissions.secrets -join ', ')" -ForegroundColor Gray
        }
        
        $hasSetPermission = $kvPermissions.secrets -contains "set" -or $kvPermissions.secrets -contains "all"
        if (-not $hasSetPermission) {
            Write-Host ""
            Write-Host "[AVISO] Voce nao tem permissao 'set' para criar secrets!" -ForegroundColor Yellow
            Write-Host "[INFO] Para conceder permissao, execute:" -ForegroundColor Cyan
            Write-Host "  az keyvault set-policy --name $KeyVaultName --object-id $userObjectId --secret-permissions get list set delete" -ForegroundColor Gray
        } else {
            Write-Host ""
            Write-Host "[OK] Voce tem permissao para criar secrets!" -ForegroundColor Green
        }
    } else {
        Write-Host "[ERRO] Voce nao tem Access Policy configurada no Key Vault!" -ForegroundColor Red
        Write-Host "[INFO] Para conceder permissao, execute:" -ForegroundColor Cyan
        Write-Host "  az keyvault set-policy --name $KeyVaultName --object-id $userObjectId --secret-permissions get list set delete" -ForegroundColor Gray
    }
}

Write-Host ""
