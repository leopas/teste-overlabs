from __future__ import annotations

import base64
import json
import time
import uuid
from typing import Any

import structlog
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from .abuse_classifier import classify, flags_to_json, should_save_raw
from .audit_store import (
    AuditAsk,
    AuditChunk,
    AuditMessage,
    AuditSession,
    get_audit_sink,
)
from .cache import RedisClient, cache_key_for_excerpt, cache_key_for_question
from .config import settings
from .crypto_simple import encrypt_text
from .llm import LLMProvider, get_llm_provider
from .metrics import CACHE_HIT_COUNT, REFUSAL_COUNT, REQUEST_COUNT, REQUEST_LATENCY, metrics_response
from .observability import (
    RequestContextMiddleware,
    configure_logging,
    configure_otel,
    request_id_ctx,
    trace_id_ctx,
    user_id_ctx,
)
from .quality import (
    REFUSAL_ANSWER,
    combine_confidence,
    compute_heuristic_confidence,
    cross_check_ok,
    detect_conflict,
    post_validate_answer,
    quality_threshold,
)
from .prompt_firewall import build_prompt_firewall
from .redaction import normalize_text as redact_normalize, redact_text, sha256_text
from .retrieval import EmbeddingsProvider, QdrantStore, excerpt, excerpt_for_question, get_embeddings_provider, select_evidence
from .schemas import AskRequest, AskResponse, RefusalReason, SourceItem
from .security import detect_prompt_injection, detect_sensitive_request, normalize_question
from .trace_store import PipelineTrace, get_trace_sink, hash_chunk


log = structlog.get_logger()
pipeline_log = structlog.get_logger("pipeline")


def _plog(event: str, **fields: Any) -> None:
    if not settings.pipeline_log_enabled:
        return
    pipeline_log.info(event, **fields)


def _safe_question_preview(q: str, max_chars: int = 80) -> str:
    s = " ".join(q.strip().split())
    if len(s) <= max_chars:
        return s
    return s[: max_chars - 1] + "…"


def refusal(reason: RefusalReason, *, confidence: float = 0.2) -> JSONResponse:
    REFUSAL_COUNT.labels(reason=reason.kind).inc()
    payload = AskResponse(answer=REFUSAL_ANSWER, confidence=confidence, sources=[]).model_dump()
    return JSONResponse(status_code=200, content=payload)


def get_cache(_settings: Any = settings) -> RedisClient:
    return RedisClient()


def get_retriever(_settings: Any = settings) -> QdrantStore:
    return QdrantStore()


def get_embedder(_settings: Any = settings) -> EmbeddingsProvider:
    return get_embeddings_provider()


def get_llm(_settings: Any = settings) -> LLMProvider:
    return get_llm_provider()


