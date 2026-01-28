#!/bin/bash
# Script para aguardar readiness de uma revision do Azure Container App
# Faz polling verificando provisioningState, runningState e replicas
#
# Uso: wait_revision_ready.sh <APP_NAME> <RESOURCE_GROUP> <REVISION_NAME> [TIMEOUT]
#   APP_NAME: Nome do Container App
#   RESOURCE_GROUP: Resource Group
#   REVISION_NAME: Nome da revision a verificar
#   TIMEOUT: Timeout em segundos (default: 300)

set -e

APP_NAME=${1}
RESOURCE_GROUP=${2}
REVISION_NAME=${3}
TIMEOUT=${4:-300}

if [ -z "$APP_NAME" ] || [ -z "$RESOURCE_GROUP" ] || [ -z "$REVISION_NAME" ]; then
    echo "❌ Uso: $0 <APP_NAME> <RESOURCE_GROUP> <REVISION_NAME> [TIMEOUT]"
    exit 1
fi

echo "⏳ Aguardando revision '$REVISION_NAME' ficar pronta..."
echo "   App: $APP_NAME"
echo "   Resource Group: $RESOURCE_GROUP"
echo "   Timeout: ${TIMEOUT}s"
echo ""

START_TIME=$(date +%s)
POLL_INTERVAL=5
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
    # Verificar provisioning state
    PROV_STATE=$(az containerapp revision show \
        --name "$APP_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --revision "$REVISION_NAME" \
        --query "properties.provisioningState" -o tsv 2>/dev/null || echo "Unknown")
    
    # Verificar running state (pode não estar disponível imediatamente)
    RUN_STATE=$(az containerapp revision show \
        --name "$APP_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --revision "$REVISION_NAME" \
        --query "properties.runningState" -o tsv 2>/dev/null || echo "")
    
    # Verificar replicas (pode não estar disponível)
    REPLICAS_JSON=$(az containerapp revision show \
        --name "$APP_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --revision "$REVISION_NAME" \
        --query "properties.replicas" -o json 2>/dev/null || echo "[]")
    
    READY_REPLICAS=$(echo "$REPLICAS_JSON" | jq -r '[.[] | select(.runningState == "Running")] | length' 2>/dev/null || echo "0")
    TOTAL_REPLICAS=$(echo "$REPLICAS_JSON" | jq -r 'length' 2>/dev/null || echo "0")
    
    # Log do estado atual
    echo "  [${ELAPSED}s] Provisioning: $PROV_STATE | Running: ${RUN_STATE:-N/A} | Replicas: ${READY_REPLICAS}/${TOTAL_REPLICAS}"
    
    # Verificar se está pronto
    if [ "$PROV_STATE" = "Succeeded" ]; then
        # Se runningState está disponível, verificar também
        if [ -n "$RUN_STATE" ]; then
            if [ "$RUN_STATE" = "Running" ]; then
                # Se tem replicas configuradas, verificar se todas estão ready
                if [ "$TOTAL_REPLICAS" -gt 0 ]; then
                    if [ "$READY_REPLICAS" -eq "$TOTAL_REPLICAS" ]; then
                        echo ""
                        echo "✅ Revision '$REVISION_NAME' está pronta!"
                        echo "   Provisioning: $PROV_STATE"
                        echo "   Running: $RUN_STATE"
                        echo "   Replicas: $READY_REPLICAS/$TOTAL_REPLICAS"
                        exit 0
                    fi
                else
                    # Sem replicas configuradas, apenas provisioning state é suficiente
                    echo ""
                    echo "✅ Revision '$REVISION_NAME' está pronta!"
                    echo "   Provisioning: $PROV_STATE"
                    echo "   Running: $RUN_STATE"
                    exit 0
                fi
            fi
        else
            # Running state não disponível ainda, apenas provisioning state
            # Aguardar mais um pouco para running state aparecer
            if [ $ELAPSED -gt 10 ]; then
                echo ""
                echo "✅ Revision '$REVISION_NAME' está pronta (provisioning concluído)"
                echo "   Provisioning: $PROV_STATE"
                exit 0
            fi
        fi
    fi
    
    # Verificar se falhou
    if [ "$PROV_STATE" = "Failed" ]; then
        echo ""
        echo "❌ Revision '$REVISION_NAME' falhou no provisioning"
        exit 1
    fi
    
    sleep $POLL_INTERVAL
    ELAPSED=$(($(date +%s) - START_TIME))
done

echo ""
echo "❌ Timeout: Revision '$REVISION_NAME' não ficou pronta em ${TIMEOUT}s"
echo "   Último estado: Provisioning=$PROV_STATE, Running=${RUN_STATE:-N/A}"
exit 1
