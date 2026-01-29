# Code Snapshot: Key Vault Secrets Resolution Fix

## Context
This snapshot focuses on the Key Vault secrets resolution issue in Azure Container Apps and the fixes implemented.

**Problem**: Container Apps were using App Service syntax (`@Microsoft.KeyVault(...)`) which doesn't work. Secrets weren't being resolved.

**Solution**: Use Container Apps syntax with `keyvaultref:` in secrets configuration and `secretRef:` in environment variables.

---

## Key Files Modified

### 1. `infra/bootstrap_api.ps1` - Bootstrap Script

**Location**: Lines 113-133 (secrets handling)

```powershell
# Construir env-vars (separar secrets de non-secrets)
# Para Container Apps, secrets devem ser criados com keyvaultref: e referenciados com secretref:
$envVars = @(
    "QDRANT_URL=$QdrantUrl",
    "REDIS_URL=$RedisUrl",
    "DOCS_ROOT=/app/DOC-IA"
)

# Adicionar todas as non-secrets do .env
foreach ($key in $nonSecrets.Keys) {
    $envVars += "$key=$($nonSecrets[$key])"
}

# Secrets serão adicionados separadamente usando --set-secrets com keyvaultref:
# e depois referenciados nas env vars com secretref:
$secretRefs = @{}
foreach ($key in $secrets.Keys) {
    $kvName = $key.ToLower().Replace('_', '-')
    # Nome do secret interno do Container App (usar o mesmo nome do Key Vault para simplicidade)
    $secretRefs[$key] = $kvName
}
```

**Location**: Lines 178-207 (YAML generation)

```powershell
# Construir lista de secrets do Key Vault (para Container Apps)
$secretsYaml = ""
$secretsYaml += "    - name: acr-password`n      value: $acrPassword`n"

# Adicionar secrets do Key Vault usando keyVaultUrl (sintaxe correta para Container Apps)
foreach ($key in $secrets.Keys) {
    $kvName = $key.ToLower().Replace('_', '-')
    $secretUri = "https://$KeyVault.vault.azure.net/secrets/$kvName"
    $secretsYaml += "    - name: $kvName`n      keyVaultUrl: $secretUri`n"
}

# Construir lista de env vars formatada
$envVarsYaml = ""
foreach ($envVar in $envVars) {
    $parts = $envVar -split '=', 2
    $name = $parts[0]
    $value = $parts[1]
    
    # Valor normal: escapar aspas e caracteres especiais
    $value = $value -replace '\\', '\\\\'  # Escapar backslashes primeiro
    $value = $value -replace '"', '\"'      # Escapar aspas
    $value = $value -replace '`n', '\n'     # Escapar newlines
    $envVarsYaml += "      - name: $name`n        value: `"$value`"`n"
}

# Adicionar env vars que referenciam secrets usando secretRef (sintaxe correta para Container Apps)
foreach ($key in $secretRefs.Keys) {
    $secretName = $secretRefs[$key]
    $envVarsYaml += "      - name: $key`n        secretRef: $secretName`n"
}
```

**Location**: Lines 276-308 (CLI fallback)

```powershell
# Construir comandos para secrets (keyvaultref) e env vars (secretref)
$setSecretsArgs = @()
$setSecretsArgs += "acr-password=$acrPassword"
foreach ($key in $secrets.Keys) {
    $kvName = $key.ToLower().Replace('_', '-')
    $secretUri = "https://$KeyVault.vault.azure.net/secrets/$kvName"
    $setSecretsArgs += "$kvName=keyvaultref:$secretUri"
}

$setEnvVarsArgs = @()
foreach ($envVar in $envVars) {
    $setEnvVarsArgs += $envVar
}
foreach ($key in $secretRefs.Keys) {
    $secretName = $secretRefs[$key]
    $setEnvVarsArgs += "$key=secretref:$secretName"
}

az containerapp create `
    --name $ApiApp `
    --resource-group $ResourceGroup `
    --environment $Environment `
    --image "$acrLoginServer/choperia-api:latest" `
    --registry-server $acrLoginServer `
    --registry-username $acrUsername `
    --registry-password $acrPassword `
    --target-port 8000 `
    --ingress external `
    --cpu 2.0 `
    --memory 4.0Gi `
    --min-replicas 1 `
    --max-replicas 5 `
    --set-secrets $setSecretsArgs `
    --set-env-vars $setEnvVarsArgs 2>&1 | Out-Null
```

---

### 2. `azure/bicep/main.bicep` - Infrastructure as Code

**Location**: Lines 33-35 (Key Vault parameter)

```bicep
@description('Nome do Key Vault (deve existir previamente)')
param keyVaultName string = ''

// Variável para construir a URI do Key Vault
var keyVaultUri = keyVaultName != '' ? 'https://${keyVaultName}.vault.azure.net/' : ''
```

**Location**: Lines 160-172 (Secrets configuration)

