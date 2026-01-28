# Referência de Variáveis de Ambiente

Referência completa de todas as variáveis de ambiente suportadas pelo sistema.

> **Nota**: Para lista gerada automaticamente, veja [Variáveis Detectadas](_generated/env_vars_detected.md).

## Classificação

### Obrigatórias

**Nenhuma variável é obrigatória** - todas têm defaults ou são opcionais.

**Nota**: Em produção (Azure Container Apps), `QDRANT_URL` e `REDIS_URL` são configurados automaticamente via DNS interno.

### Secrets

Variáveis que contêm informações sensíveis e devem ser armazenadas no Azure Key Vault:

- `OPENAI_API_KEY`: Chave da API OpenAI
- `MYSQL_PASSWORD`: Senha do MySQL
- `AUDIT_ENC_KEY_B64`: Chave de criptografia para audit logs (32 bytes base64)

**Como configurar**: Use `infra/update_container_app_env.ps1` que automaticamente cria secrets no Key Vault e usa referências `@Microsoft.KeyVault(...)`.

### Não-Secrets

Variáveis que podem ser configuradas diretamente no Container App:

- Todas as outras variáveis listadas abaixo

---

## Variáveis por Categoria

### Core (Qdrant, Redis, Documentos)

| Variável | Tipo | Default | Descrição |
|----------|------|---------|-----------|
| `QDRANT_URL` | string | `http://qdrant:6333` | URL do Qdrant (DNS interno no Azure) |
| `QDRANT_COLLECTION` | string | `docs_chunks` | Nome da coleção no Qdrant |
| `REDIS_URL` | string | `redis://redis:6379/0` | URL do Redis (DNS interno no Azure) |
| `DOCS_ROOT` | string | `/docs` | Caminho para documentos dentro do container |
| `DOCS_HOST_PATH` | string | `./DOC-IA` | Caminho no host para documentos (usado no Docker Compose) |

### OpenAI (Opcional)

| Variável | Tipo | Default | Descrição |
|----------|------|---------|-----------|
| `OPENAI_API_KEY` | string (secret) | `None` | Chave da API OpenAI (obrigatória se usar OpenAI) |
| `USE_OPENAI_EMBEDDINGS` | bool | `0` | Usar embeddings OpenAI (0=fastembed local, 1=OpenAI) |
| `OPENAI_MODEL` | string | `gpt-4o-mini` | Modelo do LLM OpenAI |
| `OPENAI_MODEL_ENRICHMENT` | string | `gpt-4o-mini` | Modelo para enrichment (se aplicável) |
| `OPENAI_EMBEDDINGS_MODEL` | string | `text-embedding-3-small` | Modelo de embeddings OpenAI |

**Nota**: Se `OPENAI_API_KEY` não estiver configurada, o sistema usa um LLM stub determinístico.

### Cache e Rate Limiting

| Variável | Tipo | Default | Descrição |
|----------|------|---------|-----------|
| `CACHE_TTL_SECONDS` | int | `600` | TTL do cache em segundos (10 minutos) |
| `RATE_LIMIT_PER_MINUTE` | int | `60` | Limite de requests por minuto por IP |

### Observabilidade

| Variável | Tipo | Default | Descrição |
|----------|------|---------|-----------|
| `LOG_LEVEL` | string | `INFO` | Nível de log (DEBUG, INFO, WARNING, ERROR) |
| `OTEL_ENABLED` | bool | `0` | Habilitar OpenTelemetry |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | string | `None` | Endpoint OTLP para OpenTelemetry |
| `PIPELINE_LOG_ENABLED` | bool | `0` | Logs detalhados do pipeline `/ask` |
| `PIPELINE_LOG_INCLUDE_TEXT` | bool | `0` | Incluir excerpts curtos dos chunks nos logs |

### Audit Logging

| Variável | Tipo | Default | Descrição |
|----------|------|---------|-----------|
| `AUDIT_LOG_ENABLED` | bool | `1` | Habilitar audit logging |
| `AUDIT_LOG_INCLUDE_TEXT` | bool | `1` | Incluir texto redacted nos logs |
| `AUDIT_LOG_RAW_MODE` | string | `risk_only` | Quando salvar texto raw: `off`, `risk_only`, `always` |
| `AUDIT_LOG_RAW_MAX_CHARS` | int | `2000` | Limite de caracteres para texto raw |
| `AUDIT_LOG_REDACT` | bool | `1` | Aplicar redação automática de PII |
| `AUDIT_ENC_KEY_B64` | string (secret) | `None` | Chave de criptografia (32 bytes base64, AES-256-GCM) |
| `AUDIT_ENC_AAD_MODE` | string | `trace_id` | Modo AAD para criptografia: `trace_id`, `request_id`, `none` |

