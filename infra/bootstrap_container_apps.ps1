# Script para bootstrap de infraestrutura Azure Container Apps
# Uso: .\infra\bootstrap_container_apps.ps1 -EnvFile ".env" -Stage "prod" -Location "brazilsouth"
#
# Este script cria:
# - Resource Group
# - Azure Container Registry (ACR)
# - Azure Key Vault
# - Azure Container Apps Environment
# - Container Apps: api, qdrant, redis
# - Azure Files (para volumes persistentes do Qdrant)
# - Configura secrets no Key Vault
# - Salva deploy_state.json

param(
    [string]$EnvFile = ".env",
    [string]$Stage = "prod",
    [string]$Location = "brazilsouth",
    [string]$ResourceGroup = $null,
    [string]$AcrName = "acrchoperia"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Bootstrap Azure Container Apps ===" -ForegroundColor Cyan
Write-Host ""

# Validar arquivo .env
if (-not (Test-Path $EnvFile)) {
    Write-Host "[ERRO] Arquivo $EnvFile não encontrado" -ForegroundColor Red
    exit 1
}

# Verificar se já existe deploy_state.json para reutilizar sufixo
$suffix = $null
if (-not $ResourceGroup) {
    $ResourceGroup = "rg-overlabs-$Stage"
}

# Tentar carregar sufixo existente do deploy_state.json
$stateFile = ".azure/deploy_state.json"
if (Test-Path $stateFile) {
    try {
        $existingState = Get-Content $stateFile | ConvertFrom-Json
        if ($existingState.apiAppName) {
            # Extrair sufixo do nome do Container App (formato: app-overlabs-prod-248)
            if ($existingState.apiAppName -match "-(\d+)$") {
                $suffix = [int]$matches[1]
                Write-Host "[INFO] Reutilizando sufixo existente do deploy_state.json: $suffix" -ForegroundColor Cyan
            }
        }
    } catch {
        Write-Host "[AVISO] Não foi possível ler deploy_state.json existente, gerando novo sufixo" -ForegroundColor Yellow
    }
}

# Se não encontrou sufixo existente, gerar um novo
if (-not $suffix) {
    $suffix = Get-Random -Minimum 100 -Maximum 999
}

$KeyVault = "kv-overlabs-$Stage-$suffix"
$Environment = "env-overlabs-$Stage-$suffix"
$ApiApp = "app-overlabs-$Stage-$suffix"
$QdrantApp = "app-overlabs-qdrant-$Stage-$suffix"
$RedisApp = "app-overlabs-redis-$Stage-$suffix"
$StorageAccount = "saoverlabs$Stage$suffix".ToLower()
$FileShare = "qdrant-storage"

Write-Host "[INFO] Suffix: $suffix" -ForegroundColor Yellow
Write-Host "[INFO] Verificando contexto Azure..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$account = az account show 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERRO] Não está logado na Azure. Execute: az login" -ForegroundColor Red
    exit 1
}
$subscriptionId = az account show --query id -o tsv
$tenantId = az account show --query tenantId -o tsv
$ErrorActionPreference = "Stop"
Write-Host "[OK] Subscription: $subscriptionId" -ForegroundColor Green
Write-Host ""

Write-Host "[INFO] Recursos a criar:" -ForegroundColor Yellow
Write-Host "  - Resource Group: $ResourceGroup" -ForegroundColor Gray
Write-Host "  - ACR: $AcrName" -ForegroundColor Gray
Write-Host "  - Key Vault: $KeyVault" -ForegroundColor Gray
Write-Host "  - Container Apps Environment: $Environment" -ForegroundColor Gray
Write-Host "  - API Container App: $ApiApp" -ForegroundColor Gray
Write-Host "  - Qdrant Container App: $QdrantApp" -ForegroundColor Gray
Write-Host "  - Redis Container App: $RedisApp" -ForegroundColor Gray
Write-Host "  - Storage Account: $StorageAccount" -ForegroundColor Gray
Write-Host "  - File Share: $FileShare" -ForegroundColor Gray
Write-Host ""

