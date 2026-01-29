#!/usr/bin/env python3
"""
Validador de arquivo .env para deploy Azure.

Valida formato, required keys, tipos básicos e classifica secrets vs non-secrets.
"""

import argparse
import re
import sys
from pathlib import Path
from typing import Dict, List, Set, Tuple


# DENYLIST: variáveis que NÃO são secrets mesmo contendo palavras-chave
DENYLIST: Set[str] = {
    "PORT",
    "ENV",
    "LOG_LEVEL",
    "HOST",
    "QDRANT_URL",
    "REDIS_URL",
    "DOCS_ROOT",
    "MYSQL_PORT",
    "MYSQL_HOST",
    "MYSQL_DATABASE",
    "MYSQL_SSL_CA",
    "OTEL_ENABLED",
    "USE_OPENAI_EMBEDDINGS",
    "AUDIT_LOG_ENABLED",
    "AUDIT_LOG_INCLUDE_TEXT",
    "AUDIT_LOG_RAW_MODE",
    "AUDIT_LOG_REDACT",
    "ABUSE_CLASSIFIER_ENABLED",
    "PROMPT_FIREWALL_ENABLED",
    "PIPELINE_LOG_ENABLED",
    "PIPELINE_LOG_INCLUDE_TEXT",
    "TRACE_SINK",
    "AUDIT_ENC_AAD_MODE",
    "RATE_LIMIT_PER_MINUTE",
    "CACHE_TTL_SECONDS",
    "PROMPT_FIREWALL_RULES_PATH",
    "PROMPT_FIREWALL_MAX_RULES",
    "PROMPT_FIREWALL_RELOAD_CHECK_SECONDS",
    "FIREWALL_LOG_SAMPLE_RATE",
    "ABUSE_RISK_THRESHOLD",
    "AUDIT_LOG_RAW_MAX_CHARS",
    "TRACE_SINK_QUEUE_SIZE",
    "OPENAI_MODEL",
    "OPENAI_MODEL_ENRICHMENT",
    "OPENAI_EMBEDDINGS_MODEL",
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "DOCS_HOST_PATH",
    "API_PORT",
    "QDRANT_PORT",
    "REDIS_PORT",
}

# Palavras-chave que indicam secrets
SECRET_KEYWORDS = {"KEY", "SECRET", "TOKEN", "PASSWORD", "PASS", "CONNECTION", "API"}

# Required keys (mínimo para funcionar)
# Nota: QDRANT_URL e REDIS_URL são configurados automaticamente pelo App Service
# então não são obrigatórios no .env
REQUIRED_KEYS = set()

# Keys que devem ser inteiros
INTEGER_KEYS = {
    "MYSQL_PORT",
    "RATE_LIMIT_PER_MINUTE",
    "CACHE_TTL_SECONDS",
    "PROMPT_FIREWALL_MAX_RULES",
    "PROMPT_FIREWALL_RELOAD_CHECK_SECONDS",
    "AUDIT_LOG_RAW_MAX_CHARS",
    "TRACE_SINK_QUEUE_SIZE",
    "API_PORT",
    "QDRANT_PORT",
    "REDIS_PORT",
}

# Keys que devem ser booleanos (0/1, true/false, yes/no)
BOOLEAN_KEYS = {
    "OTEL_ENABLED",
    "USE_OPENAI_EMBEDDINGS",
    "AUDIT_LOG_ENABLED",
    "AUDIT_LOG_INCLUDE_TEXT",
    "AUDIT_LOG_REDACT",
    "ABUSE_CLASSIFIER_ENABLED",
    "PROMPT_FIREWALL_ENABLED",
    "PIPELINE_LOG_ENABLED",
    "PIPELINE_LOG_INCLUDE_TEXT",
}


def is_secret(key: str) -> bool:
    """Determina se uma variável é um secret baseado em seu nome."""
    if key in DENYLIST:
        return False
    
    key_upper = key.upper()
    return any(keyword in key_upper for keyword in SECRET_KEYWORDS)


def is_valid_keyvault_name(name: str) -> bool:
    """Valida se o nome é válido para Key Vault secret name."""
    # Key Vault secret names: alphanumeric, hyphens, underscores
    # Length: 1-127 chars
    if not name or len(name) > 127:
        return False
    pattern = r"^[a-zA-Z0-9_-]+$"
    return bool(re.match(pattern, name))


def normalize_keyvault_name(key: str) -> str:
    """Normaliza nome de variável para Key Vault secret name."""
    # Trocar _ por -
    normalized = key.replace("_", "-").lower()
    return normalized


