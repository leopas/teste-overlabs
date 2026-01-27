# Guia do Avaliador — RAG MVP

Documentação para banca técnica: escopo, como rodar e como validar em poucos minutos.

---

## O que é

Sistema **RAG (Retrieval Augmented Generation)** que responde perguntas sobre documentos internos. Inclui:

- **R1 (escopo atual):** Ingestão de `.txt`/`.md`, chunking por layout, busca vetorial (Qdrant), re-rank por confiança/recência, geração via LLM (OpenAI ou stub), **recusa** quando não há evidência ou falha em guardrails/qualidade. Cache Redis por hash da pergunta. Guardrails (injection, sensível/PII), **Prompt Firewall** opcional (regex), auditoria (hashes, redaction, criptografia condicional), métricas Prometheus e logs estruturados.

- **R2 (fora do escopo):** Docs de funcionários/CPF na base vetorial (ficam de fora na ingestão). Autenticação forte (JWT é apenas extração de `user_id` para audit). UI.

---

## Como rodar

1. **Pré-requisitos:** Docker, Docker Compose. Opcional: Python 3.12+ para rodar scripts/ testes locais.

2. **Stack com Docker:**

   ```bash
   cp env.example .env   # ajustar DOCS_HOST_PATH, etc.
   docker compose up -d
   ```

   Sobe API (porta 8000), Qdrant (6335), Redis (6379). Documentos em `DOCS_HOST_PATH` (default `./DOC-IA`) são montados em `/docs`.

3. **Scan + Ingest:**

   ```bash
   docker compose exec api python -m scripts.scan_docs
   docker compose exec api python -m scripts.ingest
   ```

   O relatório de layout vai para `./docs/layout_report.md` (volume `./docs` → `/app/docs`).

4. **Testar o `/ask`:**

   ```bash
   curl -X POST http://localhost:8000/ask -H "Content-Type: application/json" -d "{\"question\": \"Qual o prazo de reembolso?\"}"
   ```

---

## Como validar (checklist rápido)

| Item | Como validar |
|------|--------------|
| Stack sobe | `docker compose up -d` → `docker compose ps` todos healthy |
| Scan/Ingest | `scan_docs` + `ingest` → `layout_report.md` atualizado; ingest imprime chunks indexados |
| `POST /ask` 200 | Incluindo recusa: `sources=[]`, `confidence` ≤ 0.3, mas sempre **200** |
| Headers | `X-Trace-ID`, `X-Request-ID`, `X-Answer-Source` (CACHE \| LLM \| REFUSAL), `X-Chat-Session-ID` |
| `/metrics` | `curl http://localhost:8000/metrics` → `request_count`, `cache_hit_count`, `refusal_count`, `request_latency_seconds`, etc. |
| Health | `GET /healthz` → 200; `GET /readyz` → 200 se Redis + Qdrant ok |

Detalhes de **como rodar local vs Docker**, scan/ingest, cache, Qdrant e Redis: [Runbook](runbook.md).

---

## Documentação principal

| Documento | Conteúdo |
|-----------|----------|
| [Arquitetura e fluxos](architecture.md) | Componentes, C4, deployment, sequência `/ask`, pipeline de ingestão, decisões, mapa do código |
| [Layout (relatório gerado)](layout_report.md) | Exemplo de saída do `scan_docs` e recomendações de chunking |
| [Rastreabilidade](traceability.md) | Headers, trace_id/request_id, pipeline trace, OTel opcional |
| [Audit logging](audit_logging.md) | Session, answer source, persistência (audit_session, audit_message, audit_ask, chunks), rule_id no firewall |
| [Segurança](security.md) | Guardrails, Prompt Firewall, PII, audit, threat model |
| [Observabilidade](observability.md) | Logs, Prometheus, OTel, SLOs sugeridos |
| [CI e testes](ci.md) | Testes unitários, prod-like (Docker), coverage |
| [Runbook](runbook.md) | Como rodar, scan/ingest, cache, Qdrant, Redis |
| [Diagramas](diagrams.md) | Galeria de diagramas Mermaid com links para os docs |

---

## Contrato da API: por que sempre 200?

O `POST /ask` **sempre retorna 200** quando o input é válido (incluindo recusas). Erros de validação (ex.: `question` inválida) retornam 422.

- **Recusa:** `answer` genérico, `sources=[]`, `confidence` ≤ 0,3. Header `X-Answer-Source=REFUSAL`.
- **Cache hit:** Resposta armazenada; `X-Answer-Source=CACHE`.
- **Resposta do LLM:** `X-Answer-Source=LLM`.

Isso permite que clientes tratem sucesso/recusa apenas pelo corpo e pelos headers, sem depender de códigos HTTP diferentes para “não responder”.

---

## Limitações

- **Autenticação:** Não há validação de assinatura JWT; `user_id` é extraído apenas para auditoria.
- **Prompt Firewall:** Desabilitado por padrão; regras em arquivo regex.
- **Audit em MySQL:** Exige `TRACE_SINK=mysql` e `MYSQL_*` configurados; caso contrário, audit sink é noop.
- **OTel:** Opcional; não quebra se não houver collector.

---

## Mapa rápido do código

| Módulo | Responsabilidade |
|--------|------------------|
| `app.main` | FastAPI, `/ask`, guardrails, cache, retrieval, LLM, quality, audit, headers |
| `app.security` | `normalize_question`, `detect_prompt_injection`, `detect_sensitive_request` |
| `app.prompt_firewall` | Regras regex, normalização, `check()`, métricas |
| `app.cache` | Redis: `cache_key_for_question` (SHA256), `get_json`/`set_json`, rate limit |
| `app.retrieval` | Embeddings, Qdrant, `select_evidence`, re-rank |
| `app.quality` | Conflito, confidence, threshold, cross-check, post-validation |
| `app.llm` | OpenAI ou stub |
| `app.audit_store` | `AuditSession`, `AuditMessage`, `AuditAsk`, `AuditChunk`; sink MySQL ou noop |
| `app.observability` | Middleware (X-Request-ID, X-Trace-ID), structlog, OTel |
| `app.metrics` | Prometheus: request_count, cache_hit_count, refusal_count, latency, firewall_* |
| `scripts.scan_docs` | Layout em `DOCS_ROOT` → `layout_report.md` |
| `scripts.ingest` | Chunking, embeddings, upsert Qdrant; ignora PII/funcionários |
