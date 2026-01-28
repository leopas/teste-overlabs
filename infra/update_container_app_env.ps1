# Script para atualizar variáveis de ambiente do Container App a partir do .env
# Uso: .\infra\update_container_app_env.ps1 -EnvFile ".env"

param(
    [string]$EnvFile = ".env",
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$KeyVaultName = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Atualizar Variáveis de Ambiente do Container App ===" -ForegroundColor Cyan
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

# Verificar se .env existe
if (-not (Test-Path $EnvFile)) {
    Write-Host "[ERRO] Arquivo $EnvFile não encontrado" -ForegroundColor Red
    exit 1
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host "[INFO] Key Vault: $KeyVaultName" -ForegroundColor Yellow
Write-Host "[INFO] Lendo variáveis de $EnvFile..." -ForegroundColor Yellow
Write-Host ""

# Ler variáveis do .env
$envVars = @{}
$secrets = @{}

Get-Content $EnvFile | ForEach-Object {
    if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.+)$' -and $_ -notmatch '^\s*#') {
        $key = $matches[1]
        $value = $matches[2].Trim('"').Trim("'")
        
        # Remover comentários inline
        if ($value -match '^(.+?)\s*#') {
            $value = $matches[1].Trim()
        }
        
        # Ignorar vazios
        if ([string]::IsNullOrWhiteSpace($value)) {
            return
        }
        
        # Identificar secrets (mas não todos os que contêm KEY/SECRET são secrets - alguns são flags)
        $isSecret = $key -match 'KEY|SECRET|TOKEN|PASSWORD|PASS' -and 
                    $key -notmatch 'PORT|ENV|LOG_LEVEL|HOST|QDRANT_URL|REDIS_URL|DOCS_ROOT|MYSQL_PORT|MYSQL_HOST|MYSQL_DATABASE|OTEL_ENABLED|USE_OPENAI|AUDIT_LOG|ABUSE_CLASSIFIER|PROMPT_FIREWALL|PIPELINE_LOG|TRACE_SINK|AUDIT_ENC_AAD|RATE_LIMIT|CACHE_TTL|FIREWALL|OPENAI_MODEL|OTEL_EXPORTER|DOCS_HOST|API_PORT|QDRANT_PORT|REDIS_PORT|OPENAI_EMBEDDINGS_MODEL'
        
        if ($isSecret) {
            $secrets[$key] = $value
        } else {
            $envVars[$key] = $value
        }
    }
}

Write-Host "[INFO] Variáveis não-secretas encontradas: $($envVars.Count)" -ForegroundColor Cyan
Write-Host "[INFO] Secrets encontrados: $($secrets.Count)" -ForegroundColor Cyan
Write-Host ""

# Obter URLs internas (Qdrant e Redis)
$state = Get-Content .azure/deploy_state.json | ConvertFrom-Json
$qdrantUrl = "http://$($state.qdrantAppName):6333"
$redisUrl = "redis://$($state.redisAppName):6379/0"

# Garantir que QDRANT_URL e REDIS_URL estejam corretos
$envVars["QDRANT_URL"] = $qdrantUrl
$envVars["REDIS_URL"] = $redisUrl

# Construir lista de env-vars para o Azure CLI
$allEnvVars = @()
foreach ($key in $envVars.Keys) {
    $allEnvVars += "$key=$($envVars[$key])"
}

# Adicionar Key Vault references para secrets
Write-Host "[INFO] Configurando secrets no Key Vault..." -ForegroundColor Cyan

# Tentar conceder permissão no Key Vault se necessário
Write-Host "[INFO] Verificando permissões no Key Vault..." -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
$currentUserId = az ad signed-in-user show --query id -o tsv
$subId = az account show --query id -o tsv
$scope = "/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$KeyVaultName"

