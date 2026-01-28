# Prompt para Análise de Deployment - teste-overlabs

## Contexto

Você está analisando um arquivo Markdown completo (`repo_concat_all.md`) que contém um snapshot de todo o repositório de código do projeto **teste-overlabs**. Este é um sistema RAG (Retrieval Augmented Generation) que foi migrado recentemente de **Azure App Service** para **Azure Container Apps**.

## Objetivo Principal

Analise o arquivo `repo_concat_all.md` e forneça uma análise detalhada e estruturada dos **scripts de deployment e infraestrutura**, com foco especial em:

1. **Scripts PowerShell de deployment** (diretório `infra/`)
2. **GitHub Actions workflow** (`.github/workflows/deploy-azure.yml`)
3. **Arquitetura de deployment** (Azure Container Apps)
4. **Configuração de recursos Azure** (ACR, Key Vault, Storage, Container Apps)
5. **Gerenciamento de variáveis de ambiente e secrets**
6. **Processo de CI/CD completo**

## Instruções de Análise

### 1. Identificação de Scripts de Deployment

Localize e liste todos os scripts relacionados a deployment no diretório `infra/`:

- Scripts PowerShell (`.ps1`)
- Scripts Shell (`.sh`)
- Scripts Python (se houver)
- Arquivos de configuração (YAML, JSON, etc.)

Para cada script, identifique:
- **Nome do arquivo**
- **Propósito principal**
- **Parâmetros aceitos**
- **Dependências** (outros scripts, recursos Azure, etc.)
- **Idempotência** (pode ser executado múltiplas vezes sem efeitos colaterais?)

### 2. Análise do Workflow GitHub Actions

Analise o arquivo `.github/workflows/deploy-azure.yml` e documente:

- **Jobs e suas responsabilidades**
- **Ordem de execução**
- **Autenticação** (OIDC, Service Principal, etc.)
- **Build e push de imagens Docker**
- **Deployment para Azure Container Apps**
- **Configuração de Managed Identity**
- **Smoke tests**
- **Rollback strategies** (se houver)

### 3. Arquitetura de Deployment

Documente a arquitetura atual de deployment:

- **Target**: Azure Container Apps (não mais App Service)
- **Container Apps criados**:
  - API Container App (externa, acessível via internet)
  - Qdrant Container App (interna, apenas rede interna)
  - Redis Container App (interna, apenas rede interna)
- **Recursos Azure necessários**:
  - Resource Group
  - Azure Container Registry (ACR)
  - Azure Key Vault
  - Azure Storage Account (para volumes persistentes do Qdrant)
  - Container Apps Environment
- **Networking**: Como os containers se comunicam?
- **Volumes persistentes**: Como o Qdrant persiste dados?

### 4. Processo de Bootstrap

Analise o script `infra/bootstrap_container_apps.ps1`:

- **Ordem de criação de recursos**
- **Reutilização de recursos existentes** (idempotência)
- **Geração de sufixos** para nomes de recursos
- **Configuração de Managed Identity**
- **Upload de secrets para Key Vault**
- **Criação de volumes persistentes**
- **Geração do arquivo `deploy_state.json`**

### 5. Gerenciamento de Variáveis de Ambiente

Analise os scripts que gerenciam variáveis de ambiente:

- `infra/update_container_app_env.ps1`
- `infra/configure_audit_mysql.ps1`

Documente:
- **Como secrets são identificados** (vs variáveis normais)
- **Integração com Azure Key Vault** (referências `@Microsoft.KeyVault(...)`)
- **Processo de atualização** (lote, individual, etc.)
- **Problemas conhecidos** (se mencionados no código/comentários)

### 6. Scripts de Operação

Identifique scripts para operações pós-deployment:

- **Ingestão de documentos** (`infra/run_ingest.ps1`)
- **Smoke tests** (`infra/smoke_test.ps1` / `infra/smoke_test.sh`)
- **Limpeza de recursos antigos** (`infra/cleanup_app_service.ps1`)
- **Configuração de OIDC** (`infra/setup_oidc.ps1`)

### 7. Documentação de Deployment

Analise a documentação em `docs/deployment_azure.md`:

- **Pré-requisitos**
- **Passo a passo de deployment**
- **Troubleshooting**
- **Migração de App Service para Container Apps**

### 8. Problemas Conhecidos e Limitações

Identifique no código/comentários:

- **Erros conhecidos** e suas soluções
- **Workarounds** implementados
- **Limitações** da abordagem atual
- **TODOs** ou melhorias pendentes

## Formato de Saída Esperado

Forneça sua análise em formato estruturado:

```markdown
# Análise de Deployment - teste-overlabs

## 1. Scripts de Deployment Identificados

### 1.1 bootstrap_container_apps.ps1
- **Propósito**: [descrição]
- **Parâmetros**: [lista]
- **Idempotente**: [sim/não]
- **Dependências**: [lista]
- **Fluxo de execução**: [passo a passo]

[... para cada script ...]

## 2. Workflow GitHub Actions

### 2.1 Estrutura Geral
[análise do workflow]

### 2.2 Jobs
- **validate**: [descrição]
- **build**: [descrição]
- **deploy**: [descrição]
- **smoke-test**: [descrição]

### 2.3 Autenticação
[como funciona a autenticação OIDC]

## 3. Arquitetura de Deployment

### 3.1 Recursos Azure
[lista de recursos e suas funções]

### 3.2 Container Apps
[descrição de cada Container App]

### 3.3 Networking
[como os containers se comunicam]

### 3.4 Persistência
[como dados são persistidos]

## 4. Processo de Bootstrap

[análise detalhada do bootstrap]

## 5. Gerenciamento de Variáveis de Ambiente

[análise de como env vars são gerenciadas]

## 6. Scripts de Operação

[análise dos scripts de operação]

## 7. Problemas Conhecidos

[lista de problemas e soluções]

## 8. Recomendações

[sugestões de melhorias]
```

## Observações Importantes

1. **Migração Recente**: O projeto foi migrado de Azure App Service para Container Apps. Alguns scripts antigos podem ainda estar no repositório mas marcados como DEPRECATED.

2. **PowerShell no Windows**: Todos os scripts principais são PowerShell (`.ps1`), projetados para Windows. Há versões Shell (`.sh`) para Linux, mas o foco é PowerShell.

3. **Idempotência**: A maioria dos scripts deve ser idempotente, permitindo execução múltipla sem efeitos colaterais.

4. **Segurança**: Secrets são gerenciados via Azure Key Vault, nunca hardcoded.

5. **Estado de Deployment**: O arquivo `.azure/deploy_state.json` armazena o estado do deployment (nomes de recursos, etc.).

## Perguntas Específicas a Responder

1. Qual é a ordem correta de execução dos scripts para fazer um deployment completo do zero?
2. Como funciona o processo de rollback em caso de falha?
3. Quais são os pré-requisitos antes de executar o bootstrap?
4. Como as variáveis de ambiente são sincronizadas entre `.env` e o Container App?
5. Como o Qdrant persiste dados entre reinicializações?
6. Qual é o processo de atualização da imagem da API em produção?
7. Como funciona a autenticação OIDC entre GitHub Actions e Azure?
8. Quais são os pontos de falha conhecidos e como mitigá-los?

---

**Arquivo a analisar**: `repo_concat_all.md` (gerado automaticamente pelo script `concat_repo_all_text.py`)

**Data de geração do snapshot**: Verificar no cabeçalho do arquivo MD

**Commit do repositório**: Verificar no cabeçalho do arquivo MD
