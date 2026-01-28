# Custo, Performance e Resiliência

Como o sistema reduz custos, melhora performance e lida com falhas.

## Cache

### Implementação

**Arquivo**: [`backend/app/cache.py`](backend/app/cache.py) (linhas 12-37)

```python
def cache_key_for_question(normalized_question: str) -> str:
    return hashlib.sha256(normalized_question.encode("utf-8")).hexdigest()

class RedisClient:
    def get_json(self, key: str) -> Any | None:
        raw = self._client.get(key)
        if raw is None:
            return None
        return json.loads(raw)

    def set_json(self, key: str, value: Any, ttl_seconds: int) -> None:
        self._client.setex(key, ttl_seconds, json.dumps(value, ensure_ascii=False))
```

### Como funciona

1. **Chave**: SHA256 da pergunta normalizada (strip, lower, collapse whitespace)
2. **TTL**: 600 segundos (10 minutos), configurável via `CACHE_TTL_SECONDS`
3. **Valor**: Resposta completa (answer, confidence, sources) em JSON
4. **Hit**: Retorna imediatamente, não chama Qdrant nem LLM
5. **Miss**: Processa normalmente e salva no cache

**Normalização**: [`backend/app/security.py`](backend/app/security.py) (linhas 34-41)

**Uso**: [`backend/app/main.py`](backend/app/main.py) (linha 380)

### Redução de Custo

- **Evita chamadas ao LLM**: Perguntas repetidas não geram custo de API
- **Evita chamadas ao Qdrant**: Não faz retrieval para perguntas já respondidas
- **Reduz latência**: Resposta instantânea (Redis é rápido)

**Header de resposta**: `X-Answer-Source: CACHE` quando vem do cache

---

## Rate Limiting

### Implementação

**Arquivo**: [`backend/app/cache.py`](backend/app/cache.py) (linhas 39-50)

```python
def rate_limit_allow(self, ip: str, limit_per_minute: int) -> bool:
    epoch_min = int(time.time() // 60)
    key = f"rl:{ip}:{epochMinute}"
    pipe = self._client.pipeline()
    pipe.incr(key, 1)
    pipe.expire(key, 70)
    count, _ = pipe.execute()
    return int(count) <= int(limit_per_minute)
```

### Como funciona

- **Limite padrão**: 60 requests/minuto por IP
- **Chave Redis**: `rl:<ip>:<epochMinute>`
- **Janela**: Fixa por minuto (não sliding window)
- **Ação**: Se excedido, recusa com motivo `rate_limited`

**Uso**: [`backend/app/main.py`](backend/app/main.py) (linha 274)

### Redução de Custo

- **Limita abuso**: Previne uso excessivo da API
- **Protege recursos**: Reduz carga no Qdrant e LLM
- **Configurável**: `RATE_LIMIT_PER_MINUTE` no `.env`

---

## Resiliência

### Qdrant/Redis Indisponíveis

**Arquivo**: [`backend/app/main.py`](backend/app/main.py) (linhas 118-134)

```python
@app.get("/readyz")
async def readyz() -> JSONResponse:
    cache = app.state.cache
    retriever = app.state.retriever
    ok_redis = False
    ok_qdrant = False
    try:
        ok_redis = cache.ping()
    except Exception:
        ok_redis = False
    try:
        ok_qdrant = retriever.ready()
    except Exception:
        ok_qdrant = False

    status = 200 if (ok_redis and ok_qdrant) else 503
    return JSONResponse(status_code=status, content={"redis": ok_redis, "qdrant": ok_qdrant})
```

**Comportamento**:
- `/readyz` retorna 503 se Qdrant ou Redis estiverem indisponíveis
- `/ask` **não quebra**: Retorna recusa padrão se Qdrant/Redis falharem

### Timeouts

**Redis**: [`backend/app/cache.py`](backend/app/cache.py) (linha 25)
- `socket_connect_timeout=1.0`
- `socket_timeout=1.0`
- Falha silenciosa (não quebra o endpoint)

**Qdrant**: [`backend/app/retrieval.py`](backend/app/retrieval.py) (linha 89)
- `timeout=2.0`
- Falha silenciosa (retorna recusa)

**OpenAI**: [`backend/app/retrieval.py`](backend/app/retrieval.py) (linha 64), [`backend/app/llm.py`](backend/app/llm.py) (linha 48)
- `timeout=15.0`
- Se falhar, retorna recusa

### Fallback LLM

**Arquivo**: [`backend/app/llm.py`](backend/app/llm.py) (linhas 35-42)

Se `OPENAI_API_KEY` não estiver configurada, usa stub determinístico:
- Não gera respostas reais
- Retorna recusa padrão
- Útil para desenvolvimento local sem custo

---

## Otimizações de Performance

### Embeddings Locais

**Arquivo**: [`backend/app/retrieval.py`](backend/app/retrieval.py) (linhas 36-58)

- **Modelo**: `sentence-transformers/all-MiniLM-L6-v2` (384 dims)
- **ONNX**: Evita Torch/CUDA no container
- **Custo**: Zero (local, sem API calls)
- **Trade-off**: Qualidade inferior a OpenAI embeddings

**Configuração**: `USE_OPENAI_EMBEDDINGS=0` (default)

### Re-rank Eficiente

**Arquivo**: [`backend/app/retrieval.py`](backend/app/retrieval.py) (função `select_evidence`)

- **Top-k limitado**: Busca apenas 8 chunks (`top_k=8`)
- **Re-rank por score**: Combina similarity, trust_score e freshness_score
- **Limite de tokens**: Seleciona evidência limitada por tokens

### Pipeline Assíncrono

**Arquivo**: [`backend/app/main.py`](backend/app/main.py)

- **Audit logging**: Assíncrono (não bloqueia resposta)
- **Trace store**: Assíncrono (fila em memória)
- **Resposta rápida**: Não espera persistência

---

## Limitações

- **Cache sem invalidação**: Expira apenas por TTL, não invalida quando documentos mudam
- **Rate limit simples**: Janela fixa permite bursts no início do minuto
- **Timeouts fixos**: Não adapta dinamicamente
- **Sem retry**: Falhas são silenciosas (retorna recusa)

---

## Referências

- [Arquitetura](architecture.md) - Visão geral do sistema
- [Controles de Qualidade](quality-controls.md) - Validação de respostas
