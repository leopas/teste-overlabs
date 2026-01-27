from __future__ import annotations

import hashlib
import os
import random
import re
import time
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from re import Pattern
from typing import Any

import structlog

from . import metrics
from .observability import request_id_ctx, trace_id_ctx
from .security import normalize_question


log = structlog.get_logger()

_WHITESPACE_RE = re.compile(r"\s+")
_DOTALL_RE = re.compile(r"\(\?[^)]*s")


def normalize_for_firewall(text: str) -> str:
    """
    Normalização para match no firewall: NFKD, remove diacríticos,
    lower, colapsa whitespace. Alinhado ao comentário do .regex.
    """
    if not text:
        return ""
    s = unicodedata.normalize("NFKD", text)
    s = "".join(c for c in s if unicodedata.category(c) != "Mn")
    s = s.strip().lower()
    s = _WHITESPACE_RE.sub(" ", s)
    return s.strip()


def _question_hash(normalized: str) -> str:
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


def infer_category(rule_id: str, pattern: str) -> str:
    rid = (rule_id or "").lower()
    exfil_prefixes = (
        "inj_reveal", "inj_revelar", "inj_reveler", "inj_zeige", "inj_mostra",
        "inj_dump", "inj_listar",
    )
    if any(rid.startswith(p) for p in exfil_prefixes):
        return "EXFIL"
    if rid.startswith("inj_"):
        return "INJECTION"
    if rid.startswith("sec_"):
        return "SECRETS"
    if rid.startswith("pii_"):
        return "PII"
    if rid.startswith("payload_"):
        return "PAYLOAD"
    return "INJECTION"


@dataclass
class Rule:
    id: str
    pattern: str
    compiled: Pattern[str]
    category: str = "INJECTION"


def _parse_rules(
    path: str | Path,
    max_rules: int,
) -> tuple[list[Rule], int]:
    rules: list[Rule] = []
    auto_idx = 0
    invalid_count = 0
    try:
        content = Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError as e:
        log.warning("prompt_firewall_read_error", path=str(path), error=str(e))
        return [], 0

    for raw in content.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if len(rules) >= max_rules:
            log.warning("prompt_firewall_max_rules", path=str(path), max=max_rules)
            break

        rule_id: str
        pattern_str: str
        if "::" in line:
            parts = line.split("::", 1)
            rule_id = (parts[0] or "").strip()
            pattern_str = (parts[1] or "").strip()
            if not rule_id or not pattern_str:
                continue
        else:
            auto_idx += 1
            rule_id = f"rule_{auto_idx:04d}"
            pattern_str = line

        flags = re.IGNORECASE
        if _DOTALL_RE.search(pattern_str):
            flags |= re.DOTALL
        try:
            compiled = re.compile(pattern_str, flags)
        except re.error as e:
            log.warning("prompt_firewall_invalid_regex", rule_id=rule_id, error=str(e))
            metrics.FIREWALL_INVALID_RULE_TOTAL.inc()
            invalid_count += 1
            continue

        category = infer_category(rule_id, pattern_str)
        rules.append(Rule(id=rule_id, pattern=pattern_str, compiled=compiled, category=category))

    return rules, invalid_count


class PromptFirewall:
    def __init__(
        self,
        rules_path: str,
        enabled: bool,
        max_rules: int = 200,
        reload_check_seconds: int = 2,
        log_sample_rate: float = 0.01,
    ) -> None:
        self._rules_path = rules_path
        self._enabled = enabled
        self._max_rules = max_rules
        self._reload_check_seconds = reload_check_seconds
        self._log_sample_rate = log_sample_rate
        self._rules: list[Rule] = []
        self._last_mtime: float | None = None
        self._last_check_time: float = 0.0

    def load_if_needed(self, force: bool = False) -> None:
        now = time.monotonic()
        if now - self._last_check_time < self._reload_check_seconds and not force:
            return
        self._last_check_time = now

        if not self._enabled:
            self._rules = []
            metrics.FIREWALL_RULES_LOADED.set(0)
            return

        resolved = Path(self._rules_path)
        if not resolved.is_absolute():
            resolved = Path(os.getcwd()) / self._rules_path
        if not resolved.is_file():
            self._rules = []
            metrics.FIREWALL_RULES_LOADED.set(0)
            return

        try:
            mtime = resolved.stat().st_mtime
        except OSError:
            return

        if not force and self._last_mtime is not None and mtime <= self._last_mtime:
            return

        rules, invalid_count = _parse_rules(resolved, self._max_rules)
        self._rules = rules
        self._last_mtime = mtime
        metrics.FIREWALL_RULES_LOADED.set(len(rules))
        metrics.FIREWALL_RELOAD_TOTAL.inc()
        log.info("firewall_reload", rules_count=len(rules), invalid_count=invalid_count)

    def force_reload(self) -> None:
        """Força recarga do arquivo de regras (útil em testes)."""
        self.load_if_needed(force=True)

    def check(self, text: str) -> tuple[bool, dict[str, Any]]:
        self.load_if_needed()
        metrics.FIREWALL_CHECKS_TOTAL.inc()
        t0 = time.perf_counter()
        try:
            if not self._rules:
                return False, {}

            normalized = normalize_for_firewall(text)
            for r in self._rules:
                if r.compiled.search(normalized):
                    metrics.FIREWALL_BLOCK_TOTAL.inc()
                    qhash = _question_hash(normalized)
                    trace_id = trace_id_ctx.get() or "unknown"
                    req_id = request_id_ctx.get() or "unknown"
                    log.info(
                        "firewall_block",
                        rule_id=r.id,
                        category=r.category,
                        question_hash=qhash,
                        trace_id=trace_id,
                        request_id=req_id,
                    )
                    return True, {"rule_id": r.id, "category": r.category}
            if self._log_sample_rate > 0 and random.random() < self._log_sample_rate:
                duration_ms = (time.perf_counter() - t0) * 1000
                log.info("firewall_check", duration_ms=round(duration_ms, 2), matched=False)
            return False, {}
        finally:
            metrics.FIREWALL_CHECK_DURATION.observe(time.perf_counter() - t0)


def build_prompt_firewall(settings: Any) -> PromptFirewall:
    return PromptFirewall(
        rules_path=settings.prompt_firewall_rules_path,
        enabled=settings.prompt_firewall_enabled,
        max_rules=settings.prompt_firewall_max_rules,
        reload_check_seconds=settings.prompt_firewall_reload_check_seconds,
        log_sample_rate=getattr(settings, "firewall_log_sample_rate", 0.01),
    )
