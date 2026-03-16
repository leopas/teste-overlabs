#!/usr/bin/env python3
"""
Extrai informações do repositório e gera documentação em docs-llama/_generated.

Gera:
- repo_map.md
- env_vars_detected.md
- scripts_inventory.md
- api_endpoints.json
"""

import ast
import json
import os
import re
from pathlib import Path
from typing import Any, Dict, List

# Repo root: se o script está em tools/, sobe um nível
SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent if SCRIPT_DIR.name == "tools" else SCRIPT_DIR
DOCS_ROOT = REPO_ROOT / "docs-llama"
_GENERATED_DIR = DOCS_ROOT / "_generated"


def extract_scripts() -> List[Dict[str, Any]]:
    """Extrai scripts Python do repositório (infra + backend/scripts + tools)."""
    scripts = []
    for base in ["infra", "backend/scripts", "tools"]:
        folder = REPO_ROOT / base.replace("/", os.sep)
        if not folder.exists():
            continue
        for path in folder.rglob("*.py"):
            if path.is_file():
                rel = path.relative_to(REPO_ROOT)
                scripts.append({
                    "file": str(rel).replace("\\", "/"),
                    "name": path.name,
                    "type": "python",
                })
    # Incluir também scripts .ps1 e .sh em infra
    infra = REPO_ROOT / "infra"
    if infra.exists():
        for path in infra.rglob("*"):
            if path.is_file() and path.suffix.lower() in (".ps1", ".sh"):
                rel = path.relative_to(REPO_ROOT)
                scripts.append({
                    "file": str(rel).replace("\\", "/"),
                    "name": path.name,
                    "type": path.suffix[1:].lower(),
                })
    return scripts


def extract_workflows() -> List[Dict[str, Any]]:
    """Extrai workflows do GitHub Actions."""
    workflows = []
    wf_dir = REPO_ROOT / ".github" / "workflows"
    if not wf_dir.exists():
        return workflows
    for pattern in ("*.yml", "*.yaml"):
        for path in sorted(wf_dir.glob(pattern)):
            if path.is_file():
                workflows.append({
                    "file": str(path.relative_to(REPO_ROOT)).replace("\\", "/"),
                    "name": path.name,
                })
    return workflows


def extract_compose_files() -> List[Dict[str, Any]]:
    """Extrai arquivos Docker Compose e lista serviços."""
    compose_files = []
    for name in ("docker-compose.yml", "docker-compose.yaml"):
        for path in sorted(REPO_ROOT.glob(name)):
            if path.is_file():
                compose_files.append({"file": path.name, "name": path.name, "path": str(path)})
    for path in sorted(REPO_ROOT.glob("docker-compose*.yml")):
        if path.is_file() and path.name not in {c["file"] for c in compose_files}:
            compose_files.append({"file": path.name, "name": path.name, "path": str(path)})
    # Extrair serviços de cada compose
    for comp in compose_files:
        comp["services"] = []
        try:
            with open(REPO_ROOT / comp["file"], "r", encoding="utf-8") as f:
                content = f.read()
            # Heurística: linhas "  nome_servico:" após "services:"
            in_services = False
            for line in content.splitlines():
                if line.strip() == "services:":
                    in_services = True
                    continue
                if in_services and line and not line.startswith(" "):
                    break
                if in_services and re.match(r"^\s{2}[a-zA-Z0-9_-]+:\s*$", line):
                    comp["services"].append(line.strip().rstrip(":").strip())
        except Exception:
            pass
    return compose_files


