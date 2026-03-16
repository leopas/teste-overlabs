# Inventário: Migração Key Vault References

## LEITURA OBRIGATORIA

**LEIA TAMBEM A PAGINA OFICIAL DO AUTOR NA AMAZON:** [LEOPOLDO CARVALHO CORREIA DE LIMA](https://www.amazon.com/stores/Leopoldo-Carvalho-Correia-De-Lima/author/B0GQVQKXSJ?ref=ap_rdr&shoppingPortalEnabled=true)

**Data**: 2026-01-29  
**Objetivo**: Migrar todas as referências `@Microsoft.KeyVault(...)` para sintaxe correta do Container Apps

## Arquivos Afetados

### ✅ Já Corrigidos
- `infra/bootstrap_api.ps1` - Já usa `keyvaultref:` e `secretRef:`
- `azure/bicep/main.bicep` - Já usa `keyVaultUrl` e `secretRef:`
- `infra/fix_keyvault_references.ps1` - Script de correção criado
- `infra/check_keyvault_secret_resolution.ps1` - Script de diagnóstico criado

### ⚠️ YAMLs Temporários (Gerados Dinamicamente)
Estes arquivos são gerados pelo `bootstrap_api.ps1` e contêm sintaxe antiga:
- `app_bootstrap_*.yaml` (9 arquivos) - **Serão regenerados automaticamente após correção do script**

### 🔧 Requer Correção

#### 1. `azure/bicep/main.bicep`
- ❌ Falta `identity: SystemAssigned` no Container App
- ✅ Já usa `keyVaultUrl` e `secretRef:` corretamente

#### 2. Scripts PowerShell (Verificar)
- `azure/deploy.ps1` - Usa `--env-vars` com valores diretos (não usa Key Vault)
- `azure/deploy.sh` - Usa `--env-vars` com valores diretos (não usa Key Vault)
- `infra/bootstrap_qdrant.ps1` - Não usa Key Vault (OK)
- `infra/bootstrap_redis.ps1` - Não usa Key Vault (OK)

#### 3. Documentação
- `azure/README.md` - Verificar se menciona Key Vault
- `azure/DEPLOYMENT.md` - Verificar se menciona Key Vault
- Criar runbook para adicionar novos secrets

## Ocorrências de @Microsoft.KeyVault

### Em YAMLs Temporários (16 ocorrências)
- `app_bootstrap_*.yaml` - 2 secrets por arquivo (mysql-password, openai-api-key)
- **Ação**: Serão regenerados automaticamente após correção do `bootstrap_api.ps1`

### Em Documentação (OK - são exemplos)
- `docs/*.md` - Apenas documentação/exemplos (não precisa corrigir)

### Em Scripts (Verificar)
- `infra/old/*.ps1` - Scripts antigos (não precisam correção, estão em old/)
- `cursor_pipeline_file_movement_and_code.md` - Histórico (não precisa corrigir)

## Checklist de Migração

- [x] `bootstrap_api.ps1` - Corrigido
- [ ] `azure/bicep/main.bicep` - Adicionar identity SystemAssigned
- [ ] Validar que YAMLs gerados não têm @Microsoft.KeyVault
- [ ] Criar script de validação para CI/CD
- [ ] Atualizar documentação
- [ ] Criar runbook
