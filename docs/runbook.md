# Runbook — Como rodar e depurar

Como subir a stack, rodar scan/ingest, simular cache hit/miss, inspecionar Qdrant e Redis (sem expor conteúdo sensível).

---

## O que é

Guia operacional para rodar a API com Docker ou local (Redis + Qdrant acessíveis), executar ingestão, validar cache e consultar vetores/Redis de forma segura.

---

## Como rodar

### Com Docker (recomendado)

1. Copiar e ajustar env:
   ```bash
   cp env.example .env
   # Editar DOCS_HOST_PATH (pasta com .txt/.md), portas, etc.
   ```
2. Subir a stack:
   ```bash
   docker compose up -d
   ```
3. Verificar saúde:
   ```bash
   curl http://localhost:8000/healthz
   curl http://localhost:8000/readyz
   ```

A API usa `DOCS_ROOT=/docs` (montado de `DOCS_HOST_PATH`). O volume `./docs` do host é montado em `/app/docs` (relatórios e `layout_report.md`).

### Local (sem Docker na API)

- Redis e Qdrant precisam estar acessíveis (ex.: via `docker compose` só dos bancos, ou instâncias locais).
- No `.env` (ou env): `REDIS_URL`, `QDRANT_URL`, `DOCS_ROOT` (caminho para os documentos).
- Instalar deps e rodar:
  ```bash
  cd backend
  pip install -r requirements.txt -r requirements-dev.txt
  uvicorn app.main:app --host 0.0.0.0 --port 8000
  ```
- Scripts `scan_docs` / `ingest`: `DOCS_ROOT` e `LAYOUT_REPORT_PATH` (para scan) devem apontar para os mesmos diretórios que a API usa.

---

## Scan e ingest

1. **Scan de layouts**
   ```bash
   docker compose exec api python -m scripts.scan_docs
   ```
   - Varre `DOCS_ROOT` (/docs no container).
   - Gera `layout_report.md` em `LAYOUT_REPORT_PATH` (default `/app/docs/layout_report.md` → `./docs/layout_report.md` no host).

2. **Ingest**
   ```bash
   docker compose exec api python -m scripts.ingest
   ```
   - Lê os mesmos arquivos em `DOCS_ROOT`.
   - Ignora arquivos com CPF ou `funcionarios` no path; só `.txt` e `.md`.
   - Chunking → embeddings → upsert na coleção Qdrant (`QDRANT_COLLECTION`).

Confira `./docs/layout_report.md` após o scan. O ingest imprime quantidade de chunks indexados e arquivos ignorados.

---

## Simular cache hit / miss

- **Hit:** Duas chamadas `POST /ask` com a **mesma pergunta** (após normalização). A segunda deve retornar `X-Answer-Source: CACHE` e latência menor.
- **Miss:** Pergunta diferente ou após `CACHE_TTL_SECONDS` (default 600). Retorno `X-Answer-Source: LLM` ou `REFUSAL`.

Não há comando dedicado para “limpar” o cache; use TTL ou reinicie o Redis.

---

## Inspecionar Qdrant

- **Base:** `QDRANT_URL` (ex.: `http://localhost:6335` com compose).
- **Coleção:** `QDRANT_COLLECTION` (default `docs_chunks`).

Exemplos sem expor texto sensível:

1. **Listar coleções**
   ```bash
   curl -s "http://localhost:6335/collections"
   ```
2. **Info da coleção**
   ```bash
   curl -s "http://localhost:6335/collections/docs_chunks"
   ```
3. **Scroll (sem payload de texto)**  
   Use a API REST de scroll limitando `with_payload` a campos não sensíveis (ex.: `path`, `doc_type`, `chunk_index`). Evite exibir `text` em logs ou relatórios.

Payload típico dos pontos: `doc_id`, `title`, `path`, `updated_at`, `doc_type`, `trust_score`, `freshness_score`, `chunk_index`, `text`.

---

## Inspecionar Redis (prefixos, sem conteúdo)

- **Cache de respostas:** chaves = SHA256 da pergunta normalizada (64 hex). **Sem prefixo.** Não inspecionar o valor (pode conter respostas).
- **Rate limit:** prefixo `rl:`; chaves `rl:<ip>:<epochMinute>`.

Exemplo seguro (só listar chaves, sem `GET` de valor):

```bash
docker compose exec redis redis-cli KEYS "rl:*"
```

Para cache, as chaves são hashes brutos; não use `KEYS *` em produção. Preferir `SCAN` com prefixo se houver algum no futuro.

---

## Configuração (env vars relevantes)

Apenas **nomes**:

- `DOCS_HOST_PATH`, `DOCS_ROOT`, `LAYOUT_REPORT_PATH`
- `QDRANT_URL`, `QDRANT_COLLECTION`, `REDIS_URL`
- `CACHE_TTL_SECONDS`, `RATE_LIMIT_PER_MINUTE`

---

## Como validar

- Stack sobe: `docker compose up -d` e `readyz` 200.
- Scan: `layout_report.md` em `./docs` atualizado.
- Ingest: logs com “chunks indexados” e eventual “ignorados”.
- Cache: duas `POST /ask` idênticas → segunda com `X-Answer-Source: CACHE`.
- Qdrant: `GET /collections/docs_chunks` retorna informação da coleção.
- Redis: `KEYS "rl:*"` mostra apenas rate limit; não expor valores de cache.

---

## Limitações

- Rodar “local” exige Redis e Qdrant já provisionados.
- Scan/ingest assumem `DOCS_ROOT` e layout conforme `layout_report`; outros formatos podem precisar de ajustes.

Ver também [README](README.md), [Arquitetura](architecture.md), [CI](ci.md).
