from __future__ import annotations

import pytest

from app.testing_providers import LocalDeterministicLLM

from _fakes import FakeEmbedder, FakeRetriever


@pytest.mark.asyncio
async def test_threshold_refusal_when_confidence_below_065(client, app_test, evidence_low_similarity):
    app_test.state.retriever = FakeRetriever(chunks=evidence_low_similarity)
    app_test.state.llm = LocalDeterministicLLM()
    r = await client.post("/ask", json={"question": "Qual o prazo para reembolso?"})
    assert r.status_code == 200
    data = r.json()
    assert data["sources"] == []
    assert float(data["confidence"]) <= 0.3


@pytest.mark.asyncio
async def test_single_policy_high_trust_allows_answer(client, app_test, evidence_high_conf_policy):
    app_test.state.retriever = FakeRetriever(chunks=evidence_high_conf_policy)
    app_test.state.llm = LocalDeterministicLLM()
    r = await client.post("/ask", json={"question": "Qual o prazo para reembolso de despesas nacionais?"})
    data = r.json()
    assert data["sources"]
    assert float(data["confidence"]) >= 0.65


@pytest.mark.asyncio
async def test_cross_check_two_sources_agree_allows_answer(client, app_test, evidence_two_sources_agree):
    app_test.state.retriever = FakeRetriever(chunks=evidence_two_sources_agree)
    app_test.state.llm = LocalDeterministicLLM()
    r = await client.post("/ask", json={"question": "Qual o prazo para reembolso de despesas nacionais?"})
    data = r.json()
    assert data["sources"]
    assert float(data["confidence"]) >= 0.65


@pytest.mark.asyncio
async def test_conflict_resolved_by_trust_score_prefers_policy(client, app_test, evidence_conflict):
    # Conflito (30 vs 100). A pergunta não especifica escopo; o pipeline deve escolher POLICY (trust maior).
    app_test.state.retriever = FakeRetriever(chunks=evidence_conflict)
    app_test.state.llm = LocalDeterministicLLM()
    r = await client.post("/ask", json={"question": "Qual o prazo para reembolso?"})
    data = r.json()
    assert data["sources"]
    assert "policy_new.txt" in data["sources"][0]["document"]
    assert "30" not in data["answer"]


@pytest.mark.asyncio
async def test_post_validator_rejects_unbacked_numbers(client, app_test, evidence_high_conf_policy):
    # LLM tenta inventar um número
    class BadLLM:
        async def generate(self, question, evidence):
            return {"answer": "O prazo é 45 dias.", "confidence_hint": 0.9, "used_sources_indices": [0]}

    app_test.state.retriever = FakeRetriever(chunks=evidence_high_conf_policy)
    app_test.state.llm = BadLLM()

    r = await client.post("/ask", json={"question": "Qual o prazo para reembolso de despesas nacionais?"})
    data = r.json()
    assert data["sources"] == []
    assert float(data["confidence"]) <= 0.3

