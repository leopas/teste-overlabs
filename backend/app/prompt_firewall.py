from __future__ import annotations

import hashlib
import os
import random
import re
import threading
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
# Regex para validar rule_id no início da linha: ^[A-Za-z0-9_]{1,64}::
_RULE_ID_PATTERN = re.compile(r"^[A-Za-z0-9_]{1,64}::")


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
    seen_rule_ids: dict[str, int] = {}  # Para detectar duplicatas
    
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
        
        # Parsing robusto: só trata como regra nomeada se começar com ^[A-Za-z0-9_]{1,64}::
        if _RULE_ID_PATTERN.match(line):
            parts = line.split("::", 1)
            rule_id = (parts[0] or "").strip()
            pattern_str = (parts[1] or "").strip()
            if not rule_id or not pattern_str:
                continue
            
            # Detectar duplicatas e renomear determinístico
            if rule_id in seen_rule_ids:
                seen_rule_ids[rule_id] += 1
                suffix = seen_rule_ids[rule_id]
                original_id = rule_id
                rule_id = f"{rule_id}_dup{suffix}"
                log.warning(
                    "prompt_firewall_duplicate_rule_id",
                    original_id=original_id,
                    renamed_to=rule_id,
                )
            else:
                seen_rule_ids[rule_id] = 0
        else:
            auto_idx += 1
            rule_id = f"rule_{auto_idx:04d}"
            pattern_str = line

        # Compilar regex SEM inferir flags - respeitar flags inline do pattern
        # Python 3 já usa re.UNICODE por padrão, então não precisamos forçar
        try:
            compiled = re.compile(pattern_str)
        except re.error as e:
            log.warning("prompt_firewall_invalid_regex", rule_id=rule_id, error=str(e))
            metrics.FIREWALL_INVALID_RULE_TOTAL.inc()
            invalid_count += 1
            continue

        category = infer_category(rule_id, pattern_str)
        rules.append(Rule(id=rule_id, pattern=pattern_str, compiled=compiled, category=category))

    return rules, invalid_count


def _resolve_rules_path(rules_path: str) -> Path:
    """
    Resolve rules_path de forma estável:
    - Se absoluto, usa direto
    - Se relativo, resolve relativo à raiz do projeto (assumindo estrutura backend/app/)
    - Dentro do container Docker, o código está em /app/app/, então a raiz é /app/
    """
    path = Path(rules_path)
    if path.is_absolute():
        return path
    
    # Resolver relativo ao diretório do módulo prompt_firewall.py
    # Isso garante que funciona independente do CWD
    # prompt_firewall.py está em backend/app/, então subimos 2 níveis para a raiz
    module_dir = Path(__file__).resolve().parent
    project_root = module_dir.parent.parent
    
    # Dentro do container Docker, se o código está em /app/app/, 
    # module_dir.parent.parent seria /, mas queremos /app/
    # Verificar se project_root é / e ajustar
    if str(project_root) == '/':
        # Estamos no container Docker, usar /app/ como raiz
        project_root = Path('/app')
    
    resolved = project_root / rules_path
    return resolved.resolve()  # Resolve qualquer .. ou . no path


