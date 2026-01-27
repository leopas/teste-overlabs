# Segurança e controles

Guardrails, Prompt Firewall, política de PII, audit com criptografia e threat model (STRIDE lean). Tudo descrito **conforme existe no código**.

---

## O que é

Camadas de proteção na entrada do `POST /ask`: **Prompt Firewall** (regex, opcional), **guardrails** (injection + sensitive/PII), **rate limit**. Na auditoria: hashes, redaction e criptografia condicional. Na ingestão: exclusão de PII/funcionários (R1).

---

## Gates do request

Ordem executada (diagrama em [diagrams.md#g](diagrams.md#g-gates-de-segurança-request)):

1. **Rate limit** (Redis): por IP, `RATE_LIMIT_PER_MINUTE`; excedido → REFUSAL.
2. **Prompt Firewall** (se `PROMPT_FIREWALL_ENABLED`): regex sobre pergunta normalizada; match → REFUSAL, sem retriever/LLM.
3. **Guardrails:** `detect_prompt_injection` → REFUSAL; `detect_sensitive_request` (CPF, cartão, senha/token/key, etc.) → REFUSAL.
4. Resto do pipeline (cache, retrieval, LLM, quality).

---

## Guardrails (entrada do /ask)

### Injeção de prompt

- **Onde:** `app.security.detect_prompt_injection` (regex).
- **Padrões:** "ignore previous instructions", "reveal system prompt", "jailbreak", "BEGIN SYSTEM PROMPT", etc.
- **Efeito:** REFUSAL, `refusal_reason=guardrail_injection`.

### Sensível / PII na pergunta

- **Onde:** `app.security.detect_sensitive_request`.
- **Padrões:** CPF (formatado ou 11 dígitos), cartão (13–19 dígitos), "password", "senha", "token", "api_key", "secret", "conta bancária", etc.
- **Efeito:** REFUSAL, `refusal_reason=guardrail_sensitive`.

---

## Prompt Firewall (regex)

- **Onde:** `app.prompt_firewall`; regras em arquivo (`PROMPT_FIREWALL_RULES_PATH`, default `config/prompt_firewall.regex`).
- **Conceito:** WAF de prompt; execução **antes** dos guardrails de injection/sensitive. Match → REFUSAL, sem retriever/LLM.
- **Normalização:** NFKD, remove diacríticos, lower, colapsa whitespace (`normalize_for_firewall`).
- **Categorias (por prefixo do rule_id):** INJECTION, EXFIL, SECRETS, PII, PAYLOAD.
- **Atualizar regras:** editar o `.regex`; hot reload por `mtime` (throttle `PROMPT_FIREWALL_RELOAD_CHECK_SECONDS`). O enricher (`scripts/enrich_prompt_firewall.py`) gera propostas/validações/patches; **nunca** altera o arquivo diretamente.
- **Métricas:** `firewall_rules_loaded`, `firewall_reload_total`, `firewall_checks_total`, `firewall_block_total`, `firewall_check_duration_seconds`.

Ver [prompt_firewall.md](prompt_firewall.md), [prompt_firewall_perf.md](prompt_firewall_perf.md), [prompt_firewall_enrichment.md](prompt_firewall_enrichment.md).

---

## Política de PII e R1 vs R2

### R1 (presente)

- **Pergunta:** Guardrails bloqueiam CPF, cartão, senha/token na **entrada**.
- **Ingestão:** Arquivos com CPF no conteúdo ou `funcionarios` no path são **ignorados** (`scripts.ingest` + `contains_cpf`).
- **Audit:** Texto redigido (redaction) e hashes; bruto só sob condições (risk_only/always) e criptografado.

### R2 (fora do escopo)

- Incluir documentos de funcionários na base vetorial.
- Políticas mais granulares de PII (ex.: LGPD por finalidade).

---

## Audit log e criptografia

### O que é persistido

- **Sempre:** hashes (pergunta/resposta normalizados), `trace_id`, `request_id`, `session_id`, `user_id`, `answer_source`, `confidence`, `cache_hit`, `latency_ms`, `refusal_reason`, `abuse_risk_score`, `abuse_flags_json`.
- **Com `AUDIT_LOG_INCLUDE_TEXT=1`:** texto **redigido** (redaction) de pergunta/resposta e, quando aplicável, excerpts dos chunks.
- **Raw criptografado:** quando `AUDIT_LOG_RAW_MODE=always` ou (`risk_only` e `abuse_risk_score >= ABUSE_RISK_THRESHOLD`). AES-256-GCM; envelope JSON com `alg`, `kid`, `nonce_b64`, `ct_b64`.

### Redaction

- **Onde:** `app.redaction.redact_text`.
- **Alvos:** CPF, cartão, Bearer token, API key/secret/password (palavras-chave), email, telefone.

### AAD e replay

- **AAD:** `AUDIT_ENC_AAD_MODE` = `trace_id` | `request_id` | `none`. `trace_id` amarra o ciphertext ao trace, reduzindo replay entre traces.

---

## Configuração (env vars relevantes)

Apenas **nomes**; não usar valores reais em docs.

- `RATE_LIMIT_PER_MINUTE`
- `PROMPT_FIREWALL_ENABLED`, `PROMPT_FIREWALL_RULES_PATH`, `PROMPT_FIREWALL_MAX_RULES`, `PROMPT_FIREWALL_RELOAD_CHECK_SECONDS`, `FIREWALL_LOG_SAMPLE_RATE`
- `AUDIT_LOG_ENABLED`, `AUDIT_LOG_INCLUDE_TEXT`, `AUDIT_LOG_RAW_MODE`, `AUDIT_LOG_RAW_MAX_CHARS`, `AUDIT_LOG_REDACT`
- `AUDIT_ENC_KEY_B64`, `AUDIT_ENC_AAD_MODE`
- `ABUSE_CLASSIFIER_ENABLED`, `ABUSE_RISK_THRESHOLD`
- **Nota**: O `abuse_classifier` agora usa o Prompt Firewall (`scan_for_abuse()`) para calcular `risk_score` e `flags` quando `PROMPT_FIREWALL_ENABLED=1`, mantendo apenas detecção de PII/sensível localmente. Ver [prompt_firewall.md](prompt_firewall.md#classificação-de-risco-scan_for_abuse).

---

## Como validar

- **Guardrails:** `POST /ask` com "ignore previous instructions" ou "CPF 123.456.789-00" → 200 REFUSAL, `X-Answer-Source=REFUSAL`.
- **Firewall:** Habilitar, regra que case na pergunta → REFUSAL; ver `firewall_block_total` em `/metrics`.
- **Rate limit:** Exceder `RATE_LIMIT_PER_MINUTE` por IP → REFUSAL.
- **Audit:** `TRACE_SINK=mysql`, `AUDIT_LOG_ENABLED=1`; consultar `audit_ask`, `audit_message`; ver [audit_logging.md](audit_logging.md).

---

## Threat model (STRIDE lean)

| Vetor | Mitigação |
|-------|------------|
| **Prompt injection** | Guardrails (regex) + Prompt Firewall (regex). |
| **Exfiltração** | Firewall, guardrails, recusa sem evidência; abuse classifier (usa Prompt Firewall via `scan_for_abuse()`) + raw opcional para análise. |
| **Vazamento de PII** | Guardrails na pergunta; ingestão sem CPF/funcionários; redaction em audit; hashes em vez de texto quando possível. |
| **Abuso / volume** | Rate limit; abuse classifier (integra Prompt Firewall para cálculo de risk_score); auditoria. |
| **ReDoS (regex)** | Regras focadas; métricas `firewall_check_duration`; enricher com validação de performance. |
| **Cache poisoning** | Cache key = SHA256 da pergunta normalizada; sem influência direta do cliente no valor cacheado. |

---

## Limitações

- Guardrails e firewall são heurísticas (regex); não cobrem todos os vetores.
- JWT não é validado; `user_id` extraído apenas para audit.
- Criptografia de audit é “simples” (AES-GCM com chave estática); rotação e uso de HSM ficam para evolução.
