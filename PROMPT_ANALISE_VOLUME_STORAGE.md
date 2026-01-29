# Prompt para Análise: Problema de Volume Mount no Azure Container Apps

## Contexto do Problema

Estamos enfrentando um problema persistente ao tentar montar um volume do Azure Files em um Azure Container App. O volume foi criado corretamente no Environment, os arquivos foram enviados para o Azure File Share, mas o **volume mount não está sendo aplicado no Container App**, mesmo quando o comando `az containerapp update --yaml` retorna sucesso.

## Arquitetura e Configuração

- **Plataforma**: Azure Container Apps
- **Resource Group**: `rg-overlabs-prod`
- **Environment**: `env-overlabs-prod-248`
- **Container App (API)**: `app-overlabs-prod-248`
- **Container App (Qdrant)**: `app-overlabs-qdrant-prod-248` ✅ **FUNCIONA**
- **Storage Account**: `saoverlabsprod248`
- **File Share**: `documents` (no Storage Account)
- **Volume no Environment**: `documents-storage` (configurado corretamente)
- **Volume no Container App**: `docs` (adicionado manualmente pelo portal)
- **Mount Path desejado**: `/app/DOC-IA`

## O que Funciona vs. O que Não Funciona

### ✅ Qdrant Container App (FUNCIONA PERFEITAMENTE)

O Container App do Qdrant foi criado com volume mount desde o início usando:

```powershell
az containerapp create --name app-overlabs-qdrant-prod-248 --resource-group rg-overlabs-prod --yaml qdrant.yaml
```

**YAML do Qdrant (que funcionou):**
```yaml
properties:
  environmentId: /subscriptions/.../providers/Microsoft.App/managedEnvironments/env-overlabs-prod-248
  configuration:
    ingress:
      external: false
      targetPort: 6333
      transport: http
  template:
    containers:
    - name: qdrant
      image: qdrant/qdrant:v1.7.4
      env:
      - name: QDRANT__SERVICE__GRPC_PORT
        value: "6334"
      resources:
        cpu: 1.0
        memory: 2.0Gi
      volumeMounts:
      - volumeName: qdrant-storage
        mountPath: /qdrant/storage
    scale:
      minReplicas: 1
      maxReplicas: 1
    volumes:
    - name: qdrant-storage
      storageType: AzureFile
      storageName: qdrant-storage
```

**Resultado**: Volume mount funciona perfeitamente, `/qdrant/storage` está acessível.

### ❌ API Container App (NÃO FUNCIONA)

O Container App da API foi criado inicialmente **sem** volume mount. Tentamos adicionar depois usando:

```powershell
az containerapp update --name app-overlabs-prod-248 --resource-group rg-overlabs-prod --yaml api.yaml
```

**YAML da API (que NÃO funciona):**
```yaml
properties:
  environmentId: /subscriptions/.../providers/Microsoft.App/managedEnvironments/env-overlabs-prod-248
  configuration:
    ingress:
      external: true
      targetPort: 8000
      transport: http
    registries:
    - server: acrchoperia.azurecr.io
      username: acrchoperia
      passwordSecretRef: acr-password
    secrets:
    - name: acr-password
      value: <password>
  template:
    containers:
    - name: api
      image: acrchoperia.azurecr.io/choperia-api:latest
      env:
      - name: QDRANT_URL
        value: "http://app-overlabs-qdrant-prod-248:6333"
      - name: REDIS_URL
        value: "redis://app-overlabs-redis-prod-248:6379/0"
      - name: DOCS_ROOT
        value: "/app/DOC-IA"
      # ... outras env vars ...
      resources:
        cpu: 2.0
        memory: 4.0Gi
      volumeMounts:
      - volumeName: docs
        mountPath: /app/DOC-IA
    scale:
      minReplicas: 1
      maxReplicas: 5
    volumes:
    - name: docs
      storageType: AzureFile
      storageName: documents-storage
```

**Resultado**: 
- Comando retorna `exit code 0` (sucesso)
- Nova revision é criada
- Volume `docs` aparece na configuração
- **MAS**: `volumeMounts` continua `null` ou vazio
- Diretório `/app/DOC-IA` não existe no container

## Verificações Realizadas

### 1. Volume no Environment (✅ OK)
```powershell
az containerapp env storage show `
    --name env-overlabs-prod-248 `
    --resource-group rg-overlabs-prod `
    --storage-name documents-storage
```
**Resultado**: Volume existe e está configurado corretamente.

### 2. Volume no Container App (✅ OK)
```powershell
az containerapp show `
    --name app-overlabs-prod-248 `
    --resource-group rg-overlabs-prod `
    --query "properties.template.volumes" -o json
```
**Resultado**: 
```json
[
  {
    "name": "docs",
    "storageType": "AzureFile",
    "storageName": "documents-storage"
  }
]
```

