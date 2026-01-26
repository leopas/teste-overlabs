#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Concatena TODOS os arquivos de TEXTO de 1..N projetos em um .md por projeto,
respeitando .gitignore, evitando binários e arquivos muito grandes.
Evita auto-inclusão do próprio arquivo MD gerado e QUALQUER item relacionado a ".git".

Gera um MD rico em inteligência arquitetural com:
- Project Intelligence: tree, stack detectada, comandos úteis, entrypoints, env vars, API routes
- File Index: tabela com metadados de todos os arquivos
- Modos FULL e SMART para controle de tamanho
- Side-car JSON opcional com metadados estruturados

MELHORIAS:
- Exclui diretórios de dependências (.venv, node_modules, __pycache__, etc.)
- Detecta e exclui diretórios muito grandes (>100MB por padrão)
- Lista expandida de padrões de diretórios de bibliotecas e dependências
- Filtragem inteligente para evitar sobrecarregar o arquivo MD final
- Auto-detecção do ROOT do repositório: procura por .git subindo diretórios a partir do script
- Project Intelligence: análise automática de stack, comandos, entrypoints, env vars, rotas API
- Modo SMART: trunca arquivos grandes mantendo header, assinaturas e footer
- Side-car JSON: metadados estruturados para análise programática

CLI:
  # Modo single (auto-detecta ROOT do repo onde o script está):
  python concat_repo_all_text.py
  
  # Modo multi (processa múltiplos projetos):
  python concat_repo_all_text.py "C:\\Projetos\\projA" "C:\\Projetos\\projB"

AUTO-DETECÇÃO (quando executado sem argumentos e sem env vars):
- ROOT: começa no diretório do script e sobe procurando por .git. Se encontrar, usa esse diretório.
         Se não encontrar, usa o diretório do script como ROOT.
- OUT_PATH: se CONCAT_OUT_PATH não estiver definido, usa <ROOT>/repo_concat_all.md

ENV VARS (sobrescrevem defaults):
- CONCAT_ROOT: define ROOT explicitamente (sobrescreve auto-detecção)
- CONCAT_OUT_PATH: define caminho completo do arquivo de saída (sobrescreve default)
- CONCAT_OUT_BASENAME: nome do arquivo de saída (padrão: "repo_concat_all.md")
- CONCAT_ROOTS: lista de projetos separados por | ou ; (modo multi via env)
- MAX_FILE_BYTES: tamanho máximo por arquivo (padrão: 2000000 = 2MB)
- CONCAT_MODE: modo de concatenação - "full" ou "smart" (padrão: "smart")
- SMART_TRUNCATE_BYTES: tamanho em bytes para aplicar truncamento smart (padrão: 200000 = 200KB)
- MAX_TOTAL_BYTES: tamanho máximo total do MD (0 = sem limite, padrão: 0)
- CONCAT_SIDE_CAR_JSON: gerar JSON com metadados ("1", "true", "yes" para ativar, padrão: desativado)

PROJECT INTELLIGENCE:
O MD gerado inclui automaticamente:
- Repository Tree: estrutura de diretórios (até profundidade 4)
- Stack Detected: linguagens, frameworks e infra detectados
- How to Run: comandos extraídos de Makefile, package.json, docker-compose, etc.
- Entrypoints: arquivos principais prováveis (main.py, app.py, etc.)
- Environment Variables: nomes de variáveis (sem valores) e onde aparecem
- API Surface: rotas detectadas (FastAPI, Express, etc.)
- RAG/LLM & Observability: sinais de bibliotecas relacionadas
- Smells/Gaps: TODOs, presença de testes, .env real, maiores arquivos

MODO SMART:
No modo "smart" (padrão), arquivos maiores que SMART_TRUNCATE_BYTES são truncados mantendo:
- Primeiras 120 linhas (header)
- Assinaturas detectadas (def/class/import em Python, export/function em JS/TS, etc.)
- Últimas 80 linhas (footer)
- Aviso de truncamento