# 1. Resource Group
Write-Host "[INFO] Verificando Resource Group..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$null = az group show --name $ResourceGroup 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando Resource Group..." -ForegroundColor Yellow
    az group create --name $ResourceGroup --location $Location | Out-Null
    Write-Host "[OK] Resource Group criado" -ForegroundColor Green
} else {
    Write-Host "[OK] Resource Group já existe" -ForegroundColor Green
}
Write-Host ""

# 2. ACR
Write-Host "[INFO] Verificando ACR..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$null = az acr show --name $AcrName 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando ACR..." -ForegroundColor Yellow
    az acr create --name $AcrName --resource-group $ResourceGroup --sku Basic --admin-enabled true | Out-Null
    Write-Host "[OK] ACR criado" -ForegroundColor Green
} else {
    Write-Host "[OK] ACR já existe" -ForegroundColor Green
}
Write-Host ""

# 3. Key Vault
Write-Host "[INFO] Verificando Key Vault..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$null = az keyvault show --name $KeyVault --resource-group $ResourceGroup 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando Key Vault..." -ForegroundColor Yellow
    az keyvault create --name $KeyVault --resource-group $ResourceGroup --location $Location --sku standard | Out-Null
    Write-Host "[OK] Key Vault criado" -ForegroundColor Green
    
    # Conceder permissões ao usuário atual
    Write-Host "[INFO] Configurando permissões no Key Vault..." -ForegroundColor Yellow
    $currentUser = az ad signed-in-user show --query objectId -o tsv
    az role assignment create --scope "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$KeyVault" --assignee $currentUser --role "Key Vault Secrets Officer" 2>&1 | Out-Null
    Write-Host "[OK] Permissão concedida" -ForegroundColor Green
    Write-Host "[INFO] Aguardando propagação de permissões (10s)..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
} else {
    Write-Host "[OK] Key Vault já existe" -ForegroundColor Green
}
Write-Host ""

# 4. Ler secrets do .env e fazer upload
Write-Host "[INFO] Lendo secrets do .env..." -ForegroundColor Yellow
$secrets = @{}
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
        }
    }
}

if ($secrets.Count -gt 0) {
    Write-Host "[INFO] Uploading $($secrets.Count) secrets para Key Vault..." -ForegroundColor Yellow
    foreach ($key in $secrets.Keys) {
        $kvName = $key.ToLower().Replace('_', '-')
        $value = $secrets[$key]
        
        $ErrorActionPreference = "Continue"
        $tempFile = [System.IO.Path]::GetTempFileName()
        $value | Out-File -FilePath $tempFile -Encoding utf8 -NoNewline
        az keyvault secret set --vault-name $KeyVault --name $kvName --file $tempFile 2>&1 | Out-Null
        Remove-Item $tempFile -Force
        $ErrorActionPreference = "Stop"
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] $key -> $kvName" -ForegroundColor Green
        } else {
            Write-Host "  [AVISO] Erro ao criar secret $kvName (pode já existir)" -ForegroundColor Yellow
        }
    }
    Write-Host "[OK] Secrets uploaded" -ForegroundColor Green
}
Write-Host ""

# 5. Storage Account e File Share (para volumes persistentes)
Write-Host "[INFO] Verificando Storage Account..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$null = az storage account show --name $StorageAccount --resource-group $ResourceGroup 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando Storage Account..." -ForegroundColor Yellow
    az storage account create --name $StorageAccount --resource-group $ResourceGroup --location $Location --sku Standard_LRS --kind StorageV2 | Out-Null
    Write-Host "[OK] Storage Account criado" -ForegroundColor Green
} else {
    Write-Host "[OK] Storage Account já existe" -ForegroundColor Green
}

