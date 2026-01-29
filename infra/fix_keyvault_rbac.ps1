# Script para configurar permissões RBAC no Key Vault

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$KeyVault = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Configurar RBAC no Key Vault ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se não fornecido
if (-not $ResourceGroup -or -not $ApiAppName -or -not $KeyVault) {
    $stateFile = ".azure/deploy_state.json"
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
    if (-not $KeyVault) {
        $KeyVault = $state.keyVaultName
    }
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host "[INFO] Key Vault: $KeyVault" -ForegroundColor Yellow
Write-Host ""

# 1. Obter Principal ID da Managed Identity
Write-Host "=== 1. Obtendo Managed Identity ===" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
$principalId = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "identity.principalId" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if (-not $principalId) {
    Write-Host "[ERRO] Managed Identity não está habilitada!" -ForegroundColor Red
    Write-Host "[INFO] Execute primeiro: .\infra\fix_managed_identity.ps1" -ForegroundColor Yellow
    exit 1
}

Write-Host "[OK] Principal ID: $principalId" -ForegroundColor Green
Write-Host ""

# 2. Obter Resource ID do Key Vault
Write-Host "=== 2. Obtendo Resource ID do Key Vault ===" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
$subscriptionId = az account show --query id -o tsv
$kvResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$KeyVault"
Write-Host "[OK] Key Vault Resource ID: $kvResourceId" -ForegroundColor Green
Write-Host ""

# 3. Verificar se já tem permissão
Write-Host "=== 3. Verificando Permissões Existentes ===" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
$existingRole = az role assignment list `
    --scope $kvResourceId `
    --assignee $principalId `
    --query "[].{role:roleDefinitionName,scope:scope}" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = "Stop"

if ($existingRole) {
    Write-Host "[INFO] Permissões existentes encontradas:" -ForegroundColor Yellow
    foreach ($role in $existingRole) {
        Write-Host "  - $($role.role)" -ForegroundColor Gray
    }
    
    $hasKeyVaultSecretsUser = $existingRole | Where-Object { $_.role -like "*Key Vault Secrets User*" -or $_.role -like "*Secrets User*" }
    
    if ($hasKeyVaultSecretsUser) {
        Write-Host "[OK] Permissão 'Key Vault Secrets User' já configurada!" -ForegroundColor Green
        Write-Host ""
        Write-Host "=== Resumo ===" -ForegroundColor Cyan
        Write-Host "[OK] Tudo configurado corretamente!" -ForegroundColor Green
        exit 0
    }
}
Write-Host ""

# 4. Conceder permissão "Key Vault Secrets User"
Write-Host "=== 4. Concedendo Permissão 'Key Vault Secrets User' ===" -ForegroundColor Cyan
Write-Host "[INFO] Esta role permite ler secrets do Key Vault..." -ForegroundColor Yellow

$ErrorActionPreference = "Continue"
$roleOutput = az role assignment create `
    --scope $kvResourceId `
    --assignee $principalId `
    --role "Key Vault Secrets User" `
    --assignee-object-id $principalId `
    --assignee-principal-type ServicePrincipal 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Permissão concedida com sucesso!" -ForegroundColor Green
} else {
    if ($roleOutput -match "already exists") {
        Write-Host "[OK] Permissão já existe" -ForegroundColor Green
    } else {
        Write-Host "[ERRO] Falha ao conceder permissão" -ForegroundColor Red
        Write-Host "Erro: $roleOutput" -ForegroundColor Red
        
        # Tentar método alternativo sem --assignee-object-id
        Write-Host "[INFO] Tentando método alternativo..." -ForegroundColor Yellow
        $roleOutput2 = az role assignment create `
            --scope $kvResourceId `
            --assignee $principalId `
            --role "Key Vault Secrets User" 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Permissão concedida (método alternativo)!" -ForegroundColor Green
        } else {
            Write-Host "[ERRO] Falha no método alternativo também" -ForegroundColor Red
            Write-Host "Erro: $roleOutput2" -ForegroundColor Red
            exit 1
        }
    }
}
$ErrorActionPreference = "Stop"
Write-Host ""

# 5. Verificar permissões finais
Write-Host "=== 5. Verificando Permissões Finais ===" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
Start-Sleep -Seconds 5  # Aguardar propagação
$finalRoles = az role assignment list `
    --scope $kvResourceId `
    --assignee $principalId `
    --query "[].roleDefinitionName" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if ($finalRoles) {
    Write-Host "[OK] Permissões configuradas:" -ForegroundColor Green
    $finalRoles | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
} else {
    Write-Host "[AVISO] Aguarde alguns segundos e verifique novamente" -ForegroundColor Yellow
}
Write-Host ""

# 6. Resumo
Write-Host "=== Resumo ===" -ForegroundColor Cyan
Write-Host "[OK] Managed Identity: $principalId" -ForegroundColor Green
Write-Host "[OK] Key Vault: $KeyVault" -ForegroundColor Green
Write-Host "[OK] Permissão: Key Vault Secrets User" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] Próximos passos:" -ForegroundColor Cyan
Write-Host "  1. Aguarde 1-2 minutos para propagação completa" -ForegroundColor Gray
Write-Host "  2. Teste se os secrets estão sendo resolvidos:" -ForegroundColor Gray
Write-Host "     .\infra\verify_openai_key.ps1" -ForegroundColor Gray
Write-Host "  3. Se necessário, reinicie o Container App para aplicar mudanças" -ForegroundColor Gray
Write-Host ""
