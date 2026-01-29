# Script de diagnóstico completo para verificar resolução de secrets do Key Vault
# Verifica todos os pré-requisitos do checklist rápido
#
# Uso: .\infra\check_keyvault_secret_resolution.ps1 [-SecretName "openai-api-key"]

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$KeyVaultName = $null,
    [string]$SecretName = "openai-api-key"
)

$ErrorActionPreference = "Stop"

Write-Host "=== CHECKLIST: Resolução de Secret do Key Vault ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "[INFO] Verificando secret: $SecretName" -ForegroundColor Yellow
Write-Host ""

# Carregar deploy_state.json se não fornecido
if (-not $ResourceGroup -or -not $ApiAppName -or -not $KeyVaultName) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoRoot = Split-Path -Parent $scriptDir
    $stateFile = Join-Path $repoRoot ".azure\deploy_state.json"
    
    if (-not (Test-Path $stateFile)) {
        Write-Host "[ERRO] Arquivo $stateFile não encontrado. Forneça -ResourceGroup, -ApiAppName e -KeyVaultName." -ForegroundColor Red
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
Write-Host "[INFO] Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host "[INFO] Key Vault: $KeyVaultName" -ForegroundColor Yellow
Write-Host ""

$allChecksPassed = $true

# ==========================================
# CHECK 1: Secret existe no Key Vault?
# ==========================================
Write-Host "=== [1/4] Secret existe no Key Vault? ===" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
$secretExists = az keyvault secret show --vault-name $KeyVaultName --name $SecretName --query "name" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if ($secretExists) {
    Write-Host "[OK] Secret '$SecretName' existe no Key Vault" -ForegroundColor Green
    
    # Tentar obter versão atual
    $ErrorActionPreference = "Continue"
    $secretVersion = az keyvault secret show --vault-name $KeyVaultName --name $SecretName --query "id" -o tsv 2>$null
    $ErrorActionPreference = "Stop"
    
    if ($secretVersion) {
        Write-Host "  URI: $secretVersion" -ForegroundColor Gray
    }
} else {
    Write-Host "[ERRO] Secret '$SecretName' NÃO existe no Key Vault!" -ForegroundColor Red
    Write-Host "  [AÇÃO] Execute: az keyvault secret set --vault-name $KeyVaultName --name $SecretName --value '<VALOR>'" -ForegroundColor Yellow
    $allChecksPassed = $false
}
Write-Host ""

# ==========================================
# CHECK 2: Managed Identity habilitada?
# ==========================================
Write-Host "=== [2/4] Managed Identity habilitada? ===" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
$identity = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "identity" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = "Stop"

if ($identity -and $identity.type -eq "SystemAssigned") {
    $principalId = $identity.principalId
    Write-Host "[OK] Managed Identity habilitada (SystemAssigned)" -ForegroundColor Green
    Write-Host "  Principal ID: $principalId" -ForegroundColor Gray
} else {
    Write-Host "[ERRO] Managed Identity NÃO está habilitada!" -ForegroundColor Red
    Write-Host "  [AÇÃO] Execute: az containerapp identity assign --name $ApiAppName --resource-group $ResourceGroup --system-assigned" -ForegroundColor Yellow
    $allChecksPassed = $false
    $principalId = $null
}
Write-Host ""

# ==========================================
# CHECK 3: Permissão no Key Vault?
# ==========================================
Write-Host "=== [3/4] Permissão no Key Vault? ===" -ForegroundColor Cyan

if (-not $principalId) {
    Write-Host "[AVISO] Não é possível verificar permissões (Managed Identity não habilitada)" -ForegroundColor Yellow
    $allChecksPassed = $false
} else {
    # Verificar se Key Vault usa RBAC ou Access Policies
    $ErrorActionPreference = "Continue"
    $kvRbacEnabled = az keyvault show --name $KeyVaultName --resource-group $ResourceGroup --query "properties.enableRbacAuthorization" -o tsv 2>$null
    $ErrorActionPreference = "Stop"
    
    if ($kvRbacEnabled -eq $true) {
        Write-Host "[INFO] Key Vault usa RBAC" -ForegroundColor Yellow
        
        $subscriptionId = az account show --query id -o tsv
        $kvResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$KeyVaultName"
        
        $ErrorActionPreference = "Continue"
        $rbacRoles = az role assignment list --scope $kvResourceId --assignee $principalId --query "[].roleDefinitionName" -o tsv 2>$null
        $ErrorActionPreference = "Stop"
        
        if ($rbacRoles) {
            Write-Host "[OK] Permissões RBAC encontradas:" -ForegroundColor Green
            $rbacRoles | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
            
            $hasSecretsUser = $rbacRoles | Where-Object { $_ -like "*Key Vault Secrets User*" -or $_ -like "*Secrets User*" }
            if ($hasSecretsUser) {
                Write-Host "[OK] Role 'Key Vault Secrets User' encontrada" -ForegroundColor Green
            } else {
                Write-Host "[ERRO] Role 'Key Vault Secrets User' NÃO encontrada!" -ForegroundColor Red
                Write-Host "  [AÇÃO] Execute: az role assignment create --assignee $principalId --role 'Key Vault Secrets User' --scope $kvResourceId" -ForegroundColor Yellow
                $allChecksPassed = $false
            }
        } else {
            Write-Host "[ERRO] Nenhuma permissão RBAC encontrada!" -ForegroundColor Red
            Write-Host "  [AÇÃO] Execute: az role assignment create --assignee $principalId --role 'Key Vault Secrets User' --scope $kvResourceId" -ForegroundColor Yellow
            $allChecksPassed = $false
        }
    } else {
        Write-Host "[INFO] Key Vault usa Access Policies (método antigo)" -ForegroundColor Yellow
        
        $ErrorActionPreference = "Continue"
        $policies = az keyvault show --name $KeyVaultName --resource-group $ResourceGroup --query "properties.accessPolicies" -o json 2>$null | ConvertFrom-Json
        $ErrorActionPreference = "Stop"
        
        $hasAccess = $false
        if ($policies) {
            foreach ($policy in $policies) {
                if ($policy.objectId -eq $principalId) {
                    $permissions = $policy.permissions.secrets
                    if ($permissions -and ($permissions -contains "Get" -or $permissions -contains "*")) {
                        Write-Host "[OK] Access Policy encontrada com permissão 'Get'" -ForegroundColor Green
                        $hasAccess = $true
                        break
                    }
                }
            }
        }
        
        if (-not $hasAccess) {
            Write-Host "[ERRO] Access Policy com permissão 'Get' NÃO encontrada!" -ForegroundColor Red
            Write-Host "  [AÇÃO] Execute: az keyvault set-policy --name $KeyVaultName --object-id $principalId --secret-permissions get list" -ForegroundColor Yellow
            $allChecksPassed = $false
        }
    }
}
Write-Host ""

# ==========================================
# CHECK 4: Key Vault acessível (firewall/private endpoint)?
# ==========================================
Write-Host "=== [4/4] Key Vault acessível (firewall/private endpoint)? ===" -ForegroundColor Cyan

$ErrorActionPreference = "Continue"
$kvProperties = az keyvault show --name $KeyVaultName --resource-group $ResourceGroup --query "{networkAcls:properties.networkAcls,publicNetworkAccess:properties.publicNetworkAccess}" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = "Stop"

if ($kvProperties) {
    $networkAcls = $kvProperties.networkAcls
    $publicNetworkAccess = $kvProperties.publicNetworkAccess
    
    if ($networkAcls) {
        $defaultAction = $networkAcls.defaultAction
        $ipRules = $networkAcls.ipRules
        $virtualNetworkRules = $networkAcls.virtualNetworkRules
        
        Write-Host "[INFO] Configuração de rede do Key Vault:" -ForegroundColor Yellow
        Write-Host "  Default Action: $defaultAction" -ForegroundColor Gray
        
        if ($defaultAction -eq "Deny") {
            Write-Host "[AVISO] Firewall está configurado para DENY por padrão" -ForegroundColor Yellow
            
            if ($ipRules -and $ipRules.Count -gt 0) {
                Write-Host "  IP Rules: $($ipRules.Count) regra(s)" -ForegroundColor Gray
            }
            
            if ($virtualNetworkRules -and $virtualNetworkRules.Count -gt 0) {
                Write-Host "  Virtual Network Rules: $($virtualNetworkRules.Count) regra(s)" -ForegroundColor Gray
            }
            
            # Verificar se "Allow Azure Services" está habilitado
            if ($networkAcls.bypass -and $networkAcls.bypass -contains "AzureServices") {
                Write-Host "[OK] 'Allow Azure Services' está habilitado (bypass: AzureServices)" -ForegroundColor Green
                Write-Host "  Container Apps deve conseguir acessar via Managed Identity" -ForegroundColor Gray
            } else {
                Write-Host "[AVISO] 'Allow Azure Services' pode não estar habilitado" -ForegroundColor Yellow
                Write-Host "  [AÇÃO] Verifique se o bypass inclui 'AzureServices' ou configure regra específica" -ForegroundColor Yellow
                Write-Host "  [AÇÃO] Execute: az keyvault update --name $KeyVaultName --bypass AzureServices" -ForegroundColor Yellow
            }
        } elseif ($defaultAction -eq "Allow") {
            Write-Host "[OK] Firewall permite acesso público (Default Action: Allow)" -ForegroundColor Green
        }
    } else {
        Write-Host "[OK] Nenhuma restrição de firewall configurada" -ForegroundColor Green
    }
    
    if ($publicNetworkAccess -eq "Disabled") {
        Write-Host "[AVISO] Public Network Access está DISABLED" -ForegroundColor Yellow
        Write-Host "  [AÇÃO] Verifique se Private Endpoint está configurado corretamente" -ForegroundColor Yellow
    }
} else {
    Write-Host "[AVISO] Não foi possível verificar configuração de rede" -ForegroundColor Yellow
}

Write-Host ""

# ==========================================
# CHECK EXTRA: Secret está configurado no Container App?
# ==========================================
Write-Host "=== [EXTRA] Secret está configurado no Container App? ===" -ForegroundColor Cyan

$ErrorActionPreference = "Continue"
$appSecrets = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.configuration.secrets" -o json 2>$null | ConvertFrom-Json
$appEnv = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].env" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = "Stop"