### 3. Volume Mount no Container App (❌ FALHA)
```powershell
az containerapp show `
    --name app-overlabs-prod-248 `
    --resource-group rg-overlabs-prod `
    --query "properties.template.containers[0].volumeMounts" -o json
```
**Resultado**: `null` ou `[]`

### 4. Teste de Acesso no Container (❌ FALHA)
```powershell
az containerapp exec `
    --name app-overlabs-prod-248 `
    --resource-group rg-overlabs-prod `
    --command "test -d /app/DOC-IA && echo 'EXISTS' || echo 'NOT_FOUND'"
```
**Resultado**: `NOT_FOUND`

## Tentativas de Solução Realizadas

### 1. Script `mount_docs_volume.ps1`
- **Abordagem**: Gerar YAML completo e usar `az containerapp update --yaml`
- **Resultado**: Comando retorna sucesso, mas volume mount não é aplicado
- **Código relevante**: Ver `infra/mount_docs_volume.ps1` no repositório

### 2. Script `add_volume_direct.ps1`
- **Abordagem**: Tentar JSON primeiro, depois YAML como fallback
- **Resultado**: Mesmo problema - sucesso silencioso sem aplicação

### 3. Script `add_volume_mount.ps1`
- **Abordagem**: Adicionar apenas volume mount quando volume já existe
- **Resultado**: Comando retorna sucesso, mas volume mount não aparece

### 4. Adição Manual pelo Portal Azure
- **Abordagem**: Adicionar volume e volume mount manualmente pelo portal
- **Resultado**: Volume `docs` foi adicionado, mas seção "Associated volume mounts" mostra "None found."

### 5. Script `recreate_api_from_scratch.ps1`
- **Abordagem**: Deletar e recriar o Container App usando `az containerapp create --yaml` (igual ao Qdrant)
- **Status**: Criado mas ainda não testado completamente
- **Hipótese**: Se funcionar, confirma que `create` funciona mas `update` não

### 6. Exportar YAML completo e reaplicar
- **Abordagem**: `az containerapp show -o yaml > app.yaml` → editar → `az containerapp update --yaml app.yaml`
- **Status**: Não testado ainda

### 7. Usar `--set` para patch direto
- **Abordagem**: `az containerapp update --set properties.template.containers[0].volumeMounts='[...]'`
- **Status**: Não testado ainda

## Análise de Especialista (Outra LLM - Anterior)

Uma análise anterior identificou dois problemas possíveis:

1. **YAML "parcial" + `az containerapp update --yaml`**: O comando não valida direito e pode virar um no-op silencioso para alguns campos. Há vários relatos do update "aceitar" YAML inválido/incompleto sem falhar.

2. **Container alvo errado**: Nome/índice do container no template não é o que está sendo editado. Você "aplica" mount em um container que não existe naquele template, e o ACA fica exatamente como está.

**Recomendações da análise anterior:**
- ✅ Exportar YAML completo e editar (método mais confiável)
- ✅ Usar `--set` para patch direto (alternativa robusta)
- ✅ RECRIAR o Container App usando `az containerapp create --yaml` (igual ao Qdrant)

## Diferenças Entre Qdrant (Funciona) e API (Não Funciona)

| Aspecto | Qdrant ✅ | API ❌ |
|---------|-----------|--------|
| Método de criação | `az containerapp create --yaml` | `az containerapp create` (sem YAML inicial) |
| Volume mount inicial | Sim, desde a criação | Não, adicionado depois |
| Registries/Secrets | Não tem | Tem (ACR) |
| Ingress | Internal | External |
| Container name | `qdrant` | `api` |
| YAML structure | Simples | Mais complexa (com registries/secrets) |

## Perguntas Específicas para Análise

1. **Por que `az containerapp update --yaml` retorna sucesso mas não aplica o volume mount?**
   - Existe alguma validação silenciosa que está falhando?
   - Há alguma limitação conhecida do Azure CLI para volume mounts em updates?

2. **Existe alguma diferença fundamental entre `create` e `update` para volume mounts?**
   - Por que o Qdrant (criado com `create`) funciona mas a API (atualizada com `update`) não?
   - Há alguma restrição de API do Azure Container Apps?

3. **O YAML com `registries` e `secrets` pode estar interferindo?**
   - O Qdrant não tem `registries/secrets`, a API tem
   - Pode haver algum conflito ou ordem de processamento?

4. **O nome do container (`api` vs `qdrant`) pode estar causando problema?**
   - Há alguma validação que verifica se o container name existe antes de aplicar mounts?

