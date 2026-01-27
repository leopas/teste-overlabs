from __future__ import annotations

import pytest

from app.redaction import normalize_text, redact_text, sha256_text


def test_normalize_text():
    """Testa normalização de texto."""
    assert normalize_text("  teste  com  espaços  ") == "teste com espaços"
    assert normalize_text("teste\ncom\nlinhas") == "teste com linhas"
    assert normalize_text("teste\x00com\x01control") == "testecomcontrol"


def test_sha256_text_consistency():
    """Testa que mesmo texto normalizado gera mesmo hash."""
    text1 = "  teste  com  espaços  "
    text2 = "teste com espaços"
    assert sha256_text(text1) == sha256_text(text2)


def test_redact_text_cpf():
    """Testa redação de CPF."""
    text = "O CPF é 123.456.789-00"
    redacted = redact_text(text)
    assert "[REDACTED_CPF]" in redacted
    assert "123.456.789-00" not in redacted

    text2 = "CPF: 12345678900"
    redacted2 = redact_text(text2)
    assert "[REDACTED_CPF]" in redacted2
    assert "12345678900" not in redacted2


def test_redact_text_card():
    """Testa redação de cartão."""
    text = "Cartão: 4532 1234 5678 9010"
    redacted = redact_text(text)
    assert "[REDACTED_CARD]" in redacted
    assert "4532 1234 5678 9010" not in redacted


def test_redact_text_email():
    """Testa redação de email."""
    text = "Email: usuario@exemplo.com"
    redacted = redact_text(text)
    assert "[REDACTED_EMAIL]" in redacted
    assert "usuario@exemplo.com" not in redacted


def test_redact_text_token():
    """Testa redação de token Bearer."""
    text = "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    redacted = redact_text(text)
    assert "bearer [REDACTED_TOKEN]" in redacted.lower()
    assert "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" not in redacted


def test_redact_text_preserves_structure():
    """Testa que redação preserva estrutura do texto."""
    text = "O CPF é 123.456.789-00 e o email é usuario@exemplo.com"
    redacted = redact_text(text)
    assert "O" in redacted
    assert "é" in redacted
    assert "e o" in redacted
