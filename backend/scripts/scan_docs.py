from __future__ import annotations

import os
import re
import sys
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


DOCS_ROOT = Path(os.getenv("DOCS_ROOT", "/docs"))
REPORT_PATH = Path(os.getenv("LAYOUT_REPORT_PATH", "/app/docs/layout_report.md"))


SEP_RE = re.compile(r"^(={3,}|-{3,})\s*$")
UPPER_HEADING_RE = re.compile(r"^[A-ZÁÉÍÓÚÂÊÔÃÕÇ0-9][A-ZÁÉÍÓÚÂÊÔÃÕÇ0-9 ]{5,}$")
MD_HEADING_RE = re.compile(r"^#{1,6}\s+")
QA_RE = re.compile(r"(?i)^\s*(pergunta|q)\s*:\s+|^\s*(resposta|a)\s*:\s+")
NUM_STEP_RE = re.compile(r"^\s*\d+\.\s+")
LIST_RE = re.compile(r"^\s*[-*]\s+")
PIPE_TABLE_RE = re.compile(r"\|")


@dataclass(frozen=True)
class DocStats:
    path: Path
    size_bytes: int
    ext: str
    mtime: float
    encoding_guess: str
    layout_type: str
    patterns: dict
    sample: list[str]


def _read_sample_lines(p: Path, max_lines: int = 80) -> tuple[list[str], str]:
    # encoding heurístico: tenta utf-8, depois latin-1
    for enc in ("utf-8", "utf-8-sig", "cp1252", "latin-1"):
        try:
            text = p.read_text(encoding=enc, errors="strict")
            lines = text.splitlines()
            return lines[:max_lines], enc
        except Exception:
            continue
    text = p.read_text(encoding="utf-8", errors="replace")
    return text.splitlines()[:max_lines], "utf-8(replace)"


def _classify_layout(lines: list[str]) -> tuple[str, dict]:
    has_md_heading = any(MD_HEADING_RE.match(l) for l in lines)
    has_upper_heading = any(UPPER_HEADING_RE.match(l.strip()) for l in lines)
    has_sep = any(SEP_RE.match(l.strip()) for l in lines)
    has_qa = any(QA_RE.match(l) for l in lines)
    num_steps = sum(1 for l in lines if NUM_STEP_RE.match(l))
    bullet_steps = sum(1 for l in lines if LIST_RE.match(l))
    has_table = any(PIPE_TABLE_RE.search(l) for l in lines) and sum(1 for l in lines if "|" in l) >= 3

    patterns = {
        "md_headings": has_md_heading,
        "upper_headings": has_upper_heading,
        "separators": has_sep,
        "qa_blocks": has_qa,
        "numbered_steps": num_steps,
        "bullet_lists": bullet_steps,
        "pipe_table": has_table,
    }

    if has_qa:
        return "L2_FAQ", patterns
    if num_steps >= 2 or bullet_steps >= 4:
        return "L3_PROCEDURE", patterns
    if has_table:
        return "L4_TEXT_TABLE", patterns
    if has_md_heading or has_upper_heading or has_sep:
        return "L1_POLICY", patterns
    return "L1_POLICY", patterns


def iter_files(root: Path) -> Iterable[Path]:
    for p in root.rglob("*"):
        if p.is_file():
            yield p


def main() -> int:
    if not DOCS_ROOT.exists():
        print(f"[scan_docs] DOCS_ROOT não existe: {DOCS_ROOT}", file=sys.stderr)
        return 2

    stats: list[DocStats] = []
    ext_counter: Counter[str] = Counter()

    for p in iter_files(DOCS_ROOT):
        ext = p.suffix.lower() or "(sem_ext)"
        ext_counter[ext] += 1
        st = p.stat()
        sample, enc = _read_sample_lines(p)
        layout, patterns = _classify_layout(sample)
        stats.append(
            DocStats(
                path=p,
                size_bytes=st.st_size,
                ext=ext,
                mtime=st.st_mtime,
                encoding_guess=enc,
                layout_type=layout,
                patterns=patterns,
                sample=sample,
            )
        )

    stats.sort(key=lambda s: s.size_bytes, reverse=True)

    # Preparar exemplos (máx 10 linhas por exemplo)
    def example_block(lines: list[str]) -> str:
        ex = [l.rstrip() for l in lines if l.strip()][:10]
        if not ex:
            return "(vazio)"
        return "\n".join(ex)

    layout_counter = Counter(s.layout_type for s in stats)

    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    now = datetime.now(timezone.utc).isoformat()

    out: list[str] = []
    out.append("## Relatório de layout (gerado)\n")
    out.append(f"- Gerado em: `{now}`\n")
    out.append(f"- DOCS_ROOT: `{DOCS_ROOT}`\n")
    out.append(f"- Total de arquivos: **{len(stats)}**\n")
    out.append("\n### Distribuição por extensão\n")
    for ext, c in ext_counter.most_common():
        out.append(f"- **{ext}**: {c}\n")

    out.append("\n### Top 50 por tamanho\n")
    for s in stats[:50]:
        rel = str(s.path.relative_to(DOCS_ROOT))
        out.append(f"- `{rel}` — {s.size_bytes} bytes — `{s.encoding_guess}` — {datetime.fromtimestamp(s.mtime).isoformat()}\n")

    out.append("\n### Classificação de layouts\n")
    for lt, c in layout_counter.most_common():
        out.append(f"- **{lt}**: {c}\n")

    out.append("\n### Padrões detectados (com exemplos)\n")
    for s in stats[: min(8, len(stats))]:
        rel = str(s.path.relative_to(DOCS_ROOT))
        out.append(f"\n#### `{rel}`\n")
        out.append(f"- layout: **{s.layout_type}**\n")
        out.append(f"- padrões: `{s.patterns}`\n")
        out.append("\nExemplo (até 10 linhas):\n")
        out.append("```\n")
        out.append(example_block(s.sample))
        out.append("\n```\n")

    out.append("\n### Recomendações de chunking (R1)\n")
    out.append("- **Target**: ~650 tokens por chunk (aprox. 2600 chars) com **overlap** ~120 tokens.\n")
    out.append("- **Split primário**: headings (`#`), caixa alta, separadores `====`/`----`.\n")
    out.append("- **FAQ (L2)**: manter pares Pergunta/Resposta no mesmo chunk.\n")
    out.append("- **Procedimento (L3)**: agrupar passos sequenciais; evitar quebrar no meio de uma sequência.\n")
    out.append("- **Tabela textual (L4)**: chunk por blocos (linhas) preservando header quando existir.\n")

    REPORT_PATH.write_text("".join(out), encoding="utf-8")
    print(f"[scan_docs] relatório gerado em {REPORT_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

