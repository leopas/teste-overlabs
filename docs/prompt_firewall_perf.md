# Prompt Firewall — performance e telemetria

## Métricas Prometheus

O firewall expõe as seguintes métricas em `/metrics`:

| Métrica | Tipo | Descrição |
|--------|------|-----------|
| `firewall_rules_loaded` | Gauge | Número de regras válidas atualmente carregadas |
| `firewall_reload_total` | Counter | Quantidade de recarregamentos (por `mtime` ou `force`) |
| `firewall_invalid_rule_total` | Counter | Regras ignoradas por regex inválida |
| `firewall_checks_total` | Counter | Número de chamadas a `check()` |
| `firewall_block_total` | Counter | Número de bloqueios (match em alguma regra) |
| `firewall_check_duration_seconds` | Histogram | Latência do `check()` |

Nenhuma label usa regex ou pattern (evita cardinalidade alta). Opcionalmente pode existir label `category` em métricas futuras, com valores fixos (INJECTION, EXFIL, SECRETS, PII, PAYLOAD).

## Como interpretar

- **`firewall_rules_loaded`**: Se 0 com firewall habilitado, o arquivo está ausente, só comentários, ou todas as regras falharam ao compilar.
- **`firewall_reload_total`**: Aumenta quando o arquivo de regras é alterado (`mtime`) e o throttle permite nova leitura.
- **`firewall_invalid_rule_total`**: Regras com regex inválida são ignoradas; o contador indica quantas falharam até o momento.
- **`firewall_checks_total`** vs **`firewall_block_total`**: Proporção de bloqueios sobre checks; útil para ajustar regras e avaliar falsos positivos/negativos.
- **`firewall_check_duration_seconds`**: Use para percentis (p50, p99) e garantir que o `check()` não degrade a latência do `/ask`.

## Ajuste de thresholds e regras

- **Menos bloqueios indesejados**: Afrouxe ou remova regras genéricas; prefira padrões mais específicos (ex.: `\breveal\b.*\bsystem\b` em vez de `.*reveal.*`).
- **Mais cobertura**: Inclua variações por idioma (PT, ES, FR, etc.) no mesmo `rule_id` ou em regras separadas; use `normalize_for_firewall` (NFKD, sem acentos) para manter o match estável.
- **Throttle de reload**: `PROMPT_FIREWALL_RELOAD_CHECK_SECONDS` controla a frequência do `stat`. Aumentar reduz I/O; diminuir acelera a aplicação de mudanças no arquivo.

## Boas práticas para regex (evitar ReDoS)

- Evite **backtracking catastrófico**: não use `(a+)+`, `(a|a)*`, etc. em entradas não limitadas.
- Prefira **delimitadores** (`\b`, `^`, `$`) e **quantificadores limitados** (`{0,60}` em vez de `*` quando fizer sentido).
- Teste regras com strings longas e repetitivas antes de colocar em produção.
- Mantenha regras **curtas e focadas**; evite `.*` amplo no meio do padrão.

## Logs estruturados

- **`firewall_reload`**: Em cada recarga, com `rules_count` e `invalid_count`.
- **`firewall_block`**: Em cada bloqueio, com `rule_id`, `category`, `question_hash` (SHA256 do texto normalizado), `trace_id`, `request_id`. Nunca se loga regex nem texto bruto.
- **`firewall_check`**: Amostragem configurável (`FIREWALL_LOG_SAMPLE_RATE`, padrão `0.01`) para checks que *não* bloquearam; inclui `duration_ms` e `matched=false`.

## Política de revisão e versionamento

- Mantenha o arquivo de regras em **controle de versão** (ex.: `config/prompt_firewall.regex`).
- Toda alteração deve passar por **revisão** antes de merge.
- Antes de subir novas regras, rode a suíte de testes (`test_prompt_firewall_*`, `test_guardrails`) e os property/fuzz (`test_prompt_firewall_fuzz`).
- Documente o propósito de regras novas em comentários `#` no próprio arquivo.
- Use **nomes estáveis** (`nome::REGEX`) para regras importantes, de modo que logs e métricas possam ser correlacionados ao longo do tempo.

## Referências

- [prompt_firewall.md](prompt_firewall.md): visão geral, formato do arquivo, variáveis de ambiente.
- Testes: `backend/tests/test_prompt_firewall_*`, `backend/tests/property/test_prompt_firewall_fuzz.py`.
