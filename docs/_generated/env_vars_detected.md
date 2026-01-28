# Variáveis de Ambiente Detectadas

> **Nota**: Este arquivo é gerado automaticamente por `tools/docs_extract.py`.
> Não edite manualmente. Execute `python tools/docs_extract.py` para atualizar.

## Classificação (validate_env.py)

### Variáveis Não-Secrets

- `ABUSE_CLASSIFIER_ENABLED`
- `ABUSE_RISK_THRESHOLD`
- `API_PORT`
- `AUDIT_ENC_AAD_MODE`
- `AUDIT_LOG_ENABLED`
- `AUDIT_LOG_INCLUDE_TEXT`
- `AUDIT_LOG_RAW_MAX_CHARS`
- `AUDIT_LOG_RAW_MODE`
- `AUDIT_LOG_REDACT`
- `CACHE_TTL_SECONDS`
- `DOCS_HOST_PATH`
- `DOCS_ROOT`
- `ENV`
- `FIREWALL_LOG_SAMPLE_RATE`
- `HOST`
- `LOG_LEVEL`
- `MYSQL_DATABASE`
- `MYSQL_HOST`
- `MYSQL_PORT`
- `MYSQL_SSL_CA`
- `OPENAI_EMBEDDINGS_MODEL`
- `OPENAI_MODEL`
- `OPENAI_MODEL_ENRICHMENT`
- `OTEL_ENABLED`
- `OTEL_EXPORTER_OTLP_ENDPOINT`
- `PIPELINE_LOG_ENABLED`
- `PIPELINE_LOG_INCLUDE_TEXT`
- `PORT`
- `PROMPT_FIREWALL_ENABLED`
- `PROMPT_FIREWALL_MAX_RULES`
- `PROMPT_FIREWALL_RELOAD_CHECK_SECONDS`
- `PROMPT_FIREWALL_RULES_PATH`
- `QDRANT_PORT`
- `QDRANT_URL`
- `RATE_LIMIT_PER_MINUTE`
- `REDIS_PORT`
- `REDIS_URL`
- `TRACE_SINK`
- `TRACE_SINK_QUEUE_SIZE`
- `USE_OPENAI_EMBEDDINGS`

### Variáveis Obrigatórias

*(Nenhuma variável obrigatória definida)*

### Variáveis Inteiras

- `API_PORT`
- `AUDIT_LOG_RAW_MAX_CHARS`
- `CACHE_TTL_SECONDS`
- `MYSQL_PORT`
- `PROMPT_FIREWALL_MAX_RULES`
- `PROMPT_FIREWALL_RELOAD_CHECK_SECONDS`
- `QDRANT_PORT`
- `RATE_LIMIT_PER_MINUTE`
- `REDIS_PORT`
- `TRACE_SINK_QUEUE_SIZE`

### Variáveis Booleanas

- `ABUSE_CLASSIFIER_ENABLED`
- `AUDIT_LOG_ENABLED`
- `AUDIT_LOG_INCLUDE_TEXT`
- `AUDIT_LOG_REDACT`
- `OTEL_ENABLED`
- `PIPELINE_LOG_ENABLED`
- `PIPELINE_LOG_INCLUDE_TEXT`
- `PROMPT_FIREWALL_ENABLED`
- `USE_OPENAI_EMBEDDINGS`

## Variáveis do Config (config.py)

| Variável | Tipo | Default |
|----------|------|---------|
| `ABUSE_CLASSIFIER_ENABLED` | bool | `True` |
| `ABUSE_RISK_THRESHOLD` | float | `0.8` |
| `AUDIT_ENC_AAD_MODE` | str | `trace_id` |
| `AUDIT_ENC_KEY_B64` | str | - |
| `AUDIT_LOG_ENABLED` | bool | `True` |
| `AUDIT_LOG_INCLUDE_TEXT` | bool | `True` |
| `AUDIT_LOG_RAW_MAX_CHARS` | int | `2000` |
| `AUDIT_LOG_RAW_MODE` | str | `risk_only` |
| `AUDIT_LOG_REDACT` | bool | `True` |
| `CACHE_TTL_SECONDS` | int | `600` |
| `DOCS_ROOT` | str | `/docs` |
| `FIREWALL_LOG_SAMPLE_RATE` | float | `0.01` |
| `LOG_LEVEL` | str | `INFO` |
| `OPENAI_API_KEY` | str | - |
| `OPENAI_EMBEDDINGS_MODEL` | str | `text-embedding-3-small` |
| `OPENAI_MODEL` | str | `gpt-4o-mini` |
| `OTEL_ENABLED` | bool | `False` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | str | - |
| `PIPELINE_LOG_ENABLED` | bool | `False` |
| `PIPELINE_LOG_INCLUDE_TEXT` | bool | `False` |
| `PROMPT_FIREWALL_ENABLED` | bool | `False` |
| `PROMPT_FIREWALL_MAX_RULES` | int | `200` |
| `PROMPT_FIREWALL_RELOAD_CHECK_SECONDS` | int | `2` |
| `PROMPT_FIREWALL_RULES_PATH` | str | `config/prompt_firewall.regex` |
| `QDRANT_COLLECTION` | str | `docs_chunks` |
| `QDRANT_URL` | str | `http://qdrant:6333` |
| `RATE_LIMIT_PER_MINUTE` | int | `60` |
| `REDIS_URL` | str | `redis://redis:6379/0` |
| `TRACE_SINK` | str | `noop` |
| `USE_OPENAI_EMBEDDINGS` | bool | `False` |