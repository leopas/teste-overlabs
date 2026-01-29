# PR: Migração Key Vault References para Sintaxe Correta do Container Apps

## Resumo

Migração completa de todas as referências de Key Vault do formato App Service (`@Microsoft.KeyVault(...)`) para o formato correto do Azure Container Apps (secrets com `keyVaultUrl` + `identity` e env vars com `secretRef`).

## Problema

Azure Container Apps **não resolve** a sintaxe `@Microsoft.KeyVault(...)` automaticamente. Essa sintaxe é específica do Azure App Service/Functions. O resultado era que secrets não eram resolvidos e a aplicação recebia a string literal ao invés do valor real.

## Solução

### Sintaxe Correta para Container Apps

1. **Secrets na configuração:**
   ```yaml
   configuration:
     secrets:
       - name: openai-api-key
         keyVaultUrl: https://kv.../secrets/openai-api-key
         identity: system
   ```

2. **Env vars usando secretRef:**
   ```yaml
   containers:
     - env:
         - name: OPENAI_API_KEY
           secretRef: openai-api-key
   ```

## Arquivos Modificados

### Infraestrutura
- `azure/bicep/main.bicep`
  - ✅ Adicionado `identity: { type: 'SystemAssigned' }`
  - ✅ Secrets com `keyVaultUrl` e `identity: 'system'`
  - ✅ Env vars usando `secretRef:`

### Scripts
- `infra/bootstrap_api.ps1`
  - ✅ YAML gerado inclui `identity: SystemAssigned`
  - ✅ Secrets do Key Vault com `keyVaultUrl` e `identity: system`
  - ✅ Resolve "chicken-and-egg": cria app → permissão → secrets
  - ✅ CLI fallback também corrigido

- `infra/validate_keyvault_syntax.ps1` (NOVO)
  - ✅ Validação para CI/CD
  - ✅ Falha se encontrar `@Microsoft.KeyVault` em YAMLs

### CI/CD
- `.github/workflows/deploy-azure.yml`
  - ✅ Adicionado step de validação

### Documentação
- `azure/DEPLOYMENT.md` - Atualizado com sintaxe correta
- `azure/README.md` - Atualizado com sintaxe correta
- `docs/runbook_add_keyvault_secret.md` (NOVO) - Runbook completo
- `docs/migration_summary.md` (NOVO) - Resumo da migração

## Antes vs Depois

### Antes (❌)
```yaml
env:
  - name: OPENAI_API_KEY
    value: "@Microsoft.KeyVault(SecretUri=https://kv.../secrets/openai-api-key/)"
```
**Resultado**: String literal `"@Microsoft.KeyVault(...)"` (99 chars) → 401 Unauthorized

### Depois (✅)
```yaml
configuration:
  secrets:
    - name: openai-api-key
      keyVaultUrl: https://kv.../secrets/openai-api-key
      identity: system
containers:
  - env:
      - name: OPENAI_API_KEY
        secretRef: openai-api-key
```
**Resultado**: Valor real `"sk-proj-abc123..."` (~51 chars) → Funciona ✅

## Fluxo de Bootstrap (Chicken-and-Egg Resolvido)

1. **Criar Container App** com `identity: SystemAssigned` (sem secrets KV)
2. **Conceder permissão** `Key Vault Secrets User` no Key Vault
3. **Aguardar propagação** (5 segundos)
4. **Atualizar Container App** com secrets do Key Vault (`keyvaultref:`)
5. **Atualizar env vars** com `secretRef:`

## Como Testar

### 1. Validar Sintaxe
```powershell
.\infra\validate_keyvault_syntax.ps1
```

### 2. Bootstrap Completo
```powershell
.\infra\bootstrap_container_apps.ps1
```

### 3. Verificar Resolução
```powershell
.\infra\check_keyvault_secret_resolution.ps1 -SecretName "openai-api-key"
```

### 4. Testar no Container
```powershell
az containerapp exec --name <app> --resource-group <rg> --command "echo `$OPENAI_API_KEY | head -c 20"
```
**Esperado**: Valor real (não `@Microsoft...`)

## Checklist

- [x] Zero ocorrências de `@Microsoft.KeyVault` em código ativo
- [x] Todos os secrets usando `keyVaultUrl` + `identity: system`
- [x] Todas as env vars usando `secretRef:`
- [x] Identity `SystemAssigned` habilitada
- [x] Script de validação criado
- [x] CI/CD atualizado
- [x] Documentação atualizada
- [x] Runbook criado

## Breaking Changes

⚠️ **Nenhum** - A aplicação Python não precisa mudar. Apenas a infraestrutura foi atualizada.

## Referências

- [Azure Container Apps - Secrets](https://learn.microsoft.com/en-us/azure/container-apps/manage-secrets)
- Documentação interna: `docs/keyvault_references.md`
- Runbook: `docs/runbook_add_keyvault_secret.md`
