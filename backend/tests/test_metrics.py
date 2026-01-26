from __future__ import annotations

import pytest


@pytest.mark.asyncio
async def test_metrics_endpoint_exists(client):
    r = await client.get("/metrics")
    assert r.status_code == 200
    body = r.text
    assert "request_count" in body
    assert "refusal_count" in body
    assert "cache_hit_count" in body


@pytest.mark.asyncio
async def test_metrics_increment_on_ask(client):
    # chama /ask (deve incrementar request_count)
    await client.post("/ask", json={"question": "Qual o prazo para reembolso de despesas nacionais?"})
    r = await client.get("/metrics")
    body = r.text
    assert "request_count" in body

