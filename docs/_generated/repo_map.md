# Mapa do Repositório

> **Nota**: Este arquivo é gerado automaticamente por `tools/docs_extract.py`.
> Não edite manualmente. Execute `python tools/docs_extract.py` para atualizar.

## Scripts de Infraestrutura

| Script | Tipo | Propósito | Parâmetros |
|--------|------|-----------|------------|
| [`infra\add_environment_credentials.ps1`](../infra\add_environment_credentials.ps1) | ps1 | Script rápido para adicionar federated credentials de enviro... | true |
| [`infra\add_single_env_var.ps1`](../infra\add_single_env_var.ps1) | ps1 | Script para adicionar uma única variável de ambiente ao Cont... | true |
| [`infra\bootstrap_container_apps.ps1`](../infra\bootstrap_container_apps.ps1) | ps1 | Script para bootstrap de infraestrutura Azure Container Apps... | EnvFile, Stage, Location, ResourceGroup, null, AcrName |
| [`infra\ci\rollback_revision.ps1`](../infra\ci\rollback_revision.ps1) | ps1 | Script para rollback automático de uma revisão do Azure Cont... | true |
| [`infra\ci\rollback_revision.sh`](../infra\ci\rollback_revision.sh) | sh | !/bin/bash Script para fazer rollback automático para uma re... | - |
| [`infra\ci\wait_revision_ready.ps1`](../infra\ci\wait_revision_ready.ps1) | ps1 | Script para polling de readiness de uma revisão do Azure Con... | true |
| [`infra\ci\wait_revision_ready.sh`](../infra\ci\wait_revision_ready.sh) | sh | !/bin/bash Script para aguardar readiness de uma revision do... | - |
| [`infra\cleanup_app_service.ps1`](../infra\cleanup_app_service.ps1) | ps1 | Script para remover recursos antigos do App Service (migraçã... | ResourceGroup, null, Confirm, true, Force, false |
| [`infra\configure_audit_mysql.ps1`](../infra\configure_audit_mysql.ps1) | ps1 | Script para configurar variáveis de ambiente de MySQL/audit ... | ResourceGroup, null, ApiAppName, null, true |
| [`infra\reset_qdrant_collection.ps1`](../infra\reset_qdrant_collection.ps1) | ps1 | Script para dropar e recriar a collection do Qdrant em produ... | ResourceGroup, null, ApiAppName, null, CollectionName, Force |
| [`infra\run_ingest.ps1`](../infra\run_ingest.ps1) | ps1 | Script para executar ingestão de documentos no Container App... | ResourceGroup, null, ApiAppName, null |
| [`infra\setup_oidc.ps1`](../infra\setup_oidc.ps1) | ps1 | Script para configurar OIDC (Federated Credentials) no Azure... | true |
| [`infra\smoke_test.ps1`](../infra\smoke_test.ps1) | ps1 | Smoke test para validar deploy na Azure App Service (PowerSh... | Url, Timeout, MaxRetries, InitialDelay |
| [`infra\smoke_test.sh`](../infra\smoke_test.sh) | sh | !/bin/bash Smoke test para validar deploy na Azure App Servi... | - |
| [`infra\stop_all.ps1`](../infra\stop_all.ps1) | ps1 | Script para parar todos os containers do projeto Uso: .\infr... | - |
| [`infra\stop_all.sh`](../infra\stop_all.sh) | sh | !/bin/bash Script para parar todos os containers do projeto ... | - |
| [`infra\test_ask_api.ps1`](../infra\test_ask_api.ps1) | ps1 | Script para testar a API /ask no Azure Uso: .\infra\test_ask... | true |
| [`infra\test_ask_api.sh`](../infra\test_ask_api.sh) | sh | !/bin/bash Script para testar a API /ask no Azure Uso: ./inf... | - |
| [`infra\update_container_app_env.ps1`](../infra\update_container_app_env.ps1) | ps1 | Script para atualizar variáveis de ambiente do Container App... | EnvFile, ResourceGroup, null, ApiAppName, null, KeyVaultName, null |
| [`infra\validate_env.py`](../infra\validate_env.py) | py | !/usr/bin/env python3 | - |

## Workflows GitHub Actions

| Arquivo | Nome | Triggers | Jobs |
|---------|------|----------|------|
| [`.github\workflows\deploy-azure.yml`](../.github\workflows\deploy-azure.yml) | Deploy to Azure Container Apps | push, workflow_dispatch | push, workflow_dispatch, group, contents, actions, ACR_NAME, IMAGE_NAME, CANARY_WEIGHT, validate, build, deploy |

## Docker Compose Files

| Arquivo | Serviços |
|---------|----------|
| `docker-compose.azure.yml` | api, qdrant, redis, qdrant_data |
| `docker-compose.deploy.yml` | api, qdrant, redis, qdrant_data |
| `docker-compose.test.yml` | qdrant_test_storage |
| `docker-compose.yml` | api, qdrant, redis, qdrant_storage |