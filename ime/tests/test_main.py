# ime/tests/test_main.py
"""ImeSession 集成测试 (全部使用 Mock 组件)"""
from __future__ import annotations

import sys
from pathlib import Path

# 确保可以 import ime 目录下的模块
sys.path.insert(0, str(Path(__file__).parent.parent))

from keyboard import KeyAction, KeyEvent, MockKeyboard
from injector import MockInjector
from overlay import MockOverlay
from pinyin import PinyinEngine

from main import ImeSession, KEY_A, KEY_1, KEY_2, KEY_ENTER, KEY_SPACE, KEY_BACKSPACE, KEY_ESC


def _press(code: int) -> KeyEvent:
    return KeyEvent(code=code, action=KeyAction.PRESS)


def _release(code: int) -> KeyEvent:
    return KeyEvent(code=code, action=KeyAction.RELEASE)


def test_type_pinyin_and_select():
    """输入 'ni' → 选第1个候选 → 注入 '你'"""
    kb = MockKeyboard()
    inj = MockInjector()
    ov = MockOverlay()
    engine = PinyinEngine(dict_path=Path("/nonexistent"))  # 不加载词库
    session = ImeSession(kb, engine, ov, inj)

    # n i 1
    kb.push_event(_press(KEY_A + ord("n") - ord("a")))  # KEY_N
    kb.push_event(_press(KEY_A + ord("i") - ord("a")))  # KEY_I
    kb.push_event(_press(KEY_1))
    kb.push_event(_press(KEY_ESC))  # 停止循环

    session.run()

    assert inj.log[-1] == ("char", "你")
    assert ov.cleared is True


def test_type_and_space_select():
    """输入 'hao' → Space 选第一个候选"""
    kb = MockKeyboard()
    inj = MockInjector()
    ov = MockOverlay()
    engine = PinyinEngine(dict_path=Path("/nonexistent"))
    session = ImeSession(kb, engine, ov, inj)

    kb.push_event(_press(KEY_A + ord("h") - ord("a")))  # KEY_H
    kb.push_event(_press(KEY_A + ord("a") - ord("a")))  # KEY_A
    kb.push_event(_press(KEY_A + ord("o") - ord("a")))  # KEY_O
    kb.push_event(_press(KEY_SPACE))
    kb.push_event(_press(KEY_ESC))

    session.run()

    assert inj.log[-1] == ("char", "好")


def test_backspace_in_buffer():
    """退格删除拼音"""
    kb = MockKeyboard()
    inj = MockInjector()
    ov = MockOverlay()
    engine = PinyinEngine(dict_path=Path("/nonexistent"))
    session = ImeSession(kb, engine, ov, inj)

    # 输入 'ni' → 退格 → 缓冲区变 'n'
    kb.push_event(_press(KEY_A + ord("n") - ord("a")))  # KEY_N
    kb.push_event(_press(KEY_A + ord("i") - ord("a")))  # KEY_I
    kb.push_event(_press(KEY_BACKSPACE))
    kb.push_event(_press(KEY_ESC))

    session.run()

    assert engine.buffer == "n"


def test_backspace_empty_passes_through():
    """空缓冲区时退格原样注入"""
    kb = MockKeyboard()
    inj = MockInjector()
    ov = MockOverlay()
    engine = PinyinEngine(dict_path=Path("/nonexistent"))
    session = ImeSession(kb, engine, ov, inj)

    kb.push_event(_press(KEY_BACKSPACE))
    kb.push_event(_press(KEY_ESC))

    session.run()

    # 应该注入退格键码
    assert any(entry[0] == "key" for entry in inj.log)


def test_enter_without_candidates():
    """无候选时 Enter 原样注入"""
    kb = MockKeyboard()
    inj = MockInjector()
    ov = MockOverlay()
    engine = PinyinEngine(dict_path=Path("/nonexistent"))
    session = ImeSession(kb, engine, ov, inj)

    kb.push_event(_press(KEY_ENTER))
    kb.push_event(_press(KEY_ESC))

    session.run()

    assert any(entry[0] == "key" for entry in inj.log)


def test_select_second_candidate():
    """选第2个候选词"""
    kb = MockKeyboard()
    inj = MockInjector()
    ov = MockOverlay()
    engine = PinyinEngine(dict_path=Path("/nonexistent"))
    session = ImeSession(kb, engine, ov, inj)

    # 输入 'ni' → 选第2个 (KEY_2)
    kb.push_event(_press(KEY_A + ord("n") - ord("a")))  # KEY_N
    kb.push_event(_press(KEY_A + ord("i") - ord("a")))  # KEY_I
    kb.push_event(_press(KEY_2))
    kb.push_event(_press(KEY_ESC))

    session.run()

    # "ni" 的第二个候选是 "泥"
    assert inj.log[-1] == ("char", "泥")


def test_release_events_ignored():
    """RELEASE 事件应被忽略"""
    kb = MockKeyboard()
    inj = MockInjector()
    ov = MockOverlay()
    engine = PinyinEngine(dict_path=Path("/nonexistent"))
    session = ImeSession(kb, engine, ov, inj)

    kb.push_event(_release(KEY_A))
    kb.push_event(_press(KEY_ESC))

    session.run()

    # RELEASE 不应产生任何副作用
    assert len(inj.log) == 0
    assert engine.buffer == ""


def test_overlay_shows_candidates():
    """输入时 overlay 应显示候选词"""
    kb = MockKeyboard()
    inj = MockInjector()
    ov = MockOverlay()
    engine = PinyinEngine(dict_path=Path("/nonexistent"))
    session = ImeSession(kb, engine, ov, inj)

    kb.push_event(_press(KEY_A + ord("n") - ord("a")))  # KEY_N
    kb.push_event(_press(KEY_A + ord("i") - ord("a")))  # KEY_I
    kb.push_event(_press(KEY_ESC))

    session.run()

    assert ov.last_pinyin == "ni"
    assert len(ov.last_candidates) > 0


def test_unknown_key_passes_through():
    """非 IME 处理的按键原样注入"""
    kb = MockKeyboard()
    inj = MockInjector()
    ov = MockOverlay()
    engine = PinyinEngine(dict_path=Path("/nonexistent"))
    session = ImeSession(kb, engine, ov, inj)

    # KEY_TAB = 15，不在 IME 处理范围内
    kb.push_event(_press(15))
    kb.push_event(_press(KEY_ESC))

    session.run()

    assert any(entry[0] == "key" and entry[1] == "15" for entry in inj.log)
