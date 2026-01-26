from __future__ import annotations

import pytest
from httpx import ASGITransport, AsyncClient


@pytest.mark.prodlike
@pytest.mark.asyncio
async def test_prodlike_conflict_resolution_prefers_policy(prodlike_app):
    async with AsyncClient(transport=ASGITransport(app=prodlike_app), base_url="http://test") as client:
        r = await client.post("/ask", json={"question": "Qual é o prazo de reembolso?"})
        assert r.status_code == 200
        data = r.json()
        assert data["sources"]
        # deve preferir 100 (policy) e não ecoar 30
        assert "100" in data["answer"]
        assert "30" not in data["answer"]
        assert "policy_reembolso_v3" in data["sources"][0]["document"]

