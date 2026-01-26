from __future__ import annotations

import pytest
from hypothesis import HealthCheck, given, settings as hsettings
from hypothesis import strategies as st

from app.testing_providers import FailOnCallLLM


TOKENS = ["ignore", "instructions", "system", "developer", "reveal", "prompt", "jailbreak", "bypass"]


@pytest.mark.asyncio
@hsettings(max_examples=80, suppress_health_check=[HealthCheck.too_slow, HealthCheck.function_scoped_fixture])
@given(st.lists(st.sampled_from(TOKENS), min_size=2, max_size=6))
async def test_fuzz_injection_never_calls_llm(app_test, client, tokens):
    app_test.state.llm = FailOnCallLLM()
    q = " ".join(tokens)
    r = await client.post("/ask", json={"question": q})
    assert r.status_code == 200
    data = r.json()
    # se detector pegar, deve recusar
    if data["sources"] == []:
        assert float(data["confidence"]) <= 0.3

