from __future__ import annotations

import re
import unicodedata


_WHITESPACE_RE = re.compile(r"\s+")

# Heurísticas simples (não exaustivas) para prompt injection (fallback quando firewall está disabled)
# IMPORTANTE: Estas regex devem funcionar com texto normalizado (lower, sem acentos, whitespace colapsado)
_INJECTION_RE = re.compile(
    r"(?i)\b("
    r"ignore\s+(all\s+)?(previous|above)\s+(instructions|messages)|"
    r"disregard\s+(the\s+)?(system|developer)\s+(prompt|message)|"
    r"reveal\s+(the\s+)?(system|developer)\s+(prompt|message)|"
    r"show\s+(me\s+)?(your\s+)?(system|developer)\s+(prompt|message)|"
    r"jailbreak|"
    r"begin\s+(system|developer|prompt)|end\s+(system|developer|prompt)|"
    r"you\s+are\s+chatgpt|as\s+an\s+ai\s+language\s+model"
    r")\b"
)

# PII/sensível (CPF, cartões, segredos)
_CPF_RE = re.compile(r"\b\d{3}\.\d{3}\.\d{3}-\d{2}\b|\b\d{11}\b")
_CARD_RE = re.compile(r"\b(?:\d[ -]*?){13,19}\b")
_SECRET_RE = re.compile(
    r"(?i)\b("
    r"password|senha|token|api[_ -]?key|secret|private key|ssh-rsa|BEGIN PRIVATE KEY|"
    r"cart(ã|a)o|cvv|conta banc(á|a)ria|ag(ê|e)ncia|banco"
    r")\b"
)


def normalize_question(question: str) -> str:
    """
    Normalização básica: lower, colapsa whitespace.
    Para normalização completa (NFKD + remove acentos), use normalize_for_firewall do prompt_firewall.
    """
    q = question.strip().lower()
    q = _WHITESPACE_RE.sub(" ", q)
    return q


def normalize_for_firewall_fallback(text: str) -> str:
    """
    Normalização compatível com normalize_for_firewall (NFKD + remove diacríticos).
    Usado no fallback quando firewall está disabled.
    Evita import cycle importando diretamente.
    """
    if not text:
        return ""
    s = unicodedata.normalize("NFKD", text)
    s = "".join(c for c in s if unicodedata.category(c) != "Mn")
    s = s.strip().lower()
    s = _WHITESPACE_RE.sub(" ", s)
    return s.strip()


def detect_prompt_injection(question: str) -> bool:
    """
    Detecta prompt injection usando normalização compatível com firewall.
    Retorna True se detectar injection.
    """
    normalized = normalize_for_firewall_fallback(question)
    return bool(_INJECTION_RE.search(normalized))


def detect_prompt_injection_details(question: str) -> tuple[bool, str | None]:
    """
    Detecta prompt injection e retorna (blocked, rule_id).
    rule_id é "inj_fallback_heuristic" quando detecta via fallback.
    """
    normalized = normalize_for_firewall_fallback(question)
    if _INJECTION_RE.search(normalized):
        return True, "inj_fallback_heuristic"
    return False, None


def detect_sensitive_request(question: str) -> bool:
    return bool(_CPF_RE.search(question) or _CARD_RE.search(question) or _SECRET_RE.search(question))


def contains_cpf(text: str) -> bool:
    return bool(_CPF_RE.search(text))

