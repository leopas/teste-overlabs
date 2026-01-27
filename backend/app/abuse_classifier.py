from __future__ import annotations

import json
import re
from typing import Literal

from .config import settings

# Heurísticas para detecção de abuso
_INJECTION_RE = re.compile(
    r"(?i)\b("
    r"ignore (all )?(previous|above) (instructions|messages)|"
    r"disregard (the )?(system|developer) (prompt|message)|"
    r"reveal (the )?(system|developer) (prompt|message)|"
    r"show (me )?(your )?(system|developer) (prompt|message)|"
    r"jailbreak|"
    r"BEGIN (SYSTEM|DEVELOPER|PROMPT)|END (SYSTEM|DEVELOPER|PROMPT)|"
    r"you are chatgpt|as an ai language model"
    r")\b"
)

_SENSITIVE_RE = re.compile(
    r"(?i)\b("
    r"\d{3}\.\d{3}\.\d{3}-\d{2}|\d{11}|"  # CPF
    r"(?:\d[ -]*?){13,19}|"  # Cartão
    r"password|senha|token|api[_ -]?key|secret|private key|ssh-rsa|BEGIN PRIVATE KEY|"
    r"cart(ã|a)o|cvv|conta banc(á|a)ria|ag(ê|e)ncia|banco"
    r")\b"
)

_EXFILTRATION_RE = re.compile(
    r"(?i)\b("
    r"reveal|show|tell|give|send|"
    r"system prompt|developer prompt|instructions|"
    r"ignore instructions|bypass|override"
    r")\b"
)


def classify(question: str) -> tuple[float, list[str]]:
    """
    Classifica pergunta quanto ao risco de abuso.
    
    Args:
        question: Pergunta do usuário
    
    Returns:
        Tupla (risk_score: float, flags: list[str])
        - risk_score: 0.0 a 1.0 (clampado)
        - flags: Lista de strings identificando tipos de abuso detectados
    """
    if not settings.abuse_classifier_enabled:
        return (0.0, [])

    risk_score = 0.0
    flags: list[str] = []

    question_lower = question.lower()

    # Injection tokens → +0.5
    if _INJECTION_RE.search(question_lower):
        risk_score += 0.5
        flags.append("prompt_injection_attempt")

    # Sensitive patterns (CPF, cartão, token, key) → +0.6
    if _SENSITIVE_RE.search(question_lower):
        risk_score += 0.6
        flags.append("sensitive_input")

    # Exfiltração → +0.4
    if _EXFILTRATION_RE.search(question_lower):
        risk_score += 0.4
        if "exfiltration_attempt" not in flags:
            flags.append("exfiltration_attempt")

    # Clamp entre 0.0 e 1.0
    risk_score = max(0.0, min(1.0, risk_score))

    return (risk_score, flags)


def should_save_raw(risk_score: float, raw_mode: str, threshold: float) -> bool:
    """
    Decide se deve salvar texto bruto criptografado baseado no modo e score.
    
    Args:
        risk_score: Score de risco (0.0 a 1.0)
        raw_mode: Modo de raw logging (off|risk_only|always)
        threshold: Threshold de risco para risk_only
    
    Returns:
        True se deve salvar raw criptografado
    """
    if raw_mode == "off":
        return False
    if raw_mode == "always":
        return True
    if raw_mode == "risk_only":
        return risk_score >= threshold
    return False


def flags_to_json(flags: list[str]) -> str | None:
    """
    Converte lista de flags para JSON string (para armazenar no DB).
    Retorna None se lista vazia.
    """
    if not flags:
        return None
    return json.dumps(flags, ensure_ascii=False)
