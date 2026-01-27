# Snapshot Completo do Código

Documento de referência rápida com estrutura completa do projeto, módulos, responsabilidades e estatísticas.

**Data do snapshot:** 2026-01-26  
**Commit:** `06c017e` (feat: integração Prompt Firewall com abuse_classifier + regras de exfiltração + docs)

---

## 📁 Estrutura do Projeto

```
teste-overlabs/
├── backend/                    # Aplicação FastAPI
│   ├── app/                    # Módulos principais (18 arquivos)
│   ├── scripts/                # Scripts de ingestão e enriquecimento (5 arquivos)
│   ├── tests/                  # Testes unitários e prod-like (30+ arquivos)
│   ├── Dockerfile
│   ├── pyproject.toml
│   ├── requirements.txt
│   ├── requirements-dev.txt
│   └── requirements-extra.txt
├── config/                     # Configurações
│   └── prompt_firewall.regex  # Regras do Prompt Firewall (108 linhas)
├── docs/                       # Documentação (16 arquivos .md)
├── DOC-IA/                     # Documentos para ingestão
├── docker-compose.yml          # Stack Docker (api, qdrant, redis)
├── docker-compose.test.yml     # Stack para testes prod-like
├── env.example                 # Template de variáveis de ambiente
└── Makefile                    # Comandos auxiliares
```

---

## 🔧 Módulos Principais (`backend/app/`)

### Core da Aplicação

| Arquivo | Linhas | Responsabilidade Principal |
|---------|--------|---------------------------|
| `main.py` | ~1073 | FastAPI app, endpoint `/ask`, orquestração do pipeline RAG, guardrails, cache, retrieval, LLM, quality, audit |
| `config.py` | ~200 | Settings (pydantic), carregamento de env vars, configurações de todos os módulos |
| `schemas.py` | ~100 | Pydantic models: `AskRequest`, `AskResponse`, `SourceItem`, `RefusalReason` |

### Segurança e Guardrails

| Arquivo | Linhas | Responsabilidade Principal |
|---------|--------|---------------------------|
| `security.py` | ~100 | `normalize_question()`, `detect_prompt_injection()` (fallback), `detect_sensitive_request()` |
| `prompt_firewall.py` | ~400 | Regras regex, `normalize_for_firewall()`, `check()` (bloqueio), `scan_for_abuse()` (classificação), hot reload, métricas |
| `abuse_classifier.py` | ~92 | `classify()` (integra Prompt Firewall), detecção PII/sensível, `should_save_raw()`, `flags_to_json()` |

### RAG Pipeline

| Arquivo | Linhas | Responsabilidade Principal |
|---------|--------|---------------------------|
| `cache.py` | ~150 | Redis client, `cache_key_for_question()` (SHA256), `get_json()`/`set_json()`, rate limit |
| `retrieval.py` | ~300 | Embeddings (fastembed/OpenAI), Qdrant client, `select_evidence()`, re-rank (confiança/recência) |
| `quality.py` | ~400 | `detect_conflict()`, `cross_check_ok()`, `post_validate_answer()`, `compute_heuristic_confidence()` |
| `llm.py` | ~150 | `LLMProvider` interface, `OpenAILLM`, `StubLLM`, `LocalDeterministicLLM` |

### Observabilidade e Audit

| Arquivo | Linhas | Responsabilidade Principal |
|---------|--------|---------------------------|
| `observability.py` | ~200 | Middleware (X-Request-ID, X-Trace-ID), structlog, OpenTelemetry (opcional) |
| `metrics.py` | ~150 | Prometheus metrics: `request_count`, `cache_hit_count`, `refusal_count`, `firewall_*`, `request_latency` |
| `audit_store.py` | ~400 | `AuditSession`, `AuditMessage`, `AuditAsk`, `AuditChunk`, sinks (MySQL/noop), fila assíncrona |
| `trace_store.py` | ~200 | `PipelineTrace`, `TraceSink` interface, MySQL/noop sinks |
| `redaction.py` | ~150 | `redact_text()` (CPF, cartão, token, email, telefone), `normalize_text()` para hash |
| `crypto_simple.py` | ~100 | AES-256-GCM encryption/decryption, envelope JSON |

### Testing

| Arquivo | Linhas | Responsabilidade Principal |
|---------|--------|---------------------------|
| `testing_providers.py` | ~150 | `FakeCache`, `FakeRetriever`, `FakeEmbedder`, `StubLLM`, `FailOnCallLLM`, `LocalDeterministicLLM` |

---

## 📜 Scripts (`backend/scripts/`)

