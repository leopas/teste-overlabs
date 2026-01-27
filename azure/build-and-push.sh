#!/bin/bash
# Script para build e push da imagem para ACR
# Uso: ./azure/build-and-push.sh <acr-name>

set -e

ACR_NAME=${1:-ragoverlabsacr}

if [ -z "$ACR_NAME" ]; then
  echo "❌ Erro: Nome do ACR é obrigatório"
  echo "Uso: ./azure/build-and-push.sh <acr-name>"
  exit 1
fi

echo "🔨 Building and pushing to ACR: $ACR_NAME"

# Login no ACR (se necessário)
az acr login --name $ACR_NAME

# Build e push
az acr build \
  --registry $ACR_NAME \
  --image rag-api:latest \
  --image rag-api:$(date +%Y%m%d-%H%M%S) \
  --file backend/Dockerfile \
  .

echo "✅ Build concluído!"
echo "Imagem: $ACR_NAME.azurecr.io/rag-api:latest"
