#!/usr/bin/env python3
"""
Script para extrair informações do repositório e gerar documentação automática.

Gera:
- docs/_generated/repo_map.md: Mapa do repositório
- docs/_generated/env_vars_detected.md: Variáveis de ambiente detectadas
- docs/_generated/scripts_inventory.md: Inventário de scripts
"""

import ast
import json
import re
from pathlib import Path
from typing import Any, Dict, List, Set

REPO_ROOT = Path(__file__).parent.parent


def extract_scripts() -> List[Dict[str, Any]]:
    """Extrai informações dos scripts em infra/."""
    scripts = []
    infra_dir = REPO_ROOT / "infra"
    
    if not infra_dir.exists():
        return scripts
    
    for script_path in sorted(infra_dir.rglob("*")):
        if script_path.is_file():
            ext = script_path.suffix.lower()
            if ext not in {".ps1", ".sh", ".py"}:
                continue
            
            rel_path = script_path.relative_to(REPO_ROOT)
            script_info = {
                "path": str(rel_path),
                "name": script_path.name,
                "type": ext[1:],  # Remove o ponto
                "purpose": "",
                "parameters": [],
                "usage": "",
            }
            
            # Ler cabeçalho do arquivo
            try:
                with open(script_path, "r", encoding="utf-8", errors="ignore") as f:
                    lines = f.readlines()
                    
                    # Extrair propósito do cabeçalho (comentários iniciais)
                    purpose_lines = []
                    in_header = True
                    for line in lines[:30]:  # Primeiras 30 linhas
                        if ext == ".py":
                            if line.strip().startswith('"""') or line.strip().startswith("'''"):
                                in_header = True
                                continue
                            if line.strip().startswith("#"):
                                purpose_lines.append(line.strip()[1:].strip())
                        elif ext in {".ps1", ".sh"}:
                            if line.strip().startswith("#"):
                                purpose_lines.append(line.strip()[1:].strip())
                        if line.strip() and not line.strip().startswith("#") and not line.strip().startswith('"""'):
                            break
                    
                    script_info["purpose"] = " ".join(purpose_lines[:3])  # Primeiras 3 linhas
                    
                    # Extrair parâmetros (PowerShell)
                    if ext == ".ps1":
                        for line in lines:
                            if "param(" in line.lower():
                                # Procurar por [Parameter] ou variáveis
                                param_section = []
                                in_param = True
                                for i, l in enumerate(lines[lines.index(line):lines.index(line)+50]):
                                    if ")" in l and in_param:
                                        param_section.append(l)
                                        break
                                    if in_param:
                                        param_section.append(l)
                                
                                # Extrair nomes de parâmetros
                                param_text = " ".join(param_section)
                                params = re.findall(r'\$(\w+)', param_text)
                                script_info["parameters"] = params
                                break
                    
                    # Extrair uso (linhas com "Uso:" ou "Usage:")
                    for line in lines[:20]:
                        if "uso:" in line.lower() or "usage:" in line.lower():
                            script_info["usage"] = line.split(":", 1)[1].strip() if ":" in line else ""
                            break
                            
            except Exception as e:
                script_info["purpose"] = f"Erro ao ler: {e}"
            
            scripts.append(script_info)
    
    return scripts


def extract_workflows() -> List[Dict[str, Any]]:
    """Extrai informações dos workflows do GitHub Actions."""
    workflows = []
    workflows_dir = REPO_ROOT / ".github" / "workflows"
    
    if not workflows_dir.exists():
        return workflows
    
    for workflow_file in sorted(workflows_dir.glob("*.yml")):
        try:
            with open(workflow_file, "r", encoding="utf-8") as f:
                content = f.read()
                
            # Extrair nome do workflow
            name_match = re.search(r'^name:\s*(.+)$', content, re.MULTILINE)
            name = name_match.group(1).strip() if name_match else workflow_file.stem
            
            # Extrair triggers
            triggers = []
            if "on:" in content:
                trigger_section = content.split("on:")[1].split("\n\n")[0]
                if "push:" in trigger_section:
                    triggers.append("push")
                if "pull_request:" in trigger_section:
                    triggers.append("pull_request")
                if "workflow_dispatch:" in trigger_section:
                    triggers.append("workflow_dispatch")
                if "schedule:" in trigger_section:
                    triggers.append("schedule")
            
            # Extrair jobs
            jobs = []
            job_matches = re.findall(r'^  (\w+):', content, re.MULTILINE)
            for job_match in job_matches:
                if job_match not in ["name", "runs-on", "needs", "steps"]:
                    jobs.append(job_match)
            
            workflows.append({
                "file": str(workflow_file.relative_to(REPO_ROOT)),
                "name": name,
                "triggers": triggers,
                "jobs": jobs,
            })
        except Exception as e:
            workflows.append({
                "file": str(workflow_file.relative_to(REPO_ROOT)),
                "name": workflow_file.stem,
                "error": str(e),
            })
    
    return workflows