5. **Existe alguma limitação de região, SKU ou versão do Container Apps?**
   - Estamos usando `brazilsouth` e Container Apps Environment padrão
   - Há alguma feature flag ou configuração necessária?

6. **O problema pode estar relacionado à versão do Azure CLI?**
   - Versão atual: `azure-cli 2.x` (recente)
   - Há alguma versão específica necessária para volume mounts?

7. **Há alguma forma alternativa de adicionar volume mount que funcione?**
   - REST API direta?
   - Azure PowerShell (não CLI)?
   - Terraform/Bicep?

8. **O fato de o volume ter sido adicionado manualmente pelo portal pode estar causando conflito?**
   - Há alguma diferença entre volume criado via CLI vs portal?

## Informações Adicionais

### Permissões
- ✅ Managed Identity habilitada no Container App
- ✅ Permissão `Storage File Data SMB Share Contributor` concedida no Storage Account
- ✅ Key Vault references funcionam corretamente

### Status do Container App
- ✅ Container App está rodando normalmente
- ✅ Revisions estão sendo criadas quando fazemos updates
- ✅ Aplicação funciona, apenas o volume mount não está sendo aplicado
- ✅ Logs não mostram erros relacionados a volumes

### Arquivos no Repositório

O repositório completo está disponível em `repo_concat_all.md` (gerado automaticamente). Scripts relevantes:

- `infra/bootstrap_container_apps.ps1` - Script de bootstrap (tenta criar API com volume mount)
- `infra/mount_docs_volume.ps1` - Script para montar volume
- `infra/add_volume_direct.ps1` - Script alternativo usando JSON/YAML
- `infra/add_volume_mount.ps1` - Script para adicionar apenas volume mount
- `infra/fix_volume_complete.ps1` - Script completo de correção
- `infra/recreate_api_from_scratch.ps1` - Script para recriar Container App do zero
- `infra/verify_volume_working.ps1` - Script de verificação

### Comandos para Reproduzir

```powershell
# 1. Verificar volume no Environment (funciona)
az containerapp env storage show `
    --name env-overlabs-prod-248 `
    --resource-group rg-overlabs-prod `
    --storage-name documents-storage

# 2. Verificar volume no Container App (existe)
az containerapp show `
    --name app-overlabs-prod-248 `
    --resource-group rg-overlabs-prod `
    --query "properties.template.volumes" -o json

# 3. Verificar volume mount (NÃO existe - retorna null)
az containerapp show `
    --name app-overlabs-prod-248 `
    --resource-group rg-overlabs-prod `
    --query "properties.template.containers[0].volumeMounts" -o json

# 4. Verificar nome do container
az containerapp show `
    --name app-overlabs-prod-248 `
    --resource-group rg-overlabs-prod `
    --query "properties.template.containers[].name" -o json

# 5. Tentar adicionar volume mount via YAML (retorna sucesso mas não aplica)
# Ver scripts mencionados acima
```

## Resultado Esperado vs. Real

### Esperado:
```json
{
  "properties": {
    "template": {
      "containers": [{
        "name": "api",
        "volumeMounts": [{
          "volumeName": "docs",
          "mountPath": "/app/DOC-IA"
        }]
      }],
      "volumes": [{
        "name": "docs",
        "storageType": "AzureFile",
        "storageName": "documents-storage"
      }]
    }
  }
}
```

### Real:
```json
{
  "properties": {
    "template": {
      "containers": [{
        "name": "api",
        "volumeMounts": null  // ou []
      }],
      "volumes": [{
        "name": "docs",
        "storageType": "AzureFile",
        "storageName": "documents-storage"
      }]
    }
  }
}
```

## Objetivo da Análise

Precisamos descobrir:

1. **Por que o `az containerapp update --yaml` não está aplicando o `volumeMounts` mesmo retornando sucesso?**
2. **Qual é a forma correta e confiável de adicionar volume mount em um Container App existente?**
3. **Há alguma limitação, bug ou requisito especial que não estamos considerando?**
4. **Qual é a melhor solução: recriar o Container App ou existe uma forma de atualizar que funcione?**

## Informações do Repositório

O snapshot completo do código está disponível em `repo_concat_all.md`, incluindo:
- Todos os scripts PowerShell (`.ps1`)
- Configurações YAML
- Documentação
- Código Python do backend

**Por favor, analise o problema e forneça:**
1. Diagnóstico detalhado do que pode estar errado
2. Solução recomendada com passos específicos
3. Explicação técnica do porquê `update` não funciona mas `create` funciona
4. Alternativas viáveis se a solução principal não for possível
