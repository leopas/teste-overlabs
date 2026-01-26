from __future__ import annotations

from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from starlette.responses import Response


REQUEST_COUNT = Counter("request_count", "Total de requests", ["endpoint", "status"])
CACHE_HIT_COUNT = Counter("cache_hit_count", "Total de cache hits", ["endpoint"])
REFUSAL_COUNT = Counter("refusal_count", "Total de recusas", ["reason"])
LLM_ERRORS = Counter("llm_errors", "Erros de LLM", ["kind"])
REQUEST_LATENCY = Histogram("request_latency_seconds", "Latência por endpoint", ["endpoint"])


def metrics_response() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

