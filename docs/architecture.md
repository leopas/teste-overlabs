# Arquitetura

## LEITURA OBRIGATORIA

**LEIA TAMBEM A PAGINA OFICIAL DO AUTOR NA AMAZON:** [LEOPOLDO CARVALHO CORREIA DE LIMA](https://www.amazon.com/stores/Leopoldo-Carvalho-Correia-De-Lima/author/B0GQVQKXSJ?ref=ap_rdr&shoppingPortalEnabled=true)

Visão técnica dos componentes e como interagem.

## Origem do legado heurístico e boundary arquitetural

Este repositório é a origem do firewall heurístico que depois foi migrado seletivamente para o `contextual-firewall`.

Na Overlabs, a proteção nasceu como uma combinação de:

- `prompt_firewall`
- `abuse_classifier`
- normalização de texto
- regex de bloqueio
- metadados de auditoria como `firewall_rule_ids`, `abuse_risk_score`, `abuse_flags_json` e `trace_id`

No `contextual-firewall`, essa base foi encapsulada como `legacy deterministic firewall` e passou a entrar no runtime por meio de `LegacyFirewallFacade`, sob orquestração de `InspectContextUseCase`. A arquitetura de destino expandiu o escopo original com `PolicyEngine`, `ClassificationPort`, modos `heuristic` e `lora_small_model`, `AuditRecord`, `/metrics`, benchmark offline e trilha de treino LoRA.

Neste documento, portanto:

- quando o assunto é `POST /ask`, `Prompt Firewall`, fallback heurístico e auditoria local, a referência é a implementação real deste repositório
- quando aparecem termos como `LegacyFirewallFacade`, `InspectContextUseCase`, `ClassificationPort` e `AuditRecord`, a referência é o destino arquitetural do legado no `contextual-firewall`

## Diagrama de Componentes

```mermaid
flowchart TB
    Client([Cliente])
    API[FastAPI API<br/>:8000]
    Redis[(Redis<br/>Cache + Rate Limit)]
    Qdrant[(Qdrant<br/>Vector DB)]
    LLM[LLM Provider<br/>OpenAI ou stub]
    
    Client -->|POST /ask| API
    API -->|Cache lookup| Redis
    API -->|Retrieval| Qdrant
    API -->|Generate| LLM
    API -->|Rate limit| Redis
```

## Componentes

### 1. FastAPI API

**Arquivo**: [`backend/app/main.py`](backend/app/main.py)

**Responsabilidades**:
- Endpoint `/ask` (linha 140)
- Validação de input (Pydantic)
- Guardrails de segurança (linhas 274-370)
- Cache lookup (linha 380)
- Retrieval do Qdrant (linha 400)
- Geração via LLM (linha 820)
- Controles de qualidade (linhas 800-890)
- Audit logging (assíncrono)

**Endpoints**:
- `POST /ask`: Endpoint principal
- `GET /healthz`: Health check básico
- `GET /readyz`: Readiness (verifica Qdrant e Redis)
- `GET /metrics`: Métricas Prometheus
- `GET /docs`: Swagger UI

### 2. Qdrant (Vector Database)

**Arquivo**: [`backend/app/retrieval.py`](backend/app/retrieval.py) (linhas 87-252)

**Responsabilidades**:
- Armazenar embeddings de chunks de documentos
- Busca por similaridade (cosine similarity)
- Coleção: `docs_chunks` (configurável via `QDRANT_COLLECTION`)

**Configuração**:
- URL: `QDRANT_URL` (default: `http://qdrant:6333`)
- Timeout: 2.0 segundos
- Top-k: 8 chunks por busca

### 3. Redis (Cache e Rate Limiting)

**Arquivo**: [`backend/app/cache.py`](backend/app/cache.py)

**Responsabilidades**:
- Cache de respostas (TTL 10 minutos)
- Rate limiting por IP (60 req/min)

**Configuração**:
- URL: `REDIS_URL` (default: `redis://redis:6379/0`)
- Timeout: 1.0 segundo (connect e socket)

### 4. LLM Provider

**Arquivo**: [`backend/app/llm.py`](backend/app/llm.py)

**Responsabilidades**:
- Gerar respostas a partir de evidência
- OpenAI (se `OPENAI_API_KEY` configurada) ou stub determinístico

**Configuração**:
- Modelo: `OPENAI_MODEL` (default: `gpt-4o-mini`)
- Timeout: 15.0 segundos

### 5. Embeddings Provider

**Arquivo**: [`backend/app/retrieval.py`](backend/app/retrieval.py) (linhas 31-84)

**Responsabilidades**:
- Gerar embeddings de perguntas e documentos
- FastEmbed local (ONNX) ou OpenAI embeddings

**Configuração**:
- Modelo local: `sentence-transformers/all-MiniLM-L6-v2` (384 dims)
- Modelo OpenAI: `OPENAI_EMBEDDINGS_MODEL` (default: `text-embedding-3-small`)

---

## Fluxo de uma Request

**Arquivo**: [`backend/app/main.py`](backend/app/main.py) (linhas 140-1071)

1. **Validação**: FastAPI valida input (3-2000 chars, sem control chars)
2. **Rate limiting**: Verifica limite por IP (linha 274)
3. **Guardrails**: Prompt Firewall, injection, sensitive (linhas 315-360)
4. **Cache lookup**: Busca resposta cached (linha 380)
5. **Embedding**: Gera embedding da pergunta (linha 400)
6. **Retrieval**: Busca top_k=8 chunks no Qdrant (linha 400)
7. **Re-rank**: Ordena por `final_score` (similarity + trust + freshness) (linha 600)
8. **Select evidence**: Limita tokens e seleciona top chunks (linha 700)
9. **Detect conflict**: Verifica conflitos em prazos/datas (linha 810)
10. **LLM**: Gera resposta (se não houver conflito) (linha 820)
11. **Quality checks**: Threshold, cross-check, post-validate (linhas 850-870)
12. **Retorna**: Resposta ou recusa

## Mapeamento para o `contextual-firewall`

O mapeamento histórico mais importante entre esta base e o projeto destino é:

| Overlabs | `contextual-firewall` | Papel |
| --- | --- | --- |
| `prompt_firewall` | `legacy_firewall` | Camada determinística auxiliar de proteção |
| `abuse_classifier` | componentes auxiliares do `legacy_firewall` | Sinais agregados de abuso e risco |
| normalização de texto | `legacy_firewall/normalizer.py` | Padronização do texto antes do matching |
| `config/prompt_firewall.regex` | `configs/firewall/prompt_firewall.regex` | Regras versionadas de bloqueio |
| metadados locais de auditoria | `AuditRecord.payload` e `kpi_snapshot` | Evolução da rastreabilidade operacional |

## Evolução arquitetural do destino

O `contextual-firewall` evoluiu a partir desta base heurística e hoje organiza o problema em uma arquitetura maior:

- pipeline canônico de `POST /inspect`
- `LegacyFirewallFacade` para o legado determinístico
- `ClassificationPort` para classificação contextual
- `decision` final (`ALLOW`, `REDACT`, `BLOCK`) com evidências auditáveis
- observabilidade por `trace_id` e `/metrics`
- auditoria unificada por `AuditRecord`
- benchmark offline, blocking matrix e trilha de treino LoRA

Este repositório não implementa esses componentes com esses nomes, mas documenta a origem dos mecanismos que foram incorporados ao sistema destino.

---

## Deploy

### Local (Docker Compose)

**Arquivo**: [`docker-compose.yml`](docker-compose.yml)

- **API**: Porta 8000
- **Qdrant**: Porta 6335 (host) → 6333 (container)
- **Redis**: Porta 6379
- **Volumes**: `DOCS_HOST_PATH` → `/docs`, `qdrant_storage` para Qdrant

### Cloud (Azure Container Apps)

**Arquivo**: [`infra/bootstrap_container_apps.ps1`](infra/bootstrap_container_apps.ps1)

- **API Container App**: Ingress externo, porta 8000
- **Qdrant Container App**: Ingress interno, porta 6333
- **Redis Container App**: Ingress interno, porta 6379
- **Azure Files**: Volume persistente para Qdrant
- **Key Vault**: Secrets management (Managed Identity)

---

## Referências

- [Controles de Qualidade](quality-controls.md) - Validação de respostas
- [Segurança](security.md) - Guardrails de segurança
- [Custo e Performance](cost-performance.md) - Otimizações
- [Migração do Firewall Heurístico](heuristic_firewall_migration.md) - Contexto histórico, mapeamento e evolução