def extract_compose_files() -> List[Dict[str, Any]]:
    """Extrai informações dos arquivos docker-compose."""
    compose_files = []
    
    for compose_file in sorted(REPO_ROOT.glob("docker-compose*.yml")):
        try:
            with open(compose_file, "r", encoding="utf-8") as f:
                content = f.read()
            
            # Extrair serviços
            services = []
            service_matches = re.findall(r'^  (\w+):\s*$', content, re.MULTILINE)
            for service in service_matches:
                if service not in ["version", "services", "volumes", "networks"]:
                    services.append(service)
            
            compose_files.append({
                "file": compose_file.name,
                "services": services,
            })
        except Exception as e:
            compose_files.append({
                "file": compose_file.name,
                "error": str(e),
            })
    
    return compose_files


def extract_env_vars_from_validate() -> Dict[str, Any]:
    """Extrai env vars do validate_env.py."""
    validate_file = REPO_ROOT / "infra" / "validate_env.py"
    env_vars = {
        "secrets": [],
        "non_secrets": [],
        "required": [],
        "integer_keys": [],
        "boolean_keys": [],
    }
    
    if not validate_file.exists():
        return env_vars
    
    try:
        with open(validate_file, "r", encoding="utf-8") as f:
            content = f.read()
        
        # Extrair DENYLIST (não são secrets)
        denylist_match = re.search(r'DENYLIST:\s*Set\[str\]\s*=\s*\{([^}]+)\}', content, re.DOTALL)
        if denylist_match:
            denylist_text = denylist_match.group(1)
            denylist = re.findall(r'"(\w+)"', denylist_text)
            env_vars["non_secrets"].extend(denylist)
        
        # Extrair REQUIRED_KEYS
        required_match = re.search(r'REQUIRED_KEYS\s*=\s*\{([^}]*)\}', content, re.DOTALL)
        if required_match:
            required_text = required_match.group(1)
            required = re.findall(r'"(\w+)"', required_text)
            env_vars["required"].extend(required)
        
        # Extrair INTEGER_KEYS
        integer_match = re.search(r'INTEGER_KEYS\s*=\s*\{([^}]+)\}', content, re.DOTALL)
        if integer_match:
            integer_text = integer_match.group(1)
            integers = re.findall(r'"(\w+)"', integer_text)
            env_vars["integer_keys"].extend(integers)
        
        # Extrair BOOLEAN_KEYS
        boolean_match = re.search(r'BOOLEAN_KEYS\s*=\s*\{([^}]+)\}', content, re.DOTALL)
        if boolean_match:
            boolean_text = boolean_match.group(1)
            booleans = re.findall(r'"(\w+)"', boolean_text)
            env_vars["boolean_keys"].extend(booleans)
            
    except Exception as e:
        env_vars["error"] = str(e)
    
    return env_vars


def extract_env_vars_from_config() -> List[Dict[str, Any]]:
    """Extrai env vars do config.py usando AST."""
    config_file = REPO_ROOT / "backend" / "app" / "config.py"
    env_vars = []
    
    if not config_file.exists():
        return env_vars
    
    try:
        with open(config_file, "r", encoding="utf-8") as f:
            tree = ast.parse(f.read())
        
        # Procurar pela classe Settings
        for node in ast.walk(tree):
            if isinstance(node, ast.ClassDef) and node.name == "Settings":
                for item in node.body:
                    if isinstance(item, ast.AnnAssign) and item.target:
                        var_name = item.target.id if isinstance(item.target, ast.Name) else None
                        if var_name:
                            # Extrair tipo e default
                            var_type = "str"
                            default_value = None
                            
                            if item.annotation:
                                if isinstance(item.annotation, ast.Name):
                                    var_type = item.annotation.id
                                elif isinstance(item.annotation, ast.Subscript):
                                    var_type = "Optional"
                            
                            if item.value:
                                if isinstance(item.value, ast.Constant):
                                    default_value = item.value.value
                                elif isinstance(item.value, ast.Str):  # Python < 3.8
                                    default_value = item.value.s
                            
                            env_vars.append({
                                "name": var_name.upper(),
                                "type": var_type,
                                "default": default_value,
                            })
    except Exception as e:
        env_vars.append({"error": str(e)})
    
    return env_vars


