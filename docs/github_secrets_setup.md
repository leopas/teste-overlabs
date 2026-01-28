# Como Configurar Secrets no GitHub

Guia passo a passo para configurar os secrets necessários para o deploy na Azure.

## Localização

1. **Acesse seu repositório no GitHub**
   - Exemplo: `https://github.com/leopas/teste-overlabs`

2. **Vá para Settings**
   - Clique em **Settings** no topo da página do repositório
   - Ou acesse diretamente: `https://github.com/leopas/teste-overlabs/settings`

3. **Navegue até Secrets**
   - No menu lateral esquerdo, clique em **Secrets and variables**
   - Depois clique em **Actions**

4. **URL direta:**
   ```
   https://github.com/<leopas-ou-org>/teste-overlabs/settings/secrets/actions
   ```

## Secrets Necessários

Você precisa adicionar **3 secrets**:

### 1. AZURE_CLIENT_ID

**O que é:** ID do App Registration criado no Azure AD (Passo 2 do OIDC setup)

**Como obter:**
```bash
# Se você salvou o APP_ID do Passo 2, use aquele valor
# Caso contrário, liste os App Registrations:
az ad app list --display-name "github-actions-rag-overlabs" --query "[0].appId" -o tsv
```

**Exemplo de valor:**
```
12345678-1234-1234-1234-123456789012
```

### 2. AZURE_TENANT_ID

**O que é:** ID do Tenant (diretório) do Azure AD

**Como obter:**
```bash
az account show --query tenantId -o tsv
```

**Exemplo de valor:**
```
87654321-4321-4321-4321-210987654321
```

### 3. AZURE_SUBSCRIPTION_ID

**O que é:** ID da subscription Azure onde os recursos serão criados

**Como obter:**
```bash
az account show --query id -o tsv
```

**Exemplo de valor:**
```
11111111-2222-3333-4444-555555555555
```

## Como Adicionar

1. Na página de Secrets, clique em **"New repository secret"**

2. Preencha:
   - **Name:** `AZURE_CLIENT_ID` (exatamente assim, maiúsculas)
   - **Secret:** Cole o valor obtido acima

3. Clique em **"Add secret"**

4. Repita para os outros 2 secrets:
   - `AZURE_TENANT_ID`
   - `AZURE_SUBSCRIPTION_ID`

## Verificação

Após adicionar, você deve ver na lista:

```
Repository secrets (3)
  AZURE_CLIENT_ID        [Update] [Remove]
  AZURE_TENANT_ID        [Update] [Remove]
  AZURE_SUBSCRIPTION_ID  [Update] [Remove]
```

**Nota:** Os valores nunca são exibidos, apenas `***` para segurança.

## Importante

- ✅ **Use OIDC** (federated credentials) - não precisa de `AZURE_CLIENT_SECRET`
- ❌ **NÃO adicione** `AZURE_CLIENT_SECRET` - OIDC não usa isso
- ✅ Os secrets são **específicos do repositório** (não são compartilhados entre repos)
- ✅ Você pode **atualizar** os valores a qualquer momento clicando em `[Update]`

## Troubleshooting

### "Secret not found" no workflow

- Verifique se os nomes estão **exatamente** como acima (case-sensitive)
- Verifique se você está no repositório correto
- Verifique se os secrets foram adicionados em **Actions** (não em Dependabot ou Codespaces)

### Workflow falha com "unauthorized"

- Verifique se os valores estão corretos (copie e cole novamente)
- Verifique se o App Registration existe e tem as permissões corretas
- Verifique se as federated credentials estão configuradas corretamente

## Próximo Passo

Após configurar os secrets, você pode:
1. Fazer commit e push para `main`
2. A pipeline executará automaticamente
3. Verificar em **Actions** → **Deploy to Azure Container Apps**
