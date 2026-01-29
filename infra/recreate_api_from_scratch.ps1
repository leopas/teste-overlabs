# Script para recriar Container App da API do zero com volume mount
# Usa a mesma logica do bootstrap que funcionou para o Qdrant

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$Environment = $null,
    [string]$EnvFile = ".env",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

Write-Host "=== Recriar Container App da API do Zero ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "[AVISO] Este script vai recriar o Container App completamente." -ForegroundColor Yellow
Write-Host "[AVISO] Isso vai causar downtime temporario." -ForegroundColor Yellow
Write-Host ""

if (-not $Force) {
    $confirm = Read-Host "Deseja continuar? (S/N)"
    if ($confirm -ne "S") {
        Write-Host "[INFO] Operacao cancelada." -ForegroundColor Gray
        exit 0
    }
}

# Carregar deploy_state.json
$stateFile = ".azure/deploy_state.json"
if (-not (Test-Path $stateFile)) {
    Write-Host "[ERRO] Arquivo $stateFile nao encontrado." -ForegroundColor Red
    exit 1
}
$state = Get-Content $stateFile | ConvertFrom-Json

if (-not $ResourceGroup) {
    $ResourceGroup = $state.resourceGroup
}
if (-not $ApiAppName) {
    $ApiAppName = $state.apiAppName
}
if (-not $Environment) {
    $Environment = $state.environmentName
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] Environment: $Environment" -ForegroundColor Yellow
Write-Host "[INFO] API Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host ""

# 1. Obter ACR
$acrName = $state.acrName
Write-Host "[INFO] ACR: $acrName" -ForegroundColor Yellow

$acrLoginServer = az acr show --name $acrName --query loginServer -o tsv
$acrUsername = az acr credential show --name $acrName --query username -o tsv
$acrPassword = az acr credential show --name $acrName --query passwords[0].value -o tsv

Write-Host "[OK] ACR configurado: $acrLoginServer" -ForegroundColor Green
Write-Host ""

# 2. Obter environment ID
$envId = az containerapp env show --name $Environment --resource-group $ResourceGroup --query id -o tsv

# 3. Obter URLs internas
$QdrantApp = $state.qdrantAppName
$RedisApp = $state.redisAppName
$qdrantUrl = "http://${QdrantApp}:6333"
$redisUrl = "redis://${RedisApp}:6379/0"

# 4. Obter Key Vault
$KeyVault = $state.keyVaultName

# 5. Ler variaveis do .env (igual ao bootstrap)
Write-Host "[INFO] Carregando variaveis de ambiente do .env..." -ForegroundColor Yellow

# Ler secrets do .env
$secrets = @{}
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.+)$' -and $_ -notmatch '^\s*#') {
            $key = $matches[1]
            $value = $matches[2].Trim('"').Trim("'")
            
            if ($value -match '^(.+?)\s*#') {
                $value = $matches[1].Trim()
            }
            
            $isSecret = $key -match 'KEY|SECRET|TOKEN|PASSWORD|PASS|CONNECTION|API' -and 
                        $key -notmatch 'PORT|ENV|LOG_LEVEL|HOST|QDRANT_URL|REDIS_URL|DOCS_ROOT|MYSQL_PORT|MYSQL_HOST|MYSQL_DATABASE|OTEL_ENABLED|USE_OPENAI|AUDIT_LOG|ABUSE_CLASSIFIER|PROMPT_FIREWALL|PIPELINE_LOG|TRACE_SINK|AUDIT_ENC_AAD|RATE_LIMIT|CACHE_TTL|FIREWALL|OPENAI_MODEL|OTEL_EXPORTER|DOCS_HOST|API_PORT|QDRANT_PORT|REDIS_PORT'
            
            if ($isSecret -and $value) {
                $secrets[$key] = $value
            }
        }
    }
}

# Ler variaveis nao-secretas do .env
$nonSecrets = @{}
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.+)$' -and $_ -notmatch '^\s*#') {
            $key = $matches[1]
            $value = $matches[2].Trim('"').Trim("'")
            
            if ($value -match '^(.+?)\s*#') {
                $value = $matches[1].Trim()
            }
            
            $isSecret = $key -match 'KEY|SECRET|TOKEN|PASSWORD|PASS|CONNECTION|API' -and 
                        $key -notmatch 'PORT|ENV|LOG_LEVEL|HOST|QDRANT_URL|REDIS_URL|DOCS_ROOT|MYSQL_PORT|MYSQL_HOST|MYSQL_DATABASE|OTEL_ENABLED|USE_OPENAI|AUDIT_LOG|ABUSE_CLASSIFIER|PROMPT_FIREWALL|PIPELINE_LOG|TRACE_SINK|AUDIT_ENC_AAD|RATE_LIMIT|CACHE_TTL|FIREWALL|OPENAI_MODEL|OTEL_EXPORTER|DOCS_HOST|API_PORT|QDRANT_PORT|REDIS_PORT'
            
            if (-not $isSecret -and $value) {
                $nonSecrets[$key] = $value
            }
        }
    }
}

# 6. Obter location do Environment (sem capturar stderr)
$location = az containerapp env show --name $Environment --resource-group $ResourceGroup --query location -o tsv 2>$null
$location = $location.Trim()
if (-not $location -or $location -match "error|not found") {
    $location = "brazilsouth"  # Fallback padrão
}
# Garantir que location é código (não display name)
$location = $location.ToLower().Replace(' ', '')