# Criar File Shares (Qdrant e Documents)
Write-Host "[INFO] Verificando File Shares..." -ForegroundColor Yellow
$storageKey = az storage account keys list --account-name $StorageAccount --resource-group $ResourceGroup --query "[0].value" -o tsv
$ErrorActionPreference = "Continue"

# File Share para Qdrant
$null = az storage share show --account-name $StorageAccount --account-key $storageKey --name $FileShare 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando File Share para Qdrant..." -ForegroundColor Yellow
    az storage share create --account-name $StorageAccount --account-key $storageKey --name $FileShare --quota 100 | Out-Null
    Write-Host "[OK] File Share para Qdrant criado" -ForegroundColor Green
} else {
    Write-Host "[OK] File Share para Qdrant já existe" -ForegroundColor Green
}

# File Share para documentos
$DocsFileShare = "documents"
$null = az storage share show --account-name $StorageAccount --account-key $storageKey --name $DocsFileShare 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando File Share para documentos..." -ForegroundColor Yellow
    az storage share create --account-name $StorageAccount --account-key $storageKey --name $DocsFileShare --quota 10 | Out-Null
    Write-Host "[OK] File Share para documentos criado" -ForegroundColor Green
} else {
    Write-Host "[OK] File Share para documentos já existe" -ForegroundColor Green
}

$ErrorActionPreference = "Stop"
Write-Host ""

# 6. Container Apps Environment
Write-Host "[INFO] Verificando Container Apps Environment..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$null = az containerapp env show --name $Environment --resource-group $ResourceGroup 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando Container Apps Environment..." -ForegroundColor Yellow
    az containerapp env create --name $Environment --resource-group $ResourceGroup --location $Location | Out-Null
    Write-Host "[OK] Container Apps Environment criado" -ForegroundColor Green
} else {
    Write-Host "[OK] Container Apps Environment já existe" -ForegroundColor Green
}
Write-Host ""

# 7. Redis Container App (usando imagem oficial do Redis)
Write-Host "[INFO] Verificando Redis Container App..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$null = az containerapp show --name $RedisApp --resource-group $ResourceGroup 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando Redis Container App..." -ForegroundColor Yellow
    az containerapp create `
        --name $RedisApp `
        --resource-group $ResourceGroup `
        --environment $Environment `
        --image redis:7-alpine `
        --target-port 6379 `
        --ingress internal `
        --cpu 0.5 `
        --memory 1.0Gi `
        --min-replicas 1 `
        --max-replicas 1 `
        --env-vars "REDIS_ARGS=--appendonly no" 2>&1 | Out-Null
    Write-Host "[OK] Redis Container App criado" -ForegroundColor Green
} else {
    Write-Host "[OK] Redis Container App já existe" -ForegroundColor Green
}
Write-Host ""

# 8. Qdrant Container App (com volume persistente)
Write-Host "[INFO] Verificando Qdrant Container App..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$null = az containerapp show --name $QdrantApp --resource-group $ResourceGroup 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando Qdrant Container App..." -ForegroundColor Yellow
    
    # Criar volume persistente
    $storageAccountId = az storage account show --name $StorageAccount --resource-group $ResourceGroup --query id -o tsv
    $ErrorActionPreference = "Continue"
    az containerapp env storage set `
        --name $Environment `
        --resource-group $ResourceGroup `
        --storage-name qdrant-storage `
        --azure-file-account-name $StorageAccount `
        --azure-file-account-key $storageKey `
        --azure-file-share-name $FileShare `
        --access-mode ReadWrite 2>&1 | Out-Null
    $ErrorActionPreference = "Stop"
    
    # Criar Container App com volume usando YAML
    Write-Host "  [INFO] Criando Container App com volume..." -ForegroundColor Cyan
    
    # Obter environment ID
    $envId = az containerapp env show --name $Environment --resource-group $ResourceGroup --query id -o tsv
    
    # Criar arquivo YAML temporário para o Qdrant com volume
    $yamlContent = @"
