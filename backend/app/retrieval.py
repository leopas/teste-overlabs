from __future__ import annotations

import logging
import math
import re
import socket
import sys
import time
import traceback
import urllib.parse
from dataclasses import dataclass
from typing import Any

import httpx
from qdrant_client import QdrantClient
from qdrant_client.http.exceptions import UnexpectedResponse

from .config import settings


COLLECTION_NAME = "docs_chunks"  # legado (mantido), mas use settings.qdrant_collection


@dataclass(frozen=True)
class RetrievedChunk:
    text: str
    title: str
    path: str
    doc_type: str
    updated_at: float
    trust_score: float
    freshness_score: float
    similarity: float
    final_score: float


class EmbeddingsProvider:
    async def embed(self, texts: list[str]) -> list[list[float]]:
        raise NotImplementedError


class FastEmbedEmbeddings(EmbeddingsProvider):
    """
    Embeddings locais via FastEmbed (ONNX), evitando Torch/CUDA no container.
    Modelo default: sentence-transformers/all-MiniLM-L6-v2 (384 dims).
    """

    def __init__(self, model_name: str = "sentence-transformers/all-MiniLM-L6-v2") -> None:
        self._model_name = model_name
        self._model = None

    def _load(self) -> Any:
        if self._model is None:
            from fastembed import TextEmbedding

            self._model = TextEmbedding(model_name=self._model_name)
        return self._model

    async def embed(self, texts: list[str]) -> list[list[float]]:
        model = self._load()
        # FastEmbed retorna um gerador de vetores (iterável)
        vectors = list(model.embed(texts))
        # cada item é np.ndarray-like; converter para list[float]
        return [v.tolist() for v in vectors]


class OpenAIEmbeddings(EmbeddingsProvider):
    def __init__(self, api_key: str) -> None:
        self._api_key = api_key
        self._client = httpx.AsyncClient(timeout=15.0)
        # Log da chave para debug (apenas primeiros 10 caracteres e tamanho)
        import logging
        import sys
        logger = logging.getLogger(__name__)
        key_preview = api_key[:10] if api_key and len(api_key) >= 10 else (api_key or "None")
        key_length = len(api_key) if api_key else 0
        log_msg = f"[OpenAIEmbeddings.__init__] API Key: preview='{key_preview}...', tamanho={key_length} caracteres"
        print(log_msg, file=sys.stderr)
        logger.info(log_msg)

    async def embed(self, texts: list[str]) -> list[list[float]]:
        # Log da chave antes de cada chamada (apenas primeiros 10 caracteres e tamanho)
        import logging
        import sys
        logger = logging.getLogger(__name__)
        key_preview = self._api_key[:10] if self._api_key and len(self._api_key) >= 10 else (self._api_key or "None")
        key_length = len(self._api_key) if self._api_key else 0
        log_msg = f"[OpenAIEmbeddings.embed] API Key antes da chamada: preview='{key_preview}...', tamanho={key_length} caracteres"
        print(log_msg, file=sys.stderr)
        logger.info(log_msg)
        
        headers = {"Authorization": f"Bearer {self._api_key}"}
        payload = {"model": settings.openai_embeddings_model, "input": texts}
        r = await self._client.post("https://api.openai.com/v1/embeddings", json=payload, headers=headers)
        r.raise_for_status()
        data = r.json()
        return [item["embedding"] for item in data["data"]]


def get_embeddings_provider() -> EmbeddingsProvider:
    if settings.use_openai_embeddings and settings.openai_api_key:
        return OpenAIEmbeddings(settings.openai_api_key)
    return FastEmbedEmbeddings()


def get_current_embedding_model_name() -> str:
    if settings.use_openai_embeddings and settings.openai_api_key:
        return settings.openai_embeddings_model
    return "sentence-transformers/all-MiniLM-L6-v2"


_QDRANT_READY_LAST_LOG_AT = 0.0
_QDRANT_READY_LOG_INTERVAL_SECONDS = 30.0
_QDRANT_URL_WARNED_ONCE = False


