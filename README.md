## MVP RAG (FastAPI + Qdrant + Redis) — R1

Backend com RAG e **recusa quando não há evidência**, priorizando documentos **mais confiáveis e mais recentes**. Funciona sem chave OpenAI (modo stub).

### Stack
- **FastAPI** (`/ask`, `/healthz`, `/readyz`, `/metrics`, `/docs`)
- **Qdrant** (vector DB)
- **Redis** (cache + rate limit)
- **Embeddings (default local, leve)**: `fastembed` (ONNX) com o modelo `sentence-transformers/all-MiniLM-L6-v2` (default) ou OpenAI (opcional)
- **LLM**: OpenAI (opcional) ou **stub** (sem chave => recusa)

### Pré-requisitos
- Docker + Docker Compose (no Windows, normalmente via Docker Desktop)
- A pasta de documentos do desafio disponível no host (ex.: `C:/Projetos/teste-wayon/DOC-IA`)

### Como rodar
1) (Opcional) Crie um `.env` a partir de `env.example` e ajuste `DOCS_HOST_PATH`.
   - Exemplo (Windows): `DOCS_HOST_PATH=C:/Projetos/teste-wayon/DOC-IA`
   - Porta padrão do Qdrant no host: `QDRANT_PORT=6335` (mude se já estiver em uso)
   - Para **logs detalhados do pipeline** do `/ask`:
     - `PIPELINE_LOG_ENABLED=1`
     - (opcional) `PIPELINE_LOG_INCLUDE_TEXT=1` para logar **excerpts curtos** dos chunks (não loga chunks inteiros)

2) Suba tudo:

```bash
docker compose up --build
```

3) Acesse:
- Swagger: `http://localhost:8000/docs`
- Liveness: `http://localhost:8000/healthz`
- Readiness: `http://localhost:8000/readyz`
- Métricas: `http://localhost:8000/metrics`

### Como indexar documentos
Os docs do host são montados em `/docs` dentro do container (via `DOCS_HOST_PATH` no compose).

1) Gerar relatório de layout:

```bash
docker compose run --rm api python scripts/scan_docs.py
```

2) Ingerir e indexar:

```bash
docker compose run --rm api python scripts/ingest.py
```

> R1 ingere apenas `.txt` e `.md`. Arquivos com indícios de PII (ex.: CPF) e/ou `funcionarios` no nome **são ignorados**.

### Testar o `/ask`
Exemplos (PowerShell):

```powershell
Invoke-RestMethod -Method Post -Uri http://localhost:8000/ask -ContentType 'application/json' -Body '{"question":"Qual o prazo para reembolso de despesas nacionais?"}'
Invoke-RestMethod -Method Post -Uri http://localhost:8000/ask -ContentType 'application/json' -Body '{"question":"Qual o prazo de reembolso?"}'
Invoke-RestMethod -Method Post -Uri http://localhost:8000/ask -ContentType 'application/json' -Body '{"question":"Qual é o CPF da Maria Oliveira?"}'
```

### Como rodar testes (unit + prod-like)
Instalar deps:

```bash
python -m pip install -r backend/requirements.txt -r backend/requirements-dev.txt
```

Rodar unit + fuzz (sem Docker):

```bash
cd backend
pytest -q -m "not prodlike"
pytest -q tests/property
```

Rodar prod-like (Qdrant+Redis reais via Docker):

```bash
docker compose -f docker-compose.test.yml up -d
cd backend
set QDRANT_URL=http://localhost:6336
set REDIS_URL=redis://localhost:6380/0
pytest -q -m prodlike
cd ..
docker compose -f docker-compose.test.yml down -v
```

Detalhes: veja [`docs/ci.md`](docs/ci.md).

### Traceability (rastreabilidade)
Cada chamada ao `POST /ask` gera um trace técnico correlacionado por:
- `X-Request-ID`
- `X-Trace-ID`
- `user_id` (quando houver `Authorization: Bearer <JWT>` com claim `user_id`)

Mais detalhes (OTel + MySQL sink opcional): [`docs/traceability.md`](docs/traceability.md).

### Como o sistema evita “inventar”
- **Somente** usa trechos recuperados do Qdrant como evidência.
- Se não houver base suficiente, retorna recusa padrão (HTTP 200):

```json
{ "answer": "Não encontrei informações confiáveis para responder essa pergunta.", "confidence": 0.2, "sources": [] }
```

### Prioridade de fontes (conflitos)
Cada chunk tem `trust_score` e `freshness_score`. Em conflitos (ex.: versões v1 vs v3), o sistema tenta resolver por **maior confiança e maior recência**; se continuar ambíguo, **recusa**.

### Mecanismos de qualidade (4)
- **A) Threshold**: se `confidence < 0.65` => recusa
- **B) Validação cruzada**: só responde se:
  - 2 fontes concordam, **ou**
  - 1 fonte `POLICY/MANUAL` com `trust_score >= 0.85` e sem conflito
- **C) Conflito não resolvido** => recusa
- **D) Pós-validador**: se a resposta contém claims (ex.: números) não suportados pelos trechos => recusa

### Cache, custo, resiliência
- **Cache**: sha256 da pergunta normalizada, TTL 10 min.
- **Resiliência**: se Qdrant/Redis estiverem indisponíveis, `/readyz` falha; `/ask` **não quebra** (retorna recusa padrão).

### Monitoramento
- Logs JSON (request_id, latency, cache_hit, refusal_reason, top_docs)
- Métricas Prometheus em `/metrics`
- OpenTelemetry opcional (ativável por env; sem collector não quebra)

### Limitações (R1)
- Sem frontend (R2).
- Sem ingestão de documentos de funcionários/PII (R2).

### Roadmap (R2)
- UI de chat + login
- RBAC/ABAC por funcionário/unidade
- PII masking + audit logs + políticas de retenção + criptografia
- Filtros no Qdrant por permissões/atributos

### Documentação adicional
- [`docs/architecture.md`](docs/architecture.md)
- `docs/layout_report.md` (gerado pelo scan)

