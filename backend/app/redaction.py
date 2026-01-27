from __future__ import annotations

import hashlib
import re

# Padrões para redação de PII
_CPF_RE = re.compile(r"\b\d{3}\.\d{3}\.\d{3}-\d{2}\b|\b\d{11}\b")
_CARD_RE = re.compile(r"\b(?:\d[ -]*?){13,19}\b")
_TOKEN_RE = re.compile(r"(?i)\b(bearer\s+[a-z0-9\-\._~\+/]+=*)\b")
_APIKEY_RE = re.compile(r"(?i)\b(api[_ -]?key|token|secret|senha|password)\b")
_EMAIL_RE = re.compile(r"\b[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}\b")
_PHONE_RE = re.compile(r"\b(?:\+?55\s?)?(?:\(?\d{2}\)?\s?)?\d{4,5}[-\s]?\d{4}\b")
_CONTROL_CHARS_RE = re.compile(r"[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]")
_WHITESPACE_RE = re.compile(r"\s+")


def normalize_text(text: str) -> str:
    """
    Normaliza texto: trim, collapse whitespace, remove control chars.
    Esta normalização é usada para gerar hash consistente.
    """
    s = text.strip()
    s = _CONTROL_CHARS_RE.sub("", s)
    s = _WHITESPACE_RE.sub(" ", s)
    return s


def sha256_text(text: str) -> str:
    """
    Retorna hash SHA256 do texto normalizado.
    Sempre use texto normalizado para garantir consistência.
    """
    normalized = normalize_text(text)
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


def redact_text(text: str) -> str:
    """
    Redige PII do texto:
    - CPF (formatado ou não)
    - Cartões de crédito/débito
    - Tokens Bearer
    - API keys/secrets (palavras-chave)
    - Emails
    - Telefones
    """
    s = text
    s = _CPF_RE.sub("[REDACTED_CPF]", s)
    s = _CARD_RE.sub("[REDACTED_CARD]", s)
    s = _TOKEN_RE.sub("bearer [REDACTED_TOKEN]", s)
    # Não remove palavras-chaves (para debug), mas ajuda a evitar leak acidental
    s = _APIKEY_RE.sub("[REDACTED_SECRET_KEYWORD]", s)
    s = _EMAIL_RE.sub("[REDACTED_EMAIL]", s)
    s = _PHONE_RE.sub("[REDACTED_PHONE]", s)
    return s
