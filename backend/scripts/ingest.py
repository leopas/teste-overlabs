from __future__ import annotations

import hashlib
import os
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable

from qdrant_client import QdrantClient
from qdrant_client.http import models as qm

# Permite executar como `python scripts/ingest.py` dentro do container,
# onde o pacote `app` está em `/app/app`.
_APP_ROOT = Path(__file__).resolve().parents[1]
if str(_APP_ROOT) not in sys.path:
    sys.path.insert(0, str(_APP_ROOT))

from app.config import settings
from app.retrieval import estimate_tokens, get_embeddings_provider
from app.security import contains_cpf

# Configurar logging para aparecer nos logs
import logging
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] [%(levelname)s] %(name)s: %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
    stream=sys.stderr
)

DOCS_ROOT = Path(os.getenv("DOCS_ROOT", "/docs"))

HEADING_SPLIT_RE = re.compile(r"^(#{1,6}\s+.+|[A-ZÁÉÍÓÚÂÊÔÃÕÇ0-9][A-ZÁÉÍÓÚÂÊÔÃÕÇ0-9 ]{5,}|={3,}|-{3,})\s*$")
FAQ_Q_RE = re.compile(r"(?i)^\s*(pergunta|q)\s*:\s*(.+)$")
FAQ_A_RE = re.compile(r"(?i)^\s*(resposta|a)\s*:\s*(.+)$")


@dataclass(frozen=True)
class DocMeta:
    doc_id: str
    title: str
    rel_path: str
    updated_at: float
    doc_type: str
    trust_score: float
    freshness_score: float


def iter_files(root: Path) -> Iterable[Path]:
    for p in root.rglob("*"):
        if p.is_file():
            yield p


def read_text(p: Path) -> str:
    for enc in ("utf-8", "utf-8-sig", "cp1252", "latin-1"):
        try:
            return p.read_text(encoding=enc, errors="strict")
        except Exception:
            continue
    return p.read_text(encoding="utf-8", errors="replace")