def extract_api_endpoints() -> List[Dict[str, Any]]:
    """Extrai endpoints do FastAPI."""
    main_file = REPO_ROOT / "backend" / "app" / "main.py"
    endpoints = []
    
    if not main_file.exists():
        return endpoints
    
    try:
        with open(main_file, "r", encoding="utf-8") as f:
            content = f.read()
        
        # Procurar por @app.get, @app.post, etc.
        pattern = r'@app\.(get|post|put|delete|patch|head|options)\s*\(["\']([^"\']+)["\']'
        matches = re.finditer(pattern, content)
        
        for match in matches:
            method = match.group(1).upper()
            path = match.group(2)
            
            # Procurar função associada
            func_name = "unknown"
            func_match = re.search(rf'async def (\w+).*?{re.escape(path)}', content, re.DOTALL)
            if func_match:
                func_name = func_match.group(1)
            
            # Procurar response_model
            response_model = None
            response_match = re.search(rf'@app\.{method.lower()}\s*\([^)]*response_model=(\w+)', content)
            if response_match:
                response_model = response_match.group(1)
            
            endpoints.append({
                "method": method,
                "path": path,
                "function": func_name,
                "response_model": response_model,
            })
    except Exception as e:
        endpoints.append({"error": str(e)})
    
    return endpoints


def generate_repo_map(scripts: List[Dict], workflows: List[Dict], compose_files: List[Dict]) -> str:
    """Gera repo_map.md."""
    lines = [
        "# Mapa do Repositório",
        "",
        "> **Nota**: Este arquivo é gerado automaticamente por `tools/docs_extract.py`.",
        "> Não edite manualmente. Execute `python tools/docs_extract.py` para atualizar.",
        "",
        "## Scripts de Infraestrutura",
        "",
        "| Script | Tipo | Propósito | Parâmetros |",
        "|--------|------|-----------|------------|",
    ]
    
    for script in scripts:
        params_str = ", ".join(script.get("parameters", [])) or "-"
        purpose = script.get("purpose", "")[:60] + "..." if len(script.get("purpose", "")) > 60 else script.get("purpose", "")
        lines.append(
            f"| [`{script['path']}`](../{script['path']}) | {script['type']} | {purpose} | {params_str} |"
        )
    
    lines.extend([
        "",
        "## Workflows GitHub Actions",
        "",
        "| Arquivo | Nome | Triggers | Jobs |",
        "|---------|------|----------|------|",
    ])
    
    for workflow in workflows:
        triggers_str = ", ".join(workflow.get("triggers", [])) or "-"
        jobs_str = ", ".join(workflow.get("jobs", [])) or "-"
        lines.append(
            f"| [`{workflow['file']}`](../{workflow['file']}) | {workflow['name']} | {triggers_str} | {jobs_str} |"
        )
    
    lines.extend([
        "",
        "## Docker Compose Files",
        "",
        "| Arquivo | Serviços |",
        "|---------|----------|",
    ])
    
    for compose in compose_files:
        services_str = ", ".join(compose.get("services", [])) or "-"
        lines.append(
            f"| `{compose['file']}` | {services_str} |"
        )
    
    return "\n".join(lines)


def generate_env_vars_doc(validate_vars: Dict, config_vars: List[Dict]) -> str:
    """Gera env_vars_detected.md."""
    lines = [
        "# Variáveis de Ambiente Detectadas",
        "",
        "> **Nota**: Este arquivo é gerado automaticamente por `tools/docs_extract.py`.",
        "> Não edite manualmente. Execute `python tools/docs_extract.py` para atualizar.",
        "",
        "## Classificação (validate_env.py)",
        "",
        "### Variáveis Não-Secrets",
        "",
    ]
    
    for var in sorted(validate_vars.get("non_secrets", [])):
        lines.append(f"- `{var}`")
    
    lines.extend([
        "",
        "### Variáveis Obrigatórias",
        "",
    ])
    
    required = validate_vars.get("required", [])
    if required:
        for var in sorted(required):
            lines.append(f"- `{var}`")
    else:
        lines.append("*(Nenhuma variável obrigatória definida)*")
    
    lines.extend([
        "",
        "### Variáveis Inteiras",
        "",
    ])
    
    for var in sorted(validate_vars.get("integer_keys", [])):
        lines.append(f"- `{var}`")
    
    lines.extend([
        "",
        "### Variáveis Booleanas",
        "",
    ])
    
    for var in sorted(validate_vars.get("boolean_keys", [])):
        lines.append(f"- `{var}`")
    
    lines.extend([
        "",
        "## Variáveis do Config (config.py)",
        "",
        "| Variável | Tipo | Default |",
        "|----------|------|---------|",
    ])
    
    for var in sorted(config_vars, key=lambda x: x.get("name", "")):
        name = var.get("name", "?")
        var_type = var.get("type", "?")
        default = var.get("default", "")
        default_str = f"`{default}`" if default is not None else "-"
        lines.append(f"| `{name}` | {var_type} | {default_str} |")
    
    return "\n".join(lines)


