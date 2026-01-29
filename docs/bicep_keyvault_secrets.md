# Configuração de Secrets do Key Vault no Bicep

## Mudança Implementada

O template Bicep foi atualizado para usar **secrets do Key Vault** ao invés de passar valores diretamente nas variáveis de ambiente.

## Antes (❌ NÃO SEGURO)

```bicep
env: [
  {
    name: 'MYSQL_PASSWORD'
    value: mysqlAdminPassword  // ❌ Senha exposta no template
  }
  {
    name: 'OPENAI_API_KEY'
    value: 'sk-...'  // ❌ Chave API exposta
  }
]
```

## Depois (✅ SEGURO)

### 1. Secrets definidos na configuração do Container App

```bicep
configuration: {
  secrets: [
    {
      name: 'mysql-password'
      keyVaultUrl: '${keyVault.properties.vaultUri}secrets/mysql-password'
    }
    {
      name: 'openai-api-key'
      keyVaultUrl: '${keyVault.properties.vaultUri}secrets/openai-api-key'
    }
    {
      name: 'audit-enc-key-b64'
      keyVaultUrl: '${keyVault.properties.vaultUri}secrets/audit-enc-key-b64'
    }
  ]
}
```

### 2. Env vars usando `secretRef` ao invés de `value`

```bicep
env: [
  // Variáveis não-secretas (valores diretos)
  {
    name: 'MYSQL_HOST'
    value: mysqlServer.properties.fullyQualifiedDomainName
  }
  // Secrets do Key Vault (usando secretRef)
  {
    name: 'MYSQL_PASSWORD'
    secretRef: 'mysql-password'  // ✅ Referencia o secret definido acima
  }
  {
    name: 'OPENAI_API_KEY'
    secretRef: 'openai-api-key'  // ✅ Referencia o secret definido acima
  }
]
```

## Como Usar

### 1. Criar o Key Vault (se ainda não existe)

```bash
az keyvault create \
  --name <key-vault-name> \
  --resource-group <resource-group> \
  --location brazilsouth \
  --enable-rbac-authorization true
```

### 2. Criar secrets no Key Vault

```bash
az keyvault secret set \
  --vault-name <key-vault-name> \
  --name mysql-password \
  --value "<senha-do-mysql>"

az keyvault secret set \
  --vault-name <key-vault-name> \
  --name openai-api-key \
  --value "sk-..."

az keyvault secret set \
  --vault-name <key-vault-name> \
  --name audit-enc-key-b64 \
  --value "<chave-criptografia>"
```

### 3. Atualizar `parameters.json`

```json
{
  "parameters": {
    "keyVaultName": {
      "value": "kv-overlabs-prod-300"
    }
  }
}
```

### 4. Deploy com Bicep

```bash
az deployment group create \
  --resource-group <resource-group> \
  --template-file azure/bicep/main.bicep \
  --parameters @azure/bicep/parameters.json
```

## Pré-requisitos

1. ✅ **Key Vault já existe** e foi criado previamente
2. ✅ **Secrets já existem** no Key Vault com os nomes:
   - `mysql-password`
   - `openai-api-key`
   - `audit-enc-key-b64`
3. ✅ **Container App tem Managed Identity** habilitada
4. ✅ **Managed Identity tem permissão** no Key Vault:
   - RBAC: Role `Key Vault Secrets User`
   - Access Policy: Permission `Get` em secrets

## Fallback

Se `keyVaultName` não for fornecido (string vazia), o template usa valores diretos como fallback (não recomendado para produção).

## Benefícios

1. ✅ **Segurança**: Secrets não aparecem no template ou logs
2. ✅ **Rotação**: Pode rotacionar secrets no Key Vault sem alterar o template
3. ✅ **Auditoria**: Todas as leituras de secrets são auditadas no Key Vault
4. ✅ **Centralização**: Todos os secrets em um único lugar (Key Vault)

## Referências

- [Azure Container Apps - Secrets](https://learn.microsoft.com/en-us/azure/container-apps/manage-secrets)
- [Bicep - Key Vault References](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/key-vault-parameter)
