# ime/keyboard.py
from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass
from enum import Enum
from collections import deque

try:
    import evdev
    from evdev import InputDevice
except ImportError:  # pragma: no cover – evdev 不一定在开发机可用
    evdev = None  # type: ignore[assignment]
    InputDevice = None  # type: ignore[assignment]


class KeyAction(Enum):
    """键盘动作类型"""

    PRESS = 1
    RELEASE = 0
    HOLD = 2


# evdev 事件类型常量
EV_KEY = 0x01


@dataclass
class KeyEvent:
    """键盘事件"""

    code: int
    action: KeyAction
    value: str | None = None


class Keyboard(ABC):
    """键盘设备抽象基类"""

    @abstractmethod
    def read_event(self) -> KeyEvent | None:
        """读取下一个键盘事件，无事件时返回 None"""

    @abstractmethod
    def close(self) -> None:
        """关闭设备"""


class MockKeyboard(Keyboard):
    """用于测试的 Mock 键盘，可通过 push_event() 注入事件"""

    def __init__(self) -> None:
        self._events: deque[KeyEvent] = deque()

    def push_event(self, event: KeyEvent) -> None:
        """注入一个键盘事件"""
        self._events.append(event)

    def read_event(self) -> KeyEvent | None:
        """依次返回注入的事件，队列为空时返回 None"""
        if self._events:
            return self._events.popleft()
        return None

    def close(self) -> None:
        pass


class EvdevKeyboard(Keyboard):
    """真实设备实现，通过 evdev 读取 /dev/input/eventX"""

    # evdev value → KeyAction 映射
    _ACTION_MAP: dict[int, KeyAction] = {
        1: KeyAction.PRESS,
        0: KeyAction.RELEASE,
        2: KeyAction.HOLD,
    }

    def __init__(self, device_path: str) -> None:
        if evdev is None:
            raise RuntimeError("evdev 不可用，无法创建 EvdevKeyboard")
        self._device: InputDevice = InputDevice(device_path)

    def read_event(self) -> KeyEvent | None:
        """从 evdev 设备读取下一个按键事件"""
        for event in self._device.read_loop():
            if event.type == EV_KEY:
                action = self._ACTION_MAP.get(event.value)
                if action is not None:
                    return KeyEvent(code=event.code, action=action)
        return None

    def close(self) -> None:
        self._device.close()
