from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any, Callable

from app.retrieval import RetrievedChunk


@dataclass
class FakeCache:
    now: Callable[[], float] = time.time
    store: dict[str, tuple[float, Any]] = field(default_factory=dict)  # key -> (expires_at, value)
    get_calls: int = 0
    set_calls: int = 0
    rate_calls: int = 0

    def ping(self) -> bool:
        return True

    def get_json(self, key: str) -> Any | None:
        self.get_calls += 1
        item = self.store.get(key)
        if not item:
            return None
        exp, val = item
        if exp and self.now() > exp:
            self.store.pop(key, None)
            return None
        return val

    def set_json(self, key: str, value: Any, ttl_seconds: int) -> None:
        self.set_calls += 1
        exp = self.now() + ttl_seconds if ttl_seconds > 0 else 0.0
        self.store[key] = (exp, value)

    def rate_limit_allow(self, ip: str, limit_per_minute: int) -> bool:
        self.rate_calls += 1
        return True


@dataclass
class FakeEmbedder:
    dim: int = 8
    calls: int = 0

    async def embed(self, texts: list[str]) -> list[list[float]]:
        self.calls += 1
        return [[0.0] * self.dim for _ in texts]


@dataclass
class FakeRetriever:
    chunks: list[RetrievedChunk]
    calls: int = 0
    raise_on_search: Exception | None = None

    def ready(self) -> bool:
        return True

    async def search(self, vector: list[float], top_k: int = 8) -> list[RetrievedChunk]:
        self.calls += 1
        if self.raise_on_search:
            raise self.raise_on_search
        return self.chunks[:top_k]


def make_chunk(
    *,
    text: str,
    path: str = "doc.txt",
    doc_type: str = "POLICY",
    trust_score: float = 0.9,
    freshness_score: float = 1.0,
    similarity: float = 0.9,
    final_score: float | None = None,
) -> RetrievedChunk:
    if final_score is None:
        final_score = 0.55 * similarity + 0.30 * trust_score + 0.15 * freshness_score
    return RetrievedChunk(
        text=text,
        title="title",
        path=path,
        doc_type=doc_type,
        updated_at=0.0,
        trust_score=trust_score,
        freshness_score=freshness_score,
        similarity=similarity,
        final_score=final_score,
    )

