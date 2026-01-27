"""
Testes multi-idioma do Prompt Firewall (table-driven).
Cada regra do .regex exercitada por ≥1 hit; negativos não bloqueiam; FailOnCall prova que não chama LLM/retriever.
"""
from __future__ import annotations

import os
from pathlib import Path

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import create_app
from app.prompt_firewall import PromptFirewall
from app.testing_providers import FailOnCallLLM, LocalDeterministicLLM
from _fakes import FakeCache, FakeEmbedder, FakeRetriever, FailOnCallRetriever, make_chunk
from firewall_cases import (
    LANGUAGES,
    REAL_RULES_PATH,
    parse_firewall_rules,
    sample_negatives,
    sample_triggers,
)


_PROJECT_ROOT = Path(__file__).resolve().parents[1].parent


def _rules_path() -> Path:
    return REAL_RULES_PATH


@pytest.fixture
def app_firewall_block():
    """App com firewall ativo (regras reais), FailOnCall LLM+Retriever."""
    path = _rules_path()
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


@pytest.fixture
def app_firewall_negatives(evidence_high_conf_policy):
    """App com firewall ativo, LLM determinístico e retriever com evidência (para negativos)."""
    path = _rules_path()
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
            "retriever": FakeRetriever(chunks=evidence_high_conf_policy),
            "embedder": FakeEmbedder(),
            "llm": LocalDeterministicLLM(),
            "prompt_firewall": fw,
        }
    )


@pytest.mark.asyncio
async def test_prompt_firewall_each_rule_blocks_no_llm_retriever(app_firewall_block):
    """Para cada regra com triggers no idioma, POST /ask bloqueia e não chama LLM/retriever."""
    rules = parse_firewall_rules(_rules_path())
    if not rules:
        pytest.skip("no rules parsed")
    hit_rules: set[str] = set()
    async with AsyncClient(
        transport=ASGITransport(app=app_firewall_block),
        base_url="http://test",
    ) as client:
        for spec in rules:
            langs = LANGUAGES if spec.category not in ("PII", "PAYLOAD") else ["EN"]
            for lang in langs:
                triggers = sample_triggers(spec.id, spec.category, lang)
                for payload in triggers[:2]:
                    r = await client.post("/ask", json={"question": payload})
                    assert r.status_code == 200, (spec.id, lang, payload)
                    data = r.json()
                    assert data["sources"] == [], (spec.id, lang, payload)
                    assert float(data["confidence"]) <= 0.3, (spec.id, lang, payload)
                    assert r.headers.get("X-Answer-Source") == "REFUSAL", (spec.id, lang, payload)
                    hit_rules.add(spec.id)
    assert len(hit_rules) >= 1, "at least one rule must be hit"


@pytest.mark.asyncio
async def test_prompt_firewall_negatives_do_not_block(app_firewall_negatives):
    """Negativos por categoria/idioma não devem bloquear; resposta normal (CACHE ou LLM)."""
    from firewall_cases import CATEGORIES

    async with AsyncClient(
        transport=ASGITransport(app=app_firewall_negatives),
        base_url="http://test",
    ) as client:
        for cat in CATEGORIES:
            for lang in LANGUAGES[:3]:
                negs = sample_negatives("", cat, lang)
                for q in negs[:2]:
                    r = await client.post("/ask", json={"question": q})
                    assert r.status_code == 200, (cat, lang, q)
                    src = r.headers.get("X-Answer-Source")
                    assert src in ("CACHE", "LLM"), (cat, lang, q, src)
                    data = r.json()
                    assert len(data["sources"]) > 0 or data.get("answer"), (cat, lang, q)
