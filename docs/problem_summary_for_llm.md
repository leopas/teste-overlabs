# Prompt: Problema de Resolução de Key Vault Secrets no Azure Container Apps

## Contexto do Problema

Estamos desenvolvendo uma aplicação RAG (Retrieval-Augmented Generation) em Python que roda em **Azure Container Apps**. A aplicação precisa acessar secrets do **Azure Key Vault** (como `OPENAI_API_KEY`, `MYSQL_PASSWORD`, etc.) através de variáveis de ambiente.

## O Problema Original

### Sintaxe Incorreta Usada

Inicialmente, o código estava usando a sintaxe de **Azure App Service** para referenciar secrets do Key Vault:

```
OPENAI_API_KEY = "@Microsoft.KeyVault(SecretUri=https://kv-overlabs-prod-300.vault.azure.net/secrets/openai-api-key/)"
```

### Por Que Não Funcionava

1. **Azure Container Apps NÃO resolve** a sintaxe `@Microsoft.KeyVault(...)` automaticamente
2. Essa sintaxe é específica do **Azure App Service / Azure Functions**
3. O Container Apps recebia o valor literal `"@Microsoft.KeyVault(...)"` (99 caracteres) ao invés do valor real do secret
4. A aplicação Python via `os.getenv("OPENAI_API_KEY")` recebia a string literal, não o secret resolvido
5. Resultado: **401 Unauthorized** ao chamar APIs externas (OpenAI, etc.)

### Evidências do Problema

- Logs mostravam: `preview='@Microsoft...', tamanho=99 caracteres`
- Erros: `Client error '401 Unauthorized' for url 'https://api.openai.com/v1/embeddings'`
- A chave OpenAI não era válida porque era a string literal, não o valor real

## A Solução Implementada

### Sintaxe Correta para Azure Container Apps

Azure Container Apps requer uma abordagem em **duas etapas**:

1. **Definir secrets na configuração** do Container App apontando para o Key Vault:
   ```yaml
   configuration:
     secrets:
       - name: openai-api-key
         keyVaultUrl: https://kv-overlabs-prod-300.vault.azure.net/secrets/openai-api-key
   ```

2. **Referenciar secrets nas env vars** usando `secretRef:`:
   ```yaml
   containers:
     - env:
         - name: OPENAI_API_KEY
           secretRef: openai-api-key  # ← Referencia o secret acima
   ```

### Como Funciona

1. Container Apps detecta `secretRef: openai-api-key`
2. Busca o secret na configuração com `keyVaultUrl`
3. Usa a **Managed Identity** do Container App para autenticar no Key Vault
4. Faz requisição ao Key Vault: `GET /secrets/openai-api-key`
5. Key Vault retorna o valor real do secret
6. Container Apps injeta o valor real na variável de ambiente do container
7. Aplicação Python recebe o valor real via `os.getenv("OPENAI_API_KEY")`

## Arquivos Modificados

### 1. `infra/bootstrap_api.ps1`
- **Antes**: Criava env vars com `@Microsoft.KeyVault(...)`
- **Depois**: Cria secrets com `keyvaultref:` e env vars com `secretref:`

### 2. `azure/bicep/main.bicep`
- **Antes**: Passava valores diretos de secrets nas env vars
- **Depois**: Define secrets na configuração com `keyVaultUrl` e usa `secretRef` nas env vars

### 3. Scripts de Correção Criados
- `infra/fix_keyvault_references.ps1`: Converte Container Apps existentes
- `infra/check_keyvault_secret_resolution.ps1`: Diagnóstico completo

## Pré-requisitos para Funcionar

1. ✅ **Managed Identity habilitada** no Container App
2. ✅ **Permissão no Key Vault** para a Managed Identity:
   - RBAC: Role `Key Vault Secrets User`
   - Access Policy: Permission `Get` em secrets
3. ✅ **Key Vault acessível** (firewall/private endpoint configurado)
4. ✅ **Secrets existem no Key Vault** com os nomes corretos
5. ✅ **Secrets definidos no Container App** usando `keyVaultUrl`
6. ✅ **Env vars usando `secretRef:`** ao invés de valores diretos

## Como Verificar se Funcionou

### 1. Verificar no Container
```bash
az containerapp exec --name <app-name> --resource-group <rg> --command "echo \$OPENAI_API_KEY | head -c 20"
```
**Esperado**: `sk-proj-abc123xyz...` (valor real, não `@Microsoft...`)

### 2. Verificar nos Logs
```bash
.\infra\run_ingest_in_container.ps1
```
**Esperado nos logs**:
```
[ingest] OPENAI_API_KEY: preview='sk-proj-abc...', tamanho=51 caracteres
[OpenAIEmbeddings.__init__] API Key: preview='sk-proj-abc...', tamanho=51 caracteres
INFO: httpx: HTTP Request: POST https://api.openai.com/v1/embeddings "HTTP/1.1 200 OK"
```

### 3. Verificar Funcionalidade
- ✅ Ingestão funciona sem erro `401 Unauthorized`
- ✅ Embeddings são gerados com sucesso
- ✅ Chamadas ao LLM funcionam

## Diferenças Entre Serviços Azure

| Serviço | Sintaxe | Como Funciona |
|---------|---------|---------------|
| **App Service / Functions** | `@Microsoft.KeyVault(SecretUri=...)` | Resolve automaticamente em runtime |
| **Container Apps** | `keyvaultref:` + `secretRef:` | Requer definição explícita de secrets |

## Pontos Importantes

1. **A aplicação Python não precisa mudar** - continua lendo de `os.getenv("OPENAI_API_KEY")` normalmente
2. **A resolução acontece no Azure** - antes de injetar no container
3. **A Managed Identity é essencial** - sem ela, o Container Apps não consegue acessar o Key Vault
4. **Os logs ajudam a diagnosticar** - sempre mostram preview e tamanho da chave

## Comandos Úteis

```powershell
# Corrigir Container App existente
.\infra\fix_keyvault_references.ps1

# Diagnosticar problemas
.\infra\check_keyvault_secret_resolution.ps1 -SecretName "openai-api-key"

# Recriar ambiente completo
.\infra\bootstrap_container_apps.ps1
```

## Referências

- [Azure Container Apps - Secrets](https://learn.microsoft.com/en-us/azure/container-apps/manage-secrets)
- [Azure App Service - Key Vault References](https://learn.microsoft.com/en-us/azure/app-service/app-service-key-vault-references)
- [Azure Key Vault - Managed Identity](https://learn.microsoft.com/en-us/azure/key-vault/general/managed-identity)
