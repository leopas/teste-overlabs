# Runbook de Incidentes

Guia de troubleshooting e resolução de problemas comuns em produção.

## Checklist Rápido

1. ✅ Verificar status dos Container Apps
2. ✅ Verificar logs recentes
3. ✅ Verificar revisões ativas
4. ✅ Verificar tráfego entre revisões
5. ✅ Verificar dependências (Qdrant, Redis)
6. ✅ Verificar variáveis de ambiente
7. ✅ Verificar Key Vault references

---

## Problemas Comuns

### 1. API retorna 503 (Service Unavailable)

**Sintomas**:
- `/readyz` retorna 503
- API não responde

**Diagnóstico**:
```bash
# Verificar status do Container App
az containerapp show \
  --name app-overlabs-prod-XXX \
  --resource-group rg-overlabs-prod \
  --query "properties.runningStatus"

# Verificar logs recentes
az containerapp logs show \
  --name app-overlabs-prod-XXX \
  --resource-group rg-overlabs-prod \
  --tail 50
```

**Possíveis causas**:
- Qdrant indisponível
- Redis indisponível
- Container App não está rodando

**Solução**:
1. Verificar se Qdrant e Redis estão rodando:
   ```bash
   az containerapp show --name app-overlabs-qdrant-prod-XXX --resource-group rg-overlabs-prod
   az containerapp show --name app-overlabs-redis-prod-XXX --resource-group rg-overlabs-prod
   ```
2. Reiniciar Container Apps se necessário:
   ```bash
   az containerapp revision restart \
     --name app-overlabs-prod-XXX \
     --resource-group rg-overlabs-prod \
     --revision <revision-name>
   ```

---

### 2. Key Vault References quebrando

**Sintomas**:
- Erros de autenticação
- Secrets não são resolvidos
- Erro "Forbidden" ao acessar Key Vault

**Diagnóstico**:
```bash
# Verificar Managed Identity
az containerapp show \
  --name app-overlabs-prod-XXX \
  --resource-group rg-overlabs-prod \
  --query "identity"

# Verificar permissões no Key Vault
az keyvault show \
  --name kv-overlabs-prod-XXX \
  --resource-group rg-overlabs-prod \
  --query "properties.accessPolicies"
```

**Solução**:
1. Habilitar Managed Identity (se não estiver habilitada):
   ```bash
   az containerapp identity assign \
     --name app-overlabs-prod-XXX \
     --resource-group rg-overlabs-prod \
     --system-assigned
   ```

2. Obter Principal ID:
   ```bash
   PRINCIPAL_ID=$(az containerapp show \
     --name app-overlabs-prod-XXX \
     --resource-group rg-overlabs-prod \
     --query "identity.principalId" -o tsv)
   ```

3. Conceder permissão no Key Vault:
   ```bash
   az keyvault set-policy \
     --name kv-overlabs-prod-XXX \
     --object-id $PRINCIPAL_ID \
     --secret-permissions get list
   ```

---

### 3. Managed Identity sem permissão

**Sintomas**:
- Erro "Forbidden" ao acessar Key Vault
- Secrets não são resolvidos

**Diagnóstico**:
```bash
# Verificar se Managed Identity está habilitada
az containerapp show \
  --name app-overlabs-prod-XXX \
  --resource-group rg-overlabs-prod \
  --query "identity"
```

**Solução**:
Siga os passos da seção "Key Vault References quebrando" acima.

---

### 4. Qdrant sem volume persistente

**Sintomas**:
- Dados do Qdrant são perdidos após restart
- Erro ao montar volume

**Diagnóstico**:
```bash
# Verificar se volume está montado
az containerapp show \
  --name app-overlabs-qdrant-prod-XXX \
  --resource-group rg-overlabs-prod \
  --query "properties.template.volumes"
```

**Solução**:
1. Verificar se Azure Files está configurado no Environment:
   ```bash
   az containerapp env storage list \
     --name env-overlabs-prod-XXX \
     --resource-group rg-overlabs-prod
   ```

2. Se não estiver, configurar:
   ```bash
   # Obter storage key
   STORAGE_KEY=$(az storage account keys list \
     --name saoverlabsprodXXX \
     --resource-group rg-overlabs-prod \
     --query "[0].value" -o tsv)

   # Configurar storage no Environment
   az containerapp env storage set \
     --name env-overlabs-prod-XXX \
     --resource-group rg-overlabs-prod \
     --storage-name qdrant-storage \
     --azure-file-account-name saoverlabsprodXXX \
     --azure-file-account-key $STORAGE_KEY \
     --azure-file-share-name qdrant-storage \
     --access-mode ReadWrite
   ```

3. Atualizar Container App para usar o volume (via YAML ou portal).

---

### 5. ACR auth falhando

**Sintomas**:
- Erro ao fazer pull de imagens
- "unauthorized" ou "authentication required"

**Diagnóstico**:
```bash
# Verificar se Managed Identity tem permissão no ACR
az acr show \
  --name acrchoperia \
  --resource-group rg-overlabs-prod \
  --query "properties.loginServer"
```

**Solução**:
1. Obter Principal ID do Container App:
   ```bash
   PRINCIPAL_ID=$(az containerapp show \
     --name app-overlabs-prod-XXX \
     --resource-group rg-overlabs-prod \
     --query "identity.principalId" -o tsv)
   ```

2. Conceder permissão AcrPull:
   ```bash
   az role assignment create \
     --assignee $PRINCIPAL_ID \
     --role AcrPull \
     --scope /subscriptions/<sub-id>/resourceGroups/rg-overlabs-prod/providers/Microsoft.ContainerRegistry/registries/acrchoperia
   ```

---

### 6. Revision stuck em "Provisioning"

