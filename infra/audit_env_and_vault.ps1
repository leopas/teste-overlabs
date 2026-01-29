# Script para auditar variáveis de ambiente e Key Vault em produção
# Compara o que está configurado vs o que deveria estar

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$KeyVault = $null,
    [string]$EnvFile = ".env"
)

$ErrorActionPreference = "Stop"

Write-Host "=== AUDITORIA: Variáveis de Ambiente e Key Vault ===" -ForegroundColor Cyan
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
Write-Host "[INFO] Env File: $EnvFile" -ForegroundColor Yellow
Write-Host ""

# 1. Carregar variáveis esperadas do .env
Write-Host "=== 1. CARREGANDO VARIÁVEIS ESPERADAS DO .ENV ===" -ForegroundColor Cyan
if (-not (Test-Path $EnvFile)) {
    Write-Host "[ERRO] Arquivo $EnvFile não encontrado!" -ForegroundColor Red
    exit 1
}

$expectedSecrets = @{}
$expectedNonSecrets = @{}

# Denylist: variáveis que NÃO são secrets mesmo contendo palavras-chave
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

# Palavras-chave que indicam secrets
$secretKeywords = @("KEY", "SECRET", "TOKEN", "PASSWORD", "PASS", "CONNECTION", "API")

Get-Content $EnvFile | ForEach-Object {
    if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.+)$' -and $_ -notmatch '^\s*#') {
        $key = $matches[1]
        $value = $matches[2].Trim('"').Trim("'")
        
        # Remover comentários inline
        if ($value -match '^(.+?)\s*#') {
            $value = $matches[1].Trim()
        }
        
        if ($value) {
            # Classificar como secret
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

Write-Host "[OK] Variáveis esperadas carregadas:" -ForegroundColor Green
Write-Host "  - Secrets: $($expectedSecrets.Count)" -ForegroundColor Gray
Write-Host "  - Non-secrets: $($expectedNonSecrets.Count)" -ForegroundColor Gray
Write-Host ""

# 2. Obter variáveis configuradas no Container App
Write-Host "=== 2. VARIÁVEIS CONFIGURADAS NO CONTAINER APP ===" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
$containerEnv = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].env" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = "Stop"

$configuredSecrets = @{}
$configuredNonSecrets = @{}
$kvReferences = @{}

if ($containerEnv) {
    foreach ($env in $containerEnv) {
        $name = $env.name
        $value = $env.value
        
        if ($value -match '^@Microsoft\.KeyVault') {
            $configuredSecrets[$name] = $value
            $kvReferences[$name] = $value
        } else {
            $configuredNonSecrets[$name] = $value
        }
    }
}

Write-Host "[OK] Variáveis configuradas:" -ForegroundColor Green
Write-Host "  - Secrets (KV refs): $($configuredSecrets.Count)" -ForegroundColor Gray
Write-Host "  - Non-secrets: $($configuredNonSecrets.Count)" -ForegroundColor Gray
Write-Host ""

# 3. Comparar e identificar diferenças
Write-Host "=== 3. COMPARAÇÃO: ESPERADO vs CONFIGURADO ===" -ForegroundColor Cyan
Write-Host ""

$missingSecrets = @()
$missingNonSecrets = @()
$wrongTypeSecrets = @()  # Secrets que deveriam ser KV refs mas não são
$extraVars = @()  # Variáveis configuradas mas não esperadas

# Verificar secrets faltando ou com tipo errado
foreach ($key in $expectedSecrets.Keys) {
    if (-not $configuredSecrets.ContainsKey($key)) {
        if ($configuredNonSecrets.ContainsKey($key)) {
            $wrongTypeSecrets += $key
        } else {
            $missingSecrets += $key
        }
    }
}

# Verificar non-secrets faltando
foreach ($key in $expectedNonSecrets.Keys) {
    if (-not $configuredNonSecrets.ContainsKey($key) -and -not $configuredSecrets.ContainsKey($key)) {
        $missingNonSecrets += $key
    }
}