$secretFound = $false
$envVarFound = $false

if ($appSecrets) {
    foreach ($secret in $appSecrets) {
        if ($secret.name -eq $SecretName) {
            $secretFound = $true
            Write-Host "[OK] Secret '$SecretName' está definido no Container App" -ForegroundColor Green
            if ($secret.keyVaultUrl) {
                Write-Host "  Key Vault URL: $($secret.keyVaultUrl)" -ForegroundColor Gray
            }
            break
        }
    }
}

if (-not $secretFound) {
    Write-Host "[ERRO] Secret '$SecretName' NÃO está definido no Container App!" -ForegroundColor Red
    Write-Host "  [AÇÃO] Execute: az containerapp update --name $ApiAppName --resource-group $ResourceGroup --set-secrets '$SecretName=keyvaultref:https://$KeyVaultName.vault.azure.net/secrets/$SecretName'" -ForegroundColor Yellow
    $allChecksPassed = $false
}

# Verificar se env var está usando secretRef
if ($appEnv) {
    foreach ($envVar in $appEnv) {
        if ($envVar.secretRef -eq $SecretName) {
            $envVarFound = $true
            Write-Host "[OK] Env var está usando secretRef: $($envVar.name) = secretref:$SecretName" -ForegroundColor Green
            break
        } elseif ($envVar.value -and $envVar.value -match '@Microsoft\.KeyVault') {
            Write-Host "[AVISO] Env var '$($envVar.name)' está usando sintaxe ERRADA: @Microsoft.KeyVault(...)" -ForegroundColor Yellow
            Write-Host "  [AÇÃO] Execute: .\infra\fix_keyvault_references.ps1 para corrigir" -ForegroundColor Yellow
        }
    }
}

