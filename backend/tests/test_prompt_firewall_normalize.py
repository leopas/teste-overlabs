from __future__ import annotations

import pytest

from app.prompt_firewall import normalize_for_firewall


def test_normalize_for_firewall_empty():
    assert normalize_for_firewall("") == ""
    assert normalize_for_firewall("   ") == ""


def test_normalize_for_firewall_pt_instructions():
    # instruções -> instrucoes (remove acentos)
    assert "instrucoes" in normalize_for_firewall("instruções")
    assert normalize_for_firewall("  Instruções  ") == "instrucoes"


def test_normalize_for_firewall_es_contrasena():
    # contraseña -> contrasena
    assert "contrasena" in normalize_for_firewall("contraseña")
    assert normalize_for_firewall("Contraseña") == "contrasena"


def test_normalize_for_firewall_fr_reveler():
    # révéler -> reveler
    assert "reveler" in normalize_for_firewall("révéler")
    assert normalize_for_firewall("Révéler") == "reveler"


def test_normalize_for_firewall_de_ueberspringe():
    # überspringe -> uberspringe (ü -> ue em NFKD? Nope, ü -> u + combining)
    # Mn removes combining; ü decomposes to u + combining diaeresis -> "u"
    out = normalize_for_firewall("überspringe")
    assert "uberspringe" in out or "ueberspringe" in out or "berspringe" in out
    assert "ü" not in out


def test_normalize_for_firewall_it_istruzioni_whitespace():
    s = "  istruzioni   con   spazi  "
    assert normalize_for_firewall(s) == "istruzioni con spazi"


def test_normalize_for_firewall_collapse_whitespace():
    assert normalize_for_firewall("a\tb\nc  d") == "a b c d"
    assert normalize_for_firewall("  x   y   z  ") == "x y z"


def test_normalize_for_firewall_lower():
    assert normalize_for_firewall("REVEAL System PROMPT") == "reveal system prompt"