O modo "full" mantém o comportamento original (conteúdo completo, respeitando MAX_FILE_BYTES).
"""

from __future__ import annotations
import os
import sys  
import subprocess
import shutil
import re
import json
from datetime import datetime
from typing import Iterable, List, Set, Optional, Tuple, Dict, Any

# ----- Auto-detecção do ROOT do repositório -----
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

def find_repo_root(start_dir: str) -> str:
    """
    Procura por um diretório .git subindo a partir de start_dir até a raiz do filesystem.
    Retorna o primeiro diretório encontrado que contém .git, ou start_dir se não encontrar.
    """
    current = os.path.abspath(start_dir)
    root_path = os.path.abspath(os.sep)  # Raiz do filesystem (/, C:\, etc.)
    
    while True:
        git_dir = os.path.join(current, ".git")
        if os.path.isdir(git_dir):
            return current
        # Se chegou na raiz do filesystem, para
        if current == root_path or os.path.dirname(current) == current:
            break
        current = os.path.dirname(current)
    
    # Se não encontrou .git, retorna o diretório inicial
    return start_dir

# ----- Defaults / Env (com auto-detecção) -----
DEFAULT_ROOT = find_repo_root(SCRIPT_DIR)
ROOT = os.getenv("CONCAT_ROOT", DEFAULT_ROOT)
MAX_FILE_BYTES = int(os.getenv("MAX_FILE_BYTES", "2000000"))  # 2MB
CONCAT_ROOTS_ENV = os.getenv("CONCAT_ROOTS", "").strip()
CONCAT_OUT_BASENAME = (os.getenv("CONCAT_OUT_BASENAME", "repo_concat_all.md").strip() or "repo_concat_all.md")
# OUT_PATH: se CONCAT_OUT_PATH não estiver definido, usa <ROOT>/<CONCAT_OUT_BASENAME>
OUT_PATH = os.getenv("CONCAT_OUT_PATH", os.path.join(ROOT, CONCAT_OUT_BASENAME))
# Novos env vars para modos e limites
CONCAT_MODE = os.getenv("CONCAT_MODE", "smart").strip().lower()  # "full" ou "smart"
SMART_TRUNCATE_BYTES = int(os.getenv("SMART_TRUNCATE_BYTES", "200000"))  # 200KB
MAX_TOTAL_BYTES = int(os.getenv("MAX_TOTAL_BYTES", "0"))  # 0 = sem limite
CONCAT_SIDE_CAR_JSON = os.getenv("CONCAT_SIDE_CAR_JSON", "").strip().lower() in ("1", "true", "yes")

# Extensões de binários/arquivos indesejados
EXCLUDE_EXTS: Set[str] = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".ico", ".svg",
    ".mp3", ".wav", ".ogg", ".flac", ".mp4", ".mkv", ".webm", ".mov", ".avi",
    ".woff", ".woff2", ".ttf", ".otf", ".eot",
    ".zip", ".rar", ".7z", ".tar", ".gz", ".bz2", ".xz",
    ".apk", ".ipa", ".dmg", ".iso",
    ".exe", ".dll", ".so", ".dylib", ".o", ".a", ".obj", ".class", ".jar",
    ".sqlite", ".db", ".fdb", ".mdb", ".accdb", ".parquet", ".xls", ".xlsx",
    ".pdf", ".psd",
}

# Regex patterns para exclusão de arquivos sensíveis (case-insensitive)
# CRÍTICO: Estes padrões bloqueiam arquivos que NUNCA devem aparecer no MD
EXCLUDE_BASENAME_REGEX = [
    r'^\.env',  # .env, .env.local, .env.prod, .env.development, etc. (qualquer .env*)
    r'^\.envrc$',
    r'^\.npmrc$',
    r'^\.pypirc$',
    r'credentials.*\.json$',  # credentials.json, credentials-prod.json, etc.
    r'token.*\.json$',
    r'service[_-]?account.*\.json$',  # service-account.json, service_account.json
    r'.*[_-]sa\.json$',  # qualquer arquivo terminando em -sa.json ou _sa.json
    r'id[_-]?rsa',  # id_rsa, id-rsa, idrsa (com ou sem .pub)
    r'id[_-]?ed25519',  # id_ed25519, id-ed25519
    r'known_hosts$',
    r'authorized_keys$',  # chaves SSH autorizadas
    r'secrets.*\.(json|yaml|yml)$',
    r'private.*\.(json|yaml|yml)$',
    r'oauth.*\.(json|yaml|yml)$',
    r'apikey.*\.(json|yaml|yml)$',
    r'gcp.*\.json$',
    r'firebase.*\.json$',
]

EXCLUDE_PATH_REGEX = [
    r'[/\\]\.env',  # Qualquer .env em qualquer subpasta
    r'[/\\]secrets[/\\]',
    r'[/\\]secret[/\\]',
    r'[/\\]keys[/\\]',
    r'[/\\]certs[/\\]',
    r'[/\\]\.ssh[/\\]',
    r'[/\\]\.aws[/\\]',
    r'[/\\]private[/\\]',
    r'[/\\]credentials[/\\]',
]

# Extensões de arquivos sensíveis (chaves, certificados, bancos de dados locais)
# CRÍTICO: Arquivos com estas extensões são SEMPRE excluídos
SENSITIVE_EXTS: Set[str] = {
    ".pem", ".key", ".p12", ".pfx", ".crt", ".cer", ".jks", ".kdbx",  # Chaves e certificados
    ".sqlite", ".sqlite3", ".db", ".fdb", ".mdb", ".accdb",  # Bancos de dados locais
}

FALLBACK_PRUNE_DIRS: Set[str] = {
    # Git e controle de versão
    ".git", ".svn", ".hg", ".bzr",
    
    # Node.js / JavaScript
    "node_modules", "npm-debug.log*", "yarn-debug.log*", "yarn-error.log*",
    ".next", ".nuxt", ".vuepress", ".cache", ".turbo", "dist", "build", "out",
    "coverage", ".nyc_output", ".jest", ".eslintcache",
    
    # Python
    ".venv", "venv", "env", ".env", ".virtualenv", "__pycache__", ".pytest_cache",
    ".mypy_cache", ".coverage", ".tox", ".nox", "site-packages", ".Python",
    "pip-log.txt", "pip-delete-this-directory.txt", ".pytest_cache",
    
    # Java
    "target", ".gradle", ".mvn", "build", "out", ".idea", ".vscode",
    
    # C/C++
    "Debug", "Release", "x64", "x86", "obj", "bin", ".vs", "CMakeFiles",
    
    # Go
    "vendor", "go.sum", "go.mod",
    
    # Rust
    "target", "Cargo.lock",
    
    # Ruby
    "vendor", "bundle", ".bundle", "Gemfile.lock",
    
    # PHP
    "vendor", "composer.lock",
    
    # Outros
    ".DS_Store", "Thumbs.db", "*.log", "logs", "tmp", "temp", ".tmp",
    "coverage", "test-results", ".nyc_output", ".nyc_output",
    "bower_components", ".sass-cache", ".parcel-cache",
    "android", "ios", "platforms", "plugins", "www",
    ".expo", ".expo-shared", "expo-env.d.ts",
    ".docusaurus", "docs", "documentation",
    "backup", "backups", ".backup", ".backups",
    "archive", "archives", ".archive", ".archives",
    "old", "deprecated", "legacy",
    "test", "tests", "spec", "specs", "__tests__", "__spec__",
    "mocks", "fixtures", "stubs", "doubles",
    "examples", "samples", "demos", "playground",
    "docs", "documentation", "wiki", "guides",
    "assets", "static", "public", "media", "images", "img", "icons",
    "fonts", "css", "styles", "themes", "skins",
    "locales", "i18n", "translations", "lang",
    "config", "configs", "settings", "conf",
    "secrets", "credentials", "keys", "certs", "certificates",
    "migrations", "seeds", "fixtures", "factories",
    "deploy", "deployment", "deployments", "infra", "infrastructure",
    "docker", "containers", "k8s", "kubernetes", "helm",
    "terraform", "ansible", "chef", "puppet",
    "scripts", "tools", "utilities", "bin", "sbin",
    "data", "databases", "db", "dbs", "storage",
    "cache", "caches", ".cache", "cached",
    "temp", "temporary", ".temp", ".tmp",
    "runtime", "runtimes", "binaries", "executables",
    "packages", "pkg", "pkgs", "libraries",
    "modules", "components", "widgets", "plugins", "extensions",
    "addons", "add-ons", "extensions", "extras",
    "third-party", "third_party", "external", "externals",
    "dependencies", "deps", "dev-dependencies", "dev_dependencies",
    "peer-dependencies", "peer_dependencies", "optional-dependencies",
    "bundled-dependencies", "bundled_dependencies",
    "workspaces", "monorepo", "packages", "apps",
    "generated", "auto-generated", "auto_generated", "build-generated",
    "compiled", "transpiled", "minified", "uglified",
    "sourcemaps", "source-maps", "source_maps",
    "types", "typings", "definitions", "interfaces",
    "schemas", "models", "entities", "dto", "dtos",
    "enums", "constants", "configs", "settings",
    "utils", "utilities", "helpers", "helpers",
    "validators", "validations", "sanitizers", "formatters",
    "parsers", "serializers", "deserializers", "mappers",
    "repositories", "repos", "services", "controllers",
    "middleware", "middlewares", "guards", "interceptors",
    "decorators", "annotations", "attributes", "metadata",
    "events", "listeners", "handlers", "processors",
    "workers", "jobs", "tasks", "schedulers", "cron",
    "queues", "streams", "pipes", "filters", "transformers",
    "adapters", "facades", "proxies", "wrappers",
    "factories", "builders", "creators", "generators",
    "singletons", "managers", "providers", "injectors",
    "resolvers", "loaders", "initializers", "bootstrap",
    "startup", "shutdown", "cleanup", "teardown",
    "migrations", "seeds", "fixtures", "factories",
    "fakers", "mocks", "stubs", "doubles", "spies",
    "test-utils", "test_utils", "test-helpers", "test_helpers",
    "test-data", "test_data", "test-fixtures", "test_fixtures",
    "e2e", "integration", "unit", "spec", "specs",
    "stories", "storybook", "chromatic",
    "cypress", "playwright", "selenium", "webdriver",
    "jest", "mocha", "jasmine", "karma", "vitest",
    "eslint", "prettier", "husky", "lint-staged",
    "commitizen", "commitlint", "conventional-changelog",
    "semantic-release", "release", "releases",
    "changelog", "changelogs", "history", "histories",
    "version", "versions", "tags", "branches",
    "main", "master", "develop", "dev", "staging", "stage",
    "production", "prod", "preview", "demo", "sandbox",
    "experimental", "beta", "alpha", "rc", "release-candidate",
    "hotfix", "bugfix", "feature", "enhancement", "improvement",
    "refactor", "cleanup", "optimization", "performance",
    "security", "vulnerability", "patch", "fix", "bug",
    "issue", "issues", "ticket", "tickets", "task", "tasks",
    "todo", "todos", "note", "notes", "comment", "comments",
    "review", "reviews", "feedback", "suggestions",
    "proposal", "proposals", "rfc", "rfcs", "adr", "adrs",
    "decision", "decisions", "meeting", "meetings",
    "agenda", "agendas", "minutes", "summary", "summaries",
    "report", "reports", "analysis", "analyses",
    "research", "investigation", "exploration", "experiment",
    "experiments", "proof-of-concept", "poc", "prototype",
    "prototypes", "mockup", "mockups", "wireframe", "wireframes",
    "design", "designs", "ui", "ux", "frontend", "backend",
    "apis", "rest", "graphql", "grpc", "soap",
    "websocket", "websockets", "sse", "sse", "webhook", "webhooks",
    "microservice", "microservices", "service", "services",
    "gateway", "gateways", "proxy", "proxies", "load-balancer",
    "load-balancers", "reverse-proxy", "reverse-proxies",
    "cdn", "cdn", "edge", "edges", "cache", "caches",
    "database", "databases", "db", "dbs", "sql", "nosql",
    "mongodb", "mysql", "postgresql", "postgres", "sqlite",
    "redis", "memcached", "elasticsearch", "solr",
    "kafka", "rabbitmq", "activemq", "sqs", "sns",
    "s3", "gcs", "azure-blob", "azure-blob-storage",
    "cloud", "aws", "azure", "gcp", "google-cloud",
    "docker", "kubernetes", "k8s", "helm", "terraform",
    "ansible", "chef", "puppet", "salt", "vagrant",
    "jenkins", "gitlab-ci", "github-actions", "azure-devops",
    "circleci", "travis-ci", "appveyor", "bamboo",
    "teamcity", "buildkite", "drone", "concourse",
    "monitoring", "observability", "logging", "tracing",
    "metrics", "alerts", "dashboards", "grafana",
    "prometheus", "influxdb", "datadog", "newrelic",
    "sentry", "rollbar", "bugsnag", "honeybadger",
    "security", "vulnerability", "scanning", "auditing",
    "compliance", "governance", "policies", "standards",
    "documentation", "docs", "wiki", "guides", "tutorials",
    "examples", "samples", "demos", "playground",
    "sandbox", "experimental", "beta", "alpha",
    "deprecated", "legacy", "old", "archive", "backup"
}

LANG_BY_EXT = {
    ".ts": "ts", ".tsx": "tsx",
    ".js": "js", ".jsx": "jsx", ".mjs": "js", ".cjs": "js",
    ".py": "python", ".java": "java", ".kt": "kotlin", ".go": "go",
    ".rb": "ruby", ".php": "php", ".rs": "rust", ".cpp": "cpp", ".cc": "cpp", ".cxx": "cpp", ".c": "c", ".h": "c",
    ".cs": "csharp", ".swift": "swift", ".scala": "scala",
    ".sh": "bash", ".bat": "bat", ".ps1": "powershell",
    ".json": "json", ".yml": "yaml", ".yaml": "yaml", ".toml": "toml", ".ini": "ini", ".conf": "ini",
    ".sql": "sql", ".md": "markdown", ".txt": "text", ".env": "dotenv",
    ".html": "html", ".htm": "html", ".css": "css",
}

# ---------- Utilidades ----------
def is_git_repo(root: str) -> bool:
    return os.path.isdir(os.path.join(root, ".git"))

def have_cmd(cmd: str) -> bool:
    return shutil.which(cmd) is not None

def path_has_git(rel_path: str) -> bool:
    """
    Exclui SOMENTE diretórios/itens dentro de `.git*` (ex.: `.git/`, `.git/objects/`, etc).
    IMPORTANTE: NÃO exclui arquivos como `.gitignore`, `.gitattributes`, `.gitmodules`.
    """
    p = rel_path.replace("\\", "/").lower()
    # Segmentos .git* (mas permite arquivos "dot-git" comuns)
    allowed_dot_git_files = {".gitignore", ".gitattributes", ".gitmodules", ".gitkeep"}
    for seg in p.split("/"):
        if seg == ".git":
            return True
        if seg.startswith(".git") and seg not in allowed_dot_git_files:
            return True
    return False

def is_dependency_dir(dirname: str, dir_path: str = None) -> bool:
    """
    Detecta se um diretório é de dependências, bibliotecas ou arquivos gerados
    que devem ser excluídos para evitar sobrecarregar o arquivo MD final.
    """
    dirname_lower = dirname.lower()
    
    # Diretórios do projeto que NÃO devem ser excluídos
    project_dirs = {"src", "api", "libs", "lib", "modules", "components", "utils", "helpers", "backend", "frontend", "tests"}
    if dirname_lower in project_dirs:
        return False
    
    # Verifica se está na lista de diretórios conhecidos
    if dirname_lower in FALLBACK_PRUNE_DIRS:
        return True
    
    # Se o diretório for muito grande, considera como dependência
    if dir_path and is_large_directory(dir_path):
        return True
    
    # Padrões comuns de diretórios de dependências
    dependency_patterns = [
        # Python
        r"__pycache__", r"\.pyc$", r"\.pyo$", r"\.pyd$", r"\.egg-info$",
        r"\.dist-info$", r"site-packages", r"\.virtualenv", r"\.env",
        
        # Node.js
        r"node_modules", r"\.npm", r"\.yarn", r"\.pnpm", r"\.cache",
        r"\.next", r"\.nuxt", r"\.vuepress", r"\.turbo", r"dist",
        r"build", r"out", r"coverage", r"\.nyc_output", r"\.jest",
        
        # Java
        r"target", r"\.gradle", r"\.mvn", r"\.idea", r"\.vscode",
        r"\.classpath", r"\.project", r"\.settings",
        
        # C/C++
        r"Debug", r"Release", r"x64", r"x86", r"obj", r"bin",
        r"\.vs", r"CMakeFiles", r"\.cmake",
        
        # Go
        r"vendor", r"go\.sum", r"go\.mod",
        
        # Rust
        r"target", r"Cargo\.lock",
        
        # Ruby
        r"vendor", r"bundle", r"\.bundle", r"Gemfile\.lock",
        
        # PHP
        r"vendor", r"composer\.lock",
        
        # Padrões gerais
        r"\.DS_Store", r"Thumbs\.db", r"\.log$", r"logs", r"tmp",
        r"temp", r"\.tmp", r"\.cache", r"cached", r"runtime",
        r"runtimes", r"binaries", r"executables", r"packages",
        r"pkg", r"pkgs", r"libs", r"libraries", r"modules",
        r"components", r"widgets", r"plugins", r"extensions",
        r"addons", r"add-ons", r"extras", r"third-party",
        r"third_party", r"external", r"externals", r"dependencies",
        r"deps", r"dev-dependencies", r"dev_dependencies",
        r"peer-dependencies", r"peer_dependencies", r"optional-dependencies",
        r"bundled-dependencies", r"bundled_dependencies", r"workspaces",
        r"monorepo", r"apps", r"generated", r"auto-generated",
        r"auto_generated", r"build-generated", r"compiled",
        r"transpiled", r"minified", r"uglified", r"sourcemaps",
        r"source-maps", r"source_maps", r"types", r"typings",
        r"definitions", r"interfaces", r"schemas", r"models",
        r"entities", r"dto", r"dtos", r"enums", r"constants",
        r"configs", r"settings", r"utils", r"utilities", r"helpers",
        r"validators", r"validations", r"sanitizers", r"formatters",
        r"parsers", r"serializers", r"deserializers", r"mappers",
        r"repositories", r"repos", r"services", r"controllers",
        r"middleware", r"middlewares", r"guards", r"interceptors",
        r"decorators", r"annotations", r"attributes", r"metadata",
        r"events", r"listeners", r"handlers", r"processors",
        r"workers", r"jobs", r"tasks", r"schedulers", r"cron",
        r"queues", r"streams", r"pipes", r"filters", r"transformers",
        r"adapters", r"facades", r"proxies", r"wrappers",
        r"factories", r"builders", r"creators", r"generators",
        r"singletons", r"managers", r"providers", r"injectors",
        r"resolvers", r"loaders", r"initializers", r"bootstrap",
        r"startup", r"shutdown", r"cleanup", r"teardown",
        r"migrations", r"seeds", r"fixtures", r"factories",
        r"fakers", r"mocks", r"stubs", r"doubles", r"spies",
        r"test-utils", r"test_utils", r"test-helpers", r"test_helpers",
        r"test-data", r"test_data", r"test-fixtures", r"test_fixtures",
        r"e2e", r"integration", r"unit", r"spec", r"specs",
        r"stories", r"storybook", r"chromatic", r"cypress",
        r"playwright", r"selenium", r"webdriver", r"jest", r"mocha",
        r"jasmine", r"karma", r"vitest", r"eslint", r"prettier",
        r"husky", r"lint-staged", r"commitizen", r"commitlint",
        r"conventional-changelog", r"semantic-release", r"release",
        r"releases", r"changelog", r"changelogs", r"history",
        r"histories", r"version", r"versions", r"tags", r"branches",
        r"main", r"master", r"develop", r"dev", r"staging", r"stage",
        r"production", r"prod", r"preview", r"demo", r"sandbox",
        r"experimental", r"beta", r"alpha", r"rc", r"release-candidate",
        r"hotfix", r"bugfix", r"feature", r"enhancement", r"improvement",
        r"refactor", r"cleanup", r"optimization", r"performance",
        r"security", r"vulnerability", r"patch", r"fix", r"bug",
        r"issue", r"issues", r"ticket", r"tickets", r"task", r"tasks",
        r"todo", r"todos", r"note", r"notes", r"comment", r"comments",
        r"review", r"reviews", r"feedback", r"suggestions",
        r"proposal", r"proposals", r"rfc", r"rfcs", r"adr", r"adrs",
        r"decision", r"decisions", r"meeting", r"meetings",
        r"agenda", r"agendas", r"minutes", r"summary", r"summaries",
        r"report", r"reports", r"analysis", r"analyses",
        r"research", r"investigation", r"exploration", r"experiment",
        r"experiments", r"proof-of-concept", r"poc", r"prototype",
        r"prototypes", r"mockup", r"mockups", r"wireframe", r"wireframes",
        r"design", r"designs", r"ui", r"ux",
        r"api", r"apis", r"rest", r"graphql", r"grpc", r"soap",
        r"websocket", r"websockets", r"sse", r"webhook", r"webhooks",
        r"microservice", r"microservices", r"service", r"services",
        r"gateway", r"gateways", r"proxy", r"proxies", r"load-balancer",
        r"load-balancers", r"reverse-proxy", r"reverse-proxies",
        r"cdn", r"edge", r"edges", r"cache", r"caches",
        r"database", r"databases", r"db", r"dbs", r"sql", r"nosql",
        r"mongodb", r"mysql", r"postgresql", r"postgres", r"sqlite",
        r"redis", r"memcached", r"elasticsearch", r"solr",
        r"kafka", r"rabbitmq", r"activemq", r"sqs", r"sns",
        r"s3", r"gcs", r"azure-blob", r"azure-blob-storage",
        r"cloud", r"aws", r"azure", r"gcp", r"google-cloud",
        r"docker", r"kubernetes", r"k8s", r"helm", r"terraform",
        r"ansible", r"chef", r"puppet", r"salt", r"vagrant",
        r"jenkins", r"gitlab-ci", r"github-actions", r"azure-devops",
        r"circleci", r"travis-ci", r"appveyor", r"bamboo",
        r"teamcity", r"buildkite", r"drone", r"concourse",
        r"monitoring", r"observability", r"logging", r"tracing",
        r"metrics", r"alerts", r"dashboards", r"grafana",
        r"prometheus", r"influxdb", r"datadog", r"newrelic",
        r"sentry", r"rollbar", r"bugsnag", r"honeybadger",
        r"security", r"vulnerability", r"scanning", r"auditing",
        r"compliance", r"governance", r"policies", r"standards",
        r"documentation", r"docs", r"wiki", r"guides", r"tutorials",
        r"examples", r"samples", r"demos", r"playground",
        r"sandbox", r"experimental", r"beta", r"alpha",
        r"deprecated", r"legacy", r"old", r"archive", r"backup"
    ]
    
    import re
    for pattern in dependency_patterns:
        if re.search(pattern, dirname_lower):
            return True
    
    return False

def run_git_lsfiles(root: str) -> Optional[List[str]]:
    """
    Lista arquivos usando git ls-files.
    IMPORTANTE: Se os arquivos não estiverem rastreados pelo git, retorna None
    para que o fallback use o filesystem diretamente.
    """
    if not is_git_repo(root) or not have_cmd("git"):
        return None
    try:
        # Usar --cached (rastreados) e --others (não rastreados, mas não ignorados)
        # --exclude-standard respeita .gitignore
        out = subprocess.check_output(
            ["git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard"],
            stderr=subprocess.DEVNULL,
        )
        files = out.decode("utf-8", errors="replace").splitlines()
        files = [f.replace("\\", "/") for f in files if f and not f.endswith("/")]
        # Filtro extra: nunca incluir diretórios `.git*`
        files = [f for f in files if not path_has_git(f)]
        return files if files else None
    except Exception:
        return None

def try_pathspec_iter(root: str) -> Optional[Iterable[str]]:
    try:
        import pathspec  # type: ignore
    except Exception:
        return None
    gi_path = os.path.join(root, ".gitignore")
    if not os.path.exists(gi_path):
        return None
    with open(gi_path, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    spec = pathspec.PathSpec.from_lines("gitwildmatch", lines)

    def walker() -> Iterable[str]:
        for dirpath, dirnames, filenames in os.walk(root):
            rel_dir = os.path.relpath(dirpath, root)
            rel_dir = "" if rel_dir == "." else rel_dir
            # Poda SOMENTE .git* (o resto deve ser controlado pelo .gitignore)
            dirnames[:] = [d for d in dirnames if not d.lower().startswith(".git")]
            # arquivos
            for name in filenames:
                rel = os.path.join(rel_dir, name) if rel_dir else name
                rel = rel.replace("\\", "/")
                if path_has_git(rel):
                    continue
                if not spec.match_file(rel):
                    yield rel
    return walker()

def list_all_files_fallback(root: str) -> Iterable[str]:
    for dirpath, dirnames, filenames in os.walk(root):
        # Fallback sem .gitignore: podar SOMENTE `.git*`
        dirnames[:] = [d for d in dirnames if not d.lower().startswith(".git")]
        rel_dir = os.path.relpath(dirpath, root)
        rel_dir = "" if rel_dir == "." else rel_dir
        for name in filenames:
            rel = os.path.join(rel_dir, name) if rel_dir else name
            rel = rel.replace("\\", "/")
            if path_has_git(rel):
                continue
            yield rel

def choose_fence_for(content: str) -> str:
    if "```" not in content:
        return "```"
    if "````" not in content:
        return "````"
    return "`````"

def lang_for(path: str) -> str:
    _, ext = os.path.splitext(path.lower())
    return LANG_BY_EXT.get(ext, "")

def is_probably_binary(abs_path: str) -> bool:
    try:
        size = os.path.getsize(abs_path)
        if size > MAX_FILE_BYTES:
            return True
        with open(abs_path, "rb") as f:
            chunk = f.read(4096)
        if b"\x00" in chunk:
            return True
        textish = sum((c in (9, 10, 13)) or (32 <= c <= 126) or (160 <= c <= 255) for c in chunk)
        return (len(chunk) > 0 and (textish / len(chunk) < 0.85))
    except Exception:
        return True

def is_large_directory(dir_path: str, max_dir_size_mb: int = 100) -> bool:
    """
    Verifica se um diretório é muito grande (acima do limite especificado em MB).
    Útil para evitar processar diretórios de dependências muito grandes.
    """
    try:
        total_size = 0
        max_size_bytes = max_dir_size_mb * 1024 * 1024
        
        for dirpath, dirnames, filenames in os.walk(dir_path):
            # Para cada arquivo no diretório
            for filename in filenames:
                filepath = os.path.join(dirpath, filename)
                try:
                    total_size += os.path.getsize(filepath)
                    # Se já passou do limite, retorna True imediatamente
                    if total_size > max_size_bytes:
                        return True
                except (OSError, IOError):
                    continue
                    
        return total_size > max_size_bytes
    except Exception:
        return True  # Em caso de erro, considera como grande para ser seguro

def should_exclude(path: str, basename: str = None) -> bool:
    """
    Função centralizada para decidir se um arquivo deve ser excluído.
    CRÍTICO: Esta função é chamada ANTES de ler qualquer arquivo do disco.
    Normaliza path, aplica todos os padrões de exclusão.
    
    Retorna True se o arquivo deve ser excluído por segurança ou por ser pesado/inútil.
    """
    if basename is None:
        basename = os.path.basename(path)
    
    # Normalizar path (sempre usar /) - compatível Windows/Linux
    norm_path = path.replace("\\", "/")
    basename_lower = basename.lower()
    norm_path_lower = norm_path.lower()
    
    # 1. Verificar basename com regex (mais rápido, verifica primeiro)
    for pattern in EXCLUDE_BASENAME_REGEX:
        if re.search(pattern, basename, re.IGNORECASE):
            return True  # Excluído por nome (ex: .env, credentials.json)
    
    # 2. Verificar caminho com regex (ex: /secrets/, /.ssh/)
    for pattern in EXCLUDE_PATH_REGEX:
        if re.search(pattern, norm_path, re.IGNORECASE):
            return True  # Excluído por estar em diretório sensível
    
    # 3. Verificar extensão sensível (ex: .pem, .key, .sqlite)
    ext = os.path.splitext(path.lower())[1]
    if ext in SENSITIVE_EXTS:
        return True  # Excluído por extensão (chaves, certificados, DBs locais)
    
    # 4. Verificar diretórios sensíveis (qualquer segmento do path)
    # Nota: NÃO excluímos "dependências" por heurística aqui — isso deve ficar a cargo do .gitignore.
    path_segments = norm_path.lower().split("/")
    for segment in path_segments:
        # Diretórios sensíveis por padrão (secrets, keys, etc.)
        if any(sensitive_dir in segment for sensitive_dir in ["secrets", "secret", "keys", "certs", "private", "credentials", ".ssh", ".aws"]):
            return True
    
    return False  # Arquivo permitido (ainda pode ser filtrado por should_include)

def redact_secrets(content: str) -> Tuple[str, List[Dict[str, str]]]:
    """
    Detecta e redige segredos no conteúdo.
    Retorna (conteúdo redigido, lista de padrões detectados com tipos).
    """
    if not content:
        return content, []
    
    redactions = []
    redacted_content = content
    
    # Padrões de detecção e redaction (ordem importa - mais específicos primeiro)
    patterns = [
        # Chaves privadas PEM (deve vir primeiro para não ser confundido)
        (r'(-----BEGIN\s+.*PRIVATE\s+KEY-----[\s\S]*?-----END\s+.*PRIVATE\s+KEY-----)', "PRIVATE_KEY", False),
        # Service account JSON (private_key field)
        (r'("private_key"\s*:\s*")([^"]+)(")', "SERVICE_ACCOUNT_KEY", True),
        # OpenAI keys
        (r'(sk-[a-zA-Z0-9]{20,})', "OPENAI_KEY", False),
        # Google API keys
        (r'(AIza[0-9A-Za-z_-]{35})', "GOOGLE_API_KEY", False),
        # JWT tokens (eyJ...)
        (r'(eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,})', "JWT_TOKEN", False),
        # AWS keys
        (r'(AKIA[0-9A-Z]{16})', "AWS_ACCESS_KEY", False),
        (r'(aws_secret_access_key\s*[:=]\s*["\']?)([a-zA-Z0-9/+=]{20,})', "AWS_SECRET_KEY", True),
        # Azure
        (r'(azure_client_secret\s*[:=]\s*["\']?)([a-zA-Z0-9_-]{20,})', "AZURE_CLIENT_SECRET", True),
        # Senhas e tokens (case-insensitive)
        (r'(password\s*[:=]\s*["\']?)([^\s"\'\n]{8,})', "PASSWORD", True),
        (r'(mysql_password\s*[:=]\s*["\']?)([^\s"\'\n]{8,})', "MYSQL_PASSWORD", True),
        (r'(secret\s*[:=]\s*["\']?)([^\s"\'\n]{8,})', "SECRET", True),
        (r'(token\s*[:=]\s*["\']?)([^\s"\'\n]{8,})', "TOKEN", True),
        (r'(api_key\s*[:=]\s*["\']?)([^\s"\'\n]{8,})', "API_KEY", True),
        # Bearer tokens
        (r'(Bearer\s+)([a-zA-Z0-9_-]{40,})', "BEARER_TOKEN", True),
    ]
    
    # Processar padrões em ordem reversa para manter índices corretos
    for pattern, pattern_type, has_groups in reversed(patterns):
        matches = list(re.finditer(pattern, redacted_content, re.IGNORECASE | re.MULTILINE | re.DOTALL))
        if matches:
            redactions.append({
                "pattern": pattern_type,
                "count": len(matches)
            })
            # Redigir cada match (processar de trás para frente para manter índices)
            for match in reversed(matches):
                start, end = match.span()
                if has_groups and len(match.groups()) >= 2:
                    # Padrão com grupos (ex: "password=" + valor)
                    # Manter o prefixo, redigir o valor
                    prefix = match.group(1)
                    redacted_value = f"REDACTED:{pattern_type}"
                    replacement = prefix + redacted_value
                    if len(match.groups()) >= 3:
                        # Tem sufixo também (ex: JSON com aspas)
                        suffix = match.group(3)
                        replacement = prefix + redacted_value + suffix
                else:
                    # Padrão simples, substituir tudo
                    replacement = f"REDACTED:{pattern_type}"
                
                redacted_content = (
                    redacted_content[:start] +
                    replacement +
                    redacted_content[end:]
                )
    
    return redacted_content, redactions

def should_include(path: str, root: str, exclude_basenames: Set[str]) -> bool:
    """
    Decide se um arquivo deve ser incluído no MD.
    CHAMAR should_exclude() PRIMEIRO antes de qualquer outra verificação.
    """
    # 1. PRIMEIRO: Verificar exclusão por segurança (decisão centralizada)
    if should_exclude(path):
        return False
    
    # 2. Nunca incluir .git (diretórios ou arquivos com ".git" no nome)
    if path_has_git(path):
        return False
    
    # 3. Não incluir o próprio arquivo de saída (ou variantes)
    if os.path.basename(path).lower() in exclude_basenames:
        return False
    
    # 4. Verificar extensões binárias
    ext = os.path.splitext(path.lower())[1]
    if ext in EXCLUDE_EXTS:
        return False
    
    # 5. Verificar se é binário (última verificação, mais custosa)
    abs_path = os.path.join(root, path)
    return not is_probably_binary(abs_path)

def read_text(abs_path: str) -> Optional[str]:
    try:
        with open(abs_path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except Exception:
        return None

def get_git_commit(root: str) -> Optional[str]:
    if not is_git_repo(root) or not have_cmd("git"):
        return None
    try:
        out = subprocess.check_output(
            ["git", "-C", root, "rev-parse", "--short", "HEAD"],
            stderr=subprocess.DEVNULL,
        )
        return out.decode().strip()
    except Exception:
        return None

def bytes_len(s: str) -> int:
    return len(s.encode("utf-8", errors="replace"))

# ---------- Project Intelligence Functions ----------
def render_tree(root: str, max_depth: int = 4, max_lines: int = 400) -> str:
    """Gera uma representação em árvore do diretório, limitada por profundidade e linhas."""
    lines = []
    root_abs = os.path.abspath(root)
    
    def walk_tree(current_dir: str, prefix: str = "", depth: int = 0, is_last: bool = True):
        if depth > max_depth or len(lines) >= max_lines:
            return
        
        try:
            items = []
            for item in sorted(os.listdir(current_dir)):
                item_path = os.path.join(current_dir, item)
                # Pular .git e dependências
                if item.startswith(".git") or is_dependency_dir(item, item_path):
                    continue
                if os.path.isdir(item_path) or os.path.isfile(item_path):
                    items.append((item, os.path.isdir(item_path)))
            
            for idx, (item, is_dir) in enumerate(items):
                if len(lines) >= max_lines:
                    lines.append(f"{prefix}... (truncated)")
                    return
                
                is_last_item = (idx == len(items) - 1)
                connector = "└── " if is_last_item else "├── "
                lines.append(f"{prefix}{connector}{item}{'/' if is_dir else ''}")
                
                if is_dir and depth < max_depth:
                    extension = "    " if is_last_item else "│   "
                    walk_tree(
                        os.path.join(current_dir, item),
                        prefix + extension,
                        depth + 1,
                        is_last_item
                    )
        except (OSError, PermissionError):
            pass
    
    walk_tree(root_abs)
    if len(lines) >= max_lines:
        lines.append("... (tree truncated at max_lines)")
    return "\n".join(lines) if lines else "(empty)"

def detect_stack(root: str, file_list: List[str]) -> Dict[str, Any]:
    """Detecta stack tecnológica baseado em arquivos presentes."""
    stack = {"languages": [], "frameworks": [], "infra": [], "signals": []}
    file_set = {f.lower() for f in file_list}
    basenames = {os.path.basename(f).lower() for f in file_list}
    
    # Python
    if any("pyproject.toml" in f or "requirements.txt" in f or "poetry.lock" in f or "setup.py" in f for f in file_list):
        stack["languages"].append("Python")
        if any("fastapi" in f or "fastapi" in str(file_set) for f in file_list):
            stack["frameworks"].append("FastAPI")
        if any("flask" in f or "flask" in str(file_set) for f in file_list):
            stack["frameworks"].append("Flask")
        if any("django" in f for f in file_list):
            stack["frameworks"].append("Django")
    
    # Node.js
    if "package.json" in basenames:
        stack["languages"].append("JavaScript/TypeScript")
        if any("vite.config" in f for f in file_list):
            stack["frameworks"].append("Vite")
        if any("next.config" in f for f in file_list):
            stack["frameworks"].append("Next.js")
        if any("express" in f for f in file_list):
            stack["frameworks"].append("Express")
    
    # Go
    if "go.mod" in basenames:
        stack["languages"].append("Go")
        if any("fiber" in f or "gin" in f for f in file_list):
            stack["frameworks"].append("Go Web Framework")
    
    # Infra
    if "dockerfile" in basenames or any("dockerfile" in f.lower() for f in file_list):
        stack["infra"].append("Docker")
    if "docker-compose.yml" in basenames or "docker-compose.yaml" in basenames:
        stack["infra"].append("Docker Compose")
    if any(".github/workflows" in f for f in file_list):
        stack["infra"].append("GitHub Actions")
    if any("azure-pipelines" in f or ".azure" in f for f in file_list):
        stack["infra"].append("Azure Pipelines")
    if any("terraform" in f for f in file_list):
        stack["infra"].append("Terraform")
    if any("helm" in f for f in file_list):
        stack["infra"].append("Helm")
    
    return stack

def extract_commands(root: str) -> Dict[str, List[str]]:
    """Extrai comandos úteis de Makefile, package.json, pyproject.toml, docker-compose."""
    commands = {"make": [], "npm": [], "poetry": [], "docker_compose": [], "workflows": []}
    
    # Makefile
    makefile_path = os.path.join(root, "Makefile")
    if os.path.exists(makefile_path):
        try:
            with open(makefile_path, "r", encoding="utf-8", errors="replace") as f:
                content = f.read()
                # Regex simples para targets
                targets = re.findall(r'^([a-zA-Z0-9_-]+):', content, re.MULTILINE)
                commands["make"] = [t for t in targets if not t.startswith(".")][:20]
        except Exception:
            pass
    
    # package.json
    pkg_path = os.path.join(root, "package.json")
    if os.path.exists(pkg_path):
        try:
            with open(pkg_path, "r", encoding="utf-8", errors="replace") as f:
                data = json.load(f)
                if "scripts" in data:
                    commands["npm"] = list(data["scripts"].keys())[:20]
        except Exception:
            pass
    
    # pyproject.toml (poetry/uv)
    pyproject_path = os.path.join(root, "pyproject.toml")
    if os.path.exists(pyproject_path):
        try:
            with open(pyproject_path, "r", encoding="utf-8", errors="replace") as f:
                content = f.read()
                if "[tool.poetry.scripts]" in content or "[tool.poetry]" in content:
                    commands["poetry"].append("poetry install")
                    commands["poetry"].append("poetry run pytest")
        except Exception:
            pass
    
    # docker-compose.yml
    compose_paths = [
        os.path.join(root, "docker-compose.yml"),
        os.path.join(root, "docker-compose.yaml"),
    ]
    for compose_path in compose_paths:
        if os.path.exists(compose_path):
            try:
                with open(compose_path, "r", encoding="utf-8", errors="replace") as f:
                    content = f.read()
                    # Regex simples para serviços
                    services = re.findall(r'^\s+([a-zA-Z0-9_-]+):\s*$', content, re.MULTILINE)
                    # Filtrar apenas os que estão dentro de "services:"
                    in_services = False
                    found_services = []
                    for line in content.splitlines():
                        if "services:" in line.lower():
                            in_services = True
                            continue
                        if in_services and line.strip() and not line.startswith(" ") and ":" in line:
                            break
                        if in_services and re.match(r'^\s+[a-zA-Z0-9_-]+:\s*$', line):
                            found_services.append(line.strip().rstrip(":"))
                    commands["docker_compose"] = found_services[:20]
            except Exception:
                pass
    
    # GitHub Actions workflows
    workflows_dir = os.path.join(root, ".github", "workflows")
    if os.path.isdir(workflows_dir):
        try:
            for fname in os.listdir(workflows_dir):
                if fname.endswith((".yml", ".yaml")):
                    commands["workflows"].append(fname)
        except Exception:
            pass
    
    return commands

def extract_entrypoints(file_list: List[str]) -> List[str]:
    """Detecta entrypoints prováveis do projeto."""
    entrypoints = []
    common_names = {
        "app.py", "main.py", "server.py", "index.py", "__main__.py",
        "main.go", "main.ts", "main.js", "index.ts", "index.js",
        "src/main.ts", "src/index.ts", "src/main.js", "src/index.js",
    }
    for f in file_list:
        basename = os.path.basename(f).lower()
        if basename in common_names or f.lower() in [n.lower() for n in common_names]:
            entrypoints.append(f)
    return sorted(entrypoints)[:10]

def extract_env_vars(root: str, selected_files: List[str]) -> Dict[str, Dict[str, Any]]:
    """
    Extrai nomes de variáveis de ambiente (SEM VALORES) do código.
    CRÍTICO: NUNCA inclui valores de env vars, apenas nomes e onde aparecem.
    """
    env_vars: Dict[str, Dict[str, Any]] = {}
    
    # Padrões de regex para diferentes linguagens (captura apenas o nome)
    patterns = [
        (r'os\.getenv\(["\']([^"\']+)["\']', "Python"),
        (r'os\.environ\[["\']([^"\']+)["\']', "Python"),
        (r'process\.env\.([A-Z_][A-Z0-9_]*)', "JavaScript"),
        (r'process\.env\[["\']([^"\']+)["\']', "JavaScript"),
        (r'\$\{([A-Z_][A-Z0-9_]*)\}', "YAML/Shell"),
        (r'\$([A-Z_][A-Z0-9_]*)', "Shell"),
    ]
    
    # Primeiro, tentar .env.example (apenas nomes, sem valores)
    env_example_paths = [
        os.path.join(root, ".env.example"),
        os.path.join(root, ".env.sample"),
        os.path.join(root, "env.example"),
    ]
    for env_path in env_example_paths:
        # Verificar se não foi excluído
        rel_env_path = os.path.relpath(env_path, root).replace("\\", "/")
        if should_exclude(rel_env_path):
            continue
        if os.path.exists(env_path):
            try:
                with open(env_path, "r", encoding="utf-8", errors="replace") as f:
                    for line in f:
                        line = line.strip()
                        if line and not line.startswith("#") and "=" in line:
                            # Extrair apenas o nome (antes do =), ignorar valor
                            var_name = line.split("=")[0].strip()
                            if var_name and var_name.replace("_", "").isalnum():
                                if var_name not in env_vars:
                                    env_vars[var_name] = {"count": 0, "samples": []}
                                env_vars[var_name]["count"] += 1
                                if len(env_vars[var_name]["samples"]) < 3:
                                    env_vars[var_name]["samples"].append(rel_env_path)
            except Exception:
                pass
    
    # Varredura em arquivos de código (apenas nomes, nunca valores)
    for rel_path in selected_files[:500]:  # Limitar para performance
        # Double-check: não processar arquivos excluídos
        if should_exclude(rel_path):
            continue
        abs_path = os.path.join(root, rel_path)
        if not os.path.isfile(abs_path):
            continue
        ext = os.path.splitext(rel_path)[1].lower()
        if ext not in {".py", ".js", ".ts", ".jsx", ".tsx", ".sh", ".yaml", ".yml"}:
            continue
        
        try:
            with open(abs_path, "r", encoding="utf-8", errors="replace") as f:
                content = f.read()
                for pattern, lang in patterns:
                    matches = re.finditer(pattern, content)
                    for match in matches:
                        var_name = match.group(1)  # Apenas o nome, nunca o valor
                        if var_name not in env_vars:
                            env_vars[var_name] = {"count": 0, "samples": []}
                        env_vars[var_name]["count"] += 1
                        if len(env_vars[var_name]["samples"]) < 3 and rel_path not in env_vars[var_name]["samples"]:
                            env_vars[var_name]["samples"].append(rel_path)
        except Exception:
            continue
    
    return env_vars

def extract_api_routes(selected_files: List[str], root: str) -> List[Dict[str, str]]:
    """Extrai rotas de API usando heurísticas para FastAPI, Express, etc."""
    routes = []
    
    # Padrões FastAPI
    fastapi_pattern = re.compile(r'@(app|router)\.(get|post|put|delete|patch|head|options)\s*\(\s*["\']([^"\']+)["\']')
    
    # Padrões Express
    express_pattern = re.compile(r'(app|router)\.(get|post|put|delete|patch|head|options)\s*\(\s*["\']([^"\']+)["\']')
    
    for rel_path in selected_files:
        if not rel_path.endswith((".py", ".js", ".ts")):
            continue
        abs_path = os.path.join(root, rel_path)
        try:
            with open(abs_path, "r", encoding="utf-8", errors="replace") as f:
                content = f.read()
                # FastAPI
                for match in fastapi_pattern.finditer(content):
                    method = match.group(2).upper()
                    path = match.group(3)
                    routes.append({"method": method, "path": path, "file": rel_path})
                # Express
                for match in express_pattern.finditer(content):
                    method = match.group(2).upper()
                    path = match.group(3)
                    routes.append({"method": method, "path": path, "file": rel_path})
        except Exception:
            continue
    
    return routes[:100]  # Limitar

def scan_signals(selected_files: List[str], root: str) -> Dict[str, List[str]]:
    """Escaneia sinais de RAG/LLM e observabilidade."""
    signals = {"rag_llm": [], "observability": []}
    
    rag_keywords = [
        "langchain", "llama_index", "openai", "anthropic", "qdrant", "chroma",
        "pinecone", "embeddings", "vector", "retriever", "llm", "rag"
    ]
    obs_keywords = [
        "opentelemetry", "prometheus", "sentry", "loguru", "structlog",
        "datadog", "newrelic", "grafana", "jaeger", "zipkin"
    ]
    
    for rel_path in selected_files:
        abs_path = os.path.join(root, rel_path)
        if not os.path.isfile(abs_path):
            continue
        try:
            with open(abs_path, "r", encoding="utf-8", errors="replace") as f:
                content = f.read().lower()
                for keyword in rag_keywords:
                    if keyword in content and rel_path not in signals["rag_llm"]:
                        signals["rag_llm"].append(rel_path)
                        break
                for keyword in obs_keywords:
                    if keyword in content and rel_path not in signals["observability"]:
                        signals["observability"].append(rel_path)
                        break
        except Exception:
            continue
    
    return signals

def find_env_files_in_filesystem(root: str) -> List[Dict[str, Any]]:
    """
    Procura arquivos .env* no filesystem real (não só na lista de arquivos).
    Retorna lista com path e se foi excluded.
    """
    env_files = []
    
    def walk_for_env(current_dir: str, depth: int = 0, max_depth: int = 10):
        if depth > max_depth:
            return
        try:
            for item in os.listdir(current_dir):
                item_path = os.path.join(current_dir, item)
                # Pular .git e dependências
                if item.startswith(".git") or is_dependency_dir(item, item_path):
                    continue
                
                if os.path.isfile(item_path):
                    basename_lower = item.lower()
                    if basename_lower.startswith(".env"):
                        rel_path = os.path.relpath(item_path, root)
                        rel_path_norm = rel_path.replace("\\", "/")
                        is_excluded = should_exclude(rel_path_norm, item)
                        env_files.append({
                            "path": rel_path_norm,
                            "excluded": is_excluded
                        })
                elif os.path.isdir(item_path):
                    walk_for_env(item_path, depth + 1, max_depth)
        except (OSError, PermissionError):
            pass
    
    walk_for_env(root)
    return env_files

def scan_smells(root: str, selected_files: List[str], all_files: List[str]) -> Dict[str, Any]:
    """Escaneia smells e gaps: TODOs, testes, .env real (filesystem + lista), maiores arquivos."""
    smells = {
        "todos": [],
        "tests_present": False,
        "tests_count": 0,
        "env_files": [],  # Lista de dicts com path e excluded
        "largest_files": []
    }
    
    todo_pattern = re.compile(r'\b(TODO|FIXME|HACK|XXX|NOTE|BUG)\b', re.IGNORECASE)
    todo_counts: Dict[str, int] = {}
    
    file_sizes: List[Tuple[str, int]] = []
    
    for rel_path in selected_files:
        abs_path = os.path.join(root, rel_path)
        if not os.path.isfile(abs_path):
            continue
        
        # Tamanho do arquivo
        try:
            size = os.path.getsize(abs_path)
            file_sizes.append((rel_path, size))
        except Exception:
            pass
        
        # TODOs
        try:
            with open(abs_path, "r", encoding="utf-8", errors="replace") as f:
                content = f.read()
                matches = len(todo_pattern.findall(content))
                if matches > 0:
                    todo_counts[rel_path] = matches
        except Exception:
            pass
        
        # Testes
        if "test" in rel_path.lower() or "spec" in rel_path.lower():
            smells["tests_present"] = True
            if rel_path.endswith((".py", ".js", ".ts", ".go")):
                smells["tests_count"] += 1
    
    # Top 10 TODOs
    smells["todos"] = sorted(todo_counts.items(), key=lambda x: x[1], reverse=True)[:10]
    
    # .env: verificar filesystem real E lista de arquivos
    env_from_filesystem = find_env_files_in_filesystem(root)
    # Também verificar na lista de arquivos (pode ter .env que não está no filesystem ainda)
    for rel_path in all_files:
        basename = os.path.basename(rel_path).lower()
        if basename.startswith(".env"):
            rel_path_norm = rel_path.replace("\\", "/")
            is_excluded = should_exclude(rel_path_norm, basename)
            # Evitar duplicatas
            if not any(e["path"] == rel_path_norm for e in env_from_filesystem):
                env_from_filesystem.append({
                    "path": rel_path_norm,
                    "excluded": is_excluded
                })
    
    smells["env_files"] = env_from_filesystem
    
    # Top 10 maiores arquivos
    smells["largest_files"] = sorted(file_sizes, key=lambda x: x[1], reverse=True)[:10]
    
    return smells

def smart_extract(rel_path: str, content: str, lang: str, smart_truncate_bytes: int) -> str:
    """Extrai conteúdo inteligente de arquivos grandes: header, assinaturas, footer."""
    content_bytes = len(content.encode("utf-8"))
    if content_bytes <= smart_truncate_bytes:
        return content
    
    lines = content.splitlines()
    header_lines = 120
    footer_lines = 80
    
    # Header
    header = "\n".join(lines[:header_lines])
    
    # Assinaturas (def/class/import em Python; export/function/class em TS/JS; func/type em Go)
    signatures = []
    signature_patterns = {
        "python": re.compile(r'^(def |class |import |from )', re.MULTILINE),
        "ts": re.compile(r'^(export |function |class |import )', re.MULTILINE),
        "js": re.compile(r'^(export |function |class |import |const |let )', re.MULTILINE),
        "go": re.compile(r'^(func |type |import )', re.MULTILINE),
    }
    
    pattern = signature_patterns.get(lang, None)
    if pattern:
        for match in pattern.finditer(content):
            line_num = content[:match.start()].count("\n")
            line = lines[line_num] if line_num < len(lines) else ""
            if line.strip() and line not in signatures:
                signatures.append(line)
                if len(signatures) >= 50:
                    break
    
    # Footer
    footer = "\n".join(lines[-footer_lines:]) if len(lines) > footer_lines else ""
    
    # Montar resultado
    parts = [header]
    if signatures:
        parts.append("\n// ... signatures ...\n")
        parts.append("\n".join(signatures[:50]))
    parts.append("\n\n[TRUNCATED: smart mode - showing header, signatures, and footer]\n\n")
    if footer:
        parts.append(footer)
    
    return "\n".join(parts)

# ---------- Core ----------
def build_file_list(root: str) -> List[str]:
    """
    Constrói lista de arquivos do repositório.
    Prioridade:
    1. git ls-files --cached --others --exclude-standard (respeita .gitignore)
    2. pathspec lendo .gitignore (se disponível)
    3. filesystem direto (fallback) — sem git/pathspec não dá para respeitar .gitignore 100%

    Objetivo: considerar "todos os arquivos" do projeto, exceto os ignorados pelo `.gitignore`,
    mantendo apenas uma camada mínima de segurança via should_exclude().
    """
    files = run_git_lsfiles(root)
    if files is not None and len(files) > 0:
        return sorted(files)

    # Tentar pathspec (respeita .gitignore)
    ps = try_pathspec_iter(root)
    if ps is not None:
        ps_list = list(ps)
        if len(ps_list) > 0:
            return sorted(ps_list)
    
    # Fallback: filesystem direto (inclui tudo, exceto `.git*`)
    return sorted(list(list_all_files_fallback(root)))

def prioritize_files_for_smart(files: List[str]) -> List[str]:
    """Prioriza arquivos para modo SMART: docs primeiro, depois código importante, depois resto."""
    priority_patterns = [
        # Prioridade 1: Documentação
        (lambda f: any(f.lower().startswith(p) for p in ["readme", "docs/", "domain.md", "cursor_rules.md"]), 1),
        # Prioridade 2: Configuração do projeto
        (lambda f: any(f.lower().endswith(p) for p in ["pyproject.toml", "requirements.txt", "package.json", "docker-compose.yml", "docker-compose.yaml", "makefile"]), 2),
        # Prioridade 3: Entrypoints e código principal
        (lambda f: any(f.lower().endswith(p) for p in ["main.py", "app.py", "server.py", "index.py", "main.go", "main.ts", "main.js", "index.ts", "index.js"]), 3),
        (lambda f: "/api/" in f.lower() or "/routes/" in f.lower() or "/routers/" in f.lower() or "/controllers/" in f.lower(), 3),
        # Prioridade 4: Models, schemas, entities
        (lambda f: "/models/" in f.lower() or "/entities/" in f.lower() or "/schemas/" in f.lower(), 4),
        (lambda f: "/migrations/" in f.lower(), 4),
        # Prioridade 5: Resto
        (lambda f: True, 5),
    ]
    
    prioritized = {1: [], 2: [], 3: [], 4: [], 5: []}
    seen = set()
    
    for f in files:
        if f in seen:
            continue
        for pattern_func, priority in priority_patterns:
            if pattern_func(f):
                prioritized[priority].append(f)
                seen.add(f)
                break
    
    result = []
    for priority in sorted(prioritized.keys()):
        result.extend(sorted(prioritized[priority]))
    
    return result

def safety_gate_scan(md_content: str) -> Tuple[str, List[Dict[str, Any]]]:
    """
    Safety Gate: escaneia o MD final gerado procurando por segredos.
    Se encontrar, redige e retorna (conteúdo sanitizado, lista de findings).
    
    CRÍTICO: Usa regex específicos para formatos reais de segredos, evitando falsos positivos
    em comentários de documentação.
    """
    findings = []
    safe_content = md_content
    lines = safe_content.splitlines()
    
    def is_comment_line(line_num: int) -> bool:
        """Verifica se a linha é um comentário (heurística simples)."""
        if line_num < 1 or line_num > len(lines):
            return False
        line = lines[line_num - 1].strip()
        # Ignorar linhas que são claramente comentários
        return line.startswith("#") or line.startswith("//") or line.startswith("--")
    
    def is_placeholder_value(value: str) -> bool:
        """Verifica se o valor é um placeholder/documentação, não um segredo real."""
        value_lower = value.lower()
        # Ignorar valores que são claramente placeholders
        placeholder_patterns = [
            "redacted:",
            "example",
            "placeholder",
            "xxx",
            "your_",
            "secret123",  # Exemplo comum em docs
            "senha123",   # Exemplo comum em docs
            "abc123",     # Exemplo comum
            "test",
            "demo",
        ]
        return any(ph in value_lower for ph in placeholder_patterns)
    
    # Padrões críticos que NUNCA devem aparecer no MD
    # ORDEM: mais específicos primeiro, genéricos por último
    critical_patterns = [
        # 1. Chaves privadas PEM (formato específico)
        (r'(-----BEGIN\s+.*PRIVATE\s+KEY-----[\s\S]*?-----END\s+.*PRIVATE\s+KEY-----)', "PRIVATE_KEY", False),
        # 2. OpenAI keys (formato específico: sk-...)
        (r'(sk-[a-zA-Z0-9]{20,})', "OPENAI_KEY", False),
        # 3. Google API keys (formato específico: AIza...)
        (r'(AIza[0-9A-Za-z_-]{35})', "GOOGLE_API_KEY", False),
        # 4. JWT tokens (formato específico: eyJ...)
        (r'(eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,})', "JWT_TOKEN", False),
        # 5. AWS keys (formato específico: AKIA...)
        (r'(AKIA[0-9A-Z]{16})', "AWS_ACCESS_KEY", False),
        # 6. Service account JSON (formato específico)
        (r'("type"\s*:\s*"service_account"[\s\S]{0,500}?"private_key"\s*:\s*")([^"]+)(")', "SERVICE_ACCOUNT_KEY", True),
        # 7. Senhas e secrets genéricos (apenas se não for comentário)
        # PASSWORD: manter genérico mas verificar contexto
        (r'(password\s*[:=]\s*["\']?)([^\s"\'\n]{12,})', "PASSWORD", True),
        (r'(mysql_password\s*[:=]\s*["\']?)([^\s"\'\n]{12,})', "MYSQL_PASSWORD", True),
        (r'(secret\s*[:=]\s*["\']?)([^\s"\'\n]{12,})', "SECRET", True),
        # 8. TOKEN: apenas se for formato JWT ou Bearer (já coberto acima, mas manter genérico para outros casos)
        (r'(token\s*[:=]\s*["\']?)([a-zA-Z0-9_-]{40,})', "TOKEN", True),
        # 9. API_KEY: apenas se for formato específico (já coberto acima, mas manter para outros formatos)
        (r'(api_key\s*[:=]\s*["\']?)([a-zA-Z0-9_-]{32,})', "API_KEY", True),
    ]
    
    for pattern, pattern_type, check_comment in critical_patterns:
        matches = list(re.finditer(pattern, safe_content, re.IGNORECASE | re.MULTILINE | re.DOTALL))
        if matches:
            for match in matches:
                start, end = match.span()
                line_num = safe_content[:start].count("\n") + 1
                
                # Ignorar se for comentário (apenas para padrões genéricos)
                if check_comment and is_comment_line(line_num):
                    continue
                
                # Ignorar se o valor for um placeholder/documentação
                if check_comment and len(match.groups()) >= 2:
                    value = match.group(2) if len(match.groups()) >= 2 else ""
                    if is_placeholder_value(value):
                        continue
                
                # Redigir
                if len(match.groups()) >= 2:
                    prefix = match.group(1)
                    replacement = prefix + f"REDACTED:{pattern_type}"
                    if len(match.groups()) >= 3:
                        suffix = match.group(3)
                        replacement = prefix + f"REDACTED:{pattern_type}" + suffix
                else:
                    replacement = f"REDACTED:{pattern_type}"
                
                safe_content = safe_content[:start] + replacement + safe_content[end:]
                
                findings.append({
                    "pattern": pattern_type,
                    "line": line_num,
                    "action": "redacted"
                })
    
    return safe_content, findings

def concat_repo(root: str, out_path: str, exclude_basenames: Set[str]) -> Tuple[int, int, bool]:
    """
    Concatena arquivos do repositório em um MD.
    Retorna (included_count, considered_count, safety_gate_failed)
    """
    files = build_file_list(root)
    
    # PRIMEIRO: Filtrar usando should_exclude() antes de qualquer processamento
    selected = []
    excluded_by_security = []
    for p in files:
        if should_exclude(p):
            excluded_by_security.append(p)
        elif should_include(p, root, exclude_basenames):
            selected.append(p)
    
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    commit = get_git_commit(root)
    mode = CONCAT_MODE if CONCAT_MODE in ("full", "smart") else "smart"
    
    # Estatísticas de segurança
    security_stats = {
        "excluded_by_filename": len(excluded_by_security),
        "excluded_files": excluded_by_security[:20],  # Limitar para não poluir
        "redacted_files": [],
        "redaction_patterns": {}
    }
    
    # Priorizar arquivos no modo SMART
    if mode == "smart":
        selected = prioritize_files_for_smart(selected)
    else:
        selected.sort()
    
    # Coletar metadados dos arquivos (APENAS se não foi excluded)
    file_metadata: List[Dict[str, Any]] = []
    for rel in selected:
        # Garantir que não foi excluded (double-check)
        if should_exclude(rel):
            continue
        abs_path = os.path.join(root, rel)
        try:
            stat = os.stat(abs_path)
            file_metadata.append({
                "path": rel,
                "size": stat.st_size,
                "mtime": datetime.fromtimestamp(stat.st_mtime).isoformat(),
                "lang": lang_for(rel)
            })
        except Exception:
            file_metadata.append({
                "path": rel,
                "size": 0,
                "mtime": "",
                "lang": lang_for(rel)
            })
    
    # Project Intelligence
    print("[INFO] Analisando projeto...")
    stack = detect_stack(root, selected)
    commands = extract_commands(root)
    entrypoints = extract_entrypoints(selected)
    env_vars = extract_env_vars(root, selected)
    api_routes = extract_api_routes(selected, root)
    signals = scan_signals(selected, root)
    smells = scan_smells(root, selected, files)  # Passar all_files para detectar .env em qualquer lugar
    tree = render_tree(root, max_depth=4, max_lines=400)
    
    # Contar linguagens por extensão
    lang_counts: Dict[str, int] = {}
    for rel in selected:
        lang = lang_for(rel)
        if lang:
            lang_counts[lang] = lang_counts.get(lang, 0) + 1
    
    # Nome do repo (basename do ROOT)
    repo_name = os.path.basename(os.path.abspath(root))
    
    # Construir seção de Project Intelligence
    intel_lines = [
        "# Project Intelligence",
        "",
        f"## 📦 Repository: {repo_name}",
        f"- **Root**: `{os.path.abspath(root)}`",
        f"- **Git commit**: {commit if commit else '(n/a)'}",
        f"- **Generated at**: {now}",
        "",
        "## 📁 Repository Tree",
        "",
        "```",
        tree,
        "```",
        "",
        "## 🛠️ Stack Detected",
        "",
    ]
    
    if stack["languages"]:
        intel_lines.append(f"- **Languages**: {', '.join(stack['languages'])}")
    if stack["frameworks"]:
        intel_lines.append(f"- **Frameworks**: {', '.join(stack['frameworks'])}")
    if stack["infra"]:
        intel_lines.append(f"- **Infrastructure**: {', '.join(stack['infra'])}")
    if not stack["languages"] and not stack["frameworks"]:
        intel_lines.append("- *(n/a)*")
    
    # Linguagens por extensão
    if lang_counts:
        intel_lines.append("")
        intel_lines.append("### Languages by file count")
        sorted_langs = sorted(lang_counts.items(), key=lambda x: x[1], reverse=True)
        for lang, count in sorted_langs[:10]:
            intel_lines.append(f"- **{lang}**: {count} files")
    
    # Security Report (será atualizado após processar arquivos)
    security_report_placeholder = "<<SECURITY_REPORT_PLACEHOLDER>>"
    intel_lines.extend([
        "",
        "## 🔐 Security Report",
        "",
        security_report_placeholder,
        "",
        "## 🚀 How to Run",
        "",
    ])
    
    if commands["make"]:
        intel_lines.append("### Makefile Targets")
        for target in commands["make"]:
            intel_lines.append(f"- `make {target}`")
        intel_lines.append("")
    
    if commands["npm"]:
        intel_lines.append("### npm scripts")
        for script in commands["npm"]:
            intel_lines.append(f"- `npm run {script}`")
        intel_lines.append("")
    
    if commands["poetry"]:
        intel_lines.append("### Poetry commands")
        for cmd in commands["poetry"]:
            intel_lines.append(f"- `{cmd}`")
        intel_lines.append("")
    
    if commands["docker_compose"]:
        intel_lines.append("### Docker Compose services")
        for svc in commands["docker_compose"]:
            intel_lines.append(f"- `docker-compose up {svc}`")
        intel_lines.append("")
    
    if commands["workflows"]:
        intel_lines.append("### GitHub Actions workflows")
        for wf in commands["workflows"]:
            intel_lines.append(f"- `.github/workflows/{wf}`")
        intel_lines.append("")
    
    if not any(commands.values()):
        intel_lines.append("*(n/a)*")
        intel_lines.append("")
    
    intel_lines.extend([
        "## 🎯 Entrypoints",
        "",
    ])
    if entrypoints:
        for ep in entrypoints:
            intel_lines.append(f"- `{ep}`")
    else:
        intel_lines.append("*(n/a)*")
    intel_lines.append("")
    
    intel_lines.extend([
        "## 🔐 Environment Variables (names only)",
        "",
    ])
    if env_vars:
        sorted_vars = sorted(env_vars.items(), key=lambda x: x[1]["count"], reverse=True)
        for var_name, info in sorted_vars[:50]:
            samples_str = ", ".join(info["samples"][:3])
            intel_lines.append(f"- `{var_name}` (appears {info['count']}x) - {samples_str}")
    else:
        intel_lines.append("*(n/a)*")
    intel_lines.append("")
    
    intel_lines.extend([
        "## 🌐 API Surface",
        "",
    ])
    if api_routes:
        for route in api_routes[:50]:
            intel_lines.append(f"- `{route['method']} {route['path']}` → `{route['file']}`")
    else:
        intel_lines.append("*(n/a)*")
    intel_lines.append("")
    
    intel_lines.extend([
        "## 🤖 RAG/LLM & Observability Signals",
        "",
    ])
    if signals["rag_llm"]:
        intel_lines.append("### RAG/LLM")
        for f in signals["rag_llm"][:10]:
            intel_lines.append(f"- `{f}`")
        intel_lines.append("")
    if signals["observability"]:
        intel_lines.append("### Observability")
        for f in signals["observability"][:10]:
            intel_lines.append(f"- `{f}`")
        intel_lines.append("")
    if not signals["rag_llm"] and not signals["observability"]:
        intel_lines.append("*(n/a)*")
        intel_lines.append("")
    
    intel_lines.extend([
        "## ⚠️ Smells / Gaps",
        "",
    ])
    if smells["todos"]:
        intel_lines.append("### Top TODOs/FIXMEs")
        for path, count in smells["todos"]:
            intel_lines.append(f"- `{path}`: {count} occurrences")
        intel_lines.append("")
    
    intel_lines.append(f"- **Tests present**: {'Yes' if smells['tests_present'] else 'No'} ({smells['tests_count']} test files)")
    if smells['env_files']:
        total_env = len(smells['env_files'])
        excluded_env = sum(1 for e in smells['env_files'] if e.get('excluded', False))
        included_env = total_env - excluded_env
        intel_lines.append(f"- **.env files found**: {total_env} file(s) detected")
        if excluded_env > 0:
            intel_lines.append(f"  - {excluded_env} excluded (security), {included_env} included")
        else:
            intel_lines.append(f"  - All {total_env} included")
        for env_info in smells['env_files'][:5]:
            status = "EXCLUDED" if env_info.get('excluded', False) else "included"
            intel_lines.append(f"  - `{env_info['path']}` ({status})")
    else:
        intel_lines.append("- **.env files found**: No .env files detected")
    intel_lines.append("")
    
    if smells["largest_files"]:
        intel_lines.append("### Largest files")
        for path, size in smells["largest_files"]:
            size_kb = size / 1024
            intel_lines.append(f"- `{path}`: {size_kb:.1f} KB")
        intel_lines.append("")
    
    intelligence_section = "\n".join(intel_lines)
    
    # TOC
    toc_lines = [
        "# Table of Contents",
        "",
        "- [Project Intelligence](#project-intelligence)",
        "- [File Index](#file-index)",
        "- [Files](#files)",
        "",
        "---",
        "",
    ]
    toc = "\n".join(toc_lines)
    
    # File Index
    file_index_lines = [
        "## File Index",
        "",
        "| # | Path | Size (bytes) | Modified | Language |",
        "|---|------|--------------|----------|----------|",
    ]
    for idx, meta in enumerate(file_metadata, 1):
        file_index_lines.append(
            f"| {idx} | `{meta['path']}` | {meta['size']} | {meta['mtime']} | {meta['lang'] or 'text'} |"
        )
    file_index = "\n".join(file_index_lines)
    
    # Header
    header = [
        "# Repository Snapshot (All text files)",
        f"- Root: `{os.path.abspath(root)}`",
        f"- Generated at: {now}",
        f"- Git commit: {commit if commit else '(n/a)'}",
        f"- Mode: {mode}",
        f"- Files included: {len(selected)} (max {MAX_FILE_BYTES} bytes per file, text-only heuristic)",
        "",
    ]
    
    # Files section
    files_header = [
        "---",
        "",
        "# Files",
        "",
    ]
    
    sections: List[str] = []
    total_bytes = bytes_len("\n".join(header + [toc, intelligence_section, file_index] + files_header))
    included = 0
    truncated_count = 0
    
    for idx, rel in enumerate(selected, start=1):
        if MAX_TOTAL_BYTES > 0 and total_bytes >= MAX_TOTAL_BYTES:
            sections.append(f"\n[OUTPUT TRUNCATED BY MAX_TOTAL_BYTES]\n")
            break
        
        # DOUBLE-CHECK: nunca processar arquivos excluded
        if should_exclude(rel):
            continue
        
        abs_path = os.path.join(root, rel)
        content = read_text(abs_path)
        if content is None:
            continue
        
        # Detectar e redigir segredos no conteúdo
        redacted_content, redactions = redact_secrets(content)
        is_redacted = len(redactions) > 0
        file_redactions = redactions  # Guardar para usar depois
        if is_redacted:
            content = redacted_content
            security_stats["redacted_files"].append(rel)
            # Contar padrões
            for redaction in redactions:
                pattern = redaction["pattern"]
                security_stats["redaction_patterns"][pattern] = (
                    security_stats["redaction_patterns"].get(pattern, 0) + redaction["count"]
                )
        
        # Aplicar modo smart se necessário (após redaction)
        lang = lang_for(rel)
        is_truncated = False
        if mode == "smart" and not is_redacted:
            original_size = len(content.encode("utf-8"))
            if original_size > SMART_TRUNCATE_BYTES:
                content = smart_extract(rel, content, lang, SMART_TRUNCATE_BYTES)
                is_truncated = True
                truncated_count += 1
        
        # Metadados do arquivo
        meta = next((m for m in file_metadata if m["path"] == rel), None)
        size_str = f"{meta['size']}" if meta else "?"
        mtime_str = meta["mtime"] if meta else "?"
        
        fence = choose_fence_for(content)
        comment_prefix = "#" if lang in {"python","bash","sh","yaml","toml","ini","sql","markdown","text","dotenv"} else "//"
        comment_lines = [
            f"{comment_prefix} FILE: {rel}",
            f"{comment_prefix} FULL: {os.path.abspath(abs_path)}",
            f"{comment_prefix} SIZE: {size_str} bytes",
            f"{comment_prefix} MTIME: {mtime_str}",
            f"{comment_prefix} NOTE: Concatenated snapshot for review",
        ]
        if is_redacted:
            patterns_found = ", ".join(set(r["pattern"] for r in file_redactions))
            comment_lines.append(f"{comment_prefix} SECURITY: Content redacted due to secret patterns: {patterns_found}")
        if is_truncated:
            comment_lines.append(f"{comment_prefix} TRUNCATED: smart mode applied")
        
        code_header = f"{fence}{lang}" if lang else fence
        code_block = (
            f"## [{idx}] {rel}\n\n"
            f"{code_header}\n"
            + "\n".join(comment_lines) + "\n"
            + content + "\n"
            f"{fence}\n"
        )
        
        block_bytes = bytes_len(code_block)
        if MAX_TOTAL_BYTES > 0 and total_bytes + block_bytes > MAX_TOTAL_BYTES:
            sections.append(f"\n[OUTPUT TRUNCATED BY MAX_TOTAL_BYTES]\n")
            break
        
        sections.append(code_block)
        total_bytes += block_bytes
        included += 1
    
    # Construir Security Report completo agora que temos todas as estatísticas
    security_report_lines = [
        f"- **Files excluded by filename/path**: {security_stats['excluded_by_filename']}",
    ]
    if security_stats['excluded_files']:
        security_report_lines.append("  - Sample excluded files:")
        for exc_file in security_stats['excluded_files'][:10]:
            security_report_lines.append(f"    - `{exc_file}`")
    
    security_report_lines.append(f"- **Files redacted by content**: {len(security_stats['redacted_files'])}")
    if security_stats['redacted_files']:
        security_report_lines.append("  - Redacted files:")
        for red_file in security_stats['redacted_files'][:10]:
            security_report_lines.append(f"    - `{red_file}`")
    
    if security_stats['redaction_patterns']:
        security_report_lines.append("  - Patterns detected:")
        for pattern, count in sorted(security_stats['redaction_patterns'].items(), key=lambda x: x[1], reverse=True):
            security_report_lines.append(f"    - `{pattern}`: {count} occurrences")
    
    security_report = "\n".join(security_report_lines)
    intelligence_section = intelligence_section.replace(security_report_placeholder, security_report)
    
    final_text = "\n".join(header + [toc, intelligence_section, file_index] + files_header + sections)
    
    # Safety Gate: escanear MD final por segredos
    print("[INFO] Executando Safety Gate...")
    safe_final_text, safety_findings = safety_gate_scan(final_text)
    safety_gate_failed = len(safety_findings) > 0
    
    if safety_gate_failed:
        # Listar tipos de padrões detectados (sem valores)
        pattern_types = sorted(set(f["pattern"] for f in safety_findings))
        print(f"[SECURITY] Safety Gate triggered! {len(safety_findings)} segredo(s) detectado(s)", file=sys.stderr)
        print(f"[SECURITY] Tipos detectados: {', '.join(pattern_types)}", file=sys.stderr)
        print(f"[ERRO] Safety Gate detectou {len(safety_findings)} segredo(s) no MD gerado!", file=sys.stderr)
        
        # Reescrever MD com conteúdo sanitizado
        final_text = safe_final_text
        
        # Gerar security_report.json
        security_report_path = os.path.splitext(out_path)[0] + "_security_report.json"
        security_report_data = {
            "generated_at": now,
            "root": os.path.abspath(root),
            "commit": commit,
            "safety_gate_findings": safety_findings,
            "action_taken": "MD reescrito com valores redigidos",
            "excluded_files": security_stats["excluded_files"],
            "redacted_files": security_stats["redacted_files"],
            "redaction_patterns": security_stats["redaction_patterns"]
        }
        try:
            with open(security_report_path, "w", encoding="utf-8") as f:
                json.dump(security_report_data, f, indent=2, ensure_ascii=False)
            print(f"[ERRO] Security report gerado: {security_report_path}", file=sys.stderr)
        except Exception as e:
            print(f"[ERRO] Falha ao gerar security report: {e}", file=sys.stderr)
    else:
        print("[OK] Safety Gate: nenhum segredo detectado no MD final")
    
    # Side-car JSON
    if CONCAT_SIDE_CAR_JSON:
        json_path = os.path.splitext(out_path)[0] + ".meta.json"
        json_data = {
            "root": os.path.abspath(root),
            "generated_at": now,
            "commit": commit,
            "mode": mode,
            "stack_detected": stack,
            "entrypoints": entrypoints,
            "commands": commands,
            "env_vars": {k: {"count": v["count"], "samples": v["samples"]} for k, v in env_vars.items()},
            "api_routes": api_routes[:50],
            "smells": {
                "todos": smells["todos"],
                "tests_present": smells["tests_present"],
                "tests_count": smells["tests_count"],
                "env_files": smells["env_files"],
                "largest_files": [{"path": p, "size": s} for p, s in smells["largest_files"]]
            },
            "security": {
                "excluded_by_filename": security_stats["excluded_by_filename"],
                "excluded_files": security_stats["excluded_files"],
                "redacted_files": security_stats["redacted_files"],
                "redaction_patterns": security_stats["redaction_patterns"]
            },
            "files_included": file_metadata,
            "signals": signals,
        }
        try:
            with open(json_path, "w", encoding="utf-8") as f:
                json.dump(json_data, f, indent=2, ensure_ascii=False)
            print(f"[INFO] Side-car JSON gerado: {json_path}")
        except Exception as e:
            print(f"[WARN] Falha ao gerar side-car JSON: {e}", file=sys.stderr)
    
    # Sobrescrita garantida
    try:
        if os.path.exists(out_path):
            os.remove(out_path)
    except Exception:
        pass
    
    os.makedirs(os.path.dirname(os.path.abspath(out_path)) or ".", exist_ok=True)
    with open(out_path, "w", encoding="utf-8", errors="replace") as f:
        f.write(final_text)
    
    if truncated_count > 0:
        print(f"[INFO] {truncated_count} arquivos truncados no modo smart")
    
    return included, len(selected), safety_gate_failed

def parse_roots_from_env(env_value: str) -> List[str]:
    if not env_value:
        return []
    raw = env_value.replace("|", "\n").replace(";", "\n").splitlines()
    roots = [p.strip().strip('"').strip("'") for p in raw if p.strip()]
    return roots

def resolve_projects() -> Tuple[List[str], bool]:
    cli_roots = [arg for arg in sys.argv[1:] if arg.strip()]
    if cli_roots:
        return cli_roots, True
    env_roots = parse_roots_from_env(CONCAT_ROOTS_ENV)
    if env_roots:
        return env_roots, True
    return [ROOT], False

def main():
    roots, is_multi = resolve_projects()

    if is_multi:
        print(f"[INFO] Projetos a processar ({len(roots)}):")
        for r in roots:
            print("  -", os.path.abspath(r))
        print(f"[INFO] Saída por projeto: <root>\\{CONCAT_OUT_BASENAME}\n")

        any_error = False
        for r in roots:
            if not os.path.isdir(r):
                print(f"[ERRO] ROOT não encontrado: {r}", file=sys.stderr)
                any_error = True
                continue
            out_path = os.path.join(r, CONCAT_OUT_BASENAME)
            exclude_basenames = {os.path.basename(out_path).lower()}
            included, considered, safety_failed = concat_repo(r, out_path, exclude_basenames)
            
            if safety_failed:
                print(f"[ERRO] Safety Gate falhou para {r}!", file=sys.stderr)
                any_error = True
            
            print(f"[OK] Gerado: {out_path}")
            print(f"     Arquivos considerados: {considered} | incluídos (texto): {included}\n")
        if any_error:
            # Se Safety Gate falhou, usar exit code 3 (segurança)
            # Caso contrário, exit code 2 (erro geral)
            sys.exit(3)

    else:
        r = roots[0]
        if not os.path.isdir(r):
            print(f"[ERRO] ROOT não encontrado: {r}", file=sys.stderr)
            sys.exit(2)
        out_path = OUT_PATH
        exclude_basenames = {os.path.basename(out_path).lower()}
        included, considered, safety_failed = concat_repo(r, out_path, exclude_basenames)
        
        if safety_failed:
            print(f"[ERRO] Safety Gate detectou segredos! Build falhou com exit code 3", file=sys.stderr)
            sys.exit(3)
        
        print(f"[OK] Gerado: {out_path}")
        print(f"Arquivos considerados (pós .gitignore): {considered} | incluídos (texto): {included}")

if __name__ == "__main__":
    main()

# ============================================================================
# QUICK SANITY TESTS (comentários para validação manual)
# ============================================================================
#
# Cenário 1: Repo com .git, script no root, sem env/args
#   - Colocar concat_repo_all_text.py na raiz do repo (onde tem .git)
#   - Executar: python concat_repo_all_text.py
#   - Esperado: [OK] e gera <repo>/repo_concat_all.md
#
# Cenário 2: Script em subpasta tools/, repo tem .git acima
#   - Colocar concat_repo_all_text.py em tools/concat_repo_all_text.py
#   - Executar: python tools/concat_repo_all_text.py
#   - Esperado: encontra .git acima e usa repo root, gera <repo>/repo_concat_all.md
#
# Cenário 3: Repo sem .git
#   - Executar script em diretório sem .git
#   - Esperado: usa pasta do script como ROOT, gera <script_dir>/repo_concat_all.md
#
# Cenário 4: Com CONCAT_ROOT e/ou CONCAT_OUT_PATH definidos
#   - Setar env vars: CONCAT_ROOT=C:\outro\repo CONCAT_OUT_PATH=C:\saida.md
#   - Executar: python concat_repo_all_text.py
#   - Esperado: usa valores das env vars (comportamento antigo mantido)
#
# ============================================================================
# SECURITY TESTS (validação de segurança)
# ============================================================================
#
# Teste 1: Arquivo .env em subpasta
#   - Criar backend/.env com: PASSWORD=secret123, API_KEY=sk-abc123
#   - Executar: python concat_repo_all_text.py
#   - Esperado:
#     * backend/.env NÃO aparece no MD (excluído por nome)
#     * Security Report lista backend/.env como excluído
#     * Nenhum valor de senha/chave aparece no MD
#
# Teste 2: Service account JSON
#   - Criar config/service-account.json com campo "private_key"
#   - Executar: python concat_repo_all_text.py
#   - Esperado:
#     * Se o arquivo passar (não for excluído), o campo private_key deve ser redigido
#     * Security Report lista o arquivo como redigido
#     * Padrão SERVICE_ACCOUNT_KEY aparece no relatório
#
# Teste 3: Security Report
#   - Criar múltiplos arquivos sensíveis: .env, secrets/key.pem, credentials.json
#   - Executar: python concat_repo_all_text.py
#   - Esperado:
#     * Security Report mostra quantidade de arquivos excluídos
#     * Lista de sample files excluídos (até 10)
#     * Se algum arquivo for redigido, mostra padrões detectados
#
# Teste 4: Detecção de .env em qualquer pasta
#   - Criar: backend/.env, frontend/.env.local, .env.production
#   - Executar: python concat_repo_all_text.py
#   - Esperado:
#     * Todos os .env são excluídos do MD
#     * Smells/Gaps lista todos os .env encontrados (mesmo excluídos)
#     * Security Report mostra exclusões
#
# Teste 5: Auto-exclusão do próprio MD
#   - Executar: python concat_repo_all_text.py
#   - Esperado:
#     * repo_concat_all.md NÃO aparece no próprio conteúdo
#     * Não há loop infinito ou auto-inclusão
#
# Teste 6: Safety Gate - Detecção de segredos no MD final
#   - Criar um arquivo de código (ex: config.py) com: API_KEY="sk-abc123456789"
#   - Executar: python concat_repo_all_text.py
#   - Esperado:
#     * O arquivo config.py é incluído no MD
#     * Safety Gate detecta o segredo no MD final
#     * MD é reescrito com REDACTED:OPENAI_KEY
#     * security_report.json é gerado com findings
#     * Script retorna exit code 3
#     * Verificar security_report.json contém:
#       - safety_gate_findings com pattern e linha
#       - action_taken: "MD reescrito com valores redigidos"
#
# Teste 7: Safety Gate - Múltiplos padrões
#   - Criar arquivo test_secrets.py com:
#     * PASSWORD="senha123"
#     * TOKEN="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
#     * API_KEY="AIzaSyAbc123..."
#   - Executar: python concat_repo_all_text.py
#   - Esperado:
#     * Safety Gate detecta todos os padrões
#     * security_report.json lista todos os findings
#     * MD final não contém nenhum valor real
#
# ============================================================================