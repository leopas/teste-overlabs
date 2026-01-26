from __future__ import annotations

import pytest
from httpx import ASGITransport, AsyncClient


@pytest.mark.prodlike
@pytest.mark.asyncio
async def test_prodlike_ingest_and_ask(prodlike_app):
    async with AsyncClient(transport=ASGITransport(app=prodlike_app), base_url="http://test") as client:
        r = await client.post("/ask", json={"question": "Qual é o prazo de reembolso?"})
        assert r.status_code == 200
        data = r.json()
        assert data["sources"]
        assert 0.0 <= float(data["confidence"]) <= 1.0
        assert float(data["confidence"]) >= 0.65
        assert "100" in data["answer"]
        # fontes devem apontar para policy/faq
        assert any("policy" in s["document"] or "faq" in s["document"] for s in data["sources"])

