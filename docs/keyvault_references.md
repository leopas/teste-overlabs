# Referências do Key Vault: App Service vs Container Apps

## Problema Identificado

O código estava usando a sintaxe de **Azure App Service** (`@Microsoft.KeyVault(...)`) para referenciar secrets do Key Vault, mas isso **não funciona** em **Azure Container Apps**.

## Diferenças entre os Serviços

### Azure App Service / Azure Functions

**Sintaxe:**
```
@Microsoft.KeyVault(SecretUri=https://<vault>.vault.azure.net/secrets/<name>/<version?>)
```

**Como funciona:**
- O App Service resolve automaticamente o placeholder em runtime
- Requer Managed Identity com permissão `Get` no secret
- Funciona diretamente nas Application Settings

**Exemplo:**
```powershell
az webapp config appsettings set \
  --name <app-name> \
  --resource-group <rg> \
  --settings "MY_SECRET=@Microsoft.KeyVault(SecretUri=https://kv.vault.azure.net/secrets/my-secret/)"
```

### Azure Container Apps

**Sintaxe:**
1. Criar secret no Container App apontando para Key Vault:
   ```
   keyvaultref:<SecretUri>
   ```

2. Referenciar secret na env var:
   ```
   secretref:<SecretName>
   ```

**Como funciona:**
- Container Apps não resolve `@Microsoft.KeyVault(...)` automaticamente
- Precisa declarar secrets explicitamente no Container App
- Secrets são criados com `keyvaultref:` apontando para o Key Vault
- Env vars usam `secretref:` para referenciar o secret interno

**Exemplo (CLI):**
```powershell
# 1. Criar secret no Container App (keyvaultref)
az containerapp update \
  --name <app-name> \
  --resource-group <rg> \
  --set-secrets "my-secret=keyvaultref:https://kv.vault.azure.net/secrets/my-secret" \
  --set-env-vars "MY_SECRET=secretref:my-secret"
```

**Exemplo (YAML):**
```yaml
properties:
  configuration:
    secrets:
      - name: my-secret
        keyVaultUrl: https://kv.vault.azure.net/secrets/my-secret
  template:
    containers:
      - name: api
        env:
          - name: MY_SECRET
            secretRef: my-secret
```

## Checklist para Funcionar

1. ✅ **Managed Identity habilitada** no Container App
2. ✅ **Permissão no Key Vault** para a Managed Identity:
   - RBAC: Role `Key Vault Secrets User`
   - Access Policy: Permission `Get` em secrets
3. ✅ **Vault acessível** (firewall/private endpoint configurado)
4. ✅ **Secret criado no Container App** usando `keyvaultref:`
5. ✅ **Env var usando `secretref:`** ao invés de valor direto

## Correção Aplicada

O script `bootstrap_api.ps1` foi corrigido para:

1. **Separar secrets de non-secrets** durante o bootstrap
2. **Criar secrets no Container App** usando `keyvaultref:` apontando para o Key Vault
3. **Usar `secretref:` nas env vars** ao invés de `@Microsoft.KeyVault(...)`

### Antes (ERRADO):
```powershell
--env-vars "OPENAI_API_KEY=@Microsoft.KeyVault(SecretUri=https://kv.vault.azure.net/secrets/openai-api-key/)"
```

### Depois (CORRETO):
```powershell
--set-secrets "openai-api-key=keyvaultref:https://kv.vault.azure.net/secrets/openai-api-key" \
--set-env-vars "OPENAI_API_KEY=secretref:openai-api-key"
```

## Script de Correção

Para corrigir Container Apps existentes que estão usando a sintaxe errada:

```powershell
.\infra\fix_keyvault_references.ps1
```

Este script:
1. Detecta env vars usando `@Microsoft.KeyVault(...)`
2. Converte para secrets com `keyvaultref:`
3. Atualiza env vars para usar `secretref:`

## Referências

- [Azure Container Apps - Secrets](https://learn.microsoft.com/en-us/azure/container-apps/manage-secrets)
- [Azure App Service - Key Vault References](https://learn.microsoft.com/en-us/azure/app-service/app-service-key-vault-references)
- [Azure Key Vault - Managed Identity](https://learn.microsoft.com/en-us/azure/key-vault/general/managed-identity)
