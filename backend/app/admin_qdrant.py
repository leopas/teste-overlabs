from __future__ import annotations

import base64
import json
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query
from qdrant_client import QdrantClient

from .admin_auth import require_admin
from .config import settings


router = APIRouter(
    prefix="/admin/api/qdrant",
    tags=["admin"],
    dependencies=[Depends(require_admin)],
)


def _b64_encode_json(obj: Any) -> str:
    raw = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return base64.urlsafe_b64encode(raw).decode("ascii")


def _b64_decode_json(token: str) -> Any:
    try:
        raw = base64.urlsafe_b64decode(token.encode("ascii"))
        return json.loads(raw.decode("utf-8"))
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"cursor inválido: {e}")


def _qdrant() -> QdrantClient:
    # timeout maior para operações admin
    return QdrantClient(url=settings.qdrant_url, api_key=settings.qdrant_api_key, timeout=10.0)


@router.get("/collections")
def list_collections() -> dict[str, Any]:
    q = _qdrant()
    cols = q.get_collections()
    out: list[dict[str, Any]] = []
    for c in getattr(cols, "collections", cols) or []:
        name = getattr(c, "name", None) or str(c)
        points_count = None
        try:
            info = q.get_collection(name)
            points_count = getattr(info, "points_count", None)
        except Exception:
            points_count = None
        out.append({"name": name, "points_count": points_count})
    out.sort(key=lambda x: x["name"])
    return {"collections": out}


@router.get("/points")
def scroll_points(
    collection: str = Query(settings.qdrant_collection),
    limit: int = Query(50, ge=1, le=200),
    cursor: str | None = Query(None, description="Cursor de paginação (base64url(json))"),
    with_payload: bool = Query(True),
    include_text: bool = Query(False, description="Se true, retorna payload.text completo"),
    text_preview_chars: int = Query(300, ge=0, le=5000),
) -> dict[str, Any]:
    q = _qdrant()
    offset = _b64_decode_json(cursor) if cursor else None

    points, next_offset = q.scroll(
        collection_name=collection,
        limit=limit,
        offset=offset,
        with_payload=with_payload,
        with_vectors=False,
    )

    items: list[dict[str, Any]] = []
    for p in points or []:
        payload = (p.payload or {}) if with_payload else None
        text_preview = None
        text_len = None
        if payload and "text" in payload and isinstance(payload.get("text"), str):
            txt = payload.get("text") or ""
            text_len = len(txt)
            if include_text:
                text_preview = None
            else:
                text_preview = (txt if len(txt) <= text_preview_chars else (txt[: max(text_preview_chars - 1, 0)] + "…"))
                # não retornar texto completo por padrão
                payload = dict(payload)
                payload.pop("text", None)

        items.append(
            {
                "id": p.id,
                "payload": payload,
                "text_preview": text_preview,
                "text_len": text_len,
                "score": getattr(p, "score", None),
            }
        )

    next_cursor = _b64_encode_json(next_offset) if next_offset is not None else None
    return {
        "collection": collection,
        "count": len(items),
        "items": items,
        "next_cursor": next_cursor,
    }

