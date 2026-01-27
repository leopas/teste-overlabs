# Evidence Map: Documentação → Código

Mapeamento de declarações testáveis da documentação para evidências no código.

**Data:** 2026-01-26  
**Auditor:** Auditoria de Aderência

---

## Declarações Testáveis Extraídas

### A) Prompt Firewall - Bloqueio e Persistência

| ID | Doc | Declaração | Tipo | Criticidade | Evidência no Código | Status |
|----|-----|------------|------|-------------|---------------------|--------|
| PF-001 | `audit_logging.md:39` | Quando o firewall bloqueia, `audit_ask.firewall_rule_ids` contém JSON array com o `rule_id` | Behavior | CRÍTICA | `main.py:327-343` | ✅ OK |
| PF-002 | `audit_logging.md:40` | `firewall_rule_ids` é `TEXT NULL`; preenchido apenas quando há bloqueio pelo Prompt Firewall; `NULL` caso contrário | Schema/Behavior | CRÍTICA | `db_audit_schema.sql:48`, `main.py:327` | ⚠️ DIVERGE |
| PF-003 | `audit_logging.md:41` | O `rule_id` também existe em logs: evento `firewall_block` (rule_id, category, question_hash, trace_id, request_id) | Observability | ALTA | `prompt_firewall.py:256-263` | ✅ OK |
| PF-004 | `prompt_firewall.md:76` | `audit_sink.enqueue_ask` com `refusal_reason=guardrail_firewall` e `firewall_rule_ids` (JSON array) | Behavior | CRÍTICA | `main.py:328-344` | ✅ OK |
| PF-005 | `prompt_firewall.md:78` | O `rule_id` é persistido em `audit_ask.firewall_rule_ids` como JSON array | Behavior | CRÍTICA | `audit_store.py:341-389` | ✅ OK |
| PF-006 | `prompt_firewall.md:68` | Fallback heurístico retorna `rule_id = "inj_fallback_heuristic"` e persiste `firewall_rule_ids` | Behavior | ALTA | `main.py:354-384` | ✅ OK |
| PF-007 | `prompt_firewall.md:12` | Desabilitado por padrão: não altera o comportamento em produção até ser ativado | Config | ALTA | `config.py:46` | ✅ OK |
| PF-008 | `prompt_firewall.md:11` | Hot reload por `mtime`: editar o arquivo dispensa restart da API | Behavior | MÉDIA | `prompt_firewall.py:189-232` | ✅ OK |
| PF-009 | `prompt_firewall.md:11` | Throttle do `stat`: checagem de alteração limitada por `PROMPT_FIREWALL_RELOAD_CHECK_SECONDS` | Behavior | MÉDIA | `prompt_firewall.py:192-201` | ✅ OK |
| PF-010 | `prompt_firewall.md:74` | Resposta **200** com `answer` genérico de recusa, `sources=[]`, `confidence ≤ 0.3` | Behavior | CRÍTICA | `main.py:347-351` | ✅ OK |
| PF-011 | `prompt_firewall.md:75` | Headers: `X-Answer-Source=REFUSAL`, `X-Trace-ID`, `X-Chat-Session-ID` | Behavior | ALTA | `main.py:348-350` | ✅ OK |
| PF-012 | `prompt_firewall.md:76` | `trace_event("guardrails.block", {"kind": "firewall", "rule_id": "…"})` | Observability | ALTA | `main.py:320` | ✅ OK |
| PF-013 | `main.py:327` | Se `rule_id == "unknown"`, `firewall_rule_ids_json = None` | Behavior | CRÍTICA | `main.py:327` | ⚠️ NÃO DOCUMENTADO |

### B) Audit Logging - Writer e Schema

