#!/bin/bash
# Script de deploy completo na Azure
# Uso: ./azure/deploy.sh <resource-group> <location> <acr-name>

set -e

RESOURCE_GROUP=${1:-rag-overlabs-rg}
LOCATION=${2:-brazilsouth}
ACR_NAME=${3:-ragoverlabsacr}
APP_NAME=${4:-rag-overlabs-app}
ENVIRONMENT=${5:-rag-overlabs-env}

echo "🚀 Deploying RAG system to Azure..."
echo "Resource Group: $RESOURCE_GROUP"
echo "Location: $LOCATION"
echo "ACR: $ACR_NAME"
echo "App: $APP_NAME"

# 1. Criar Resource Group
echo "📦 Creating resource group..."
az group create --name $RESOURCE_GROUP --location $LOCATION

# 2. Criar Azure Container Registry
echo "🐳 Creating Azure Container Registry..."
az acr create \
  --resource-group $RESOURCE_GROUP \
  --name $ACR_NAME \
  --sku Basic \
  --admin-enabled true

# 3. Build e push das imagens
echo "🔨 Building and pushing images..."
ACR_LOGIN_SERVER=$(az acr show --name $ACR_NAME --query loginServer -o tsv)

# Build API image
echo "Building API image..."
az acr build \
  --registry $ACR_NAME \
  --image rag-api:latest \
  --file backend/Dockerfile \
  .

# Build Qdrant (usar imagem oficial)
echo "Using official Qdrant image..."
# Qdrant será usado diretamente da imagem oficial

# 4. Criar Azure Redis Cache
echo "💾 Creating Azure Redis Cache..."
az redis create \
  --resource-group $RESOURCE_GROUP \
  --name ${APP_NAME}-redis \
  --location $LOCATION \
  --sku Basic \
  --vm-size c0

# 5. Criar Azure Database for MySQL (Flexible Server)
echo "🗄️ Creating Azure Database for MySQL..."
MYSQL_SERVER_NAME="${APP_NAME}-mysql"
MYSQL_ADMIN_USER="ragadmin"
MYSQL_ADMIN_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)

az mysql flexible-server create \
  --resource-group $RESOURCE_GROUP \
  --name $MYSQL_SERVER_NAME \
  --location $LOCATION \
  --admin-user $MYSQL_ADMIN_USER \
  --admin-password $MYSQL_ADMIN_PASSWORD \
  --sku-name Standard_B1ms \
  --tier Burstable \
  --public-access 0.0.0.0 \
  --storage-size 32 \
  --version 8.0.21

# Criar database
az mysql flexible-server db create \
  --resource-group $RESOURCE_GROUP \
  --server-name $MYSQL_SERVER_NAME \
  --database-name rag_audit

# 6. Criar Azure Container Apps Environment
echo "🌐 Creating Container Apps Environment..."
az containerapp env create \
  --name $ENVIRONMENT \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION

# 7. Obter credenciais
REDIS_HOST=$(az redis show --resource-group $RESOURCE_GROUP --name ${APP_NAME}-redis --query hostName -o tsv)
REDIS_PORT=$(az redis show --resource-group $RESOURCE_GROUP --name ${APP_NAME}-redis --query port -o tsv)
REDIS_KEY=$(az redis list-keys --resource-group $RESOURCE_GROUP --name ${APP_NAME}-redis --query primaryKey -o tsv)
REDIS_URL="rediss://:$REDIS_KEY@$REDIS_HOST:$REDIS_PORT/0"

MYSQL_FQDN=$(az mysql flexible-server show --resource-group $RESOURCE_GROUP --name $MYSQL_SERVER_NAME --query fullyQualifiedDomainName -o tsv)
ACR_USERNAME=$(az acr credential show --name $ACR_NAME --query username -o tsv)
ACR_PASSWORD=$(az acr credential show --name $ACR_NAME --query passwords[0].value -o tsv)

# 8. Deploy Qdrant container app
echo "🔍 Deploying Qdrant..."
az containerapp create \
  --name ${APP_NAME}-qdrant \
  --resource-group $RESOURCE_GROUP \
  --environment $ENVIRONMENT \
  --image qdrant/qdrant:latest \
  --target-port 6333 \
  --ingress external \
  --cpu 1.0 \
  --memory 2.0Gi \
  --min-replicas 1 \
  --max-replicas 1 \
  --env-vars "QDRANT__SERVICE__GRPC_PORT=6334"

QDRANT_URL=$(az containerapp show --name ${APP_NAME}-qdrant --resource-group $RESOURCE_GROUP --query properties.configuration.ingress.fqdn -o tsv)
QDRANT_URL="http://${QDRANT_URL}:6333"

# 9. Deploy API container app
echo "🚀 Deploying API..."
az containerapp create \
  --name $APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --environment $ENVIRONMENT \
  --image ${ACR_LOGIN_SERVER}/rag-api:latest \
  --registry-server $ACR_LOGIN_SERVER \
  --registry-username $ACR_USERNAME \
  --registry-password $ACR_PASSWORD \
  --target-port 8000 \
  --ingress external \
  --cpu 2.0 \
  --memory 4.0Gi \
  --min-replicas 1 \
  --max-replicas 5 \
  --env-vars \
    "QDRANT_URL=$QDRANT_URL" \
    "REDIS_URL=$REDIS_URL" \
    "DOCS_ROOT=/docs" \
    "MYSQL_HOST=$MYSQL_FQDN" \
    "MYSQL_PORT=3306" \
    "MYSQL_USER=$MYSQL_ADMIN_USER" \
    "MYSQL_PASSWORD=$MYSQL_ADMIN_PASSWORD" \
    "MYSQL_DATABASE=rag_audit" \
    "MYSQL_SSL_CA=/app/certs/DigiCertGlobalRootCA.crt.pem" \
    "TRACE_SINK=mysql" \
    "AUDIT_LOG_ENABLED=1" \
    "AUDIT_LOG_INCLUDE_TEXT=1" \
    "AUDIT_LOG_RAW_MODE=risk_only" \
    "ABUSE_CLASSIFIER_ENABLED=1" \
    "PROMPT_FIREWALL_ENABLED=0" \
    "LOG_LEVEL=INFO"

# 10. Obter URL da API
API_URL=$(az containerapp show --name $APP_NAME --resource-group $RESOURCE_GROUP --query properties.configuration.ingress.fqdn -o tsv)

echo ""
echo "✅ Deploy concluído!"
echo ""
echo "📋 Informações importantes:"
echo "   API URL: https://$API_URL"
echo "   Qdrant URL: $QDRANT_URL"
echo "   MySQL Server: $MYSQL_FQDN"
echo "   MySQL User: $MYSQL_ADMIN_USER"
echo "   MySQL Password: $MYSQL_ADMIN_PASSWORD (salve em Key Vault!)"
echo ""
echo "⚠️  PRÓXIMOS PASSOS:"
echo "   1. Aplicar schema SQL: mysql -h $MYSQL_FQDN -u $MYSQL_ADMIN_USER -p < docs/db_audit_schema.sql"
echo "   2. Configurar secrets no Key Vault (OPENAI_API_KEY, AUDIT_ENC_KEY_B64, etc.)"
echo "   3. Upload dos documentos para Azure Storage e montar como volume"
echo "   4. Executar scan_docs e ingest dentro do container"
echo ""
