# API Reference

Referência completa dos endpoints da API FastAPI.

## Base URL

- **Local**: `http://localhost:8000`
- **Produção**: `https://<fqdn-do-container-app>`

## Endpoints

### `GET /healthz`

Endpoint de liveness (health check básico).

**Resposta**:
```json
{
  "status": "ok"
}
```

**Status Code**: `200`

**Uso**: Verificar se a API está rodando (não verifica dependências).

---

### `GET /readyz`

Endpoint de readiness (verifica dependências).

**Resposta**:
```json
{
  "redis": true,
  "qdrant": true
}
```

**Status Codes**:
- `200`: Tudo OK (Redis e Qdrant acessíveis)
- `503`: Alguma dependência indisponível

**Uso**: Verificar se a API está pronta para receber requests (verifica Redis e Qdrant).

---

### `GET /metrics`

Endpoint de métricas Prometheus.

**Resposta**: Texto no formato Prometheus

**Status Code**: `200`

**Métricas Disponíveis**:
- `request_count`: Contador de requests por endpoint e status
- `cache_hit_count`: Contador de cache hits
- `refusal_count`: Contador de recusas por motivo
- `request_latency_seconds`: Histograma de latência
- `llm_errors`: Contador de erros do LLM
- `firewall_*`: Métricas do Prompt Firewall (quando habilitado)

**Uso**: Integração com Prometheus/Grafana para monitoramento.

---

### `POST /ask`

Endpoint principal para fazer perguntas ao sistema RAG.

**Request Body**:
```json
{
  "question": "Qual o prazo para reembolso de despesas nacionais?"
}
```

**Validação**:
- `question`: String, 3-2000 caracteres, sem caracteres de controle

**Response Headers**:
- `X-Request-ID`: ID único da request
- `X-Trace-ID`: ID único do trace (correlaciona com audit)
- `X-Answer-Source`: Origem da resposta (`CACHE`, `LLM`, ou `REFUSAL`)
- `X-Chat-Session-ID`: ID da sessão de chat (persistido entre requests)

**Response Body**:
```json
{
  "answer": "O prazo para reembolso de despesas nacionais é de 30 dias corridos...",
  "confidence": 0.85,
  "sources": [
    {
      "document": "politica-reembolso-v3.txt",
      "excerpt": "Prazo de reembolso: 30 dias corridos para despesas nacionais..."
    }
  ]
}
```

**Resposta de Recusa**:
```json
{
  "answer": "Não encontrei informações confiáveis para responder essa pergunta.",
  "confidence": 0.2,
  "sources": []
}
```

**Status Code**: `200` (sempre, mesmo em recusa)

**Motivos de Recusa**:
- `input_invalid`: Input inválido
- `guardrail_injection`: Detecção de prompt injection
- `guardrail_sensitive`: Detecção de informação sensível/PII
- `guardrail_firewall`: Bloqueado pelo Prompt Firewall
- `rate_limited`: Rate limit excedido
- `cache_error`: Erro no cache
- `qdrant_unavailable`: Qdrant indisponível
- `no_evidence`: Sem evidência suficiente
- `conflict_unresolved`: Conflito irresolúvel
- `quality_threshold`: Confiança abaixo do threshold (0.65)
- `quality_crosscheck_failed`: Validação cruzada falhou
- `quality_post_validation_failed`: Pós-validação falhou
- `llm_error`: Erro no LLM

**Exemplo com curl**:
```bash
curl -X POST http://localhost:8000/ask \
  -H "Content-Type: application/json" \
  -d '{"question": "Qual o prazo para reembolso?"}'
```

**Exemplo com Python**:
```python
import httpx

response = httpx.post(
    "http://localhost:8000/ask",
    json={"question": "Qual o prazo para reembolso?"}
)

data = response.json()
print(f"Resposta: {data['answer']}")
print(f"Confiança: {data['confidence']}")
print(f"Fontes: {len(data['sources'])}")
print(f"Trace ID: {response.headers['X-Trace-ID']}")
print(f"Answer Source: {response.headers['X-Answer-Source']}")
```

**Exemplo com Session ID**:
```python
import httpx

# Primeira chamada (gera session_id)
response1 = httpx.post(
    "http://localhost:8000/ask",
    json={"question": "Qual o prazo?"}
)
session_id = response1.headers["X-Chat-Session-ID"]

# Segunda chamada (reutiliza session_id)
response2 = httpx.post(
    "http://localhost:8000/ask",
    json={"question": "E para despesas internacionais?"},
    headers={"X-Chat-Session-ID": session_id}
)
# session_id será o mesmo
```

---

### `GET /docs`

Swagger UI interativo (FastAPI automático).

**Acesso**: http://localhost:8000/docs

**Uso**: Interface web para testar os endpoints.

---

### `GET /openapi.json`

Especificação OpenAPI (JSON).

**Acesso**: http://localhost:8000/openapi.json

**Uso**: Integração com ferramentas de documentação ou clientes gerados.

---

## Headers de Request

### `X-Chat-Session-ID` (opcional)

