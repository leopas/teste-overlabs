from __future__ import annotations

import asyncio
import json
import time
import uuid
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request, status

from .admin_auth import require_admin
from .cache import RedisClient


router = APIRouter(
    prefix="/admin/api",
    tags=["admin"],
    dependencies=[Depends(require_admin)],
)


LOCK_KEY = "admin:ingest:lock"
LOCK_TTL_SECONDS = 60 * 30  # 30 min
JOB_TTL_SECONDS = 60 * 60 * 6  # 6h
LOG_MAX_LINES = 600


def _now() -> float:
    return time.time()


def _job_key(job_id: str) -> str:
    return f"admin:job:{job_id}"


def _job_log_key(job_id: str) -> str:
    return f"admin:joblog:{job_id}"


def _ensure_redis(cache: RedisClient) -> None:
    try:
        cache.ping()
    except Exception as e:
        raise HTTPException(status_code=503, detail=f"Redis indisponível para jobs admin: {e}")


def _set_job(cache: RedisClient, job_id: str, data: dict[str, Any]) -> None:
    cache.raw().setex(_job_key(job_id), JOB_TTL_SECONDS, json.dumps(data, ensure_ascii=False))


def _get_job(cache: RedisClient, job_id: str) -> dict[str, Any] | None:
    raw = cache.raw().get(_job_key(job_id))
    if not raw:
        return None
    return json.loads(raw)


def _append_log(cache: RedisClient, job_id: str, line: str) -> None:
    r = cache.raw()
    k = _job_log_key(job_id)
    pipe = r.pipeline()
    pipe.rpush(k, line)
    pipe.ltrim(k, -LOG_MAX_LINES, -1)
    pipe.expire(k, JOB_TTL_SECONDS)
    pipe.execute()


def _get_logs(cache: RedisClient, job_id: str, tail: int = 200) -> list[str]:
    tail = max(1, min(int(tail), LOG_MAX_LINES))
    r = cache.raw()
    k = _job_log_key(job_id)
    return [x.decode("utf-8", errors="replace") if isinstance(x, (bytes, bytearray)) else str(x) for x in r.lrange(k, -tail, -1)]


async def _run_subprocess(job_id: str, cache: RedisClient, args: list[str], *, step: str) -> int:
    _append_log(cache, job_id, f"[job] step_start={step} args={args}")
    proc = await asyncio.create_subprocess_exec(
        *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    assert proc.stdout is not None
    while True:
        line = await proc.stdout.readline()
        if not line:
            break
        _append_log(cache, job_id, line.decode("utf-8", errors="replace").rstrip("\n"))
    code = await proc.wait()
    _append_log(cache, job_id, f"[job] step_end={step} exit_code={code}")
    return int(code)


async def _run_ingest_job(job_id: str, cache: RedisClient) -> None:
    # Atualiza status
    job = _get_job(cache, job_id) or {}
    job.update({"status": "running", "started_at": _now(), "step": "scan_docs"})
    _set_job(cache, job_id, job)

    try:
        # 1) scan_docs (sync via subprocess)
        code1 = await _run_subprocess(job_id, cache, ["python", "-m", "scripts.scan_docs"], step="scan_docs")
        if code1 != 0:
            raise RuntimeError(f"scan_docs falhou (exit={code1})")

        # 2) ingest (async via subprocess)
        job.update({"step": "ingest"})
        _set_job(cache, job_id, job)
        code2 = await _run_subprocess(job_id, cache, ["python", "-m", "scripts.ingest"], step="ingest")
        if code2 != 0:
            raise RuntimeError(f"ingest falhou (exit={code2})")

        job.update({"status": "succeeded", "finished_at": _now(), "step": "done"})
        _set_job(cache, job_id, job)
        _append_log(cache, job_id, "[job] done status=succeeded")
    except Exception as e:
        job.update({"status": "failed", "finished_at": _now(), "error": str(e)})
        _set_job(cache, job_id, job)
        _append_log(cache, job_id, f"[job] done status=failed error={e}")
    finally:
        # liberar lock (best-effort)
        try:
            cache.raw().delete(LOCK_KEY)
        except Exception:
            pass


@router.post("/ingest")
async def start_ingest(request: Request) -> dict[str, Any]:
    """
    Dispara scan_docs + ingest (upsert/incremental).
    """
    cache: RedisClient = request.app.state.cache
    _ensure_redis(cache)

    r = cache.raw()
    job_id = uuid.uuid4().hex
    acquired = r.set(LOCK_KEY, job_id, nx=True, ex=LOCK_TTL_SECONDS)
    if not acquired:
        current = r.get(LOCK_KEY)
        cur = current.decode("utf-8", errors="replace") if isinstance(current, (bytes, bytearray)) else str(current)
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail={"message": "Ingest já em execução", "job_id": cur})

    job = {
        "id": job_id,
        "status": "queued",
        "created_at": _now(),
        "started_at": None,
        "finished_at": None,
        "step": "queued",
        "error": None,
    }
    _set_job(cache, job_id, job)
    _append_log(cache, job_id, "[job] queued")

    asyncio.create_task(_run_ingest_job(job_id, cache))
    return {"job_id": job_id}


@router.get("/jobs/{job_id}")
def get_job(job_id: str, request: Request, tail: int = 200) -> dict[str, Any]:
    cache: RedisClient = request.app.state.cache
    _ensure_redis(cache)

    job = _get_job(cache, job_id)
    if not job:
        raise HTTPException(status_code=404, detail="job não encontrado")
    logs = _get_logs(cache, job_id, tail=tail)
    return {"job": job, "logs": logs}

