#!/bin/bash
# Script para fazer rollback automático para uma revision anterior
# Restaura 100% do tráfego para a revision especificada
#
# Uso: rollback_revision.sh <APP_NAME> <RESOURCE_GROUP> <PREV_REVISION>
#   APP_NAME: Nome do Container App
#   RESOURCE_GROUP: Resource Group
#   PREV_REVISION: Nome da revision anterior para restaurar

set -e

APP_NAME=${1}
RESOURCE_GROUP=${2}
PREV_REVISION=${3}

if [ -z "$APP_NAME" ] || [ -z "$RESOURCE_GROUP" ] || [ -z "$PREV_REVISION" ]; then
    echo "❌ Uso: $0 <APP_NAME> <RESOURCE_GROUP> <PREV_REVISION>"
    exit 1
fi

echo "🔄 Executando rollback para revision anterior..."
echo "   App: $APP_NAME"
echo "   Resource Group: $RESOURCE_GROUP"
echo "   Revision de destino: $PREV_REVISION"
echo ""

# Verificar se a revision existe
REV_EXISTS=$(az containerapp revision show \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --revision "$PREV_REVISION" \
    --query "name" -o tsv 2>/dev/null || echo "")

if [ -z "$REV_EXISTS" ]; then
    echo "❌ Revision '$PREV_REVISION' não encontrada"
    exit 1
fi

# Restaurar 100% do tráfego para a revision anterior
echo "  Restaurando 100% do tráfego para '$PREV_REVISION'..."
az containerapp ingress traffic set \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --revision-weight "${PREV_REVISION}=100" 2>&1

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Rollback concluído com sucesso!"
    echo "   Tráfego restaurado para: $PREV_REVISION"
    
    # Registrar no summary do GitHub Actions (se disponível)
    if [ -n "$GITHUB_STEP_SUMMARY" ]; then
        echo "## 🔄 Rollback Executado" >> "$GITHUB_STEP_SUMMARY"
        echo "" >> "$GITHUB_STEP_SUMMARY"
        echo "**Motivo**: Smoke test falhou" >> "$GITHUB_STEP_SUMMARY"
        echo "**Revision restaurada**: \`$PREV_REVISION\`" >> "$GITHUB_STEP_SUMMARY"
        echo "**Tráfego**: 100%" >> "$GITHUB_STEP_SUMMARY"
        echo "" >> "$GITHUB_STEP_SUMMARY"
    fi
else
    echo ""
    echo "❌ Falha ao executar rollback"
    exit 1
fi
