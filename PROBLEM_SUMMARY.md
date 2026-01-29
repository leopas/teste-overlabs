# Problema: Volume Mount não está sendo aplicado no Azure Container Apps

## Contexto

Estamos tentando montar um volume do Azure Files no Container App da API para que os documentos em `/app/DOC-IA` sejam acessíveis dentro do container. O volume foi criado no Environment e os arquivos foram enviados para o Azure File Share, mas o volume mount não está sendo aplicado no Container App.

## Arquitetura

- **Plataforma**: Azure Container Apps
- **Resource Group**: `rg-overlabs-prod`
- **Environment**: `env-overlabs-prod-300`
- **Container App**: `app-overlabs-prod-300`
- **Storage Account**: `saoverlabsprod300`
- **File Share**: `documents` (no Storage Account)
- **Volume no Environment**: `documents-storage` (configurado corretamente)
- **Volume no Container App**: `docs` (adicionado manualmente pelo portal)
- **Mount Path desejado**: `/app/DOC-IA`

## O que queremos fazer

1. Montar o volume `documents-storage` (ou `docs`) no Container App
2. Fazer o mount no caminho `/app/DOC-IA`
3. Tornar os documentos acessíveis dentro do container para ingestão no Qdrant

## Estado Atual

### O que está funcionando:
- ✅ Volume `documents-storage` existe no Container Apps Environment
- ✅ Volume `docs` existe no Container App (adicionado manualmente pelo portal)
- ✅ Arquivos foram enviados com sucesso para o Azure File Share `documents` (14 arquivos .txt)
- ✅ Storage Account e File Share estão configurados corretamente
- ✅ Permissões do Managed Identity estão corretas (`Storage File Data SMB Share Contributor`)

### O que NÃO está funcionando:
- ❌ Volume mount não está sendo aplicado no Container App
- ❌ Diretório `/app/DOC-IA` não está acessível no container
- ❌ Comandos `az containerapp update --yaml` não estão aplicando as mudanças

## Tentativas de Solução

### 1. Script `mount_docs_volume.ps1`
- **Abordagem**: Usar YAML para atualizar o Container App com volume e volume mount
- **Resultado**: Comando `az containerapp update --yaml` retorna sucesso, mas o volume mount não aparece na configuração
- **Verificação**: `az containerapp show --query "properties.template.containers[0].volumeMounts"` retorna `null`

### 2. Script `add_volume_direct.ps1`
- **Abordagem**: Tentar JSON primeiro, depois YAML como fallback
- **Resultado**: Mesmo problema - comando retorna sucesso mas mudanças não são aplicadas

### 3. Script `add_volume_mount.ps1`
- **Abordagem**: Adicionar apenas o volume mount quando o volume já existe
- **Resultado**: Comando retorna sucesso, mas volume mount não aparece na verificação

### 4. Adição Manual pelo Portal Azure
- **Abordagem**: Adicionar volume e volume mount manualmente pelo portal
- **Resultado**: Volume `docs` foi adicionado com sucesso, mas volume mount ainda não aparece
- **Observação**: No portal, a seção "Associated volume mounts" mostra "None found."

### 5. Script `fix_volume_complete.ps1`
- **Abordagem**: Script completo que faz tudo (criar volume, adicionar mount, upload, reiniciar)
- **Resultado**: Volume criado, arquivos enviados, mas volume mount não aplicado

## Comandos Azure CLI Testados

### Comando que retorna sucesso mas não aplica:
```powershell
az containerapp update `
    --name app-overlabs-prod-300 `
    --resource-group rg-overlabs-prod `
    --yaml <arquivo.yaml>
```

### YAML usado (exemplo):
```yaml
properties:
  environmentId: /subscriptions/.../resourceGroups/.../providers/Microsoft.App/managedEnvironments/env-overlabs-prod-300
  template:
    containers:
    - name: api
      image: acrchoperia.azurecr.io/choperia-api:latest
      env:
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

### Verificação após update:
```powershell
# Retorna null ou array vazio
az containerapp show --name app-overlabs-prod-300 --resource-group rg-overlabs-prod --query "properties.template.containers[0].volumeMounts" -o json

# Retorna o volume (mas sem mount)
az containerapp show --name app-overlabs-prod-300 --resource-group rg-overlabs-prod --query "properties.template.volumes" -o json
# Resultado: [{"name": "docs", "storageType": "AzureFile", "storageName": "documents-storage"}]
```

## Erros e Comportamentos Estranhos

1. **Comando retorna sucesso mas não aplica**: `az containerapp update --yaml` retorna exit code 0, mas as mudanças não aparecem na configuração
2. **Sem mensagens de erro**: Não há erros explícitos, apenas silêncio
3. **Volume existe mas mount não**: O volume `docs` aparece na configuração, mas `volumeMounts` está vazio
4. **Portal mostra "None found"**: Na seção "Associated volume mounts" do volume, aparece "None found."

## Informações Adicionais

