from __future__ import annotations

import json
import os
import queue
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Literal, Protocol

import structlog

from .config import settings

log = structlog.get_logger("audit_store")


@dataclass
class AuditSession:
    session_id: str
    user_id: str | None
    client_fingerprint: str | None = None


@dataclass
class AuditMessage:
    session_id: str
    trace_id: str
    role: Literal["user", "assistant", "system"]
    text_hash: str
    text_redacted: str | None = None
    text_raw_enc: str | None = None  # JSON envelope base64
    text_raw_enc_alg: str | None = None
    text_raw_enc_kid: str | None = None


@dataclass
class AuditAsk:
    trace_id: str
    request_id: str
    session_id: str
    user_id: str | None
    question_hash: str
    answer_hash: str
    answer_source: Literal["CACHE", "LLM", "REFUSAL"]
    confidence: float | None = None
    refusal_reason: str | None = None
    cache_key: str | None = None
    cache_hit: bool = False
    llm_model: str | None = None
    latency_ms: int | None = None
    abuse_risk_score: float | None = None
    abuse_flags_json: str | None = None
    firewall_rule_ids: str | None = None  # JSON array de rule_ids do Prompt Firewall (ex: '["inj_ignore_previous_instructions"]')


@dataclass
class AuditChunk:
    trace_id: str
    rank: int
    doc_id: str | None = None
    document: str | None = None
    path: str | None = None
    chunk_id: str | None = None
    chunk_index: int | None = None
    score_similarity: float | None = None
    score_trust: float | None = None
    score_freshness: float | None = None
    score_final: float | None = None
    text_hash: str = ""
    excerpt_redacted: str | None = None


@dataclass
class AuditVectorFingerprint:
    trace_id: str
    embedding_model: str
    vector_dim: int
    vector_hash: str


class AuditSink(Protocol):
    def enqueue_session(self, session: AuditSession) -> None: ...

    def enqueue_message(self, message: AuditMessage) -> None: ...

    def enqueue_ask(self, ask: AuditAsk) -> None: ...

    def enqueue_chunk(self, chunk: AuditChunk) -> None: ...

    def enqueue_vector_fingerprint(self, fingerprint: AuditVectorFingerprint) -> None: ...

    def shutdown(self) -> None: ...


class NoopAuditSink:
    """Implementação vazia que não persiste nada."""

    def enqueue_session(self, session: AuditSession) -> None:
        pass

    def enqueue_message(self, message: AuditMessage) -> None:
        pass

    def enqueue_ask(self, ask: AuditAsk) -> None:
        pass

    def enqueue_chunk(self, chunk: AuditChunk) -> None:
        pass

    def enqueue_vector_fingerprint(self, fingerprint: AuditVectorFingerprint) -> None:
        pass

    def shutdown(self) -> None:
        pass


