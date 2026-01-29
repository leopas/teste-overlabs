# PR: Migração Key Vault para padrão Azure Container Apps

## Objetivo

Migrar todas as referências de Key Vault do formato App Service (`@Microsoft.KeyVault(SecretUri=...)`) para o padrão correto do Azure Container Apps: secrets em `properties.configuration.secrets` com `keyVaultUrl` + `identity`, e env vars referenciando `secretRef` (nunca `value` com `@Microsoft.KeyVault(...)`).

## Arquivos afetados

| Tipo | Arquivos |
|------|----------|
| **.gitignore** | Padrões `app_bootstrap_*.yaml`, `app_recreate_*.yaml` adicionados |
| **YAML** | `azure/container-app-api-template.yaml` (novo, template ACA) |
| **Validador** | `infra/validate_keyvault_syntax.ps1` (removida exclusão de artefatos; falha em `value:` com @Microsoft.KeyVault) |
| **Scripts** | `azure/setup-keyvault.ps1`, `azure/setup-keyvault.sh` (exemplos em ACA); `infra/bootstrap_api.ps1` (YAML temporário em `.azure/`) |
| **Docs** | `docs/deployment_azure.md`, `azure/QUICKSTART.md`, `docs/runbook_add_keyvault_secret.md` (rotação + duas fases + nota infra/old) |

**Bicep:** `azure/bicep/main.bicep` já estava correto (keyVaultUrl + identity + secretRef). Nenhuma alteração.

## Antes / Depois (exemplo: OPENAI_API_KEY)

**Antes (App Service – não funciona em ACA):**
```yaml
env:
  - name: OPENAI_API_KEY
    value: "@Microsoft.KeyVault(SecretUri=https://kv-xxx.vault.azure.net/secrets/openai-api-key/)"
```
Resultado no container: string literal `"@Microsoft.KeyVault(...)"` (não resolvida).

**Depois (ACA):**
```yaml
configuration:
  secrets:
    - name: openai-api-key
      keyVaultUrl: https://kv-xxx.vault.azure.net/secrets/openai-api-key
      identity: system
template:
  containers:
    - env:
        - name: OPENAI_API_KEY
          secretRef: openai-api-key
```
Resultado no container: valor real do secret.

## Como testar

1. **Validação local:**
   ```powershell
   .\infra\validate_keyvault_syntax.ps1
   ```
   Deve passar (zero `@Microsoft.KeyVault` em YAMLs/scripts ativos).

2. **Pipeline:** O job `validate` em `.github/workflows/deploy-azure.yml` já executa o script acima.

3. **Deploy:** Após merge, o bootstrap (`infra/bootstrap_api.ps1`) continua em duas fases: create com identity → conceder RBAC no KV → update com secrets keyvaultref e env secretRef.

## Runbook

- **Como adicionar novo secret do Key Vault ao Container App:** `docs/runbook_add_keyvault_secret.md` (inclui rotação e duas fases).
