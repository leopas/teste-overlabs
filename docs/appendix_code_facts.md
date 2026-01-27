# Apêndice: fatos do código (auditoria)

Uma página de referência com **fatos confirmados** no código atual. Use para validar que a documentação não faz promessas falsas.

---

## Endpoints expostos

| Endpoint | Método | Responsabilidade |
|----------|--------|------------------|
| `/healthz` | GET | Liveness; sempre 200. |
| `/readyz` | GET | Redis + Qdrant ok → 200; caso contrário 503. |
| `/metrics` | GET | Prometheus (request_count, cache_hit_count, refusal_count, latency, firewall_*, etc.). |
| `/ask` | POST | RAG: validação, guardrails, cache, retrieval, LLM, qualidade. Sempre 200 com input válido (inclusive recusa). |

---

## Headers retornados

- **Todas as rotas** (middleware `RequestContextMiddleware` em `app/observability.py`):
  - `X-Request-ID`: cliente pode enviar; senão o servidor gera UUID. Sempre ecoado na resposta.
  - `X-Trace-ID`: OTel span ou UUID. Sempre ecoado na resposta.

- **Apenas `POST /ask`** (em `app/main.py`):
  - `X-Answer-Source`: `CACHE` | `LLM` | `REFUSAL`.
  - `X-Chat-Session-ID`: gerado pelo servidor se o cliente não enviar; ecoado em toda resposta `/ask`.

---

## Cache e hashing

- **Cache key (Redis):**
  - Normalização: `security.normalize_question` → strip, lower, collapse whitespace.
  - Key: `cache_key_for_question(normalized)` = SHA256 hex (`cache.py`).
  - Uso: lookup/get/set de resposta; sem prefixo. Rate limit usa `rl:<ip>:<epochMinute>`.

- **Audit / fingerprint (hashes persistidos):**
  - Normalização: `redaction.normalize_text` → strip, remove control chars, collapse whitespace (sem lower).
  - `question_hash` / `answer_hash` em `audit_ask`: `sha256_text(redact_normalize(...))` (`redaction.sha256_text`).
  - `text_hash` em `audit_message` e `audit_retrieval_chunk`: mesmo esquema sobre texto redigido/normalizado.
  - **Distinto do cache:** audit usa `redact_normalize`; cache usa `normalize_question` + `cache_key_for_question`.

---

## Conflito e pós-validação

- **`quality.detect_conflict`** (`quality.py`):
  - Conflito **apenas** em prazos (ex.: “X dias”) e datas (`dd/mm/yyyy`), por escopo (nacional / internacional / geral).
  - Se a pergunta restringe escopo, só considera sentenças desse escopo.
  - Retorna `ConflictInfo(has_conflict, details)`.

- **`quality.post_validate_answer`** (`quality.py`):
  - Verifica se **números** citados na resposta existem nos trechos de evidência (`_NUM_RE`).
  - Rejeita se houver número na resposta que não esteja na evidência.

- **`quality.cross_check_ok`**:
  - Exige `not conflict.has_conflict`.
  - Regra: 2+ fontes distintas **ou** 1 fonte `POLICY`/`MANUAL` com `trust_score >= 0.85`.

---

## Recusa

- Sempre HTTP **200** com `answer` genérico (`REFUSAL_ANSWER`), `sources=[]`, `confidence` ≤ 0,3.
- `refusal_reason` em audit; `X-Answer-Source=REFUSAL` no header.

---

## Audit / trace

- Audit: `audit_store.py`; sink MySQL ou noop. Tabelas: `audit_session`, `audit_message`, `audit_ask`, `audit_retrieval_chunk`, `audit_vector_fingerprint` (opcional). Schema em `docs/db_audit_schema.sql`.
- Pipeline trace: `trace_store.py`; opcional (MySQL). Schema em `docs/db_trace_schema.sql`.
- **`rule_id` do firewall:** persistido em `audit_ask.firewall_rule_ids` (JSON array, ex: `'["inj_ignore_previous_instructions"]'`) quando há bloqueio. Também em logs (`firewall_block`, `guardrail_block`).
- **Classificação de abuso:** `abuse_risk_score` (FLOAT 0.0-1.0) e `abuse_flags_json` (JSON array) calculados via Prompt Firewall `scan_for_abuse()` quando habilitado + detecção local de PII/sensível. Metodologia: [prompt_firewall.md#classificação-de-risco-scan_for_abuse](prompt_firewall.md#classificação-de-risco-scan_for_abuse).

---

## Módulos e paths

| Módulo | Caminho | Funções / notas |
|--------|---------|------------------|
| Main, /ask | `backend/app/main.py` | Fluxo completo; headers; audit enqueue. |
| Security | `backend/app/security.py` | `normalize_question`, `detect_prompt_injection`, `detect_sensitive_request`. |
| Cache | `backend/app/cache.py` | `cache_key_for_question`, `get_json`, `set_json`, rate limit. |
| Redaction | `backend/app/redaction.py` | `normalize_text`, `sha256_text`, `redact_text`. |
| Quality | `backend/app/quality.py` | `detect_conflict`, `cross_check_ok`, `post_validate_answer`, `quality_threshold`, `compute_heuristic_confidence`, `combine_confidence`. |
| Retrieval | `backend/app/retrieval.py` | Embeddings (FastEmbed ou OpenAI), Qdrant, `select_evidence`, re-rank. |
| Observability | `backend/app/observability.py` | Middleware `X-Request-ID` / `X-Trace-ID`, structlog, OTel. |
| Audit | `backend/app/audit_store.py` | `AuditSession`, `AuditMessage`, `AuditAsk`, `AuditChunk`; MySQL ou noop. |
| Prompt firewall | `backend/app/prompt_firewall.py` | `check()` (bloqueio), `scan_for_abuse()` (classificação de risco), regras regex, métricas. |
| Abuse classifier | `backend/app/abuse_classifier.py` | `classify()` (integra Prompt Firewall quando habilitado), detecção local de PII/sensível, `should_save_raw()`, `flags_to_json()`. |

---

## Embeddings

- Default: FastEmbed, modelo `sentence-transformers/all-MiniLM-L6-v2` (384 dims). `retrieval.get_embeddings_provider`, `retrieval.FastEmbedEmbeddings`.
- Opcional: OpenAI `text-embedding-3-small` (ou `OPENAI_EMBEDDINGS_MODEL`) quando `USE_OPENAI_EMBEDDINGS` e `OPENAI_API_KEY`.

---

## Ordem do fluxo `/ask` (resumida)

1. Rate limit (Redis).
2. Prompt Firewall (se habilitado); match → REFUSAL.
3. Guardrails: injection → REFUSAL; sensitive/PII → REFUSAL.
4. `normalize_question` → cache key → Redis get.
5. Cache hit → 200 CACHE + audit.
6. Embed → Qdrant search top_k=8 → re-rank → `select_evidence` → `detect_conflict`.
7. Conflito irresolúvel → REFUSAL.
8. LLM generate; refusal/vazio → REFUSAL.
9. Confidence, `cross_check_ok`, `quality_threshold`, `post_validate_answer`; falha → REFUSAL.
10. Resposta 200 LLM; cache set; audit (ask, chunks).

Ver `main.py` e [architecture.md](architecture.md) para detalhes.
