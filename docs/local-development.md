# Guia de Desenvolvimento Local

Guia completo para configurar e rodar o projeto localmente.

## Pré-requisitos

- **Docker Desktop** (Windows/Mac) ou **Docker + Docker Compose** (Linux)
- **Python 3.12+** (opcional, para rodar API sem Docker)
- **Git**
- Pasta de documentos disponível (ex.: `DOC-IA/`)

## Setup Inicial

### 1. Clonar o Repositório

```bash
git clone <repo-url>
cd teste-overlabs
```

### 2. Configurar Variáveis de Ambiente

Crie um arquivo `.env` a partir do exemplo:

```bash
cp env.example .env
```

Edite o `.env` e configure pelo menos:

```bash
# Caminho para os documentos (ajuste para seu sistema)
DOCS_HOST_PATH=./DOC-IA  # Windows: C:/Projetos/teste-overlabs/DOC-IA

# Portas (ajuste se houver conflitos)
API_PORT=8000
QDRANT_PORT=6335
REDIS_PORT=6379

# OpenAI (opcional - pode deixar vazio para modo stub)
OPENAI_API_KEY=
```

**Nota**: O sistema funciona sem `OPENAI_API_KEY` (usa stub determinístico).

## Rodar com Docker Compose (Recomendado)

### Subir a Stack

```bash
docker compose up --build
```

Isso sobe:
- **API** na porta 8000 (ou `API_PORT`)
- **Qdrant** na porta 6335 (ou `QDRANT_PORT`)
- **Redis** na porta 6379 (ou `REDIS_PORT`)

### Verificar Saúde

```bash
# Health check
curl http://localhost:8000/healthz

# Readiness (verifica Qdrant e Redis)
curl http://localhost:8000/readyz

# Métricas Prometheus
curl http://localhost:8000/metrics
```

### Acessar Swagger UI

Abra no navegador: http://localhost:8000/docs

## Rodar API Localmente (sem Docker)

Útil para desenvolvimento e debug.

### Pré-requisitos

- Redis e Qdrant rodando (via Docker Compose ou instâncias locais)

### Setup

1. **Instalar dependências**:
   ```bash
   cd backend
   pip install -r requirements.txt -r requirements-dev.txt
   ```

2. **Configurar variáveis de ambiente**:
   ```bash
   export QDRANT_URL=http://localhost:6335
   export REDIS_URL=redis://localhost:6379/0
   export DOCS_ROOT=./DOC-IA  # Caminho para documentos
   ```

3. **Rodar a API**:
   ```bash
   uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
   ```

O `--reload` habilita auto-reload quando arquivos mudam.

## Indexar Documentos

### 1. Gerar Relatório de Layout

Analisa os documentos e gera `layout_report.md`:

```bash
# Com Docker
docker compose exec api python -m scripts.scan_docs

# Localmente
cd backend
python -m scripts.scan_docs
```

O relatório é salvo em `docs/layout_report.md`.

### 2. Ingerir e Indexar

Indexa os documentos no Qdrant:

```bash
# Com Docker
docker compose exec api python -m scripts.ingest

# Localmente
cd backend
python -m scripts.ingest
```

**O que acontece**:
- Lê arquivos `.txt` e `.md` de `DOCS_ROOT`
- Ignora arquivos com CPF ou `funcionarios` no path
- Faz chunking por headings/FAQ (~650 tokens, overlap 120)
- Gera embeddings (fastembed local ou OpenAI)
- Upsert no Qdrant (coleção `docs_chunks`)

## Testar a API

### Exemplo com curl

```bash
curl -X POST http://localhost:8000/ask \
  -H "Content-Type: application/json" \
  -d '{"question": "Qual o prazo para reembolso de despesas nacionais?"}'
```

### Exemplo com Python

```python
import httpx

response = httpx.post(
    "http://localhost:8000/ask",
    json={"question": "Qual o prazo para reembolso?"}
)

data = response.json()
print(f"Resposta: {data['answer']}")
print(f"Confiança: {data['confidence']}")
print(f"Fontes: {len(data['sources'])}")

# Headers importantes
print(f"Trace ID: {response.headers['X-Trace-ID']}")
print(f"Session ID: {response.headers['X-Chat-Session-ID']}")
print(f"Answer Source: {response.headers['X-Answer-Source']}")
```

### Exemplo com PowerShell

```powershell
Invoke-RestMethod -Method Post -Uri http://localhost:8000/ask `
  -ContentType 'application/json' `
  -Body '{"question":"Qual o prazo para reembolso?"}'
```

## Rodar Testes

### Testes Unitários

```bash
cd backend
pytest -q -m "not prodlike"
```