def generate_scripts_inventory(scripts: List[Dict]) -> str:
    """Gera scripts_inventory.md."""
    lines = [
        "# Inventário de Scripts",
        "",
        "> **Nota**: Este arquivo é gerado automaticamente por `tools/docs_extract.py`.",
        "> Não edite manualmente. Execute `python tools/docs_extract.py` para atualizar.",
        "",
    ]
    
    # Agrupar por tipo
    by_type: Dict[str, List[Dict]] = {}
    for script in scripts:
        script_type = script.get("type", "unknown")
        if script_type not in by_type:
            by_type[script_type] = []
        by_type[script_type].append(script)
    
    for script_type in sorted(by_type.keys()):
        lines.extend([
            f"## Scripts {script_type.upper()}",
            "",
        ])
        
        for script in sorted(by_type[script_type], key=lambda x: x["name"]):
            lines.extend([
                f"### `{script['path']}`",
                "",
                f"**Tipo**: {script['type']}",
                "",
            ])
            
            if script.get("purpose"):
                lines.append(f"**Propósito**: {script['purpose']}")
                lines.append("")
            
            if script.get("parameters"):
                lines.append(f"**Parâmetros**: {', '.join(script['parameters'])}")
                lines.append("")
            
            if script.get("usage"):
                lines.append(f"**Uso**: `{script['usage']}`")
                lines.append("")
            
            lines.append("---")
            lines.append("")
    
    return "\n".join(lines)


def main():
    """Gera todos os arquivos de documentação automática."""
    print("🔍 Extraindo informações do repositório...")
    
    # Extrair dados
    scripts = extract_scripts()
    workflows = extract_workflows()
    compose_files = extract_compose_files()
    validate_vars = extract_env_vars_from_validate()
    config_vars = extract_env_vars_from_config()
    endpoints = extract_api_endpoints()
    
    print(f"  ✓ {len(scripts)} scripts encontrados")
    print(f"  ✓ {len(workflows)} workflows encontrados")
    print(f"  ✓ {len(compose_files)} compose files encontrados")
    print(f"  ✓ {len(validate_vars.get('non_secrets', []))} env vars não-secrets")
    print(f"  ✓ {len(config_vars)} env vars do config")
    print(f"  ✓ {len(endpoints)} endpoints da API")
    
    # Criar diretório _generated
    generated_dir = REPO_ROOT / "docs" / "_generated"
    generated_dir.mkdir(parents=True, exist_ok=True)
    
    # Gerar arquivos
    print("\n📝 Gerando arquivos de documentação...")
    
    repo_map = generate_repo_map(scripts, workflows, compose_files)
    repo_map_file = generated_dir / "repo_map.md"
    repo_map_file.write_text(repo_map, encoding="utf-8")
    print(f"  ✓ {repo_map_file}")
    
    env_vars_doc = generate_env_vars_doc(validate_vars, config_vars)
    env_vars_file = generated_dir / "env_vars_detected.md"
    env_vars_file.write_text(env_vars_doc, encoding="utf-8")
    print(f"  ✓ {env_vars_file}")
    
    scripts_inventory = generate_scripts_inventory(scripts)
    scripts_file = generated_dir / "scripts_inventory.md"
    scripts_file.write_text(scripts_inventory, encoding="utf-8")
    print(f"  ✓ {scripts_file}")
    
    # Salvar endpoints em JSON para uso posterior
    endpoints_file = generated_dir / "api_endpoints.json"
    endpoints_file.write_text(json.dumps(endpoints, indent=2), encoding="utf-8")
    print(f"  ✓ {endpoints_file}")
    
    print("\n✅ Documentação automática gerada com sucesso!")
    print(f"\n📁 Arquivos gerados em: {generated_dir.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    main()