```bicep
configuration: {
  ingress: {
    external: true
    targetPort: 8000
    transport: 'http'
    allowInsecure: false
  }
  registries: [
    {
      server: acr.properties.loginServer
      identity: ''
    }
  ]
  // Secrets do Key Vault (apenas se keyVaultName foi fornecido)
  secrets: keyVaultName != '' ? [
    {
      name: 'mysql-password'
      keyVaultUrl: '${keyVaultUri}secrets/mysql-password'
    }
    {
      name: 'openai-api-key'
      keyVaultUrl: '${keyVaultUri}secrets/openai-api-key'
    }
    {
      name: 'audit-enc-key-b64'
      keyVaultUrl: '${keyVaultUri}secrets/audit-enc-key-b64'
    }
  ] : []
}
```

**Location**: Lines 181-280 (Environment variables)

```bicep
env: keyVaultName != '' ? [
  // Variáveis não-secretas (valores diretos)
  {
    name: 'QDRANT_URL'
    value: 'http://${qdrantApp.properties.configuration.ingress.fqdn}:6333'
  }
  {
    name: 'REDIS_URL'
    value: 'rediss://:${redis.listKeys().primaryKey}@${redis.properties.hostName}:${redis.properties.port}/0'
  }
  {
    name: 'MYSQL_HOST'
    value: mysqlServer.properties.fullyQualifiedDomainName
  }
  {
    name: 'MYSQL_PORT'
    value: '3306'
  }
  {
    name: 'MYSQL_USER'
    value: mysqlAdminUser
  }
  {
    name: 'MYSQL_DATABASE'
    value: 'rag_audit'
  }
  {
    name: 'MYSQL_SSL_CA'
    value: '/app/certs/DigiCertGlobalRootCA.crt.pem'
  }
  {
    name: 'TRACE_SINK'
    value: 'mysql'
  }
  {
    name: 'AUDIT_LOG_ENABLED'
    value: '1'
  }
  {
    name: 'AUDIT_LOG_INCLUDE_TEXT'
    value: '1'
  }
  {
    name: 'AUDIT_LOG_RAW_MODE'
    value: 'risk_only'
  }
  {
    name: 'ABUSE_CLASSIFIER_ENABLED'
    value: '1'
  }
  {
    name: 'PROMPT_FIREWALL_ENABLED'
    value: '0'
  }
  {
    name: 'LOG_LEVEL'
    value: 'INFO'
  }
  {
    name: 'DOCS_ROOT'
    value: '/app/DOC-IA'
  }
  // Secrets do Key Vault (usando secretRef)
  {
    name: 'MYSQL_PASSWORD'
    secretRef: 'mysql-password'
  }
  {
    name: 'OPENAI_API_KEY'
    secretRef: 'openai-api-key'
  }
  {
    name: 'AUDIT_ENC_KEY_B64'
    secretRef: 'audit-enc-key-b64'
  }
] : [
  // Fallback: se Key Vault não foi fornecido, usar valores diretos (NÃO RECOMENDADO)
  // ... (fallback code)
]
```

---

### 3. `backend/app/config.py` - Application Configuration

**Location**: Lines 17-18 (OpenAI API Key)

```python
use_openai_embeddings: bool = False
openai_api_key: str | None = None
```

**Note**: The application uses Pydantic Settings which automatically reads from `os.getenv("OPENAI_API_KEY")`. No code changes needed - it just receives the resolved value.

---

### 4. `backend/app/retrieval.py` - Embeddings Provider

**Location**: Lines 61-73 (OpenAIEmbeddings initialization with logging)

```python
class OpenAIEmbeddings(EmbeddingsProvider):
    def __init__(self, api_key: str) -> None:
        self._api_key = api_key
        self._client = httpx.AsyncClient(timeout=15.0)
        # Log da chave para debug (apenas primeiros 10 caracteres e tamanho)
        import logging
        import sys
        logger = logging.getLogger(__name__)
        key_preview = api_key[:10] if api_key and len(api_key) >= 10 else (api_key or "None")
        key_length = len(api_key) if api_key else 0
        log_msg = f"[OpenAIEmbeddings.__init__] API Key: preview='{key_preview}...', tamanho={key_length} caracteres"
        print(log_msg, file=sys.stderr)
        logger.info(log_msg)
```

**Location**: Lines 75-88 (Embed method with logging)

```python
async def embed(self, texts: list[str]) -> list[list[float]]:
    # Log da chave antes de cada chamada (apenas primeiros 10 caracteres e tamanho)
    import logging
    import sys
    logger = logging.getLogger(__name__)
    key_preview = self._api_key[:10] if self._api_key and len(self._api_key) >= 10 else (self._api_key or "None")
    key_length = len(self._api_key) if self._api_key else 0
    log_msg = f"[OpenAIEmbeddings.embed] API Key antes da chamada: preview='{key_preview}...', tamanho={key_length} caracteres"
    print(log_msg, file=sys.stderr)
    logger.info(log_msg)
    
    headers = {"Authorization": f"Bearer {self._api_key}"}
    payload = {"model": settings.openai_embeddings_model, "input": texts}
    r = await self._client.post("https://api.openai.com/v1/embeddings", json=payload, headers=headers)
    r.raise_for_status()
    data = r.json()
    return [item["embedding"] for item in data["data"]]
```

---