### Trace Store

| Variável | Tipo | Default | Descrição |
|----------|------|---------|-----------|
| `TRACE_SINK` | string | `noop` | Sink para traces: `noop` ou `mysql` |
| `TRACE_SINK_QUEUE_SIZE` | int | `1000` | Tamanho da fila de traces |

### MySQL (para Trace Store e Audit)

| Variável | Tipo | Default | Descrição |
|----------|------|---------|-----------|
| `MYSQL_HOST` | string | `None` | Host do MySQL |
| `MYSQL_PORT` | int | `3306` | Porta do MySQL |
| `MYSQL_USER` | string | `None` | Usuário do MySQL |
| `MYSQL_PASSWORD` | string (secret) | `None` | Senha do MySQL |
| `MYSQL_DATABASE` | string | `None` | Nome do banco de dados |
| `MYSQL_SSL_CA` | string | `/app/certs/DigiCertGlobalRootCA.crt.pem` | Caminho para CA do MySQL (Azure MySQL) |

**Nota**: Para Azure MySQL, o formato do usuário pode ser `user@servername` (o sistema tenta ambos).

### Classificação de Abuso

| Variável | Tipo | Default | Descrição |
|----------|------|---------|-----------|
| `ABUSE_CLASSIFIER_ENABLED` | bool | `1` | Habilitar classificação de abuso |
| `ABUSE_RISK_THRESHOLD` | float | `0.80` | Threshold de risco (0.0-1.0) |

### Prompt Firewall (WAF de Prompt)

| Variável | Tipo | Default | Descrição |
|----------|------|---------|-----------|
| `PROMPT_FIREWALL_ENABLED` | bool | `0` | Habilitar Prompt Firewall |
| `PROMPT_FIREWALL_RULES_PATH` | string | `config/prompt_firewall.regex` | Caminho para arquivo de regras |
| `PROMPT_FIREWALL_MAX_RULES` | int | `200` | Limite máximo de regras |
| `PROMPT_FIREWALL_RELOAD_CHECK_SECONDS` | int | `2` | Intervalo para verificar mudanças no arquivo |
| `FIREWALL_LOG_SAMPLE_RATE` | float | `0.01` | Taxa de amostragem para logs (0.0-1.0) |

### Portas (Docker Compose)

| Variável | Tipo | Default | Descrição |
|----------|------|---------|-----------|
| `API_PORT` | int | `8000` | Porta da API no host |
| `QDRANT_PORT` | int | `6335` | Porta do Qdrant no host (mapeia para 6333) |
| `REDIS_PORT` | int | `6379` | Porta do Redis no host |

---

## Configuração por Ambiente

### Local (Docker Compose)

Crie um arquivo `.env`:

```bash
# Documentos
DOCS_HOST_PATH=./DOC-IA

# Portas
API_PORT=8000
QDRANT_PORT=6335
REDIS_PORT=6379

# OpenAI (opcional)
OPENAI_API_KEY=
USE_OPENAI_EMBEDDINGS=0

# Logs
PIPELINE_LOG_ENABLED=0
LOG_LEVEL=INFO
```

### Produção (Azure Container Apps)

1. **Configurar via script**:
   ```powershell
   .\infra\update_container_app_env.ps1 -EnvFile ".env"
   ```

2. **Configurar individualmente**:
   ```powershell
   .\infra\add_single_env_var.ps1 -VarName "AUDIT_LOG_RAW_MAX_CHARS" -VarValue "2000"
   ```

3. **Secrets no Key Vault**:
   - Secrets são automaticamente criados no Key Vault
   - Referências `@Microsoft.KeyVault(...)` são usadas no Container App
   - Managed Identity é configurada automaticamente

---

## Validação

Valide seu arquivo `.env` antes de usar:

```bash
python infra/validate_env.py --env .env --show-classification
```

Isso verifica:
- Formato correto (KEY=VALUE)
- Tipos (inteiros, booleanos)
- Nomes válidos para Key Vault
- Classificação secrets vs non-secrets

---

## Referências

- [Variáveis Detectadas](_generated/env_vars_detected.md) - Lista gerada automaticamente
- [Configuração no Azure](deployment_azure.md#configurar-variáveis-de-ambiente) - Como configurar em produção
- [Validador de Env](reference/scripts.md#validate_envpy) - Script de validação