| Script | Responsabilidade |
|--------|-----------------|
| `scan_docs.py` | Varre `DOCS_ROOT`, classifica layout (L1_POLICY, L2_FAQ, etc.), gera `layout_report.md` |
| `ingest.py` | Chunking (~650 tokens, overlap 120), embeddings, upsert Qdrant, ignora PII/funcionários |
| `enrich_prompt_firewall.py` | CLI para enriquecer regras: `propose` (OpenAI API), `validate` (regex compile, performance, recall/FP), `apply` (patch) |
| `firewall_enrich_lib.py` | Biblioteca compartilhada para enriquecimento de regras |
| `test_api_security.py` | Testes manuais de segurança da API |

---

## 🧪 Testes (`backend/tests/`)

### Testes Unitários

| Arquivo | Cobertura |
|---------|-----------|
| `test_abuse_classifier.py` | `classify()`, integração com Prompt Firewall, flags, backward compatibility |
| `test_guardrails.py` | Injection, sensitive/PII, firewall blocking, fallback |
| `test_prompt_firewall_*.py` | Normalização, i18n, reload, métricas, hardening, fuzz, enriquecimento |
| `test_quality.py` | Conflito, cross-check, post-validation, confidence |
| `test_cache.py` | Redis get/set, cache key, rate limit |
| `test_audit_*.py` | Crypto, headers, redaction, persistência |
| `test_contract.py` | Contrato da API (sempre 200, headers, schemas) |
| `test_metrics.py` | Prometheus counters, histograms |
| `test_resilience.py` | Timeouts, erros, graceful degradation |
| `test_traceability.py` | Trace IDs, logs estruturados |

### Testes Prod-like (`tests/prodlike/`)

| Arquivo | Cobertura |
|---------|-----------|
| `test_prodlike_ingest_and_ask.py` | Ingest real + `/ask` end-to-end |
| `test_prodlike_audit.py` | Persistência MySQL, session, message, ask, chunks |
| `test_prodlike_cache_ttl.py` | TTL do cache Redis |
| `test_prodlike_conflict_resolution.py` | Conflito com dados reais |
| `test_prodlike_guardrail_no_llm_call.py` | Guardrails bloqueiam antes do LLM |
| `test_prodlike_sensitive_refusal.py` | Recusa por PII/sensível |

### Testes Property-based (`tests/property/`)

| Arquivo | Cobertura |
|---------|-----------|
| `test_fuzz_*.py` | Fuzz testing com `hypothesis`: injection, números, question format |
| `test_prompt_firewall_fuzz.py` | Fuzz do Prompt Firewall (normalização, regras) |

### Fixtures e Helpers

| Arquivo | Conteúdo |
|---------|----------|
| `conftest.py` | Fixtures pytest: `client`, `evidence`, `tmp_path`, etc. |
| `_fakes.py` | `FakeCache`, `FakeRetriever`, `FakeEmbedder`, `make_chunk()` |
| `firewall_cases.py` | Casos de teste para Prompt Firewall |
| `firewall_corpus/` | Corpus para validação de regras (malicious_i18n.txt, benign_i18n.txt) |

**Total de testes:** 30+ arquivos, cobertura meta: 80% em `backend/app/`

---

## 📚 Documentação (`docs/`)

### Documentação Principal

| Documento | Conteúdo |
|-----------|----------|
| `README.md` | **Guia do Avaliador** — ponto de entrada, como rodar, validação em 10 min |
| `architecture.md` | Componentes, C4, deployment, fluxo `/ask`, pipeline ingestão, decisões, mapa do código |
| `security.md` | Guardrails, Prompt Firewall, PII, audit, threat model (STRIDE lean) |
| `audit_logging.md` | Session tracking, answer source, persistência, `firewall_rule_ids`, queries SQL |
| `traceability.md` | Headers (X-Request-ID, X-Trace-ID), pipeline trace, OTel opcional |
| `observability.md` | Logs (structlog), Prometheus, OTel, SLOs sugeridos |
| `runbook.md` | Como rodar, scan/ingest, cache, Qdrant, Redis, troubleshooting |
| `ci.md` | Testes unitários, prod-like (Docker), coverage |

### Prompt Firewall

| Documento | Conteúdo |
|-----------|----------|
| `prompt_firewall.md` | Documentação principal: regras, normalização, `check()`, `scan_for_abuse()`, métricas |
| `prompt_firewall_enrichment.md` | CLI `enrich_prompt_firewall.py`, metodologia, corpus, validação |
| `prompt_firewall_analysis_guide.md` | Guia de análise de regras, performance, recall/FP |
| `prompt_firewall_examples.md` | Exemplos de mensagens bloqueadas por regra |
| `prompt_firewall_perf.md` | Performance, latência, otimizações |
| `prompt_firewall_test_cases.txt` | Casos de teste em texto |

### Referência

