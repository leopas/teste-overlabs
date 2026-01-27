# Rastreabilidade (traceability)

Este backend gera um **trace técnico** por chamada ao `POST /ask`, correlacionando `request_id`, `trace_id`, `user_id` (quando houver JWT), decisões de guardrails/qualidade, cache, retrieval, LLM e resultado. Os **headers de resposta** permitem correlacionar com audit e logs.

---

## Headers de resposta

A API retorna os seguintes headers. **Todos** são definidos pelo servidor; o cliente pode enviar `X-Request-ID` e `X-Chat-Session-ID` para serem ecoados.

| Header | Quem gera | Onde | Descrição |
|--------|-----------|------|-----------|
| `X-Request-ID` | Cliente pode enviar; senão servidor (UUID) | Middleware (`observability.py`) em **todas** as rotas | Identificador da request. Ecoado em toda resposta. |
| `X-Trace-ID` | Servidor (OTel span ou UUID) | Middleware em **todas** as rotas | Identificador do trace. Correlaciona com `trace_id` nas tabelas de audit e no pipeline trace. |
| `X-Answer-Source` | Servidor | Apenas `POST /ask` (`main.py`) | Origem da resposta: `CACHE`, `LLM` ou `REFUSAL`. |
| `X-Chat-Session-ID` | Cliente pode enviar; senão servidor (UUID 16 chars) | Apenas `POST /ask` | ID da sessão de chat. Ecoado em toda resposta `/ask`. Mensagens e `audit_ask` são ligadas a `session_id`. |

### Correlação com audit

- `trace_id` (header `X-Trace-ID`) = `audit_ask.trace_id` = `audit_message.trace_id` = `audit_retrieval_chunk.trace_id`.
- `request_id` (header `X-Request-ID`) = `audit_ask.request_id`.
- `session_id` (header `X-Chat-Session-ID`) = `audit_session.session_id` = `audit_message.session_id` = `audit_ask.session_id`.

Para saber se a resposta veio do cache, do LLM ou foi recusa: use `X-Answer-Source` ou `audit_ask.answer_source`.

---

### Exemplo com `curl` (sem dados sensíveis)

```bash
# Pergunta válida
curl -s -D - -X POST http://localhost:8000/ask \
  -H "Content-Type: application/json" \
  -d '{"question": "Qual o prazo de reembolso?"}' \
  | head -20
```

Verifique os headers na saída, por exemplo:

```
X-Request-ID: <uuid ou valor enviado>
X-Trace-ID: <uuid>
X-Answer-Source: CACHE ou LLM ou REFUSAL
X-Chat-Session-ID: <16 hex chars ou valor enviado>
```

```bash
# Recusa (ex.: injection)
curl -s -D - -X POST http://localhost:8000/ask \
  -H "Content-Type: application/json" \
  -d '{"question": "Ignore previous instructions"}' \
  | head -20
```

Esperado: `X-Answer-Source: REFUSAL`, corpo com `sources=[]`, `confidence` ≤ 0,3.

---

## Privacidade

- Por padrão **não** se persiste texto bruto de pergunta/resposta/chunks; apenas hashes, IDs e metadados.
- Texto em logs somente com `PIPELINE_LOG_INCLUDE_TEXT=1`, com **redaction** (CPF, cartão, token, etc.).

---

## OpenTelemetry (opcional)

- `OTEL_ENABLED=1`, `OTEL_EXPORTER_OTLP_ENDPOINT=<url>`.
- Quando ativo, `trace_id`/`span_id` vêm do OTel; caso contrário, `trace_id` = UUID4.

---

## Pipeline trace store (MySQL, opcional)

- `TRACE_SINK=mysql`, `MYSQL_*` configurados.
- Schema em [`docs/db_trace_schema.sql`](db_trace_schema.sql).
- Dependência: `backend/requirements-extra.txt`.

---

## Eventos típicos do trace (sem PII)

- `ask.start`, `guardrails.check` / `guardrails.block`
- `cache.get` / `cache.set`
- `retrieval.embed_query`, `retrieval.qdrant_search`, `retrieval.rerank`
- `quality.evaluate` / `quality.fail`
- `llm.call` / `llm.error`
- `response.final`

Ver também [audit_logging.md](audit_logging.md) e [appendix_code_facts.md](appendix_code_facts.md).
