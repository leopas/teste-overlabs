from __future__ import annotations

import pytest
from hypothesis import HealthCheck, given, settings as hsettings
from hypothesis import strategies as st


@pytest.mark.asyncio
@hsettings(max_examples=80, suppress_health_check=[HealthCheck.too_slow, HealthCheck.function_scoped_fixture])
@given(
    st.text(
        min_size=3,
        max_size=2000,
        alphabet=st.characters(blacklist_categories=("Cs",)),  # evita surrogate inválido
    )
)
async def test_fuzz_question_never_500(client, text):
    r = await client.post("/ask", json={"question": text})
    assert r.status_code in (200, 422)
    if r.status_code == 200:
        data = r.json()
        assert set(data.keys()) == {"answer", "confidence", "sources"}
        assert 0.0 <= float(data["confidence"]) <= 1.0
        assert isinstance(data["sources"], list)
        if data["sources"] == []:
            # recusa
            assert float(data["confidence"]) <= 0.3

