# Script para validar que todas as variáveis do .env foram configuradas corretamente no Container App
# Uso: .\infra\validate_bootstrap.ps1 [-ResourceGroup "rg-overlabs-prod"] [-ApiAppName "app-overlabs-prod-300"] [-EnvFile ".env"]

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$EnvFile = ".env"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Validação Pós-Bootstrap ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se não fornecido
if (-not $ResourceGroup -or -not $ApiAppName) {
    $stateFile = ".azure/deploy_state.json"
    if (Test-Path $stateFile) {
        $state = Get-Content $stateFile | ConvertFrom-Json
        if (-not $ResourceGroup) {
            $ResourceGroup = $state.resourceGroup
        }
        if (-not $ApiAppName) {
            $ApiAppName = $state.apiAppName
        }
    } else {
        Write-Host "[ERRO] Resource Group e ApiAppName não fornecidos e deploy_state.json não encontrado" -ForegroundColor Red
        exit 1
    }
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] API Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host "[INFO] Env File: $EnvFile" -ForegroundColor Yellow
Write-Host ""

# Validar arquivo .env
if (-not (Test-Path $EnvFile)) {
    Write-Host "[ERRO] Arquivo $EnvFile não encontrado" -ForegroundColor Red
    exit 1
}

# Carregar variáveis do .env (mesma lógica do bootstrap)
$envVarsFromFile = @{}
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
        
        # Remover comentários inline
        if ($value -match '^(.+?)\s*#') {
            $value = $matches[1].Trim()
        }
        
        if ($value) {
            $envVarsFromFile[$key] = $value
        }
    }
}

Write-Host "[INFO] Variáveis encontradas no .env: $($envVarsFromFile.Count)" -ForegroundColor Cyan
Write-Host ""

# Obter variáveis configuradas no Container App
Write-Host "[INFO] Obtendo variáveis do Container App..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$containerEnvVars = az containerapp show `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --query "properties.template.containers[0].env" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = "Stop"

if (-not $containerEnvVars) {
    Write-Host "[ERRO] Falha ao obter variáveis do Container App!" -ForegroundColor Red
    exit 1
}

# Converter para hashtable para facilitar busca
$containerVars = @{}
foreach ($envVar in $containerEnvVars) {
    $containerVars[$envVar.name] = $envVar.value
}

Write-Host "[INFO] Variáveis encontradas no Container App: $($containerVars.Count)" -ForegroundColor Cyan
Write-Host ""

# Variáveis que são configuradas automaticamente (não precisam estar no .env)
$autoConfigured = @(
    "QDRANT_URL",  # Configurado pelo bootstrap com URL interna
    "REDIS_URL",   # Configurado pelo bootstrap
    "DOCS_ROOT"    # Configurado como /app/DOC-IA
)

# Comparar e validar
Write-Host "=== Validação de Variáveis ===" -ForegroundColor Cyan
Write-Host ""

$missing = @()
$mismatched = @()
$ok = @()
$secretsOk = @()
$secretsMissing = @()

foreach ($key in $envVarsFromFile.Keys) {
    # Pular variáveis que são configuradas automaticamente
    if ($autoConfigured -contains $key) {
        continue
    }
    
    # Verificar se é secret
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
        # Para secrets, verificar se há referência Key Vault
        if ($containerVars.ContainsKey($key)) {
            $containerValue = $containerVars[$key]
            if ($containerValue -match "@Microsoft\.KeyVault") {
                $secretsOk += $key
            } else {
                $mismatched += @{
                    Key = $key
                    Expected = "Key Vault Reference"
                    Actual = "Direct Value"
                }
            }
        } else {
            $secretsMissing += $key
        }
    } else {
        # Para non-secrets, verificar valor
        if ($containerVars.ContainsKey($key)) {
            $expectedValue = $envVarsFromFile[$key]
            $actualValue = $containerVars[$key]
            
            # Normalizar para comparação (remover aspas, espaços)
            $expectedNormalized = $expectedValue.ToString().Trim('"').Trim("'").Trim()
            $actualNormalized = $actualValue.ToString().Trim('"').Trim("'").Trim()
            
            if ($expectedNormalized -eq $actualNormalized) {
                $ok += $key
            } else {
                $mismatched += @{
                    Key = $key
                    Expected = $expectedNormalized
                    Actual = $actualNormalized
                }
            }
        } else {
            $missing += $key
        }
    }
}

