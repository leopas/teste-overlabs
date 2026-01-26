---
name: tests-prodlike-fastapi-rag-v2
overview: Implementar suíte de testes unit + prod-like (Qdrant+Redis reais via Docker) exercitando o pipeline real de ingest/retrieval/cache usando o embedder configurado no `.env` (incluindo OpenAI embeddings), isolando apenas o LLM com um provedor determinístico local; sem GitHub Actions, com execução documentada em `docs/ci.md`.
todos:
  - id: dev-deps
    content: Adicionar backend/requirements-dev.txt, pytest.ini e configuração de coverage.
    status: completed
  - id: di-refactor
    content: Refatorar backend/app/main.py para providers + app.state + create_app(test_overrides).
    status: completed
  - id: collection-config
    content: Adicionar QDRANT_COLLECTION no config e aplicar em retrieval + scripts/ingest.py para permitir coleções únicas por teste.
    status: completed
  - id: testing-providers
    content: Criar backend/app/testing_providers.py com LocalDeterministicLLM, FailOnCallLLM e SpyLLM.
    status: completed
  - id: unit-tests
    content: Implementar unit tests (contrato, guardrails, qualidade, cache, resiliência, métricas, readyz).
    status: completed
  - id: prodlike-infra
    content: Criar docker-compose.test.yml + Makefile targets com COMPOSE_PROJECT_NAME=ragtest e portas 6336/6380.
    status: completed
  - id: prodlike-tests
    content: Implementar testes prod-like com ingest real em docs sintéticos e coleção Qdrant única por execução, isolando apenas LLM.
    status: completed
  - id: property-tests
    content: Implementar property tests com Hypothesis (sem Docker) e limites para <60s.
    status: completed
  - id: docs
    content: Criar docs/ci.md e atualizar README com como rodar testes e observações de embeddings OpenAI nos prod-like.
    status: completed
---

## Escopo (V2)

- **Unit tests**: rápidos e determinísticos (sem Docker, sem rede).
- **Prod-like tests**: sobem **Qdrant + Redis reais via Docker**, rodam **ingest real** em docs sintéticos e chamam `/ask` via **ASGITransport**.
- **LLM**: sempre local/determinística por padrão (`LocalDeterministicLLM`).
- **Embeddings**: usar o **embedder real configurado no `.env`**; você escolheu **usar OpenAI embeddings nos prod-like** (isso envolve rede/custo e pode flake).
- **Sem GitHub Actions**: documentar em [`docs/ci.md`](docs/ci.md).

## Mudanças necessárias na base (refactor mínimo, sem mudar produção)

### 1) DI mínima e app.state

Arquivo: [`backend/app/main.py`](backend/app/main.py)

- Criar providers:
- `get_cache(settings)`
- `get_retriever(settings)`
- `get_embedder(settings)`
- `get_llm(settings)`
- Alterar `create_app(test_overrides: dict | None = None)`:
- Em produção: comportamento idêntico.
- Em testes: permitir sobrescrever só o que precisar.
- Guardar dependências em:
- `app.state.cache`, `app.state.retriever`, `app.state.embedder`, `app.state.llm`

Motivo: permite testes “não chamar LLM” (FailOnCall) e contadores/spy sem mocks globais.

### 2) Collection name dinâmica por teste

Hoje a collection é fixa `docs_chunks` (`COLLECTION_NAME` em `backend/app/retrieval.py` e usado em `backend/scripts/ingest.py`).

Mudança proposta:

- Adicionar em [`backend/app/config.py`](backend/app/config.py) um setting `qdrant_collection` (default `docs_chunks`) vindo de env `QDRANT_COLLECTION`.
- Ajustar retrieval e ingest para usar `settings.qdrant_collection`.

Motivo: prod-like cria `collection_name = test_chunks_<uuid>` e deleta ao final, sem “sujeira”.

### 3) Providers de teste para LLM

