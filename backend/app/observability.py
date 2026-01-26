from __future__ import annotations

import json
import logging
import os
import base64
import binascii
import time
import uuid
from contextvars import ContextVar
from typing import Any, Callable

import structlog
from fastapi import Request
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import Response

from .config import settings


request_id_ctx: ContextVar[str | None] = ContextVar("request_id", default=None)
trace_id_ctx: ContextVar[str | None] = ContextVar("trace_id", default=None)
span_id_ctx: ContextVar[str | None] = ContextVar("span_id", default=None)
user_id_ctx: ContextVar[str | None] = ContextVar("user_id", default=None)


def _json_renderer(_: Any, __: Any, event_dict: dict[str, Any]) -> str:
    return json.dumps(event_dict, ensure_ascii=False, separators=(",", ":"))


def configure_logging() -> None:
    level = getattr(logging, settings.log_level.upper(), logging.INFO)
    logging.basicConfig(level=level)

    structlog.configure(
        processors=[
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.contextvars.merge_contextvars,
            structlog.processors.add_log_level,
            structlog.processors.StackInfoRenderer(),
            structlog.processors.format_exc_info,
            _json_renderer,
        ],
        context_class=dict,
        logger_factory=structlog.stdlib.LoggerFactory(),
        wrapper_class=structlog.make_filtering_bound_logger(level),
        cache_logger_on_first_use=True,
    )


class RequestContextMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next: Callable[[Request], Any]) -> Response:
        rid = request.headers.get("X-Request-ID") or str(uuid.uuid4())
        request_id_ctx.set(rid)
        trace_id, span_id = get_trace_ids()
        trace_id_ctx.set(trace_id)
        span_id_ctx.set(span_id)
        user_id = extract_user_id_from_request(request)
        user_id_ctx.set(user_id)

        structlog.contextvars.bind_contextvars(request_id=rid, trace_id=trace_id, span_id=span_id, user_id=user_id)

        start = time.perf_counter()
        try:
            response: Response = await call_next(request)
        finally:
            latency_ms = int((time.perf_counter() - start) * 1000)
            structlog.contextvars.bind_contextvars(latency_ms=latency_ms)

        response.headers["X-Request-ID"] = rid
        response.headers["X-Trace-ID"] = trace_id
        return response


def get_trace_ids() -> tuple[str, str | None]:
    """
    - Se houver span OTel atual válido: retorna trace_id/span_id do span.
    - Caso contrário: gera trace_id UUID4 e span_id None.
    """
    try:
        from opentelemetry import trace

        span = trace.get_current_span()
        ctx = span.get_span_context() if span else None
        if ctx and getattr(ctx, "is_valid", False):
            # trace_id/span_id em hex (fixo)
            return f"{ctx.trace_id:032x}", f"{ctx.span_id:016x}"
    except Exception:
        pass

    return str(uuid.uuid4()), None


def extract_user_id_from_request(request: Request) -> str | None:
    """
    Extrai `user_id` de um JWT (Authorization: Bearer <jwt>) sem validar assinatura.
    - Segurança: isto é apenas auditoria técnica/correlação; não substitui autenticação.
    """
    auth = request.headers.get("Authorization") or ""
    if not auth.lower().startswith("bearer "):
        return None
    token = auth.split(" ", 1)[1].strip()
    parts = token.split(".")
    if len(parts) < 2:
        return None
    payload_b64 = parts[1]
    # base64url padding
    pad = "=" * (-len(payload_b64) % 4)
    payload_b64 += pad
    try:
        raw = base64.urlsafe_b64decode(payload_b64.encode("utf-8"))
    except (binascii.Error, ValueError):
        return None
    try:
        payload = json.loads(raw.decode("utf-8"))
    except Exception:
        return None
    uid = payload.get("user_id")
    if uid is None:
        return None
    return str(uid)


def configure_otel() -> None:
    if not settings.otel_enabled:
        return
    try:
        from opentelemetry import trace
        from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
        from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
        from opentelemetry.sdk.resources import Resource
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor
    except Exception:
        # Não quebrar se libs não estiverem disponíveis
        return

    endpoint = settings.otel_exporter_otlp_endpoint or os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT") or ""
    if not endpoint:
        # Sem endpoint, não quebra
        return

    provider = TracerProvider(resource=Resource.create({"service.name": "mvp-rag-api"}))
    processor = BatchSpanProcessor(OTLPSpanExporter(endpoint=endpoint))
    provider.add_span_processor(processor)
    trace.set_tracer_provider(provider)

    # Instrumentações serão aplicadas pelo main.py (FastAPI) quando app existir.
    HTTPXClientInstrumentor().instrument()

