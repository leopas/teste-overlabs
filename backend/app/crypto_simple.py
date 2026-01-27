from __future__ import annotations

import base64
import hashlib
import os
from typing import Any

import structlog

from .config import settings

log = structlog.get_logger("crypto")


def load_key() -> bytes | None:
    """
    Carrega e valida chave AES-256 (32 bytes) de AUDIT_ENC_KEY_B64.
    Retorna None se não configurado ou inválido.
    """
    key_b64 = settings.audit_enc_key_b64
    if not key_b64:
        return None

    try:
        key = base64.b64decode(key_b64)
        if len(key) != 32:
            log.error("audit_enc_key_invalid_length", expected=32, got=len(key))
            return None
        return key
    except Exception as e:
        log.error("audit_enc_key_decode_error", error=str(e))
        return None


def key_id(key: bytes) -> str:
    """
    Retorna identificador da chave (SHA256(key)[:16]) para rotação futura.
    """
    return hashlib.sha256(key).hexdigest()[:16]


def encrypt_text(plaintext: str, aad: bytes) -> dict[str, Any] | None:
    """
    Criptografa texto com AES-256-GCM.
    
    Args:
        plaintext: Texto a criptografar
        aad: Additional Authenticated Data (protege contra replay entre traces)
    
    Returns:
        Envelope JSON com alg, kid, nonce_b64, ct_b64 ou None se erro/chave não configurada
    """
    key = load_key()
    if not key:
        return None

    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM

        # Cortar texto para evitar payload gigante
        max_chars = settings.audit_log_raw_max_chars
        if len(plaintext) > max_chars:
            plaintext = plaintext[:max_chars]

        # Gerar nonce (12 bytes para GCM)
        nonce = os.urandom(12)

        # Criptografar
        aesgcm = AESGCM(key)
        plaintext_bytes = plaintext.encode("utf-8")
        ciphertext = aesgcm.encrypt(nonce, plaintext_bytes, aad)

        # Envelope JSON
        return {
            "alg": "AES-256-GCM",
            "kid": key_id(key),
            "nonce_b64": base64.b64encode(nonce).decode("ascii"),
            "ct_b64": base64.b64encode(ciphertext).decode("ascii"),
        }
    except Exception as e:
        log.error("encrypt_text_error", error=str(e))
        return None


def decrypt_text(envelope: dict[str, Any], aad: bytes) -> str | None:
    """
    Descriptografa texto (apenas para debug/admin futuro).
    
    Args:
        envelope: Envelope JSON com alg, kid, nonce_b64, ct_b64
        aad: Additional Authenticated Data (deve ser o mesmo usado na criptografia)
    
    Returns:
        Texto descriptografado ou None se erro
    """
    key = load_key()
    if not key:
        return None

    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM

        # Validar envelope
        if envelope.get("alg") != "AES-256-GCM":
            log.error("decrypt_invalid_alg", alg=envelope.get("alg"))
            return None

        # Validar key id (opcional, mas ajuda a detectar chave errada)
        expected_kid = key_id(key)
        if envelope.get("kid") != expected_kid:
            log.warning("decrypt_key_id_mismatch", expected=expected_kid, got=envelope.get("kid"))

        # Decodificar
        nonce = base64.b64decode(envelope["nonce_b64"])
        ciphertext = base64.b64decode(envelope["ct_b64"])

        # Descriptografar
        aesgcm = AESGCM(key)
        plaintext_bytes = aesgcm.decrypt(nonce, ciphertext, aad)
        return plaintext_bytes.decode("utf-8")
    except Exception as e:
        log.error("decrypt_text_error", error=str(e))
        return None