properties:
  environmentId: $envId
  configuration:
    ingress:
      external: false
      targetPort: 6333
      transport: http
  template:
    containers:
    - name: qdrant
      image: qdrant/qdrant:v1.7.4
      env:
      - name: QDRANT__SERVICE__GRPC_PORT
        value: "6334"
      resources:
        cpu: 1.0
        memory: 2.0Gi
      volumeMounts:
      - volumeName: qdrant-storage
        mountPath: /qdrant/storage
    scale:
      minReplicas: 1
      maxReplicas: 1
    volumes:
    - name: qdrant-storage
      storageType: AzureFile
      storageName: qdrant-storage
"@
    
    $tempYaml = [System.IO.Path]::GetTempFileName() + ".yaml"
    $yamlContent | Out-File -FilePath $tempYaml -Encoding utf8 -NoNewline
    
    $ErrorActionPreference = "Continue"
    try {
        az containerapp create `
            --name $QdrantApp `
            --resource-group $ResourceGroup `
            --yaml $tempYaml 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] Container App criado com volume" -ForegroundColor Green
        } else {
            Write-Host "  [AVISO] Erro ao criar com YAML, tentando sem volume..." -ForegroundColor Yellow
            # Fallback: criar sem volume
            az containerapp create `
                --name $QdrantApp `
                --resource-group $ResourceGroup `
                --environment $Environment `
                --image qdrant/qdrant:v1.7.4 `
                --target-port 6333 `
                --ingress internal `
                --cpu 1.0 `
                --memory 2.0Gi `
                --min-replicas 1 `
                --max-replicas 1 `
                --env-vars "QDRANT__SERVICE__GRPC_PORT=6334" 2>&1 | Out-Null
            Write-Host "  [AVISO] Container App criado sem volume. Configure manualmente via portal." -ForegroundColor Yellow
        }
    } finally {
        Remove-Item $tempYaml -Force -ErrorAction SilentlyContinue
    }
    
    $ErrorActionPreference = "Stop"
    Write-Host "[OK] Qdrant Container App criado" -ForegroundColor Green
} else {
    Write-Host "[OK] Qdrant Container App já existe" -ForegroundColor Green
}
Write-Host ""

# 9. Obter URLs internas
$ErrorActionPreference = "Continue"
$qdrantFqdn = az containerapp show --name $QdrantApp --resource-group $ResourceGroup --query "properties.configuration.ingress.fqdn" -o tsv 2>$null
$redisFqdn = az containerapp show --name $RedisApp --resource-group $ResourceGroup --query "properties.configuration.ingress.fqdn" -o tsv 2>$null
$ErrorActionPreference = "Stop"

# URLs internas (usando DNS interno do Container Apps Environment)
# No Container Apps, containers se comunicam via nome do app + porta interna
$qdrantUrl = "http://${QdrantApp}:6333"
$redisUrl = "redis://${RedisApp}:6379/0"

Write-Host "[INFO] URLs internas configuradas:" -ForegroundColor Cyan
Write-Host "  QDRANT_URL: $qdrantUrl" -ForegroundColor Gray
Write-Host "  REDIS_URL: $redisUrl" -ForegroundColor Gray
Write-Host ""