def hash_str(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def detect_title(text: str, filename: str) -> str:
    for line in text.splitlines()[:30]:
        l = line.strip()
        if not l:
            continue
        if l.startswith("#"):
            return l.lstrip("#").strip()
        if len(l) >= 6 and l.isupper():
            return l
        # padrão comum: "Política de X"
        if l.lower().startswith(("política", "politica", "manual")):
            return l
    return Path(filename).stem


def classify_doc_type(path: str) -> str:
    p = path.lower()
    if "policy" in p or "politica" in p or "política" in p:
        return "POLICY"
    if "manual" in p:
        return "MANUAL"
    if "faq" in p:
        return "FAQ"
    if "procedimento" in p or "processo" in p:
        return "PROCESS"
    return "GENERAL"


def trust_for_doc_type(doc_type: str) -> float:
    dt = doc_type.upper()
    if dt in {"POLICY", "MANUAL"}:
        return 0.9
    if dt == "PROCESS":
        return 0.8
    if dt == "FAQ":
        return 0.7
    return 0.6


def compute_freshness_scores(mtimes: list[float]) -> dict[float, float]:
    if not mtimes:
        return {}
    mn = min(mtimes)
    mx = max(mtimes)
    if mx - mn < 1.0:
        return {m: 1.0 for m in mtimes}
    out: dict[float, float] = {}
    for m in mtimes:
        out[m] = (m - mn) / (mx - mn)
    return out


def split_faq(text: str, title: str) -> list[str]:
    chunks: list[str] = []
    q: str | None = None
    a_lines: list[str] = []

    def flush() -> None:
        nonlocal q, a_lines
        if q and a_lines:
            qa = f"{title}\nPergunta: {q}\nResposta: {' '.join(a_lines).strip()}"
            chunks.append(qa.strip())
        q = None
        a_lines = []

    for line in text.splitlines():
        m_q = FAQ_Q_RE.match(line)
        if m_q:
            flush()
            q = m_q.group(2).strip()
            continue
        m_a = FAQ_A_RE.match(line)
        if m_a:
            a_lines.append(m_a.group(2).strip())
            continue
        if q and line.strip():
            # continuação de resposta
            a_lines.append(line.strip())

    flush()
    return chunks


def split_by_headings(text: str, title: str) -> list[tuple[str, str]]:
    # retorna lista de (section_title, section_text)
    sections: list[tuple[str, list[str]]] = []
    current_title = title
    buf: list[str] = []

    def flush() -> None:
        nonlocal buf, current_title
        if buf:
            sections.append((current_title, buf))
        buf = []

    for line in text.splitlines():
        if HEADING_SPLIT_RE.match(line.strip()):
            flush()
            h = line.strip()
            if h.startswith("#"):
                current_title = h.lstrip("#").strip()
            elif h and not set(h) <= {"=", "-"}:
                current_title = h
            continue
        buf.append(line)
    flush()
    out: list[tuple[str, str]] = []
    for st, lines in sections:
        body = "\n".join(lines).strip()
        if body:
            out.append((st, body))
    return out


def chunk_sections(sections: list[tuple[str, str]], target_tokens: int = 650, overlap_tokens: int = 120) -> list[str]:
    # chunking linear com overlap por tokens aproximados
    chunks: list[str] = []
    for sec_title, sec_body in sections:
        pref = f"Título/Seção: {sec_title}\n\n"
        text = pref + sec_body.strip()
        if estimate_tokens(text) <= target_tokens:
            chunks.append(text)
            continue

        # quebrar por parágrafos
        paras = [p.strip() for p in re.split(r"\n\s*\n", sec_body) if p.strip()]
        current: list[str] = []
        cur_tokens = 0

        def flush_with_overlap() -> None:
            nonlocal current, cur_tokens
            if not current:
                return
            chunk_text = pref + "\n\n".join(current).strip()
            chunks.append(chunk_text)
            # overlap: manter o fim do chunk atual
            if overlap_tokens <= 0:
                current = []
                cur_tokens = 0
                return
            tail: list[str] = []
            tail_tokens = 0
            for para in reversed(current):
                t = estimate_tokens(para)
                if tail_tokens + t > overlap_tokens:
                    break
                tail.insert(0, para)
                tail_tokens += t
            current = tail
            cur_tokens = sum(estimate_tokens(p) for p in current)

        for para in paras:
            t = estimate_tokens(para)
            if current and cur_tokens + t > target_tokens:
                flush_with_overlap()
            current.append(para)
            cur_tokens += t

        if current:
            chunk_text = pref + "\n\n".join(current).strip()
            chunks.append(chunk_text)

    return chunks


async def main() -> int:
    if not DOCS_ROOT.exists():
        print(f"[ingest] DOCS_ROOT não existe: {DOCS_ROOT}", file=sys.stderr)
        return 2

    # Descobrir mtimes para freshness
    files = list(iter_files(DOCS_ROOT))
    mtimes = [p.stat().st_mtime for p in files]
    freshness_by_mtime = compute_freshness_scores(mtimes)

    logger = logging.getLogger(__name__)
    
    # Log da chave OpenAI ANTES de criar o embedder
    print(f"[ingest] Verificando configuração OpenAI...", file=sys.stderr)
    print(f"[ingest] USE_OPENAI_EMBEDDINGS={settings.use_openai_embeddings}", file=sys.stderr)
    if settings.openai_api_key:
        key_preview = settings.openai_api_key[:10] if len(settings.openai_api_key) >= 10 else settings.openai_api_key
        key_length = len(settings.openai_api_key)
        print(f"[ingest] OPENAI_API_KEY: preview='{key_preview}...', tamanho={key_length} caracteres", file=sys.stderr)
        logger.info(f"OpenAI API Key no settings: preview='{key_preview}...', tamanho={key_length} caracteres")
    else:
        print(f"[ingest] OPENAI_API_KEY esta vazia ou None!", file=sys.stderr)
        logger.warning("OpenAI API Key esta vazia ou None no settings!")
    
    embedder = get_embeddings_provider()
    print(f"[ingest] Embedder criado: {type(embedder).__name__}", file=sys.stderr)
    
    # Log do Qdrant URL (não é segredo; essencial para debug de rede no ACA)
    print(f"[ingest] QDRANT_URL={settings.qdrant_url}", file=sys.stderr)
    qdrant = QdrantClient(url=settings.qdrant_url, api_key=settings.qdrant_api_key, timeout=30.0)

    indexed = 0
    ignored = []

    # Preparar coleção (descobrir dim via embedding de teste)
    print("[ingest] Testando embedding (isso vai mostrar logs da chave OpenAI)...", file=sys.stderr)
    test_vec = (await embedder.embed(["dim probe"]))[0]
    dim = len(test_vec)
    collection_name = settings.qdrant_collection
    try:
        qdrant.get_collection(collection_name)
    except Exception as e:
        print(f"[ingest] get_collection falhou (vai tentar create_collection): {e!r}", file=sys.stderr)
        qdrant.create_collection(
            collection_name=collection_name,
            vectors_config=qm.VectorParams(size=dim, distance=qm.Distance.COSINE),
        )

    for p in files:
        rel = str(p.relative_to(DOCS_ROOT)).replace("\\", "/")
        ext = p.suffix.lower()

        if ext not in {".txt", ".md"}:
            ignored.append((rel, f"extensão {ext} (ignorado por padrão)"))
            continue

        if "funcionarios" in rel.lower():
            ignored.append((rel, "R1: arquivo de funcionários/PII (ignorado)"))
            continue

        text = read_text(p)
        if contains_cpf(text):
            ignored.append((rel, "R1: contém CPF/PII (ignorado)"))
            continue

        st = p.stat()
        doc_id = hash_str(rel)
        title = detect_title(text, p.name)
        updated_at = float(st.st_mtime)
        doc_type = classify_doc_type(rel)
        trust_score = trust_for_doc_type(doc_type)
        freshness_score = float(freshness_by_mtime.get(updated_at, 0.0))

        meta = DocMeta(
            doc_id=doc_id,
            title=title,
            rel_path=rel,
            updated_at=updated_at,
            doc_type=doc_type,
            trust_score=trust_score,
            freshness_score=freshness_score,
        )

        # Chunking (FAQ vs headings)
        if doc_type == "FAQ":
            faq_chunks = split_faq(text, title=meta.title)
            sections = [(meta.title, c) for c in faq_chunks] if faq_chunks else split_by_headings(text, title=meta.title)
        else:
            sections = split_by_headings(text, title=meta.title)

        chunk_texts = chunk_sections(sections, target_tokens=650, overlap_tokens=120)
        if not chunk_texts:
            ignored.append((rel, "arquivo vazio após normalização"))
            continue

        vectors = await embedder.embed(chunk_texts)
        points: list[qm.PointStruct] = []
        for idx, (chunk, vec) in enumerate(zip(chunk_texts, vectors)):
            point_id = hash_str(f"{meta.doc_id}:{idx}")[:32]
            payload = {
                "doc_id": meta.doc_id,
                "title": meta.title,
                "path": meta.rel_path,
                "updated_at": meta.updated_at,
                "doc_type": meta.doc_type,
                "trust_score": meta.trust_score,
                "freshness_score": meta.freshness_score,
                "chunk_index": idx,
                "text": chunk,
            }
            points.append(qm.PointStruct(id=point_id, vector=vec, payload=payload))

        qdrant.upsert(collection_name=collection_name, points=points)
        indexed += len(points)
        print(f"[ingest] upsert {len(points)} chunks: {rel} ({meta.doc_type})")

    print(f"\n[ingest] concluído: {indexed} chunks indexados em '{collection_name}'")
    if ignored:
        print("\n[ingest] ignorados:")
        for rel, why in ignored:
            print(f"- {rel}: {why}")
    return 0


if __name__ == "__main__":
    import asyncio

    raise SystemExit(asyncio.run(main()))

