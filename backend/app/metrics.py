from __future__ import annotations

from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest
from starlette.responses import Response


REQUEST_COUNT = Counter("request_count", "Total de requests", ["endpoint", "status"])
CACHE_HIT_COUNT = Counter("cache_hit_count", "Total de cache hits", ["endpoint"])
REFUSAL_COUNT = Counter("refusal_count", "Total de recusas", ["reason"])
LLM_ERRORS = Counter("llm_errors", "Erros de LLM", ["kind"])
REQUEST_LATENCY = Histogram("request_latency_seconds", "Latência por endpoint", ["endpoint"])

# Prompt Firewall
FIREWALL_RULES_LOADED = Gauge("firewall_rules_loaded", "Número de regras válidas carregadas")
FIREWALL_RELOAD_TOTAL = Counter("firewall_reload_total", "Quantas vezes recarregou")
FIREWALL_RELOAD_DURATION = Histogram(
    "firewall_reload_duration_seconds",
    "Latência do reload de regras (parsing + compilação)",
)
FIREWALL_INVALID_RULE_TOTAL = Counter("firewall_invalid_rule_total", "Regras inválidas ignoradas")
FIREWALL_CHECKS_TOTAL = Counter("firewall_checks_total", "Número de checks")
FIREWALL_BLOCK_TOTAL = Counter("firewall_block_total", "Número de bloqueios")
FIREWALL_CHECK_DURATION = Histogram(
    "firewall_check_duration_seconds",
    "Latência total do check() do firewall (inclui reload se necessário)",
)


def metrics_response() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

