# ime/tests/test_pinyin.py
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

import pytest
from ime.pinyin import PinyinEngine

@pytest.fixture
def engine():
    return PinyinEngine()

def test_single_char(engine):
    candidates = engine.get_candidates("ni")
    assert "你" in candidates
    assert "泥" in candidates

def test_two_chars(engine):
    candidates = engine.get_candidates("nihao")
    assert "你好" in candidates[0] or "你好" in candidates

def test_empty_input(engine):
    assert engine.get_candidates("") == []

def test_invalid_input_returns_empty(engine):
    result = engine.get_candidates("123")
    assert result == []

def test_max_candidates(engine):
    candidates = engine.get_candidates("a")
    assert len(candidates) <= 5

def test_clear_buffer(engine):
    engine.append("n")
    engine.append("i")
    assert engine.buffer == "ni"
    engine.clear()
    assert engine.buffer == ""

def test_append_and_get(engine):
    engine.append("n")
    engine.append("i")
    candidates = engine.candidates
    assert len(candidates) > 0
    assert "你" in candidates or "泥" in candidates

def test_backspace(engine):
    engine.append("n")
    engine.append("i")
    engine.backspace()
    assert engine.buffer == "n"
