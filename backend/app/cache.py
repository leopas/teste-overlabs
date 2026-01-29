from __future__ import annotations

import hashlib
import json
from typing import Any

import redis

from .config import settings


def cache_key_for_question(normalized_question: str) -> str:
    return hashlib.sha256(normalized_question.encode("utf-8")).hexdigest()


def cache_key_for_excerpt(excerpt_text: str) -> str:
    """
    Hash estável para excerpts (audit/log). Não use para autenticação/segurança.
    """
    return hashlib.sha256(excerpt_text.encode("utf-8")).hexdigest()


class RedisClient:
    def __init__(self) -> None:
        # Em ACA, 1s pode ser agressivo e causar falsos timeouts (especialmente em cold start).
        self._client = redis.Redis.from_url(
            settings.redis_url,
            socket_connect_timeout=5.0,
            socket_timeout=5.0,
            retry_on_timeout=True,
            health_check_interval=30,
        )

    def ping(self) -> bool:
        return bool(self._client.ping())

    def get_json(self, key: str) -> Any | None:
        raw = self._client.get(key)
        if raw is None:
            return None
        return json.loads(raw)

    def set_json(self, key: str, value: Any, ttl_seconds: int) -> None:
        self._client.setex(key, ttl_seconds, json.dumps(value, ensure_ascii=False))

    def rate_limit_allow(self, ip: str, limit_per_minute: int) -> bool:
        # Janela fixa por minuto para simplicidade
        # key: rl:<ip>:<epochMinute>
        import time

        epoch_min = int(time.time() // 60)
        key = f"rl:{ip}:{epoch_min}"
        pipe = self._client.pipeline()
        pipe.incr(key, 1)
        pipe.expire(key, 70)
        count, _ = pipe.execute()
        return int(count) <= int(limit_per_minute)

    def raw(self) -> redis.Redis:
        """
        Acesso ao client raw para casos avançados (admin/jobs).
        """
        return self._client