class QdrantStore:
    def __init__(self) -> None:
        global _QDRANT_URL_WARNED_ONCE
        # Guardrail (informativo): em ACA com ingress HTTP, usar ":6333" quase sempre é errado.
        # Mantém compatibilidade, mas ajuda a diagnosticar configuração incorreta.
        if not _QDRANT_URL_WARNED_ONCE:
            try:
                url = settings.qdrant_url
                parsed = urllib.parse.urlparse(url)
                host = parsed.hostname or ""
                port = parsed.port
                if port == 6333 and ".internal." not in host:
                    _QDRANT_URL_WARNED_ONCE = True
                    warn = (
                        "[qdrant_url_guardrail] "
                        f"QDRANT_URL={url!r} parece usar :6333 sem FQDN internal. "
                        "Em ACA com ingress HTTP, prefira https://<qdrant_ingress_fqdn> (sem :6333)."
                    )
                    print(warn, file=sys.stderr)
                    logging.getLogger(__name__).warning(warn)
            except Exception:
                pass
        self._client = QdrantClient(url=settings.qdrant_url, timeout=2.0)

    def ready(self) -> bool:
        global _QDRANT_READY_LAST_LOG_AT
        try:
            self._client.get_collections()
            return True
        except Exception as e:
            # Log detalhado (throttled) para diagnosticar DNS/porta/TLS no ACA.
            now = time.time()
            if now - _QDRANT_READY_LAST_LOG_AT >= _QDRANT_READY_LOG_INTERVAL_SECONDS:
                _QDRANT_READY_LAST_LOG_AT = now
                logger = logging.getLogger(__name__)
                url = settings.qdrant_url
                parsed = urllib.parse.urlparse(url)
                host = parsed.hostname or ""
                scheme = parsed.scheme or ""
                port = parsed.port or (443 if scheme == "https" else 80)

                dns_ok = False
                dns_ip = None
                tcp_ok = False
                tcp_err = None

                try:
                    infos = socket.getaddrinfo(host, port)
                    dns_ip = infos[0][4][0] if infos else None
                    dns_ok = True
                except Exception as de:
                    dns_ok = False
                    tcp_err = f"dns_error={de!r}"

                if dns_ok:
                    try:
                        s = socket.create_connection((host, port), timeout=2.5)
                        s.close()
                        tcp_ok = True
                    except Exception as te:
                        tcp_ok = False
                        tcp_err = f"tcp_error={te!r}"

                # IMPORTANTe: o logger padrão do Uvicorn geralmente não imprime "extra".
                # Então também imprimimos uma linha explícita no stderr (vai para Log Stream do ACA).
                tb = traceback.format_exc()
                msg = (
                    "[qdrant_ready_failed] "
                    f"qdrant_url={url!r} scheme={scheme!r} host={host!r} port={port} "
                    f"dns_ok={dns_ok} dns_ip={dns_ip!r} tcp_ok={tcp_ok} net_err={tcp_err!r} "
                    f"error_type={type(e).__name__} error={e!r} "
                    f"endpoint_hint={url.rstrip('/') + '/collections'!r}"
                )
                print(msg, file=sys.stderr)
                print(tb, file=sys.stderr)
                logger.warning(msg)
            return False

    async def search(self, vector: list[float], top_k: int = 8) -> list[RetrievedChunk]:
        # usar filtro None por padrão
        try:
            # qdrant-client >= 1.16 usa query_points
            query_res = self._client.query_points(
                collection_name=settings.qdrant_collection,
                query=vector,
                limit=top_k,
                with_payload=True,
            )
            results = getattr(query_res, "points", query_res)
        except UnexpectedResponse as e:
            # coleção ainda não criada / não indexada
            if getattr(e, "status_code", None) == 404:
                return []
            raise
        chunks: list[RetrievedChunk] = []
        for p in results:
            payload = p.payload or {}
            text = str(payload.get("text") or "")
            title = str(payload.get("title") or "")
            path = str(payload.get("path") or "")
            doc_type = str(payload.get("doc_type") or "GENERAL")
            updated_at = float(payload.get("updated_at") or 0.0)
            trust_score = float(payload.get("trust_score") or 0.0)
            freshness_score = float(payload.get("freshness_score") or 0.0)

            similarity = float(p.score or 0.0)
            # Normalização defensiva se vier em [-1,1]
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