# Exibir resultados
$hasErrors = $false

if ($ok.Count -gt 0) {
    Write-Host "[OK] Variáveis non-secrets configuradas corretamente ($($ok.Count)):" -ForegroundColor Green
    foreach ($key in $ok) {
        Write-Host "  [OK] $key" -ForegroundColor Gray
    }
    Write-Host ""
}

if ($secretsOk.Count -gt 0) {
    Write-Host "[OK] Secrets com Key Vault reference ($($secretsOk.Count)):" -ForegroundColor Green
    foreach ($key in $secretsOk) {
        Write-Host "  [OK] $key (Key Vault)" -ForegroundColor Gray
    }
    Write-Host ""
}

if ($missing.Count -gt 0) {
    Write-Host "[ERRO] Variáveis do .env NÃO encontradas no Container App ($($missing.Count)):" -ForegroundColor Red
    foreach ($key in $missing) {
        Write-Host "  [ERRO] $key" -ForegroundColor Red
    }
    Write-Host ""
    $hasErrors = $true
}

if ($secretsMissing.Count -gt 0) {
    Write-Host "[ERRO] Secrets do .env NÃO encontrados no Container App ($($secretsMissing.Count)):" -ForegroundColor Red
    foreach ($key in $secretsMissing) {
        Write-Host "  [ERRO] $key" -ForegroundColor Red
    }
    Write-Host ""
    $hasErrors = $true
}

if ($mismatched.Count -gt 0) {
    Write-Host "[AVISO] Variáveis com valores diferentes ($($mismatched.Count)):" -ForegroundColor Yellow
    foreach ($item in $mismatched) {
        Write-Host "  [AVISO] $($item.Key)" -ForegroundColor Yellow
        Write-Host "    Esperado: $($item.Expected)" -ForegroundColor Gray
        Write-Host "    Atual:    $($item.Actual)" -ForegroundColor Gray
    }
    Write-Host ""
    $hasErrors = $true
}

# Verificar variáveis automáticas
Write-Host "=== Variáveis Automáticas ===" -ForegroundColor Cyan
Write-Host ""
foreach ($autoVar in $autoConfigured) {
    if ($containerVars.ContainsKey($autoVar)) {
        $value = $containerVars[$autoVar]
        Write-Host "[OK] $autoVar = $value" -ForegroundColor Green
    } else {
        Write-Host "[ERRO] $autoVar não configurada!" -ForegroundColor Red
        $hasErrors = $true
    }
}
Write-Host ""

# Resumo final
Write-Host "=== Resumo ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Variáveis do .env: $($envVarsFromFile.Count)" -ForegroundColor Yellow
Write-Host "Variáveis no Container: $($containerVars.Count)" -ForegroundColor Yellow
Write-Host "Non-secrets OK: $($ok.Count)" -ForegroundColor Green
Write-Host "Secrets OK: $($secretsOk.Count)" -ForegroundColor Green
Write-Host "Faltando: $($missing.Count + $secretsMissing.Count)" -ForegroundColor $(if ($missing.Count + $secretsMissing.Count -gt 0) { "Red" } else { "Green" })
Write-Host "Valores diferentes: $($mismatched.Count)" -ForegroundColor $(if ($mismatched.Count -gt 0) { "Yellow" } else { "Green" })
Write-Host ""

if ($hasErrors) {
    Write-Host "[ERRO] Validação falhou! Corrija os problemas acima." -ForegroundColor Red
    Write-Host ""
    Write-Host "[INFO] Para corrigir, execute o bootstrap novamente:" -ForegroundColor Yellow
    Write-Host "  .\infra\bootstrap_container_apps.ps1 -EnvFile '$EnvFile' -Stage 'prod'" -ForegroundColor Gray
    exit 1
} else {
    Write-Host "[OK] Todas as variáveis foram configuradas corretamente!" -ForegroundColor Green
    exit 0
}
