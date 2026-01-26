from __future__ import annotations

import pytest

from app.main import create_app
from app.testing_providers import LocalDeterministicLLM
from httpx import ASGITransport, AsyncClient

from _fakes import FakeCache, FakeEmbedder, FakeRetriever


@pytest.mark.asyncio
async def test_llm_timeout_graceful_refusal(evidence_high_conf_policy):
    class TimeoutLLM:
        async def generate(self, question, evidence):
            raise TimeoutError("timeout")

    app = create_app(
        test_overrides={
            "cache": FakeCache(),
            "retriever": FakeRetriever(chunks=evidence_high_conf_policy),
            "embedder": FakeEmbedder(),
            "llm": TimeoutLLM(),
        }
    )
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        r = await c.post("/ask", json={"question": "Qual o prazo para reembolso?"})
        assert r.status_code == 200
        data = r.json()
        assert data["sources"] == []


@pytest.mark.asyncio
async def test_qdrant_down_graceful_refusal(evidence_high_conf_policy):
    retriever = FakeRetriever(chunks=evidence_high_conf_policy, raise_on_search=RuntimeError("qdrant down"))
    app = create_app(
        test_overrides={
            "cache": FakeCache(),
            "retriever": retriever,
            "embedder": FakeEmbedder(),
            "llm": LocalDeterministicLLM(),
        }
    )
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        r = await c.post("/ask", json={"question": "Qual o prazo para reembolso?"})
        assert r.status_code == 200
        assert r.json()["sources"] == []


@pytest.mark.asyncio
async def test_redis_down_does_not_break(evidence_high_conf_policy):
    class FlakyCache(FakeCache):
        def get_json(self, key):
            raise RuntimeError("redis down")

        def set_json(self, key, value, ttl_seconds):
            raise RuntimeError("redis down")

    app = create_app(
        test_overrides={
            "cache": FlakyCache(),
            "retriever": FakeRetriever(chunks=evidence_high_conf_policy),
            "embedder": FakeEmbedder(),
            "llm": LocalDeterministicLLM(),
        }
    )
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        r = await c.post("/ask", json={"question": "Qual o prazo para reembolso de despesas nacionais?"})
        assert r.status_code == 200
        data = r.json()
        # Mesmo sem cache, deve conseguir responder
        assert data["sources"]