# Verificar variáveis extras (configuradas mas não esperadas)
foreach ($key in $configuredSecrets.Keys) {
    if (-not $expectedSecrets.ContainsKey($key) -and -not $expectedNonSecrets.ContainsKey($key)) {
        $extraVars += @{Name=$key; Type="Secret (KV ref)"; Value=$configuredSecrets[$key]}
    }
}
foreach ($key in $configuredNonSecrets.Keys) {
    if (-not $expectedSecrets.ContainsKey($key) -and -not $expectedNonSecrets.ContainsKey($key)) {
        $extraVars += @{Name=$key; Type="Non-secret"; Value=$configuredNonSecrets[$key]}
    }
}

# Exibir resultados
if ($missingSecrets.Count -gt 0) {
    Write-Host "[ERRO] Secrets faltando ($($missingSecrets.Count)):" -ForegroundColor Red
    foreach ($key in $missingSecrets) {
        Write-Host "  - $key" -ForegroundColor Gray
    }
    Write-Host ""
}

if ($wrongTypeSecrets.Count -gt 0) {
    Write-Host "[ERRO] Secrets configurados como non-secrets ($($wrongTypeSecrets.Count)):" -ForegroundColor Red
    foreach ($key in $wrongTypeSecrets) {
        Write-Host "  - $key (deveria ser Key Vault reference)" -ForegroundColor Gray
    }
    Write-Host ""
}

if ($missingNonSecrets.Count -gt 0) {
    Write-Host "[AVISO] Non-secrets faltando ($($missingNonSecrets.Count)):" -ForegroundColor Yellow
    foreach ($key in $missingNonSecrets) {
        Write-Host "  - $key" -ForegroundColor Gray
    }
    Write-Host ""
}

if ($extraVars.Count -gt 0) {
    Write-Host "[INFO] Variáveis extras (configuradas mas não esperadas) ($($extraVars.Count)):" -ForegroundColor Cyan
    foreach ($var in $extraVars) {
        Write-Host "  - $($var.Name) ($($var.Type))" -ForegroundColor Gray
    }
    Write-Host ""
}

# 4. Verificar Key Vault references
Write-Host "=== 4. VERIFICAÇÃO DE KEY VAULT REFERENCES ===" -ForegroundColor Cyan
Write-Host ""

$kvIssues = @()

foreach ($key in $configuredSecrets.Keys) {
    $ref = $configuredSecrets[$key]
    Write-Host "[INFO] Verificando: $key" -ForegroundColor Yellow
    
    # Extrair nome do secret do Key Vault reference
    if ($ref -match 'secrets/([^/]+)') {
        $secretName = $matches[1]
        Write-Host "  Secret name no KV: $secretName" -ForegroundColor Gray
        
        # Verificar se o secret existe no Key Vault
        $ErrorActionPreference = "Continue"
        $secretExists = az keyvault secret show --vault-name $KeyVault --name $secretName --query "name" -o tsv 2>$null
        $ErrorActionPreference = "Stop"
        
        if ($secretExists) {
            Write-Host "  [OK] Secret existe no Key Vault" -ForegroundColor Green
        } else {
            Write-Host "  [ERRO] Secret NÃO existe no Key Vault!" -ForegroundColor Red
            $kvIssues += @{Var=$key; Secret=$secretName; Issue="Secret não existe no KV"}
        }
    } else {
        Write-Host "  [ERRO] Formato de Key Vault reference inválido!" -ForegroundColor Red
        $kvIssues += @{Var=$key; Secret="N/A"; Issue="Formato inválido"}
    }
    Write-Host ""
}

# 5. Verificar Managed Identity e permissões
Write-Host "=== 5. VERIFICAÇÃO DE MANAGED IDENTITY ===" -ForegroundColor Cyan
Write-Host ""

