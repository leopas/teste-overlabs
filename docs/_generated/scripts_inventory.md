# Inventário de Scripts

> **Nota**: Este arquivo é gerado automaticamente por `tools/docs_extract.py`.
> Não edite manualmente. Execute `python tools/docs_extract.py` para atualizar.

## Scripts PS1

### `infra\add_environment_credentials.ps1`

**Tipo**: ps1

**Propósito**: Script rápido para adicionar federated credentials de environments Uso: .\infra\add_environment_credentials.ps1 -GitHubOrg "leopas" -GitHubRepo "teste-overlabs"

**Parâmetros**: true

**Uso**: `.\infra\add_environment_credentials.ps1 -GitHubOrg "leopas" -GitHubRepo "teste-overlabs"`

---

### `infra\add_single_env_var.ps1`

**Tipo**: ps1

**Propósito**: Script para adicionar uma única variável de ambiente ao Container App Uso: .\infra\add_single_env_var.ps1 -VarName "AUDIT_LOG_RAW_MAX_CHARS" -VarValue "2000"

**Parâmetros**: true

**Uso**: `.\infra\add_single_env_var.ps1 -VarName "AUDIT_LOG_RAW_MAX_CHARS" -VarValue "2000"`

---

### `infra\bootstrap_container_apps.ps1`

**Tipo**: ps1

**Propósito**: Script para bootstrap de infraestrutura Azure Container Apps Uso: .\infra\bootstrap_container_apps.ps1 -EnvFile ".env" -Stage "prod" -Location "brazilsouth" 

**Parâmetros**: EnvFile, Stage, Location, ResourceGroup, null, AcrName

**Uso**: `.\infra\bootstrap_container_apps.ps1 -EnvFile ".env" -Stage "prod" -Location "brazilsouth"`

---

### `infra\cleanup_app_service.ps1`

**Tipo**: ps1

**Propósito**: Script para remover recursos antigos do App Service (migração para Container Apps) Uso: .\infra\cleanup_app_service.ps1 -ResourceGroup "rg-overlabs-prod" -Confirm:$false 

**Parâmetros**: ResourceGroup, null, Confirm, true, Force, false

**Uso**: `.\infra\cleanup_app_service.ps1 -ResourceGroup "rg-overlabs-prod" -Confirm:$false`

---

### `infra\configure_audit_mysql.ps1`

**Tipo**: ps1

**Propósito**: Script para configurar variáveis de ambiente de MySQL/audit no Container App Uso: .\infra\configure_audit_mysql.ps1 -MysqlHost "..." -MysqlUser "..." -MysqlPassword "..." -MysqlDatabase "..."

**Parâmetros**: ResourceGroup, null, ApiAppName, null, true

**Uso**: `.\infra\configure_audit_mysql.ps1 -MysqlHost "..." -MysqlUser "..." -MysqlPassword "..." -MysqlDatabase "..."`

---

### `infra\reset_qdrant_collection.ps1`

**Tipo**: ps1

**Propósito**: Script para dropar e recriar a collection do Qdrant em produção Uso: .\infra\reset_qdrant_collection.ps1

**Parâmetros**: ResourceGroup, null, ApiAppName, null, CollectionName, Force

**Uso**: `.\infra\reset_qdrant_collection.ps1`

---

### `infra\ci\rollback_revision.ps1`

**Tipo**: ps1

**Propósito**: Script para rollback automático de uma revisão do Azure Container App Uso: .\infra\ci\rollback_revision.ps1 -AppName "app-overlabs-prod-XXX" -ResourceGroup "rg-overlabs-prod" -PrevRevisionName "app-overlabs-prod-XXX--prev123" -FailedRevisionName "app-overlabs-prod-XXX--failed123"

**Parâmetros**: true

**Uso**: `.\infra\ci\rollback_revision.ps1 -AppName "app-overlabs-prod-XXX" -ResourceGroup "rg-overlabs-prod" -PrevRevisionName "app-overlabs-prod-XXX--prev123" -FailedRevisionName "app-overlabs-prod-XXX--failed123"`

---

### `infra\run_ingest.ps1`

**Tipo**: ps1

**Propósito**: Script para executar ingestão de documentos no Container App de produção Uso: .\infra\run_ingest.ps1

