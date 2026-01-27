# backend/scripts/firewall_enrich_lib.py
"""
Lib partilhada para enrich_prompt_firewall: parse de regras, carga do corpus,
normalize_for_firewall, compilação com (?s), rotinas de diff.
"""
from __future__ import annotations

import difflib
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from re import Pattern
from typing import Any

_SCRIPTS = Path(__file__).resolve().parent
_APP_ROOT = _SCRIPTS.parent
if str(_APP_ROOT) not in sys.path:
    sys.path.insert(0, str(_APP_ROOT))

from app.prompt_firewall import infer_category, normalize_for_firewall  # noqa: E402

_DOTALL_RE = re.compile(r"\(\?[^)]*s")


def compile_rule_pattern(pattern: str) -> tuple[Pattern[str] | None, str | None]:
    """
    Compila regex com IGNORECASE + DOTALL se (?s)/(?is). Retorna (compiled, None)
    ou (None, error_msg).
    """
    flags = re.IGNORECASE
    if _DOTALL_RE.search(pattern):
        flags |= re.DOTALL
    try:
        return re.compile(pattern, flags), None
    except re.error as e:
        return None, str(e)


def load_corpus(corpus_dir: str | Path) -> tuple[list[str], list[str]]:
    """
    Carrega malicious_i18n.txt e benign_i18n.txt. Ignora linhas vazias e #.
    Retorna (malicious_lines, benign_lines). UTF-8.
    """
    d = Path(corpus_dir)
    mal, ben = [], []
    for name, out in [("malicious_i18n.txt", mal), ("benign_i18n.txt", ben)]:
        p = d / name
        if not p.is_file():
            continue
        for raw in p.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            out.append(line)
    return mal, ben


def load_corpus_stats_and_samples(
    corpus_dir: str | Path, malicious: list[str], benign: list[str], n_samples: int = 3
) -> dict[str, Any]:
    """Retorna dict com n_malicious, n_benign e exemplos amostrais."""
    return {
        "n_malicious": len(malicious),
        "n_benign": len(benign),
        "malicious_samples": malicious[:n_samples] if malicious else [],
        "benign_samples": benign[:n_samples] if benign else [],
    }


@dataclass
class ProposalRule:
    id: str
    regex: str
    languages: list[str]
    category: str
    rationale: str
    risk_of_fp: str
    expected_hits: list[str]
    expected_non_hits: list[str]
    perf_notes: str = ""


@dataclass
class RuleSpec:
    id: str
    pattern: str
    category: str = "INJECTION"


def parse_firewall_rules(path: str | Path, max_rules: int = 500) -> list[RuleSpec]:
    """Parseia o arquivo de regras (sem compilar)."""
    out: list[RuleSpec] = []
    auto_idx = 0
    p = Path(path)
    if not p.is_file():
        return []
    try:
        content = p.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    for raw in content.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if len(out) >= max_rules:
            break
        rule_id: str
        pattern_str: str
        if "::" in line:
            parts = line.split("::", 1)
            rule_id = (parts[0] or "").strip()
            pattern_str = (parts[1] or "").strip()
            if not rule_id or not pattern_str:
                continue
        else:
            auto_idx += 1
            rule_id = f"rule_{auto_idx:04d}"
            pattern_str = line
        cat = infer_category(rule_id, pattern_str)
        out.append(RuleSpec(id=rule_id, pattern=pattern_str, category=cat))
    return out


def dedup_proposals(proposals: list[ProposalRule], existing: list[RuleSpec]) -> list[ProposalRule]:
    """Remove propostas com id já existente ou regex igual (normalizada)."""
    existing_ids = {r.id for r in existing}
    existing_patterns = {r.pattern.strip().lower() for r in existing}
    out = []
    for p in proposals:
        if p.id in existing_ids:
            continue
        if p.regex.strip().lower() in existing_patterns:
            continue
        existing_ids.add(p.id)
        existing_patterns.add(p.regex.strip().lower())
        out.append(p)
    return out


def rules_file_lines(path: str | Path) -> list[str]:
    """Lê o ficheiro de regras e retorna linhas (para diff)."""
    p = Path(path)
    if not p.is_file():
        return []
    return p.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)


def build_merged_rules_content(
    current_lines: list[str],
    accepted_proposals: list[ProposalRule],
) -> str:
    """
    Constrói novo conteúdo: regras atuais + novas, ordenadas por categoria.
    Mantém cabeçalhos/comentários; insere novas regras nos blocos por categoria.
    """
    # Estrutura simples: preservar cabeçalho até primeira regra; depois blocos por categoria.
    out: list[str] = []
    seen = set()
    for line in current_lines:
        out.append(line)
        if line.strip().startswith("# ") and "=" in line:
            continue
        if "::" in line:
            rid = line.split("::", 1)[0].strip()
            seen.add(rid)

    for p in accepted_proposals:
        if p.id in seen:
            continue
        seen.add(p.id)
        out.append(f"{p.id}::{p.regex}\n")
    return "".join(out)


def unified_diff_rules(old_path: str | Path, new_content: str, from_name: str = "a/rules") -> str:
    """Gera unified diff entre ficheiro atual e new_content."""
    old_lines = rules_file_lines(old_path)
    s = new_content if new_content.endswith("\n") else new_content + "\n"
    new_lines = s.splitlines(keepends=True)
    return "".join(
        difflib.unified_diff(
            old_lines,
            new_lines,
            fromfile=from_name,
            tofile="b/rules",
        )
    )
