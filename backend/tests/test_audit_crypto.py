from __future__ import annotations

import base64
import json
import os

import pytest

from app.config import settings
from app.crypto_simple import decrypt_text, encrypt_text, key_id, load_key


def test_load_key_valid():
    """Testa carregamento de chave válida."""
    # Gerar chave válida
    key_bytes = os.urandom(32)
    key_b64 = base64.b64encode(key_bytes).decode()
    settings.audit_enc_key_b64 = key_b64

    key = load_key()
    assert key is not None
    assert len(key) == 32
    assert key == key_bytes


def test_load_key_invalid_length():
    """Testa que chave com tamanho inválido retorna None."""
    key_b64 = base64.b64encode(b"short").decode()
    settings.audit_enc_key_b64 = key_b64

    key = load_key()
    assert key is None


def test_load_key_not_configured():
    """Testa que chave não configurada retorna None."""
    settings.audit_enc_key_b64 = None
    key = load_key()
    assert key is None


def test_key_id():
    """Testa geração de key id."""
    key = os.urandom(32)
    kid = key_id(key)
    assert len(kid) == 16
    assert isinstance(kid, str)


def test_encrypt_text():
    """Testa criptografia de texto."""
    key_bytes = os.urandom(32)
    key_b64 = base64.b64encode(key_bytes).decode()
    settings.audit_enc_key_b64 = key_b64
    settings.audit_log_raw_max_chars = 2000

    plaintext = "Texto secreto para criptografar"
    aad = b"trace_id_123"

    envelope = encrypt_text(plaintext, aad)
    assert envelope is not None
    assert envelope["alg"] == "AES-256-GCM"
    assert "kid" in envelope
    assert "nonce_b64" in envelope
    assert "ct_b64" in envelope

    # Validar que é base64 válido
    nonce = base64.b64decode(envelope["nonce_b64"])
    assert len(nonce) == 12

    ct = base64.b64decode(envelope["ct_b64"])
    assert len(ct) > 0


def test_encrypt_text_truncates_long_text():
    """Testa que texto muito longo é truncado."""
    key_bytes = os.urandom(32)
    key_b64 = base64.b64encode(key_bytes).decode()
    settings.audit_enc_key_b64 = key_b64
    settings.audit_log_raw_max_chars = 100

    plaintext = "a" * 200
    aad = b"trace_id_123"

    envelope = encrypt_text(plaintext, aad)
    assert envelope is not None
    # Decriptografar e verificar que foi truncado
    decrypted = decrypt_text(envelope, aad)
    assert decrypted is not None
    assert len(decrypted) <= 100


def test_decrypt_text():
    """Testa descriptografia de texto."""
    key_bytes = os.urandom(32)
    key_b64 = base64.b64encode(key_bytes).decode()
    settings.audit_enc_key_b64 = key_b64
    settings.audit_log_raw_max_chars = 2000

    plaintext = "Texto secreto para criptografar"
    aad = b"trace_id_123"

    envelope = encrypt_text(plaintext, aad)
    assert envelope is not None

    decrypted = decrypt_text(envelope, aad)
    assert decrypted == plaintext


def test_decrypt_text_wrong_aad():
    """Testa que descriptografia com AAD errado falha."""
    key_bytes = os.urandom(32)
    key_b64 = base64.b64encode(key_bytes).decode()
    settings.audit_enc_key_b64 = key_b64
    settings.audit_log_raw_max_chars = 2000

    plaintext = "Texto secreto"
    aad1 = b"trace_id_123"
    aad2 = b"trace_id_456"

    envelope = encrypt_text(plaintext, aad1)
    assert envelope is not None

    # Tentar descriptografar com AAD diferente deve falhar
    decrypted = decrypt_text(envelope, aad2)
    assert decrypted is None


def test_encrypt_text_no_key():
    """Testa que criptografia sem chave retorna None."""
    settings.audit_enc_key_b64 = None
    envelope = encrypt_text("teste", b"aad")
    assert envelope is None