def parse_env_file(env_path: Path) -> Tuple[Dict[str, str], List[str]]:
    """Lê arquivo .env e retorna dict de variáveis e lista de erros."""
    env_vars: Dict[str, str] = {}
    errors: List[str] = []
    
    if not env_path.exists():
        errors.append(f"Arquivo não encontrado: {env_path}")
        return env_vars, errors
    
    try:
        with open(env_path, "r", encoding="utf-8") as f:
            for line_num, line in enumerate(f, 1):
                line = line.strip()
                
                # Ignorar linhas vazias e comentários
                if not line or line.startswith("#"):
                    continue
                
                # Validar formato KEY=VALUE
                if "=" not in line:
                    errors.append(f"Linha {line_num}: formato inválido (esperado KEY=VALUE)")
                    continue
                
                parts = line.split("=", 1)
                if len(parts) != 2:
                    errors.append(f"Linha {line_num}: formato inválido")
                    continue
                
                key = parts[0].strip()
                value = parts[1].strip()
                
                # Remover comentários inline (tudo após #)
                if "#" in value:
                    # Verificar se # está dentro de aspas
                    in_quotes = False
                    quote_char = None
                    for i, char in enumerate(value):
                        if char in ('"', "'") and (i == 0 or value[i-1] != '\\'):
                            if not in_quotes:
                                in_quotes = True
                                quote_char = char
                            elif char == quote_char:
                                in_quotes = False
                                quote_char = None
                        elif char == '#' and not in_quotes:
                            value = value[:i].strip()
                            break
                
                # Remover aspas se houver
                if value.startswith('"') and value.endswith('"'):
                    value = value[1:-1]
                elif value.startswith("'") and value.endswith("'"):
                    value = value[1:-1]
                
                if not key:
                    errors.append(f"Linha {line_num}: chave vazia")
                    continue
                
                # Validar nome para Key Vault
                normalized = normalize_keyvault_name(key)
                if not is_valid_keyvault_name(normalized):
                    errors.append(
                        f"Linha {line_num}: nome '{key}' não é válido para Key Vault "
                        f"(normalizado: '{normalized}')"
                    )
                
                env_vars[key] = value
    except Exception as e:
        errors.append(f"Erro ao ler arquivo: {e}")
    
    return env_vars, errors


def validate_types(env_vars: Dict[str, str]) -> List[str]:
    """Valida tipos básicos de variáveis."""
    errors: List[str] = []
    
    for key, value in env_vars.items():
        # Validar inteiros
        if key in INTEGER_KEYS:
            try:
                int(value)
            except ValueError:
                errors.append(f"{key}: deve ser um inteiro, recebido '{value}'")
        
        # Validar booleanos
        if key in BOOLEAN_KEYS:
            value_lower = value.lower()
            valid_bools = {"0", "1", "true", "false", "yes", "no", ""}
            if value_lower not in valid_bools:
                errors.append(
                    f"{key}: deve ser booleano (0/1, true/false, yes/no), recebido '{value}'"
                )
    
    return errors


def validate_required(env_vars: Dict[str, str]) -> List[str]:
    """Valida se required keys estão presentes."""
    errors: List[str] = []
    missing = REQUIRED_KEYS - set(env_vars.keys())
    if missing:
        errors.append(f"Keys obrigatórias ausentes: {', '.join(sorted(missing))}")
    return errors


def validate_secrets(env_vars: Dict[str, str]) -> List[str]:
    """Valida que secrets obrigatórios não estão vazios."""
    errors: List[str] = []
    
    # Secrets que são obrigatórios se presentes (não podem estar vazios)
    # Secrets opcionais vazios são permitidos (serão configurados depois)
    required_secrets_when_present = {
        # Adicione aqui secrets que devem ter valor se presentes
    }
    
    for key, value in env_vars.items():
        if is_secret(key) and not value:
            # Só reclamar se for um secret conhecido como obrigatório quando presente
            if key in required_secrets_when_present:
                errors.append(f"Secret '{key}' está vazio (deve ter valor se presente)")
            # Para outros secrets, apenas avisar (não é erro)
    
    return errors


def classify_variables(env_vars: Dict[str, str]) -> Tuple[Dict[str, str], Dict[str, str]]:
    """Classifica variáveis em secrets e non-secrets."""
    secrets: Dict[str, str] = {}
    non_secrets: Dict[str, str] = {}
    
    for key, value in env_vars.items():
        if is_secret(key):
            secrets[key] = value
        else:
            non_secrets[key] = value
    
    return secrets, non_secrets


def main():
    parser = argparse.ArgumentParser(description="Valida arquivo .env para deploy Azure")
    parser.add_argument(
        "--env",
        type=Path,
        default=Path(".env"),
        help="Caminho para arquivo .env (default: .env)",
    )
    parser.add_argument(
        "--show-classification",
        action="store_true",
        help="Mostrar classificação de secrets vs non-secrets",
    )
    
    args = parser.parse_args()
    
    print(f"Validando arquivo: {args.env}")
    print()
    
    # Parse e validações básicas
    env_vars, parse_errors = parse_env_file(args.env)
    if parse_errors:
        print("[ERRO] Erros de parsing:")
        for error in parse_errors:
            print(f"  - {error}")
        print()
        return 1
    
    print(f"[OK] Arquivo lido com sucesso ({len(env_vars)} variáveis)")
    print()
    
    # Validações
    all_errors: List[str] = []
    
    required_errors = validate_required(env_vars)
    if required_errors:
        all_errors.extend(required_errors)
    
    type_errors = validate_types(env_vars)
    if type_errors:
        all_errors.extend(type_errors)
    
    secret_errors = validate_secrets(env_vars)
    if secret_errors:
        all_errors.extend(secret_errors)
    
    if all_errors:
        print("[ERRO] Erros de validação:")
        for error in all_errors:
            print(f"  - {error}")
        print()
        return 1
    
    print("[OK] Todas as validações passaram")
    print()
    
    # Classificação
    secrets, non_secrets = classify_variables(env_vars)
    
    print(f"[INFO] Classificação:")
    print(f"  - Secrets: {len(secrets)}")
    print(f"  - Non-secrets: {len(non_secrets)}")
    print()
    
    if args.show_classification:
        print("[SECRETS]")
        for key in sorted(secrets.keys()):
            print(f"  - {key}")
        print()
        print("[NON-SECRETS]")
        for key in sorted(non_secrets.keys()):
            print(f"  - {key}")
        print()
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