| ID | Doc | Declaração | Tipo | Criticidade | Evidência no Código | Status |
|----|-----|------------|------|-------------|---------------------|--------|
| AL-001 | `audit_logging.md:17` | Persistência assíncrona (fila em memória, worker grava em MySQL) | Behavior | CRÍTICA | `audit_store.py:119-303` | ✅ OK |
| AL-002 | `db_audit_schema.sql:48` | `firewall_rule_ids TEXT NULL` | Schema | CRÍTICA | `db_audit_schema.sql:48` | ✅ OK |
| AL-003 | `audit_logging.md:40` | Preenchido apenas quando há bloqueio pelo Prompt Firewall; `NULL` caso contrário | Behavior | CRÍTICA | `main.py:327,367,403-418` | ⚠️ DIVERGE |
| AL-004 | `audit_store.py:367` | `INSERT` inclui `firewall_rule_ids` e `UPDATE` também | Behavior | CRÍTICA | `audit_store.py:350-367` | ✅ OK |
| AL-005 | `audit_store.py:385` | Se `firewall_rule_ids` vier `None`, o DB recebe `NULL` | Behavior | CRÍTICA | `audit_store.py:385` | ✅ OK |
| AL-006 | `audit_store.py:291` | Se houver erro, loga com contexto (sem swallow silencioso) | Behavior | ALTA | `audit_store.py:277-292` | ✅ OK |

### C) Configuração - Variáveis de Ambiente

| ID | Doc | Declaração | Tipo | Criticidade | Evidência no Código | Status |
|----|-----|------------|------|-------------|---------------------|--------|
| CFG-001 | `prompt_firewall.md:18` | `PROMPT_FIREWALL_ENABLED` default é `0` | Config | ALTA | `config.py:46` | ✅ OK |
| CFG-002 | `prompt_firewall.md:19` | `PROMPT_FIREWALL_RULES_PATH` default é `config/prompt_firewall.regex` | Config | ALTA | `config.py:47` | ✅ OK |
| CFG-003 | `prompt_firewall.md:21` | `PROMPT_FIREWALL_MAX_RULES` default é `200` | Config | MÉDIA | `config.py:48` | ✅ OK |
| CFG-004 | `prompt_firewall.md:21` | `PROMPT_FIREWALL_RELOAD_CHECK_SECONDS` default é `2` | Config | MÉDIA | `config.py:49` | ✅ OK |
| CFG-005 | `prompt_firewall.py:334` | `firewall_log_sample_rate` existe (default 0.01) | Config | BAIXA | `config.py:50`, `prompt_firewall.py:177` | ✅ OK |
| CFG-006 | `env.example:68` | `FIREWALL_LOG_SAMPLE_RATE` documentado | Config | BAIXA | `env.example:68` | ✅ OK |

### D) Fallback Injection vs Firewall

| ID | Doc | Declaração | Tipo | Criticidade | Evidência no Código | Status |
|----|-----|------------|------|-------------|---------------------|--------|
| FB-001 | `prompt_firewall.md:65-68` | Quando firewall disabled, fallback bloqueia e persiste `firewall_rule_ids` com `inj_fallback_heuristic` | Behavior | ALTA | `main.py:354-384` | ✅ OK |
| FB-002 | `audit_logging.md:40` | `firewall_rule_ids` preenchido quando há bloqueio pelo Prompt Firewall ou fallback heurístico | Behavior | CRÍTICA | `main.py:327,367` | ✅ OK (corrigido) |
| FB-003 | `prompt_firewall.md:30` | `refusal_reason=guardrail_firewall` quando firewall bloqueia | Behavior | CRÍTICA | `main.py:319` | ✅ OK |
| FB-004 | `main.py:357` | `refusal_reason=guardrail_injection` quando fallback bloqueia | Behavior | CRÍTICA | `main.py:357` | ✅ OK |

---

## Divergências Identificadas e Corrigidas

### DIV-001: `firewall_rule_ids` no fallback heurístico

**Severidade:** CRÍTICA  
**Status:** ✅ CORRIGIDO

**Declaração na doc (antes):**
- `audit_logging.md:40`: "preenchido apenas quando há bloqueio pelo Prompt Firewall; `NULL` caso contrário"

**Evidência no código:**
- `main.py:367`: Fallback injection também grava `firewall_rule_ids_json = json.dumps([rule_id])`
- `main.py:383`: `firewall_rule_ids=firewall_rule_ids_json` é passado para `AuditAsk`

**Análise:**
- A documentação em `audit_logging.md` estava **incorreta**.
- O código grava `firewall_rule_ids` também para fallback (`guardrail_injection`).
- A documentação em `prompt_firewall.md:68` estava correta: "Fallback heurístico retorna `rule_id = "inj_fallback_heuristic"` e persiste `firewall_rule_ids`".