class PromptFirewall:
    def __init__(
        self,
        rules_path: str,
        enabled: bool,
        max_rules: int = 200,
        reload_check_seconds: int = 2,
        log_sample_rate: float = 0.01,
    ) -> None:
        self._rules_path = _resolve_rules_path(rules_path)
        self._enabled = enabled
        self._max_rules = max_rules
        self._reload_check_seconds = reload_check_seconds
        self._log_sample_rate = log_sample_rate
        self._rules: list[Rule] = []
        self._last_mtime: float | None = None
        self._last_check_time: float = 0.0
        self._reload_lock = threading.RLock()  # RLock para permitir reentrância se necessário

    def load_if_needed(self, force: bool = False) -> None:
        # Double-check pattern: verificar condições fora do lock primeiro
        now = time.monotonic()
        if now - self._last_check_time < self._reload_check_seconds and not force:
            return
        
        # Revalidar dentro do lock
        with self._reload_lock:
            # Revalidar throttle após adquirir lock (outra thread pode ter recarregado)
            now = time.monotonic()
            if now - self._last_check_time < self._reload_check_seconds and not force:
                return
            self._last_check_time = now

            if not self._enabled:
                self._rules = []
                metrics.FIREWALL_RULES_LOADED.set(0)
                return

            # _rules_path já está resolvido no __init__
            if not self._rules_path.is_file():
                self._rules = []
                metrics.FIREWALL_RULES_LOADED.set(0)
                return

            try:
                mtime = self._rules_path.stat().st_mtime
            except OSError:
                return

            if not force and self._last_mtime is not None and mtime <= self._last_mtime:
                return

            # Medir duração do reload
            reload_start = time.perf_counter()
            rules, invalid_count = _parse_rules(self._rules_path, self._max_rules)
            reload_duration = time.perf_counter() - reload_start
            
            self._rules = rules
            self._last_mtime = mtime
            metrics.FIREWALL_RULES_LOADED.set(len(rules))
            metrics.FIREWALL_RELOAD_TOTAL.inc()
            metrics.FIREWALL_RELOAD_DURATION.observe(reload_duration)
            log.info("firewall_reload", rules_count=len(rules), invalid_count=invalid_count)

    def force_reload(self) -> None:
        """Força recarga do arquivo de regras (útil em testes)."""
        self.load_if_needed(force=True)

    def check(self, text: str) -> tuple[bool, dict[str, Any]]:
        # Timer começa ANTES do load_if_needed para incluir tempo de reload
        t0 = time.perf_counter()
        metrics.FIREWALL_CHECKS_TOTAL.inc()
        
        try:
            self.load_if_needed()
            
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

    def scan_for_abuse(self, text: str) -> tuple[float, list[str]]:
        """
        Escaneia texto para calcular score de risco e flags de abuso baseado nas regras do firewall.
        Não bloqueia, apenas classifica. Útil para integração com abuse_classifier.
        
        Returns:
            Tupla (risk_score: float, flags: list[str])
            - risk_score: 0.0 a 1.0 baseado nas categorias de regras que casaram
            - flags: Lista de flags identificando tipos de abuso
        """
        if not self._enabled:
            return (0.0, [])
        
        self.load_if_needed()
        
        if not self._rules:
            return (0.0, [])
        
        normalized = normalize_for_firewall(text)
        risk_score = 0.0
        flags: list[str] = []
        matched_categories: set[str] = set()
        
        for r in self._rules:
            if r.compiled.search(normalized):
                matched_categories.add(r.category)
                
                # Mapear categorias para scores e flags
                if r.category == "INJECTION":
                    risk_score = max(risk_score, 0.5)
                    if "prompt_injection_attempt" not in flags:
                        flags.append("prompt_injection_attempt")
                elif r.category == "EXFIL":
                    risk_score = max(risk_score, 0.4)
                    if "exfiltration_attempt" not in flags:
                        flags.append("exfiltration_attempt")
                elif r.category == "SECRETS":
                    risk_score = max(risk_score, 0.6)
                    if "sensitive_input" not in flags:
                        flags.append("sensitive_input")
                elif r.category == "PII":
                    risk_score = max(risk_score, 0.6)
                    if "sensitive_input" not in flags:
                        flags.append("sensitive_input")
                elif r.category == "PAYLOAD":
                    risk_score = max(risk_score, 0.7)
                    if "suspicious_payload" not in flags:
                        flags.append("suspicious_payload")
        
        # Se múltiplas categorias, aumentar score
        if len(matched_categories) > 1:
            risk_score = min(1.0, risk_score + 0.2)
        
        return (risk_score, flags)


def build_prompt_firewall(settings: Any) -> PromptFirewall:
    return PromptFirewall(
        rules_path=settings.prompt_firewall_rules_path,
        enabled=settings.prompt_firewall_enabled,
        max_rules=settings.prompt_firewall_max_rules,
        reload_check_seconds=settings.prompt_firewall_reload_check_seconds,
        log_sample_rate=getattr(settings, "firewall_log_sample_rate", 0.01),
    )
