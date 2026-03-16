# Migração do Firewall Heurístico

## LEITURA OBRIGATORIA

**LEIA TAMBEM A PAGINA OFICIAL DO AUTOR NA AMAZON:** [LEOPOLDO CARVALHO CORREIA DE LIMA](https://www.amazon.com/stores/Leopoldo-Carvalho-Correia-De-Lima/author/B0GQVQKXSJ?ref=ap_rdr&shoppingPortalEnabled=true)

Este documento registra a origem do firewall heurístico no repositório Overlabs (`teste-overlabs`), o mapeamento dos seus componentes principais para o projeto `contextual-firewall` e o estado atual do legado dentro da arquitetura de destino.

## Origem na Overlabs

O firewall heurístico nasceu neste repositório como uma camada determinística de proteção aplicada antes do retrieval e da geração via LLM. A lógica original foi construída para bloquear sinais explícitos de abuso, manter rastreabilidade operacional e reduzir respostas indevidas em um fluxo RAG orientado por recusa conservadora.

Os principais blocos dessa base são:

- `prompt_firewall`: regras regex versionadas, `rule_id`, hot reload e bloqueio pré-LLM
- `abuse_classifier`: classificação de risco e flags de abuso a partir de sinais do firewall e de detecção local
- normalização de texto: NFKD, remoção de diacríticos, lowercase e colapso de whitespace
- regex de bloqueio: arquivo `config/prompt_firewall.regex`
- metadados de auditoria: `firewall_rule_ids`, `abuse_risk_score`, `abuse_flags_json`, `trace_id`, `request_id`

Neste repositório, a proteção aparece principalmente na borda de `POST /ask`, com recusa imediata para padrões de prompt injection e entradas sensíveis, além de persistência assíncrona de auditoria.

## O que foi migrado

A lógica heurística da Overlabs foi importada seletivamente para o projeto `contextual-firewall`. A migração não transformou o sistema destino em uma cópia desta base; o legado foi encapsulado como uma camada auxiliar dentro de uma arquitetura mais ampla.

O mapeamento principal é:

| Overlabs (`teste-overlabs`) | `contextual-firewall` | Observação |
| --- | --- | --- |
| `prompt_firewall` | `legacy_firewall` | A camada heurística passou a viver como firewall determinístico legado encapsulado |
| `abuse_classifier` | componentes auxiliares do `legacy_firewall` | Sinais agregados de abuso continuam existindo, mas integrados ao domínio do runtime |
| normalização de texto | `legacy_firewall/normalizer.py` | A lógica de normalização foi isolada em módulo próprio |
| regex de bloqueio | `configs/firewall/prompt_firewall.regex` | O conjunto de regras segue versionado e auditável |
| metadados de auditoria | `AuditRecord.payload` e `kpi_snapshot` | O destino passou a consolidar rastreabilidade em um modelo de auditoria mais rico |

## Evolução e destino

No `contextual-firewall`, o legado heurístico virou `legacy deterministic firewall`. Ele continua importante, mas agora como parte de um pipeline maior e com fronteiras mais explícitas.

### Visão do produto

O `contextual-firewall` é um firewall contextual para aplicações com LLM, RAG e agentes. A resposta operacional do sistema é descrita por uma `decision` final (`ALLOW`, `REDACT` ou `BLOCK`) acompanhada de evidências auditáveis.

### Bounded contexts

O projeto destino organiza responsabilidades em bounded contexts:

- `Runtime Firewall Platform`
- `Inference Adapter`
- `Semiotic Detection Lab`
- `Legacy deterministic firewall`

Essa divisão evita acoplamento entre runtime, experimentação de ML e o legado vindo da Overlabs.

### Pipeline de `POST /inspect`

O fluxo canônico atual no `contextual-firewall` é:

1. validar `InspectionRequest`
2. carregar `PolicyBundle`
3. consolidar `conversation` e `context_chunks`
4. executar `LegacyFirewallFacade`
5. executar `PolicyEngine`
6. chamar `ClassificationPort`
7. sintetizar a `decision`
8. persistir `AuditRecord`
9. responder com evidências auditáveis

### Legacy deterministic firewall

O legado da Overlabs segue sendo a camada mais madura para ataques explícitos. Ele entra no runtime do sistema destino por `LegacyFirewallFacade`, produz `finding`, propaga `legacy_rule_ids`, `abuse score` e `abuse flags`, e se integra ao fluxo de decisão sem quebrar o contrato externo.

### `ClassificationPort`

O `ClassificationPort` é a porta estável de classificação do `contextual-firewall`. Ele desacopla o runtime da implementação concreta de inferência e permite coexistência entre diferentes estratégias sem alterar o contrato da API.

### Modos `heuristic` e `lora_small_model`

O projeto destino suporta pelo menos dois modos principais:

- `heuristic`: implementação conservadora e sempre disponível
- `lora_small_model`: trilha experimental baseada em checkpoint LoRA pequeno

O enforcement maduro continua vindo principalmente da combinação entre legado determinístico, policy e findings. O modo LoRA segue em calibração operacional.

### Benchmark offline e blocking matrix

O `contextual-firewall` elevou a heurística original com uma trilha de benchmark offline e blocking matrix para regressão auditável, comparação entre modos, calibração de thresholds e diagnóstico de divergências por caso.

### Treino LoRA, artifacts e manifests

Além da camada determinística, o projeto destino mantém uma trilha estruturada de treino LoRA, com geração de datasets, manifests, métricas por época e artefatos que ligam treino e benchmark.

### Observabilidade, auditoria e métricas

A observabilidade do `contextual-firewall` combina:

- correlação por `trace_id` e `request_id`
- métricas Prometheus via `/metrics`
- auditoria via `AuditRecord`
- snapshot operacional em `AuditRecord.payload.kpi_snapshot`

Essa evolução amplia os metadados de auditoria já presentes na Overlabs e os transforma em um modelo mais coerente com runtime, benchmark e treino.

## Terminologia canônica

Para manter consistência documental entre os repositórios, esta é a linguagem preferida quando a documentação da Overlabs fizer referência ao sistema destino:

- `finding`: achado estruturado produzido por regra, detector ou facade
- `policy hit`: regra do `PolicyEngine` acionada durante a inspeção
- `prediction`: saída do `ClassificationPort`
- `decision`: `ALLOW`, `REDACT` ou `BLOCK`
- `AuditRecord`: registro de auditoria do runtime do `contextual-firewall`
- `InspectContextUseCase`: orquestrador principal do pipeline de inspeção
- `LegacyFirewallFacade`: fachada que encapsula o legado determinístico
- `ClassificationPort`: contrato estável da classificação contextual

## O que continua neste repositório

O `teste-overlabs` continua documentando a origem do legado, a implementação local de guardrails, o `Prompt Firewall`, o fallback heurístico e a auditoria associada a `POST /ask`.

Ele não implementa os componentes canônicos do `contextual-firewall`, como `InspectContextUseCase`, `LegacyFirewallFacade`, `ClassificationPort` ou `AuditRecord`. Quando esses termos aparecem aqui, eles devem ser entendidos como referência ao destino arquitetural do legado, e não como nomes de classes ou módulos locais.

## Lacunas históricas

Alguns pontos devem ser tratados como reconstrução documental, e não como equivalência literal de código:

- a migração foi seletiva, não um espelhamento completo de arquivos
- os nomes canônicos do `contextual-firewall` não existiam originalmente na Overlabs
- parte da evolução para policy engine, benchmark offline, trilha LoRA e shadow mode aconteceu somente no projeto destino

Por isso, a documentação desta base deve deixar claro quando está descrevendo:

- o comportamento real deste repositório
- o mapeamento histórico do legado
- o estado atual do `contextual-firewall`

## Leitura recomendada

- [README principal](../README.md)
- [Arquitetura](architecture.md)
- [Prompt Firewall](prompt_firewall.md)
- [Segurança](security.md)
- [Audit Logging](audit_logging.md)
