# 📋 Guia Completo de Deploy na Azure

Este documento detalha todas as opções e configurações para deploy na Azure.

## Índice

1. [Arquitetura](#arquitetura)
2. [Pré-requisitos](#pré-requisitos)
3. [Opções de Deploy](#opções-de-deploy)
4. [Configuração Pós-Deploy](#configuração-pós-deploy)
5. [Manutenção](#manutenção)
6. [Troubleshooting](#troubleshooting)

## Arquitetura

```
┌─────────────────────────────────────────────────────────┐
│                    Azure Container Apps                   │
│  ┌──────────────┐              ┌──────────────┐        │
│  │   API App    │              │  Qdrant App   │        │
│  │  (FastAPI)   │◄─────────────►│  (Vector DB) │        │
│  └──────────────┘              └──────────────┘        │
│         │                                                  │
│         ├──────────────────────────────────────┐       │
│         │                                          │       │
│         ▼                                          ▼       │
│  ┌──────────────┐                          ┌──────────────┐│
│  │ Azure Redis  │                          │ Azure MySQL ││
│  │    Cache     │                          │  (Audit)    ││
│  └──────────────┘                          └──────────────┘│
└─────────────────────────────────────────────────────────┘
```

### Componentes

- **Azure Container Apps**: Orquestração dos containers
  - API (FastAPI): 2 vCPU, 4GB RAM, 1-5 replicas
  - Qdrant: 1 vCPU, 2GB RAM, 1 replica
- **Azure Container Registry**: Armazenamento de imagens Docker
- **Azure Redis Cache**: Cache e rate limiting (Basic, c0)
- **Azure Database for MySQL**: Audit logging (Flexible Server, Burstable B1ms)
- **Azure Key Vault** (opcional): Secrets management

## Pré-requisitos

### 1. Azure CLI

```bash
# Instalar (Windows)
# https://aka.ms/installazurecliwindows

# Instalar (Linux/Mac)
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Verificar
az --version
```

### 2. Login e Subscription

```bash
# Login
az login

# Listar subscriptions
az account list --output table

# Selecionar subscription
az account set --subscription "<subscription-id>"

# Verificar
az account show
```

### 3. Permissões Necessárias

Você precisa de uma das seguintes roles no Resource Group:
- **Owner**
- **Contributor**
- **User Access Administrator** + **Contributor**

### 4. Certificado MySQL (Opcional)

O certificado CA do Azure MySQL já está incluído no Dockerfile (`/app/certs/DigiCertGlobalRootCA.crt.pem`). Se precisar baixar manualmente:

```powershell
.\azure\download-mysql-cert.ps1
```

## Opções de Deploy

### Opção 1: Script PowerShell (Recomendado)

**Mais rápido e completo:**

```powershell
.\azure\deploy.ps1 -ResourceGroup "rag-overlabs-rg" -Location "brazilsouth"
```

**Parâmetros:**
- `-ResourceGroup`: Nome do resource group (default: `rag-overlabs-rg`)
- `-Location`: Região Azure (default: `brazilsouth`)
- `-AcrName`: Nome do ACR (default: `ragoverlabsacr`)
- `-AppName`: Nome da app (default: `rag-overlabs-app`)
- `-Environment`: Nome do environment (default: `rag-overlabs-env`)

### Opção 2: Script Bash

```bash
chmod +x azure/deploy.sh
./azure/deploy.sh rag-overlabs-rg brazilsouth ragoverlabsacr
```

### Opção 3: Bicep Template

**Infraestrutura como código:**

```bash
# Editar parameters.json com seus valores
az deployment group create \
  --resource-group rag-overlabs-rg \
  --template-file azure/bicep/main.bicep \
  --parameters @azure/bicep/parameters.json
```

**Vantagens:**
- Versionamento da infraestrutura
- Idempotente (pode rodar múltiplas vezes)
- Fácil de revisar e modificar

## Configuração Pós-Deploy

### 1. Aplicar Schema SQL

**Obrigatório para audit logging funcionar:**

```powershell
# Obter informações
$MYSQL_HOST = az mysql flexible-server show `
  --resource-group rag-overlabs-rg `
  --name rag-overlabs-app-mysql `
  --query fullyQualifiedDomainName -o tsv

$MYSQL_USER = az mysql flexible-server show `
  --resource-group rag-overlabs-rg `
  --name rag-overlabs-app-mysql `
  --query administratorLogin -o tsv

# Aplicar schema
mysql -h $MYSQL_HOST -u $MYSQL_USER -p < docs/db_audit_schema.sql
```

**Ou via Azure Cloud Shell:**

```bash
# Upload do arquivo SQL
az storage blob upload \
  --account-name <storage-account> \
  --container-name <container> \
  --name db_audit_schema.sql \
  --file docs/db_audit_schema.sql

# Executar no Cloud Shell
mysql -h <mysql-host> -u <user> -p < docs/db_audit_schema.sql
```

### 2. Configurar Secrets (Key Vault)

**Criar Key Vault:**

```powershell
.\azure\setup-keyvault.ps1 rag-overlabs-rg rag-overlabs-kv
```

**Adicionar Secrets:**

```powershell
# OpenAI API Key
az keyvault secret set `
  --vault-name rag-overlabs-kv `
  --name "OpenAIApiKey" `
  --value "<sua-chave-openai>"

# Audit Encryption Key (gerar)
$encKey = python -c "import os,base64; print(base64.b64encode(os.urandom(32)).decode())"
az keyvault secret set `
  --vault-name rag-overlabs-kv `
  --name "AuditEncKey" `
  --value $encKey
```

**Atualizar Container App para usar Key Vault:**

```powershell
az containerapp update `
  --name rag-overlabs-app `
  --resource-group rag-overlabs-rg `
  --set-env-vars `
    "OPENAI_API_KEY=@Microsoft.KeyVault(SecretUri=https://rag-overlabs-kv.vault.azure.net/secrets/OpenAIApiKey/)" `
    "AUDIT_ENC_KEY_B64=@Microsoft.KeyVault(SecretUri=https://rag-overlabs-kv.vault.azure.net/secrets/AuditEncKey/)"
```

**Nota:** Requer configuração de Managed Identity (ver documentação Azure).

### 3. Upload de Documentos

**Opção A: Executar ingest dentro do container**

```powershell
# Upload dos documentos para Azure Storage (temporário)
az storage account create `
  --name ragoverlabsstorage `
  --resource-group rag-overlabs-rg `
  --location brazilsouth `
  --sku Standard_LRS

az storage container create `
  --name documents `
  --account-name ragoverlabsstorage

# Upload
az storage blob upload-batch `
  --destination documents `
  --source ./DOC-IA `
  --account-name ragoverlabsstorage

# Executar ingest no container
az containerapp exec `
  --name rag-overlabs-app `
  --resource-group rag-overlabs-rg `
  --command "python -m scripts.scan_docs"

az containerapp exec `
  --name rag-overlabs-app `
  --resource-group rag-overlabs-rg `
  --command "python -m scripts.ingest"
```

**Opção B: Incluir documentos na imagem Docker** (não recomendado para produção)

Modificar `backend/Dockerfile` para copiar documentos:

```dockerfile
COPY DOC-IA /app/DOC-IA
ENV DOCS_ROOT=/app/DOC-IA
```

### 4. Configurar Firewall do MySQL

**Permitir acesso do Container Apps:**

```powershell
# Obter IPs do Container Apps Environment
$envId = az containerapp env show `
  --name rag-overlabs-env `
  --resource-group rag-overlabs-rg `
  --query id -o tsv

# Adicionar regra de firewall (permitir todos os IPs do Azure)
az mysql flexible-server firewall-rule create `
  --resource-group rag-overlabs-rg `
  --name rag-overlabs-app-mysql `
  --rule-name AllowAzureServices `
  --start-ip-address 0.0.0.0 `
  --end-ip-address 0.0.0.0
```

## Manutenção

### Atualizar Código

```powershell
# Rebuild e push
.\azure\build-and-push.ps1 ragoverlabsacr

# Atualizar app
.\azure\update-app.ps1 rag-overlabs-rg rag-overlabs-app ragoverlabsacr
```

### Ver Logs

```powershell
# Logs em tempo real
az containerapp logs show `
  --name rag-overlabs-app `
  --resource-group rag-overlabs-rg `
  --follow

# Últimas 100 linhas
az containerapp logs show `
  --name rag-overlabs-app `
  --resource-group rag-overlabs-rg `
  --tail 100
```

### Escalar Aplicação

```powershell
# Aumentar replicas
az containerapp update `
  --name rag-overlabs-app `
  --resource-group rag-overlabs-rg `
  --min-replicas 2 `
  --max-replicas 10
```

### Backup MySQL

```powershell
# Backup manual
az mysql flexible-server backup create `
  --resource-group rag-overlabs-rg `
  --server-name rag-overlabs-app-mysql `
  --backup-name manual-backup-$(Get-Date -Format "yyyyMMdd-HHmmss")
```

## Troubleshooting

### API não responde

1. **Verificar status:**
   ```powershell
   az containerapp show `
     --name rag-overlabs-app `
     --resource-group rag-overlabs-rg `
     --query properties.runningStatus
   ```

2. **Verificar logs:**
   ```powershell
   az containerapp logs show `
     --name rag-overlabs-app `
     --resource-group rag-overlabs-rg `
     --tail 50
   ```

3. **Verificar variáveis de ambiente:**
   ```powershell
   az containerapp show `
     --name rag-overlabs-app `
     --resource-group rag-overlabs-rg `
     --query properties.template.containers[0].env
   ```

### Erro de conexão MySQL

1. **Verificar se schema foi aplicado:**
   ```sql
   SHOW TABLES LIKE 'audit_%';
   ```

2. **Verificar firewall rules:**
   ```powershell
   az mysql flexible-server firewall-rule list `
     --resource-group rag-overlabs-rg `
     --name rag-overlabs-app-mysql
   ```

3. **Testar conexão:**
   ```powershell
   $MYSQL_HOST = az mysql flexible-server show `
     --resource-group rag-overlabs-rg `
     --name rag-overlabs-app-mysql `
     --query fullyQualifiedDomainName -o tsv
   
   mysql -h $MYSQL_HOST -u ragadmin -p
   ```

### Qdrant não conecta

1. **Verificar se Qdrant está rodando:**
   ```powershell
   az containerapp show `
     --name rag-overlabs-qdrant `
     --resource-group rag-overlabs-rg `
     --query properties.runningStatus
   ```

2. **Verificar URL no env var:**
   ```powershell
   az containerapp show `
     --name rag-overlabs-app `
     --resource-group rag-overlabs-rg `
     --query "properties.template.containers[0].env[?name=='QDRANT_URL'].value" -o tsv
   ```

3. **Testar conectividade:**
   ```powershell
   $QDRANT_URL = az containerapp show `
     --name rag-overlabs-qdrant `
     --resource-group rag-overlabs-rg `
     --query properties.configuration.ingress.fqdn -o tsv
   
   curl "http://${QDRANT_URL}:6333/collections"
   ```

## Custos

### Estimativa Mensal (Brasil Sul)

| Serviço | SKU | Custo Estimado |
|---------|-----|----------------|
| Container Apps | 2 vCPU, 4GB (API) + 1 vCPU, 2GB (Qdrant) | ~$15-25 |
| ACR | Basic | ~$5 |
| Redis Cache | Basic (c0) | ~$15 |
| MySQL Flexible | Burstable (B1ms) | ~$12 |
| **Total** | | **~$47-57/mês** |

*Custos variam conforme uso. Verifique [Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/).*

## Limpar Recursos

```powershell
# ⚠️ CUIDADO: Isso deleta TUDO!
az group delete --name rag-overlabs-rg --yes --no-wait
```

## Próximos Passos

- [ ] Configurar Application Insights
- [ ] Setup CI/CD com GitHub Actions
- [ ] Configurar backup automático do MySQL
- [ ] Implementar volume mount para documentos (Azure Files)
- [ ] Configurar autoscaling baseado em métricas
- [ ] Implementar Qdrant com persistência (Storage Account)