Criar [`backend/app/testing_providers.py`](backend/app/testing_providers.py) com:

- `LocalDeterministicLLM`: escolhe evidência de maior score, extrai 1 frase que já exista no texto (sem inventar), retorna JSON estrito.
- `FailOnCallLLM`: qualquer chamada => `RuntimeError`.
- `SpyLLM` (e opcional `SpyRetriever`/`SpyCache`).

## Dependências dev e config

Criar [`backend/requirements-dev.txt`](backend/requirements-dev.txt):

- pytest, pytest-asyncio, httpx
- hypothesis, freezegun, coverage[toml], faker
- respx opcional (apenas se for necessário mockar rede em unit tests)

Config:

- [`backend/pytest.ini`](backend/pytest.ini) (markers: `prodlike`, `live_llm`, `live_embeddings`)
- `.coveragerc` ou coverage em `pyproject` (meta 80% em `backend/app`, excluindo `backend/scripts`).

## Infra prod-like (Docker)

Criar `docker-compose.test.yml` (minimalista) com:

- `qdrant-test` (porta host fixa **6336**)
- `redis-test` (porta host fixa **6380**)
- `COMPOSE_PROJECT_NAME=ragtest` para isolar rede/volumes

## Estrutura de testes

Criar `backend/tests/`:

- unit: `test_contract.py`, `test_guardrails.py`, `test_quality.py`, `test_cache.py`, `test_resilience.py`, `test_metrics.py`, `test_readyz.py`
- prodlike (marker `@pytest.mark.prodlike`):
- `prodlike/test_prodlike_ingest_and_ask.py`
- `prodlike/test_prodlike_cache_ttl.py`
- `prodlike/test_prodlike_conflict_resolution.py`
- `prodlike/test_prodlike_guardrail_no_llm_call.py`
- `prodlike/test_prodlike_sensitive_refusal.py`
- property: `property/test_fuzz_question.py`, `property/test_fuzz_injection.py`, `property/test_fuzz_numbers.py`

## Makefile

Criar `Makefile` na raiz:

- `make test-unit` (unit + property, sem docker)
- `make test-prod` (sobe docker test, roda `-m prodlike`, derruba e limpa)
- `make test` (unit + prodlike)
- `make test-live` (opcional: roda `-m live_llm` se `OPENAI_API_KEY` existir)

Como você pediu, `make test` inclui prod-like.

## Como os prod-like tests vão rodar (fluxo)

Para cada teste/fixture de sessão:

1. `docker compose -f docker-compose.test.yml up -d`
2. Criar docs sintéticos em `tmp_path` (POLICY/GENERAL/FAQ/MANUAL + arquivo com CPF para garantir bloqueio)
3. Rodar ingest real (`python backend/scripts/ingest.py`) com env:

- `DOCS_ROOT=<tmp_path>`
- `QDRANT_URL=http://localhost:6336`
- `REDIS_URL=redis://localhost:6380/0`
- `QDRANT_COLLECTION=test_chunks_<uuid>`
- embeddings conforme `.env` (incluindo OpenAI embeddings)

4. Subir app via `create_app(test_overrides={"llm": LocalDeterministicLLM()})`
5. Chamar `/ask` via ASGITransport
6. Assert de contrato, qualidade, cache hit, guardrails, etc.
7. Deletar collection no teardown e `docker compose down -v` no final.

## Documentação

Criar [`docs/ci.md`](docs/ci.md) com pré-requisitos e comandos:

- `pip install -r backend/requirements.txt -r backend/requirements-dev.txt`
- `make test-unit`
- `make test-prod`
- `make test`

Atualizar `README.md` com “Como rodar testes”.

## Riscos/Observações

- Você escolheu **OpenAI embeddings nos prod-like**: isso faz chamadas externas e pode flake. Vamos:
- Colocar timeouts curtos.
- Permitir skip controlado se `OPENAI_API_KEY` não existir (ou falhar).
- Registrar claramente em `docs/ci.md`.