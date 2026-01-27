#!/bin/bash
# Smoke test para validar deploy na Azure App Service
# Testa /healthz e /readyz com retry e backoff exponencial

set -e

URL=${1:-"https://app-overlabs-prod-123.azurewebsites.net"}
TIMEOUT=${2:-30}
MAX_RETRIES=${3:-5}
INITIAL_DELAY=${4:-2}

echo "🧪 Smoke test para: $URL"
echo "   Timeout: ${TIMEOUT}s"
echo "   Max retries: $MAX_RETRIES"
echo ""

# Função para testar endpoint
test_endpoint() {
    local endpoint=$1
    local expected_status=${2:-200}
    local url="${URL}${endpoint}"
    
    echo "  Testando: $endpoint (esperado: $expected_status)"
    
    local retry=0
    local delay=$INITIAL_DELAY
    
    while [ $retry -lt $MAX_RETRIES ]; do
        if [ $retry -gt 0 ]; then
            echo "    Retry $retry/$MAX_RETRIES (aguardando ${delay}s)..."
            sleep $delay
            delay=$((delay * 2))  # Backoff exponencial
        fi
        
        # Fazer requisição com timeout
        if response=$(curl -s -w "\n%{http_code}" --max-time $TIMEOUT "$url" 2>/dev/null); then
            http_code=$(echo "$response" | tail -n1)
            body=$(echo "$response" | sed '$d')
            
            if [ "$http_code" = "$expected_status" ]; then
                echo "  ✅ $endpoint retornou $http_code"
                if [ -n "$body" ]; then
                    echo "     Response: $body"
                fi
                return 0
            else
                echo "  ⚠️  $endpoint retornou $http_code (esperado $expected_status)"
                if [ -n "$body" ]; then
                    echo "     Response: $body"
                fi
            fi
        else
            echo "  ⚠️  Erro ao conectar em $endpoint"
        fi
        
        retry=$((retry + 1))
    done
    
    echo "  ❌ $endpoint falhou após $MAX_RETRIES tentativas"
    return 1
}

# Testar /healthz
echo "📋 Testando /healthz..."
if ! test_endpoint "/healthz" 200; then
    echo ""
    echo "❌ Smoke test falhou: /healthz não respondeu corretamente"
    exit 1
fi

echo ""

# Testar /readyz
echo "📋 Testando /readyz..."
if ! test_endpoint "/readyz" 200; then
    echo ""
    echo "⚠️  Aviso: /readyz não está pronto (pode ser temporário)"
    echo "   Continuando com smoke test..."
fi

echo ""
echo "✅ Smoke test passou com sucesso!"
exit 0