if (-not $envVarFound) {
    Write-Host "[AVISO] Nenhuma env var encontrada usando secretRef: $SecretName" -ForegroundColor Yellow
    Write-Host "  [AÇÃO] Verifique se a env var está configurada corretamente" -ForegroundColor Yellow
}

Write-Host ""

# ==========================================
# RESUMO
# ==========================================
Write-Host "=== RESUMO ===" -ForegroundColor Cyan
Write-Host ""

if ($allChecksPassed) {
    Write-Host "[OK] Todos os checks passaram! O secret deve ser resolvido corretamente." -ForegroundColor Green
    Write-Host ""
    Write-Host "[INFO] Para testar, execute:" -ForegroundColor Yellow
    Write-Host "  az containerapp exec --name $ApiAppName --resource-group $ResourceGroup --command 'echo `$OPENAI_API_KEY | head -c 20'" -ForegroundColor Gray
    exit 0
} else {
    Write-Host "[ERRO] Alguns checks falharam. Corrija os problemas acima antes de continuar." -ForegroundColor Red
    Write-Host ""
    Write-Host "[INFO] Scripts úteis:" -ForegroundColor Yellow
    Write-Host "  - .\infra\fix_all_access.ps1 (corrige permissões e secrets)" -ForegroundColor Gray
    Write-Host "  - .\infra\fix_keyvault_references.ps1 (corrige sintaxe de referências)" -ForegroundColor Gray
    exit 1
}
