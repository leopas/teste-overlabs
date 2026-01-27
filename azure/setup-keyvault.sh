#!/bin/bash
# Script para configurar Azure Key Vault e adicionar secrets
# Uso: ./azure/setup-keyvault.sh <resource-group> <keyvault-name>

set -e

RESOURCE_GROUP=${1:-rag-overlabs-rg}
KV_NAME=${2:-rag-overlabs-kv}

echo "🔐 Configurando Azure Key Vault: $KV_NAME"

# Criar Key Vault (se não existir)
if ! az keyvault show --name $KV_NAME --resource-group $RESOURCE_GROUP &>/dev/null; then
  echo "📦 Criando Key Vault..."
  az keyvault create \
    --name $KV_NAME \
    --resource-group $RESOURCE_GROUP \
    --location brazilsouth \
    --sku standard
else
  echo "✅ Key Vault já existe"
fi

echo ""
echo "📝 Adicione seus secrets:"
echo ""
echo "  # OpenAI API Key"
echo "  az keyvault secret set --vault-name $KV_NAME --name OpenAIApiKey --value '<sua-chave>'"
echo ""
echo "  # Audit Encryption Key (32 bytes base64)"
echo "  python -c \"import os,base64; print(base64.b64encode(os.urandom(32)).decode())\""
echo "  az keyvault secret set --vault-name $KV_NAME --name AuditEncKey --value '<chave-gerada>'"
echo ""
echo "  # MySQL Password (se necessário)"
echo "  az keyvault secret set --vault-name $KV_NAME --name MysqlPassword --value '<senha>'"
echo ""
echo "🔗 Para usar no Container App:"
echo "  az containerapp update --name rag-overlabs-app --resource-group $RESOURCE_GROUP \\"
echo "    --set-env-vars \\"
echo "      'OPENAI_API_KEY=@Microsoft.KeyVault(SecretUri=https://$KV_NAME.vault.azure.net/secrets/OpenAIApiKey/)' \\"
echo "      'AUDIT_ENC_KEY_B64=@Microsoft.KeyVault(SecretUri=https://$KV_NAME.vault.azure.net/secrets/AuditEncKey/)'"
echo ""