### Testes Property-Based (Fuzz)

```bash
cd backend
pytest -q tests/property
```

### Testes Prod-Like (Qdrant + Redis reais)

1. **Subir stack de teste**:
   ```bash
   docker compose -f docker-compose.test.yml up -d
   ```

2. **Configurar env vars**:
   ```bash
   export QDRANT_URL=http://localhost:6336
   export REDIS_URL=redis://localhost:6380/0
   ```

3. **Rodar testes**:
   ```bash
   cd backend
   pytest -q -m prodlike
   ```

4. **Limpar**:
   ```bash
   docker compose -f docker-compose.test.yml down -v
   ```

## Lint e Formatação

### Bandit (Segurança Python)

```bash
cd backend
bandit -r app
```

### Semgrep (SAST)

```bash
semgrep --config "p/security-audit" --config "p/python" .
```

### Formatação (Black)

```bash
cd backend
black app scripts
```

## Debugging

### Ver Logs da API

```bash
# Docker
docker compose logs -f api

# Localmente
# Logs aparecem no console (structlog JSON)
```

### Inspecionar Qdrant

```bash
# Listar coleções
curl http://localhost:6335/collections

# Info da coleção
curl http://localhost:6335/collections/docs_chunks
```

### Inspecionar Redis

```bash
# Conectar ao Redis
docker compose exec redis redis-cli

# Listar chaves de rate limit (sem expor valores)
KEYS rl:*

# Não use KEYS * em produção (pode ser lento)
```

### Logs Detalhados do Pipeline

Para ver logs detalhados do pipeline `/ask`:

```bash
# No .env
PIPELINE_LOG_ENABLED=1
PIPELINE_LOG_INCLUDE_TEXT=1  # Inclui excerpts curtos dos chunks
```

## Estrutura de Volumes

### Docker Compose

- `DOCS_HOST_PATH` → `/docs` (read-only): Documentos para ingestão
- `./docs` → `/app/docs`: Relatórios gerados (layout_report.md)
- `./config` → `/app/config`: Regras do Prompt Firewall
- `qdrant_storage`: Volume persistente para Qdrant

### Localmente

- `DOCS_ROOT`: Caminho para documentos (pode ser relativo ou absoluto)
- `LAYOUT_REPORT_PATH`: Onde salvar `layout_report.md` (default: `./docs/layout_report.md`)

## Variáveis de Ambiente Importantes

### Obrigatórias (têm defaults)

- `QDRANT_URL`: URL do Qdrant (default: `http://qdrant:6333` no Docker)
- `REDIS_URL`: URL do Redis (default: `redis://redis:6379/0` no Docker)
- `DOCS_ROOT`: Caminho para documentos (default: `/docs`)

### Opcionais

- `OPENAI_API_KEY`: Chave OpenAI (opcional, usa stub se vazio)
- `USE_OPENAI_EMBEDDINGS`: Usar embeddings OpenAI (default: 0)
- `AUDIT_LOG_ENABLED`: Habilitar audit logging (default: 1)
- `TRACE_SINK`: Sink para traces (default: `noop`, use `mysql` para persistir)
- `PIPELINE_LOG_ENABLED`: Logs detalhados do pipeline (default: 0)

Para lista completa, veja [Variáveis de Ambiente](reference/env-vars.md).

## Troubleshooting

### API não inicia

- Verifique se Qdrant e Redis estão rodando
- Verifique logs: `docker compose logs api`
- Verifique `/readyz`: deve retornar 200 quando tudo estiver OK

### Ingest falha

- Verifique se `DOCS_ROOT` aponta para pasta com documentos
- Verifique permissões de leitura
- Verifique logs: `docker compose logs api`

### Cache não funciona

- Verifique se Redis está acessível
- Verifique `REDIS_URL` está correto
- Cache usa SHA256 da pergunta normalizada (perguntas idênticas devem dar cache hit)

### Qdrant não persiste dados

- Em Docker Compose, verifique se o volume `qdrant_storage` está montado
- Em produção (Azure), verifique se Azure Files está montado

## Parar Containers

Para parar todos os containers do projeto:

**Windows**:
```powershell
.\infra\stop_all.ps1
```

**Linux/Mac**:
```bash
./infra/stop_all.sh
```

O script para:
- Containers do `docker-compose.yml`
- Containers de outros compose files (test, deploy, azure)
- Containers órfãos relacionados ao projeto

## Próximos Passos

- [Deploy na Azure](deployment_azure.md) - Como fazer deploy em produção
- [API Reference](api.md) - Documentação completa da API
- [Arquitetura](architecture.md) - Entender os componentes
- [Runbook](runbook.md) - Operações do dia a dia
