from __future__ import annotations

import pytest
from httpx import ASGITransport, AsyncClient


@pytest.mark.prodlike
@pytest.mark.asyncio
async def test_prodlike_cache_hit_via_redis(prodlike_app):
    async with AsyncClient(transport=ASGITransport(app=prodlike_app), base_url="http://test") as client:
        q = {"question": "Qual é o prazo de reembolso?"}
        r1 = await client.post("/ask", json=q)
        assert r1.status_code == 200
        r2 = await client.post("/ask", json=q)
        assert r2.status_code == 200
        assert r1.json() == r2.json()

