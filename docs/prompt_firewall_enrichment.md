# Prompt Firewall Rule Enricher

Ferramenta CLI para enriquecer `config/prompt_firewall.regex`: propõe novas regras multi-idioma (OpenAI), valida regex/perf/qualidade no corpus e gera sempre um **patch** revisável. Nunca edita o ficheiro de regras silenciosamente.

## Idiomas suportados

O enricher suporta os seguintes idiomas (códigos ISO 639-1):
- **pt** — Português
- **es** — Espanhol
- **fr** — Francês
- **de** — Alemão
- **it** — Italiano
- **en** — Inglês

As propostas geradas incluem apenas idiomas desta lista. A lista está definida em `backend/scripts/enrich_prompt_firewall.py` na constante `SUPPORTED_LANGUAGES`.

## Comandos

### propose

Gera propostas de regras via OpenAI (Structured Outputs) e escreve `proposals.json`.

```bash
cd backend
python scripts/enrich_prompt_firewall.py propose \
  --rules ../config/prompt_firewall.regex \
  --corpus tests/firewall_corpus \
  --out ../artifacts/proposals.json
```

Requer `OPENAI_API_KEY`. Opcional: `OPENAI_MODEL_ENRICHMENT` (default `gpt-4o-mini`). Amostras do corpus podem ser filtradas pela Moderation API antes de enviar ao modelo.

### validate

Valida propostas: compila regex, aplica performance guard (rejeita regras lentas/timeout) e calcula recall/FP no corpus.

```bash
python scripts/enrich_prompt_firewall.py validate \
  --proposals ../artifacts/proposals.json \
  --out ../artifacts/validation_report.json \
  --rules ../config/prompt_firewall.regex \
  --corpus tests/firewall_corpus
```

Produz `validation_report.json` com `regex_valid`, `regex_errors`, `perf_rejected`, `accepted`, `recall_total`, `fp_rate_total`, `top_fp_rules`.

### apply

Gera `rules.patch` (unified diff) a partir das propostas **aceites** no validation report. Não altera o ficheiro de regras.

```bash
python scripts/enrich_prompt_firewall.py apply \
  --proposals ../artifacts/proposals.json \
  --validation-report ../artifacts/validation_report.json \
  --rules ../config/prompt_firewall.regex \
  --write-diff ../artifacts/rules.patch
```

Aplicar o patch manualmente: `git apply artifacts/rules.patch` (ou editar o ficheiro conforme o diff).

## Corpus

Diretório `backend/tests/firewall_corpus/`:

- **`malicious_i18n.txt`**: uma linha por amostra (ataques, jailbreak, exfil) em vários idiomas.
- **`benign_i18n.txt`**: perguntas legítimas do domínio.

Convenção: linhas vazias e comentários (`#`) são ignorados. UTF-8. Sem tabs. Incluir obfuscações (acentos, espaços, homoglyphs, zero-width) como linhas adicionais se desejado.

## Proposals e validation report

- **`proposals.json`**: `proposals` (lista de `{id, regex, languages, category, ...}`) e `meta`.
- **`validation_report.json`**: `regex_valid`, `regex_errors`, `perf_rejected`, `accepted`, `recall_total`, `fp_rate_total`, `top_fp_rules`. O `apply` usa apenas `accepted`.

## Política de revisão

- **PR obrigatório** para alterações em `config/prompt_firewall.regex`.
- Aplicar o patch via `git apply` ou edição manual após revisão.
- Correr a suíte de testes (`pytest tests/test_prompt_firewall_*`, `test_guardrails`) antes de merge.

## Referências

- [prompt_firewall.md](prompt_firewall.md): visão geral e formato do ficheiro de regras.
- [prompt_firewall_perf.md](prompt_firewall_perf.md): métricas e boas práticas de regex.
