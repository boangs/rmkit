# ime/tests/test_overlay.py
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from ime.overlay import MockOverlay


def test_mock_initial_state():
    o = MockOverlay()
    assert o.cleared is False
    assert o.last_pinyin == ""
    assert o.last_candidates == []
    assert o.last_selected == 0


def test_mock_show_candidates():
    o = MockOverlay()
    o.show_candidates("ni", ["你", "泥", "呢"], selected=1)
    assert o.last_pinyin == "ni"
    assert o.last_candidates == ["你", "泥", "呢"]
    assert o.last_selected == 1
    assert o.cleared is False


def test_mock_clear():
    o = MockOverlay()
    o.show_candidates("hao", ["好", "号"])
    assert o.cleared is False
    o.clear()
    assert o.cleared is True


def test_mock_close():
    o = MockOverlay()
    o.close()  # 不应抛出异常
