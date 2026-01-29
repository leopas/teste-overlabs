# Script consolidado de auditoria completa para garantir acesso aos recursos Azure
# Verifica: Key Vault, Storage Account, Managed Identity, variáveis de ambiente, etc.

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$KeyVaultName = $null,
    [string]$Environment = $null,
    [string]$EnvFile = ".env"
)

$ErrorActionPreference = "Stop"

Write-Host "=== AUDITORIA COMPLETA: Acesso aos Recursos Azure ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se não fornecido
if (-not $ResourceGroup -or -not $ApiAppName -or -not $KeyVaultName -or -not $Environment) {
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
    if (-not $KeyVaultName) {
        $KeyVaultName = $state.keyVaultName
    }
    if (-not $Environment) {
        $Environment = $state.environmentName
    }
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host "[INFO] Key Vault: $KeyVaultName" -ForegroundColor Yellow
Write-Host "[INFO] Environment: $Environment" -ForegroundColor Yellow
Write-Host ""

$allIssues = @()
$allWarnings = @()

# ==========================================
# 1. MANAGED IDENTITY
# ==========================================
Write-Host "=== 1. MANAGED IDENTITY ===" -ForegroundColor Cyan
$identity = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "identity" -o json | ConvertFrom-Json

if ($identity -and $identity.type -eq "SystemAssigned") {
    $principalId = $identity.principalId
    Write-Host "[OK] Managed Identity habilitada (SystemAssigned)" -ForegroundColor Green
    Write-Host "  Principal ID: $principalId" -ForegroundColor Gray
} else {
    Write-Host "[ERRO] Managed Identity NÃO está habilitada!" -ForegroundColor Red
    $allIssues += "Managed Identity não habilitada"
    $principalId = $null
}
Write-Host ""

# ==========================================
# 2. KEY VAULT ACCESS
# ==========================================
Write-Host "=== 2. KEY VAULT ACCESS ===" -ForegroundColor Cyan

if ($principalId) {
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
            if (-not $hasSecretsUser) {
                Write-Host "[ERRO] Role 'Key Vault Secrets User' não encontrada!" -ForegroundColor Red
                $allIssues += "Falta permissão 'Key Vault Secrets User' no Key Vault"
            }
        } else {
            Write-Host "[ERRO] Nenhuma permissão RBAC encontrada!" -ForegroundColor Red
            $allIssues += "Falta permissão RBAC no Key Vault"
        }
    } else {
        Write-Host "[INFO] Key Vault usa Access Policies (método antigo)" -ForegroundColor Yellow
        
        $ErrorActionPreference = "Continue"
        $kvPermissions = az keyvault show --name $KeyVaultName --resource-group $ResourceGroup --query "properties.accessPolicies[?objectId=='$principalId'].permissions" -o json 2>$null | ConvertFrom-Json
        $ErrorActionPreference = "Stop"
        
        if ($kvPermissions) {
            Write-Host "[OK] Permissões encontradas:" -ForegroundColor Green
            if ($kvPermissions.secrets) {
                Write-Host "  Secrets: $($kvPermissions.secrets -join ', ')" -ForegroundColor Gray
            }
        } else {
            Write-Host "[ERRO] Nenhuma permissão encontrada!" -ForegroundColor Red
            $allIssues += "Falta permissão no Key Vault (Access Policies)"
        }
    }
    
    # Verificar variáveis de ambiente que usam Key Vault
    Write-Host ""
    Write-Host "[INFO] Verificando variáveis de ambiente com Key Vault references..." -ForegroundColor Yellow
    $appConfig = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].env" -o json | ConvertFrom-Json
    
    $kvRefs = @()
    foreach ($env in $appConfig) {
        if ($env.value -match '@Microsoft\.KeyVault') {
            $kvRefs += $env.name
        }
    }
    
    if ($kvRefs.Count -gt 0) {
        Write-Host "[OK] $($kvRefs.Count) variável(is) usando Key Vault references:" -ForegroundColor Green
        $kvRefs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
        
        # Verificar se os secrets existem no Key Vault
        foreach ($varName in $kvRefs) {
            $envVar = $appConfig | Where-Object { $_.name -eq $varName }
            if ($envVar.value -match 'secrets/([^/]+)') {
                $secretName = $matches[1]
                $ErrorActionPreference = "Continue"
                $secretExists = az keyvault secret show --vault-name $KeyVaultName --name $secretName --query "name" -o tsv 2>$null
                $ErrorActionPreference = "Stop"
                
                if (-not $secretExists) {
                    Write-Host "  [ERRO] Secret '$secretName' não existe no Key Vault!" -ForegroundColor Red
                    $allIssues += "Secret '$secretName' não existe no Key Vault (referenciado por $varName)"
                }
            }
        }
    } else {
        Write-Host "[AVISO] Nenhuma variável usando Key Vault references encontrada" -ForegroundColor Yellow
    }
} else {
    Write-Host "[AVISO] Não é possível verificar Key Vault (Managed Identity não habilitada)" -ForegroundColor Yellow
    $allWarnings += "Key Vault não verificado (sem Managed Identity)"
}
Write-Host ""