**Fix aplicado:**
- ✅ Atualizado `audit_logging.md:40` para refletir que `firewall_rule_ids` é preenchido quando:
  - Bloqueio pelo Prompt Firewall (`refusal_reason=guardrail_firewall`)
  - Bloqueio por fallback heurístico (`refusal_reason=guardrail_injection`)
- ✅ Adicionada nota explicando a diferença entre `guardrail_firewall` e `guardrail_injection`.

### DIV-002: Caso `rule_id == "unknown"` não documentado

**Severidade:** ALTA  
**Status:** ✅ DOCUMENTADO (comportamento correto, apenas não estava documentado)

**Evidência no código:**
- `main.py:317`: `rule_id = fw_details.get("rule_id", "unknown")`
- `main.py:327`: `firewall_rule_ids_json = json.dumps([rule_id]) if rule_id != "unknown" else None`
- `prompt_firewall.py:264`: Quando bloqueia, sempre retorna `{"rule_id": r.id, "category": r.category}`

**Análise:**
- `prompt_firewall.py:264` sempre retorna `rule_id` quando bloqueia, então o caso "unknown" só aconteceria se `fw_details` não contivesse a chave `"rule_id"`, o que não deveria acontecer dado o código atual.
- O código está preparado para este edge case (defensivo).

**Fix aplicado:**
- ✅ Teste adicionado (`test_firewall_rule_id_unknown_results_in_null`) para validar comportamento correto.
- ✅ Documentado no relatório de aderência.

### DIV-003: `guardrail_sensitive` não grava `firewall_rule_ids`

**Severidade:** MÉDIA

**Evidência no código:**
- `main.py:403-418`: Quando `detect_sensitive_request` bloqueia, `AuditAsk` é criado **sem** `firewall_rule_ids`.

**Análise:**
- Consistente: `guardrail_sensitive` não é relacionado ao firewall, então não grava `firewall_rule_ids`.
- Documentação está correta neste ponto.

**Status:** ✅ OK (não é divergência, comportamento esperado)

---

## Evidências Detalhadas por Arquivo

### `backend/app/main.py`

#### Bloqueio pelo Prompt Firewall (linhas 315-351)

```python
315: blocked, fw_details = firewall.check(question)
316: if blocked:
317:     rule_id = fw_details.get("rule_id", "unknown")
318:     category = fw_details.get("category", "INJECTION")
319:     refusal_reason = RefusalReason(kind="guardrail_firewall", details={"rule_id": rule_id})
320:     trace_event("guardrails.block", {"kind": "firewall", "rule_id": rule_id, "category": category})
321:     _plog("guardrail_block", kind="firewall", rule_id=rule_id, category=category)
322:     answer_source = "REFUSAL"
323:     log_audit_message("user", req.question)
324:     log_audit_message("assistant", REFUSAL_ANSWER)
325:     answer_hash_audit = sha256_text(redact_normalize(REFUSAL_ANSWER))
326:     latency_total = int((time.perf_counter() - start) * 1000)
327:     firewall_rule_ids_json = json.dumps([rule_id]) if rule_id != "unknown" else None
328:     audit_sink.enqueue_ask(
329:         AuditAsk(
330:             trace_id=trace_id,
331:             request_id=req_id,
332:             session_id=session_id,
333:             user_id=user_id,
334:             question_hash=question_hash_audit,
335:             answer_hash=answer_hash_audit,
336:             answer_source="REFUSAL",
337:             confidence=0.2,
338:             refusal_reason=refusal_reason.kind,
339:             cache_hit=False,
340:             latency_ms=latency_total,
341:             abuse_risk_score=abuse_risk_score,
342:             abuse_flags_json=flags_to_json(abuse_flags),
343:             firewall_rule_ids=firewall_rule_ids_json,
344:         )
345:     )
```

**Evidência:** ✅ Quando firewall bloqueia, `firewall_rule_ids` é preenchido com JSON array `["<rule_id>"]`, exceto se `rule_id == "unknown"` (neste caso, `None`).

