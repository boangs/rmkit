# ime/tests/test_keyboard.py
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from ime.keyboard import KeyAction, KeyEvent, MockKeyboard


def test_mock_keyboard_push_and_read():
    kb = MockKeyboard()
    e1 = KeyEvent(code=30, action=KeyAction.PRESS, value="a")
    e2 = KeyEvent(code=48, action=KeyAction.RELEASE)
    e3 = KeyEvent(code=46, action=KeyAction.HOLD, value="c")
    kb.push_event(e1)
    kb.push_event(e2)
    kb.push_event(e3)

    assert kb.read_event() == e1
    assert kb.read_event() == e2
    assert kb.read_event() == e3


def test_mock_keyboard_empty_read():
    kb = MockKeyboard()
    assert kb.read_event() is None


def test_key_action_values():
    assert KeyAction.PRESS.value == 1
    assert KeyAction.RELEASE.value == 0
    assert KeyAction.HOLD.value == 2


def test_key_event_dataclass():
    e = KeyEvent(code=42, action=KeyAction.PRESS, value="shift")
    assert e.code == 42
    assert e.action == KeyAction.PRESS
    assert e.value == "shift"

    e_no_value = KeyEvent(code=30, action=KeyAction.RELEASE)
    assert e_no_value.value is None


def test_mock_keyboard_close():
    kb = MockKeyboard()
    kb.close()  # 不应抛出异常
