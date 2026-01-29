# Referência de Scripts de Infraestrutura

Inventário completo de todos os scripts disponíveis para gerenciar a infraestrutura.

> **Nota**: Para lista gerada automaticamente, veja [Inventário de Scripts](_generated/scripts_inventory.md).

## Scripts PowerShell

### `bootstrap_container_apps.ps1`

**Propósito**: Bootstrap completo da infraestrutura Azure Container Apps.

**Parâmetros**:
- `-EnvFile` (string, default: `.env`): Arquivo `.env` com variáveis de ambiente
- `-Stage` (string, default: `prod`): Stage do ambiente (prod, staging, etc.)
- `-Location` (string, default: `brazilsouth`): Região do Azure
- `-ResourceGroup` (string, opcional): Nome do Resource Group (se não fornecido, usa `rg-overlabs-{Stage}`)
- `-AcrName` (string, default: `acrchoperia`): Nome do Azure Container Registry

**O que cria**:
- Resource Group
- Azure Container Registry (ACR)
- Azure Key Vault
- Container Apps Environment
- Container Apps: API, Qdrant, Redis
- Azure Files (Storage Account + File Share para Qdrant)
- Secrets no Key Vault (a partir do `.env`)
- `deploy_state.json`

**Uso**:
```powershell
.\infra\bootstrap_container_apps.ps1 -EnvFile ".env" -Stage "prod" -Location "brazilsouth"
```

**Idempotência**: Sim - pode ser executado múltiplas vezes sem problemas.

**Dependências**: Azure CLI instalado e logado (`az login`).

---

### `update_container_app_env.ps1`

**Propósito**: Atualizar todas as variáveis de ambiente do Container App a partir do `.env`.

**Parâmetros**:
- `-EnvFile` (string, default: `.env`): Arquivo `.env` com variáveis
- `-ResourceGroup` (string, opcional): Resource Group (carrega de `deploy_state.json` se não fornecido)
- `-ApiAppName` (string, opcional): Nome do Container App (carrega de `deploy_state.json` se não fornecido)
- `-KeyVaultName` (string, opcional): Nome do Key Vault (carrega de `deploy_state.json` se não fornecido)

**O que faz**:
1. Lê todas as variáveis do `.env`
2. Identifica secrets (via `validate_env.py`)
3. Cria/atualiza secrets no Key Vault
4. Atualiza variáveis de ambiente do Container App (secrets via Key Vault refs, non-secrets diretamente)

**Uso**:
```powershell
.\infra\update_container_app_env.ps1 -EnvFile ".env"
```

**Idempotência**: Sim.

**Dependências**: `deploy_state.json` ou parâmetros fornecidos.

---

### `add_single_env_var.ps1`

**Propósito**: Adicionar ou atualizar uma única variável de ambiente no Container App.

**Parâmetros**:
- `-VarName` (string, obrigatório): Nome da variável
- `-VarValue` (string, obrigatório): Valor da variável
- `-ResourceGroup` (string, opcional): Resource Group
- `-ApiAppName` (string, opcional): Nome do Container App

**Uso**:
```powershell
.\infra\add_single_env_var.ps1 -VarName "AUDIT_LOG_RAW_MAX_CHARS" -VarValue "2000"
```

**Idempotência**: Sim.

---

### `configure_audit_mysql.ps1`

**Propósito**: Configurar variáveis de ambiente relacionadas ao MySQL para audit logging.

**Parâmetros**:
- `-ResourceGroup` (string, opcional): Resource Group
- `-ApiAppName` (string, opcional): Nome do Container App
- `-MysqlHost` (string, obrigatório): Host do MySQL
- `-MysqlUser` (string, obrigatório): Usuário do MySQL
- `-MysqlPassword` (string, obrigatório): Senha do MySQL
- `-MysqlDatabase` (string, obrigatório): Nome do banco de dados

**O que faz**:
1. Cria secrets no Key Vault (se necessário)
2. Atualiza variáveis de ambiente do Container App

**Uso**:
```powershell
.\infra\configure_audit_mysql.ps1 `
  -MysqlHost "mysql-server.mysql.database.azure.com" `
  -MysqlUser "admin" `
  -MysqlPassword "senha-secreta" `
  -MysqlDatabase "audit_db"
```

**Idempotência**: Sim.

---

### `run_ingest.ps1`

**Propósito**: Executar ingestão de documentos no Container App de produção.

**Parâmetros**:
- `-ResourceGroup` (string, opcional): Resource Group
- `-ApiAppName` (string, opcional): Nome do Container App

