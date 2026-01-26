from __future__ import annotations

import pytest

from _fakes import FakeCache, FakeEmbedder, FakeRetriever
from app.main import create_app
from app.testing_providers import LocalDeterministicLLM
from httpx import ASGITransport, AsyncClient


@pytest.mark.asyncio
async def test_cache_hit_skips_retrieval_and_llm(evidence_high_conf_policy):
    cache = FakeCache()
    retriever = FakeRetriever(chunks=evidence_high_conf_policy)
    embedder = FakeEmbedder()

    class SpyLLM(LocalDeterministicLLM):
        def __init__(self):
            self.calls = 0

        async def generate(self, question, evidence):
            self.calls += 1
            return await super().generate(question, evidence)

    llm = SpyLLM()
    app = create_app(test_overrides={"cache": cache, "retriever": retriever, "embedder": embedder, "llm": llm})
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        q = {"question": "Qual o prazo para reembolso de despesas nacionais?"}
        r1 = await c.post("/ask", json=q)
        assert r1.status_code == 200
        assert retriever.calls == 1
        assert llm.calls == 1

        r2 = await c.post("/ask", json=q)
        assert r2.status_code == 200
        assert retriever.calls == 1  # não incrementou
        assert llm.calls == 1  # não incrementou
        assert r1.json() == r2.json()


@pytest.mark.asyncio
async def test_cache_ttl_expire_recomputes(evidence_high_conf_policy):
    now = 1_700_000_000.0

    def clock():
        return now

    cache = FakeCache(now=clock)
    retriever = FakeRetriever(chunks=evidence_high_conf_policy)
    embedder = FakeEmbedder()
    llm = LocalDeterministicLLM()
    app = create_app(test_overrides={"cache": cache, "retriever": retriever, "embedder": embedder, "llm": llm})

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        q = {"question": "Qual o prazo para reembolso de despesas nacionais?"}
        r1 = await c.post("/ask", json=q)
        assert r1.status_code == 200
        assert retriever.calls == 1

        # avança tempo além do TTL padrão (600s)
        now += 601
        r2 = await c.post("/ask", json=q)
        assert r2.status_code == 200
        assert retriever.calls == 2