# ==========================================
# 3. STORAGE ACCOUNT ACCESS
# ==========================================
Write-Host "=== 3. STORAGE ACCOUNT ACCESS ===" -ForegroundColor Cyan

$ErrorActionPreference = "Continue"
$volumeInfo = az containerapp env storage show `
    --name $Environment `
    --resource-group $ResourceGroup `
    --storage-name documents-storage `
    --query "{accountName:properties.azureFile.accountName,shareName:properties.azureFile.shareName}" `
    -o json 2>$null
$ErrorActionPreference = "Stop"

if ($volumeInfo) {
    $volumeObj = $volumeInfo | ConvertFrom-Json
    $storageAccount = $volumeObj.accountName
    Write-Host "[OK] Volume 'documents-storage' encontrado" -ForegroundColor Green
    Write-Host "  Storage Account: $storageAccount" -ForegroundColor Gray
    Write-Host "  File Share: $($volumeObj.shareName)" -ForegroundColor Gray
    
    if ($principalId) {
        $storageAccountId = az storage account show --name $storageAccount --resource-group $ResourceGroup --query id -o tsv
        $requiredRole = "Storage File Data SMB Share Contributor"
        
        $ErrorActionPreference = "Continue"
        $roleAssignments = az role assignment list `
            --assignee $principalId `
            --scope $storageAccountId `
            --query "[?roleDefinitionName=='$requiredRole']" -o json 2>$null
        $ErrorActionPreference = "Stop"
        
        if ($roleAssignments -and ($roleAssignments | ConvertFrom-Json).Count -gt 0) {
            Write-Host "[OK] Container App tem permissão '$requiredRole' no Storage Account" -ForegroundColor Green
        } else {
            Write-Host "[ERRO] Container App NÃO tem permissão '$requiredRole' no Storage Account!" -ForegroundColor Red
            $allIssues += "Falta permissão '$requiredRole' no Storage Account"
        }
    } else {
        Write-Host "[AVISO] Não é possível verificar permissões (Managed Identity não habilitada)" -ForegroundColor Yellow
        $allWarnings += "Storage permissions não verificadas (sem Managed Identity)"
    }
    
    # Verificar se o volume está montado no Container App
    $appConfig = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template" -o json | ConvertFrom-Json
    
    $hasVolumeMount = $false
    if ($appConfig.volumes) {
        foreach ($vol in $appConfig.volumes) {
            if ($vol.name -eq "documents-storage") {
                $hasVolumeMount = $true
                break
            }
        }
    }
    
    if ($hasVolumeMount) {
        Write-Host "[OK] Volume está definido no Container App" -ForegroundColor Green
    } else {
        Write-Host "[ERRO] Volume NÃO está definido no Container App!" -ForegroundColor Red
        $allIssues += "Volume 'documents-storage' não está montado no Container App"
    }
    
    # Verificar volume mount no container
    $containerConfig = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0]" -o json | ConvertFrom-Json
    $hasContainerMount = $false
    if ($containerConfig.volumeMounts) {
        foreach ($vm in $containerConfig.volumeMounts) {
            if ($vm.volumeName -eq "documents-storage") {
                $hasContainerMount = $true
                Write-Host "[OK] Volume mount está configurado no container" -ForegroundColor Green
                Write-Host "  Mount Path: $($vm.mountPath)" -ForegroundColor Gray
                break
            }
        }
    }
    
    if (-not $hasContainerMount) {
        Write-Host "[ERRO] Volume mount NÃO está configurado no container!" -ForegroundColor Red
        $allIssues += "Volume mount não configurado no container"
    }
} else {
    Write-Host "[AVISO] Volume 'documents-storage' não encontrado no Environment" -ForegroundColor Yellow
    $allWarnings += "Volume 'documents-storage' não encontrado"
}
Write-Host ""