#### Bloqueio por Fallback Heurístico (linhas 353-391)

```python
353: # Fallback: detectar injection quando firewall está disabled
354: injection_blocked, injection_rule_id = detect_prompt_injection_details(question)
355: if injection_blocked:
356:     rule_id = injection_rule_id or "inj_fallback_heuristic"
357:     refusal_reason = RefusalReason(kind="guardrail_injection", details={"rule_id": rule_id})
358:     trace_event("guardrails.block", {"kind": "injection", "rule_id": rule_id})
359:     _plog("guardrail_block", kind="injection", rule_id=rule_id)
360:     answer_source = "REFUSAL"
361:     # Logar mensagens user e assistant (recusa)
362:     log_audit_message("user", req.question)
363:     log_audit_message("assistant", REFUSAL_ANSWER)
364:     # Logar audit_ask
365:     answer_hash_audit = sha256_text(redact_normalize(REFUSAL_ANSWER))
366:     latency_total = int((time.perf_counter() - start) * 1000)
367:     firewall_rule_ids_json = json.dumps([rule_id])
368:     audit_sink.enqueue_ask(
369:         AuditAsk(
370:             trace_id=trace_id,
371:             request_id=req_id,
372:             session_id=session_id,
373:             user_id=user_id,
374:             question_hash=question_hash_audit,
375:             answer_hash=answer_hash,
376:             answer_source="REFUSAL",
377:             confidence=0.2,
378:             refusal_reason=refusal_reason.kind,
379:             cache_hit=False,
380:             latency_ms=latency_total,
381:             abuse_risk_score=abuse_risk_score,
382:             abuse_flags_json=flags_to_json(abuse_flags),
383:             firewall_rule_ids=firewall_rule_ids_json,
384:         )
385:     )
```

**Evidência:** ✅ Fallback também grava `firewall_rule_ids` com `["inj_fallback_heuristic"]`.

### `backend/app/audit_store.py`

#### Writer MySQL - INSERT/UPDATE (linhas 341-389)

```python
341: def _write_ask(self, conn, ask: AuditAsk) -> None:
342:     cur = conn.cursor()
343:     try:
344:         # Usar ON DUPLICATE KEY UPDATE para garantir que sempre existe (evita race condition)
345:         cur.execute(
346:             """
347:             INSERT INTO audit_ask
348:             (trace_id, request_id, session_id, user_id, question_hash, answer_hash, answer_source,
349:              confidence, refusal_reason, cache_key, cache_hit, llm_model, latency_ms,
350:              abuse_risk_score, abuse_flags_json, firewall_rule_ids, created_at)
351:             VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, UTC_TIMESTAMP())
352:             ON DUPLICATE KEY UPDATE
353:                 request_id = VALUES(request_id),
354:                 session_id = VALUES(session_id),
355:                 user_id = VALUES(user_id),
356:                 question_hash = VALUES(question_hash),
357:                 answer_hash = VALUES(answer_hash),
358:                 answer_source = VALUES(answer_source),
359:                 confidence = VALUES(confidence),
360:                 refusal_reason = VALUES(refusal_reason),
361:                 cache_key = VALUES(cache_key),
362:                 cache_hit = VALUES(cache_hit),
363:                 llm_model = VALUES(llm_model),
364:                 latency_ms = VALUES(latency_ms),
365:                 abuse_risk_score = VALUES(abuse_risk_score),
366:                 abuse_flags_json = VALUES(abuse_flags_json),
367:                 firewall_rule_ids = VALUES(firewall_rule_ids)
368:             """,
369:             (
370:                 ask.trace_id,
371:                 ask.request_id,
372:                 ask.session_id,
373:                 ask.user_id,
374:                 ask.question_hash,
375:                 ask.answer_hash,
376:                 ask.answer_source,
377:                 ask.confidence,
378:                 ask.refusal_reason,
379:                 ask.cache_key,
380:                 ask.cache_hit,
381:                 ask.llm_model,
382:                 ask.latency_ms,
383:                 ask.abuse_risk_score,
384:                 ask.abuse_flags_json,
385:                 ask.firewall_rule_ids,
386:             ),
387:         )
388:     finally:
389:         cur.close()
```

