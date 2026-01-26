from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient

# Forçar que o import `app.*` aponte para ESTE repo (evita colisão com outros projetos no PYTHONPATH)
_BACKEND_ROOT = Path(__file__).resolve().parents[1]  # .../backend
sys.path.insert(0, str(_BACKEND_ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))  # .../backend/tests
for mod in list(sys.modules.keys()):
    if mod == "app" or mod.startswith("app."):
        sys.modules.pop(mod, None)

from app.config import settings  # noqa: E402
from app.main import create_app  # noqa: E402
from app.retrieval import RetrievedChunk  # noqa: E402
from app.testing_providers import FailOnCallLLM, LocalDeterministicLLM  # noqa: E402
from _fakes import FakeCache, FakeEmbedder, FakeRetriever, make_chunk  # noqa: E402


@pytest.fixture
def evidence_high_conf_policy() -> list[RetrievedChunk]:
    return [
        make_chunk(
            text="Título/Seção: Política\nO prazo para reembolso de despesas nacionais é de até 10 dias corridos.",
            path="policy_reembolso.txt",
            doc_type="POLICY",
            trust_score=0.9,
            similarity=0.9,
        )
    ]


@pytest.fixture
def evidence_two_sources_agree() -> list[RetrievedChunk]:
    return [
        make_chunk(
            text="Título/Seção: Política\nO prazo para reembolso de despesas nacionais é de até 10 dias corridos.",
            path="policy_v3.txt",
            doc_type="POLICY",
            trust_score=0.9,
            similarity=0.85,
        ),
        make_chunk(
            text="Título/Seção: FAQ\nPergunta: prazo nacional?\nResposta: até 10 dias corridos.",
            path="faq.txt",
            doc_type="FAQ",
            trust_score=0.7,
            similarity=0.82,
        ),
    ]


@pytest.fixture
def evidence_conflict() -> list[RetrievedChunk]:
    return [
        make_chunk(
            text="Título/Seção: Geral\nO prazo para reembolso é de 30 dias.",
            path="general_old.txt",
            doc_type="GENERAL",
            trust_score=0.6,
            similarity=0.9,
        ),
        make_chunk(
            text="Título/Seção: Política\nO prazo para reembolso é de 100 dias.",
            path="policy_new.txt",
            doc_type="POLICY",
            trust_score=0.9,
            similarity=0.88,
        ),
    ]


@pytest.fixture
def evidence_low_similarity() -> list[RetrievedChunk]:
    return [
        make_chunk(
            text="Título/Seção: Política\nRegras gerais sem prazo claro.",
            path="policy.txt",
            doc_type="POLICY",
            trust_score=0.9,
            similarity=0.1,
        )
    ]


@pytest.fixture
async def app_test(evidence_high_conf_policy: list[RetrievedChunk]) -> Any:
    # habilita logs de pipeline para testes que capturam logs
    settings.pipeline_log_enabled = True
    settings.pipeline_log_include_text = False
    cache = FakeCache()
    retriever = FakeRetriever(chunks=evidence_high_conf_policy)
    embedder = FakeEmbedder()
    llm = LocalDeterministicLLM()
    return create_app(test_overrides={"cache": cache, "retriever": retriever, "embedder": embedder, "llm": llm})


@pytest.fixture
async def client(app_test: Any) -> AsyncClient:
    transport = ASGITransport(app=app_test)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


@pytest.fixture
def fail_llm() -> FailOnCallLLM:
    return FailOnCallLLM()