# Tentar conceder permissão (idempotente)
az role assignment create `
    --scope $scope `
    --assignee $currentUserId `
    --role "Key Vault Secrets Officer" 2>&1 | Out-Null

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Permissão Key Vault Secrets Officer verificada/concedida" -ForegroundColor Green
    Write-Host "  Aguardando 3s para propagação..." -ForegroundColor Gray
    Start-Sleep -Seconds 3
} else {
    Write-Host "[AVISO] Pode não ter permissão para criar secrets. Tentando mesmo assim..." -ForegroundColor Yellow
}
$ErrorActionPreference = "Stop"

foreach ($key in $secrets.Keys) {
    $kvName = $key.ToLower().Replace('_', '-')
    
    # Verificar se secret já existe
    $ErrorActionPreference = "Continue"
    $secretExists = az keyvault secret show --vault-name $KeyVaultName --name $kvName 2>$null
    $ErrorActionPreference = "Stop"
    
    if (-not $secretExists) {
        Write-Host "  Criando secret: $kvName" -ForegroundColor Yellow
        $ErrorActionPreference = "Continue"
        az keyvault secret set `
            --vault-name $KeyVaultName `
            --name $kvName `
            --value $secrets[$key] 2>&1 | Out-Null
        $ErrorActionPreference = "Stop"
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    [OK] Secret criado" -ForegroundColor Green
        } else {
            Write-Host "    [ERRO] Falha ao criar secret (pode ser falta de permissão)" -ForegroundColor Red
            Write-Host "    Usando valor direto (não recomendado para produção)" -ForegroundColor Yellow
            $allEnvVars += "$key=$($secrets[$key])"
            continue
        }
    } else {
        Write-Host "  Secret já existe: $kvName (atualizando...)" -ForegroundColor Gray
        $ErrorActionPreference = "Continue"
        az keyvault secret set `
            --vault-name $KeyVaultName `
            --name $kvName `
            --value $secrets[$key] 2>&1 | Out-Null
        $ErrorActionPreference = "Stop"
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    [OK] Secret atualizado" -ForegroundColor Green
        } else {
            Write-Host "    [AVISO] Falha ao atualizar secret, usando valor existente" -ForegroundColor Yellow
        }
    }
    
    $allEnvVars += "$key=@Microsoft.KeyVault(SecretUri=https://$KeyVaultName.vault.azure.net/secrets/$kvName/)"
}

Write-Host "[OK] Secrets configurados" -ForegroundColor Green
Write-Host ""

# Atualizar Container App
Write-Host "[INFO] Atualizando Container App com $($allEnvVars.Count) variáveis de ambiente..." -ForegroundColor Cyan
Write-Host "  (Isso pode levar alguns segundos...)" -ForegroundColor Gray
Write-Host ""

# Construir comando com variáveis entre aspas para evitar problemas de parsing
# O Azure CLI espera as variáveis no formato: VAR1=value1 VAR2=value2
# No PowerShell, precisamos passar como array de strings, cada uma entre aspas
Write-Host "  Total de variáveis: $($allEnvVars.Count)" -ForegroundColor Gray

$ErrorActionPreference = "Continue"

# O problema é que PowerShell interpreta = como operador
# Solução: atualizar em lotes menores usando --set-env-vars múltiplas vezes
# Cada lote será processado separadamente para evitar problemas de parsing

Write-Host "  Atualizando variáveis uma por uma..." -ForegroundColor Gray
Write-Host "  (Isso pode levar alguns minutos, mas é mais confiável)" -ForegroundColor Gray
Write-Host ""

$successCount = 0
$failCount = 0
$total = $allEnvVars.Count
$current = 0

foreach ($envVar in $allEnvVars) {
    $current++
    if ($envVar -match '^([^=]+)=(.*)$') {
        $varName = $matches[1]
        $varValue = $matches[2]
        
        Write-Host "  [$current/$total] $varName..." -ForegroundColor Gray -NoNewline
        
        # Atualizar uma variável por vez usando --set-env-vars
        # Usar aspas duplas ao redor da string completa para evitar parsing
        $result = az containerapp update `
            --name $ApiAppName `
            --resource-group $ResourceGroup `
            --set-env-vars "$envVar" 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            $successCount++
            Write-Host " [OK]" -ForegroundColor Green
        } else {
            $failCount++
            Write-Host " [ERRO]" -ForegroundColor Red
            # Não mostrar erro completo para não poluir a saída
            # Mas continuar com próxima variável
        }
    }
}

$ErrorActionPreference = "Stop"

Write-Host ""
if ($failCount -eq 0) {
    Write-Host "[OK] Todas as $total variáveis foram atualizadas com sucesso!" -ForegroundColor Green
} else {
    Write-Host "[AVISO] $successCount de $total variáveis foram atualizadas, $failCount falharam" -ForegroundColor Yellow
}

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Container App atualizado com sucesso!" -ForegroundColor Green
    Write-Host ""
    Write-Host "[INFO] Variáveis configuradas:" -ForegroundColor Cyan
    Write-Host "  - Variáveis não-secretas: $($envVars.Count)" -ForegroundColor Gray
    Write-Host "  - Secrets (Key Vault): $($secrets.Count)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "[INFO] O Container App será reiniciado automaticamente com as novas variáveis" -ForegroundColor Yellow
    Write-Host ""
} else {
    Write-Host "[ERRO] Falha ao atualizar Container App" -ForegroundColor Red
    exit 1
}
