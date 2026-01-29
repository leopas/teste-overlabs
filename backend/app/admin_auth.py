from __future__ import annotations

import secrets

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBasic, HTTPBasicCredentials

from .config import settings


_security = HTTPBasic(auto_error=False)


def require_admin(credentials: HTTPBasicCredentials | None = Depends(_security)) -> str:
    """
    Protege rotas públicas de administração com Basic Auth.

    Configure via env/secrets:
    - ADMIN_USERNAME
    - ADMIN_PASSWORD
    """
    if not settings.admin_username or not settings.admin_password:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Admin auth não configurado (defina ADMIN_USERNAME e ADMIN_PASSWORD).",
        )

    if credentials is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Unauthorized",
            headers={"WWW-Authenticate": 'Basic realm="admin"'},
        )

    ok_user = secrets.compare_digest(credentials.username or "", settings.admin_username)
    ok_pass = secrets.compare_digest(credentials.password or "", settings.admin_password)
    if not (ok_user and ok_pass):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Unauthorized",
            headers={"WWW-Authenticate": 'Basic realm="admin"'},
        )

    return credentials.username

