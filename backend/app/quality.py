from __future__ import annotations

import re
from dataclasses import dataclass


REFUSAL_ANSWER = "Não encontrei informações confiáveis para responder essa pergunta."

_NUM_RE = re.compile(r"\b\d+(?:[.,]\d+)?\b")
_DAYS_RE = re.compile(r"\b(\d+)\s*(?:dia|dias)\b", re.IGNORECASE)
_DATE_RE = re.compile(r"\b(\d{2}/\d{2}/\d{4})\b")
_NATIONAL_RE = re.compile(r"(?i)\bnacion(?:al|ais)\b")
_INTERNATIONAL_RE = re.compile(r"(?i)\binternacion(?:al|ais)\b")


@dataclass(frozen=True)
class ConflictInfo:
    has_conflict: bool
    details: dict


def detect_conflict(texts: list[str], *, question: str | None = None) -> ConflictInfo:
    """
    Conflito (R1) focado em prazos.

    Regra prática:
    - Só considera "conflito" quando existirem **valores diferentes** para o mesmo escopo.
    - Escopos suportados: nacional / internacional / geral.
    - Se a pergunta já especifica "nacional" ou "internacional", só considera sentenças desse escopo.

    Isso evita falso conflito quando um único doc lista 10 dias (nacional) e 30 dias (internacional).
    """

    q = (question or "").lower()
    target_scopes: set[str] | None = None
    if _NATIONAL_RE.search(q):
        target_scopes = {"nacional"}
    elif _INTERNATIONAL_RE.search(q):
        target_scopes = {"internacional"}

    # scope -> set(values)
    scoped_days: dict[str, set[str]] = {"nacional": set(), "internacional": set(), "geral": set()}
    dates: set[str] = set()

    def scope_for_sentence(s: str) -> str:
        has_n = bool(_NATIONAL_RE.search(s))
        has_i = bool(_INTERNATIONAL_RE.search(s))
        if has_n and not has_i:
            return "nacional"
        if has_i and not has_n:
            return "internacional"
        # quando menciona ambos ou nenhum, tratar como "geral"
        return "geral"

    for t in texts:
        # sentenças por linha e por ponto final (robusto para nossos txt curtos)
        raw_sentences = []
        for line in t.splitlines():
            raw_sentences.extend([p.strip() for p in line.split(".") if p.strip()])

        for s in raw_sentences:
            scope = scope_for_sentence(s)
            if target_scopes is not None and scope not in target_scopes:
                continue
            for m in _DAYS_RE.finditer(s):
                scoped_days[scope].add(m.group(1))
            for m in _DATE_RE.finditer(s):
                dates.add(m.group(1))

    # conflito por escopo: mais de um valor no mesmo escopo
    conflict_scopes = {scope: sorted(vals) for scope, vals in scoped_days.items() if len(vals) > 1}
    has_conflict = bool(conflict_scopes)

    details: dict = {}
    if any(scoped_days.values()):
        details["days_by_scope"] = {k: sorted(v) for k, v in scoped_days.items() if v}
    if dates:
        details["dates"] = sorted(dates)
    if conflict_scopes:
        details["conflict_scopes"] = conflict_scopes

    return ConflictInfo(has_conflict=has_conflict, details=details)


def compute_heuristic_confidence(similarities: list[float], trust_scores: list[float]) -> float:
    if not similarities or not trust_scores:
        return 0.0
    top3_sim = similarities[:3]
    top3_trust = trust_scores[:3]
    avg_sim = sum(top3_sim) / len(top3_sim)
    avg_trust = sum(top3_trust) / len(top3_trust)
    base = (avg_sim * 0.6) + (avg_trust * 0.4)
    return max(0.0, min(1.0, base))


def combine_confidence(heuristic: float, hint: float | None, hint_weight: float = 0.30) -> float:
    if hint is None:
        return max(0.0, min(1.0, heuristic))
    hint = max(0.0, min(1.0, hint))
    heuristic = max(0.0, min(1.0, heuristic))
    final = (1.0 - hint_weight) * heuristic + hint_weight * hint
    return max(0.0, min(1.0, final))


def quality_threshold(confidence: float, threshold: float = 0.65) -> bool:
    return confidence >= threshold


def cross_check_ok(
    doc_types: list[str],
    doc_paths: list[str],
    trust_scores: list[float],
    conflict: ConflictInfo,
) -> bool:
    if conflict.has_conflict:
        return False

    # Regra B: 2 fontes concordam OU 1 fonte POLICY/MANUAL com trust >= 0.85
    distinct_docs = {p for p in doc_paths if p}
    if len(distinct_docs) >= 2:
        return True
    if len(doc_types) == 1:
        dt = (doc_types[0] or "").upper()
        trust = trust_scores[0] if trust_scores else 0.0
        if dt in {"POLICY", "MANUAL"} and trust >= 0.85:
            return True
    return False


def post_validate_answer(answer: str, evidence_text: str) -> bool:
    # Pós-validador simples (R1): números citados devem existir nos trechos.
    answer_nums = set(_NUM_RE.findall(answer))
    if not answer_nums:
        return True
    ev_nums = set(_NUM_RE.findall(evidence_text))
    return answer_nums.issubset(ev_nums)

