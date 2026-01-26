## CI local (sem GitHub Actions)

Este repositório não inclui workflow de GitHub Actions por decisão do projeto. A ideia é que `make test` funcione como um “CI local”.

### Pré-requisitos
- Python 3.12+ (ou o Python do seu ambiente)
- Docker Desktop ligado (para os testes prod-like)

### Instalar dependências

```bash
python -m pip install -r backend/requirements.txt -r backend/requirements-dev.txt
```

### Rodar testes unit + fuzz (sem Docker)

```bash
cd backend
pytest -q -m "not prodlike"
pytest -q tests/property
```

### Rodar testes prod-like (Qdrant + Redis reais via Docker)
Os testes prod-like sobem `qdrant-test` e `redis-test` via `docker-compose.test.yml` (porta 6336/6380) e rodam ingest real em documentos sintéticos.

```bash
docker compose -f docker-compose.test.yml up -d
cd backend
set QDRANT_URL=http://localhost:6336
set REDIS_URL=redis://localhost:6380/0
pytest -q -m prodlike
cd ..
docker compose -f docker-compose.test.yml down -v
```

### Observação sobre embeddings “ativos” do ambiente
Os prod-like usam o embedder configurado por env:
- `USE_OPENAI_EMBEDDINGS=1` + `OPENAI_API_KEY` => embeddings OpenAI (rede/custo/possível flake)
- caso contrário => `fastembed` (ONNX) local

### Observação sobre MySQL (trace sink)
O schema está em `docs/db_trace_schema.sql`. Para aplicar, use as variáveis `MYSQL_*` no `.env`.

### Cobertura
O coverage está configurado em `backend/pyproject.toml` (meta 80% em `backend/app`, exclui scripts e tests).

```bash
cd backend
coverage run -m pytest -q
coverage report
```

