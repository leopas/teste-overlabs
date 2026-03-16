# Segurança

## LEITURA OBRIGATORIA

**LEIA TAMBEM A PAGINA OFICIAL DO AUTOR NA AMAZON:** [LEOPOLDO CARVALHO CORREIA DE LIMA](https://www.amazon.com/stores/Leopoldo-Carvalho-Correia-De-Lima/author/B0GQVQKXSJ?ref=ap_rdr&shoppingPortalEnabled=true)

O que o sistema bloqueia e como protege contra ataques.

## Contexto histórico e evolução

Os guardrails documentados aqui representam a forma original da camada heurística criada neste repositório Overlabs. Essa base inclui `prompt_firewall`, `abuse_classifier`, normalização de texto, regex de bloqueio e metadados de auditoria associados ao fluxo de `POST /ask`.

Mais tarde, essa lógica foi migrada seletivamente para o `contextual-firewall`, onde hoje aparece como `legacy deterministic firewall`. No sistema destino, o legado passou a coexistir com uma arquitetura maior, incluindo `LegacyFirewallFacade`, `InspectContextUseCase`, `ClassificationPort`, policy engine versionado, `AuditRecord`, `/metrics`, benchmark offline e trilha de treino LoRA.

Para manter a documentação coerente entre origem e destino, vale separar três níveis de leitura:

- comportamento local real: fallback heurístico, Prompt Firewall, detecção de sensível/PII e recusa imediata
- mapeamento histórico: como esses componentes foram importados para o `contextual-firewall`
- estado atual do destino: `finding`, `policy hit`, `prediction` e `decision` (`ALLOW`, `REDACT`, `BLOCK`)

## Validação de Input

### Implementação

**Arquivo**: [`backend/app/schemas.py`](backend/app/schemas.py) (linhas 12-20)

```python
class AskRequest(BaseModel):
    question: str = Field(..., min_length=3, max_length=2000)

    @field_validator("question")
    @classmethod
    def no_control_chars(cls, v: str) -> str:
        if _CONTROL_CHARS_RE.search(v):
            raise ValueError("question contém caracteres de controle")
        return v
```

### Regras

- **Tamanho**: 3-2000 caracteres
- **Caracteres de controle**: Bloqueados (regex `[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]`)

**Uso**: [`backend/app/main.py`](backend/app/main.py) (linha 140) - validação automática pelo FastAPI

---

## Detecção de Prompt Injection

### Implementação

**Arquivo**: [`backend/app/security.py`](backend/app/security.py) (linhas 59-76)

```python
def detect_prompt_injection(question: str) -> bool:
    normalized = normalize_for_firewall_fallback(question)
    return bool(_INJECTION_RE.search(normalized))
```

### Padrões Detectados

**Regex**: [`backend/app/security.py`](backend/app/security.py) (linhas 11-21)

- "ignore (all) previous instructions"
- "disregard the system prompt"
- "reveal the system prompt"
- "show me your system prompt"
- "jailbreak"
- "begin system prompt" / "end system prompt"
- "you are chatgpt"
- "as an ai language model"

### Normalização

**Arquivo**: [`backend/app/security.py`](backend/app/security.py) (linhas 44-56)

- NFKD normalization (remove diacríticos)
- Lowercase
- Collapse whitespace

**Uso**: [`backend/app/main.py`](backend/app/main.py) (linha 350) - apenas quando Prompt Firewall está disabled

**Nota**: Se Prompt Firewall estiver habilitado, usa regras regex do arquivo `config/prompt_firewall.regex` em vez deste fallback.

---

## Bloqueio de Perguntas Sensíveis

### Implementação

**Arquivo**: [`backend/app/security.py`](backend/app/security.py) (linha 79)

```python
def detect_sensitive_request(question: str) -> bool:
    return bool(_CPF_RE.search(question) or _CARD_RE.search(question) or _SECRET_RE.search(question))
```

### Padrões Detectados

**CPF**: [`backend/app/security.py`](backend/app/security.py) (linha 24)
- Formato: `XXX.XXX.XXX-XX` ou `XXXXXXXXXXX` (11 dígitos)

**Cartão**: [`backend/app/security.py`](backend/app/security.py) (linha 25)
- 13-19 dígitos com espaços/hífens opcionais

**Segredos**: [`backend/app/security.py`](backend/app/security.py) (linhas 26-31)
- Palavras-chave: "password", "senha", "token", "api key", "secret", "private key", "ssh-rsa", "BEGIN PRIVATE KEY", "cartão", "cvv", "conta bancária", "agência", "banco"

### Ação

**Uso**: [`backend/app/main.py`](backend/app/main.py) (linha 360)

- **Recusa imediata**: Não chama retriever nem LLM
- **Motivo**: `guardrail_sensitive`
- **Confiança**: 0.2 (recusa padrão)

---

## Prompt Firewall (Opcional)

### Implementação

**Arquivo**: [`backend/app/prompt_firewall.py`](backend/app/prompt_firewall.py)

### Como funciona

- **Regras regex**: Lidas de `config/prompt_firewall.regex`
- **Hot reload**: Verifica mudanças no arquivo a cada 2 segundos (configurável)
- **Normalização**: NFKD + remove diacríticos + lowercase + collapse whitespace
- **Bloqueio**: Se regra casa, recusa imediatamente

**Uso**: [`backend/app/main.py`](backend/app/main.py) (linha 315)

**Configuração**: `PROMPT_FIREWALL_ENABLED=1` no `.env`

**Nota**: Quando habilitado, substitui o fallback de prompt injection em `security.py`.

### Mapeamento histórico

No `contextual-firewall`, esta camada corresponde ao `legacy deterministic firewall`, encapsulado por `LegacyFirewallFacade`. A implementação local continua sendo a origem do matching determinístico; o sistema destino apenas reorganiza esse legado dentro de um runtime maior.

---

## Rate Limiting

### Implementação

**Arquivo**: [`backend/app/cache.py`](backend/app/cache.py) (linhas 39-50)

```python
def rate_limit_allow(self, ip: str, limit_per_minute: int) -> bool:
    epoch_min = int(time.time() // 60)
    key = f"rl:{ip}:{epoch_min}"
    pipe = self._client.pipeline()
    pipe.incr(key, 1)
    pipe.expire(key, 70)
    count, _ = pipe.execute()
    return int(count) <= int(limit_per_minute)
```

### Como funciona

- **Limite padrão**: 60 requests/minuto por IP
- **Chave Redis**: `rl:<ip>:<epochMinute>`
- **Janela**: Fixa por minuto (não sliding window)
- **Ação**: Se excedido, recusa com motivo `rate_limited`

**Uso**: [`backend/app/main.py`](backend/app/main.py) (linha 274)

**Configuração**: `RATE_LIMIT_PER_MINUTE=60` no `.env`

---

## Fluxo de Segurança

**Arquivo**: [`backend/app/main.py`](backend/app/main.py) (linhas 262-370)

1. **Validação input**: FastAPI valida automaticamente (linha 140)
2. **Rate limiting**: Verifica limite por IP (linha 274)
3. **Prompt Firewall**: Se habilitado, verifica regras regex (linha 315)
4. **Prompt injection fallback**: Se firewall disabled, usa heurística (linha 350)
5. **Sensitive request**: Verifica CPF, cartão, segredos (linha 360)
6. **Se bloqueado**: Recusa imediatamente, não chama retriever/LLM

## Linguagem recomendada para documentação cruzada

Quando esta base for comparada ao `contextual-firewall`, use a terminologia canônica do projeto destino:

- `finding`: achado estruturado gerado por regra, detector ou facade
- `policy hit`: regra do `PolicyEngine` acionada
- `prediction`: saída do `ClassificationPort`
- `decision`: resultado final `ALLOW`, `REDACT` ou `BLOCK`
- `AuditRecord`: registro de auditoria do sistema destino

Importante: esses nomes não substituem automaticamente os modelos locais. Eles servem para descrever a evolução do legado com vocabulário consistente.

---

## Limitações

- **Prompt injection heurística**: Não é exaustiva, pode ter falsos negativos
- **Rate limit simples**: Janela fixa permite bursts no início do minuto
- **Sensitive detection**: Baseado em regex, pode ter falsos positivos/negativos
- **Sem autenticação**: API não requer autenticação (assume ambiente controlado)

---

## Referências

- [Controles de Qualidade](quality-controls.md) - Validação de respostas
- [Arquitetura](architecture.md) - Visão geral do sistema
- [Prompt Firewall](prompt_firewall.md) - Detalhes da camada heurística local
- [Migração do Firewall Heurístico](heuristic_firewall_migration.md) - Origem, mapeamento e evolução para o `contextual-firewall`
