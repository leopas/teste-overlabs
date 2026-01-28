from __future__ import annotations

import json
import os
import queue
import re
import threading
import time
import hashlib
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Protocol

import structlog

from .redaction import redact_text


log = structlog.get_logger("trace_store")


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha256_hex(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def hash_chunk(text: str) -> str:
    return sha256_hex(text)


# redact_text agora está em redaction.py (importado acima)


@dataclass
class TraceEvent:
    name: str
    ts: str
    duration_ms: int | None = None
    attrs: dict[str, Any] = field(default_factory=dict)


@dataclass
class PipelineTrace:
    trace_id: str
    request_id: str
    user_id: str | None
    question_hash: str
    started_at: str = field(default_factory=utc_now_iso)
    finished_at: str | None = None
    duration_ms: int | None = None
    steps: list[TraceEvent] = field(default_factory=list)
    outcome: str | None = None  # answered/refused
    refusal_reason: str | None = None
    confidence: float | None = None
    model: str | None = None
    cache_hit: bool | None = None
    topk: int | None = None

    _t0: float = field(default_factory=time.perf_counter, repr=False)

    def add_event(self, name: str, attrs: dict[str, Any] | None = None, duration_ms: int | None = None) -> None:
        self.steps.append(TraceEvent(name=name, ts=utc_now_iso(), duration_ms=duration_ms, attrs=attrs or {}))

    def finish(self, *, outcome: str, refusal_reason: str | None, confidence: float | None, model: str | None) -> None:
        self.finished_at = utc_now_iso()
        self.duration_ms = int((time.perf_counter() - self._t0) * 1000)
        self.outcome = outcome
        self.refusal_reason = refusal_reason
        self.confidence = confidence
        self.model = model


class TraceSink(Protocol):
    def enqueue(self, trace: PipelineTrace) -> None: ...

    def shutdown(self) -> None: ...


class NoopTraceSink:
    def enqueue(self, trace: PipelineTrace) -> None:
        return

    def shutdown(self) -> None:
        return


class MySQLTraceSink:
    """
    Persistência assíncrona em MySQL.
    - Não bloqueia a request: enqueue em memória e worker grava.
    - Se mysql-connector não estiver instalado ou houver erro, loga e segue.
    """

    def __init__(self) -> None:
        self._q: queue.Queue[PipelineTrace] = queue.Queue(maxsize=int(os.getenv("TRACE_SINK_QUEUE_SIZE", "1000")))
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._worker, name="mysql-trace-sink", daemon=True)
        self._thread.start()

    def enqueue(self, trace: PipelineTrace) -> None:
        try:
            self._q.put_nowait(trace)
        except queue.Full:
            log.warning("trace_sink_queue_full", trace_id=trace.trace_id)

    def shutdown(self) -> None:
        self._stop.set()
        try:
            self._thread.join(timeout=2.0)
        except Exception:
            pass

    def _connect(self):
        try:
            import mysql.connector  # type: ignore
        except Exception as e:
            log.error("mysql_connector_missing", error=str(e))
            return None

        host = (os.getenv("MYSQL_HOST") or "").strip() or None
        port = int(os.getenv("MYSQL_PORT", "3306"))
        user_raw = (os.getenv("MYSQL_USER") or "").strip() or None
        password = os.getenv("MYSQL_PASSWORD")
        database = (os.getenv("MYSQL_DATABASE") or os.getenv("MYSQL_DB") or "").strip() or None

        # Azure MySQL frequentemente exige `user@servername` (servername = prefixo do host)
        server_name = (host.split(".", 1)[0] if host else "").strip()
        candidate_users: list[str | None] = [user_raw]
        if user_raw and "@" not in user_raw and server_name:
            candidate_users.append(f"{user_raw}@{server_name}")

        cfg_base = {
            "host": host,
            "port": port,
            "password": password,
            "database": database,
        }

        ssl_ca = os.getenv("MYSQL_SSL_CA")
        if ssl_ca:
            cfg_base["ssl_ca"] = ssl_ca
            cfg_base["ssl_verify_cert"] = True

        if not host or not user_raw or not password or not database:
            log.error(
                "mysql_config_incomplete",
                present={
                    "host": bool(host),
                    "port": bool(port),
                    "user": bool(user_raw),
                    "password": bool(password),
                    "database": bool(database),
                    "ssl_ca": bool(ssl_ca),
                },
            )
            return None

        last_err: str | None = None
        for u in [x for x in candidate_users if x]:
            try:
                cfg = dict(cfg_base)
                cfg["user"] = u
                return mysql.connector.connect(**cfg)
            except Exception as e:
                last_err = str(e)
                continue

        log.error("mysql_connect_error", error=last_err or "unknown")
        return None

    def _worker(self) -> None:
        conn = None
        while not self._stop.is_set():
            try:
                trace = self._q.get(timeout=0.5)
            except queue.Empty:
                continue

            try:
                if conn is None or not getattr(conn, "is_connected", lambda: False)():
                    conn = self._connect()
                if conn is None:
                    continue
                self._write(conn, trace)
            except Exception as e:
                log.error("mysql_write_error", error=str(e), trace_id=trace.trace_id)
                try:
                    if conn is not None:
                        conn.close()
                except Exception:
                    pass
                conn = None
            finally:
                try:
                    self._q.task_done()
                except Exception as e:
                    log.warning("trace_queue_task_done_error", error=str(e), error_type=type(e).__name__)

    def _write(self, conn, trace: PipelineTrace) -> None:
        cur = conn.cursor()
        try:
            cur.execute(
                """
                INSERT INTO pipeline_trace
                (trace_id, request_id, user_id, question_hash, started_at, finished_at, duration_ms,
                 outcome, refusal_reason, confidence, model, cache_hit, topk, created_at)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,UTC_TIMESTAMP())
                """,
                (
                    trace.trace_id,
                    trace.request_id,
                    trace.user_id,
                    trace.question_hash,
                    trace.started_at,
                    trace.finished_at,
                    trace.duration_ms,
                    trace.outcome,
                    trace.refusal_reason,
                    trace.confidence,
                    trace.model,
                    int(trace.cache_hit) if trace.cache_hit is not None else None,
                    trace.topk,
                ),
            )

            for i, ev in enumerate(trace.steps):
                cur.execute(
                    """
                    INSERT INTO pipeline_event
                    (trace_id, seq, name, ts, duration_ms, attrs_json, created_at)
                    VALUES (%s,%s,%s,%s,%s,%s,UTC_TIMESTAMP())
                    """,
                    (
                        trace.trace_id,
                        i,
                        ev.name,
                        ev.ts,
                        ev.duration_ms,
                        json.dumps(ev.attrs, ensure_ascii=False, separators=(",", ":")),
                    ),
                )

            conn.commit()
        finally:
            cur.close()


def get_trace_sink() -> TraceSink:
    sink = (os.getenv("TRACE_SINK") or "noop").strip().lower()
    # Conveniência: se MYSQL_* estiver configurado, assume mysql por padrão
    if sink in ("", "noop") and (os.getenv("MYSQL_HOST") or "").strip():
        sink = "mysql"
    if sink == "mysql":
        return MySQLTraceSink()
    return NoopTraceSink()