# 7. Construir env vars (igual ao bootstrap)
$envVars = @(
    "QDRANT_URL=$qdrantUrl",
    "REDIS_URL=$redisUrl",
    "DOCS_ROOT=/app/DOC-IA"
)

# Adicionar variaveis nao-secretas
foreach ($key in $nonSecrets.Keys) {
    $envVars += "$key=$($nonSecrets[$key])"
}

# Adicionar Key Vault references para secrets
foreach ($key in $secrets.Keys) {
    $kvName = $key.ToLower().Replace('_', '-')
    $envVars += "$key=@Microsoft.KeyVault(SecretUri=https://$KeyVault.vault.azure.net/secrets/$kvName/)"
}

Write-Host "[OK] Carregadas $($envVars.Count) variaveis de ambiente" -ForegroundColor Green
Write-Host ""

# 8. Construir YAML (igual ao Qdrant que funcionou)
$envVarsYaml = ""
foreach ($envVar in $envVars) {
    $parts = $envVar -split '=', 2
    $name = $parts[0]
    $value = $parts[1]
    
    # Escapar Key Vault references corretamente
    if ($value -match '^@Microsoft\.KeyVault') {
        $valueEscaped = $value -replace '"', '\"'
        $envVarsYaml += "      - name: $name`n        value: `"$valueEscaped`"`n"
    } else {
        $value = $value -replace '\\', '\\\\'  # Escapar backslashes primeiro
        $value = $value -replace '"', '\"'      # Escapar aspas
        $envVarsYaml += "      - name: $name`n        value: `"$value`"`n"
    }
}

$yamlContent = @"
location: $location
properties:
  environmentId: "$envId"
  configuration:
    ingress:
      external: true
      allowInsecure: false
      targetPort: 8000
      transport: http
      traffic:
      - weight: 100
        latestRevision: true
    registries:
    - server: $acrLoginServer
      username: $acrUsername
      passwordSecretRef: acr-password
    secrets:
    - name: acr-password
      value: $acrPassword
  template:
    containers:
    - name: api
      image: $acrLoginServer/choperia-api:latest
      env:
$envVarsYaml
      resources:
        cpu: 2.0
        memory: 4.0Gi
      volumeMounts:
      - volumeName: docs
        mountPath: /app/DOC-IA
    scale:
      minReplicas: 1
      maxReplicas: 5
    volumes:
    - name: docs
      storageType: AzureFile
      storageName: documents-storage
"@

$yamlFile = "app_recreate_$(Get-Date -Format 'yyyyMMddHHmmss').yaml"
# Escrever sem BOM (Byte Order Mark) para evitar erro de parsing no Azure CLI
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($yamlFile, $yamlContent, $utf8NoBom)

Write-Host "[INFO] YAML salvo em: $yamlFile" -ForegroundColor Gray
Write-Host "[INFO] Criando Container App com volume mount..." -ForegroundColor Yellow

# 8. Verificar se Container App existe e deletar se necessario
$ErrorActionPreference = "Continue"
$appExists = az containerapp show --name $ApiAppName --resource-group $ResourceGroup 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "[INFO] Container App existe. Deletando..." -ForegroundColor Yellow
    az containerapp delete --name $ApiAppName --resource-group $ResourceGroup --yes 2>&1 | Out-Null
    Write-Host "[INFO] Aguardando 10s..." -ForegroundColor Gray
    Start-Sleep -Seconds 10
}
$ErrorActionPreference = "Stop"

# 9. Criar Container App com volume mount (igual ao Qdrant)
Write-Host "[INFO] Criando Container App..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
az containerapp create `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --yaml $yamlFile 2>&1 | Out-Null

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Container App criado com volume mount!" -ForegroundColor Green
    
    # Verificar se foi aplicado
    Write-Host "[INFO] Verificando se volume mount foi aplicado..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
    
    $verifyMounts = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].volumeMounts" -o json | ConvertFrom-Json
    
    if ($verifyMounts) {
        Write-Host "[OK] Volume mount confirmado!" -ForegroundColor Green
        foreach ($vm in $verifyMounts) {
            Write-Host "  - Volume: $($vm.volumeName), Mount: $($vm.mountPath)" -ForegroundColor Gray
        }
        
        # Limpar arquivo YAML
        Remove-Item $yamlFile -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "[AVISO] Volume mount nao foi confirmado." -ForegroundColor Yellow
        Write-Host "[INFO] YAML mantido em: $yamlFile para inspecao" -ForegroundColor Gray
    }
} else {
    Write-Host "[ERRO] Falha ao criar Container App" -ForegroundColor Red
    Write-Host "[INFO] YAML mantido em: $yamlFile para inspecao" -ForegroundColor Yellow
    Write-Host "[INFO] Tente criar manualmente: az containerapp create -n $ApiAppName -g $ResourceGroup --yaml $yamlFile" -ForegroundColor Cyan
    exit 1
}
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "[OK] Container App recriado com sucesso!" -ForegroundColor Green
Write-Host "[INFO] Aguarde alguns minutos e verifique: .\infra\verify_volume_working.ps1" -ForegroundColor Cyan
Write-Host ""
