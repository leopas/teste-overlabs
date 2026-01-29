#!/usr/bin/env python3
"""
Script de ingestão de produção para Qdrant com logs detalhados.
Pode ser executado via: python -m scripts.ingest_prod [opções]
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import logging
import os
import re
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable

from qdrant_client import QdrantClient
from qdrant_client.http import models as qm

# Permite executar como `python scripts/ingest_prod.py` dentro do container
_APP_ROOT = Path(__file__).resolve().parents[1]
if str(_APP_ROOT) not in sys.path:
    sys.path.insert(0, str(_APP_ROOT))

from app.config import settings
from app.retrieval import estimate_tokens, get_embeddings_provider
from app.security import contains_cpf

# Configurar logging estruturado
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)

DOCS_ROOT = Path(os.getenv("DOCS_ROOT", "/app/DOC-IA"))

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
    """Itera sobre todos os arquivos no diretório raiz."""
    for p in root.rglob("*"):
        if p.is_file():
            yield p


def read_text(p: Path) -> str:
    """Lê arquivo com detecção de encoding."""
    for enc in ["utf-8", "latin-1"]:
        try:
            return p.read_text(encoding=enc)
        except UnicodeDecodeError:
            continue
    raise ValueError(f"Não foi possível decodificar {p}")


def hash_str(s: str) -> str:
    """Gera hash SHA256 de uma string."""
    return hashlib.sha256(s.encode()).hexdigest()


def detect_title(text: str, filename: str) -> str:
    """Detecta título do documento."""
    lines = text.strip().split("\n")
    for line in lines[:10]:
        line = line.strip()
        if line and not line.startswith("#"):
            if len(line) < 100:
                return line
    return filename.replace(".txt", "").replace(".md", "")


def classify_doc_type(rel_path: str) -> str:
    """Classifica tipo de documento baseado no caminho."""
    rel_lower = rel_path.lower()
    if "faq" in rel_lower or "pergunta" in rel_lower:
        return "FAQ"
    elif "manual" in rel_lower:
        return "Manual"
    elif "politica" in rel_lower or "política" in rel_lower:
        return "Política"
    elif "procedimento" in rel_lower:
        return "Procedimento"
    elif "comunicado" in rel_lower:
        return "Comunicado"
    else:
        return "Documento"


def trust_for_doc_type(doc_type: str) -> float:
    """Retorna score de confiança baseado no tipo."""
    trust_map = {
        "Política": 0.95,
        "Manual": 0.90,
        "Procedimento": 0.85,
        "FAQ": 0.80,
        "Comunicado": 0.75,
        "Documento": 0.70,
    }
    return trust_map.get(doc_type, 0.70)


def compute_freshness_scores(mtimes: list[float]) -> dict[float, float]:
    """Calcula scores de frescor baseado em mtimes."""
    if not mtimes:
        return {}
    max_mtime = max(mtimes)
    min_mtime = min(mtimes)
    if max_mtime == min_mtime:
        return {m: 1.0 for m in mtimes}
    return {m: (m - min_mtime) / (max_mtime - min_mtime) for m in mtimes}


def split_faq(text: str, title: str = "") -> list[str]:
    """Extrai pares pergunta-resposta de FAQ."""
    chunks = []
    current_q = None
    current_a = []
    for line in text.split("\n"):
        q_match = FAQ_Q_RE.match(line)
        a_match = FAQ_A_RE.match(line)
        if q_match:
            if current_q and current_a:
                chunks.append(f"{current_q}\n{chr(10).join(current_a)}")
            current_q = q_match.group(2).strip()
            current_a = []
        elif a_match:
            current_a.append(a_match.group(2).strip())
        elif current_a:
            current_a.append(line.strip())
    if current_q and current_a:
        chunks.append(f"{current_q}\n{chr(10).join(current_a)}")
    return chunks if chunks else []


def split_by_headings(text: str, title: str = "") -> list[tuple[str, str]]:
    """Divide texto em seções baseado em headings."""
    sections = []
    current_heading = title
    current_lines = []
    for line in text.split("\n"):
        if HEADING_SPLIT_RE.match(line.strip()):
            if current_lines:
                sections.append((current_heading, "\n".join(current_lines).strip()))
            current_heading = line.strip().lstrip("#").strip()
            current_lines = []
        else:
            current_lines.append(line)
    if current_lines:
        sections.append((current_heading, "\n".join(current_lines).strip()))
    return sections


def chunk_sections(sections: list[tuple[str, str]], target_tokens: int = 650, overlap_tokens: int = 120) -> list[str]:
    """Divide seções em chunks com overlap."""
    chunks = []
    for heading, content in sections:
        pref = f"# {heading}\n\n" if heading else ""
        paras = [p.strip() for p in content.split("\n\n") if p.strip()]
        current: list[str] = []
        cur_tokens = 0

        def flush_with_overlap():
            nonlocal current, cur_tokens
            if not current:
                return
            chunk_text = pref + "\n\n".join(current).strip()
            chunks.append(chunk_text)
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


async def truncate_collection(qdrant: QdrantClient, collection_name: str, verbose: bool = False) -> int:
    """Trunca a collection, removendo todos os pontos."""
    logger.info(f"Truncando collection '{collection_name}'...")
    try:
        info = qdrant.get_collection(collection_name)
        total_points = info.points_count
        logger.info(f"Collection existe com {total_points} pontos")
        
        if total_points == 0:
            logger.info("Collection já está vazia")
            return 0
        
        all_ids = []
        offset = None
        while True:
            result = qdrant.scroll(
                collection_name=collection_name,
                limit=1000,
                offset=offset,
                with_payload=False,
                with_vectors=False
            )
            points, next_offset = result
            if not points:
                break
            all_ids.extend([p.id for p in points])
            if next_offset is None:
                break
            offset = next_offset
        
        logger.info(f"Deletando {len(all_ids)} pontos em lotes de 1000...")
        deleted = 0
        for i in range(0, len(all_ids), 1000):
            batch = all_ids[i:i+1000]
            qdrant.delete(
                collection_name=collection_name,
                points_selector=qm.PointIdsList(points=batch)
            )
            deleted += len(batch)
            if verbose:
                logger.info(f"  Deletados {deleted}/{len(all_ids)} pontos...")
        
        logger.info(f"✓ Collection truncada: {len(all_ids)} pontos removidos")
        return len(all_ids)
    except Exception as e:
        if "404" in str(e) or "not found" in str(e).lower():
            logger.warning("Collection não existe. Será criada durante a ingestão.")
            return 0
        else:
            logger.error(f"Erro ao truncar collection: {e}", exc_info=True)
            raise


async def main() -> int:
    """Função principal de ingestão."""
    parser = argparse.ArgumentParser(description="Ingestão de documentos para Qdrant (produção)")
    parser.add_argument("--truncate", action="store_true", help="Truncar collection antes de ingerir")
    parser.add_argument("--verbose", "-v", action="store_true", help="Logs verbosos")
    parser.add_argument("--docs-root", type=str, help="Diretório raiz dos documentos (override DOCS_ROOT env)")
    args = parser.parse_args()
    
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    
    docs_root = Path(args.docs_root) if args.docs_root else DOCS_ROOT
    
    logger.info("=" * 60)
    logger.info("INGESTÃO DE DOCUMENTOS PARA QDRANT (PRODUÇÃO)")
    logger.info("=" * 60)
    logger.info(f"DOCS_ROOT: {docs_root}")
    logger.info(f"QDRANT_URL: {settings.qdrant_url}")
    logger.info(f"Collection: {settings.qdrant_collection}")
    logger.info(f"Embeddings: {'OpenAI' if settings.use_openai_embeddings else 'FastEmbed'}")
    logger.info("")
    
    if not docs_root.exists():
        logger.error(f"DOCS_ROOT não existe: {docs_root}")
        return 2
    
    start_time = time.time()
    
    # Descobrir arquivos
    logger.info("Descobrindo arquivos...")
    files = list(iter_files(docs_root))
    logger.info(f"Encontrados {len(files)} arquivo(s)")
    
    if not files:
        logger.warning("Nenhum arquivo encontrado para ingestão!")
        return 1
    
    # Calcular freshness scores
    mtimes = [p.stat().st_mtime for p in files]
    freshness_by_mtime = compute_freshness_scores(mtimes)
    
    # Inicializar providers
    logger.info("Inicializando embedder...")
    embedder = get_embeddings_provider()
    logger.info(f"✓ Embedder inicializado: {type(embedder).__name__}")
    
    logger.info("Conectando ao Qdrant...")
    qdrant = QdrantClient(url=settings.qdrant_url, api_key=settings.qdrant_api_key, timeout=30.0)
    logger.info("✓ Conectado ao Qdrant")
    
    # Truncar se solicitado
    if args.truncate:
        try:
            await truncate_collection(qdrant, settings.qdrant_collection, args.verbose)
        except Exception as e:
            logger.error(f"Falha ao truncar collection: {e}", exc_info=True)
            return 1
        logger.info("")
    
    # Preparar coleção
    logger.info("Preparando collection...")
    test_vec = (await embedder.embed(["dim probe"]))[0]
    dim = len(test_vec)
    logger.info(f"Dimensão dos embeddings: {dim}")
    
    collection_name = settings.qdrant_collection
    try:
        qdrant.get_collection(collection_name)
        logger.info(f"✓ Collection '{collection_name}' já existe")
    except Exception:
        logger.info(f"Criando collection '{collection_name}'...")
        qdrant.create_collection(
            collection_name=collection_name,
            vectors_config=qm.VectorParams(size=dim, distance=qm.Distance.COSINE),
        )
        logger.info(f"✓ Collection '{collection_name}' criada")
    
    logger.info("")
    logger.info("Iniciando ingestão de documentos...")
    logger.info("-" * 60)
    
    indexed = 0
    ignored = []
    errors = []
    
    for idx, p in enumerate(files, 1):
        rel = str(p.relative_to(docs_root))
        ext = p.suffix.lower()
        
        logger.info(f"[{idx}/{len(files)}] Processando: {rel}")
        
        if ext not in {".txt", ".md"}:
            reason = f"extensão {ext} (ignorado por padrão)"
            logger.debug(f"  → Ignorado: {reason}")
            ignored.append((rel, reason))
            continue
        
        if "funcionarios" in rel.lower():
            reason = "R1: arquivo de funcionários/PII (ignorado)"
            logger.debug(f"  → Ignorado: {reason}")
            ignored.append((rel, reason))
            continue
        
        try:
            text = read_text(p)
        except Exception as e:
            reason = f"erro ao ler arquivo: {e}"
            logger.warning(f"  → Erro: {reason}")
            errors.append((rel, reason))
            continue
        
        if contains_cpf(text):
            reason = "R1: contém CPF/PII (ignorado)"
            logger.debug(f"  → Ignorado: {reason}")
            ignored.append((rel, reason))
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
        
        # Chunking
        if doc_type == "FAQ":
            faq_chunks = split_faq(text, title=meta.title)
            sections = [(meta.title, c) for c in faq_chunks] if faq_chunks else split_by_headings(text, title=meta.title)
        else:
            sections = split_by_headings(text, title=meta.title)
        
        chunk_texts = chunk_sections(sections, target_tokens=650, overlap_tokens=120)
        if not chunk_texts:
            reason = "arquivo vazio após normalização"
            logger.debug(f"  → Ignorado: {reason}")
            ignored.append((rel, reason))
            continue
        
        # Gerar embeddings
        logger.debug(f"  → Gerando embeddings para {len(chunk_texts)} chunk(s)...")
        try:
            vectors = await embedder.embed(chunk_texts)
        except Exception as e:
            reason = f"erro ao gerar embeddings: {e}"
            logger.error(f"  → Erro: {reason}")
            errors.append((rel, reason))
            continue
        
        # Preparar pontos
        points: list[qm.PointStruct] = []
        for chunk_idx, (chunk, vec) in enumerate(zip(chunk_texts, vectors)):
            point_id = hash_str(f"{meta.doc_id}:{chunk_idx}")[:32]
            payload = {
                "doc_id": meta.doc_id,
                "title": meta.title,
                "path": meta.rel_path,
                "updated_at": meta.updated_at,
                "doc_type": meta.doc_type,
                "trust_score": meta.trust_score,
                "freshness_score": meta.freshness_score,
                "chunk_index": chunk_idx,
                "text": chunk,
            }
            points.append(qm.PointStruct(id=point_id, vector=vec, payload=payload))
        
        # Upsert no Qdrant
        try:
            qdrant.upsert(collection_name=collection_name, points=points)
            indexed += len(points)
            logger.info(f"  ✓ Indexados {len(points)} chunk(s) ({meta.doc_type})")
        except Exception as e:
            reason = f"erro ao fazer upsert: {e}"
            logger.error(f"  → Erro: {reason}")
            errors.append((rel, reason))
            continue
    
    elapsed = time.time() - start_time
    
    # Resumo final
    logger.info("")
    logger.info("=" * 60)
    logger.info("RESUMO DA INGESTÃO")
    logger.info("=" * 60)
    logger.info(f"✓ Chunks indexados: {indexed}")
    logger.info(f"⚠ Arquivos ignorados: {len(ignored)}")
    logger.info(f"✗ Erros: {len(errors)}")
    logger.info(f"⏱ Tempo total: {elapsed:.2f}s")
    logger.info("")
    
    if ignored:
        logger.info("Arquivos ignorados:")
        for rel, why in ignored:
            logger.info(f"  - {rel}: {why}")
        logger.info("")
    
    if errors:
        logger.error("Erros encontrados:")
        for rel, why in errors:
            logger.error(f"  - {rel}: {why}")
        logger.info("")
    
    # Verificar pontos finais na collection
    try:
        info = qdrant.get_collection(collection_name)
        logger.info(f"Total de pontos na collection '{collection_name}': {info.points_count}")
    except Exception as e:
        logger.warning(f"Não foi possível verificar pontos finais: {e}")
    
    logger.info("=" * 60)
    
    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