# ==========================================
# 4. VARIÁVEIS DE AMBIENTE
# ==========================================
Write-Host "=== 4. VARIÁVEIS DE AMBIENTE ===" -ForegroundColor Cyan

if (Test-Path $EnvFile) {
    Write-Host "[INFO] Comparando .env com Container App..." -ForegroundColor Yellow
    
    # Carregar variáveis esperadas do .env
    $expectedSecrets = @{}
    $expectedNonSecrets = @{}
    
    $denylist = @(
        "PORT", "ENV", "LOG_LEVEL", "HOST",
        "QDRANT_URL", "REDIS_URL", "DOCS_ROOT",
        "MYSQL_PORT", "MYSQL_HOST", "MYSQL_DATABASE", "MYSQL_SSL_CA",
        "OTEL_ENABLED", "USE_OPENAI_EMBEDDINGS",
        "AUDIT_LOG_ENABLED", "AUDIT_LOG_INCLUDE_TEXT", "AUDIT_LOG_RAW_MODE", "AUDIT_LOG_REDACT", "AUDIT_LOG_RAW_MAX_CHARS",
        "ABUSE_CLASSIFIER_ENABLED", "ABUSE_RISK_THRESHOLD",
        "PROMPT_FIREWALL_ENABLED", "PROMPT_FIREWALL_RULES_PATH", "PROMPT_FIREWALL_MAX_RULES", "PROMPT_FIREWALL_RELOAD_CHECK_SECONDS",
        "PIPELINE_LOG_ENABLED", "PIPELINE_LOG_INCLUDE_TEXT",
        "TRACE_SINK", "TRACE_SINK_QUEUE_SIZE",
        "AUDIT_ENC_AAD_MODE",
        "RATE_LIMIT_PER_MINUTE", "CACHE_TTL_SECONDS",
        "FIREWALL_LOG_SAMPLE_RATE",
        "OPENAI_MODEL", "OPENAI_MODEL_ENRICHMENT", "OPENAI_EMBEDDINGS_MODEL",
        "OTEL_EXPORTER_OTLP_ENDPOINT",
        "DOCS_HOST_PATH",
        "API_PORT", "QDRANT_PORT", "REDIS_PORT"
    )
    
    $secretKeywords = @("KEY", "SECRET", "TOKEN", "PASSWORD", "PASS", "CONNECTION", "API")
    
    Get-Content $EnvFile | ForEach-Object {
        if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.+)$' -and $_ -notmatch '^\s*#') {
            $key = $matches[1]
            $value = $matches[2].Trim('"').Trim("'")
            
            if ($value -match '^(.+?)\s*#') {
                $value = $matches[1].Trim()
            }
            
            if ($value) {
                $isInDenylist = $denylist -contains $key
                $keyUpper = $key.ToUpper()
                $hasSecretKeyword = $false
                foreach ($keyword in $secretKeywords) {
                    if ($keyUpper -like "*$keyword*") {
                        $hasSecretKeyword = $true
                        break
                    }
                }
                
                $isSecret = -not $isInDenylist -and $hasSecretKeyword
                
                if ($isSecret) {
                    $expectedSecrets[$key] = $value
                } else {
                    $expectedNonSecrets[$key] = $value
                }
            }
        }
    }
    
    # Obter variáveis configuradas
    $appConfig = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].env" -o json | ConvertFrom-Json
    
    $configuredSecrets = @{}
    $configuredNonSecrets = @{}
    
    foreach ($env in $appConfig) {
        if ($env.value -match '@Microsoft\.KeyVault') {
            $configuredSecrets[$env.name] = $env.value
        } else {
            $configuredNonSecrets[$env.name] = $env.value
        }
    }
    
    # Comparar
    $missingSecrets = @()
    $missingNonSecrets = @()
    
    foreach ($key in $expectedSecrets.Keys) {
        if (-not $configuredSecrets.ContainsKey($key)) {
            $missingSecrets += $key
        }
    }
    
    foreach ($key in $expectedNonSecrets.Keys) {
        if (-not $configuredNonSecrets.ContainsKey($key) -and -not $configuredSecrets.ContainsKey($key)) {
            $missingNonSecrets += $key
        }
    }
    
    if ($missingSecrets.Count -gt 0) {
        Write-Host "[ERRO] Secrets faltando ($($missingSecrets.Count)):" -ForegroundColor Red
        $missingSecrets | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
        $allIssues += "Secrets faltando: $($missingSecrets -join ', ')"
    }
    
    if ($missingNonSecrets.Count -gt 0) {
        Write-Host "[AVISO] Non-secrets faltando ($($missingNonSecrets.Count)):" -ForegroundColor Yellow
        $missingNonSecrets | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
        $allWarnings += "Non-secrets faltando: $($missingNonSecrets -join ', ')"
    }
    
    if ($missingSecrets.Count -eq 0 -and $missingNonSecrets.Count -eq 0) {
        Write-Host "[OK] Todas as variáveis esperadas estão configuradas" -ForegroundColor Green
    }
} else {
    Write-Host "[AVISO] Arquivo .env não encontrado (pode ser esperado se secrets estão no Key Vault)" -ForegroundColor Yellow
}
Write-Host ""

