from __future__ import annotations

import re


_WHITESPACE_RE = re.compile(r"\s+")

# Heurísticas simples (não exaustivas) para prompt injection
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
    q = question.strip().lower()
    q = _WHITESPACE_RE.sub(" ", q)
    return q


def detect_prompt_injection(question: str) -> bool:
    return bool(_INJECTION_RE.search(question))


def detect_sensitive_request(question: str) -> bool:
    return bool(_CPF_RE.search(question) or _CARD_RE.search(question) or _SECRET_RE.search(question))


def contains_cpf(text: str) -> bool:
    return bool(_CPF_RE.search(text))

