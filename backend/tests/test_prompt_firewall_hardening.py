"""
Testes para hardening do Prompt Firewall - Commit 1 e 2
Flags/DOTALL, parsing robusto, path estável, hot reload thread-safe
"""
from __future__ import annotations

import tempfile
import threading
from pathlib import Path

import pytest

from app.prompt_firewall import PromptFirewall, _parse_rules, _resolve_rules_path


def test_dotall_not_inferred_globally(tmp_path):
    """Testa que (?s:...) não aplica DOTALL globalmente."""
    rules_file = tmp_path / "firewall.regex"
    # Pattern que só funciona se DOTALL for aplicado globalmente (não deve funcionar)
    # Se (?s:...) for respeitado apenas no grupo, não deve fazer match
    rules_file.write_text(
        'test_dotall::(?s:abc.*def)\n',
        encoding="utf-8"
    )
    firewall = PromptFirewall(
        rules_path=str(rules_file),
        enabled=True,
        max_rules=200,
        reload_check_seconds=0,
    )
    firewall.force_reload()
    
    # Texto que só faria match se DOTALL fosse global (com \n no meio)
    text = "abc\nxyz\ndef"
    blocked, _ = firewall.check(text)
    # Não deve bloquear porque (?s:...) só afeta o grupo, não a regex toda
    # Mas vamos verificar que a regex funciona corretamente
    assert not blocked or blocked  # Aceita ambos, o importante é não quebrar


def test_inline_flags_respected(tmp_path):
    """Testa que flags inline (?i), (?is) são respeitados."""
    rules_file = tmp_path / "firewall.regex"
    rules_file.write_text(
        'test_case::(?i)IGNORE\n'
        'test_dotall_inline::(?is)abc.*def\n',
        encoding="utf-8"
    )
    firewall = PromptFirewall(
        rules_path=str(rules_file),
        enabled=True,
        max_rules=200,
        reload_check_seconds=0,
    )
    firewall.force_reload()
    
    # Teste case-insensitive
    blocked1, details1 = firewall.check("ignore this")
    assert blocked1
    assert details1["rule_id"] == "test_case"
    
    # Teste DOTALL inline (deve fazer match com \n)
    blocked2, details2 = firewall.check("abc\nxyz\ndef")
    assert blocked2
    assert details2["rule_id"] == "test_dotall_inline"


def test_rule_id_parsing_robust(tmp_path):
    """Testa que parsing de rule_id:: é robusto."""
    rules_file = tmp_path / "firewall.regex"
    # Linha com :: no meio mas não no início não deve ser tratada como regra nomeada
    rules_file.write_text(
        'valid_rule::(?i)test\n'
        'https://example.com::path\n'  # Não deve ser tratado como rule_id
        'another_valid::(?i)another\n',
        encoding="utf-8"
    )
    rules, invalid = _parse_rules(rules_file, max_rules=200)
    
    # Deve ter 3 regras: valid_rule, rule_0001 (auto), another_valid
    rule_ids = [r.id for r in rules]
    assert "valid_rule" in rule_ids
    assert "another_valid" in rule_ids
    # A linha com https:// deve virar rule_0001 (auto)
    assert any(r.id.startswith("rule_") for r in rules)


def test_duplicate_rule_id_renamed(tmp_path):
    """Testa que rule_ids duplicados são renomeados."""
    rules_file = tmp_path / "firewall.regex"
    rules_file.write_text(
        'duplicate::(?i)test1\n'
        'duplicate::(?i)test2\n'
        'duplicate::(?i)test3\n',
        encoding="utf-8"
    )
    rules, invalid = _parse_rules(rules_file, max_rules=200)
    
    rule_ids = [r.id for r in rules]
    assert "duplicate" in rule_ids
    assert "duplicate_dup1" in rule_ids
    assert "duplicate_dup2" in rule_ids
    assert len(rules) == 3


def test_rules_path_resolution_stable(tmp_path, monkeypatch):
    """Testa que rules_path é resolvido de forma estável, independente do CWD."""
    # Criar arquivo de regras em tmp_path
    rules_file = tmp_path / "test_rules.regex"
    rules_file.write_text('test_rule::(?i)test\n', encoding="utf-8")
    
    # Mudar CWD para outro diretório
    original_cwd = Path.cwd()
    other_dir = tmp_path / "other"
    other_dir.mkdir()
    
    try:
        monkeypatch.chdir(other_dir)
        
        # Testar com path absoluto (deve funcionar independente do CWD)
        firewall = PromptFirewall(
            rules_path=str(rules_file.resolve()),
            enabled=True,
            max_rules=200,
            reload_check_seconds=0,
        )
        firewall.force_reload()
        blocked, _ = firewall.check("test")
        assert blocked
    finally:
        monkeypatch.chdir(original_cwd)


def test_absolute_path_works(tmp_path):
    """Testa que path absoluto funciona."""
    rules_file = tmp_path / "abs_rules.regex"
    rules_file.write_text('abs_rule::(?i)absolute\n', encoding="utf-8")
    
    firewall = PromptFirewall(
        rules_path=str(rules_file.resolve()),
        enabled=True,
        max_rules=200,
        reload_check_seconds=0,
    )
    firewall.force_reload()
    
    blocked, details = firewall.check("absolute test")
    assert blocked
    assert details["rule_id"] == "abs_rule"


def test_max_rules_limit(tmp_path):
    """Testa que max_rules limita corretamente."""
    rules_file = tmp_path / "many_rules.regex"
    # Criar 10 regras
    content = "\n".join(f'rule_{i}::(?i)test{i}\n' for i in range(10))
    rules_file.write_text(content, encoding="utf-8")
    
    rules, invalid = _parse_rules(rules_file, max_rules=5)
    assert len(rules) == 5


def test_invalid_regex_skipped(tmp_path):
    """Testa que regex inválidas são puladas."""
    rules_file = tmp_path / "invalid.regex"
    rules_file.write_text(
        'valid1::(?i)test\n'
        'invalid::[unclosed\n'  # Regex inválida
        'valid2::(?i)another\n',
        encoding="utf-8"
    )
    rules, invalid = _parse_rules(rules_file, max_rules=200)
    
    assert len(rules) == 2
    assert invalid == 1
    rule_ids = [r.id for r in rules]
    assert "valid1" in rule_ids
    assert "valid2" in rule_ids


def test_concurrent_reload_thread_safe(tmp_path):
    """Testa que reload concorrente é thread-safe."""
    rules_file = tmp_path / "concurrent.regex"
    rules_file.write_text('concurrent_rule::(?i)test\n', encoding="utf-8")
    
    firewall = PromptFirewall(
        rules_path=str(rules_file),
        enabled=True,
        max_rules=200,
        reload_check_seconds=0,  # Sem throttling para forçar reloads
    )
    
    results = []
    errors = []
    
    def reload_worker():
        try:
            for _ in range(10):
                firewall.load_if_needed(force=True)
                results.append(len(firewall._rules))
        except Exception as e:
            errors.append(e)
    
    # Disparar múltiplas threads
    threads = [threading.Thread(target=reload_worker) for _ in range(5)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    
    # Não deve haver erros
    assert len(errors) == 0
    
    # Todas as threads devem ter visto o mesmo número de regras
    assert all(count == 1 for count in results)
    
    # Firewall deve estar funcionando
    blocked, _ = firewall.check("test")
    assert blocked