### Versão do Azure CLI:
```powershell
az --version
# azure-cli 2.x (versão recente)
```

### Container App Status:
- Container App está rodando normalmente
- Revisions estão sendo criadas quando fazemos updates
- Aplicação funciona, apenas o volume mount não está sendo aplicado

### Permissões:
- Managed Identity está habilitada no Container App
- Permissão `Storage File Data SMB Share Contributor` foi concedida
- Key Vault references funcionam corretamente

## Perguntas Específicas

1. **Por que `az containerapp update --yaml` retorna sucesso mas não aplica o volume mount?**
2. **Existe alguma limitação ou requisito especial para volume mounts em Container Apps?**
3. **O nome do volume precisa ser exatamente igual ao `storageName` no Environment?**
4. **Há alguma diferença entre criar o Container App com volume mount vs. adicionar depois?**
5. **Existe alguma forma alternativa de adicionar volume mount que funcione?**
6. **O problema pode estar relacionado à versão do Azure CLI ou API do Container Apps?**

## Descoberta Importante

**O volume mount do Qdrant funcionou perfeitamente!**

A diferença chave:
- **Qdrant**: Foi criado com `az containerapp create --yaml` (criação inicial) ✅
- **API**: Estamos tentando atualizar com `az containerapp update --yaml` (atualização) ❌

**Hipótese**: O comando `az containerapp update --yaml` pode não aplicar volume mounts da mesma forma que `az containerapp create --yaml`.

**Solução proposta**: Recriar o Container App da API usando `az containerapp create --yaml` com o mesmo formato YAML que funcionou para o Qdrant.

## Análise de Especialista (Outra LLM)

**Problemas identificados:**

1. **YAML "parcial" + `az containerapp update --yaml`**: O comando não valida direito e pode virar um no-op silencioso para alguns campos (vários relatos do update "aceitar" YAML inválido/incompleto sem falhar).

2. **Container alvo errado**: Nome/índice do container no template não é o que está sendo editado. Você "aplica" mount em um container que não existe naquele template, e o ACA fica exatamente como está.

**Soluções recomendadas:**

1. ✅ **EXPORTAR YAML completo** → Editar → Reaplicar (método mais confiável)
   - Script criado: `add_volume_mount_export_yaml.ps1`
   - Comando: `az containerapp show ... -o yaml > app.yaml` → editar → `az containerapp update --yaml app.yaml --debug`

2. ✅ **Usar `--set` para patch direto** (alternativa robusta)
   - Script criado: `add_volume_mount_set.ps1`
   - Comando: `az containerapp update --set properties.template.containers[0].volumeMounts='[...]'`

3. ✅ **RECRIAR o Container App** usando `az containerapp create --yaml` (igual ao Qdrant)
   - Script criado: `recreate_api_with_volume.ps1`

## Tentativas Adicionais que Podem Ser Testadas

1. ✅ **EXPORTAR YAML completo e editar** - Script criado: `add_volume_mount_export_yaml.ps1`
2. ✅ **Usar `--set` para patch direto** - Script criado: `add_volume_mount_set.ps1`
3. ✅ **RECRIAR o Container App** - Script criado: `recreate_api_with_volume.ps1`
4. Verificar se há alguma limitação de região ou SKU do Container Apps
5. Tentar usar Azure CLI extension específica para Container Apps
6. Verificar logs de auditoria do Azure para ver se há erros ocultos

## Arquivos Relevantes no Repositório

- `infra/bootstrap_container_apps.ps1` - Script de bootstrap (tenta criar com volume mount)
- `infra/mount_docs_volume.ps1` - Script para montar volume
- `infra/add_volume_direct.ps1` - Script alternativo usando JSON/YAML
- `infra/add_volume_mount.ps1` - Script para adicionar apenas volume mount
- `infra/fix_volume_complete.ps1` - Script completo de correção
- `infra/verify_volume_working.ps1` - Script de verificação

## Comando para Reproduzir o Problema

```powershell
# 1. Verificar volume no Environment (funciona)
az containerapp env storage show --name env-overlabs-prod-300 --resource-group rg-overlabs-prod --storage-name documents-storage

# 2. Verificar volume no Container App (existe)
az containerapp show --name app-overlabs-prod-300 --resource-group rg-overlabs-prod --query "properties.template.volumes" -o json

# 3. Verificar volume mount (NÃO existe - retorna null)
az containerapp show --name app-overlabs-prod-300 --resource-group rg-overlabs-prod --query "properties.template.containers[0].volumeMounts" -o json

# 4. Tentar adicionar volume mount via YAML (retorna sucesso mas não aplica)
# (usar qualquer um dos scripts mencionados acima)
```

## Resultado Esperado vs. Real

**Esperado:**
```json
{
  "properties": {
    "template": {
      "containers": [{
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

**Real:**
```json
{
  "properties": {
    "template": {
      "containers": [{
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

---

**Precisamos descobrir por que o `az containerapp update --yaml` não está aplicando o `volumeMounts` mesmo retornando sucesso.**