def extract_env_vars_from_validate() -> Dict[str, Any]:
    """Extrai variáveis de ambiente do validate_env.py (infra ou infra/old)."""
    result = {"non_secrets": [], "required": [], "integer_keys": [], "boolean_keys": []}
    for candidate in ["infra/validate_env.py", "infra/old/validate_env.py"]:
        path = REPO_ROOT / candidate.replace("/", os.sep)
        if not path.exists():
            continue
        try:
            with open(path, "r", encoding="utf-8") as f:
                content = f.read()
            # DENYLIST -> non_secrets
            m = re.search(r"DENYLIST[^=]*=\s*\{([^}]+)\}", content, re.DOTALL)
            if m:
                result["non_secrets"] = re.findall(r'"(\w+)"', m.group(1))
            # REQUIRED_KEYS
            m = re.search(r"REQUIRED_KEYS\s*=\s*\{([^}]*)\}", content, re.DOTALL)
            if m:
                result["required"] = re.findall(r'"(\w+)"', m.group(1))
            # INTEGER_KEYS
            m = re.search(r"INTEGER_KEYS\s*=\s*\{([^}]+)\}", content, re.DOTALL)
            if m:
                result["integer_keys"] = re.findall(r'"(\w+)"', m.group(1))
            # BOOLEAN_KEYS
            m = re.search(r"BOOLEAN_KEYS\s*=\s*\{([^}]+)\}", content, re.DOTALL)
            if m:
                result["boolean_keys"] = re.findall(r'"(\w+)"', m.group(1))
            break
        except Exception as e:
            result["error"] = str(e)
    return result


def extract_env_vars_from_config() -> List[Dict[str, Any]]:
    """Extrai variáveis do backend/app/config.py (Settings) via AST."""
    config_path = REPO_ROOT / "backend" / "app" / "config.py"
    if not config_path.exists():
        return []
    env_vars = []
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            tree = ast.parse(f.read())
        for node in ast.walk(tree):
            if isinstance(node, ast.ClassDef) and node.name == "Settings":
                for item in node.body:
                    if isinstance(item, ast.AnnAssign) and item.target:
                        name = item.target.id if isinstance(item.target, ast.Name) else None
                        if not name:
                            continue
                        var_type = "str"
                        if item.annotation and isinstance(item.annotation, ast.Name):
                            var_type = item.annotation.id
                        default = None
                        if item.value:
                            if isinstance(item.value, ast.Constant):
                                default = item.value.value
                        env_vars.append({"name": name, "type": var_type, "default": default})
                break
    except Exception:
        pass
    return env_vars


def extract_api_endpoints() -> List[Dict[str, Any]]:
    """Extrai endpoints da API a partir de backend/app/main.py."""
    main_path = REPO_ROOT / "backend" / "app" / "main.py"
    endpoints = []
    if not main_path.exists():
        return endpoints
    try:
        with open(main_path, "r", encoding="utf-8") as f:
            content = f.read()
        pattern = r"@(?:app|router)\.(get|post|put|delete|patch|head|options)\s*\(\s*[\"']([^\"']+)[\"']"
        for match in re.finditer(pattern, content):
            method = match.group(1).upper()
            path = match.group(2)
            endpoints.append({"method": method, "path": path})
    except Exception:
        pass
    return endpoints


def generate_repo_map(
    scripts: List[Dict],
    workflows: List[Dict],
    compose_files: List[Dict],
) -> str:
    """Gera repo_map.md."""
    lines = [
        "# Repository Map",
        "",
        "> **Note**: This file is automatically generated by tools/docs_extract.py.",
        "> Do not edit this file manually. Run `python tools/docs_extract.py` to update it.",
        "",
        "## Scripts",
        "",
    ]
    for script in scripts:
        lines.append(f"### `{script['file']}`")
        lines.append(f"**Name**: {script['name']}")
        lines.append("")
    lines.extend(["", "## Workflows", ""])
    for w in workflows:
        lines.append(f"### `{w['file']}`")
        lines.append(f"**Name**: {w['name']}")
        lines.append("")
    lines.extend(["", "## Docker Compose Files", ""])
    for comp in compose_files:
        lines.append(f"### `{comp['file']}`")
        lines.append(f"**Services**: {', '.join(comp.get('services', []))}")
        lines.append("")
    return "\n".join(lines)


