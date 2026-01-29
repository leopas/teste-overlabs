# Comportamento Esperado: Resolução de Secrets do Key Vault

## Antes da Alteração (❌ NÃO FUNCIONAVA)

### O que acontecia:

1. **Container App recebia:**
   ```
   OPENAI_API_KEY = "@Microsoft.KeyVault(SecretUri=https://kv-overlabs-prod-300.vault.azure.net/secrets/openai-api-key/)"
   ```

2. **Aplicação Python via `os.getenv("OPENAI_API_KEY")` recebia:**
   - Valor literal: `"@Microsoft.KeyVault(SecretUri=...)"` (99 caracteres)
   - **NÃO era resolvido** pelo Container Apps (essa sintaxe é do App Service)

3. **Resultado:**
   - ❌ Chave OpenAI inválida
   - ❌ Erro `401 Unauthorized` ao chamar API OpenAI
   - ❌ Logs mostravam: `preview='@Microsoft...', tamanho=99 caracteres`

### Logs que você via:

```
[ingest] OPENAI_API_KEY: preview='@Microsoft...', tamanho=99 caracteres
[OpenAIEmbeddings.__init__] API Key: preview='@Microsoft...', tamanho=99 caracteres
ERROR: Client error '401 Unauthorized' for url 'https://api.openai.com/v1/embeddings'
```

---

## Depois da Alteração (✅ FUNCIONA)

### O que acontece agora:

1. **Container App recebe (via `secretRef`):**
   ```
   OPENAI_API_KEY = secretref:openai-api-key
   ```

2. **Azure Container Apps resolve automaticamente:**
   - Busca o secret `openai-api-key` definido na configuração
   - O secret aponta para: `keyVaultUrl: https://kv-overlabs-prod-300.vault.azure.net/secrets/openai-api-key`
   - Container Apps usa a **Managed Identity** para buscar o valor do Key Vault
   - **Injeta o valor real** na variável de ambiente do container

3. **Aplicação Python via `os.getenv("OPENAI_API_KEY")` recebe:**
   - ✅ Valor real: `"sk-proj-abc123xyz..."` (51 caracteres típicos)
   - ✅ Chave válida e funcional

4. **Resultado:**
   - ✅ Chave OpenAI válida
   - ✅ Chamadas à API OpenAI funcionam
   - ✅ Logs mostram: `preview='sk-proj-abc...', tamanho=51 caracteres`

### Logs que você verá:

```
[ingest] OPENAI_API_KEY: preview='sk-proj-abc...', tamanho=51 caracteres
[OpenAIEmbeddings.__init__] API Key: preview='sk-proj-abc...', tamanho=51 caracteres
INFO: httpx: HTTP Request: POST https://api.openai.com/v1/embeddings "HTTP/1.1 200 OK"
```

---

## Fluxo Completo de Resolução

### 1. No Azure Container Apps (Infraestrutura)

```yaml
# Configuração do Container App
configuration:
  secrets:
    - name: openai-api-key
      keyVaultUrl: https://kv-overlabs-prod-300.vault.azure.net/secrets/openai-api-key
  containers:
    - env:
        - name: OPENAI_API_KEY
          secretRef: openai-api-key  # ← Referencia o secret acima
```

### 2. Resolução pelo Azure (Runtime)

1. Container Apps detecta `secretRef: openai-api-key`
2. Busca o secret na configuração: `keyVaultUrl: https://...`
3. Usa a **Managed Identity** do Container App para autenticar no Key Vault
4. Faz requisição ao Key Vault: `GET /secrets/openai-api-key`
5. Key Vault retorna o valor real do secret
6. Container Apps injeta o valor na variável de ambiente do container

### 3. Na Aplicação Python (Código)

