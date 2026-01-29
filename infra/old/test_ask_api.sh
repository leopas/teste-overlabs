#!/bin/bash
# Script para testar a API /ask no Azure
# Uso: ./infra/test_ask_api.sh "Qual é a política de reembolso?" staging

set -e

QUESTION="${1:-Qual é a política de reembolso?}"
SLOT="${2:-production}"

# Carregar deploy_state.json
if [ ! -f ".azure/deploy_state.json" ]; then
    echo "[ERRO] Arquivo .azure/deploy_state.json não encontrado" >&2
    exit 1
fi

WEB_APP=$(jq -r '.appServiceName' .azure/deploy_state.json)

# Construir URL
if [ "$SLOT" = "staging" ]; then
    BASE_URL="https://${WEB_APP}-staging.azurewebsites.net"
else
    BASE_URL="https://${WEB_APP}.azurewebsites.net"
fi

URL="${BASE_URL}/ask"

echo "=== Teste da API /ask ==="
echo ""
echo "[INFO] Testando endpoint: $URL"
echo "[INFO] Pergunta: $QUESTION"
echo ""

# Validar tamanho da pergunta
if [ ${#QUESTION} -lt 3 ]; then
    echo "[ERRO] A pergunta deve ter pelo menos 3 caracteres" >&2
    exit 1
fi

if [ ${#QUESTION} -gt 2000 ]; then
    echo "[ERRO] A pergunta deve ter no máximo 2000 caracteres" >&2
    exit 1
fi

# Criar payload JSON
PAYLOAD=$(jq -n --arg q "$QUESTION" '{question: $q}')

echo "[INFO] Enviando requisição..."
echo ""

# Executar curl
RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$PAYLOAD" \
    "$URL")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -eq 200 ]; then
    echo "[OK] Resposta recebida:"
    echo ""
    echo "$BODY" | jq '.'
    echo ""
    echo "[INFO] Resumo:"
    ANSWER=$(echo "$BODY" | jq -r '.answer')
    CONFIDENCE=$(echo "$BODY" | jq -r '.confidence')
    SOURCES_COUNT=$(echo "$BODY" | jq '.sources | length')
    echo "  Answer: ${ANSWER:0:100}..."
    echo "  Confidence: $CONFIDENCE"
    echo "  Sources: $SOURCES_COUNT"
else
    echo "[ERRO] Falha na requisição:" >&2
    echo "  Status Code: $HTTP_CODE" >&2
    echo "  Response: $BODY" >&2
    exit 1
fi

echo ""
echo "=== Teste Concluído ==="