def generate_env_vars_doc(
    validate_vars: Dict[str, Any],
    config_vars: List[Dict],
) -> str:
    """Gera env_vars_detected.md."""
    lines = [
        "# Detected Environment Variables",
        "",
        "> **Note**: This file is automatically generated by tools/docs_extract.py.",
        "> Do not edit this file manually. Run `python tools/docs_extract.py` to update it.",
        "",
        "## Classified (validate_env.py)",
        "",
        "### Non-Secrets",
        "",
    ]
    for var in sorted(validate_vars.get("non_secrets", []), key=str.lower):
        lines.append(f"- `{var}`")
    lines.extend(["", "### Required", ""])
    required = validate_vars.get("required", [])
    if required:
        for var in sorted(required):
            lines.append(f"- `{var}`")
    else:
        lines.append("*(No required variables defined)*")
    lines.extend(["", "### Integer Keys", ""])
    for var in sorted(validate_vars.get("integer_keys", []), key=str.lower):
        lines.append(f"- `{var}`")
    lines.extend(["", "### Boolean Keys", ""])
    for var in sorted(validate_vars.get("boolean_keys", []), key=str.lower):
        lines.append(f"- `{var}`")
    lines.extend(["", "## Config (config.py)", "", "| Variable | Type | Default |", "|----------|------|---------|"])
    for var in sorted(config_vars, key=lambda x: x.get("name", "")):
        name = var.get("name", "?")
        var_type = var.get("type", "?")
        default = var.get("default", "")
        default_str = f"`{default}`" if default not in (None, "") else "-"
        lines.append(f"| `{name}` | {var_type} | {default_str} |")
    return "\n".join(lines)


def generate_scripts_inventory(scripts: List[Dict]) -> str:
    """Gera scripts_inventory.md."""
    lines = [
        "# Scripts Inventory",
        "",
        "> **Note**: This file is automatically generated by tools/docs_extract.py.",
        "> Do not edit this file manually. Run `python tools/docs_extract.py` to update it.",
        "",
    ]
    by_type: Dict[str, List[Dict]] = {}
    for script in scripts:
        t = script.get("type", "unknown")
        if t not in by_type:
            by_type[t] = []
        by_type[t].append(script)
    for script_type in sorted(by_type.keys()):
        lines.append(f"## Scripts {script_type.upper()}")
        lines.append("")
        for script in sorted(by_type[script_type], key=lambda x: x["name"]):
            lines.append(f"### `{script['file']}`")
            lines.append("")
            lines.append(f"**Type**: {script['type']}")
            lines.append("")
            lines.append("---")
            lines.append("")
    return "\n".join(lines)


def main() -> None:
    """Gera todos os arquivos de documentação."""
    print("[INFO] Extracting information from the repository...")
    scripts = extract_scripts()
    workflows = extract_workflows()
    compose_files = extract_compose_files()
    validate_vars = extract_env_vars_from_validate()
    config_vars = extract_env_vars_from_config()
    endpoints = extract_api_endpoints()

    print(f"  - {len(scripts)} scripts found")
    print(f"  - {len(workflows)} workflows found")
    print(f"  - {len(compose_files)} compose files found")
    print(f"  - {len(endpoints)} API endpoints found")

    _GENERATED_DIR.mkdir(parents=True, exist_ok=True)

    out_map = _GENERATED_DIR / "repo_map.md"
    out_map.write_text(
        generate_repo_map(scripts, workflows, compose_files),
        encoding="utf-8",
    )
    print(f"  - {out_map}")

    out_env = _GENERATED_DIR / "env_vars_detected.md"
    out_env.write_text(
        generate_env_vars_doc(validate_vars, config_vars),
        encoding="utf-8",
    )
    print(f"  - {out_env}")

    out_scripts = _GENERATED_DIR / "scripts_inventory.md"
    out_scripts.write_text(generate_scripts_inventory(scripts), encoding="utf-8")
    print(f"  - {out_scripts}")

    out_api = _GENERATED_DIR / "api_endpoints.json"
    out_api.write_text(json.dumps(endpoints, indent=2), encoding="utf-8")
    print(f"  - {out_api}")

    print("\n[OK] Documentation generated successfully!")
    print(f"Output: {_GENERATED_DIR.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    main()
