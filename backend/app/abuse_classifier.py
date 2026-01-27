from __future__ import annotations

import json
import re
from typing import Literal

from .config import settings

# Heurísticas para detecção de PII/sensível (não coberto pelo Prompt Firewall)
# Injection/exfiltração agora é detectado pelo Prompt Firewall via scan_for_abuse()
_SENSITIVE_RE = re.compile(
    r"(?i)\b("
    r"\d{3}\.\d{3}\.\d{3}-\d{2}|\d{11}|"  # CPF
    r"(?:\d[ -]*?){13,19}|"  # Cartão
    r"password|senha|token|api[_ -]?key|secret|private key|ssh-rsa|BEGIN PRIVATE KEY|"
    r"cart(ã|a)o|cvv|conta banc(á|a)ria|ag(ê|e)ncia|banco"
    r")\b"
)


def classify(question: str, prompt_firewall=None) -> tuple[float, list[str]]:
    """
    Classifica pergunta quanto ao risco de abuso.
    
    Agora usa o Prompt Firewall para detecção de injection/exfiltração quando disponível,
    mantendo apenas detecção de PII/sensível localmente.
    
    Args:
        question: Pergunta do usuário
        prompt_firewall: Instância do PromptFirewall (opcional, injetada via app.state)
    
    Returns:
        Tupla (risk_score: float, flags: list[str])
        - risk_score: 0.0 a 1.0 (clampado)
        - flags: Lista de strings identificando tipos de abuso detectados
    """
    if not settings.abuse_classifier_enabled:
        return (0.0, [])

    risk_score = 0.0
    flags: list[str] = []

    # Usar Prompt Firewall para injection/exfiltração (se disponível e habilitado)
    if prompt_firewall and prompt_firewall._enabled:
        fw_score, fw_flags = prompt_firewall.scan_for_abuse(question)
        risk_score = max(risk_score, fw_score)
        flags.extend(fw_flags)

    # Sensitive patterns (CPF, cartão, token, key) → +0.6
    # Mantido aqui pois não está no Prompt Firewall (PII é detectado mas não bloqueado)
    question_lower = question.lower()
    if _SENSITIVE_RE.search(question_lower):
        risk_score = max(risk_score, 0.6)
        if "sensitive_input" not in flags:
            flags.append("sensitive_input")

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
