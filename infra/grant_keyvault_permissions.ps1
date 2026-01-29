# Script para conceder permissões no Key Vault ao usuário atual
# Tenta conceder automaticamente, ou mostra comando para administrador

param(
    [string]$ResourceGroup = $null,
    [string]$KeyVaultName = $null,
    [string]$UserObjectId = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Conceder Permissoes no Key Vault ===" -ForegroundColor Cyan
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

# Obter Object ID do usuário atual se não fornecido
if (-not $UserObjectId) {
    Write-Host "[INFO] Obtendo Object ID do usuario atual..." -ForegroundColor Yellow
    $UserObjectId = az ad signed-in-user show --query id -o tsv
    $currentUser = az account show --query user.name -o tsv
    Write-Host "  Usuario: $currentUser" -ForegroundColor Gray
    Write-Host "  Object ID: $UserObjectId" -ForegroundColor Gray
    Write-Host ""
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] Key Vault: $KeyVaultName" -ForegroundColor Yellow
Write-Host ""

# Verificar se Key Vault usa RBAC
Write-Host "[INFO] Verificando tipo de autorizacao do Key Vault..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$kvRbacEnabled = az keyvault show --name $KeyVaultName --resource-group $ResourceGroup --query "properties.enableRbacAuthorization" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if ($kvRbacEnabled -eq $true) {
    Write-Host "[INFO] Key Vault usa RBAC" -ForegroundColor Yellow
    Write-Host ""
    
    $subscriptionId = az account show --query id -o tsv
    $kvResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$KeyVaultName"
    $requiredRole = "Key Vault Secrets Officer"
    
    # Verificar se já tem a permissão
    Write-Host "[INFO] Verificando permissoes atuais..." -ForegroundColor Yellow
    $ErrorActionPreference = "Continue"
    $userRoles = az role assignment list --scope $kvResourceId --assignee $UserObjectId --query "[].roleDefinitionName" -o tsv 2>$null
    $ErrorActionPreference = "Stop"
    
    $hasRole = $userRoles | Where-Object { $_ -like "*Key Vault Secrets Officer*" -or $_ -like "*Owner*" -or $_ -like "*Contributor*" }
    
    if ($hasRole) {
        Write-Host "[OK] Voce ja tem permissao suficiente!" -ForegroundColor Green
        $userRoles | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
    } else {
        Write-Host "[INFO] Tentando conceder permissao '$requiredRole'..." -ForegroundColor Cyan
        
        # Tentar conceder a permissão
        $ErrorActionPreference = "Continue"
        $assignOutput = az role assignment create `
            --assignee-object-id $UserObjectId `
            --assignee-principal-type User `
            --role $requiredRole `
            --scope $kvResourceId 2>&1
        $assignExitCode = $LASTEXITCODE
        $ErrorActionPreference = "Stop"
        
        if ($assignExitCode -eq 0) {
            Write-Host "[OK] Permissao '$requiredRole' concedida com sucesso!" -ForegroundColor Green
            Write-Host "[INFO] Aguardando 10s para propagacao..." -ForegroundColor Yellow
            Start-Sleep -Seconds 10
        } else {
            Write-Host "[ERRO] Falha ao conceder permissao automaticamente" -ForegroundColor Red
            if ($assignOutput) {
                $errorMsg = ($assignOutput | Out-String).Trim()
                $errorLines = $errorMsg -split "`n" | Where-Object { $_ -match "Authorization|permission|denied|forbidden" -or $_ -match "ERROR" }
                if ($errorLines.Count -gt 0) {
                    Write-Host "  Erro: $($errorLines[0])" -ForegroundColor Red
                }
            }
            Write-Host ""
            Write-Host "[INFO] Voce precisa de 'User Access Administrator' ou 'Owner' para conceder permissoes" -ForegroundColor Yellow
            Write-Host "[INFO] Ou peca a um administrador para executar o comando abaixo:" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  az role assignment create `" -ForegroundColor Gray
            Write-Host "    --assignee-object-id $UserObjectId `" -ForegroundColor Gray
            Write-Host "    --assignee-principal-type User `" -ForegroundColor Gray
            Write-Host "    --role '$requiredRole' `" -ForegroundColor Gray
            Write-Host "    --scope '$kvResourceId'" -ForegroundColor Gray
            Write-Host ""
            Write-Host "[INFO] Ou execute como administrador:" -ForegroundColor Cyan
            Write-Host "  az role assignment create --assignee-object-id $UserObjectId --assignee-principal-type User --role '$requiredRole' --scope '$kvResourceId'" -ForegroundColor Gray
        }
    }
} else {
    Write-Host "[INFO] Key Vault usa Access Policies (metodo antigo)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "[INFO] Concedendo permissao via Access Policy..." -ForegroundColor Cyan
    
    $ErrorActionPreference = "Continue"
    az keyvault set-policy `
        --name $KeyVaultName `
        --object-id $UserObjectId `
        --secret-permissions get list set delete 2>&1 | Out-Null
    $policyExitCode = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    
    if ($policyExitCode -eq 0) {
        Write-Host "[OK] Permissao concedida via Access Policy!" -ForegroundColor Green
    } else {
        Write-Host "[ERRO] Falha ao conceder permissao via Access Policy" -ForegroundColor Red
        Write-Host "[INFO] Execute manualmente:" -ForegroundColor Cyan
        Write-Host "  az keyvault set-policy --name $KeyVaultName --object-id $UserObjectId --secret-permissions get list set delete" -ForegroundColor Gray
    }
}

Write-Host ""