# 9.5. Configurar volume de documentos no Environment
Write-Host "[INFO] Configurando volume de documentos no Environment..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$docsStorageExists = az containerapp env storage show `
    --name $Environment `
    --resource-group $ResourceGroup `
    --storage-name documents-storage 2>&1 | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando volume de documentos..." -ForegroundColor Yellow
    az containerapp env storage set `
        --name $Environment `
        --resource-group $ResourceGroup `
        --storage-name documents-storage `
        --azure-file-account-name $StorageAccount `
        --azure-file-account-key $storageKey `
        --azure-file-share-name $DocsFileShare `
        --access-mode ReadWrite 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Volume de documentos configurado" -ForegroundColor Green
    } else {
        Write-Host "[AVISO] Falha ao configurar volume de documentos. Continuando sem volume..." -ForegroundColor Yellow
    }
} else {
    Write-Host "[OK] Volume de documentos já existe" -ForegroundColor Green
}
$ErrorActionPreference = "Stop"
Write-Host ""

# 10. API Container App
Write-Host "[INFO] Verificando API Container App..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$null = az containerapp show --name $ApiApp --resource-group $ResourceGroup 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando API Container App..." -ForegroundColor Yellow
    
    # Ler variáveis não-secretas do .env
    $nonSecrets = @{}
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
    
    # Construir env-vars
    $envVars = @(
        "QDRANT_URL=$qdrantUrl",
        "REDIS_URL=$redisUrl",
        "DOCS_ROOT=/app/DOC-IA"
    )
    
    foreach ($key in $nonSecrets.Keys) {
        $envVars += "$key=$($nonSecrets[$key])"
    }
    
    # Adicionar Key Vault references para secrets
    foreach ($key in $secrets.Keys) {
        $kvName = $key.ToLower().Replace('_', '-')
        $envVars += "$key=@Microsoft.KeyVault(SecretUri=https://$KeyVault.vault.azure.net/secrets/$kvName/)"
    }
    
    # Obter environment ID e subscription ID
    $envId = az containerapp env show --name $Environment --resource-group $ResourceGroup --query id -o tsv
    $subscriptionId = az account show --query id -o tsv
    
    # Criar Container App com volume usando YAML
    Write-Host "  [INFO] Criando Container App com volume de documentos..." -ForegroundColor Cyan
    
    $acrLoginServer = az acr show --name $AcrName --query loginServer -o tsv
    $acrUsername = az acr credential show --name $AcrName --query username -o tsv
    $acrPassword = az acr credential show --name $AcrName --query passwords[0].value -o tsv
    
    # Construir YAML para Container App com volume
    # Construir lista de env vars formatada
    $envVarsYaml = ""
    foreach ($envVar in $envVars) {
        $parts = $envVar -split '=', 2
        $name = $parts[0]
        $value = $parts[1]
        # Escapar aspas duplas no valor
        $value = $value -replace '"', '\"'
        $envVarsYaml += "      - name: $name`n        value: `"$value`"`n"
    }
    
    $yamlContent = @"
properties:
  environmentId: $envId
  configuration:
    ingress:
      external: true
      targetPort: 8000
      transport: http
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
$envVarsYaml      resources:
        cpu: 2.0
        memory: 4.0Gi
      volumeMounts:
      - volumeName: documents-storage
        mountPath: /app/DOC-IA
    scale:
      minReplicas: 1
      maxReplicas: 5
    volumes:
    - name: documents-storage
      storageType: AzureFile
      storageName: documents-storage