**Sintomas**:
- Nova revision não fica pronta
- Estado fica em "Provisioning" por muito tempo

**Diagnóstico**:
```bash
# Verificar estado da revision
az containerapp revision show \
  --name app-overlabs-prod-XXX \
  --resource-group rg-overlabs-prod \
  --revision <revision-name> \
  --query "properties.provisioningState"

# Verificar eventos
az containerapp revision list \
  --name app-overlabs-prod-XXX \
  --resource-group rg-overlabs-prod \
  --query "[?name=='<revision-name>'].properties"
```

**Solução**:
1. Verificar logs da revision:
   ```bash
   az containerapp logs show \
     --name app-overlabs-prod-XXX \
     --resource-group rg-overlabs-prod \
     --revision <revision-name> \
     --tail 100
   ```

2. Se necessário, fazer rollback:
   ```bash
   ./infra/ci/rollback_revision.sh \
     "app-overlabs-prod-XXX" \
     "rg-overlabs-prod" \
     "<prev-revision>" \
     "<failed-revision>"
   ```

3. Verificar se há problemas com a imagem (ACR, tamanho, etc.)

---

### 7. Smoke test falhando no CI/CD

**Sintomas**:
- Pipeline falha no smoke test
- Rollback automático é acionado

**Diagnóstico**:
1. Verificar logs do GitHub Actions
2. Verificar logs do Container App:
   ```bash
   az containerapp logs show \
     --name app-overlabs-prod-XXX \
     --resource-group rg-overlabs-prod \
     --tail 100
   ```

**Solução**:
1. Verificar se a nova revision está recebendo tráfego:
   ```bash
   az containerapp ingress traffic show \
     --name app-overlabs-prod-XXX \
     --resource-group rg-overlabs-prod
   ```

2. Verificar se `/healthz` e `/readyz` estão respondendo:
   ```bash
   curl https://<fqdn>/healthz
   curl https://<fqdn>/readyz
   ```

3. Se necessário, ajustar `CANARY_WEIGHT` no workflow (reduzir para 5% se muito agressivo)

---

### 8. Variáveis de ambiente incorretas

**Sintomas**:
- API usa configuração errada (ex.: HuggingFace em vez de OpenAI)
- Erros de conexão

**Diagnóstico**:
```bash
# Listar variáveis de ambiente
az containerapp show \
  --name app-overlabs-prod-XXX \
  --resource-group rg-overlabs-prod \
  --query "properties.template.containers[0].env"
```

**Solução**:
1. Atualizar todas as variáveis:
   ```powershell
   .\infra\update_container_app_env.ps1 -EnvFile ".env"
   ```

2. Ou atualizar uma variável específica:
   ```powershell
   .\infra\add_single_env_var.ps1 -VarName "OPENAI_API_KEY" -VarValue "@Microsoft.KeyVault(...)"
   ```

3. Aguardar nova revision ser criada e ficar pronta

---

### 9. Ingestão não funciona

**Sintomas**:
- Documentos não são indexados
- Qdrant vazio

**Diagnóstico**:
```bash
# Verificar se DOCS_ROOT está configurado
az containerapp show \
  --name app-overlabs-prod-XXX \
  --resource-group rg-overlabs-prod \
  --query "properties.template.containers[0].env[?name=='DOCS_ROOT']"
```

**Solução**:
1. Verificar se `DOCS_ROOT` está configurado
2. Executar ingestão manualmente:
   ```powershell
   .\infra\run_ingest.ps1
   ```

3. Verificar logs da ingestão:
   ```bash
   az containerapp logs show \
     --name app-overlabs-prod-XXX \
     --resource-group rg-overlabs-prod \
     --tail 100
   ```

---

## Comandos Úteis

### Ver status geral

```bash
# Listar todos os Container Apps
az containerapp list \
  --resource-group rg-overlabs-prod \
  --query "[].{name:name,status:properties.runningStatus}" \
  -o table

# Ver revisões ativas
az containerapp revision list \
  --name app-overlabs-prod-XXX \
  --resource-group rg-overlabs-prod \
  --query "[?properties.active==\`true\`].{name:name,trafficWeight:properties.trafficWeight}" \
  -o table
```

### Ver logs

```bash
# Logs em tempo real
az containerapp logs show \
  --name app-overlabs-prod-XXX \
  --resource-group rg-overlabs-prod \
  --follow

# Últimas 100 linhas
az containerapp logs show \
  --name app-overlabs-prod-XXX \
  --resource-group rg-overlabs-prod \
  --tail 100
```

### Fazer rollback manual

```bash
# Listar revisões
az containerapp revision list \
  --name app-overlabs-prod-XXX \
  --resource-group rg-overlabs-prod \
  --query "[].{name:name,createdTime:properties.createdTime}" \
  -o table

# Redirecionar 100% do tráfego para revision anterior
az containerapp ingress traffic set \
  --name app-overlabs-prod-XXX \
  --resource-group rg-overlabs-prod \
  --revision-weight "<prev-revision>=100"
```

---

## Escalação

Se o problema não for resolvido:

1. **Documentar**:
   - Sintomas observados
   - Comandos executados e resultados
   - Logs relevantes
   - Timestamp do incidente

2. **Contatar**:
   - Time de DevOps/Platform
   - Suporte Azure (se necessário)

3. **Post-mortem**:
   - Analisar causa raiz
   - Atualizar este runbook com nova solução
   - Melhorar monitoramento/alertas se necessário

---

## Referências

- [Runbook Operacional](runbook.md) - Operações do dia a dia
- [Deploy na Azure](deployment_azure.md) - Configuração e deploy
- [CI/CD](ci_cd.md) - Pipeline e canary deployment
