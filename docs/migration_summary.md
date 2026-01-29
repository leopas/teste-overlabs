# Resumo da Migração: Key Vault References

## Objetivo
Migrar todas as referências de Key Vault do formato App Service (`@Microsoft.KeyVault(...)`) para o formato correto do Azure Container Apps (secrets com `keyVaultUrl` + `identity` e env vars com `secretRef`).

## Status: ✅ CONCLUÍDO

## Arquivos Modificados

### 1. Infraestrutura como Código
- ✅ `azure/bicep/main.bicep`
  - Adicionado `identity: { type: 'SystemAssigned' }` no Container App
  - Secrets configurados com `keyVaultUrl` e `identity: 'system'`
  - Env vars usando `secretRef:` ao invés de valores diretos

### 2. Scripts PowerShell
- ✅ `infra/bootstrap_api.ps1`
  - YAML gerado inclui `identity: SystemAssigned`
  - Secrets do Key Vault adicionados com `keyVaultUrl` e `identity: system`
  - Resolve "chicken-and-egg": cria app sem secrets KV, concede permissão, depois atualiza com secrets
  - Env vars com `secretRef:` adicionadas após conceder permissão no Key Vault
  - CLI fallback também usa `keyvaultref:` e `secretref:`

- ✅ `infra/fix_keyvault_references.ps1` (já existia)
  - Script para corrigir Container Apps existentes

- ✅ `infra/check_keyvault_secret_resolution.ps1` (já existia)
  - Script de diagnóstico completo

- ✅ `infra/validate_keyvault_syntax.ps1` (NOVO)
  - Validação para CI/CD que falha se encontrar `@Microsoft.KeyVault` em YAMLs

### 3. CI/CD
- ✅ `.github/workflows/deploy-azure.yml`
  - Adicionado step de validação de sintaxe Key Vault

### 4. Documentação
- ✅ `azure/DEPLOYMENT.md`
  - Atualizado com sintaxe correta do Container Apps
  - Removido exemplo com `@Microsoft.KeyVault(...)`

- ✅ `azure/README.md`
  - Atualizado com sintaxe correta do Container Apps
  - Removido exemplo com `@Microsoft.KeyVault(...)`

- ✅ `docs/runbook_add_keyvault_secret.md` (NOVO)
  - Runbook completo para adicionar novos secrets

- ✅ `docs/migration_inventory.md` (NOVO)
  - Inventário da migração

## Antes vs Depois

### Antes (❌ ERRADO)
```yaml
properties:
  configuration:
    secrets: []  # Vazio
  template:
    containers:
      - env:
          - name: OPENAI_API_KEY
            value: "@Microsoft.KeyVault(SecretUri=https://kv.../secrets/openai-api-key/)"
```

### Depois (✅ CORRETO)
```yaml
properties:
  identity:
    type: SystemAssigned
  configuration:
    secrets:
      - name: openai-api-key
        keyVaultUrl: https://kv.../secrets/openai-api-key
        identity: system
  template:
    containers:
      - env:
          - name: OPENAI_API_KEY
            secretRef: openai-api-key
```

## Fluxo de Bootstrap (Chicken-and-Egg Resolvido)

1. **Fase 1: Criar Container App**
   - Com `identity: SystemAssigned` no YAML
   - SEM secrets do Key Vault (apenas ACR password)
   - SEM env vars com `secretRef`

2. **Fase 2: Configurar Permissões**
   - Obter `principalId` da Managed Identity
   - Conceder role `Key Vault Secrets User` no Key Vault
   - Aguardar propagação (5 segundos)

3. **Fase 3: Adicionar Secrets do Key Vault**
   - `az containerapp update --set-secrets "secret-name=keyvaultref:https://..."`
   - Adicionar todos os secrets necessários

4. **Fase 4: Adicionar Env Vars com secretRef**
   - `az containerapp update --set-env-vars "ENV_VAR=secretref:secret-name"`
   - Adicionar todas as env vars que referenciam secrets

## Validação

### Script de Validação
```powershell
.\infra\validate_keyvault_syntax.ps1
```

**Verifica:**
- ❌ YAMLs com `@Microsoft.KeyVault`
- ❌ Scripts PowerShell que injetam `@Microsoft.KeyVault` em YAMLs/env vars
- ❌ Bicep com `@Microsoft.KeyVault`
- ⚠️ Secrets com `value:` literal (deveria usar `keyVaultUrl`)

### CI/CD
O pipeline GitHub Actions agora valida automaticamente a sintaxe.

## YAMLs Temporários

Os arquivos `app_bootstrap_*.yaml` são gerados dinamicamente pelo `bootstrap_api.ps1`. Após a correção do script, os novos YAMLs gerados estarão corretos.

**Ação**: Os YAMLs antigos podem ser deletados (são temporários).

## Checklist Final

- [x] Bicep atualizado com `identity` e `keyVaultUrl` + `identity: system`
- [x] `bootstrap_api.ps1` corrigido (YAML e CLI)
- [x] Resolve "chicken-and-egg" (cria app → permissão → secrets)
- [x] Script de validação criado
- [x] CI/CD atualizado com validação
- [x] Documentação atualizada
- [x] Runbook criado
- [x] Zero ocorrências de `@Microsoft.KeyVault` em código ativo (apenas docs/exemplos)

## Como Testar

1. **Validar sintaxe:**
   ```powershell
   .\infra\validate_keyvault_syntax.ps1
   ```

2. **Bootstrap completo:**
   ```powershell
   .\infra\bootstrap_container_apps.ps1
   ```

3. **Verificar resolução:**
   ```powershell
   .\infra\check_keyvault_secret_resolution.ps1 -SecretName "openai-api-key"
   ```

4. **Testar no container:**
   ```powershell
   az containerapp exec --name <app> --resource-group <rg> --command "echo `$OPENAI_API_KEY | head -c 20"
   ```
   **Esperado**: Valor real (não `@Microsoft...`)

## Próximos Passos

1. Executar validação no CI/CD
2. Testar bootstrap completo em ambiente de teste
3. Deletar YAMLs temporários antigos (opcional)
4. Monitorar logs após deploy para confirmar resolução
