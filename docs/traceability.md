## Traceability (rastreabilidade ponta-a-ponta)

Este backend gera um **trace técnico** por chamada ao `POST /ask`, correlacionando:
- `request_id` (header `X-Request-ID`)
- `trace_id` (header `X-Trace-ID`)
- `user_id` (quando houver JWT com claim `user_id`)
- decisões de guardrails/qualidade, cache, retrieval, LLM e resultado

### Privacidade (mandatório)
- Por padrão, **não persistimos** texto bruto de pergunta/resposta/chunks.
- Persistimos apenas **hashes** (ex.: `sha256(question_normalized)`, `sha256(chunk_text)`), IDs e metadados.
- Texto só aparece em logs quando `PIPELINE_LOG_INCLUDE_TEXT=1` e é aplicado **redaction** básico (CPF/cartão/token).

### Headers e correlação
- Toda resposta de `/ask` inclui:
  - `X-Request-ID`
  - `X-Trace-ID`

Em logs JSON (structlog), os campos são automaticamente “bindados” via contextvars:
- `request_id`
- `trace_id`
- `span_id` (quando OTel ativo)
- `user_id` (quando detectado)

### OpenTelemetry (OTel)
Para habilitar spans (quando houver collector):
- `OTEL_ENABLED=1`
- `OTEL_EXPORTER_OTLP_ENDPOINT=<endpoint>`

Quando habilitado, o `trace_id/span_id` do OTel é usado como correlação. Quando desabilitado, um `trace_id` (UUID4) é gerado.

### Pipeline trace store (MySQL) — opcional
Para persistir rastreabilidade em MySQL:
- `TRACE_SINK=mysql`
- `MYSQL_HOST`, `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_DATABASE`
- (opcional) `MYSQL_PORT=3306`
- (opcional) `MYSQL_SSL_CA=./certs/<ca>.pem`

Dependência (opcional):
- Instale `backend/requirements-extra.txt`:

```bash
python -m pip install -r backend/requirements-extra.txt
```

O schema sugerido está em [`docs/db_trace_schema.sql`](docs/db_trace_schema.sql).

### Exemplo de eventos (sem PII)
Um trace típico registra eventos como:
- `ask.start`
- `guardrails.check` / `guardrails.block`
- `cache.get` / `cache.set`
- `retrieval.embed_query`
- `retrieval.qdrant_search`
- `retrieval.rerank` (top docs com `chunk_hash`, scores e metadados)
- `quality.evaluate` / `quality.fail`
- `llm.call` / `llm.error`
- `response.final` (confidence e fontes com `excerpt_hash`)