### 5. `backend/scripts/ingest.py` - Ingestion Script

**Location**: Lines 238-259 (Embedder initialization with logging)

```python
embedder = get_embeddings_provider()

logger = logging.getLogger(__name__)

# Log da chave OpenAI ANTES de criar o embedder
print(f"[ingest] Verificando configuração OpenAI...", file=sys.stderr)
print(f"[ingest] USE_OPENAI_EMBEDDINGS={settings.use_openai_embeddings}", file=sys.stderr)
if settings.openai_api_key:
    key_preview = settings.openai_api_key[:10] if len(settings.openai_api_key) >= 10 else settings.openai_api_key
    key_length = len(settings.openai_api_key)
    print(f"[ingest] OPENAI_API_KEY: preview='{key_preview}...', tamanho={key_length} caracteres", file=sys.stderr)
    logger.info(f"OpenAI API Key no settings: preview='{key_preview}...', tamanho={key_length} caracteres")
else:
    print(f"[ingest] OPENAI_API_KEY esta vazia ou None!", file=sys.stderr)
    logger.warning("OpenAI API Key esta vazia ou None no settings!")

embedder = get_embeddings_provider()
print(f"[ingest] Embedder criado: {type(embedder).__name__}", file=sys.stderr)

qdrant = QdrantClient(url=settings.qdrant_url, timeout=10.0)

indexed = 0
ignored = []

# Preparar coleção (descobrir dim via embedding de teste)
print("[ingest] Testando embedding (isso vai mostrar logs da chave OpenAI)...", file=sys.stderr)
test_vec = (await embedder.embed(["dim probe"]))[0]
```

---

## New Scripts Created

### 1. `infra/fix_keyvault_references.ps1`

Converts existing Container Apps from `@Microsoft.KeyVault(...)` syntax to `secretRef:` syntax.

**Key Logic**: Lines 79-97

```powershell
# Verificar se está usando sintaxe errada (@Microsoft.KeyVault)
if ($value -and $value -match '^@Microsoft\.KeyVault\(SecretUri=https://([^/]+)\.vault\.azure\.net/secrets/([^/]+)') {
    $vaultName = $matches[1]
    $secretName = $matches[2]
    
    Write-Host "  [AVISO] Encontrada sintaxe errada em $name : $value" -ForegroundColor Yellow
    
    # Extrair nome do secret do Key Vault (sem versão)
    $kvSecretName = $secretName -replace '/.*$', ''
    
    # Adicionar secret com keyvaultref
    $secretUri = "https://$vaultName.vault.azure.net/secrets/$kvSecretName"
    $secretsToAdd += "$kvSecretName=keyvaultref:$secretUri"
    
    # Adicionar env var com secretref
    $envVarsToUpdate += "$name=secretref:$kvSecretName"
    
    $needsUpdate = $true
    Write-Host "  [INFO] Será convertido para: secretRef=$kvSecretName" -ForegroundColor Cyan
}
```

### 2. `infra/check_keyvault_secret_resolution.ps1`

Comprehensive diagnostic script that checks all prerequisites for Key Vault secret resolution.

**Checks**:
1. Secret exists in Key Vault?
2. Managed Identity enabled?
3. Permission on Key Vault?
4. Firewall/Private Endpoint configured?
5. Secret configured in Container App?
6. Env var using `secretRef`?

---

## Expected Behavior

### Before Fix (❌)
- `os.getenv("OPENAI_API_KEY")` returns: `"@Microsoft.KeyVault(SecretUri=...)"` (99 chars)
- Logs show: `preview='@Microsoft...', tamanho=99 caracteres`
- Result: `401 Unauthorized` errors

### After Fix (✅)
- `os.getenv("OPENAI_API_KEY")` returns: `"sk-proj-abc123xyz..."` (~51 chars)
- Logs show: `preview='sk-proj-abc...', tamanho=51 caracteres`
- Result: API calls work successfully

---

## Resolution Flow

```
Key Vault (Secret: "sk-proj-abc123...")
    ↓ (Managed Identity)
Container App Configuration
    secrets: [{ name: "openai-api-key", keyVaultUrl: "https://..." }]
    env: [{ name: "OPENAI_API_KEY", secretRef: "openai-api-key" }]
    ↓ (Azure resolves)
Container Runtime
    $OPENAI_API_KEY = "sk-proj-abc123..." (real value)
    ↓ (os.getenv)
Python Application
    settings.openai_api_key = "sk-proj-abc123..."
    ✅ Works!
```

---

## Testing

### Verify in Container
```powershell
az containerapp exec --name <app> --resource-group <rg> --command "echo \$OPENAI_API_KEY | head -c 20"
```

### Check Logs
```powershell
.\infra\run_ingest_in_container.ps1
```

### Diagnostic Script
```powershell
.\infra\check_keyvault_secret_resolution.ps1 -SecretName "openai-api-key"
```

---

## References

- Full problem summary: `docs/problem_summary_for_llm.md`
- Behavior documentation: `docs/keyvault_resolution_behavior.md`
- Bicep documentation: `docs/bicep_keyvault_secrets.md`
- Key Vault references: `docs/keyvault_references.md`
