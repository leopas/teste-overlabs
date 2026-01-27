# Audit Logging e Rastreabilidade

Documentação para banca: session tracking, answer source, persistência, rule_id no firewall. Diagrama ER: [diagrams.md#e](diagrams.md#e-er-do-schema-de-audit).

---

## O que é

Sistema de audit que persiste rastreabilidade das interações com `POST /ask`: chat log (user/assistant), metadados técnicos (answer_source, latência, confiança, chunks), classificação de abuso e, quando aplicável, texto bruto criptografado (AES-256-GCM).

---

## Como funciona

- **Session tracking:** `X-Chat-Session-ID` — gerado pelo servidor se o cliente não enviar; ecoado em toda resposta. Mensagens e `audit_ask` são ligadas à sessão.
- **Answer source:** `X-Answer-Source` = `CACHE` | `LLM` | `REFUSAL`. Também gravado em `audit_ask.answer_source`. Em recusa, `refusal_reason` indica o motivo (ex.: `guardrail_firewall`, `no_evidence`).
- **Persistência:** Assíncrona (fila em memória, worker grava em MySQL). Tabelas: `audit_session`, `audit_message`, `audit_ask`, `audit_retrieval_chunk`, `audit_vector_fingerprint` (opcional). Schema em `docs/db_audit_schema.sql`.

## O que é Gravado

### Por Padrão (Sempre)

- **Hash** de pergunta e resposta (SHA256 do texto normalizado)
- **Metadados**: trace_id, request_id, session_id, user_id, timestamps
- **Resumo técnico**: answer_source, confidence, cache_hit, latency_ms, llm_model
- **Classificação de abuso**: `abuse_risk_score` (FLOAT 0.0-1.0), `abuse_flags_json` (JSON array) — calculado via Prompt Firewall (`scan_for_abuse()`) quando habilitado + detecção local de PII/sensível. Metodologia: [prompt_firewall.md#classificação-de-risco-scan_for_abuse](prompt_firewall.md#classificação-de-risco-scan_for_abuse).

### Quando `AUDIT_LOG_INCLUDE_TEXT=1`

- **Texto redigido** (redacted) de pergunta e resposta
- **Excerpts redigidos** dos chunks retornados (se habilitado)

### Quando `AUDIT_LOG_RAW_MODE=always` ou (`risk_only` + `risk_score >= threshold`)

- **Texto bruto criptografado** (AES-256-GCM) em envelope JSON

### Quando o firewall bloqueia (rule_id)

- Em `audit_ask` fica `refusal_reason = 'guardrail_firewall'` e **`firewall_rule_ids`** (JSON array de rule_ids que bloquearam, ex: `'["inj_ignore_previous_instructions"]'`).
- O campo `firewall_rule_ids` é `TEXT NULL`; preenchido quando há bloqueio pelo **Prompt Firewall** (`refusal_reason=guardrail_firewall`) ou pelo **fallback heurístico** (`refusal_reason=guardrail_injection`); `NULL` caso contrário (ex.: recusa por sensitive/PII, rate limit, etc.).
- **Nota:** O fallback heurístico (`detect_prompt_injection`) grava `firewall_rule_ids = '["inj_fallback_heuristic"]'` para manter rastreabilidade mesmo quando o Prompt Firewall está desabilitado. Ver [prompt_firewall.md](prompt_firewall.md#fallback-quando-firewall-está-disabled).
- **O `rule_id` também existe em logs:** evento `firewall_block` (rule_id, category, question_hash, trace_id, request_id) e `guardrail_block` com `rule_id` e `category`.

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
# Nota: O abuse_classifier agora usa o Prompt Firewall (scan_for_abuse) para injection/exfiltração
# quando PROMPT_FIREWALL_ENABLED=1, mantendo apenas detecção de PII/sensível localmente

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
- **audit_ask**: Resumo técnico de cada chamada (inclui `firewall_rule_ids` quando bloqueado pelo Prompt Firewall)
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

**Nota**: O `abuse_risk_score` é calculado pelo Prompt Firewall (`scan_for_abuse()`) quando `PROMPT_FIREWALL_ENABLED=1`, combinado com detecção local de PII/sensível. Categorias mapeiam para scores: INJECTION (0.5), EXFIL (0.4), SECRETS/PII (0.6), PAYLOAD (0.7). Múltiplas categorias aumentam o score. Ver [prompt_firewall.md#classificação-de-risco-scan_for_abuse](prompt_firewall.md#classificação-de-risco-scan_for_abuse).

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

### Recusas por firewall (com rule_id)

```sql
SELECT 
    trace_id, 
    request_id, 
    session_id, 
    question_hash, 
    firewall_rule_ids,
    created_at
FROM audit_ask
WHERE refusal_reason = 'guardrail_firewall'
ORDER BY created_at DESC;
```

### Recusas por regra específica do firewall

```sql
SELECT 
    trace_id,
    request_id,
    session_id,
    question_hash,
    firewall_rule_ids,
    created_at
FROM audit_ask
WHERE refusal_reason = 'guardrail_firewall'
  AND JSON_CONTAINS(firewall_rule_ids, '"inj_ignore_previous_instructions"')
ORDER BY created_at DESC;
```

O campo `firewall_rule_ids` contém um JSON array (ex: `'["inj_ignore_previous_instructions"]'`). Use `JSON_CONTAINS` para filtrar por regra específica.

## Answer source & provenance

- **Como saber se veio do cache vs LLM:** use o header `X-Answer-Source` ou `audit_ask.answer_source` (`CACHE` | `LLM` | `REFUSAL`).
- **Chunks retornados:** registrados em `audit_retrieval_chunk` apenas quando há **retrieval** (busca no Qdrant). Em **cache hit**, os chunks vêm do payload cacheado e também são persistidos; em **recusa antes do retriever** (firewall, guardrails, rate limit), não há chunks.

## Headers de resposta

O endpoint `/ask` retorna (e o middleware define em outras rotas quando aplicável):

- **X-Request-ID**: enviado pelo cliente ou gerado pelo servidor; ecoado em toda resposta.
- **X-Trace-ID**: ID do trace; correlaciona com `trace_id` no audit.
- **X-Answer-Source**: `CACHE` | `LLM` | `REFUSAL` (apenas em `/ask`).
- **X-Chat-Session-ID**: ID da sessão; gerado pelo servidor se o cliente não enviar; ecoado em toda resposta `/ask`.

Detalhes: [traceability.md](traceability.md).

### Exemplo de uso

```python
import httpx

BASE = "http://localhost:8000"

# Primeira chamada (gera session_id)
r = httpx.post(f"{BASE}/ask", json={"question": "Qual o prazo?"})
session_id = r.headers["X-Chat-Session-ID"]
trace_id = r.headers["X-Trace-ID"]
answer_source = r.headers["X-Answer-Source"]

# Segunda chamada (reutiliza session_id)
r2 = httpx.post(
    f"{BASE}/ask",
    json={"question": "Qual a política?"},
    headers={"X-Chat-Session-ID": session_id},
)
assert r2.headers["X-Chat-Session-ID"] == session_id
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

## Como validar

- Enviar `POST /ask` com e sem `X-Chat-Session-ID`; conferir que o header é ecoado e que mensagens do mesmo `session_id` aparecem em `audit_message`.
- Comparar `X-Answer-Source` (CACHE / LLM / REFUSAL) com `audit_ask.answer_source` e com `refusal_reason` quando for REFUSAL.
- Consultar `audit_ask` e `audit_retrieval_chunk` por `trace_id` retornado nos headers; verificar chunks apenas quando houve retrieval (não em cache hit puro nem em recusa antes do retriever).
- Para bloqueios pelo Prompt Firewall: verificar que `refusal_reason = 'guardrail_firewall'` e `firewall_rule_ids` contém JSON array com o `rule_id` (ex: `'["inj_ignore_previous_instructions"]'`).
- Para bloqueios por fallback heurístico: verificar que `refusal_reason = 'guardrail_injection'` e `firewall_rule_ids = '["inj_fallback_heuristic"]'`.

## Limitações

- Audit depende de `TRACE_SINK=mysql` e `MYSQL_*`; com `noop`, nada é persistido.
- Worker assíncrono: em fila cheia, eventos podem ser descartados (warning em log).
- `firewall_rule_ids` é preenchido quando há bloqueio pelo Prompt Firewall (`guardrail_firewall`) ou pelo fallback heurístico (`guardrail_injection`); `NULL` caso contrário (ex.: `guardrail_sensitive`, `rate_limited`, etc.).

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
