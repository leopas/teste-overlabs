#!/bin/bash
# Script para atualizar apenas a Container App com nova imagem
# Uso: ./azure/update-app.sh <resource-group> <app-name> <acr-name>

set -e

RESOURCE_GROUP=${1:-rag-overlabs-rg}
APP_NAME=${2:-rag-overlabs-app}
ACR_NAME=${3:-ragoverlabsacr}

echo "🔄 Atualizando Container App: $APP_NAME"

# Build nova imagem
echo "🔨 Building new image..."
az acr build \
  --registry $ACR_NAME \
  --image rag-api:latest \
  --file backend/Dockerfile \
  . | Out-Null

# Atualizar Container App
echo "🚀 Updating container app..."
az containerapp update \
  --name $APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --image ${ACR_NAME}.azurecr.io/rag-api:latest

echo "✅ Atualização concluída!"
API_URL=$(az containerapp show --name $APP_NAME --resource-group $RESOURCE_GROUP --query properties.configuration.ingress.fqdn -o tsv)
echo "API URL: https://$API_URL"
