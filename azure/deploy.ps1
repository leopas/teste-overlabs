# Script de deploy completo na Azure (PowerShell)
# Uso: .\azure\deploy.ps1 -ResourceGroup "rag-overlabs-rg" -Location "brazilsouth"

param(
    [string]$ResourceGroup = "rag-overlabs-rg",
    [string]$Location = "brazilsouth",
    [string]$AcrName = "ragoverlabsacr",
    [string]$AppName = "rag-overlabs-app",
    [string]$Environment = "rag-overlabs-env"
)

$ErrorActionPreference = "Stop"

Write-Host "🚀 Deploying RAG system to Azure..." -ForegroundColor Green
Write-Host "Resource Group: $ResourceGroup"
Write-Host "Location: $Location"
Write-Host "ACR: $AcrName"
Write-Host "App: $AppName"

# 1. Criar Resource Group
Write-Host "`n📦 Creating resource group..." -ForegroundColor Yellow
az group create --name $ResourceGroup --location $Location | Out-Null

# 2. Criar Azure Container Registry
Write-Host "🐳 Creating Azure Container Registry..." -ForegroundColor Yellow
az acr create `
  --resource-group $ResourceGroup `
  --name $AcrName `
  --sku Basic `
  --admin-enabled true | Out-Null

# 3. Build e push das imagens
Write-Host "🔨 Building and pushing images..." -ForegroundColor Yellow
$AcrLoginServer = az acr show --name $AcrName --query loginServer -o tsv

# Build API image
Write-Host "Building API image..." -ForegroundColor Cyan
az acr build `
  --registry $AcrName `
  --image rag-api:latest `
  --file backend/Dockerfile `
  . | Out-Null

# 4. Criar Azure Redis Cache
Write-Host "💾 Creating Azure Redis Cache..." -ForegroundColor Yellow
az redis create `
  --resource-group $ResourceGroup `
  --name "$AppName-redis" `
  --location $Location `
  --sku Basic `
  --vm-size c0 | Out-Null

# 5. Criar Azure Database for MySQL (Flexible Server)
Write-Host "🗄️ Creating Azure Database for MySQL..." -ForegroundColor Yellow
$MysqlServerName = "$AppName-mysql"
$MysqlAdminUser = "ragadmin"
$MysqlAdminPassword = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 25 | ForEach-Object {[char]$_})

az mysql flexible-server create `
  --resource-group $ResourceGroup `
  --name $MysqlServerName `
  --location $Location `
  --admin-user $MysqlAdminUser `
  --admin-password $MysqlAdminPassword `
  --sku-name Standard_B1ms `
  --tier Burstable `
  --public-access 0.0.0.0 `
  --storage-size 32 `
  --version 8.0.21 | Out-Null

# Criar database
az mysql flexible-server db create `
  --resource-group $ResourceGroup `
  --server-name $MysqlServerName `
  --database-name rag_audit | Out-Null

# 6. Criar Azure Container Apps Environment
Write-Host "🌐 Creating Container Apps Environment..." -ForegroundColor Yellow
az containerapp env create `
  --name $Environment `
  --resource-group $ResourceGroup `
  --location $Location | Out-Null

# 7. Obter credenciais
$RedisHost = az redis show --resource-group $ResourceGroup --name "$AppName-redis" --query hostName -o tsv
$RedisPort = az redis show --resource-group $ResourceGroup --name "$AppName-redis" --query port -o tsv
$RedisKey = az redis list-keys --resource-group $ResourceGroup --name "$AppName-redis" --query primaryKey -o tsv
$RedisUrl = "rediss://:$RedisKey@${RedisHost}:${RedisPort}/0"

$MysqlFqdn = az mysql flexible-server show --resource-group $ResourceGroup --name $MysqlServerName --query fullyQualifiedDomainName -o tsv
$AcrUsername = az acr credential show --name $AcrName --query username -o tsv
$AcrPassword = az acr credential show --name $AcrName --query passwords[0].value -o tsv

# 8. Deploy Qdrant container app
Write-Host "🔍 Deploying Qdrant..." -ForegroundColor Yellow
az containerapp create `
  --name "$AppName-qdrant" `
  --resource-group $ResourceGroup `
  --environment $Environment `
  --image qdrant/qdrant:latest `
  --target-port 6333 `
  --ingress external `
  --cpu 1.0 `
  --memory 2.0Gi `
  --min-replicas 1 `
  --max-replicas 1 `
  --env-vars "QDRANT__SERVICE__GRPC_PORT=6334" | Out-Null

$QdrantFqdn = az containerapp show --name "$AppName-qdrant" --resource-group $ResourceGroup --query properties.configuration.ingress.fqdn -o tsv
$QdrantUrl = "http://${QdrantFqdn}:6333"

# 9. Deploy API container app
Write-Host "🚀 Deploying API..." -ForegroundColor Yellow
az containerapp create `
  --name $AppName `
  --resource-group $ResourceGroup `
  --environment $Environment `
  --image "${AcrLoginServer}/rag-api:latest" `
  --registry-server $AcrLoginServer `
  --registry-username $AcrUsername `
  --registry-password $AcrPassword `
  --target-port 8000 `
  --ingress external `
  --cpu 2.0 `
  --memory 4.0Gi `
  --min-replicas 1 `
  --max-replicas 5 `
  --env-vars `
    "QDRANT_URL=$QdrantUrl" `
    "REDIS_URL=$RedisUrl" `
    "DOCS_ROOT=/docs" `
    "MYSQL_HOST=$MysqlFqdn" `
    "MYSQL_PORT=3306" `
    "MYSQL_USER=$MysqlAdminUser" `
    "MYSQL_PASSWORD=$MysqlAdminPassword" `
    "MYSQL_DATABASE=rag_audit" `
    "MYSQL_SSL_CA=/app/certs/DigiCertGlobalRootCA.crt.pem" `
    "TRACE_SINK=mysql" `
    "AUDIT_LOG_ENABLED=1" `
    "AUDIT_LOG_INCLUDE_TEXT=1" `
    "AUDIT_LOG_RAW_MODE=risk_only" `
    "ABUSE_CLASSIFIER_ENABLED=1" `
    "PROMPT_FIREWALL_ENABLED=0" `
    "LOG_LEVEL=INFO" | Out-Null

# 10. Obter URL da API
$ApiFqdn = az containerapp show --name $AppName --resource-group $ResourceGroup --query properties.configuration.ingress.fqdn -o tsv

Write-Host ""
Write-Host "✅ Deploy concluído!" -ForegroundColor Green
Write-Host ""
Write-Host "📋 Informações importantes:" -ForegroundColor Cyan
Write-Host "   API URL: https://$ApiFqdn"
Write-Host "   Qdrant URL: $QdrantUrl"
Write-Host "   MySQL Server: $MysqlFqdn"
Write-Host "   MySQL User: $MysqlAdminUser"
Write-Host "   MySQL Password: $MysqlAdminPassword (salve em Key Vault!)"
Write-Host ""
Write-Host "⚠️  PRÓXIMOS PASSOS:" -ForegroundColor Yellow
Write-Host "   1. Aplicar schema SQL: mysql -h $MysqlFqdn -u $MysqlAdminUser -p < docs/db_audit_schema.sql"
Write-Host "   2. Configurar secrets no Key Vault (OPENAI_API_KEY, AUDIT_ENC_KEY_B64, etc.)"
Write-Host "   3. Upload dos documentos para Azure Storage e montar como volume"
Write-Host "   4. Executar scan_docs e ingest dentro do container"
Write-Host ""
