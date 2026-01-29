# Deploy na Azure

Este diretório contém scripts e configurações para fazer deploy do sistema RAG na Azure usando Azure Container Apps.

## Arquitetura

O deploy utiliza:
- **Azure Container Apps**: Para orquestrar os containers (API e Qdrant)
- **Azure Container Registry (ACR)**: Para armazenar as imagens Docker
- **Azure Redis Cache**: Para cache e rate limiting
- **Azure Database for MySQL (Flexible Server)**: Para audit logging
- **Azure Key Vault** (opcional): Para armazenar secrets

## Pré-requisitos

1. **Azure CLI** instalado e configurado:
   ```bash
   az login
   az account set --subscription <subscription-id>
   ```

2. **Permissões** na subscription:
   - Contributor ou Owner no resource group
   - Permissão para criar Container Apps, ACR, Redis, MySQL

3. **Docker** (opcional, se quiser build local antes)

## Deploy Rápido

### PowerShell (Windows)

```powershell
cd C:\Projetos\teste-overlabs
.\azure\deploy.ps1 -ResourceGroup "rag-overlabs-rg" -Location "brazilsouth"
```

### Bash (Linux/macOS/WSL)

```bash
cd /path/to/teste-overlabs
chmod +x azure/deploy.sh
./azure/deploy.sh rag-overlabs-rg brazilsouth ragoverlabsacr
```

## O que o script faz

1. ✅ Cria Resource Group
2. ✅ Cria Azure Container Registry (ACR)
3. ✅ Build e push da imagem da API para ACR
4. ✅ Cria Azure Redis Cache (Basic, c0)
5. ✅ Cria Azure Database for MySQL (Flexible Server, Burstable B1ms)
6. ✅ Cria Container Apps Environment
7. ✅ Deploy do Qdrant como Container App
8. ✅ Deploy da API como Container App com todas as variáveis de ambiente

## Pós-Deploy

### 1. Aplicar Schema SQL

```bash
# Obter informações do MySQL
MYSQL_HOST=$(az mysql flexible-server show --resource-group rag-overlabs-rg --name rag-overlabs-app-mysql --query fullyQualifiedDomainName -o tsv)
MYSQL_USER=$(az mysql flexible-server show --resource-group rag-overlabs-rg --name rag-overlabs-app-mysql --query administratorLogin -o tsv)

# Aplicar schema
mysql -h $MYSQL_HOST -u $MYSQL_USER -p < docs/db_audit_schema.sql
```

### 2. Configurar Secrets (Azure Key Vault)

```bash
# Criar Key Vault
az keyvault create \
  --name rag-overlabs-kv \
  --resource-group rag-overlabs-rg \
  --location brazilsouth

# Adicionar secrets
az keyvault secret set --vault-name rag-overlabs-kv --name "OpenAIApiKey" --value "<sua-chave>"
az keyvault secret set --vault-name rag-overlabs-kv --name "AuditEncKey" --value "<chave-base64-32-bytes>"

# Atualizar Container App para usar Key Vault (sintaxe correta do Container Apps)
# 1. Habilitar Managed Identity
az containerapp identity assign \
  --name rag-overlabs-app \
  --resource-group rag-overlabs-rg \
  --system-assigned

# 2. Conceder permissão no Key Vault
PRINCIPAL_ID=$(az containerapp show --name rag-overlabs-app --resource-group rag-overlabs-rg --query "identity.principalId" -o tsv)
KV_RESOURCE_ID=$(az keyvault show --name rag-overlabs-kv --resource-group rag-overlabs-rg --query id -o tsv)
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Key Vault Secrets User" \
  --scope $KV_RESOURCE_ID

# 3. Configurar secrets (keyvaultref)
az containerapp update \
  --name rag-overlabs-app \
  --resource-group rag-overlabs-rg \
  --set-secrets \
    "openai-api-key=keyvaultref:https://rag-overlabs-kv.vault.azure.net/secrets/OpenAIApiKey" \
    "audit-enc-key-b64=keyvaultref:https://rag-overlabs-kv.vault.azure.net/secrets/AuditEncKey"

# 4. Configurar env vars (secretRef)
az containerapp update \
  --name rag-overlabs-app \
  --resource-group rag-overlabs-rg \
  --set-env-vars \
    "OPENAI_API_KEY=secretref:openai-api-key" \
    "AUDIT_ENC_KEY_B64=secretref:audit-enc-key-b64"
```

