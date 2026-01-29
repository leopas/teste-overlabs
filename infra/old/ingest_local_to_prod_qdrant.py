#!/usr/bin/env python3
"""
Script para executar ingestão localmente apontando para Qdrant de produção.

Uso:
    python infra/ingest_local_to_prod_qdrant.py
    python infra/ingest_local_to_prod_qdrant.py --truncate-first
    python infra/ingest_local_to_prod_qdrant.py --qdrant-url https://app-overlabs-qdrant-prod-300.azurecontainerapps.io
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

# Adicionar backend ao path
REPO_ROOT = Path(__file__).parent.parent
BACKEND_ROOT = REPO_ROOT / "backend"
if str(BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(BACKEND_ROOT))

# Tentar importar python-dotenv para ler .env
try:
    from dotenv import load_dotenv
    HAS_DOTENV = True
except ImportError:
    HAS_DOTENV = False

from qdrant_client import QdrantClient
from qdrant_client.http import models as qm


def get_qdrant_url_from_azure(resource_group: str, qdrant_app_name: str) -> str:
    """Obtém a URL do Qdrant Container App via Azure CLI."""
    try:
        result = subprocess.run(
            [
                "az",
                "containerapp",
                "show",
                "--name",
                qdrant_app_name,
                "--resource-group",
                resource_group,
                "--query",
                "properties.configuration.ingress.fqdn",
                "-o",
                "tsv",
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        fqdn = result.stdout.strip()
        if not fqdn:
            raise ValueError("FQDN vazio")
        return f"https://{fqdn}"
    except FileNotFoundError:
        # Azure CLI não está instalado ou não está no PATH
        raise FileNotFoundError(
            "Azure CLI não encontrado no PATH. Use --qdrant-url para fornecer a URL diretamente."
        )
    except subprocess.CalledProcessError as e:
        print(f"[ERRO] Falha ao obter URL do Qdrant: {e.stderr}", file=sys.stderr)
        raise
    except Exception as e:
        print(f"[ERRO] Erro inesperado: {e}", file=sys.stderr)
        raise


def load_deploy_state() -> dict:
    """Carrega deploy_state.json."""
    state_file = REPO_ROOT / ".azure" / "deploy_state.json"
    if not state_file.exists():
        raise FileNotFoundError(f"Arquivo {state_file} não encontrado")
    
    with open(state_file, "r", encoding="utf-8") as f:
        return json.load(f)


def truncate_collection(qdrant_url: str, collection_name: str = "docs_chunks") -> None:
    """Trunca uma collection do Qdrant (deleta todos os pontos).
    
    Conecta diretamente ao Qdrant via biblioteca qdrant_client (HTTP).
    Não precisa acessar o container.
    """
    print(f"[INFO] Truncando collection '{collection_name}'...")
    print(f"[INFO] Conectando ao Qdrant via biblioteca: {qdrant_url}")
    
    qdrant = QdrantClient(url=qdrant_url, timeout=30.0)
    
    try:
        collection_info = qdrant.get_collection(collection_name)
        points_count = collection_info.points_count
        print(f"[INFO] Collection existe com {points_count} pontos")
    except Exception as e:
        if "404" in str(e) or "not found" in str(e).lower():
            print(f"[AVISO] Collection '{collection_name}' não existe. Será criada durante a ingestão.")
            return
        else:
            raise
    
    # Coletar todos os IDs
    print(f"[INFO] Coletando IDs de todos os pontos...")
    all_ids = []
    offset = None
    
    while True:
        result = qdrant.scroll(
            collection_name=collection_name,
            limit=1000,
            offset=offset,
            with_payload=False,
            with_vectors=False,
        )
        points, next_offset = result
        if not points:
            break
        all_ids.extend([p.id for p in points])
        if next_offset is None:
            break
        offset = next_offset
    
    if all_ids:
        print(f"[INFO] Deletando {len(all_ids)} pontos...")
        # Deletar em lotes de 1000
        batch_size = 1000
        for i in range(0, len(all_ids), batch_size):
            batch = all_ids[i : i + batch_size]
            qdrant.delete(
                collection_name=collection_name,
                points_selector=qm.PointIdsList(points=batch),
            )
            print(f"  Deletados {min(i + batch_size, len(all_ids))}/{len(all_ids)} pontos...")
        
        print(f"[OK] Collection truncada com sucesso ({len(all_ids)} pontos removidos)")
    else:
        print(f"[INFO] Collection '{collection_name}' já está vazia")


def run_scan_docs(docs_path: Path) -> bool:
    """Executa scan_docs localmente usando arquivos locais de DOC-IA."""
    print("[INFO] Executando scan_docs localmente...")
    print(f"[INFO] Usando documentos locais: {docs_path}")
    print("")
    
    env = os.environ.copy()
    env["DOCS_ROOT"] = str(docs_path)
    
    try:
        result = subprocess.run(
            [sys.executable, "-m", "scripts.scan_docs"],
            cwd=str(BACKEND_ROOT),
            env=env,
            check=True,
            capture_output=True,
            text=True,
        )
        print("[OK] scan_docs concluído")
        print(result.stdout)
        return True
    except subprocess.CalledProcessError as e:
        print(f"[AVISO] scan_docs retornou código {e.returncode}")
        print(e.stdout)
        print(e.stderr, file=sys.stderr)
        print("  Continuando com ingestão mesmo assim...")
        return False


def run_ingest(
    docs_path: Path,
    qdrant_url: str,
    use_openai: bool = True,
    openai_api_key: str | None = None,
) -> bool:
    """Executa ingest localmente apontando para Qdrant de produção.
    
    - Usa arquivos locais de DOC-IA (não precisa copiar para container)
    - Conecta ao Qdrant remoto via biblioteca qdrant_client (HTTP)
    - Tudo roda localmente, apenas o Qdrant é remoto
    """
    print("[INFO] Executando ingest localmente → Qdrant de produção...")
    print(f"  Qdrant (remoto): {qdrant_url}")
    print(f"  Documentos (local): {docs_path}")
    print(f"  Embeddings: {'OpenAI' if use_openai else 'Local (fastembed)'}")
    print("")
    
    env = os.environ.copy()
    env["DOCS_ROOT"] = str(docs_path)  # Arquivos locais
    env["QDRANT_URL"] = qdrant_url  # Qdrant remoto via HTTP
    env["USE_OPENAI_EMBEDDINGS"] = "true" if use_openai else "false"
    
    if openai_api_key:
        env["OPENAI_API_KEY"] = openai_api_key
    
    try:
        result = subprocess.run(
            [sys.executable, "-m", "scripts.ingest"],
            cwd=str(BACKEND_ROOT),
            env=env,
            check=True,
            capture_output=True,
            text=True,
        )
        print("[OK] Ingestão concluída com sucesso!")
        print("")
        print("Saída:")
        print(result.stdout)
        return True
    except subprocess.CalledProcessError as e:
        print(f"[ERRO] Ingestão falhou com código {e.returncode}")
        print("")
        print("Saída:")
        print(e.stdout)
        print("Erros:", file=sys.stderr)
        print(e.stderr, file=sys.stderr)
        return False


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Executar ingestão localmente apontando para Qdrant de produção"
    )
    parser.add_argument(
        "--qdrant-url",
        type=str,
        help="URL do Qdrant (ex: https://app-overlabs-qdrant-prod-300.azurecontainerapps.io). Se não fornecido, obtém de deploy_state.json",
    )
    parser.add_argument(
        "--resource-group",
        type=str,
        help="Resource Group (se não fornecido, lê de deploy_state.json)",
    )
    parser.add_argument(
        "--qdrant-app-name",
        type=str,
        help="Nome do Qdrant Container App (se não fornecido, lê de deploy_state.json)",
    )
    parser.add_argument(
        "--docs-path",
        type=str,
        default="DOC-IA",
        help="Caminho para documentos locais (default: DOC-IA)",
    )
    parser.add_argument(
        "--truncate-first",
        action="store_true",
        help="Truncar collection antes de indexar",
    )
    parser.add_argument(
        "--openai-api-key",
        type=str,
        help="OpenAI API Key (se não fornecido, usa OPENAI_API_KEY do ambiente)",
    )
    
    args = parser.parse_args()
    
    print("=== Ingestão Local → Qdrant de Produção ===")
    print("")
    
    # Carregar deploy_state.json se necessário
    if not args.qdrant_url or not args.resource_group or not args.qdrant_app_name:
        try:
            state = load_deploy_state()
            resource_group = args.resource_group or state.get("resourceGroup")
            qdrant_app_name = args.qdrant_app_name or state.get("qdrantAppName")
        except FileNotFoundError as e:
            print(f"[ERRO] {e}", file=sys.stderr)
            print("  Forneça --resource-group e --qdrant-app-name ou --qdrant-url", file=sys.stderr)
            return 1
    else:
        resource_group = args.resource_group
        qdrant_app_name = args.qdrant_app_name
    
    # Obter URL do Qdrant
    if args.qdrant_url:
        qdrant_url = args.qdrant_url
        
        # Normalizar URL
        if not qdrant_url.startswith(("http://", "https://")):
            qdrant_url = f"https://{qdrant_url}"
        
        # Extrair hostname (sem porta, sem path)
        parsed = urlparse(qdrant_url)
        hostname = parsed.hostname or ""
        port = parsed.port
        scheme = parsed.scheme
        
        # Se parece ser um Container App mas falta o domínio .azurecontainerapps.io
        if hostname.startswith("app-") and ".azurecontainerapps.io" not in hostname:
            hostname = f"{hostname}.azurecontainerapps.io"
            print(f"[INFO] Adicionando domínio do Container Apps: {hostname}")
        
        # Reconstruir URL
        if port:
            qdrant_url = f"{scheme}://{hostname}:{port}{parsed.path or ''}"
        else:
            # Para Container Apps, adicionar porta :6333 se não tiver
            if ".azurecontainerapps.io" in hostname:
                qdrant_url = f"https://{hostname}:6333{parsed.path or ''}"
            else:
                # Para Qdrant local, usar http e porta padrão
                qdrant_url = f"http://{hostname}:6333{parsed.path or ''}"
        
        # Garantir https para Container Apps
        if ".azurecontainerapps.io" in qdrant_url and qdrant_url.startswith("http://"):
            qdrant_url = qdrant_url.replace("http://", "https://")
        
        print(f"[INFO] Usando Qdrant URL fornecida (normalizada): {qdrant_url}")
    else:
        print(f"[INFO] Resource Group: {resource_group}")
        print(f"[INFO] Qdrant Container App: {qdrant_app_name}")
        print("")
        print("[INFO] Obtendo URL do Qdrant via Azure CLI...")
        try:
            qdrant_url = get_qdrant_url_from_azure(resource_group, qdrant_app_name)
        except FileNotFoundError as e:
            print(f"[ERRO] {e}", file=sys.stderr)
            print("", file=sys.stderr)
            print("Soluções:", file=sys.stderr)
            print("  1. Instale o Azure CLI: https://aka.ms/installazurecliwindows", file=sys.stderr)
            print("  2. Ou forneça a URL diretamente:", file=sys.stderr)
            print("     --qdrant-url http://app-overlabs-qdrant-prod-300:6333", file=sys.stderr)
            return 1
        except Exception as e:
            print(f"[ERRO] Falha ao obter URL do Qdrant: {e}", file=sys.stderr)
            print("", file=sys.stderr)
            print("Forneça a URL diretamente:", file=sys.stderr)
            print("  --qdrant-url http://app-overlabs-qdrant-prod-300:6333", file=sys.stderr)
            return 1
    
    print(f"[OK] Qdrant URL: {qdrant_url}")
    print("")
    
    # Verificar documentos locais (resolver para caminho absoluto)
    docs_path = Path(args.docs_path)
    if not docs_path.is_absolute():
        # Se for relativo, resolver a partir da raiz do repo
        docs_path = (REPO_ROOT / docs_path).resolve()
    
    if not docs_path.exists():
        print(f"[ERRO] Diretório '{docs_path}' não encontrado!", file=sys.stderr)
        return 1
    
    if not docs_path.is_dir():
        print(f"[ERRO] '{docs_path}' não é um diretório!", file=sys.stderr)
        return 1
    
    print(f"[OK] Documentos locais encontrados: {docs_path}")
    print("")
    
    # Carregar .env
    env_file = REPO_ROOT / ".env"
    if env_file.exists():
        if HAS_DOTENV:
            load_dotenv(env_file)
            print(f"[INFO] Carregando variáveis de .env: {env_file}")
        else:
            # Fallback manual: ler .env sem python-dotenv
            try:
                with open(env_file, "r", encoding="utf-8") as f:
                    for line in f:
                        line = line.strip()
                        # Ignorar comentários e linhas vazias
                        if not line or line.startswith("#"):
                            continue
                        # Parse KEY=VALUE
                        if "=" in line:
                            # Remover comentários inline
                            if "#" in line:
                                line = line.split("#")[0].strip()
                            key, value = line.split("=", 1)
                            key = key.strip()
                            value = value.strip().strip('"').strip("'")
                            if key and value:
                                os.environ.setdefault(key, value)
                print(f"[INFO] Variáveis carregadas do .env (modo manual)")
            except Exception as e:
                print(f"[AVISO] Erro ao ler .env: {e}")
    else:
        print(f"[AVISO] Arquivo .env não encontrado em {env_file}")
    
    # Verificar OpenAI API Key
    openai_key = args.openai_api_key or os.getenv("OPENAI_API_KEY")
    if not openai_key:
        print("[AVISO] OPENAI_API_KEY não encontrada")
        print("  Configure antes de continuar:")
        print("    export OPENAI_API_KEY='sk-...'  # Linux/Mac")
        print("    $env:OPENAI_API_KEY = 'sk-...'  # PowerShell")
        print("")
        response = input("Deseja continuar mesmo assim? (S/N): ")
        if response.upper() != "S":
            return 0
    else:
        print("[OK] OPENAI_API_KEY configurada")
    
    print("")
    
    # Truncar collection se solicitado
    if args.truncate_first:
        try:
            truncate_collection(qdrant_url)
            print("")
        except Exception as e:
            print(f"[AVISO] Erro ao truncar collection: {e}")
            print("  Continuando mesmo assim...")
            print("")
    
    # Executar scan_docs
    if not run_scan_docs(docs_path):
        print("")
    
    # Executar ingest
    success = run_ingest(
        docs_path=docs_path,
        qdrant_url=qdrant_url,
        use_openai=True,
        openai_api_key=openai_key,
    )
    
    if success:
        print("")
        print("=== Ingestão Concluída! ===")
        print("")
        print("[INFO] Documentos foram indexados no Qdrant de produção:")
        print(f"  URL: {qdrant_url}")
        print("  Collection: docs_chunks")
        print("")
        return 0
    else:
        return 1


if __name__ == "__main__":
    sys.exit(main())
