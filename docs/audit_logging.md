# Audit Logging e Rastreabilidade

## Visão Geral

O sistema de audit logging persiste rastreabilidade completa de todas as interações com o endpoint `/ask`, incluindo:

- **Chat log completo**: Perguntas e respostas (user/assistant)
- **Metadados técnicos**: Origem da resposta (CACHE/LLM/REFUSAL), latência, confiança, chunks retornados
- **Classificação de abuso**: Score de risco e flags de detecção
- **Criptografia opcional**: Texto bruto criptografado (AES-256-GCM) para casos de alto risco

## O que é Gravado

### Por Padrão (Sempre)

- **Hash** de pergunta e resposta (SHA256 do texto normalizado)
- **Metadados**: trace_id, request_id, session_id, user_id, timestamps
- **Resumo técnico**: answer_source, confidence, cache_hit, latency_ms, llm_model
- **Classificação de abuso**: risk_score, flags (JSON array)

### Quando `AUDIT_LOG_INCLUDE_TEXT=1`

- **Texto redigido** (redacted) de pergunta e resposta
- **Excerpts redigidos** dos chunks retornados (se habilitado)

### Quando `AUDIT_LOG_RAW_MODE=always` ou (`risk_only` + `risk_score >= threshold`)

- **Texto bruto criptografado** (AES-256-GCM) em envelope JSON

## Configuração

### Variáveis de Ambiente

```bash
# Habilitar audit logging
AUDIT_LOG_ENABLED=1
TRACE_SINK=mysql              # noop|mysql

# Incluir texto redigido
AUDIT_LOG_INCLUDE_TEXT=1
AUDIT_LOG_REDACT=1

# Modo de raw logging
AUDIT_LOG_RAW_MODE=risk_only  # off|risk_only|always
AUDIT_LOG_RAW_MAX_CHARS=2000

# Criptografia
# Gerar chave: python -c "import os,base64; print(base64.b64encode(os.urandom(32)).decode())"
AUDIT_ENC_KEY_B64=<chave_base64_32_bytes>
AUDIT_ENC_AAD_MODE=trace_id   # trace_id|request_id|none

# Classificação de abuso
ABUSE_CLASSIFIER_ENABLED=1
ABUSE_RISK_THRESHOLD=0.80

# MySQL
MYSQL_HOST=<host>
MYSQL_PORT=3306
MYSQL_DATABASE=<database>
MYSQL_USER=<user>
MYSQL_PASSWORD=<password>
MYSQL_SSL_CA=<caminho_para_ca_cert>  # Opcional para Azure MySQL
```

### Gerar Chave de Criptografia

```bash
python -c "import os,base64; print(base64.b64encode(os.urandom(32)).decode())"
```

**IMPORTANTE**: Nunca commitar a chave no código ou logs. Armazene em variáveis de ambiente seguras (ex: Azure Key Vault, AWS Secrets Manager).

## Schema MySQL

O schema está em `docs/db_audit_schema.sql`. Tabelas principais:

- **audit_session**: Sessões de chat
- **audit_message**: Mensagens user/assistant (chat log)
- **audit_ask**: Resumo técnico de cada chamada
- **audit_retrieval_chunk**: Chunks retornados na consulta
- **audit_vector_fingerprint**: Fingerprint do vetor de embedding (opcional)

## Queries SQL Úteis

### Mensagens de uma Session

```sql
SELECT 
    role,
    text_hash,
    text_redacted,
    created_at
FROM audit_message
WHERE session_id = 'abc123'
ORDER BY created_at;
```

### Chunks de um Trace

```sql
SELECT 
    rank,
    document,
    path,
    score_similarity,
    score_trust,
    score_final,
    excerpt_redacted
FROM audit_retrieval_chunk
WHERE trace_id = 'trace_xyz'
ORDER BY rank;
```

### Perguntas com Alto Risco de Abuso

```sql
SELECT 
    trace_id,
    question_hash,
    answer_source,
    abuse_risk_score,
    abuse_flags_json,
    created_at
FROM audit_ask
WHERE abuse_risk_score >= 0.80
ORDER BY created_at DESC;
```

### Respostas do Cache vs LLM

