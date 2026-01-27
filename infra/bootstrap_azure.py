#!/usr/bin/env python3
"""
Bootstrap script para criar infraestrutura Azure para deploy.

Cria recursos de forma idempotente:
- Resource Group
- ACR (reutiliza se existir)
- Key Vault
- App Service Plan
- Web App (multi-container)
- Storage Account + File Share
- Staging Slot

Configura:
- Managed Identity na Web App
- Permissões no Key Vault
- App Settings (Key Vault refs para secrets)
- Azure Files mount
"""

import argparse
import json
import os
import random
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import sys
from pathlib import Path

# Adicionar diretório infra ao path para imports
sys.path.insert(0, str(Path(__file__).parent))

from validate_env import classify_variables, is_secret, normalize_keyvault_name, parse_env_file


def find_az_cli() -> str:
    """Encontra o caminho do Azure CLI, tentando locais comuns no Windows."""
    # Tentar usar 'az' diretamente (se estiver no PATH)
    try:
        result = subprocess.run(
            ["az", "--version"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            return "az"
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    
    # Locais comuns no Windows
    if sys.platform == "win32":
        common_paths = [
            r"C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd",
            r"C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin\az.cmd",
            os.path.expanduser(r"~\AppData\Local\Microsoft\WindowsApps\az.cmd"),
        ]
        
        for path in common_paths:
            if os.path.exists(path):
                return path
    
    # Se não encontrou, retornar 'az' e deixar o erro acontecer naturalmente
    return "az"


def run_az_command(cmd: List[str], check: bool = True, capture_output: bool = True) -> Tuple[int, str, str]:
    """Executa comando Azure CLI e retorna código, stdout, stderr."""
    az_path = find_az_cli()
    
    try:
        result = subprocess.run(
            [az_path] + cmd,
            capture_output=capture_output,
            text=True,
            check=False,
            shell=(sys.platform == "win32" and az_path.endswith(".cmd")),
        )
        stdout = result.stdout.strip() if result.stdout else ""
        stderr = result.stderr.strip() if result.stderr else ""
        
        if check and result.returncode != 0:
            print(f"[ERRO] Erro ao executar: {az_path} {' '.join(cmd)}")
            if stderr:
                print(f"   stderr: {stderr}")
            sys.exit(1)
        
        return result.returncode, stdout, stderr
    except FileNotFoundError:
        print("[ERRO] Azure CLI não encontrado. Instale: https://aka.ms/InstallAzureCLI")
        print(f"[INFO] Tentou usar: {az_path}")
        sys.exit(1)


def az_resource_exists(resource_type: str, name: str, resource_group: Optional[str] = None) -> bool:
    """Verifica se um recurso Azure existe."""
    cmd = ["show", "--name", name]
    if resource_group:
        cmd.extend(["--resource-group", resource_group])
    
    # Adicionar tipo se necessário
    if resource_type == "acr":
        cmd = ["acr", "show", "--name", name]
    elif resource_type == "keyvault":
        cmd = ["keyvault", "show", "--name", name]
    elif resource_type == "appservice":
        cmd = ["webapp", "show", "--name", name, "--resource-group", resource_group]
    elif resource_type == "appserviceplan":
        cmd = ["appservice", "plan", "show", "--name", name, "--resource-group", resource_group]
    elif resource_type == "storage":
        cmd = ["storage", "account", "show", "--name", name, "--resource-group", resource_group]
    else:
        return False
    
    code, _, _ = run_az_command(cmd, check=False)
    return code == 0


def get_azure_context() -> Dict[str, str]:
    """Obtém contexto Azure atual (subscription, tenant)."""
    code, stdout, _ = run_az_command(["account", "show"], check=False)
    if code != 0:
        print("[ERRO] Não há subscription selecionada. Execute: az account set --subscription <id>")
        sys.exit(1)
    
    account_info = json.loads(stdout)
    return {
        "subscriptionId": account_info["id"],
        "tenantId": account_info["tenantId"],
    }


def generate_suffix() -> str:
    """Gera suffix random de 3 dígitos."""
    return f"{random.randint(100, 999)}"


def create_resource_group(name: str, location: str) -> bool:
    """Cria Resource Group se não existir."""
    if az_resource_exists("group", name):
        print(f"[OK] Resource Group '{name}' já existe")
        return False
    
    print(f"[INFO] Criando Resource Group: {name}")
    run_az_command(["group", "create", "--name", name, "--location", location])
    print(f"[OK] Resource Group criado")
    return True


def ensure_acr(name: str, resource_group: str, location: str) -> bool:
    """Garante que ACR existe (cria se não existir)."""
    if az_resource_exists("acr", name):
        print(f"[OK] ACR '{name}' já existe (reutilizando)")
        return False
    
    print(f"[INFO] Criando ACR: {name}")
    run_az_command([
        "acr", "create",
        "--name", name,
        "--resource-group", resource_group,
        "--sku", "Basic",
        "--admin-enabled", "true",
    ])
    print(f"[OK] ACR criado")
    return True


def get_current_user_object_id() -> str:
    """Obtém o Object ID do usuário atual."""
    code, stdout, _ = run_az_command(["ad", "signed-in-user", "show", "--query", "id", "-o", "tsv"], check=False)
    if code == 0 and stdout and stdout.strip():
        return stdout.strip()
    return ""


def grant_keyvault_permissions(keyvault_name: str, resource_group: str, subscription_id: str) -> None:
    """Concede permissões ao usuário atual no Key Vault."""
    print(f"  [INFO] Configurando permissões no Key Vault...")
    
    # Obter Object ID do usuário atual
    user_oid = get_current_user_object_id()
    
    if user_oid:
        # Usar RBAC (Role-Based Access Control)
        scope = f"/subscriptions/{subscription_id}/resourceGroups/{resource_group}/providers/Microsoft.KeyVault/vaults/{keyvault_name}"
        
        # Verificar se a role já existe
        code, stdout, _ = run_az_command([
            "role", "assignment", "list",
            "--scope", scope,
            "--assignee", user_oid,
            "--role", "Key Vault Secrets Officer",
            "--query", "[0].id",
            "-o", "tsv"
        ], check=False)
        
        if code != 0 or not stdout or not stdout.strip():
            # Dar permissão usando RBAC
            code, _, _ = run_az_command([
                "role", "assignment", "create",
                "--scope", scope,
                "--assignee", user_oid,
                "--role", "Key Vault Secrets Officer",
            ], check=False)  # Não falhar se já existir
            if code == 0:
                print(f"  [OK] Permissão concedida via RBAC")
            else:
                print(f"  [AVISO] Erro ao conceder permissão (pode já existir)")
        else:
            print(f"  [OK] Permissão já existe")
    else:
        # Fallback: usar access policy (legado) - mas Key Vault com RBAC não aceita isso
        print(f"  [AVISO] Não foi possível obter Object ID do usuário")
        print(f"  [INFO] Tente conceder manualmente:")
        print(f"    az role assignment create --scope {scope} --assignee <seu-email> --role 'Key Vault Secrets Officer'")


def create_key_vault(name: str, resource_group: str, location: str, subscription_id: str) -> bool:
    """Cria Key Vault se não existir."""
    created = False
    if az_resource_exists("keyvault", name):
        print(f"[OK] Key Vault '{name}' já existe")
    else:
        print(f"[INFO] Criando Key Vault: {name}")
        run_az_command([
            "keyvault", "create",
            "--name", name,
            "--resource-group", resource_group,
            "--location", location,
            "--sku", "standard",
            "--enable-rbac-authorization", "true",  # Usar RBAC
        ])
        print(f"[OK] Key Vault criado")
        created = True
    
    # Sempre garantir permissões (mesmo se já existir)
    grant_keyvault_permissions(name, resource_group, subscription_id)
    
    return created


def upload_secrets_to_keyvault(keyvault_name: str, secrets: Dict[str, str]) -> None:
    """Upload secrets do .env para Key Vault."""
    print(f"[INFO] Uploading {len(secrets)} secrets para Key Vault...")
    
    for key, value in secrets.items():
        normalized_name = normalize_keyvault_name(key)
        print(f"  - {key} -> {normalized_name}")
        
        # Verificar se o valor está vazio
        if not value or not value.strip():
            print(f"    [AVISO] Secret '{key}' está vazio, pulando...")
            continue
        
        # Usar arquivo temporário para valores que podem ter caracteres especiais
        import tempfile
        with tempfile.NamedTemporaryFile(mode='w', delete=False, encoding='utf-8') as f:
            f.write(value)
            temp_file = f.name
        
        try:
            run_az_command([
                "keyvault", "secret", "set",
                "--vault-name", keyvault_name,
                "--name", normalized_name,
                "--file", temp_file,
            ])
        finally:
            # Limpar arquivo temporário
            import os
            try:
                os.unlink(temp_file)
            except:
                pass
    
    print(f"[OK] Secrets uploaded")


def create_app_service_plan(name: str, resource_group: str, location: str) -> bool:
    """Cria App Service Plan se não existir."""
    if az_resource_exists("appserviceplan", name, resource_group):
        print(f"[OK] App Service Plan '{name}' já existe")
        return False
    
    print(f"[INFO] Criando App Service Plan: {name}")
    run_az_command([
        "appservice", "plan", "create",
        "--name", name,
        "--resource-group", resource_group,
        "--location", location,
        "--is-linux",
        "--sku", "B1",  # Basic B1 (pode ser ajustado)
    ])
    print(f"[OK] App Service Plan criado")
    return True


def create_web_app(
    name: str,
    resource_group: str,
    app_service_plan: str,
    acr_name: str,
) -> bool:
    """Cria Web App se não existir."""
    if az_resource_exists("appservice", name, resource_group):
        print(f"[OK] Web App '{name}' já existe")
        return False
    
    print(f"[INFO] Criando Web App: {name}")
    run_az_command([
        "webapp", "create",
        "--name", name,
        "--resource-group", resource_group,
        "--plan", app_service_plan,
        "--runtime", "DOCKER|mcr.microsoft.com/azure-app-service/php:8.2",  # Placeholder, será sobrescrito pelo compose
    ])
    
    # Habilitar multi-container
    run_az_command([
        "webapp", "config", "set",
        "--name", name,
        "--resource-group", resource_group,
        "--linux-fx-version", "DOCKER|mcr.microsoft.com/azure-app-service/php:8.2",
    ])
    
    # Habilitar System Assigned Managed Identity
    print(f"  [INFO] Habilitando Managed Identity...")
    run_az_command([
        "webapp", "identity", "assign",
        "--name", name,
        "--resource-group", resource_group,
    ])
    
    # Configurar porta
    run_az_command([
        "webapp", "config", "appsettings", "set",
        "--name", name,
        "--resource-group", resource_group,
        "--settings", "WEBSITES_PORT=8000",
    ])
    
    print(f"[OK] Web App criado")
    return True


def grant_keyvault_access(webapp_name: str, resource_group: str, keyvault_name: str) -> None:
    """Concede permissões ao Managed Identity da Web App no Key Vault."""
    print(f"[INFO] Concedendo permissões no Key Vault...")
    
    # Obter principal ID do Managed Identity
    _, stdout, _ = run_az_command([
        "webapp", "identity", "show",
        "--name", webapp_name,
        "--resource-group", resource_group,
    ])
    
    identity_info = json.loads(stdout)
    principal_id = identity_info.get("principalId")
    
    if not principal_id:
        print("⚠️  Managed Identity não encontrado")
        return
    
    # Dar permissões (Get, List)
    run_az_command([
        "keyvault", "set-policy",
        "--name", keyvault_name,
        "--object-id", principal_id,
        "--secret-permissions", "get", "list",
    ])
    
    print(f"[OK] Permissões concedidas")


def configure_app_settings(
    webapp_name: str,
    resource_group: str,
    keyvault_name: str,
    secrets: Dict[str, str],
    non_secrets: Dict[str, str],
) -> None:
    """Configura App Settings (Key Vault refs para secrets, valores diretos para non-secrets)."""
    print(f"[INFO] Configurando App Settings...")
    
    settings: List[str] = []
    
    # Non-secrets: valores diretos
    for key, value in non_secrets.items():
        # Escapar para shell
        value_escaped = value.replace('"', '\\"').replace('$', '\\$')
        settings.append(f"{key}={value_escaped}")
    
    # Secrets: Key Vault references
    for key in secrets.keys():
        normalized_name = normalize_keyvault_name(key)
        secret_uri = f"https://{keyvault_name}.vault.azure.net/secrets/{normalized_name}/"
        kv_ref = f"@Microsoft.KeyVault(SecretUri={secret_uri})"
        settings.append(f"{key}={kv_ref}")
    
    # Configurar todas de uma vez
    run_az_command([
        "webapp", "config", "appsettings", "set",
        "--name", webapp_name,
        "--resource-group", resource_group,
        "--settings", *settings,
    ])
    
    print(f"[OK] App Settings configurados ({len(settings)} variáveis)")


def create_storage_account(name: str, resource_group: str, location: str) -> bool:
    """Cria Storage Account se não existir."""
    if az_resource_exists("storage", name, resource_group):
        print(f"[OK] Storage Account '{name}' já existe")
        return False
    
    print(f"[INFO] Criando Storage Account: {name}")
    run_az_command([
        "storage", "account", "create",
        "--name", name,
        "--resource-group", resource_group,
        "--location", location,
        "--sku", "Standard_LRS",
        "--kind", "StorageV2",
    ])
    print(f"[OK] Storage Account criado")
    return True


def create_file_share(storage_account: str, share_name: str, resource_group: str) -> bool:
    """Cria File Share se não existir."""
    print(f"[INFO] Criando File Share: {share_name}")
    
    # Verificar se já existe
    code, _, _ = run_az_command([
        "storage", "share", "show",
        "--name", share_name,
        "--account-name", storage_account,
    ], check=False)
    
    if code == 0:
        print(f"[OK] File Share '{share_name}' já existe")
        return False
    
    run_az_command([
        "storage", "share", "create",
        "--name", share_name,
        "--account-name", storage_account,
        "--quota", "10",  # 10 GB
    ])
    print(f"[OK] File Share criado")
    return True


def configure_azure_files_mount(
    webapp_name: str,
    resource_group: str,
    storage_account: str,
    file_share: str,
    mount_path: str = "/mnt/qdrant",
) -> None:
    """Configura mount de Azure Files no App Service."""
    print(f"[INFO] Configurando Azure Files mount: {mount_path}")
    
    # Obter storage key
    _, stdout, _ = run_az_command([
        "storage", "account", "keys", "list",
        "--account-name", storage_account,
        "--resource-group", resource_group,
        "--query", "[0].value",
        "--output", "tsv",
    ])
    
    storage_key = stdout.strip()
    
    # Configurar mount
    run_az_command([
        "webapp", "config", "storage-account", "add",
        "--name", webapp_name,
        "--resource-group", resource_group,
        "--custom-id", "qdrant-storage",
        "--storage-type", "AzureFiles",
        "--share-name", file_share,
        "--account-name", storage_account,
        "--access-key", storage_key,
        "--mount-path", mount_path,
    ])
    
    print(f"[OK] Azure Files mount configurado")


def create_staging_slot(webapp_name: str, resource_group: str) -> bool:
    """Cria staging slot se não existir."""
    slot_name = "staging"
    
    code, _, _ = run_az_command([
        "webapp", "deployment", "slot", "show",
        "--name", webapp_name,
        "--resource-group", resource_group,
        "--slot", slot_name,
    ], check=False)
    
    if code == 0:
        print(f"[OK] Staging slot já existe")
        return False
    
    print(f"[INFO] Criando staging slot...")
    run_az_command([
        "webapp", "deployment", "slot", "create",
        "--name", webapp_name,
        "--resource-group", resource_group,
        "--slot", slot_name,
        "--configuration-source", webapp_name,
    ])
    print(f"[OK] Staging slot criado")
    return True


def save_deploy_state(
    state_path: Path,
    context: Dict[str, str],
    resource_names: Dict[str, str],
    location: str,
) -> None:
    """Salva estado de deploy em JSON (sem secrets)."""
    state = {
        "subscriptionId": context["subscriptionId"],
        "tenantId": context["tenantId"],
        "location": location,
        "resourceGroup": resource_names["resource_group"],
        "acrName": resource_names["acr_name"],
        "keyVaultName": resource_names["key_vault"],
        "appServiceName": resource_names["web_app"],
        "appServicePlanName": resource_names["app_service_plan"],
        "storageAccountName": resource_names["storage_account"],
        "fileShareName": resource_names["file_share"],
        "composeFile": "docker-compose.azure.yml",
        "imageRepos": {
            "api": "choperia-api",
            "qdrant": "qdrant/qdrant",
            "redis": "redis",
        },
        "createdAt": datetime.utcnow().isoformat() + "Z",
        "updatedAt": datetime.utcnow().isoformat() + "Z",
    }
    
    state_path.parent.mkdir(parents=True, exist_ok=True)
    
    with open(state_path, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, ensure_ascii=False)
    
    print(f"[OK] Estado salvo em: {state_path}")


def main():
    parser = argparse.ArgumentParser(description="Bootstrap infraestrutura Azure")
    parser.add_argument(
        "--env",
        type=Path,
        default=Path(".env"),
        help="Caminho para arquivo .env (default: .env)",
    )
    parser.add_argument(
        "--stage",
        default="prod",
        help="Stage do deploy (default: prod)",
    )
    parser.add_argument(
        "--location",
        default="brazilsouth",
        help="Localização Azure (default: brazilsouth)",
    )
    parser.add_argument(
        "--acr-name",
        default="acrchoperia",
        help="Nome do ACR (default: acrchoperia)",
    )
    parser.add_argument(
        "--suffix",
        help="Suffix para nomes de recursos (default: random 3 dígitos)",
    )
    
    args = parser.parse_args()
    
    # Validar .env
    print("[INFO] Validando arquivo .env...")
    env_vars, errors = parse_env_file(args.env)
    if errors:
        print("[ERRO] Erros ao ler .env:")
        for error in errors:
            print(f"  - {error}")
        sys.exit(1)
    
    if not env_vars:
        print("[ERRO] Nenhuma variável encontrada no .env")
        sys.exit(1)
    
    print(f"[OK] {len(env_vars)} variáveis encontradas\n")
    
    # Classificar variáveis
    secrets, non_secrets = classify_variables(env_vars)
    print(f"[INFO] Classificação: {len(secrets)} secrets, {len(non_secrets)} non-secrets\n")
    
    # Obter contexto Azure
    print("[INFO] Verificando contexto Azure...")
    context = get_azure_context()
    print(f"[OK] Subscription: {context['subscriptionId']}\n")
    
    # Gerar suffix
    suffix = args.suffix or generate_suffix()
    print(f"[INFO] Suffix: {suffix}\n")
    
    # Nomes de recursos
    resource_names = {
        "resource_group": f"rg-overlabs-{args.stage}",
        "acr_name": args.acr_name,
        "key_vault": f"kv-overlabs-{args.stage}-{suffix}",
        "app_service_plan": f"asp-overlabs-{args.stage}-{suffix}",
        "web_app": f"app-overlabs-{args.stage}-{suffix}",
        "storage_account": f"saoverlabs{args.stage}{suffix}".lower()[:24],  # Max 24 chars
        "file_share": "qdrant-storage",
    }
    
    print("[INFO] Recursos a criar:")
    for key, value in resource_names.items():
        print(f"  - {key}: {value}")
    print()
    
    # Criar recursos
    print("[INFO] Criando recursos Azure...\n")
    
    create_resource_group(resource_names["resource_group"], args.location)
    print()
    
    ensure_acr(resource_names["acr_name"], resource_names["resource_group"], args.location)
    print()
    
    create_key_vault(resource_names["key_vault"], resource_names["resource_group"], args.location, context["subscriptionId"])
    print()
    
    upload_secrets_to_keyvault(resource_names["key_vault"], secrets)
    print()
    
    create_app_service_plan(
        resource_names["app_service_plan"],
        resource_names["resource_group"],
        args.location,
    )
    print()
    
    create_web_app(
        resource_names["web_app"],
        resource_names["resource_group"],
        resource_names["app_service_plan"],
        resource_names["acr_name"],
    )
    print()
    
    grant_keyvault_access(
        resource_names["web_app"],
        resource_names["resource_group"],
        resource_names["key_vault"],
    )
    print()
    
    configure_app_settings(
        resource_names["web_app"],
        resource_names["resource_group"],
        resource_names["key_vault"],
        secrets,
        non_secrets,
    )
    print()
    
    create_storage_account(
        resource_names["storage_account"],
        resource_names["resource_group"],
        args.location,
    )
    print()
    
    create_file_share(
        resource_names["storage_account"],
        resource_names["file_share"],
        resource_names["resource_group"],
    )
    print()
    
    configure_azure_files_mount(
        resource_names["web_app"],
        resource_names["resource_group"],
        resource_names["storage_account"],
        resource_names["file_share"],
    )
    print()
    
    create_staging_slot(resource_names["web_app"], resource_names["resource_group"])
    print()
    
    # Salvar estado
    state_path = Path(".azure/deploy_state.json")
    save_deploy_state(state_path, context, resource_names, args.location)
    print()
    
    print("[OK] Bootstrap concluído com sucesso!")
    print()
    print("[INFO] Próximos passos:")
    print("  1. Verificar .azure/deploy_state.json")
    print("  2. Configurar OIDC no Azure AD (federated credentials)")
    print("  3. Fazer commit e push para main")
    print("  4. Pipeline executará automaticamente")
    print()


if __name__ == "__main__":
    main()
