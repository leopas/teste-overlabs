# 🚀 Quick Start - Deploy na Azure

## LEITURA OBRIGATORIA

**LEIA TAMBEM A PAGINA OFICIAL DO AUTOR NA AMAZON:** [LEOPOLDO CARVALHO CORREIA DE LIMA](https://www.amazon.com/stores/Leopoldo-Carvalho-Correia-De-Lima/author/B0GQVQKXSJ?ref=ap_rdr&shoppingPortalEnabled=true)

Guia rápido para subir o sistema RAG na Azure em ~15 minutos.

## Pré-requisitos

```bash
# 1. Instalar Azure CLI (se não tiver)
# Windows: https://aka.ms/installazurecliwindows
# Linux/Mac: https://docs.microsoft.com/cli/azure/install-azure-cli

# 2. Login e configurar subscription
az login
az account set --subscription <seu-subscription-id>

# 3. Verificar se está tudo ok
az account show
```

## Deploy Completo (PowerShell)

```powershell
# Navegar até o projeto
cd C:\Projetos\teste-overlabs

# Executar deploy (cria tudo: ACR, Redis, MySQL, Container Apps)
.\azure\deploy.ps1 -ResourceGroup "rag-overlabs-rg" -Location "brazilsouth"
```

**Isso vai:**
- ✅ Criar Resource Group
- ✅ Criar Azure Container Registry
- ✅ Build e push da imagem da API
- ✅ Criar Azure Redis Cache
- ✅ Criar Azure Database for MySQL
- ✅ Criar Container Apps Environment
- ✅ Deploy do Qdrant
- ✅ Deploy da API

**Tempo estimado:** 10-15 minutos

## Pós-Deploy (Obrigatório)

### 1. Aplicar Schema SQL

```powershell
# Obter informações
$MYSQL_HOST = az mysql flexible-server show --resource-group rag-overlabs-rg --name rag-overlabs-app-mysql --query fullyQualifiedDomainName -o tsv
$MYSQL_USER = az mysql flexible-server show --resource-group rag-overlabs-rg --name rag-overlabs-app-mysql --query administratorLogin -o tsv

# Aplicar schema (vai pedir senha)
mysql -h $MYSQL_HOST -u $MYSQL_USER -p < docs/db_audit_schema.sql
```

### 2. Configurar Secrets (Key Vault)

```powershell
# Criar Key Vault
.\azure\setup-keyvault.ps1 rag-overlabs-rg rag-overlabs-kv

# Adicionar secrets
az keyvault secret set --vault-name rag-overlabs-kv --name "OpenAIApiKey" --value "<sua-chave-openai>"

# Gerar chave de criptografia
python -c "import os,base64; print(base64.b64encode(os.urandom(32)).decode())"
az keyvault secret set --vault-name rag-overlabs-kv --name "AuditEncKey" --value "<chave-gerada>"

# Atualizar Container App (ACA: keyvaultref + secretRef)
az containerapp update `
  --name rag-overlabs-app `
  --resource-group rag-overlabs-rg `
  --set-secrets `
    "openai-api-key=keyvaultref:https://rag-overlabs-kv.vault.azure.net/secrets/OpenAIApiKey" `
    "audit-enc-key-b64=keyvaultref:https://rag-overlabs-kv.vault.azure.net/secrets/AuditEncKey"
az containerapp update `
  --name rag-overlabs-app `
  --resource-group rag-overlabs-rg `
  --set-env-vars `
    "OPENAI_API_KEY=secretref:openai-api-key" `
    "AUDIT_ENC_KEY_B64=secretref:audit-enc-key-b64"
```

### 3. Upload de Documentos e Ingest

**Opção A: Executar dentro do container**

```powershell
# Conectar ao container
az containerapp exec `
  --name rag-overlabs-app `
  --resource-group rag-overlabs-rg `
  --command "python -m scripts.scan_docs"

az containerapp exec `
  --name rag-overlabs-app `
  --resource-group rag-overlabs-rg `
  --command "python -m scripts.ingest"
```

**Opção B: Upload para Azure Storage e montar como volume** (mais complexo, ver README.md)

## Testar a API

```powershell
# Obter URL da API
$API_URL = az containerapp show --name rag-overlabs-app --resource-group rag-overlabs-rg --query properties.configuration.ingress.fqdn -o tsv

# Testar health
curl https://$API_URL/healthz

# Testar /ask
curl -X POST https://$API_URL/ask `
  -H "Content-Type: application/json" `
  -d '{\"question\": \"Qual o prazo de reembolso?\"}'
```

## Ver Logs

```powershell
az containerapp logs show `
  --name rag-overlabs-app `
  --resource-group rag-overlabs-rg `
  --follow
```

## Atualizar Código

```powershell
# Rebuild e push
.\azure\build-and-push.ps1 ragoverlabsacr

# Atualizar app
.\azure\update-app.ps1 rag-overlabs-rg rag-overlabs-app ragoverlabsacr
```

## Custos

**Estimativa mensal (Brasil Sul, uso baixo):**
- Container Apps: ~$10-20
- ACR Basic: ~$5
- Redis Basic (c0): ~$15
- MySQL Flexible (B1ms): ~$12
- **Total: ~$42-52/mês**

## Troubleshooting

### API não responde
```powershell
# Ver status
az containerapp show --name rag-overlabs-app --resource-group rag-overlabs-rg --query properties.runningStatus

# Ver logs
az containerapp logs show --name rag-overlabs-app --resource-group rag-overlabs-rg --tail 100
```

### Erro de conexão MySQL
- Verificar se o schema foi aplicado
- Verificar firewall rules do MySQL (permitir acesso do Container App)
- Verificar credenciais nas variáveis de ambiente

### Qdrant não conecta
- Verificar se o Qdrant Container App está rodando
- Verificar URL no env var `QDRANT_URL`

## Limpar Tudo

```powershell
# ⚠️ CUIDADO: Isso deleta TUDO!
az group delete --name rag-overlabs-rg --yes --no-wait
```

## Próximos Passos

1. ✅ Configurar Application Insights para observabilidade
2. ✅ Setup CI/CD com GitHub Actions
3. ✅ Configurar backup automático do MySQL
4. ✅ Implementar volume mount para documentos (Azure Files)
5. ✅ Configurar autoscaling baseado em métricas
