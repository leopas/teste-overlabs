from __future__ import annotations

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=None, extra="ignore")

    qdrant_url: str = "http://qdrant:6333"
    # Para Qdrant SaaS/Cloud (ou instâncias com auth), configure via secret:
    # - Key Vault -> secretRef -> env var QDRANT_API_KEY
    qdrant_api_key: str | None = None
    qdrant_collection: str = "docs_chunks"
    redis_url: str = "redis://redis:6379/0"
    docs_root: str = "/docs"

    cache_ttl_seconds: int = 600
    rate_limit_per_minute: int = 60

    use_openai_embeddings: bool = False
    openai_api_key: str | None = None
    openai_model: str = "gpt-4o-mini"
    openai_embeddings_model: str = "text-embedding-3-small"

    otel_enabled: bool = False
    otel_exporter_otlp_endpoint: str | None = None

    log_level: str = "INFO"

    # Logs detalhados do pipeline do /ask (ativável por env)
    # 0 = desligado; 1 = ligado
    pipeline_log_enabled: bool = False
    # 0 = não loga excerpts/chunks; 1 = loga excerpt curto por chunk
    pipeline_log_include_text: bool = False

    # Auditoria / rastreabilidade
    audit_log_enabled: bool = True
    trace_sink: str = "noop"  # noop|mysql
    audit_log_include_text: bool = True
    audit_log_raw_mode: str = "risk_only"  # off|risk_only|always
    audit_log_raw_max_chars: int = 2000
    audit_log_redact: bool = True
    audit_enc_key_b64: str | None = None
    audit_enc_aad_mode: str = "trace_id"  # trace_id|request_id|none
    abuse_classifier_enabled: bool = True
    abuse_risk_threshold: float = 0.80

    # Prompt Firewall (WAF de prompt)
    prompt_firewall_enabled: bool = False
    prompt_firewall_rules_path: str = "config/prompt_firewall.regex"
    prompt_firewall_max_rules: int = 200
    prompt_firewall_reload_check_seconds: int = 2
    firewall_log_sample_rate: float = 0.01

    # Admin UI/API (Qdrant admin + ingest trigger)
    # IMPORTANTE: como será exposto publicamente, configure via secrets (Key Vault -> secretRef).
    admin_username: str | None = None
    admin_password: str | None = None


settings = Settings()