def estimate_tokens(text: str) -> int:
    # Aproximação grosseira: 1 token ~ 4 chars
    return int(math.ceil(len(text) / 4.0))


def select_evidence(chunks: list[RetrievedChunk], max_tokens: int = 2800) -> list[RetrievedChunk]:
    selected: list[RetrievedChunk] = []
    used = 0
    for c in chunks:
        t = estimate_tokens(c.text)
        if selected and used + t > max_tokens:
            break
        selected.append(c)
        used += t
    return selected


def excerpt(text: str, max_chars: int = 240) -> str:
    s = " ".join(text.strip().split())
    if len(s) <= max_chars:
        return s
    return s[: max_chars - 1] + "…"


_NATIONAL_RE = re.compile(r"(?i)\bnacion(?:al|ais)\b")
_INTERNATIONAL_RE = re.compile(r"(?i)\binternacion(?:al|ais)\b")
_DAYS_RE = re.compile(r"(?i)\b\d+\s*(?:dia|dias)\b")


def excerpt_for_question(text: str, question: str, max_chars: int = 240) -> str:
    """
    Excerpt mais objetivo: tenta recortar apenas sentenças relevantes ao escopo/termos da pergunta.
    """
    q = question.lower()
    want_national = bool(_NATIONAL_RE.search(q))
    want_international = bool(_INTERNATIONAL_RE.search(q))

    # remove prefixo de metadata comum da ingestão
    cleaned_lines: list[str] = []
    for line in text.splitlines():
        l = line.strip()
        if not l:
            continue
        if l.lower().startswith("título/seção:"):
            continue
        cleaned_lines.append(l)
    cleaned = " ".join(cleaned_lines)

    # split simples em sentenças
    raw_sentences = [s.strip() for s in re.split(r"[.\n]+", cleaned) if s.strip()]

    # se pergunta define escopo, filtrar sentenças por escopo
    scoped: list[str] = []
    if want_national and not want_international:
        scoped = [s for s in raw_sentences if _NATIONAL_RE.search(s)]
    elif want_international and not want_national:
        scoped = [s for s in raw_sentences if _INTERNATIONAL_RE.search(s)]
    else:
        scoped = raw_sentences

    # score por overlap simples de palavras (sem stopwords) + bônus por conter número/dias
    tokens = [t for t in re.findall(r"[a-zA-ZÀ-ÿ0-9]+", q) if len(t) >= 4]
    stop = {"qual", "quais", "prazo", "prazo", "para", "como", "quando", "onde", "sobre", "despesas", "reembolso"}
    tokens = [t for t in tokens if t not in stop]

    def score(s: str) -> int:
        s_l = s.lower()
        sc = 0
        for t in tokens:
            if t in s_l:
                sc += 2
        if _DAYS_RE.search(s):
            sc += 3
        return sc

    ranked = sorted(scoped, key=score, reverse=True)
    # pegar 1-2 sentenças no máximo, até max_chars
    out_parts: list[str] = []
    used = 0
    for s in ranked[:3]:
        if not s:
            continue
        # evita incluir frase do escopo "oposto" quando pergunta é específica
        if want_national and not want_international and _INTERNATIONAL_RE.search(s):
            continue
        if want_international and not want_national and _NATIONAL_RE.search(s):
            continue
        if out_parts and (used + 2 + len(s)) > max_chars:
            break
        out_parts.append(s)
        used += len(s) + 1
        if used >= max_chars:
            break

    if out_parts:
        out = ". ".join(out_parts).strip()
        if not out.endswith("."):
            out += "."
        return excerpt(out, max_chars=max_chars)

    # fallback
    return excerpt(cleaned, max_chars=max_chars)

