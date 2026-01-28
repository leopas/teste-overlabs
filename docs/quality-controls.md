# Controles de Qualidade

Como o sistema valida confiança, detecta conflitos e decide recusar respostas.

## Visão Geral

O sistema aplica **4 controles de qualidade** em sequência antes de retornar uma resposta:

1. **Threshold de confiança** (0.65)
2. **Cross-check** (validação cruzada)
3. **Detecção de conflitos** (prazos/datas por escopo)
4. **Pós-validação** (números na resposta devem existir na evidência)

**Fluxo completo**: [`backend/app/main.py`](backend/app/main.py) (linhas 800-890)

---

## 1. Threshold de Confiança

### Implementação

**Arquivo**: [`backend/app/quality.py`](backend/app/quality.py) (linhas 105-106)

```python
def quality_threshold(confidence: float, threshold: float = 0.65) -> bool:
    return confidence >= threshold
```

### Como funciona

- **Threshold padrão**: 0.65 (65%)
- **Cálculo de confiança**: Combinação de similaridade (60%), trust_score (40%) e freshness_score (20%)
- **Se `confidence < 0.65`**: Recusa imediatamente

**Cálculo de confiança**: [`backend/app/quality.py`](backend/app/quality.py) (linhas 85-102)

**Uso no fluxo**: [`backend/app/main.py`](backend/app/main.py) (linha 850)

---

## 2. Cross-Check (Validação Cruzada)

### Implementação

**Arquivo**: [`backend/app/quality.py`](backend/app/quality.py) (linhas 109-128)

```python
def cross_check_ok(
    doc_types: list[str],
    doc_paths: list[str],
    trust_scores: list[float],
    conflict: ConflictInfo,
) -> bool:
    if conflict.has_conflict:
        return False

    # Regra B: 2 fontes concordam OU 1 fonte POLICY/MANUAL com trust >= 0.85
    distinct_docs = {p for p in doc_paths if p}
    if len(distinct_docs) >= 2:
        return True
    if len(doc_types) == 1:
        dt = (doc_types[0] or "").upper()
        trust = trust_scores[0] if trust_scores else 0.0
        if dt in {"POLICY", "MANUAL"} and trust >= 0.85:
            return True
    return False
```

### Regras

1. **2+ fontes distintas**: Se há pelo menos 2 documentos diferentes, passa
2. **1 fonte POLICY/MANUAL com trust >= 0.85**: Se há apenas 1 documento e é POLICY ou MANUAL com trust_score alto, passa
3. **Conflito detectado**: Se há conflito, falha automaticamente

**Uso no fluxo**: [`backend/app/main.py`](backend/app/main.py) (linha 860)

---

## 3. Detecção de Conflitos

### Implementação

**Arquivo**: [`backend/app/quality.py`](backend/app/quality.py) (linhas 22-82)

```python
def detect_conflict(texts: list[str], *, question: str | None = None) -> ConflictInfo:
    # Detecta prazos em dias e datas dd/mm/yyyy por escopo (nacional/internacional/geral)
    # Conflito = mais de um valor diferente no mesmo escopo
```

### Como funciona

1. **Escopos suportados**: Nacional, internacional, geral
2. **Filtro por pergunta**: Se pergunta menciona "nacional", só considera sentenças nacionais
3. **Detecção**: Extrai prazos (dias) e datas (dd/mm/yyyy) de cada sentença
4. **Conflito**: Mais de um valor diferente no mesmo escopo

**Exemplo**:
- Sentença 1: "Prazo nacional: 10 dias"
- Sentença 2: "Prazo nacional: 30 dias"
- **Resultado**: Conflito detectado (2 valores diferentes para "nacional")

**Uso no fluxo**: [`backend/app/main.py`](backend/app/main.py) (linha 810)

### Limitações

- **Apenas prazos e datas**: Não detecta outros tipos de conflito (ex.: valores monetários diferentes)
- **Escopo por palavras-chave**: Depende de palavras "nacional" ou "internacional" no texto

---

## 4. Pós-Validação

### Implementação

**Arquivo**: [`backend/app/quality.py`](backend/app/quality.py) (linhas 130-136)

```python
def post_validate_answer(answer: str, evidence_text: str) -> bool:
    # Pós-validador simples (R1): números citados devem existir nos trechos.
    answer_nums = set(_NUM_RE.findall(answer))
    if not answer_nums:
        return True
    ev_nums = set(_NUM_RE.findall(evidence_text))
    return answer_nums.issubset(ev_nums)
```

### Como funciona

1. **Extrai números**: Todos os números da resposta do LLM
2. **Extrai números da evidência**: Todos os números dos trechos retornados
3. **Validação**: Se algum número da resposta não está na evidência, falha

**Exemplo**:
- Evidência: "Prazo: 30 dias"
- Resposta LLM: "O prazo é de 45 dias"
- **Resultado**: Falha (45 não está na evidência)

**Uso no fluxo**: [`backend/app/main.py`](backend/app/main.py) (linha 870)

---

## Fluxo Completo

**Arquivo**: [`backend/app/main.py`](backend/app/main.py) (linhas 800-890)

1. **Retrieval**: Busca top_k=8 chunks no Qdrant (linha 400)
2. **Re-rank**: Ordena por `final_score` (similarity + trust + freshness) (linha 600)
3. **Select evidence**: Limita tokens e seleciona top chunks (linha 700)
4. **Detect conflict**: Verifica conflitos em prazos/datas (linha 810)
5. **LLM**: Gera resposta (se não houver conflito) (linha 820)
6. **Quality threshold**: Verifica confidence >= 0.65 (linha 850)
7. **Cross-check**: Verifica 2+ fontes ou 1 fonte POLICY/MANUAL (linha 860)
8. **Post-validate**: Verifica números na resposta (linha 870)
9. **Retorna**: Resposta ou recusa

---

## Motivos de Recusa

**Arquivo**: [`backend/app/schemas.py`](backend/app/schemas.py) (linhas 34-49)

- `input_invalid`: Input inválido (3-2000 chars, sem caracteres de controle)
- `guardrail_injection`: Prompt injection detectado
- `guardrail_sensitive`: Informação sensível detectada (CPF, cartão, etc.)
- `guardrail_firewall`: Bloqueado pelo Prompt Firewall
- `rate_limited`: Rate limit excedido
- `cache_error`: Erro no cache
- `qdrant_unavailable`: Qdrant indisponível
- `no_evidence`: Sem evidência suficiente
- `conflict_unresolved`: Conflito irresolúvel
- `quality_threshold`: Confiança abaixo do threshold (0.65)
- `quality_crosscheck_failed`: Validação cruzada falhou
- `quality_post_validation_failed`: Pós-validação falhou
- `llm_error`: Erro no LLM

---

## Referências

- [Arquitetura](architecture.md) - Visão geral do sistema
- [Segurança](security.md) - Guardrails de segurança
- [Custo e Performance](cost-performance.md) - Otimizações