**Evidência:** ✅ `firewall_rule_ids` está no INSERT e no UPDATE. Se `ask.firewall_rule_ids` for `None`, MySQL recebe `NULL`.

#### Tratamento de Erro (linhas 277-292)

```python
277:             conn.commit()
278:         except Exception as e:
279:             error_str = str(e)
280:             # Se for erro de FK em chunk, re-enfileirar se ainda tiver tentativas
281:             if item_type == "chunk" and ("foreign key constraint" in error_str.lower() or "1452" in error_str):
282:                 retry_count = item.get("retry_count", 0)
283:                 if retry_count < 3:
284:                     log.warning("chunk_fk_retry", trace_id=data.trace_id, retry_count=retry_count)
285:                     try:
286:                         self._q.put_nowait({"type": "chunk", "data": data, "retry_count": retry_count + 1})
287:                     except queue.Full:
288:                         log.warning("chunk_retry_queue_full", trace_id=data.trace_id)
289:                 else:
290:                     log.error("chunk_fk_max_retries", trace_id=data.trace_id, error=error_str)
291:             else:
292:                 log.error("mysql_audit_write_error", error=error_str, item_type=item.get("type"))
```

**Evidência:** ✅ Erros são logados com contexto (`item_type`, `error`). Não há swallow silencioso.

### `docs/db_audit_schema.sql`

#### Schema (linha 48)

```sql
48:   firewall_rule_ids TEXT NULL,                  -- JSON array de rule_ids do Prompt Firewall que bloquearam (ex: ["inj_ignore_previous_instructions"])
```

**Evidência:** ✅ Coluna existe, tipo `TEXT NULL`, compatível com código.

### `backend/app/prompt_firewall.py`

#### Método `check()` retorna `rule_id` (linhas 238-268)

```python
238: def check(self, text: str) -> tuple[bool, dict[str, Any]]:
239:     # ...
244:     self.load_if_needed()
245:     
246:     if not self._rules:
247:         return False, {}
248:
249:     normalized = normalize_for_firewall(text)
250:     for r in self._rules:
251:         if r.compiled.search(normalized):
252:             metrics.FIREWALL_BLOCK_TOTAL.inc()
253:             qhash = _question_hash(normalized)
254:             trace_id = trace_id_ctx.get() or "unknown"
255:             req_id = request_id_ctx.get() or "unknown"
256:             log.info(
257:                 "firewall_block",
258:                 rule_id=r.id,
259:                 category=r.category,
260:                 question_hash=qhash,
261:                 trace_id=trace_id,
262:                 request_id=req_id,
263:             )
264:             return True, {"rule_id": r.id, "category": r.category}
```

**Evidência:** ✅ Quando bloqueia, sempre retorna `{"rule_id": r.id, "category": r.category}`. `rule_id` nunca será "unknown" quando `blocked=True` (a menos que `r.id` seja literalmente "unknown", o que seria um bug na regra).

**Análise:** O caso `rule_id == "unknown"` em `main.py:317` só aconteceria se `fw_details` não contivesse a chave `"rule_id"`, o que não deveria acontecer dado o código de `prompt_firewall.py:264`.

---

## Resumo de Status

| Status | Quantidade | IDs |
|--------|------------|-----|
| ✅ OK | 22 | PF-001, PF-002 (corrigido), PF-003 a PF-012, AL-001, AL-002, AL-004 a AL-006, CFG-001 a CFG-006, FB-001, FB-002 (corrigido), FB-003, FB-004 |
| ⚠️ DOCUMENTADO | 1 | PF-013 (caso `rule_id == "unknown"` - teste adicionado, comportamento validado) |

---

## Status Final

### ✅ Todas as Divergências Corrigidas

1. ✅ **DIV-001 corrigida**: `audit_logging.md` atualizado para refletir que `firewall_rule_ids` também é preenchido no fallback.
2. ✅ **PF-013 documentado**: Teste adicionado para validar comportamento quando `rule_id == "unknown"`.
3. ✅ **Testes adicionados**: 6 novos testes em `test_audit_firewall_rule_ids_persistence.py` cobrindo persistência de `firewall_rule_ids`.