```python
# backend/app/config.py
class Settings(BaseSettings):
    openai_api_key: str | None = None  # ← Lê de OPENAI_API_KEY automaticamente

# Pydantic Settings lê automaticamente de os.getenv("OPENAI_API_KEY")
settings = Settings()  # ← Já tem o valor resolvido aqui!

# backend/app/retrieval.py
class OpenAIEmbeddings:
    def __init__(self, api_key: str):
        # api_key já vem com o valor real do Key Vault
        self._api_key = api_key  # ← "sk-proj-abc123xyz..."
```

---

## Como Verificar se Está Funcionando

### 1. Verificar no Container (via `az containerapp exec`)

```powershell
az containerapp exec `
  --name app-overlabs-prod-300 `
  --resource-group rg-overlabs-prod `
  --command "echo `$OPENAI_API_KEY | head -c 20"
```

**Resultado esperado:**
- ✅ `sk-proj-abc123xyz...` (chave real)
- ❌ `@Microsoft.KeyVault(...)` (ainda não resolvido)

### 2. Verificar nos Logs da Aplicação

Execute a ingestão e veja os logs:

```powershell
.\infra\run_ingest_in_container.ps1
```

**Logs esperados:**
```
[ingest] OPENAI_API_KEY: preview='sk-proj-abc...', tamanho=51 caracteres
[OpenAIEmbeddings.__init__] API Key: preview='sk-proj-abc...', tamanho=51 caracteres
```

### 3. Verificar se a API OpenAI Funciona

Se a chave está resolvida corretamente:
- ✅ Ingestão funciona sem erro `401 Unauthorized`
- ✅ Embeddings são gerados com sucesso
- ✅ Chamadas ao LLM funcionam

### 4. Script de Diagnóstico

```powershell
.\infra\check_keyvault_secret_resolution.ps1 -SecretName "openai-api-key"
```

Este script verifica todos os pré-requisitos:
- ✅ Secret existe no Key Vault?
- ✅ Managed Identity habilitada?
- ✅ Permissão no Key Vault?
- ✅ Firewall/Private Endpoint configurado?
- ✅ Secret configurado no Container App?
- ✅ Env var usando `secretRef`?

---

## Diferenças Visuais

### Antes (❌):

```bash
$ echo $OPENAI_API_KEY
@Microsoft.KeyVault(SecretUri=https://kv-overlabs-prod-300.vault.azure.net/secrets/openai-api-key/)

$ python -c "import os; print(len(os.getenv('OPENAI_API_KEY')))"
99
```

### Depois (✅):

```bash
$ echo $OPENAI_API_KEY
sk-proj-abc123xyz789def456ghi012jkl345mno678pqr901stu234vwx567yz

$ python -c "import os; print(len(os.getenv('OPENAI_API_KEY')))"
51
```

---

## Resumo

| Aspecto | Antes | Depois |
|---------|-------|--------|
| **Valor na env var** | `@Microsoft.KeyVault(...)` | `sk-proj-abc123...` (valor real) |
| **Tamanho** | 99 caracteres | ~51 caracteres (típico) |
| **Resolução** | ❌ Não resolvido | ✅ Resolvido automaticamente |
| **API OpenAI** | ❌ 401 Unauthorized | ✅ Funciona |
| **Logs** | `preview='@Microsoft...'` | `preview='sk-proj-abc...'` |

---

## Pontos Importantes

1. **A aplicação Python NÃO precisa mudar nada** - ela continua lendo de `os.getenv("OPENAI_API_KEY")` normalmente
2. **A resolução acontece no Azure** - antes de injetar no container
3. **A Managed Identity é essencial** - sem ela, o Container Apps não consegue acessar o Key Vault
4. **Os logs ajudam a diagnosticar** - sempre mostram preview e tamanho da chave

---

## Troubleshooting

Se ainda não funcionar:

1. Execute o checklist: `.\infra\check_keyvault_secret_resolution.ps1`
2. Verifique se a Managed Identity tem permissão: `Key Vault Secrets User`
3. Verifique se o secret existe no Key Vault
4. Verifique se o Container App está usando `secretRef:` e não `value:`
5. Aguarde alguns segundos após atualizar (propagação do Azure)