| Documento | Conteúdo |
|-----------|----------|
| `appendix_code_facts.md` | Referência para auditoria: endpoints, headers, hashing, conflito, módulos |
| `diagrams.md` | Galeria de diagramas Mermaid (C4, sequência, ER, observabilidade) |
| `db_audit_schema.sql` | Schema MySQL de audit (audit_session, audit_message, audit_ask, audit_retrieval_chunk) |
| `db_trace_schema.sql` | Schema MySQL de trace (opcional) |
| `layout_report.md` | Exemplo de saída do `scan_docs` |

---

## 🔌 Dependências Principais

### Runtime (`requirements.txt`)

- **FastAPI** — Framework web
- **uvicorn** — ASGI server
- **httpx** — Cliente HTTP assíncrono (OpenAI API)
- **qdrant-client** — Cliente Qdrant
- **redis** — Cliente Redis
- **fastembed** — Embeddings ONNX (sentence-transformers/all-MiniLM-L6-v2)
- **pydantic** — Validação de dados
- **structlog** — Logging estruturado JSON
- **prometheus-client** — Métricas Prometheus
- **cryptography** — AES-256-GCM
- **mysql-connector-python** — MySQL (audit opcional)

### Desenvolvimento (`requirements-dev.txt`)

- **pytest** — Framework de testes
- **pytest-asyncio** — Suporte async
- **httpx** — Cliente HTTP para testes
- **respx** — Mock de requisições HTTP
- **hypothesis** — Property-based testing
- **freezegun** — Mock de tempo
- **coverage** — Cobertura de código
- **faker** — Dados sintéticos

### Extras (`requirements-extra.txt`)

- **opentelemetry-api**, **opentelemetry-sdk** — OTel (opcional)

---

## 🐳 Docker Compose

### Serviços

| Serviço | Porta | Descrição |
|---------|-------|-----------|
| `api` | 8000 | FastAPI (Uvicorn) |
| `qdrant` | 6335→6333 | Vector DB |
| `redis` | 6379 | Cache e rate limit |

### Volumes

- `DOCS_HOST_PATH` → `/docs` (documentos para ingestão)
- `./docs` → `/app/docs` (layout_report.md)
- `./config` → `/app/config` (prompt_firewall.regex)
- `qdrant_storage` → persistência Qdrant

---

## ⚙️ Configuração (Variáveis de Ambiente)

### Core

- `QDRANT_URL`, `QDRANT_COLLECTION`, `REDIS_URL`, `DOCS_ROOT`
- `USE_OPENAI_EMBEDDINGS`, `OPENAI_API_KEY`, `OPENAI_MODEL`, `OPENAI_EMBEDDINGS_MODEL`
- `CACHE_TTL_SECONDS`, `RATE_LIMIT_PER_MINUTE`

### Segurança

- `PROMPT_FIREWALL_ENABLED`, `PROMPT_FIREWALL_RULES_PATH`
- `ABUSE_CLASSIFIER_ENABLED`, `ABUSE_RISK_THRESHOLD`

### Audit

- `AUDIT_LOG_ENABLED`, `AUDIT_LOG_INCLUDE_TEXT`, `AUDIT_LOG_REDACT`
- `AUDIT_LOG_RAW_MODE` (off|risk_only|always), `AUDIT_LOG_RAW_MAX_CHARS`
- `AUDIT_ENC_KEY_B64`, `AUDIT_ENC_AAD_MODE` (trace_id|request_id|none)
- `TRACE_SINK` (noop|mysql), `MYSQL_*`

### Observabilidade

- `OTEL_ENABLED`, `OTEL_EXPORTER_OTLP_ENDPOINT`
- `PIPELINE_LOG_ENABLED`, `PIPELINE_LOG_INCLUDE_TEXT`

---

## 📊 Estatísticas do Código

### Módulos (`backend/app/`)

- **Total de arquivos:** 18
- **Linhas de código (estimado):** ~3500+
- **Módulo maior:** `main.py` (~1073 linhas)
- **Módulos principais:** `prompt_firewall.py` (~400), `quality.py` (~400), `audit_store.py` (~400)

### Testes (`backend/tests/`)

- **Total de arquivos:** 30+
- **Testes unitários:** ~25 arquivos
- **Testes prod-like:** 6 arquivos
- **Testes property-based:** 4 arquivos
- **Cobertura meta:** 80% em `backend/app/`

### Documentação (`docs/`)

- **Total de arquivos:** 16 arquivos .md
- **Schema SQL:** 2 arquivos
- **Total de páginas:** ~2000+ linhas de documentação

### Configuração

- **Regras Prompt Firewall:** 108 linhas (`config/prompt_firewall.regex`)
- **Variáveis de ambiente:** ~40+ (ver `env.example`)