**Parâmetros**: ResourceGroup, null, ApiAppName, null

**Uso**: `.\infra\run_ingest.ps1`

---

### `infra\setup_oidc.ps1`

**Tipo**: ps1

**Propósito**: Script para configurar OIDC (Federated Credentials) no Azure AD Uso: .\infra\setup_oidc.ps1 -GitHubOrg "seu-org" -GitHubRepo "teste-overlabs"

**Parâmetros**: true

**Uso**: `.\infra\setup_oidc.ps1 -GitHubOrg "seu-org" -GitHubRepo "teste-overlabs"`

---

### `infra\smoke_test.ps1`

**Tipo**: ps1

**Propósito**: Smoke test para validar deploy na Azure App Service (PowerShell) Testa /healthz e /readyz com retry e backoff exponencial

**Parâmetros**: Url, Timeout, MaxRetries, InitialDelay

---

### `infra\stop_all.ps1`

**Tipo**: ps1

**Propósito**: Script para parar todos os containers do projeto Uso: .\infra\stop_all.ps1

**Uso**: `.\infra\stop_all.ps1`

---

### `infra\test_ask_api.ps1`

**Tipo**: ps1

**Propósito**: Script para testar a API /ask no Azure Uso: .\infra\test_ask_api.ps1 -Question "Qual é a política de reembolso?" -Slot staging

**Parâmetros**: true

**Uso**: `.\infra\test_ask_api.ps1 -Question "Qual é a política de reembolso?" -Slot staging`

---

### `infra\update_container_app_env.ps1`

**Tipo**: ps1

**Propósito**: Script para atualizar variáveis de ambiente do Container App a partir do .env Uso: .\infra\update_container_app_env.ps1 -EnvFile ".env"

**Parâmetros**: EnvFile, ResourceGroup, null, ApiAppName, null, KeyVaultName, null

**Uso**: `.\infra\update_container_app_env.ps1 -EnvFile ".env"`

---

### `infra\ci\wait_revision_ready.ps1`

**Tipo**: ps1

**Propósito**: Script para polling de readiness de uma revisão do Azure Container App Uso: .\infra\ci\wait_revision_ready.ps1 -AppName "app-overlabs-prod-XXX" -ResourceGroup "rg-overlabs-prod" -RevisionName "app-overlabs-prod-XXX--abc123" -TimeoutSeconds 300

**Parâmetros**: true

**Uso**: `.\infra\ci\wait_revision_ready.ps1 -AppName "app-overlabs-prod-XXX" -ResourceGroup "rg-overlabs-prod" -RevisionName "app-overlabs-prod-XXX--abc123" -TimeoutSeconds 300`

---

## Scripts PY

### `infra\validate_env.py`

**Tipo**: py

**Propósito**: !/usr/bin/env python3

---

## Scripts SH

### `infra\ci\rollback_revision.sh`

**Tipo**: sh

**Propósito**: !/bin/bash Script para fazer rollback automático para uma revision anterior Restaura 100% do tráfego para a revision especificada

**Uso**: `rollback_revision.sh <APP_NAME> <RESOURCE_GROUP> <PREV_REVISION>`

---

### `infra\smoke_test.sh`

**Tipo**: sh

**Propósito**: !/bin/bash Smoke test para validar deploy na Azure App Service Testa /healthz e /readyz com retry e backoff exponencial

---

### `infra\stop_all.sh`

**Tipo**: sh

**Propósito**: !/bin/bash Script para parar todos os containers do projeto Uso: ./infra/stop_all.sh

**Uso**: `./infra/stop_all.sh`

---

### `infra\test_ask_api.sh`

**Tipo**: sh

**Propósito**: !/bin/bash Script para testar a API /ask no Azure Uso: ./infra/test_ask_api.sh "Qual é a política de reembolso?" staging

**Uso**: `./infra/test_ask_api.sh "Qual é a política de reembolso?" staging`

---

### `infra\ci\wait_revision_ready.sh`

**Tipo**: sh

**Propósito**: !/bin/bash Script para aguardar readiness de uma revision do Azure Container App Faz polling verificando provisioningState, runningState e replicas

**Uso**: `wait_revision_ready.sh <APP_NAME> <RESOURCE_GROUP> <REVISION_NAME> [TIMEOUT]`

---