```sql
SELECT 
    answer_source,
    COUNT(*) as count,
    AVG(latency_ms) as avg_latency_ms,
    AVG(confidence) as avg_confidence
FROM audit_ask
WHERE created_at >= DATE_SUB(NOW(), INTERVAL 24 HOUR)
GROUP BY answer_source;
```

### Histórico Completo de uma Conversa

```sql
SELECT 
    m.role,
    m.text_redacted,
    a.answer_source,
    a.confidence,
    a.created_at
FROM audit_message m
JOIN audit_ask a ON m.trace_id = a.trace_id
WHERE m.session_id = 'abc123'
ORDER BY m.created_at;
```

## Headers de Resposta

O endpoint `/ask` retorna os seguintes headers:

- **X-Trace-ID**: ID único do trace (correlaciona com `trace_id` no DB)
- **X-Answer-Source**: Origem da resposta (`CACHE`, `LLM`, ou `REFUSAL`)
- **X-Chat-Session-ID**: ID da sessão de chat (persistido entre requests se enviado no header `X-Chat-Session-ID`)

### Exemplo de Uso

```python
import httpx

# Primeira chamada (gera session_id)
response = httpx.post("http://api/ask", json={"question": "Qual o prazo?"})
session_id = response.headers["X-Chat-Session-ID"]
trace_id = response.headers["X-Trace-ID"]
answer_source = response.headers["X-Answer-Source"]

# Segunda chamada (reutiliza session_id)
response2 = httpx.post(
    "http://api/ask",
    json={"question": "Qual a política?"},
    headers={"X-Chat-Session-ID": session_id}
)
# session_id será o mesmo
assert response2.headers["X-Chat-Session-ID"] == session_id
```

## Retenção Recomendada

- **Texto bruto criptografado**: 30 dias (LGPD: mínimo necessário)
- **Metadados e texto redigido**: 180 dias (análise e compliance)
- **Hashes**: Indefinido (útil para detecção de duplicatas)

### Script de Limpeza (Exemplo)

```sql
-- Remover raw criptografado após 30 dias
DELETE FROM audit_message
WHERE text_raw_enc IS NOT NULL
  AND created_at < DATE_SUB(NOW(), INTERVAL 30 DAY);

-- Remover metadados após 180 dias
DELETE FROM audit_ask
WHERE created_at < DATE_SUB(NOW(), INTERVAL 180 DAY);
```

## Segurança e LGPD

### Redação Automática

O sistema redige automaticamente:
- CPF (formatado ou não)
- Cartões de crédito/débito
- Tokens Bearer
- API keys/secrets (palavras-chave)
- Emails
- Telefones

### Criptografia

- **Algoritmo**: AES-256-GCM
- **AAD (Additional Authenticated Data)**: Protege contra replay entre traces
  - `trace_id`: AAD = trace_id (padrão)
  - `request_id`: AAD = request_id
  - `none`: AAD = vazio
- **Envelope JSON**: `{"alg":"AES-256-GCM", "kid":"...", "nonce_b64":"...", "ct_b64":"..."}`

### Mínimo Necessário

O sistema segue o princípio de "mínimo necessário":
- Hash sempre salvo (identificação sem texto)
- Texto redigido quando `AUDIT_LOG_INCLUDE_TEXT=1`
- Texto bruto apenas quando necessário (always ou risk_only com threshold)

## Troubleshooting

### Audit não está gravando

1. Verificar `AUDIT_LOG_ENABLED=1`
2. Verificar `TRACE_SINK=mysql` ou variáveis `MYSQL_*` configuradas
3. Verificar logs: `mysql_connect_error`, `mysql_audit_write_error`
4. Verificar se schema foi aplicado: `SHOW TABLES LIKE 'audit_%';`

### Chave de criptografia inválida

1. Verificar que `AUDIT_ENC_KEY_B64` tem 32 bytes (44 caracteres base64)
2. Verificar logs: `audit_enc_key_invalid_length`, `audit_enc_key_decode_error`

### Performance

- Audit logging é **assíncrono** (não bloqueia requests)
- Queue size configurável via `TRACE_SINK_QUEUE_SIZE` (padrão: 1000)
- Se queue estiver cheia, eventos são descartados (logado como warning)
