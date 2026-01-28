# Índice da Documentação - teste-overlabs

> **⚠️ Aviso de Confidencialidade**: Este repositório é confidencial e destinado apenas para fins de avaliação. Veja [CONFIDENTIALITY.md](../CONFIDENTIALITY.md) para detalhes.

Mapa navegável de toda a documentação do projeto.

## Visão Geral

- [README Principal](../README.md) - Porta de entrada do projeto
- [Arquitetura](architecture.md) - Visão técnica dos componentes
- [Diagramas](diagrams.md) - Diagramas detalhados do sistema

## Desenvolvimento Local

- [Guia de Desenvolvimento Local](local-development.md) - Como rodar localmente
- [CI/CD](ci_cd.md) - Pipeline GitHub Actions e canary deployment

## Deploy e Operação

- [Deploy na Azure](deployment_azure.md) - Guia completo de deploy em Azure Container Apps
- [Runbook Operacional](runbook.md) - Operações do dia a dia
- [Runbook de Incidentes](runbook_incidents.md) - Troubleshooting e resolução de problemas

## Referência Técnica

- [API Reference](api.md) - Endpoints da API FastAPI
- [Variáveis de Ambiente](reference/env-vars.md) - Referência completa de env vars
- [Scripts de Infraestrutura](reference/scripts.md) - Inventário de scripts

## Documentação Especializada

### Segurança e Observabilidade

- [Segurança](security.md) - Guardrails, Prompt Firewall, classificação de abuso
- [Audit Logging](audit_logging.md) - Sistema de auditoria e rastreabilidade
- [Traceability](traceability.md) - Rastreabilidade de requests
- [Observability](observability.md) - Logs, métricas, OpenTelemetry

### Prompt Firewall

- [Prompt Firewall](prompt_firewall.md) - WAF de prompt (regras regex)
- [Prompt Firewall - Enrichment](prompt_firewall_enrichment.md) - Como enriquecer regras
- [Prompt Firewall - Exemplos](prompt_firewall_examples.md) - Exemplos de uso
- [Prompt Firewall - Performance](prompt_firewall_perf.md) - Análise de performance

### Configuração e Setup

- [GitHub Secrets Setup](github_secrets_setup.md) - Configurar OIDC para GitHub Actions
- [CI/CD Pipeline](ci_cd.md) - Detalhes do pipeline de deploy

## Documentação Gerada Automaticamente

> **Nota**: Estes arquivos são gerados automaticamente. Não edite manualmente.

- [Mapa do Repositório](_generated/repo_map.md) - Estrutura de scripts, workflows e compose files
- [Variáveis de Ambiente Detectadas](_generated/env_vars_detected.md) - Env vars extraídas do código
- [Inventário de Scripts](_generated/scripts_inventory.md) - Lista completa de scripts

## Documentação Técnica Avançada

- [Implementation Evidence Map](implementation_evidence_map.md) - Mapeamento de implementações
- [Implementation Adherence Report](implementation_adherence_report.md) - Relatório de aderência
- [Code Snapshot](code_snapshot.md) - Snapshot do código
- [Appendix Code Facts](appendix_code_facts.md) - Fatos sobre o código

## Guias Rápidos

### Para Desenvolvedores

1. **Primeiro contato**: Leia o [README](../README.md) e [Arquitetura](architecture.md)
2. **Setup local**: Siga o [Guia de Desenvolvimento Local](local-development.md)
3. **Entender a API**: Veja [API Reference](api.md)
4. **Configurar ambiente**: Consulte [Variáveis de Ambiente](reference/env-vars.md)

### Para DevOps/Platform

1. **Deploy inicial**: Siga [Deploy na Azure](deployment_azure.md)
2. **Configurar CI/CD**: Veja [CI/CD](ci_cd.md) e [GitHub Secrets Setup](github_secrets_setup.md)
3. **Operação diária**: Use [Runbook Operacional](runbook.md)
4. **Troubleshooting**: Consulte [Runbook de Incidentes](runbook_incidents.md)

### Para Operação

1. **Operações rotineiras**: [Runbook Operacional](runbook.md)
2. **Problemas comuns**: [Runbook de Incidentes](runbook_incidents.md)
3. **Scripts disponíveis**: [Scripts de Infraestrutura](reference/scripts.md)
4. **Monitoramento**: [Observability](observability.md)

## Estrutura de Arquivos

```
docs/
├── INDEX.md                    # Este arquivo
├── architecture.md            # Arquitetura do sistema
├── local-development.md        # Desenvolvimento local
├── deployment_azure.md         # Deploy Azure Container Apps
├── ci_cd.md                    # Pipeline CI/CD
├── runbook.md                  # Operações do dia a dia
├── runbook_incidents.md        # Troubleshooting
├── api.md                      # Referência da API
├── reference/
│   ├── env-vars.md            # Variáveis de ambiente
│   └── scripts.md             # Scripts de infraestrutura
├── _generated/                 # Arquivos gerados automaticamente
│   ├── repo_map.md
│   ├── env_vars_detected.md
│   └── scripts_inventory.md
└── [outros arquivos especializados]
```

## Atualização da Documentação

Para atualizar os arquivos gerados automaticamente:

```bash
python tools/docs_extract.py
```

Isso regenera:
- `docs/_generated/repo_map.md`
- `docs/_generated/env_vars_detected.md`
- `docs/_generated/scripts_inventory.md`
- `docs/_generated/api_endpoints.json`
