---
name: Documentação Estado da Arte
overview: ""
todos: []
---

# Plano: Documentação Estado da Arte - teste-overlabs

## Objetivo

Criar documentação completa, navegável e operacionalmente útil para o repositório teste-overlabs, seguindo princípios "doc-as-code" com extração automática de referências e conteúdo manual orientado a operação, engenharia e onboarding.

## Auditoria Realizada

### Estado Atual

**Componentes Identificados**:

- **API**: FastAPI com endpoints `/ask`, `/healthz`, `/readyz`, `/metrics`, `/docs`
- **Qdrant**: Vector DB (porta 6333 interno, 6335 host)
- **Redis**: Cache e rate limiting (porta 6379)
- **MySQL**: Opcional para audit logging (quando `TRACE_SINK=mysql`)
- **Azure Container Apps**: Deploy em produção (API, Qdrant, Redis como Container Apps separados)
- **Azure Files**: Persistência para Qdrant
- **Azure Key Vault**: Secrets management
- **ACR**: Azure Container Registry (`acrchoperia`)

**Scripts Identificados**:

- `infra/bootstrap_container_apps.ps1`: Bootstrap completo da infraestrutura
- `infra/update_container_app_env.ps1`: Atualizar env vars do Container App
- `infra/configure_audit_mysql.ps1`: Configurar MySQL
- `infra/run_ingest.ps1`: Executar ingestão em produção
- `infra/smoke_test.sh/.ps1`: Smoke tests
- `infra/ci/wait_revision_ready.sh`: Polling de readiness
- `infra/ci/rollback_revision.sh`: Rollback automático
- `infra/validate_env.py`: Validador de env vars
- `infra/setup_oidc.ps1`: Configurar OIDC para GitHub Actions
- `infra/cleanup_app_service.ps1`: Limpar recursos antigos do App Service

**Drift Identificado**:

- ✅ `docs/deployment_azure.md` já atualizado para Container Apps
- ✅ `docs/ci_cd.md` já existe e documenta canary deployment
- ⚠️ `README.md` raiz menciona Container Apps mas pode ser melhorado
- ⚠️ `docs/architecture.md` não menciona Azure Container Apps deployment
- ⚠️ Falta documentação de referência de scripts
- ⚠️ Falta documentação de referência de env vars
- ⚠️ Falta runbook de incidentes detalhado
- ⚠️ Falta índice navegável (`docs/INDEX.md`)

**Lacunas Identificadas**:

1. Não existe `docs/INDEX.md` (mapa da documentação)
2. Não existe `docs/reference/env-vars.md` (referência completa)
3. Não existe `docs/reference/scripts.md` (inventário de scripts)
4. Não existe `docs/local-development.md` (guia de desenvolvimento local)
5. Não existe `docs/api.md` (referência de endpoints)
6. `docs/runbook.md` existe mas pode ser expandido
7. Falta `docs/runbook_incidents.md` específico
8. Não existe gerador automático (`tools/docs_extract.py`)

## Estrutura de Documentação Proposta

```
docs/
├── INDEX.md                          # Mapa navegável (NOVO)
├── architecture.md                   # Atualizar com Container Apps
├── local-development.md              # Guia de dev local (NOVO)
├── deployment-azure.md               # Já existe, manter
├── ci-cd.md                          # Já existe, manter
├── runbook.md                        # Expandir
├── runbook_incidents.md              # Runbook de incidentes (NOVO)
├── api.md                            # Referência de endpoints (NOVO)
├── reference/
│   ├── env-vars.md                   # Referência completa (NOVO)
│   └── scripts.md                    # Inventário de scripts (NOVO)
├── _generated/                       # Arquivos gerados (NOVO)
│   ├── repo_map.md                   # Mapa do repositório
│   ├── env_vars_detected.md          # Env vars extraídas
│   └── scripts_inventory.md           # Scripts extraídos
└── [docs existentes mantidos]
```

## Implementação por Commits

### Commit 1: Criar gerador automático e estrutura base

**Arquivos**:

- `tools/docs_extract.py` (NOVO): Script Python que extrai:
  - Lista de scripts `infra/*` com parâmetros e propósito
  - Lista de workflows `.github/workflows/*`
  - Lista de compose files
  - Env vars de `infra/validate_env.py` e `backend/app/config.py`
  - Endpoints do FastAPI (via análise de `main.py`)
- `docs/_generated/.gitkeep` (NOVO): Diretório para arqui