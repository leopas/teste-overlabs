# Runbook: Adicionar Novo Secret do Key Vault ao Container App

## Objetivo
Adicionar um novo secret do Azure Key Vault ao Container App usando a sintaxe correta do Azure Container Apps.

## Pré-requisitos
- ✅ Key Vault já existe e está acessível
- ✅ Secret já existe no Key Vault
- ✅ Container App tem Managed Identity habilitada
- ✅ Managed Identity tem permissão `Key Vault Secrets User` no Key Vault

## Passo a Passo

### 1. Criar/Verificar Secret no Key Vault

```powershell
# Verificar se o secret existe
az keyvault secret show --vault-name <key-vault-name> --name <secret-name>

# Se não existir, criar
az keyvault secret set `
  --vault-name <key-vault-name> `
  --name <secret-name> `
  --value "<valor-do-secret>"
```

**Exemplo:**
```powershell
az keyvault secret set `
  --vault-name kv-overlabs-prod-300 `
  --name my-new-secret `
  --value "my-secret-value"
```

### 2. Adicionar Secret ao Container App

#### Opção A: Via YAML (Recomendado)

Edite o YAML do Container App ou o template Bicep:

**Bicep (`azure/bicep/main.bicep`):**
```bicep
secrets: keyVaultName != '' ? [
  // ... secrets existentes ...
  {
    name: 'my-new-secret'  // kebab-case
    keyVaultUrl: '${keyVaultUri}secrets/my-new-secret'
    identity: 'system'
  }
] : []
```

**YAML (gerado pelo bootstrap):**
```yaml
configuration:
  secrets:
    - name: my-new-secret
      keyVaultUrl: https://kv-overlabs-prod-300.vault.azure.net/secrets/my-new-secret
      identity: system
```

#### Opção B: Via Azure CLI

```powershell
az containerapp update `
  --name <container-app-name> `
  --resource-group <resource-group> `
  --set-secrets "my-new-secret=keyvaultref:https://<key-vault-name>.vault.azure.net/secrets/my-new-secret"
```

### 3. Adicionar Env Var Referenciando o Secret

#### Opção A: Via YAML

**Bicep:**
```bicep
env: keyVaultName != '' ? [
  // ... outras env vars ...
  {
    name: 'MY_NEW_SECRET'  // UPPER_SNAKE_CASE
    secretRef: 'my-new-secret'  // Referencia o secret definido acima
  }
] : []
```

**YAML:**
```yaml
containers:
  - name: api
    env:
      - name: MY_NEW_SECRET
        secretRef: my-new-secret
```

#### Opção B: Via Azure CLI

```powershell
az containerapp update `
  --name <container-app-name> `
  --resource-group <resource-group> `
  --set-env-vars "MY_NEW_SECRET=secretref:my-new-secret"
```

### 4. Verificar Configuração

```powershell
# Verificar secrets configurados
az containerapp show `
  --name <container-app-name> `
  --resource-group <resource-group> `
  --query "properties.configuration.secrets" -o json

# Verificar env vars
az containerapp show `
  --name <container-app-name> `
  --resource-group <resource-group> `
  --query "properties.template.containers[0].env" -o json
```

### 5. Testar no Container

```powershell
# Verificar se o valor está sendo resolvido
az containerapp exec `
  --name <container-app-name> `
  --resource-group <resource-group> `
  --command "echo `$MY_NEW_SECRET | head -c 20"