**O que faz**:
1. Executa `python -m scripts.scan_docs` no container
2. Executa `python -m scripts.ingest` no container

**Uso**:
```powershell
.\infra\run_ingest.ps1
```

**Dependências**: Container App deve ter `DOCS_ROOT` configurado e documentos disponíveis.

---

### `run_ingest_in_container.ps1`

**Propósito**: Executar ingestão dentro do container da API (recomendado).

**Parâmetros**:
- `-TruncateFirst` (flag): Truncar collection antes de indexar
- `-VerifyDocs` (flag): Verificar se /app/DOC-IA existe antes de executar

**Uso**:
```powershell
# Básico
.\infra\run_ingest_in_container.ps1

# Com truncate primeiro
.\infra\run_ingest_in_container.ps1 -TruncateFirst

# Verificar documentos antes
.\infra\run_ingest_in_container.ps1 -VerifyDocs
```

**O que faz**:
1. Verifica se `/app/DOC-IA` existe no container (volume montado)
2. Verifica configuração de embeddings (OpenAI)
3. Opcionalmente trunca a collection
4. Executa `scan_docs` dentro do container
5. Executa `ingest` dentro do container
6. Usa Qdrant interno (não precisa tornar externo)

**Vantagens**:
- ✅ Usa documentos já montados no container
- ✅ Acessa Qdrant interno (mais seguro)
- ✅ Usa todas as variáveis de ambiente já configuradas
- ✅ Não precisa copiar documentos manualmente
- ✅ Não precisa tornar Qdrant externo

---

### `ingest_local_to_prod_qdrant.py`

**Propósito**: Executar ingestão localmente apontando para Qdrant de produção (alternativa).

**Parâmetros**:
- `--qdrant-url` (string, opcional): URL do Qdrant (se não fornecido, obtém de deploy_state.json)
- `--resource-group` (string, opcional): Resource Group (se não fornecido, lê de deploy_state.json)
- `--qdrant-app-name` (string, opcional): Nome do Qdrant Container App (se não fornecido, lê de deploy_state.json)
- `--docs-path` (string, default: "DOC-IA"): Caminho para documentos locais
- `--truncate-first` (flag): Truncar collection antes de indexar
- `--openai-api-key` (string, opcional): OpenAI API Key (se não fornecido, usa OPENAI_API_KEY do ambiente)

**Uso**:
```bash
# Usando deploy_state.json
python infra/ingest_local_to_prod_qdrant.py

# Com truncate primeiro
python infra/ingest_local_to_prod_qdrant.py --truncate-first

# Fornecendo URL diretamente
python infra/ingest_local_to_prod_qdrant.py --qdrant-url https://app-overlabs-qdrant-prod-300.azurecontainerapps.io
```

**O que faz**:
1. Obtém URL do Qdrant de produção (via Azure CLI ou parâmetro)
2. Opcionalmente trunca a collection
3. Executa `scan_docs` localmente
4. Executa `ingest` localmente apontando para Qdrant remoto
5. Usa OpenAI embeddings (requer `OPENAI_API_KEY`)

**Vantagens**:
- Não precisa copiar documentos para o container
- Usa documentos locais diretamente
- Mais rápido para desenvolvimento/testes
- Fácil de debugar localmente

---

### `reset_qdrant_collection.ps1`

**Propósito**: Dropar e recriar a collection do Qdrant em produção, reindexando todos os documentos.

**Parâmetros**:
- `-ResourceGroup` (string, opcional): Resource Group
- `-ApiAppName` (string, opcional): Nome do Container App da API
- `-CollectionName` (string, default: "docs_chunks"): Nome da collection
- `-Force` (switch): Pular confirmação

**O que faz**:
1. Deleta a collection do Qdrant (se existir)
2. Executa `scan_docs.py` para gerar `layout_report.md`
3. Executa `ingest.py` para recriar a collection e indexar todos os documentos

**Uso**:
```powershell
.\infra\reset_qdrant_collection.ps1
```

**Com confirmação automática**:
```powershell
.\infra\reset_qdrant_collection.ps1 -Force
```

**Atenção**: Esta operação **deleta todos os dados indexados** e reindexa do zero. Use quando:
- A collection está corrompida
- Mudou o schema dos documentos
- Precisa limpar dados antigos
- Mudou o modelo de embeddings

**Idempotência**: Sim (pode ser executado múltiplas vezes).

---

