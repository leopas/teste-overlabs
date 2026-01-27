# Script para configurar App Settings na Web App
# Uso: .\infra\configure_app_settings.ps1 -WebApp "app-overlabs-prod-282" -ResourceGroup "rg-overlabs-prod" -KeyVault "kv-overlabs-prod-282" -EnvFile ".env"

param(
    [Parameter(Mandatory=$true)]
    [string]$WebApp,
    
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroup,
    
    [Parameter(Mandatory=$true)]
    [string]$KeyVault,
    
    [string]$EnvFile = ".env"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Configurando App Settings ===" -ForegroundColor Cyan
Write-Host ""

# 1. Obter Managed Identity
Write-Host "[INFO] Obtendo Managed Identity..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$principalId = az webapp identity show --name $WebApp --resource-group $ResourceGroup --query principalId -o tsv 2>$null
$ErrorActionPreference = "Stop"

if (-not $principalId) {
    Write-Host "[ERRO] Managed Identity não encontrado. Execute: az webapp identity assign --name $WebApp --resource-group $ResourceGroup" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Principal ID: $principalId" -ForegroundColor Green
Write-Host ""

# 2. Conceder permissões no Key Vault (RBAC)
Write-Host "[INFO] Concedendo permissões no Key Vault..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$subscriptionId = az account show --query id -o tsv
$scope = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$KeyVault"

$existing = az role assignment list --scope $scope --assignee $principalId --role "Key Vault Secrets User" --query "[0].id" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if (-not $existing) {
    $ErrorActionPreference = "Continue"
    az role assignment create --scope $scope --assignee $principalId --role "Key Vault Secrets User" 2>&1 | Out-Null
    $ErrorActionPreference = "Stop"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Permissão concedida" -ForegroundColor Green
    } else {
        Write-Host "[AVISO] Erro ao conceder permissão (pode já existir)" -ForegroundColor Yellow
    }
} else {
    Write-Host "[OK] Permissão já existe" -ForegroundColor Green
}
Write-Host ""

# 3. Ler .env e classificar variáveis
Write-Host "[INFO] Lendo e classificando variáveis do .env..." -ForegroundColor Yellow
$secrets = @{}
$nonSecrets = @{}

Get-Content $EnvFile | ForEach-Object {
    if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.+)$' -and $_ -notmatch '^\s*#') {
        $key = $matches[1]
        $value = $matches[2].Trim('"').Trim("'")
        
        # Remover comentários inline
        if ($value -match '^(.+?)\s*#') {
            $value = $matches[1].Trim()
        }
        
        # Classificar como secret
        $isSecret = $key -match 'KEY|SECRET|TOKEN|PASSWORD|PASS|CONNECTION|API' -and 
                    $key -notmatch 'PORT|ENV|LOG_LEVEL|HOST|QDRANT_URL|REDIS_URL|DOCS_ROOT|MYSQL_PORT|MYSQL_HOST|MYSQL_DATABASE|OTEL_ENABLED|USE_OPENAI|AUDIT_LOG|ABUSE_CLASSIFIER|PROMPT_FIREWALL|PIPELINE_LOG|TRACE_SINK|AUDIT_ENC_AAD|RATE_LIMIT|CACHE_TTL|FIREWALL|OPENAI_MODEL|OTEL_EXPORTER|DOCS_HOST|API_PORT|QDRANT_PORT|REDIS_PORT'
        
        if ($isSecret -and $value) {
            $secrets[$key] = $value
        } elseif ($value) {
            $nonSecrets[$key] = $value
        }
    }
}

Write-Host "[OK] Encontrados: $($secrets.Count) secrets, $($nonSecrets.Count) non-secrets" -ForegroundColor Green
Write-Host ""

# 4. Configurar App Settings
Write-Host "[INFO] Configurando App Settings..." -ForegroundColor Yellow

$settings = @()

# Non-secrets: valores diretos
foreach ($key in $nonSecrets.Keys) {
    $value = $nonSecrets[$key]
    $settings += "$key=$value"
}

# Secrets: Key Vault references
foreach ($key in $secrets.Keys) {
    $kvName = $key.ToLower().Replace('_', '-')
    $secretUri = "https://$KeyVault.vault.azure.net/secrets/$kvName/"
    $kvRef = "@Microsoft.KeyVault(SecretUri=$secretUri)"
    $settings += "$key=$kvRef"
}

# Configurar todas de uma vez
Write-Host "  [INFO] Aplicando $($settings.Count) variáveis..." -ForegroundColor Cyan

$ErrorActionPreference = "Continue"
$settingsString = $settings -join " "
az webapp config appsettings set --name $WebApp --resource-group $ResourceGroup --settings $settingsString 2>&1 | Out-Null
$ErrorActionPreference = "Stop"

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] App Settings configurados" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Secrets (Key Vault references): $($secrets.Count)" -ForegroundColor Cyan
    foreach ($key in $secrets.Keys) {
        Write-Host "    - $key" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  Non-secrets (valores diretos): $($nonSecrets.Count)" -ForegroundColor Cyan
    $first5 = ($nonSecrets.Keys | Select-Object -First 5) -join ', '
    Write-Host "    (primeiras 5: $first5)" -ForegroundColor Gray
} else {
    Write-Host "[ERRO] Falha ao configurar App Settings" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== Concluído! ===" -ForegroundColor Green
