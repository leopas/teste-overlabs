from __future__ import annotations

import re

import pytest


@pytest.mark.asyncio
async def test_ask_returns_200_and_schema_on_success(client):
    r = await client.post("/ask", json={"question": "Qual o prazo para reembolso de despesas nacionais?"})
    assert r.status_code == 200
    assert "X-Trace-ID" in r.headers
    assert r.headers["X-Trace-ID"]
    data = r.json()
    assert set(data.keys()) == {"answer", "confidence", "sources"}
    assert isinstance(data["answer"], str)
    assert isinstance(data["confidence"], (int, float))
    assert 0.0 <= float(data["confidence"]) <= 1.0
    assert isinstance(data["sources"], list)
    assert len(data["sources"]) >= 1
    for s in data["sources"]:
        assert set(s.keys()) == {"document", "excerpt"}
        assert isinstance(s["document"], str)
        assert isinstance(s["excerpt"], str)
        assert len(s["excerpt"]) <= 240


@pytest.mark.asyncio
async def test_ask_returns_200_and_schema_on_refusal(client, app_test):
    # substitui retriever para retornar vazio
    class EmptyRetriever:
        def ready(self):
            return True

        async def search(self, vector, top_k=8):
            return []

    app_test.state.retriever = EmptyRetriever()

    r = await client.post("/ask", json={"question": "Qual o prazo para reembolso?"})
    assert r.status_code == 200
    assert "X-Trace-ID" in r.headers
    assert r.headers["X-Trace-ID"]
    data = r.json()
    assert set(data.keys()) == {"answer", "confidence", "sources"}
    assert data["sources"] == []
    assert float(data["confidence"]) <= 0.3


@pytest.mark.asyncio
async def test_question_validation_min_max(client):
    r = await client.post("/ask", json={"question": "oi"})
    assert r.status_code == 422

    long_q = "a" * 2001
    r2 = await client.post("/ask", json={"question": long_q})
    assert r2.status_code == 422

    r3 = await client.post("/ask", json={"question": "abc\u0001def"})
    assert r3.status_code == 422