class MySQLAuditSink:
    """
    Persistência assíncrona em MySQL.
    - Não bloqueia a request: enqueue em memória e worker grava.
    - Se mysql-connector não estiver instalado ou houver erro, loga e segue.
    """

    def __init__(self) -> None:
        self._q: queue.Queue[dict[str, Any]] = queue.Queue(maxsize=int(os.getenv("TRACE_SINK_QUEUE_SIZE", "1000")))
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._worker, name="mysql-audit-sink", daemon=True)
        self._thread.start()

    def enqueue_session(self, session: AuditSession) -> None:
        try:
            self._q.put_nowait({"type": "session", "data": session})
        except queue.Full:
            log.warning("audit_sink_queue_full", session_id=session.session_id)

    def enqueue_message(self, message: AuditMessage) -> None:
        try:
            self._q.put_nowait({"type": "message", "data": message})
        except queue.Full:
            log.warning("audit_sink_queue_full", trace_id=message.trace_id)

    def enqueue_ask(self, ask: AuditAsk) -> None:
        try:
            self._q.put_nowait({"type": "ask", "data": ask})
        except queue.Full:
            log.warning("audit_sink_queue_full", trace_id=ask.trace_id)

    def enqueue_chunk(self, chunk: AuditChunk) -> None:
        try:
            self._q.put_nowait({"type": "chunk", "data": chunk, "retry_count": 0})
        except queue.Full:
            log.warning("audit_sink_queue_full", trace_id=chunk.trace_id)

    def enqueue_vector_fingerprint(self, fingerprint: AuditVectorFingerprint) -> None:
        try:
            self._q.put_nowait({"type": "vector_fingerprint", "data": fingerprint})
        except queue.Full:
            log.warning("audit_sink_queue_full", trace_id=fingerprint.trace_id)

    def shutdown(self) -> None:
        self._stop.set()
        try:
            self._thread.join(timeout=2.0)
        except Exception as e:
            log.warning("audit_shutdown_thread_join_error", error=str(e), error_type=type(e).__name__)

    def _connect(self):
        """Reutiliza lógica de conexão de MySQLTraceSink."""
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

        # Azure MySQL frequentemente exige `user@servername`
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
                item = self._q.get(timeout=0.5)
            except queue.Empty:
                continue

            try:
                if conn is None or not getattr(conn, "is_connected", lambda: False)():
                    conn = self._connect()
                if conn is None:
                    continue

                item_type = item["type"]
                data = item["data"]
                retry_count = item.get("retry_count", 0)

                # Para chunks, verificar se audit_ask existe primeiro
                if item_type == "chunk" and retry_count < 3:
                    # Verificar se audit_ask existe
                    cur_check = conn.cursor()
                    try:
                        cur_check.execute("SELECT 1 FROM audit_ask WHERE trace_id = %s LIMIT 1", (data.trace_id,))
                        exists = cur_check.fetchone() is not None
                    finally:
                        cur_check.close()

                    if not exists:
                        # Re-enfileirar chunk para tentar depois
                        log.debug("chunk_waiting_for_ask", trace_id=data.trace_id, retry_count=retry_count)
                        try:
                            self._q.put_nowait({"type": "chunk", "data": data, "retry_count": retry_count + 1})
                        except queue.Full:
                            log.warning("chunk_retry_queue_full", trace_id=data.trace_id)
                        continue

                if item_type == "session":
                    self._write_session(conn, data)
                elif item_type == "message":
                    self._write_message(conn, data)
                elif item_type == "ask":
                    self._write_ask(conn, data)
                elif item_type == "chunk":
                    self._write_chunk(conn, data)
                elif item_type == "vector_fingerprint":
                    self._write_vector_fingerprint(conn, data)

                conn.commit()
            except Exception as e:
                error_str = str(e)
                # Se for erro de FK em chunk, re-enfileirar se ainda tiver tentativas
                if item_type == "chunk" and ("foreign key constraint" in error_str.lower() or "1452" in error_str):
                    retry_count = item.get("retry_count", 0)
                    if retry_count < 3:
                        log.warning("chunk_fk_retry", trace_id=data.trace_id, retry_count=retry_count)
                        try:
                            self._q.put_nowait({"type": "chunk", "data": data, "retry_count": retry_count + 1})
                        except queue.Full:
                            log.warning("chunk_retry_queue_full", trace_id=data.trace_id)
                    else:
                        log.error("chunk_fk_max_retries", trace_id=data.trace_id, error=error_str)
                else:
                    log.error("mysql_audit_write_error", error=error_str, item_type=item.get("type"))
                try:
                    if conn is not None:
                        conn.close()
                except Exception as e:
                    log.warning("audit_connection_close_error", error=str(e), error_type=type(e).__name__)
                conn = None
            finally:
                try:
                    self._q.task_done()
                except Exception as e:
                    log.warning("audit_queue_task_done_error", error=str(e), error_type=type(e).__name__)

    def _write_session(self, conn, session: AuditSession) -> None:
        cur = conn.cursor()
        try:
            cur.execute(
                """
                INSERT INTO audit_session (session_id, user_id, client_fingerprint, created_at, last_seen_at)
                VALUES (%s, %s, %s, UTC_TIMESTAMP(), UTC_TIMESTAMP())
                ON DUPLICATE KEY UPDATE last_seen_at = UTC_TIMESTAMP()
                """,
                (session.session_id, session.user_id, session.client_fingerprint),
            )
        finally:
            cur.close()

    def _write_message(self, conn, message: AuditMessage) -> None:
        cur = conn.cursor()
        try:
            cur.execute(
                """
                INSERT INTO audit_message
                (session_id, trace_id, role, text_hash, text_redacted, text_raw_enc, text_raw_enc_alg, text_raw_enc_kid, created_at)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, UTC_TIMESTAMP())
                """,
                (
                    message.session_id,
                    message.trace_id,
                    message.role,
                    message.text_hash,
                    message.text_redacted,
                    message.text_raw_enc,
                    message.text_raw_enc_alg,
                    message.text_raw_enc_kid,
                ),
            )
        finally:
            cur.close()

    def _write_ask(self, conn, ask: AuditAsk) -> None:
        cur = conn.cursor()
        try:
            # Usar ON DUPLICATE KEY UPDATE para garantir que sempre existe (evita race condition)
            cur.execute(
                """
                INSERT INTO audit_ask
                (trace_id, request_id, session_id, user_id, question_hash, answer_hash, answer_source,
                 confidence, refusal_reason, cache_key, cache_hit, llm_model, latency_ms,
                 abuse_risk_score, abuse_flags_json, firewall_rule_ids, created_at)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, UTC_TIMESTAMP())
                ON DUPLICATE KEY UPDATE
                    request_id = VALUES(request_id),
                    session_id = VALUES(session_id),
                    user_id = VALUES(user_id),
                    question_hash = VALUES(question_hash),
                    answer_hash = VALUES(answer_hash),
                    answer_source = VALUES(answer_source),
                    confidence = VALUES(confidence),
                    refusal_reason = VALUES(refusal_reason),
                    cache_key = VALUES(cache_key),
                    cache_hit = VALUES(cache_hit),
                    llm_model = VALUES(llm_model),
                    latency_ms = VALUES(latency_ms),
                    abuse_risk_score = VALUES(abuse_risk_score),
                    abuse_flags_json = VALUES(abuse_flags_json),
                    firewall_rule_ids = VALUES(firewall_rule_ids)
                """,
                (
                    ask.trace_id,
                    ask.request_id,
                    ask.session_id,
                    ask.user_id,
                    ask.question_hash,
                    ask.answer_hash,
                    ask.answer_source,
                    ask.confidence,
                    ask.refusal_reason,
                    ask.cache_key,
                    ask.cache_hit,
                    ask.llm_model,
                    ask.latency_ms,
                    ask.abuse_risk_score,
                    ask.abuse_flags_json,
                    ask.firewall_rule_ids,
                ),
            )
        finally:
            cur.close()

    def _write_chunk(self, conn, chunk: AuditChunk) -> None:
        cur = conn.cursor()
        try:
            cur.execute(
                """
                INSERT INTO audit_retrieval_chunk
                (trace_id, `rank`, doc_id, document, path, chunk_id, chunk_index,
                 score_similarity, score_trust, score_freshness, score_final,
                 text_hash, excerpt_redacted, created_at)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, UTC_TIMESTAMP())
                """,
                (
                    chunk.trace_id,
                    chunk.rank,
                    chunk.doc_id,
                    chunk.document,
                    chunk.path,
                    chunk.chunk_id,
                    chunk.chunk_index,
                    chunk.score_similarity,
                    chunk.score_trust,
                    chunk.score_freshness,
                    chunk.score_final,
                    chunk.text_hash,
                    chunk.excerpt_redacted,
                ),
            )
        finally:
            cur.close()

    def _write_vector_fingerprint(self, conn, fingerprint: AuditVectorFingerprint) -> None:
        cur = conn.cursor()
        try:
            cur.execute(
                """
                INSERT INTO audit_vector_fingerprint
                (trace_id, embedding_model, vector_dim, vector_hash, created_at)
                VALUES (%s, %s, %s, %s, UTC_TIMESTAMP())
                """,
                (fingerprint.trace_id, fingerprint.embedding_model, fingerprint.vector_dim, fingerprint.vector_hash),
            )
        finally:
            cur.close()


def get_audit_sink() -> AuditSink:
    """
    Retorna o sink de audit apropriado baseado na configuração.
    """
    if not settings.audit_log_enabled:
        return NoopAuditSink()

    sink = settings.trace_sink.lower()
    # Conveniência: se MYSQL_* estiver configurado, assume mysql por padrão
    if sink in ("", "noop") and (os.getenv("MYSQL_HOST") or "").strip():
        sink = "mysql"

    if sink == "mysql":
        return MySQLAuditSink()

    return NoopAuditSink()
