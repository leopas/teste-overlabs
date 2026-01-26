from __future__ import annotations

import os
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator

import pytest
import redis as redis_lib
from qdrant_client import QdrantClient
from qdrant_client.http.exceptions import UnexpectedResponse

from app.retrieval import RetrievedChunk
from app.testing_providers import LocalDeterministicLLM, create_embedder_from_env


QDRANT_HOST = os.getenv("QDRANT_URL", "http://localhost:6336")
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6380/0")


def _compose_test_cmd() -> list[str]:
    return ["docker", "compose", "-f", str(Path(__file__).resolve().parents[3] / "docker-compose.test.yml")]


@pytest.fixture(scope="session")
def prodlike_services() -> Iterator[None]:
    # sobe qdrant+redis para os testes prodlike
    env = os.environ.copy()
    env["COMPOSE_PROJECT_NAME"] = env.get("COMPOSE_PROJECT_NAME", "ragtest")
    subprocess.run(_compose_test_cmd() + ["up", "-d"], check=True, env=env)

    # espera qdrant responder
    deadline = time.time() + 30
    while time.time() < deadline:
        try:
            c = QdrantClient(url=QDRANT_HOST, timeout=2.0)
            c.get_collections()
            break
        except Exception:
            time.sleep(0.5)
    else:
        raise RuntimeError("Qdrant não subiu a tempo")

    # espera redis responder
    deadline = time.time() + 20
    while time.time() < deadline:
        try:
            r = redis_lib.Redis.from_url(REDIS_URL, socket_connect_timeout=1.0, socket_timeout=1.0)
            r.ping()
            break
        except Exception:
            time.sleep(0.5)
    else:
        raise RuntimeError("Redis não subiu a tempo")

    yield

    subprocess.run(_compose_test_cmd() + ["down", "-v"], check=False, env=env)


@pytest.fixture
def collection_name() -> str:
    return f"test_chunks_{uuid.uuid4().hex[:8]}"


@pytest.fixture
def qdrant_client() -> QdrantClient:
    return QdrantClient(url=QDRANT_HOST, timeout=10.0)


@pytest.fixture
def redis_client():
    return redis_lib.Redis.from_url(REDIS_URL, socket_connect_timeout=1.0, socket_timeout=1.0)


@dataclass
class ProdRedisCache:
    redis: Any

    def ping(self) -> bool:
        return bool(self.redis.ping())

    def get_json(self, key: str):
        import json

        raw = self.redis.get(key)
        if raw is None:
            return None
        return json.loads(raw)

    def set_json(self, key: str, value: Any, ttl_seconds: int) -> None:
        import json

        self.redis.setex(key, ttl_seconds, json.dumps(value, ensure_ascii=False))

    def rate_limit_allow(self, ip: str, limit_per_minute: int) -> bool:
        # desabilita rate-limit nos prodlike (não é o foco aqui)
        return True


@dataclass
class ProdQdrantRetriever:
    qdrant: QdrantClient
    collection: str

    def ready(self) -> bool:
        try:
            self.qdrant.get_collections()
            return True
        except Exception:
            return False

    async def search(self, vector: list[float], top_k: int = 8) -> list[RetrievedChunk]:
        try:
            res = self.qdrant.query_points(
                collection_name=self.collection,
                query=vector,
                limit=top_k,
                with_payload=True,
            )
            points = getattr(res, "points", res)
        except UnexpectedResponse as e:
            if getattr(e, "status_code", None) == 404:
                return []
            raise

        chunks: list[RetrievedChunk] = []
        for p in points:
            payload = p.payload or {}
            text = str(payload.get("text") or "")
            title = str(payload.get("title") or "")
            path = str(payload.get("path") or "")
            doc_type = str(payload.get("doc_type") or "GENERAL")
            updated_at = float(payload.get("updated_at") or 0.0)
            trust_score = float(payload.get("trust_score") or 0.0)
            freshness_score = float(payload.get("freshness_score") or 0.0)
            similarity = float(getattr(p, "score", 0.0) or 0.0)
            if similarity < 0.0:
                similarity = (similarity + 1.0) / 2.0
            final_score = 0.55 * similarity + 0.30 * trust_score + 0.15 * freshness_score
            chunks.append(
                RetrievedChunk(
                    text=text,
                    title=title,
                    path=path,
                    doc_type=doc_type,
                    updated_at=updated_at,
                    trust_score=trust_score,
                    freshness_score=freshness_score,
                    similarity=similarity,
                    final_score=final_score,
                )
            )
        chunks.sort(key=lambda c: c.final_score, reverse=True)
        return chunks


def write_synth_docs(root: Path) -> None:
    (root / "policy_reembolso_v3.txt").write_text(
        "Política de Reembolso v3\\nData: 10/12/2025\\n\\nO prazo de reembolso é de até 100 dias.\\n",
        encoding="utf-8",
    )
    (root / "general_antigo.txt").write_text(
        "Comunicado antigo\\n\\nO prazo de reembolso é de 30 dias.\\n",
        encoding="utf-8",
    )
    (root / "faq_reembolso.txt").write_text(
        "Pergunta: Qual o prazo de reembolso?\\nResposta: O prazo é de 100 dias.\\n",
        encoding="utf-8",
    )
    (root / "manual.txt").write_text(
        "Manual Operacional\\n\\nComo enviar recibos: siga o procedimento.\\n",
        encoding="utf-8",
    )
    (root / "sensivel.txt").write_text(
        "Nome: Fulano\\nCPF: 123.456.789-00\\n",
        encoding="utf-8",
    )


def run_ingest(tmp_docs: Path, collection: str) -> None:
    env = os.environ.copy()
    env["DOCS_ROOT"] = str(tmp_docs)
    env["QDRANT_URL"] = QDRANT_HOST
    env["QDRANT_COLLECTION"] = collection
    # respeita embedder do ambiente (inclui USE_OPENAI_EMBEDDINGS / OPENAI_API_KEY)
    subprocess.run(
        [sys.executable, str(Path(__file__).resolve().parents[2] / "scripts" / "ingest.py")],
        check=True,
        env=env,
        cwd=str(Path(__file__).resolve().parents[2]),
    )


@pytest.fixture
def prodlike_app(prodlike_services, qdrant_client: QdrantClient, redis_client, collection_name: str, tmp_path: Path):
    # prepara docs + ingest real em coleção única
    write_synth_docs(tmp_path)
    run_ingest(tmp_path, collection=collection_name)

    # cria app com overrides: retriever/cache/embedder reais e LLM local determinística
    from app.main import create_app

    app = create_app(
        test_overrides={
            "cache": ProdRedisCache(redis_client),
            "retriever": ProdQdrantRetriever(qdrant_client, collection=collection_name),
            "embedder": create_embedder_from_env(),
            "llm": LocalDeterministicLLM(),
        }
    )

    yield app

    # teardown: delete collection para não sujar
    try:
        qdrant_client.delete_collection(collection_name)
    except Exception:
        pass