---

## 🔑 Funcionalidades Principais

### RAG Pipeline

1. ✅ Validação de input (3-2000 chars, sem control chars)
2. ✅ Rate limit (Redis por IP)
3. ✅ Classificação de abuso (`abuse_classifier` + Prompt Firewall)
4. ✅ Prompt Firewall (regex blocking, `firewall_rule_ids` no audit)
5. ✅ Guardrails fallback (injection, sensitive/PII)
6. ✅ Cache Redis (SHA256 da pergunta normalizada)
7. ✅ Embeddings (fastembed ONNX ou OpenAI)
8. ✅ Retrieval Qdrant (top_k=8)
9. ✅ Re-rank (confiança/recência)
10. ✅ Detecção de conflito (prazos/datas por escopo)
11. ✅ LLM (OpenAI gpt-4o-mini ou stub)
12. ✅ Quality checks (threshold, cross-check, post-validation)
13. ✅ Audit logging (session, message, ask, chunks, criptografia condicional)

### Segurança

- ✅ Prompt Firewall (regex, hot reload, métricas)
- ✅ `scan_for_abuse()` para classificação de risco
- ✅ Integração Prompt Firewall ↔ abuse_classifier
- ✅ Detecção de injection (firewall + fallback)
- ✅ Detecção de PII/sensível (CPF, cartão, token, etc.)
- ✅ Redaction automática (CPF, cartão, email, telefone)
- ✅ Criptografia AES-256-GCM (raw logging condicional)
- ✅ Rate limiting

### Observabilidade

- ✅ Logs estruturados JSON (structlog)
- ✅ Métricas Prometheus (`/metrics`)
- ✅ OpenTelemetry (opcional)
- ✅ Headers de rastreabilidade (X-Request-ID, X-Trace-ID, X-Chat-Session-ID)
- ✅ Pipeline trace (eventos detalhados)

### Audit

- ✅ Session tracking
- ✅ Answer source (CACHE|LLM|REFUSAL)
- ✅ Persistência MySQL (assíncrona)
- ✅ `firewall_rule_ids` quando bloqueado
- ✅ `abuse_risk_score` e `abuse_flags_json`
- ✅ Texto redigido e bruto criptografado (condicional)

---

## 🚀 Endpoints da API

| Endpoint | Método | Descrição |
|----------|--------|-----------|
| `/ask` | POST | Endpoint principal RAG. Request: `{"question": "..."}`. Response sempre 200 (inclusive REFUSAL). Headers: `X-Answer-Source`, `X-Trace-ID`, `X-Request-ID`, `X-Chat-Session-ID`. |
| `/healthz` | GET | Health check básico |
| `/readyz` | GET | Readiness check (Redis + Qdrant) |
| `/metrics` | GET | Métricas Prometheus |

---

## 📝 Notas Importantes

### Contrato da API

- **Sempre retorna 200** quando input é válido (incluindo recusas)
- Recusa: `answer` genérico, `sources=[]`, `confidence` ≤ 0,3, `X-Answer-Source=REFUSAL`
- Cache hit: `X-Answer-Source=CACHE`
- Resposta LLM: `X-Answer-Source=LLM`

### Integração Prompt Firewall ↔ Abuse Classifier

- `abuse_classifier.classify()` chama `firewall.scan_for_abuse()` quando firewall habilitado
- `scan_for_abuse()` calcula `risk_score` e `flags` baseado em categorias de regras
- `abuse_classifier` mantém apenas detecção local de PII/sensível (não coberto pelo firewall)
- Resultado combinado usado para audit e decisão de criptografia raw

### Hash de Cache vs Audit

- **Cache:** `security.normalize_question()` (lower, collapse ws) → SHA256
- **Audit:** `redaction.normalize_text()` (sem lower) → SHA256
- **Distintos** — propósito diferente

### Limitações Conhecidas

- Prompt Firewall desabilitado por padrão
- Audit MySQL requer `TRACE_SINK=mysql` e `MYSQL_*` configurados
- OTel opcional; não quebra se não houver collector
- Autenticação: JWT apenas extrai `user_id` para audit (sem validação de assinatura)

---

## 🔗 Links Úteis

- **Documentação principal:** [docs/README.md](README.md)
- **Arquitetura:** [docs/architecture.md](architecture.md)
- **Segurança:** [docs/security.md](security.md)
- **Audit:** [docs/audit_logging.md](audit_logging.md)
- **Prompt Firewall:** [docs/prompt_firewall.md](prompt_firewall.md)
- **Runbook:** [docs/runbook.md](runbook.md)

---

**Última atualização:** 2026-01-26  
**Versão do snapshot:** 1.0