ID da sessão de chat. Se não fornecido, um novo ID é gerado.

**Uso**: Manter contexto entre múltiplas perguntas na mesma sessão.

**Exemplo**:
```bash
curl -X POST http://localhost:8000/ask \
  -H "Content-Type: application/json" \
  -H "X-Chat-Session-ID: abc123" \
  -d '{"question": "Qual o prazo?"}'
```

### `Authorization` (opcional)

Bearer token JWT com claim `user_id`.

**Uso**: Identificar o usuário para audit logging.

**Exemplo**:
```bash
curl -X POST http://localhost:8000/ask \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{"question": "Qual o prazo?"}'
```

---

## Headers de Response

### `X-Request-ID`

ID único da request (gerado automaticamente).

**Uso**: Correlacionar logs e traces.

### `X-Trace-ID`

ID único do trace (correlaciona com audit logging).

**Uso**: Buscar no banco de audit para rastreabilidade completa.

### `X-Answer-Source`

Origem da resposta:
- `CACHE`: Resposta veio do cache Redis
- `LLM`: Resposta gerada pelo LLM
- `REFUSAL`: Resposta de recusa padrão

**Uso**: Entender de onde veio a resposta para análise de performance.

### `X-Chat-Session-ID`

ID da sessão de chat (persistido entre requests).

**Uso**: Reutilizar em requests subsequentes para manter contexto.

---

## Códigos de Status

| Código | Significado |
|--------|-------------|
| `200` | Sucesso (inclui recusas) |
| `422` | Erro de validação (input inválido) |
| `503` | Service Unavailable (apenas `/readyz`) |

**Nota**: O endpoint `/ask` sempre retorna `200`, mesmo em recusas. O motivo da recusa está no campo `sources` (vazio) e `confidence` (baixo).

---

## Rate Limiting

Rate limiting por IP via Redis.

**Limite padrão**: 60 requests por minuto (`RATE_LIMIT_PER_MINUTE`)

**Quando excedido**: Resposta de recusa com `rate_limited`.

---

## Cache

Cache de respostas via Redis.

**Chave**: SHA256 da pergunta normalizada

**TTL**: 10 minutos (600 segundos, `CACHE_TTL_SECONDS`)

**Como funciona**:
1. Pergunta é normalizada (strip, lower, collapse whitespace)
2. Hash SHA256 é calculado
3. Se existe no Redis, retorna resposta cached (`X-Answer-Source: CACHE`)
4. Se não existe, processa normalmente e salva no cache

---

## Erros Comuns

### `422 Unprocessable Entity`

**Causa**: Input inválido (pergunta muito curta/longa ou com caracteres de controle)

**Solução**: Validar input antes de enviar

### `503 Service Unavailable` (apenas `/readyz`)

**Causa**: Redis ou Qdrant indisponíveis

**Solução**: Verificar se os serviços estão rodando

### Resposta de Recusa

**Causa**: Vários motivos possíveis (ver seção "Motivos de Recusa")

**Solução**: Verificar logs e audit para entender o motivo específico

---

## Exemplos Completos

### Exemplo 1: Pergunta Simples

```bash
curl -X POST http://localhost:8000/ask \
  -H "Content-Type: application/json" \
  -d '{"question": "Qual o prazo para reembolso de despesas nacionais?"}'
```

**Resposta esperada**:
```json
{
  "answer": "O prazo para reembolso de despesas nacionais é de 30 dias corridos...",
  "confidence": 0.85,
  "sources": [...]
}
```

### Exemplo 2: Pergunta que Resulta em Recusa

```bash
curl -X POST http://localhost:8000/ask \
  -H "Content-Type: application/json" \
  -d '{"question": "Qual é o CPF da Maria Oliveira?"}'
```

**Resposta esperada**:
```json
{
  "answer": "Não encontrei informações confiáveis para responder essa pergunta.",
  "confidence": 0.2,
  "sources": []
}
```

### Exemplo 3: Com Session ID

```python
import httpx

client = httpx.Client()
session_id = None

# Primeira pergunta
response1 = client.post(
    "http://localhost:8000/ask",
    json={"question": "Qual o prazo?"}
)
session_id = response1.headers["X-Chat-Session-ID"]
print(f"Session: {session_id}")

# Segunda pergunta (mesma sessão)
response2 = client.post(
    "http://localhost:8000/ask",
    json={"question": "E para despesas internacionais?"},
    headers={"X-Chat-Session-ID": session_id}
)
print(f"Session mantida: {response2.headers['X-Chat-Session-ID'] == session_id}")
```

---

## Integração com Swagger UI

Acesse http://localhost:8000/docs para:
- Ver todos os endpoints
- Testar interativamente
- Ver schemas de request/response
- Gerar código de exemplo

---

## Referências

- [FastAPI Documentation](https://fastapi.tiangolo.com/)
- [OpenAPI Specification](https://swagger.io/specification/)
- [Arquitetura do Sistema](architecture.md)
- [Observability](observability.md) - Logs e métricas
