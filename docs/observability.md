# Observabilidade e operação

Logs JSON estruturados, métricas Prometheus, OpenTelemetry opcional e SLOs sugeridos. Tudo conforme implementado no código.

---

## O que é

- **Logs:** structlog em JSON; correlação via `request_id`, `trace_id`, `span_id`, `user_id`; logger `pipeline` para eventos do `/ask` (opcional).
- **Métricas:** Prometheus em `/metrics`; contadores e histogramas de request, cache, recusa, LLM, firewall.
- **OTel:** Opcional; spans exportados via OTLP. Sem collector configurado, o sistema não quebra.

---

## Logs JSON estruturados

- **Renderizador:** JSON (`ensure_ascii=False`).
- **Contextvars (correlação):** `request_id`, `trace_id`, `span_id`, `user_id`; `latency_ms` ao final da request (middleware).
- **Origem:** Header `X-Request-ID` ou UUID gerado; `trace_id`/`span_id` do OTel (se ativo) ou UUID.
- **Eventos típicos:** `ask_done` (cache_hit, top_docs, refusal_reason), `firewall_block`, `firewall_reload`, `trace_sink_error`, `mysql_audit_write_error`, etc.
- **Pipeline:** Com `PIPELINE_LOG_ENABLED=1`, o logger `pipeline` emite eventos (ex.: `ask_received`, `cache_checked`, `qdrant_search_done`, `evidence_selected`, `llm_done`, `response_built`). Com `PIPELINE_LOG_INCLUDE_TEXT=1`, excerpts podem aparecer (com redaction aplicada onde usado).

---

## Métricas Prometheus (/metrics)

| Métrica | Tipo | Descrição |
|--------|------|-----------|
| `request_count` | Counter | Total de requests por `endpoint` e `status`. |
| `request_latency_seconds` | Histogram | Latência por `endpoint`. |
| `cache_hit_count` | Counter | Cache hits por `endpoint`. |
| `refusal_count` | Counter | Recusas por `reason` (guardrail_injection, guardrail_sensitive, guardrail_firewall, rate_limited, no_evidence, etc.). |
| `llm_errors` | Counter | Erros de LLM por `kind`. |
| `firewall_rules_loaded` | Gauge | Número de regras válidas carregadas. |
| `firewall_reload_total` | Counter | Quantidade de reloads do arquivo de regras. |
| `firewall_invalid_rule_total` | Counter | Regras inválidas (regex) ignoradas. |
| `firewall_checks_total` | Counter | Total de checks do firewall. |
| `firewall_block_total` | Counter | Total de bloqueios. |
| `firewall_check_duration_seconds` | Histogram | Latência do `check()` do firewall. |

---

## OpenTelemetry (opcional)

- **Env:** `OTEL_ENABLED=1`, `OTEL_EXPORTER_OTLP_ENDPOINT=<url>` (ex.: `http://collector:4318/v1/traces`).
- **O que faz:** Configura `TracerProvider`, `BatchSpanProcessor`, instrumentação FastAPI e HTTPX. `trace_id`/`span_id` dos spans passam a ser usados para correlação em logs.
- **Sem collector:** Se o endpoint não estiver acessível, a aplicação continua; export pode falhar em silêncio dependendo do exporter.

---

## Configuração (env vars relevantes)

Apenas **nomes**:

- `LOG_LEVEL`
- `PIPELINE_LOG_ENABLED`, `PIPELINE_LOG_INCLUDE_TEXT`
- `OTEL_ENABLED`, `OTEL_EXPORTER_OTLP_ENDPOINT`

---

## Como validar

- **Logs:** `docker compose logs -f api`; verificar JSON com `request_id`, `trace_id`, `latency_ms`.
- **Métricas:** `curl http://localhost:8000/metrics`; checar `request_count`, `cache_hit_count`, `refusal_count`, `firewall_*`.
- **OTel:** Habilitar e apontar para um collector; confirmar spans no backend de tracing.

---

## SLOs sugeridos e o que monitorar

- **Latência `/ask`:** p50/p95 (ex.: p95 &lt; 3s quando há LLM).
- **Cache hit rate:** `cache_hit_count` / `request_count` por janela.
- **Refusal rate:** `refusal_count` por `reason`; útil para ajustar guardrails e qualidade.
- **Firewall:** `firewall_block_total`, `firewall_check_duration_seconds` (evitar picos que sugiram ReDoS).
- **Disponibilidade:** `readyz` (Redis + Qdrant) e erros 5xx; alertas sobre `llm_errors` e erros de persistência (audit/trace).

Diagrama do pipeline de métricas/logs e OTel: [diagrams.md#f](diagrams.md#f-observabilidade).

---

## Limitações

- OTel não é obrigatório; sem libs ou collector, apenas não há spans.
- Pipeline log com texto aumenta volume e risco de vazamento; usar com cuidado e redaction.