```

**Esperado**: Valor real do secret (não `@Microsoft.KeyVault(...)`)

## Convenções de Nomenclatura

- **Secret no Key Vault**: `kebab-case` (ex: `my-new-secret`)
- **Secret no Container App**: `kebab-case` (ex: `my-new-secret`)
- **Env Var**: `UPPER_SNAKE_CASE` (ex: `MY_NEW_SECRET`)

## Troubleshooting

### Secret não está sendo resolvido

1. **Verificar Managed Identity:**
   ```powershell
   az containerapp show --name <app> --resource-group <rg> --query "identity" -o json
   ```

2. **Verificar Permissões:**
   ```powershell
   $principalId = az containerapp show --name <app> --resource-group <rg> --query "identity.principalId" -o tsv
   az role assignment list --assignee $principalId --scope /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<kv>
   ```

3. **Verificar Firewall do Key Vault:**
   ```powershell
   az keyvault show --name <kv> --query "properties.networkAcls" -o json
   ```
   - Deve permitir "Azure Services" ou ter regra específica

4. **Verificar Logs do Container App:**
   ```powershell
   az containerapp logs show --name <app> --resource-group <rg> --follow
   ```

### Erro: "Secret not found"

- Verificar se o secret existe no Key Vault
- Verificar se o nome está correto (case-sensitive)
- Verificar se a URI está correta (sem versão para pegar latest)

### Erro: "Forbidden" ou "Unauthorized"

- Verificar se Managed Identity tem permissão `Key Vault Secrets User`
- Verificar se o Key Vault permite acesso via "Azure Services"
- Aguardar alguns segundos após conceder permissão (propagação)

## Exemplo Completo

### Adicionar `DATABASE_CONNECTION_STRING`

1. **Criar secret no Key Vault:**
   ```powershell
   az keyvault secret set `
     --vault-name kv-overlabs-prod-300 `
     --name database-connection-string `
     --value "Server=...;Database=...;User Id=...;Password=..."
   ```

2. **Atualizar Bicep:**
   ```bicep
   secrets: keyVaultName != '' ? [
     // ... existentes ...
     {
       name: 'database-connection-string'
       keyVaultUrl: '${keyVaultUri}secrets/database-connection-string'
       identity: 'system'
     }
   ] : []
   
   env: keyVaultName != '' ? [
     // ... existentes ...
     {
       name: 'DATABASE_CONNECTION_STRING'
       secretRef: 'database-connection-string'
     }
   ] : []
   ```

3. **Deploy:**
   ```powershell
   az deployment group create `
     --resource-group <rg> `
     --template-file azure/bicep/main.bicep `
     --parameters @azure/bicep/parameters.json
   ```

4. **Verificar:**
   ```powershell
   az containerapp exec `
     --name <app> `
     --resource-group <rg> `
     --command "echo `$DATABASE_CONNECTION_STRING | head -c 30"
   ```

## Checklist

- [ ] Secret criado no Key Vault
- [ ] Secret adicionado em `configuration.secrets` com `keyVaultUrl` e `identity: system`
- [ ] Env var adicionada com `secretRef:` (não `value:`)
- [ ] Managed Identity habilitada no Container App
- [ ] Permissão `Key Vault Secrets User` concedida
- [ ] Key Vault acessível (firewall configurado)
- [ ] Testado no container (valor resolvido corretamente)

## Duas fases no bootstrap

Ao criar o Container App pela primeira vez: (1) criar o app com identity habilitada, sem secrets do Key Vault no YAML; (2) conceder permissão RBAC no Key Vault ao `principalId` do app; (3) aplicar secrets com `az containerapp update --set-secrets` e env vars com `--set-env-vars ...=secretref:...`. O script `infra/bootstrap_api.ps1` já faz isso. Não use scripts em `infra/old/` para deploy; são legado e podem usar sintaxe incorreta (`@Microsoft.KeyVault`).

## Rotacionar secrets

1. **Atualizar o valor no Key Vault** (novo valor ou nova versão):
   ```powershell
   az keyvault secret set --vault-name <kv> --name <secret-name> --value "<novo-valor>"
   ```
2. O Container App usa a URL sem versão (latest); a próxima leitura já verá o novo valor.
3. Para forçar refresh imediato: criar nova revisão (ex.: `az containerapp update --name <app> --resource-group <rg>` com qualquer alteração mínima) ou aguardar o próximo cold start.

## Referências

- [Azure Container Apps - Secrets](https://learn.microsoft.com/en-us/azure/container-apps/manage-secrets)
- [Azure Key Vault - Managed Identity](https://learn.microsoft.com/en-us/azure/key-vault/general/managed-identity)
- Documentação interna: `docs/keyvault_references.md`