### `setup_oidc.ps1`

**Propósito**: Configurar OIDC (Federated Credentials) no Azure AD para GitHub Actions.

**Parâmetros**:
- `-GitHubOrg` (string, obrigatório): Organização ou usuário do GitHub
- `-GitHubRepo` (string, obrigatório): Nome do repositório
- `-AppName` (string, default: `github-actions-rag-overlabs`): Nome da App Registration
- `-ResourceGroup` (string, default: `rg-overlabs-prod`): Resource Group
- `-AcrName` (string, default: `acrchoperia`): Nome do ACR
- `-Location` (string, default: `brazilsouth`): Região

**O que faz**:
1. Cria ou reutiliza App Registration no Azure AD
2. Concede permissões (Contributor no RG, AcrPush no ACR)
3. Cria Federated Credentials para branches e tags
4. Exibe valores para configurar no GitHub Secrets

**Uso**:
```powershell
.\infra\setup_oidc.ps1 -GitHubOrg "leopas" -GitHubRepo "teste-overlabs"
```

**Idempotência**: Sim.

---

### `cleanup_app_service.ps1`

**Propósito**: Limpar recursos antigos do Azure App Service (migração para Container Apps).

**Parâmetros**:
- `-ResourceGroup` (string, opcional): Resource Group
- `-Force` (switch): Pular confirmação

**O que remove**:
- Web Apps (incluindo slots)
- App Service Plans

**O que mantém**:
- ACR
- Key Vault
- Storage Account
- Outros recursos

**Uso**:
```powershell
.\infra\cleanup_app_service.ps1 -Force
```

**Atenção**: Esta operação é **irreversível**!

---

### `smoke_test.ps1`

**Propósito**: Smoke test para validar deploy.

**Parâmetros**:
- `-Url` (string, default: exemplo): URL da API
- `-Timeout` (int, default: 30): Timeout em segundos
- `-MaxRetries` (int, default: 5): Número máximo de tentativas
- `-InitialDelay` (int, default: 2): Delay inicial entre tentativas

**Uso**:
```powershell
.\infra\smoke_test.ps1 -Url "https://app-overlabs-prod-123.azurecontainerapps.io"
```

---

## Scripts Shell (Linux/Mac)

### `smoke_test.sh`

**Propósito**: Smoke test para validar deploy (Linux/Mac).

**Parâmetros** (variáveis de ambiente):
- `URL`: URL da API
- `TIMEOUT`: Timeout em segundos
- `MAX_RETRIES`: Número máximo de tentativas
- `INITIAL_DELAY`: Delay inicial

**Uso**:
```bash
export URL="https://app-overlabs-prod-123.azurecontainerapps.io"
./infra/smoke_test.sh
```

---

### `wait_revision_ready.sh` / `wait_revision_ready.ps1`

**Propósito**: Aguardar readiness de uma revision do Azure Container App (polling).

**Parâmetros** (PowerShell):
- `-AppName`: Nome do Container App
- `-ResourceGroup`: Resource Group
- `-RevisionName`: Nome da revision
- `-TimeoutSeconds` (opcional, default: 300): Timeout em segundos

**Parâmetros** (Bash):
1. `APP_NAME`: Nome do Container App
2. `RESOURCE_GROUP`: Resource Group
3. `REVISION_NAME`: Nome da revision
4. `TIMEOUT` (opcional, default: 300): Timeout em segundos

**Uso** (PowerShell):
```powershell
.\infra\ci\wait_revision_ready.ps1 `
  -AppName "app-overlabs-prod-123" `
  -ResourceGroup "rg-overlabs-prod" `
  -RevisionName "app-overlabs-prod-123--abc123" `
  -TimeoutSeconds 300
```

**Uso** (Bash):
```bash
./infra/ci/wait_revision_ready.sh \
  "app-overlabs-prod-123" \
  "rg-overlabs-prod" \
  "app-overlabs-prod-123--abc123" \
  300
```

**O que faz**:
- Polling contínuo do estado da revision
- Verifica `provisioningState` e `runningState`
- Backoff exponencial entre tentativas
- Falha se timeout ou se revision falhar

---

### `rollback_revision.sh` / `rollback_revision.ps1`

**Propósito**: Fazer rollback automático para uma revision anterior.

**Parâmetros** (PowerShell):
- `-AppName`: Nome do Container App
- `-ResourceGroup`: Resource Group
- `-PrevRevisionName`: Nome da revision anterior (para rollback)
- `-FailedRevisionName`: Nome da revision que falhou