$ErrorActionPreference = "Continue"
$miPrincipalId = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "identity.principalId" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if ($miPrincipalId) {
    Write-Host "[OK] Managed Identity habilitada" -ForegroundColor Green
    Write-Host "  Principal ID: $miPrincipalId" -ForegroundColor Gray
    
    # Verificar se Key Vault usa RBAC ou Access Policies
    $ErrorActionPreference = "Continue"
    $kvRbacEnabled = az keyvault show --name $KeyVault --resource-group $ResourceGroup --query "properties.enableRbacAuthorization" -o tsv 2>$null
    $ErrorActionPreference = "Stop"
    
    if ($kvRbacEnabled -eq $true) {
        # Key Vault usa RBAC
        Write-Host "[INFO] Key Vault usa RBAC. Verificando role assignments..." -ForegroundColor Yellow
        
        $subscriptionId = az account show --query id -o tsv
        $kvResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$KeyVault"
        
        $ErrorActionPreference = "Continue"
        $rbacRoles = az role assignment list --scope $kvResourceId --assignee $miPrincipalId --query "[].roleDefinitionName" -o tsv 2>$null
        $ErrorActionPreference = "Stop"
        
        if ($rbacRoles) {
            Write-Host "[OK] Permissões RBAC encontradas:" -ForegroundColor Green
            $rbacRoles | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
            
            $hasSecretsUser = $rbacRoles | Where-Object { $_ -like "*Key Vault Secrets User*" -or $_ -like "*Secrets User*" }
            if (-not $hasSecretsUser) {
                Write-Host "[AVISO] Role 'Key Vault Secrets User' não encontrada!" -ForegroundColor Yellow
                Write-Host "[INFO] Execute: .\infra\fix_keyvault_rbac.ps1" -ForegroundColor Cyan
            }
        } else {
            Write-Host "[ERRO] Nenhuma permissão RBAC encontrada!" -ForegroundColor Red
            Write-Host "[INFO] Execute: .\infra\fix_keyvault_rbac.ps1" -ForegroundColor Cyan
        }
    } else {
        # Key Vault usa Access Policies (método antigo)
        Write-Host "[INFO] Key Vault usa Access Policies. Verificando permissões..." -ForegroundColor Yellow
        $ErrorActionPreference = "Continue"
        $kvPermissions = az keyvault show --name $KeyVault --resource-group $ResourceGroup --query "properties.accessPolicies[?objectId=='$miPrincipalId'].permissions" -o json 2>$null | ConvertFrom-Json
        $ErrorActionPreference = "Stop"
        
        if ($kvPermissions) {
            Write-Host "[OK] Permissões encontradas:" -ForegroundColor Green
            if ($kvPermissions.secrets) {
                Write-Host "  Secrets: $($kvPermissions.secrets -join ', ')" -ForegroundColor Gray
            }
        } else {
            Write-Host "[AVISO] Nenhuma permissão encontrada!" -ForegroundColor Yellow
            Write-Host "[INFO] Execute:" -ForegroundColor Cyan
            Write-Host "  az keyvault set-policy --name $KeyVault --object-id $miPrincipalId --secret-permissions get list" -ForegroundColor Gray
        }
    }
} else {
    Write-Host "[ERRO] Managed Identity não está habilitada!" -ForegroundColor Red
    Write-Host "[INFO] Execute: .\infra\fix_managed_identity.ps1" -ForegroundColor Cyan
}
Write-Host ""

# 6. Resumo final
Write-Host "=== RESUMO DA AUDITORIA ===" -ForegroundColor Cyan
Write-Host ""

$totalIssues = $missingSecrets.Count + $wrongTypeSecrets.Count + $missingNonSecrets.Count + $kvIssues.Count

if ($totalIssues -eq 0) {
    Write-Host "[OK] Tudo configurado corretamente!" -ForegroundColor Green
} else {
    Write-Host "[AVISO] $totalIssues problema(s) encontrado(s):" -ForegroundColor Yellow
    Write-Host "  - Secrets faltando: $($missingSecrets.Count)" -ForegroundColor $(if ($missingSecrets.Count -gt 0) { "Red" } else { "Green" })
    Write-Host "  - Secrets com tipo errado: $($wrongTypeSecrets.Count)" -ForegroundColor $(if ($wrongTypeSecrets.Count -gt 0) { "Red" } else { "Green" })
    Write-Host "  - Non-secrets faltando: $($missingNonSecrets.Count)" -ForegroundColor $(if ($missingNonSecrets.Count -gt 0) { "Yellow" } else { "Green" })
    Write-Host "  - Problemas no Key Vault: $($kvIssues.Count)" -ForegroundColor $(if ($kvIssues.Count -gt 0) { "Red" } else { "Green" })
}

Write-Host ""
Write-Host "[INFO] Para corrigir problemas, execute:" -ForegroundColor Cyan
Write-Host "  .\infra\bootstrap_api.ps1 -ResourceGroup $ResourceGroup -Environment <env> -ApiApp $ApiAppName ..." -ForegroundColor Gray
Write-Host ""
