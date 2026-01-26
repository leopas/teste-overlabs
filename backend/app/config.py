from __future__ import annotations

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=None, extra="ignore")

    qdrant_url: str = "http://qdrant:6333"
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


settings = Settings()