### 3. Upload de Documentos

Opção A: Azure Storage + Volume Mount
```bash
# Criar Storage Account
az storage account create \
  --name ragoverlabsstorage \
  --resource-group rag-overlabs-rg \
  --location brazilsouth \
  --sku Standard_LRS

# Criar container
az storage container create \
  --name documents \
  --account-name ragoverlabsstorage

# Upload dos documentos
az storage blob upload-batch \
  --destination documents \
  --source ./DOC-IA \
  --account-name ragoverlabsstorage

# Montar como volume no Container App (requer configuração adicional)
```

Opção B: Incluir documentos na imagem Docker (não recomendado para produção)

### 4. Executar Ingest

```bash
# Conectar ao container
az containerapp exec \
  --name rag-overlabs-app \
  --resource-group rag-overlabs-rg \
  --command "/bin/bash"

# Dentro do container
python -m scripts.scan_docs
python -m scripts.ingest
```

## Variáveis de Ambiente

O script configura automaticamente:
- `QDRANT_URL`: URL do Qdrant Container App
- `REDIS_URL`: Connection string do Azure Redis
- `MYSQL_HOST`, `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_DATABASE`
- `TRACE_SINK=mysql`
- `AUDIT_LOG_ENABLED=1`

**Você precisa configurar manualmente:**
- `OPENAI_API_KEY` (se usar OpenAI)
- `AUDIT_ENC_KEY_B64` (chave de criptografia)
- `PROMPT_FIREWALL_ENABLED=1` (se quiser habilitar)

## Custos Estimados (Brasil Sul)

- **Container Apps**: ~$0.000012/vCPU-segundo + ~$0.0000015/GB-segundo
- **ACR Basic**: ~$5/mês
- **Redis Cache Basic (c0)**: ~$15/mês
- **MySQL Flexible Server (B1ms)**: ~$12/mês
- **Total estimado**: ~$32-40/mês (sem uso intensivo)

## Troubleshooting

### Ver logs da API
```bash
az containerapp logs show \
  --name rag-overlabs-app \
  --resource-group rag-overlabs-rg \
  --follow
```

### Verificar status dos containers
```bash
az containerapp show \
  --name rag-overlabs-app \
  --resource-group rag-overlabs-rg \
  --query properties.runningStatus
```

### Atualizar imagem
```bash
# Rebuild e push
az acr build --registry ragoverlabsacr --image rag-api:latest --file backend/Dockerfile .

# Atualizar Container App
az containerapp update \
  --name rag-overlabs-app \
  --resource-group rag-overlabs-rg \
  --image ragoverlabsacr.azurecr.io/rag-api:latest
```

### Conectar ao MySQL
```bash
MYSQL_HOST=$(az mysql flexible-server show --resource-group rag-overlabs-rg --name rag-overlabs-app-mysql --query fullyQualifiedDomainName -o tsv)
mysql -h $MYSQL_HOST -u ragadmin -p
```

## Limitações Conhecidas

1. **Qdrant**: Container App não suporta volumes persistentes nativamente. Considere usar Qdrant Cloud ou Azure Storage com mount.
2. **Documentos**: Precisa de estratégia para upload e montagem (Storage Account ou incluir na imagem).
3. **Secrets**: Key Vault integration requer configuração adicional de Managed Identity.

## Próximos Passos

- [ ] Configurar Azure Key Vault para secrets
- [ ] Implementar volume mount para documentos (Azure Files)
- [ ] Configurar Application Insights para observabilidade
- [ ] Setup de CI/CD com GitHub Actions
- [ ] Configurar backup do MySQL
- [ ] Implementar Qdrant com persistência (Storage Account ou Qdrant Cloud)
