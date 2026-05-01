# ime/tests/test_injector.py
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from ime.injector import MockInjector


def test_mock_inject_char():
    injector = MockInjector()
    injector.inject_char("中")
    assert injector.log == [("char", "中")]


def test_mock_inject_key():
    injector = MockInjector()
    injector.inject_key(30)
    assert injector.log == [("key", "30")]


def test_mock_inject_multiple():
    injector = MockInjector()
    injector.inject_char("你")
    injector.inject_key(2)
    injector.inject_char("好")
    assert len(injector.log) == 3
    assert injector.log[0] == ("char", "你")
    assert injector.log[1] == ("key", "2")
    assert injector.log[2] == ("char", "好")


def test_mock_inject_close():
    injector = MockInjector()
    injector.close()  # 不应抛出异常