"@
    
    $tempYaml = [System.IO.Path]::GetTempFileName() + ".yaml"
    $yamlContent | Out-File -FilePath $tempYaml -Encoding utf8 -NoNewline
    
    try {
        az containerapp create `
            --name $ApiApp `
            --resource-group $ResourceGroup `
            --yaml $tempYaml 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] API Container App criado com volume de documentos" -ForegroundColor Green
        } else {
            Write-Host "[AVISO] Erro ao criar com YAML. Tentando sem volume..." -ForegroundColor Yellow
            # Fallback: criar sem volume
            az containerapp create `
                --name $ApiApp `
                --resource-group $ResourceGroup `
                --environment $Environment `
                --image "$acrLoginServer/choperia-api:latest" `
                --registry-server $acrLoginServer `
                --registry-username $acrUsername `
                --registry-password $acrPassword `
                --target-port 8000 `
                --ingress external `
                --cpu 2.0 `
                --memory 4.0Gi `
                --min-replicas 1 `
                --max-replicas 5 `
                --env-vars $envVars 2>&1 | Out-Null
            Write-Host "[AVISO] Container App criado sem volume. Configure manualmente via portal." -ForegroundColor Yellow
        }
    } finally {
        Remove-Item $tempYaml -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "[OK] API Container App já existe" -ForegroundColor Green
    Write-Host "[INFO] Para adicionar volume, atualize manualmente via portal ou recrie o Container App" -ForegroundColor Yellow
}
Write-Host ""

# 10.5. Upload de documentos para Azure Files
Write-Host "[INFO] Verificando upload de documentos..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$localDocsPath = "DOC-IA"
if (Test-Path $localDocsPath) {
    Write-Host "[INFO] Fazendo upload de documentos para Azure Files..." -ForegroundColor Cyan
    
    # Listar arquivos existentes
    $existingFiles = az storage file list `
        --account-name $StorageAccount `
        --account-key $storageKey `
        --share-name $DocsFileShare `
        --query "[].name" -o tsv 2>$null
    
    if ($existingFiles) {
        Write-Host "[INFO] File Share já contém arquivos. Pulando upload." -ForegroundColor Yellow
        Write-Host "  Para re-upload, delete os arquivos manualmente ou use: az storage file delete-batch" -ForegroundColor Gray
    } else {
        # Upload dos documentos
        az storage file upload-batch `
            --account-name $StorageAccount `
            --account-key $storageKey `
            --source $localDocsPath `
            --destination $DocsFileShare 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Documentos enviados para Azure Files" -ForegroundColor Green
        } else {
            Write-Host "[AVISO] Falha ao fazer upload. Você pode fazer manualmente depois." -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "[AVISO] Diretório local '$localDocsPath' não encontrado. Pulando upload." -ForegroundColor Yellow
    Write-Host "  Faça upload manual depois usando: az storage file upload-batch" -ForegroundColor Gray
}
$ErrorActionPreference = "Stop"
Write-Host ""

# 11. Salvar deploy_state.json
Write-Host "[INFO] Salvando deploy_state.json..." -ForegroundColor Yellow
$stateDir = ".azure"
if (-not (Test-Path $stateDir)) {
    New-Item -ItemType Directory -Path $stateDir | Out-Null
}

$state = @{
    resourceGroup = $ResourceGroup
    location = $Location
    acrName = $AcrName
    keyVaultName = $KeyVault
    environmentName = $Environment
    apiAppName = $ApiApp
    qdrantAppName = $QdrantApp
    redisAppName = $RedisApp
    storageAccountName = $StorageAccount
    fileShareName = $FileShare
    subscriptionId = $subscriptionId
    tenantId = $tenantId
    createdAt = (Get-Date).ToString("o")
    updatedAt = (Get-Date).ToString("o")
}

$state | ConvertTo-Json -Depth 10 | Set-Content "$stateDir/deploy_state.json"
Write-Host "[OK] deploy_state.json salvo" -ForegroundColor Green
Write-Host ""

# 12. Obter URL da API
$ErrorActionPreference = "Continue"
$apiFqdn = az containerapp show --name $ApiApp --resource-group $ResourceGroup --query "properties.configuration.ingress.fqdn" -o tsv 2>$null
$ErrorActionPreference = "Stop"

Write-Host "=== Bootstrap Concluído! ===" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] URLs:" -ForegroundColor Cyan
if ($apiFqdn) {
    Write-Host "  API: https://$apiFqdn" -ForegroundColor Green
}
Write-Host "  Qdrant (interno): $qdrantUrl" -ForegroundColor Gray
Write-Host "  Redis (interno): $redisUrl" -ForegroundColor Gray
Write-Host ""
Write-Host "[INFO] Próximos passos:" -ForegroundColor Yellow
Write-Host "  1. Build e push da imagem da API para ACR" -ForegroundColor Gray
Write-Host "  2. Atualizar Container App com a nova imagem" -ForegroundColor Gray
Write-Host "  3. Configurar Managed Identity para Key Vault access" -ForegroundColor Gray
Write-Host ""