# ==========================================
# RESUMO FINAL
# ==========================================
Write-Host "=== RESUMO DA AUDITORIA ===" -ForegroundColor Cyan
Write-Host ""

$totalIssues = $allIssues.Count
$totalWarnings = $allWarnings.Count

if ($totalIssues -eq 0 -and $totalWarnings -eq 0) {
    Write-Host "[OK] Tudo configurado corretamente!" -ForegroundColor Green
} else {
    if ($totalIssues -gt 0) {
        Write-Host "[ERRO] Problemas encontrados ($totalIssues):" -ForegroundColor Red
        foreach ($issue in $allIssues) {
            Write-Host "  - $issue" -ForegroundColor Red
        }
        Write-Host ""
    }
    
    if ($totalWarnings -gt 0) {
        Write-Host "[AVISO] Avisos ($totalWarnings):" -ForegroundColor Yellow
        foreach ($warning in $allWarnings) {
            Write-Host "  - $warning" -ForegroundColor Yellow
        }
        Write-Host ""
    }
    
    Write-Host "[INFO] Scripts para corrigir problemas:" -ForegroundColor Cyan
    
    if ($allIssues -contains "Managed Identity não habilitada") {
        Write-Host "  - Habilitar Managed Identity: az containerapp identity assign --name $ApiAppName --resource-group $ResourceGroup --system-assigned" -ForegroundColor Gray
    }
    
    if ($allIssues -match "Key Vault") {
        Write-Host "  - Verificar Key Vault: .\infra\fix_keyvault_user_permissions.ps1" -ForegroundColor Gray
        Write-Host "  - Conceder permissoes: .\infra\grant_keyvault_permissions.ps1" -ForegroundColor Gray
    }
    
    if ($allIssues -match "Storage") {
        Write-Host "  - Verificar Storage: .\infra\fix_all_access.ps1 (ja verifica Storage)" -ForegroundColor Gray
    }
    
    if ($allIssues -match "Volume") {
        Write-Host "  - Montar volume: .\infra\mount_docs_volume.ps1" -ForegroundColor Gray
        Write-Host "  - Ou corrigir tudo: .\infra\fix_all_access.ps1" -ForegroundColor Gray
    }
    
    if ($allIssues -match "Secrets faltando") {
        Write-Host "  - Corrigir tudo: .\infra\fix_all_access.ps1" -ForegroundColor Gray
        Write-Host "  - Ou re-executar bootstrap: .\infra\bootstrap_api.ps1 ..." -ForegroundColor Gray
    }
}

Write-Host ""