def create_app(test_overrides: dict[str, Any] | None = None) -> FastAPI:
    configure_logging()
    configure_otel()

    app = FastAPI(title="MVP RAG (FastAPI + Qdrant + Redis)", version="0.1.0")
    app.add_middleware(RequestContextMiddleware)

    if settings.otel_enabled and settings.otel_exporter_otlp_endpoint:
        try:
            from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

            FastAPIInstrumentor().instrument_app(app)
        except Exception:
            pass

    overrides = test_overrides or {}
    app.state.cache = overrides.get("cache") or get_cache(settings)
    app.state.retriever = overrides.get("retriever") or get_retriever(settings)
    app.state.embedder = overrides.get("embedder") or get_embedder(settings)
    app.state.llm = overrides.get("llm") or get_llm(settings)
    app.state.trace_sink = overrides.get("trace_sink") or get_trace_sink()
    app.state.audit_sink = overrides.get("audit_sink") or get_audit_sink()
    app.state.prompt_firewall = overrides.get("prompt_firewall") or build_prompt_firewall(settings)

    @app.get("/healthz")
    async def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/readyz")
    async def readyz() -> JSONResponse:
        cache = app.state.cache
        retriever = app.state.retriever
        ok_redis = False
        ok_qdrant = False
        try:
            ok_redis = cache.ping()
        except Exception:
            ok_redis = False
        try:
            ok_qdrant = retriever.ready()
        except Exception:
            ok_qdrant = False

        status = 200 if (ok_redis and ok_qdrant) else 503
        return JSONResponse(status_code=status, content={"redis": ok_redis, "qdrant": ok_qdrant})

    @app.get("/metrics")
    async def metrics() -> Any:
        return metrics_response()

    @app.post("/ask", response_model=AskResponse)
    async def ask(req: AskRequest, request: Request) -> JSONResponse:
        cache = request.app.state.cache
        retriever = request.app.state.retriever
        embedder = request.app.state.embedder
        llm = request.app.state.llm
        trace_sink = request.app.state.trace_sink
        audit_sink = request.app.state.audit_sink

        endpoint = "/ask"
        start = time.perf_counter()
        cache_hit = False
        top_docs: list[dict[str, Any]] = []
        refusal_reason: RefusalReason | None = None
        counted = False
        trace_finished = False
        answer_source: str = "REFUSAL"  # CACHE, LLM, ou REFUSAL

        trace_id = trace_id_ctx.get() or "unknown"
        req_id = request_id_ctx.get() or "unknown"
        user_id = user_id_ctx.get()

        # Session ID: ler do header ou gerar
        session_id = request.headers.get("X-Chat-Session-ID")
        if not session_id:
            session_id = uuid.uuid4().hex[:16]

        # question_hash deve ser sha256 da pergunta normalizada (igual ao cache key)
        normalized_for_hash = normalize_question(req.question)
        question_hash = cache_key_for_question(normalized_for_hash)

        # Abuse classification
        abuse_risk_score = 0.0
        abuse_flags: list[str] = []
        if settings.abuse_classifier_enabled:
            abuse_risk_score, abuse_flags = classify(req.question)

        # Normalizar pergunta para hash/redaction
        normalized_question = redact_normalize(req.question)
        question_hash_audit = sha256_text(normalized_question)
        pipeline_trace = PipelineTrace(
            trace_id=trace_id,
            request_id=req_id,
            user_id=user_id,
            question_hash=question_hash,
            topk=8,
        )

        def trace_event(name: str, attrs: dict[str, Any] | None = None, duration_ms: int | None = None) -> None:
            # Nunca colocar texto bruto aqui (somente hashes/metadados).
            pipeline_trace.add_event(name=name, attrs=attrs or {}, duration_ms=duration_ms)
            # logs detalhados: somente se habilitado (com possível redaction fora daqui)
            _plog(name, **(attrs or {}), duration_ms=duration_ms)

        def log_audit_message(role: str, text: str) -> None:
            """Loga mensagem user/assistant no audit store."""
            if not settings.audit_log_enabled:
                return

            text_normalized = redact_normalize(text)
            text_hash_audit = sha256_text(text_normalized)
            text_redacted_val = None
            text_raw_enc_val = None
            text_raw_enc_alg_val = None
            text_raw_enc_kid_val = None

            if settings.audit_log_include_text:
                if settings.audit_log_redact:
                    text_redacted_val = redact_text(text)
                else:
                    text_redacted_val = text

            # Raw encryption se necessário
            should_encrypt = should_save_raw(
                abuse_risk_score, settings.audit_log_raw_mode, settings.abuse_risk_threshold
            )
            if should_encrypt:
                # AAD baseado no modo configurado
                aad = b""
                if settings.audit_enc_aad_mode == "trace_id":
                    aad = trace_id.encode()
                elif settings.audit_enc_aad_mode == "request_id":
                    aad = req_id.encode()

                envelope = encrypt_text(text, aad)
                if envelope:
                    text_raw_enc_val = json.dumps(envelope)
                    text_raw_enc_alg_val = envelope.get("alg")
                    text_raw_enc_kid_val = envelope.get("kid")

            audit_sink.enqueue_message(
                AuditMessage(
                    session_id=session_id,
                    trace_id=trace_id,
                    role=role,  # type: ignore
                    text_hash=text_hash_audit,
                    text_redacted=text_redacted_val,
                    text_raw_enc=text_raw_enc_val,
                    text_raw_enc_alg=text_raw_enc_alg_val,
                    text_raw_enc_kid=text_raw_enc_kid_val,
                )
            )

        # Logar session (touch last_seen_at)
        if settings.audit_log_enabled:
            audit_sink.enqueue_session(
                AuditSession(session_id=session_id, user_id=user_id, client_fingerprint=None)
            )

        def finish_trace(outcome: str, refusal_kind: str | None, confidence: float | None, model: str | None) -> None:
            nonlocal trace_finished
            if trace_finished:
                return
            pipeline_trace.cache_hit = cache_hit
            pipeline_trace.finish(outcome=outcome, refusal_reason=refusal_kind, confidence=confidence, model=model)
            try:
                trace_sink.enqueue(pipeline_trace)
            except Exception as e:
                log.warning("trace_sink_error", error=str(e))
            trace_finished = True

        try:
            ip = (request.client.host if request.client else "unknown") or "unknown"
            trace_event("ask.start", {"ip": ip})
            _plog(
                "ask_received",
                ip=ip,
                question_len=len(req.question),
                question_preview=(
                    redact_text(_safe_question_preview(req.question)) if settings.pipeline_log_include_text else None
                ),
            )
            try:
                if not cache.rate_limit_allow(ip, settings.rate_limit_per_minute):
                    refusal_reason = RefusalReason(kind="rate_limited", details={"ip": ip})
                    trace_event("guardrails.block", {"kind": "rate_limited"})
                    _plog("rate_limited", ip=ip, limit_per_minute=settings.rate_limit_per_minute)
                    answer_source = "REFUSAL"
                    # Logar mensagens user e assistant (recusa)
                    log_audit_message("user", req.question)
                    log_audit_message("assistant", REFUSAL_ANSWER)
                    # Logar audit_ask
                    answer_hash_audit = sha256_text(redact_normalize(REFUSAL_ANSWER))
                    latency_total = int((time.perf_counter() - start) * 1000)
                    audit_sink.enqueue_ask(
                        AuditAsk(
                            trace_id=trace_id,
                            request_id=req_id,
                            session_id=session_id,
                            user_id=user_id,
                            question_hash=question_hash_audit,
                            answer_hash=answer_hash_audit,
                            answer_source="REFUSAL",
                            confidence=0.2,
                            refusal_reason=refusal_reason.kind,
                            cache_hit=False,
                            latency_ms=latency_total,
                            abuse_risk_score=abuse_risk_score,
                            abuse_flags_json=flags_to_json(abuse_flags),
                        )
                    )
                    finish_trace("refused", refusal_reason.kind, 0.2, model=None)
                    response = refusal(refusal_reason, confidence=0.2)
                    response.headers["X-Trace-ID"] = trace_id
                    response.headers["X-Answer-Source"] = "REFUSAL"
                    response.headers["X-Chat-Session-ID"] = session_id
                    return response
            except Exception as e:
                # se rate limit falhar, não bloqueia o endpoint
                _plog("rate_limit_error", error=str(e))
                pass

            question = req.question
            firewall = request.app.state.prompt_firewall
            blocked, fw_details = firewall.check(question)
            if blocked:
                rule_id = fw_details.get("rule_id", "unknown")
                category = fw_details.get("category", "INJECTION")
                refusal_reason = RefusalReason(kind="guardrail_firewall", details={"rule_id": rule_id})
                trace_event("guardrails.block", {"kind": "firewall", "rule_id": rule_id, "category": category})
                _plog("guardrail_block", kind="firewall", rule_id=rule_id, category=category)
                answer_source = "REFUSAL"
                log_audit_message("user", req.question)
                log_audit_message("assistant", REFUSAL_ANSWER)
                answer_hash_audit = sha256_text(redact_normalize(REFUSAL_ANSWER))
                latency_total = int((time.perf_counter() - start) * 1000)
                audit_sink.enqueue_ask(
                    AuditAsk(
                        trace_id=trace_id,
                        request_id=req_id,
                        session_id=session_id,
                        user_id=user_id,
                        question_hash=question_hash_audit,
                        answer_hash=answer_hash_audit,
                        answer_source="REFUSAL",
                        confidence=0.2,
                        refusal_reason=refusal_reason.kind,
                        cache_hit=False,
                        latency_ms=latency_total,
                        abuse_risk_score=abuse_risk_score,
                        abuse_flags_json=flags_to_json(abuse_flags),
                    )
                )
                finish_trace("refused", refusal_reason.kind, 0.2, model=None)
                response = refusal(refusal_reason, confidence=0.2)
                response.headers["X-Trace-ID"] = trace_id
                response.headers["X-Answer-Source"] = "REFUSAL"
                response.headers["X-Chat-Session-ID"] = session_id
                return response

            if detect_prompt_injection(question):
                refusal_reason = RefusalReason(kind="guardrail_injection", details={})
                trace_event("guardrails.block", {"kind": "injection"})
                _plog("guardrail_block", kind="injection")
                answer_source = "REFUSAL"
                # Logar mensagens user e assistant (recusa)
                log_audit_message("user", req.question)
                log_audit_message("assistant", REFUSAL_ANSWER)
                # Logar audit_ask
                answer_hash_audit = sha256_text(redact_normalize(REFUSAL_ANSWER))
                latency_total = int((time.perf_counter() - start) * 1000)
                audit_sink.enqueue_ask(
                    AuditAsk(
                        trace_id=trace_id,
                        request_id=req_id,
                        session_id=session_id,
                        user_id=user_id,
                        question_hash=question_hash_audit,
                        answer_hash=answer_hash_audit,
                        answer_source="REFUSAL",
                        confidence=0.2,
                        refusal_reason=refusal_reason.kind,
                        cache_hit=False,
                        latency_ms=latency_total,
                        abuse_risk_score=abuse_risk_score,
                        abuse_flags_json=flags_to_json(abuse_flags),
                    )
                )
                finish_trace("refused", refusal_reason.kind, 0.2, model=None)
                response = refusal(refusal_reason, confidence=0.2)
                response.headers["X-Trace-ID"] = trace_id
                response.headers["X-Answer-Source"] = "REFUSAL"
                response.headers["X-Chat-Session-ID"] = session_id
                return response
            if detect_sensitive_request(question):
                refusal_reason = RefusalReason(kind="guardrail_sensitive", details={})
                trace_event("guardrails.block", {"kind": "sensitive"})
                _plog("guardrail_block", kind="sensitive")
                answer_source = "REFUSAL"
                # Logar mensagens user e assistant (recusa)
                log_audit_message("user", req.question)
                log_audit_message("assistant", REFUSAL_ANSWER)
                # Logar audit_ask
                answer_hash_audit = sha256_text(redact_normalize(REFUSAL_ANSWER))
                latency_total = int((time.perf_counter() - start) * 1000)
                audit_sink.enqueue_ask(
                    AuditAsk(
                        trace_id=trace_id,
                        request_id=req_id,
                        session_id=session_id,
                        user_id=user_id,
                        question_hash=question_hash_audit,
                        answer_hash=answer_hash_audit,
                        answer_source="REFUSAL",
                        confidence=0.2,
                        refusal_reason=refusal_reason.kind,
                        cache_hit=False,
                        latency_ms=latency_total,
                        abuse_risk_score=abuse_risk_score,
                        abuse_flags_json=flags_to_json(abuse_flags),
                    )
                )
                finish_trace("refused", refusal_reason.kind, 0.2, model=None)
                response = refusal(refusal_reason, confidence=0.2)
                response.headers["X-Trace-ID"] = trace_id
                response.headers["X-Answer-Source"] = "REFUSAL"
                response.headers["X-Chat-Session-ID"] = session_id
                return response

            normalized = normalize_question(question)
            key = cache_key_for_question(normalized)
            trace_event("guardrails.check", {"passed": True})
            trace_event("question.normalized", {"question_hash": key})
            _plog("question_normalized", normalized_len=len(normalized), cache_key_prefix=key[:12])

            # Logar mensagem user
            log_audit_message("user", req.question)

            try:
                t0 = time.perf_counter()
                cached = cache.get_json(key)
                cache_ms = int((time.perf_counter() - t0) * 1000)
                trace_event("cache.get", {"hit": bool(cached), "key": key}, duration_ms=cache_ms)
                _plog("cache_checked", latency_ms=cache_ms, hit=bool(cached))
                if cached:
                    cache_hit = True
                    answer_source = "CACHE"
                    CACHE_HIT_COUNT.labels(endpoint=endpoint).inc()
                    REQUEST_COUNT.labels(endpoint=endpoint, status="200").inc()
                    counted = True
                    _plog("cache_hit_return")

                    # Logar mensagem assistant e audit_ask mesmo em cache hit
                    answer_text = str(cached.get("answer", "")) if isinstance(cached, dict) else ""
                    log_audit_message("assistant", answer_text)

                    # Logar audit_ask
                    answer_hash_audit = sha256_text(redact_normalize(answer_text))
                    latency_total = int((time.perf_counter() - start) * 1000)
                    audit_sink.enqueue_ask(
                        AuditAsk(
                            trace_id=trace_id,
                            request_id=req_id,
                            session_id=session_id,
                            user_id=user_id,
                            question_hash=question_hash_audit,
                            answer_hash=answer_hash_audit,
                            answer_source="CACHE",
                            confidence=float(cached.get("confidence")) if isinstance(cached, dict) else None,
                            cache_key=key,
                            cache_hit=True,
                            latency_ms=latency_total,
                            abuse_risk_score=abuse_risk_score,
                            abuse_flags_json=flags_to_json(abuse_flags),
                        )
                    )

                    # Se resposta cacheada inclui sources, logar chunks também
                    if isinstance(cached, dict) and cached.get("sources"):
                        sources = cached.get("sources", [])
                        for rank, source in enumerate(sources[:8], 1):
                            excerpt_text = source.get("excerpt", "")
                            audit_sink.enqueue_chunk(
                                AuditChunk(
                                    trace_id=trace_id,
                                    rank=rank,
                                    document=source.get("document"),
                                    path=source.get("document"),
                                    text_hash=sha256_text(redact_normalize(excerpt_text)),
                                    excerpt_redacted=redact_text(excerpt_text) if settings.audit_log_include_text else None,
                                )
                            )

                    finish_trace("answered", None, float(cached.get("confidence")) if isinstance(cached, dict) else None, None)
                    response = JSONResponse(status_code=200, content=cached)
                    response.headers["X-Trace-ID"] = trace_id
                    response.headers["X-Answer-Source"] = "CACHE"
                    response.headers["X-Chat-Session-ID"] = session_id
                    return response
            except Exception as e:
                # cache é best-effort
                trace_event("cache.error", {"error": str(e)})
                _plog("cache_error", error=str(e))
                pass

            # Retrieval
            try:
                t_embed = time.perf_counter()
                q_vec = (await embedder.embed([normalized]))[0]
                embed_ms = int((time.perf_counter() - t_embed) * 1000)
                _plog(
                    "embedding_done",
                    latency_ms=embed_ms,
                    vector_dim=len(q_vec),
                )
                trace_event("retrieval.embed_query", {"vector_dim": len(q_vec)}, duration_ms=embed_ms)
                t_search = time.perf_counter()
                chunks = await retriever.search(q_vec, top_k=8)
                search_ms = int((time.perf_counter() - t_search) * 1000)
                _plog(
                    "qdrant_search_done",
                    latency_ms=search_ms,
                    top_k=8,
                    returned=len(chunks),
                )
                trace_event("retrieval.qdrant_search", {"top_k": 8, "returned": len(chunks)}, duration_ms=search_ms)
            except Exception as e:
                refusal_reason = RefusalReason(kind="qdrant_unavailable", details={"error": str(e)})
                trace_event("retrieval.error", {"error": str(e)})
                _plog("qdrant_error", error=str(e))
                answer_source = "REFUSAL"
                # Logar mensagem assistant (recusa)
                log_audit_message("assistant", REFUSAL_ANSWER)
                # Logar audit_ask
                answer_hash_audit = sha256_text(redact_normalize(REFUSAL_ANSWER))
                latency_total = int((time.perf_counter() - start) * 1000)
                audit_sink.enqueue_ask(
                    AuditAsk(
                        trace_id=trace_id,
                        request_id=req_id,
                        session_id=session_id,
                        user_id=user_id,
                        question_hash=question_hash_audit,
                        answer_hash=answer_hash_audit,
                        answer_source="REFUSAL",
                        confidence=0.2,
                        refusal_reason=refusal_reason.kind,
                        cache_hit=False,
                        latency_ms=latency_total,
                        abuse_risk_score=abuse_risk_score,
                        abuse_flags_json=flags_to_json(abuse_flags),
                    )
                )
                finish_trace("refused", refusal_reason.kind, 0.2, model=None)
                response = refusal(refusal_reason, confidence=0.2)
                response.headers["X-Trace-ID"] = trace_id
                response.headers["X-Answer-Source"] = "REFUSAL"
                response.headers["X-Chat-Session-ID"] = session_id
                return response

            if not chunks:
                refusal_reason = RefusalReason(kind="no_evidence", details={})
                _plog("no_evidence", stage="retrieval")
                trace_event("retrieval.no_evidence", {})
                answer_source = "REFUSAL"
                # Logar mensagem assistant (recusa)
                log_audit_message("assistant", REFUSAL_ANSWER)
                # Logar audit_ask
                answer_hash_audit = sha256_text(redact_normalize(REFUSAL_ANSWER))
                latency_total = int((time.perf_counter() - start) * 1000)
                audit_sink.enqueue_ask(
                    AuditAsk(
                        trace_id=trace_id,
                        request_id=req_id,
                        session_id=session_id,
                        user_id=user_id,
                        question_hash=question_hash_audit,
                        answer_hash=answer_hash_audit,
                        answer_source="REFUSAL",
                        confidence=0.2,
                        refusal_reason=refusal_reason.kind,
                        cache_hit=False,
                        latency_ms=latency_total,
                        abuse_risk_score=abuse_risk_score,
                        abuse_flags_json=flags_to_json(abuse_flags),
                    )
                )
                finish_trace("refused", refusal_reason.kind, 0.2, model=None)
                response = refusal(refusal_reason, confidence=0.2)
                response.headers["X-Trace-ID"] = trace_id
                response.headers["X-Answer-Source"] = "REFUSAL"
                response.headers["X-Chat-Session-ID"] = session_id
                return response

            selected = select_evidence(chunks, max_tokens=2800)
            # top docs hashados (sem texto)
            top_docs_hashed = [
                {
                    "path": c.path,
                    "doc_type": c.doc_type,
                    "final_score": round(c.final_score, 4),
                    "similarity": round(c.similarity, 4),
                    "trust_score": c.trust_score,
                    "freshness_score": c.freshness_score,
                    "chunk_hash": hash_chunk(c.text),
                }
                for c in selected[:8]
            ]
            trace_event("retrieval.rerank", {"top_docs": top_docs_hashed, "selected": len(selected)})
            _plog("evidence_selected", selected=len(selected), max_tokens=2800)

            # Coletar chunks para enfileirar só depois de audit_ask (evitar FK chunk->ask)
            audit_chunks_collected: list[AuditChunk] = []
            if settings.audit_log_enabled:
                for rank, chunk in enumerate(selected[:8], 1):
                    chunk_text_normalized = redact_normalize(chunk.text)
                    audit_chunks_collected.append(
                        AuditChunk(
                            trace_id=trace_id,
                            rank=rank,
                            document=chunk.title or chunk.path,
                            path=chunk.path,
                            chunk_id=None,  # Não temos chunk_id no RetrievedChunk
                            score_similarity=chunk.similarity,
                            score_trust=chunk.trust_score,
                            score_freshness=chunk.freshness_score,
                            score_final=chunk.final_score,
                            text_hash=sha256_text(chunk_text_normalized),
                            excerpt_redacted=redact_text(excerpt(chunk.text, max_chars=200))
                            if settings.audit_log_include_text
                            else None,
                        )
                    )
            if settings.pipeline_log_include_text:
                _plog(
                    "retrieved_chunks",
                    chunks=[
                        {
                            "path": c.path,
                            "doc_type": c.doc_type,
                            "final_score": round(c.final_score, 4),
                            "similarity": round(c.similarity, 4),
                            "trust_score": c.trust_score,
                            "freshness_score": c.freshness_score,
                            "excerpt": redact_text(excerpt(c.text, max_chars=140)),
                        }
                        for c in selected[:8]
                    ],
                )
            else:
                _plog(
                    "retrieved_chunks",
                    chunks=[
                        {
                            "path": c.path,
                            "doc_type": c.doc_type,
                            "final_score": round(c.final_score, 4),
                            "similarity": round(c.similarity, 4),
                            "trust_score": c.trust_score,
                            "freshness_score": c.freshness_score,
                        }
                        for c in selected[:8]
                    ],
                )
            top_docs = [
                {
                    "path": c.path,
                    "final_score": round(c.final_score, 4),
                    "similarity": round(c.similarity, 4),
                    "trust_score": c.trust_score,
                    "freshness_score": c.freshness_score,
                }
                for c in selected[:5]
            ]

            conflict_initial = detect_conflict([c.text for c in selected[:5]], question=question)
            conflict = conflict_initial
            conflict_penalty = 0.0
            _plog("conflict_checked", has_conflict=conflict_initial.has_conflict, details=conflict_initial.details)
            trace_event("quality.conflict_checked", {"has_conflict": conflict_initial.has_conflict, "details": conflict_initial.details})

            # Resolver conflito por confiança/recência (quando possível)
            if conflict_initial.has_conflict:
                best = max(selected, key=lambda c: (c.trust_score, c.freshness_score, c.final_score))
                _plog(
                    "conflict_resolve_choose_best",
                    path=best.path,
                    doc_type=best.doc_type,
                    trust_score=best.trust_score,
                    freshness_score=best.freshness_score,
                    final_score=round(best.final_score, 4),
                )
                trace_event(
                    "quality.conflict_resolve_choose_best",
                    {
                        "path": best.path,
                        "doc_type": best.doc_type,
                        "trust_score": best.trust_score,
                        "freshness_score": best.freshness_score,
                        "final_score": round(best.final_score, 4),
                        "chunk_hash": hash_chunk(best.text),
                    },
                )
                selected = [best]
                conflict = detect_conflict([best.text], question=question)
                # Penalizar levemente por conflito detectado no retrieval inicial
                conflict_penalty = 0.05
                if conflict.has_conflict:
                    refusal_reason = RefusalReason(kind="conflict_unresolved", details=conflict_initial.details)
                    _plog("conflict_unresolved", details=conflict_initial.details)
                    trace_event("quality.fail", {"kind": "conflict_unresolved", "details": conflict_initial.details})
                    answer_source = "REFUSAL"
                    # Logar mensagem assistant (recusa)
                    log_audit_message("assistant", REFUSAL_ANSWER)
                    # Logar audit_ask
                    answer_hash_audit = sha256_text(redact_normalize(REFUSAL_ANSWER))
                    latency_total = int((time.perf_counter() - start) * 1000)
                    audit_sink.enqueue_ask(
                        AuditAsk(
                            trace_id=trace_id,
                            request_id=req_id,
                            session_id=session_id,
                            user_id=user_id,
                            question_hash=question_hash_audit,
                            answer_hash=answer_hash_audit,
                            answer_source="REFUSAL",
                            confidence=0.2,
                            refusal_reason=refusal_reason.kind,
                            cache_hit=False,
                            latency_ms=latency_total,
                            abuse_risk_score=abuse_risk_score,
                            abuse_flags_json=flags_to_json(abuse_flags),
                        )
                    )
                    for c in audit_chunks_collected:
                        audit_sink.enqueue_chunk(c)
                    audit_chunks_collected.clear()
                    finish_trace("refused", refusal_reason.kind, 0.2, model=None)
                    response = refusal(refusal_reason, confidence=0.2)
                    response.headers["X-Trace-ID"] = trace_id
                    response.headers["X-Answer-Source"] = "REFUSAL"
                    response.headers["X-Chat-Session-ID"] = session_id
                    return response

            evidence_texts = [c.text for c in selected]
            _plog("evidence_compiled", evidence_count=len(evidence_texts))
            trace_event("quality.evaluate", {"evidence_count": len(evidence_texts)})

            # Geração
            llm_hint: float | None = None
            used_indices: list[int] = []
            answer: str = ""
            model_name: str | None = None
            try:
                t_llm = time.perf_counter()
                llm_out = await llm.generate(question=question, evidence=evidence_texts)
                llm_ms = int((time.perf_counter() - t_llm) * 1000)
                model_name = settings.openai_model if settings.openai_api_key else "stub"
                _plog(
                    "llm_done",
                    latency_ms=llm_ms,
                    provider=("openai" if settings.openai_api_key else "stub"),
                )
                trace_event("llm.call", {"called": True, "latency_ms": llm_ms, "model": model_name})
                if llm_out.get("refusal") or not str(llm_out.get("answer") or "").strip():
                    refusal_reason = RefusalReason(kind="no_evidence", details={"llm": "stub_or_refusal"})
                    _plog("llm_refused_or_empty")
                    trace_event("llm.refused_or_empty", {"model": model_name})
                    answer_source = "REFUSAL"
                    # Logar mensagem assistant (recusa)
                    log_audit_message("assistant", REFUSAL_ANSWER)
                    # Logar audit_ask
                    answer_hash_audit = sha256_text(redact_normalize(REFUSAL_ANSWER))
                    latency_total = int((time.perf_counter() - start) * 1000)
                    audit_sink.enqueue_ask(
                        AuditAsk(
                            trace_id=trace_id,
                            request_id=req_id,
                            session_id=session_id,
                            user_id=user_id,
                            question_hash=question_hash_audit,
                            answer_hash=answer_hash_audit,
                            answer_source="REFUSAL",
                            confidence=0.2,
                            refusal_reason=refusal_reason.kind,
                            cache_hit=False,
                            llm_model=model_name,
                            latency_ms=latency_total,
                            abuse_risk_score=abuse_risk_score,
                            abuse_flags_json=flags_to_json(abuse_flags),
                        )
                    )
                    for c in audit_chunks_collected:
                        audit_sink.enqueue_chunk(c)
                    audit_chunks_collected.clear()
                    finish_trace("refused", refusal_reason.kind, 0.2, model=model_name)
                    response = refusal(refusal_reason, confidence=0.2)
                    response.headers["X-Trace-ID"] = trace_id
                    response.headers["X-Answer-Source"] = "REFUSAL"
                    response.headers["X-Chat-Session-ID"] = session_id
                    return response
                answer = str(llm_out.get("answer") or "").strip()
                llm_hint = float(llm_out.get("confidence_hint") or 0.0)
                used_indices = [int(i) for i in (llm_out.get("used_sources_indices") or []) if isinstance(i, int) or str(i).isdigit()]
                _plog(
                    "llm_parsed",
                    answer_len=len(answer),
                    confidence_hint=llm_hint,
                    used_sources_indices=used_indices,
                )
            except Exception as e:
                refusal_reason = RefusalReason(kind="llm_error", details={"error": str(e)})
                _plog("llm_error", error=str(e))
                trace_event("llm.error", {"error": str(e), "model": model_name})
                answer_source = "REFUSAL"
                # Logar mensagem assistant (recusa)
                log_audit_message("assistant", REFUSAL_ANSWER)
                # Logar audit_ask
                answer_hash_audit = sha256_text(redact_normalize(REFUSAL_ANSWER))
                latency_total = int((time.perf_counter() - start) * 1000)
                audit_sink.enqueue_ask(
                    AuditAsk(
                        trace_id=trace_id,
                        request_id=req_id,
                        session_id=session_id,
                        user_id=user_id,
                        question_hash=question_hash_audit,
                        answer_hash=answer_hash_audit,
                        answer_source="REFUSAL",
                        confidence=0.2,
                        refusal_reason=refusal_reason.kind,
                        cache_hit=False,
                        llm_model=model_name,
                        latency_ms=latency_total,
                        abuse_risk_score=abuse_risk_score,
                        abuse_flags_json=flags_to_json(abuse_flags),
                    )
                )
                for c in audit_chunks_collected:
                    audit_sink.enqueue_chunk(c)
                audit_chunks_collected.clear()
                finish_trace("refused", refusal_reason.kind, 0.2, model=model_name)
                response = refusal(refusal_reason, confidence=0.2)
                response.headers["X-Trace-ID"] = trace_id
                response.headers["X-Answer-Source"] = "REFUSAL"
                response.headers["X-Chat-Session-ID"] = session_id
                return response

            # Confidence + qualidade
            sims = [c.similarity for c in selected]
            trusts = [c.trust_score for c in selected]
            doc_types = [c.doc_type for c in selected]
            doc_paths = [c.path for c in selected]
            heuristic = compute_heuristic_confidence(sims, trusts)
            heuristic = max(0.0, heuristic - conflict_penalty)
            confidence = combine_confidence(heuristic, llm_hint, hint_weight=0.30)
            _plog(
                "confidence_computed",
                heuristic=round(heuristic, 4),
                llm_hint=(round(llm_hint, 4) if llm_hint is not None else None),
                conflict_penalty=conflict_penalty,
                final=round(confidence, 4),
            )

            if not quality_threshold(confidence, threshold=0.65):
                refusal_reason = RefusalReason(kind="quality_threshold", details={"confidence": confidence})
                _plog("quality_fail", kind="threshold", confidence=round(confidence, 4))
                trace_event("quality.fail", {"kind": "threshold", "confidence": float(confidence)})
                answer_source = "REFUSAL"
                # Logar mensagem assistant (recusa)
                log_audit_message("assistant", REFUSAL_ANSWER)
                # Logar audit_ask
                answer_hash_audit = sha256_text(redact_normalize(REFUSAL_ANSWER))
                latency_total = int((time.perf_counter() - start) * 1000)
                audit_sink.enqueue_ask(
                    AuditAsk(
                        trace_id=trace_id,
                        request_id=req_id,
                        session_id=session_id,
                        user_id=user_id,
                        question_hash=question_hash_audit,
                        answer_hash=answer_hash_audit,
                        answer_source="REFUSAL",
                        confidence=0.2,
                        refusal_reason=refusal_reason.kind,
                        cache_hit=False,
                        llm_model=model_name,
                        latency_ms=latency_total,
                        abuse_risk_score=abuse_risk_score,
                        abuse_flags_json=flags_to_json(abuse_flags),
                    )
                )
                for c in audit_chunks_collected:
                    audit_sink.enqueue_chunk(c)
                audit_chunks_collected.clear()
                finish_trace("refused", refusal_reason.kind, 0.2, model=model_name)
                response = refusal(refusal_reason, confidence=0.2)
                response.headers["X-Trace-ID"] = trace_id
                response.headers["X-Answer-Source"] = "REFUSAL"
                response.headers["X-Chat-Session-ID"] = session_id
                return response

            if not cross_check_ok(doc_types, doc_paths, trusts, conflict):
                refusal_reason = RefusalReason(kind="quality_crosscheck_failed", details={"doc_types": doc_types})
                _plog("quality_fail", kind="crosscheck", doc_types=doc_types, doc_paths=doc_paths)
                trace_event("quality.fail", {"kind": "crosscheck", "doc_types": doc_types})
                answer_source = "REFUSAL"
                # Logar mensagem assistant (recusa)
                log_audit_message("assistant", REFUSAL_ANSWER)
                # Logar audit_ask
                answer_hash_audit = sha256_text(redact_normalize(REFUSAL_ANSWER))
                latency_total = int((time.perf_counter() - start) * 1000)
                audit_sink.enqueue_ask(
                    AuditAsk(
                        trace_id=trace_id,
                        request_id=req_id,
                        session_id=session_id,
                        user_id=user_id,
                        question_hash=question_hash_audit,
                        answer_hash=answer_hash_audit,
                        answer_source="REFUSAL",
                        confidence=0.2,
                        refusal_reason=refusal_reason.kind,
                        cache_hit=False,
                        llm_model=model_name,
                        latency_ms=latency_total,
                        abuse_risk_score=abuse_risk_score,
                        abuse_flags_json=flags_to_json(abuse_flags),
                    )
                )
                for c in audit_chunks_collected:
                    audit_sink.enqueue_chunk(c)
                audit_chunks_collected.clear()
                finish_trace("refused", refusal_reason.kind, 0.2, model=model_name)
                response = refusal(refusal_reason, confidence=0.2)
                response.headers["X-Trace-ID"] = trace_id
                response.headers["X-Answer-Source"] = "REFUSAL"
                response.headers["X-Chat-Session-ID"] = session_id
                return response

            evidence_concat = "\n\n".join(evidence_texts)
            if not post_validate_answer(answer, evidence_concat):
                refusal_reason = RefusalReason(kind="quality_post_validation_failed", details={})
                _plog("quality_fail", kind="post_validation")
                trace_event("quality.fail", {"kind": "post_validation"})
                answer_source = "REFUSAL"
                # Logar mensagem assistant (recusa)
                log_audit_message("assistant", REFUSAL_ANSWER)
                # Logar audit_ask
                answer_hash_audit = sha256_text(redact_normalize(REFUSAL_ANSWER))
                latency_total = int((time.perf_counter() - start) * 1000)
                audit_sink.enqueue_ask(
                    AuditAsk(
                        trace_id=trace_id,
                        request_id=req_id,
                        session_id=session_id,
                        user_id=user_id,
                        question_hash=question_hash_audit,
                        answer_hash=answer_hash_audit,
                        answer_source="REFUSAL",
                        confidence=0.2,
                        refusal_reason=refusal_reason.kind,
                        cache_hit=False,
                        llm_model=model_name,
                        latency_ms=latency_total,
                        abuse_risk_score=abuse_risk_score,
                        abuse_flags_json=flags_to_json(abuse_flags),
                    )
                )
                for c in audit_chunks_collected:
                    audit_sink.enqueue_chunk(c)
                audit_chunks_collected.clear()
                finish_trace("refused", refusal_reason.kind, 0.2, model=model_name)
                response = refusal(refusal_reason, confidence=0.2)
                response.headers["X-Trace-ID"] = trace_id
                response.headers["X-Answer-Source"] = "REFUSAL"
                response.headers["X-Chat-Session-ID"] = session_id
                return response

            # Sources (apenas as usadas pelo LLM, se vierem; senão, top-1..n)
            if used_indices:
                used = [selected[i] for i in used_indices if 0 <= i < len(selected)]
            else:
                used = selected[: min(3, len(selected))]

            sources = [
                SourceItem(
                    document=u.path or u.title or "documento",
                    excerpt=excerpt_for_question(u.text, question),
                ).model_dump()
                for u in used
            ]
            resp_obj = AskResponse(answer=answer, confidence=float(confidence), sources=sources).model_dump()
            _plog("response_built", confidence=round(float(confidence), 4), sources=len(sources))
            trace_event(
                "response.final",
                {
                    "confidence": float(confidence),
                    "sources": [
                        {"document": s["document"], "excerpt_hash": cache_key_for_excerpt(s["excerpt"])}
                        for s in sources
                    ],
                },
            )

            # Logar mensagem assistant e audit_ask
            answer_source = "LLM"
            log_audit_message("assistant", answer)
            answer_hash_audit = sha256_text(redact_normalize(answer))
            latency_total = int((time.perf_counter() - start) * 1000)
            audit_sink.enqueue_ask(
                AuditAsk(
                    trace_id=trace_id,
                    request_id=req_id,
                    session_id=session_id,
                    user_id=user_id,
                    question_hash=question_hash_audit,
                    answer_hash=answer_hash_audit,
                    answer_source="LLM",
                    confidence=float(confidence),
                    cache_key=key,
                    cache_hit=False,
                    llm_model=model_name,
                    latency_ms=latency_total,
                    abuse_risk_score=abuse_risk_score,
                    abuse_flags_json=flags_to_json(abuse_flags),
                )
            )
            for c in audit_chunks_collected:
                audit_sink.enqueue_chunk(c)
            audit_chunks_collected.clear()

            try:
                t_set = time.perf_counter()
                cache.set_json(key, resp_obj, ttl_seconds=settings.cache_ttl_seconds)
                set_ms = int((time.perf_counter() - t_set) * 1000)
                trace_event("cache.set", {"key": key, "ttl": settings.cache_ttl_seconds}, duration_ms=set_ms)
                _plog("cache_set", latency_ms=set_ms, ttl=settings.cache_ttl_seconds)
            except Exception as e:
                trace_event("cache.set_error", {"error": str(e)})
                _plog("cache_set_error", error=str(e))
                pass

            REQUEST_COUNT.labels(endpoint=endpoint, status="200").inc()
            counted = True
            finish_trace("answered", None, float(confidence), model=model_name)
            response = JSONResponse(status_code=200, content=resp_obj)
            response.headers["X-Trace-ID"] = trace_id
            response.headers["X-Answer-Source"] = "LLM"
            response.headers["X-Chat-Session-ID"] = session_id
            return response
        finally:
            latency = time.perf_counter() - start
            REQUEST_LATENCY.labels(endpoint=endpoint).observe(latency)
            if not counted:
                REQUEST_COUNT.labels(endpoint=endpoint, status="200").inc()
            log.info(
                "ask_done",
                cache_hit=cache_hit,
                top_docs=top_docs,
                refusal_reason=(refusal_reason.model_dump() if refusal_reason else None),
            )
            if not trace_finished:
                finish_trace(
                    "refused" if refusal_reason else "answered",
                    refusal_reason.kind if refusal_reason else None,
                    0.2 if refusal_reason else None,
                    None,
                )

    return app


app = create_app()

