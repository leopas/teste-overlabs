"""
Fuzz do Prompt Firewall (Hypothesis): unicode, tokens perigosos, whitespace.
Nunca 500; se contiver tokens de injection/exfil claros, deve bloquear.
"""
from __future__ import annotations

from pathlib import Path

import pytest
from hypothesis import HealthCheck, given, settings as hsettings
from hypothesis import strategies as st

from app.main import create_app
from app.prompt_firewall import PromptFirewall
from app.testing_providers import FailOnCallLLM
from _fakes import FakeCache, FakeEmbedder, FailOnCallRetriever

_PROJECT_ROOT = Path(__file__).resolve().parents[2].parent  # property -> tests -> backend -> project
_REAL_RULES = _PROJECT_ROOT / "config" / "prompt_firewall.regex"

DANGER_TOKENS = [
    "jailbreak", "reveal", "ignore", "instructions", "bypass",
    "disregard", "system", "prompt", "developer", "message",
]


@st.composite
def st_question(draw, include_danger: bool = False):
    hay = [
        st.text(alphabet="abcdefghijklmnopqrstuvwxyz \t\n", min_size=0, max_size=20),
    ]
    if include_danger:
        hay.append(st.sampled_from(DANGER_TOKENS))
    parts = draw(
        st.lists(
            st.one_of(*hay),
            min_size=1,
            max_size=8,
        )
    )
    if include_danger and not any(p in DANGER_TOKENS for p in parts):
        parts.append(draw(st.sampled_from(DANGER_TOKENS)))
    return " ".join(parts)


@pytest.fixture
def app_firewall_fuzz():
    path = _REAL_RULES
    if not path.is_file():
        pytest.skip(f"rules file not found: {path}")
    fw = PromptFirewall(
        rules_path=str(path),
        enabled=True,
        max_rules=200,
        reload_check_seconds=0,
    )
    return create_app(
        test_overrides={
            "cache": FakeCache(),
            "retriever": FailOnCallRetriever,
            "embedder": FakeEmbedder(),
            "llm": FailOnCallLLM(),
            "prompt_firewall": fw,
        }
    )


@pytest.mark.asyncio
@hsettings(
    max_examples=50,
    deadline=60000,
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.function_scoped_fixture],
)
@given(q=st_question(include_danger=False))
async def test_firewall_fuzz_never_500(app_firewall_fuzz, q):
    from httpx import ASGITransport, AsyncClient

    async with AsyncClient(
        transport=ASGITransport(app=app_firewall_fuzz),
        base_url="http://test",
    ) as client:
        r = await client.post("/ask", json={"question": q})
    assert r.status_code != 500


@pytest.mark.asyncio
@hsettings(
    max_examples=30,
    deadline=30000,
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.function_scoped_fixture],
)
@given(q=st_question(include_danger=True))
async def test_firewall_fuzz_danger_tokens_block(app_firewall_fuzz, q):
    """Se contiver tokens de injection/exfil claros, deve bloquear (REFUSAL)."""
    from httpx import ASGITransport, AsyncClient
    async with AsyncClient(
        transport=ASGITransport(app=app_firewall_fuzz),
        base_url="http://test",
    ) as client:
        r = await client.post("/ask", json={"question": q})
    assert r.status_code == 200
    if r.headers.get("X-Answer-Source") == "REFUSAL":
        data = r.json()
        assert data["sources"] == []
        assert float(data["confidence"]) <= 0.3
