"""
Testes para o enricher do Prompt Firewall: expected_hits / expected_non_hits das propostas.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

_BACKEND = Path(__file__).resolve().parents[1]
if str(_BACKEND) not in sys.path:
    sys.path.insert(0, str(_BACKEND))
_SCRIPTS = _BACKEND / "scripts"
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))

from app.prompt_firewall import normalize_for_firewall  # noqa: E402
import firewall_enrich_lib as lib  # noqa: E402

_ARTIFACTS = _BACKEND.parent / "artifacts"


def _load_proposals(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    data = json.loads(path.read_text(encoding="utf-8"))
    return data.get("proposals") or []


def _load_accepted(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    data = json.loads(path.read_text(encoding="utf-8"))
    return data.get("accepted") or []


@pytest.fixture
def proposals_path() -> Path:
    return _ARTIFACTS / "proposals.json"


@pytest.fixture
def validation_report_path() -> Path:
    return _ARTIFACTS / "validation_report.json"


def test_proposal_expected_hits_and_non_hits(proposals_path: Path, validation_report_path: Path) -> None:
    """Para cada proposta (ou accepted): expected_hits batem, expected_non_hits não batem."""
    accepted = _load_accepted(validation_report_path)
    proposals = _load_proposals(proposals_path) if not accepted else accepted
    if not proposals:
        pytest.skip("no proposals nor accepted")
    for p in proposals:
        regex = p.get("regex") or ""
        hits = p.get("expected_hits") or []
        non_hits = p.get("expected_non_hits") or []
        comp, err = lib.compile_rule_pattern(regex)
        assert comp is not None and err is None, f"invalid regex {p.get('id')!r}: {err}"
        for h in hits:
            norm = normalize_for_firewall(h)
            assert comp.search(norm), f"expected hit for {p.get('id')!r}: {h!r}"
        for n in non_hits:
            norm = normalize_for_firewall(n)
            assert not comp.search(norm), f"expected non-hit for {p.get('id')!r}: {n!r}"