**Parâmetros** (Bash):
1. `APP_NAME`: Nome do Container App
2. `RESOURCE_GROUP`: Resource Group
3. `PREV_REVISION_NAME`: Nome da revision anterior (para rollback)
4. `FAILED_REVISION_NAME`: Nome da revision que falhou

**Uso** (PowerShell):
```powershell
.\infra\ci\rollback_revision.ps1 `
  -AppName "app-overlabs-prod-123" `
  -ResourceGroup "rg-overlabs-prod" `
  -PrevRevisionName "app-overlabs-prod-123--prev123" `
  -FailedRevisionName "app-overlabs-prod-123--failed123"
```

**Uso** (Bash):
```bash
./infra/ci/rollback_revision.sh \
  "app-overlabs-prod-123" \
  "rg-overlabs-prod" \
  "app-overlabs-prod-123--prev123" \
  "app-overlabs-prod-123--failed123"
```

**O que faz**:
1. Redireciona 100% do tráfego para a revision anterior
2. Desativa a revision que falhou
3. Gera summary no GitHub Actions (se executado no CI/CD)

---

## Scripts Python

### `validate_env.py`

**Propósito**: Validar arquivo `.env` para deploy Azure.

**Parâmetros**:
- `--env` (Path, default: `.env`): Caminho para arquivo `.env`
- `--show-classification`: Mostrar classificação de secrets vs non-secrets

**Uso**:
```bash
python infra/validate_env.py --env .env --show-classification
```

**O que valida**:
- Formato correto (KEY=VALUE)
- Tipos (inteiros, booleanos)
- Nomes válidos para Key Vault
- Classificação secrets vs non-secrets

---

## Ordem de Execução Recomendada

### Setup Inicial

1. **Bootstrap**:
   ```powershell
   .\infra\bootstrap_container_apps.ps1 -EnvFile ".env" -Stage "prod" -Location "brazilsouth"
   ```

2. **Configurar OIDC** (se usar CI/CD):
   ```powershell
   .\infra\setup_oidc.ps1 -GitHubOrg "usuario" -GitHubRepo "teste-overlabs"
   ```

3. **Configurar variáveis de ambiente**:
   ```powershell
   .\infra\update_container_app_env.ps1 -EnvFile ".env"
   ```

4. **Configurar MySQL** (se usar audit logging):
   ```powershell
   .\infra\configure_audit_mysql.ps1 -MysqlHost "..." -MysqlUser "..." -MysqlPassword "..." -MysqlDatabase "..."
   ```

5. **Executar ingestão**:
   ```powershell
   .\infra\run_ingest.ps1
   ```

6. **Reset completo da collection** (se necessário):
   ```powershell
   .\infra\reset_qdrant_collection.ps1
   ```

### Atualizações

- **Atualizar todas as variáveis**: `update_container_app_env.ps1`
- **Atualizar uma variável**: `add_single_env_var.ps1`
- **Re-executar ingestão**: `run_ingest.ps1`
- **Reset completo da collection**: `reset_qdrant_collection.ps1`

---

## Troubleshooting

### Scripts PowerShell não executam

- Verifique se está no PowerShell (não CMD)
- Verifique permissões de execução: `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`

### Erro "Container App não encontrado"

- Verifique se o bootstrap foi executado
- Verifique `deploy_state.json` existe e está correto
- Verifique se está no Resource Group correto

### Erro de permissões no Key Vault

- Verifique se tem permissão `Key Vault Secrets Officer` ou `Key Vault Secrets User`
- Execute: `az keyvault set-policy --name <kv-name> --upn <seu-email> --secret-permissions get set list`

### `stop_all.ps1` / `stop_all.sh`

**Propósito**: Parar todos os containers do projeto.

**Parâmetros**: Nenhum

**O que faz**:
1. Para containers do `docker-compose.yml`
2. Para containers de outros compose files (test, deploy, azure)
3. Para containers órfãos relacionados ao projeto (por nome)

**Uso**:
```powershell
# Windows
.\infra\stop_all.ps1
```

```bash
# Linux/Mac
./infra/stop_all.sh
```

**Idempotência**: Sim - pode ser executado múltiplas vezes.

---

## Referências

- [Inventário de Scripts](_generated/scripts_inventory.md) - Lista gerada automaticamente
- [Deploy na Azure](deployment_azure.md) - Como usar os scripts no deploy
- [CI/CD](ci_cd.md) - Scripts usados no pipeline
