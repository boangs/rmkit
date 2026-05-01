# ime/injector.py
from __future__ import annotations

from abc import ABC, abstractmethod

try:
    import evdev
    from evdev import UInput
    from evdev.ecodes import EV_KEY, KEY_LEFTCTRL, KEY_LEFTSHIFT, KEY_U, KEY_ENTER, KEY_0, KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9, KEY_A, KEY_B, KEY_C, KEY_D, KEY_E, KEY_F
except ImportError:  # pragma: no cover – evdev 不一定在开发机可用
    evdev = None  # type: ignore[assignment]
    UInput = None  # type: ignore[assignment]
    EV_KEY = 0x01  # type: ignore[assignment]
    KEY_LEFTCTRL = 0  # type: ignore[assignment]
    KEY_LEFTSHIFT = 0  # type: ignore[assignment]
    KEY_U = 0  # type: ignore[assignment]
    KEY_ENTER = 0  # type: ignore[assignment]
    KEY_0 = 0  # type: ignore[assignment]
    KEY_1 = 0  # type: ignore[assignment]
    KEY_2 = 0  # type: ignore[assignment]
    KEY_3 = 0  # type: ignore[assignment]
    KEY_4 = 0  # type: ignore[assignment]
    KEY_5 = 0  # type: ignore[assignment]
    KEY_6 = 0  # type: ignore[assignment]
    KEY_7 = 0  # type: ignore[assignment]
    KEY_8 = 0  # type: ignore[assignment]
    KEY_9 = 0  # type: ignore[assignment]
    KEY_A = 0  # type: ignore[assignment]
    KEY_B = 0  # type: ignore[assignment]
    KEY_C = 0  # type: ignore[assignment]
    KEY_D = 0  # type: ignore[assignment]
    KEY_E = 0  # type: ignore[assignment]
    KEY_F = 0  # type: ignore[assignment]


class Injector(ABC):
    """字符注入抽象基类"""

    @abstractmethod
    def inject_char(self, char: str) -> None:
        """注入一个 Unicode 字符"""

    @abstractmethod
    def inject_key(self, code: int) -> None:
        """注入一个按键码"""

    @abstractmethod
    def close(self) -> None:
        """关闭设备"""


class MockInjector(Injector):
    """用于测试的 Mock 注入器，记录所有注入操作"""

    def __init__(self) -> None:
        self.log: list[tuple[str, ...]] = []

    def inject_char(self, char: str) -> None:
        self.log.append(("char", char))

    def inject_key(self, code: int) -> None:
        self.log.append(("key", str(code)))

    def close(self) -> None:
        pass


# 十六进制字符 → evdev 按键码映射
_HEX_KEY_MAP: dict[str, int] = {
    "0": KEY_0, "1": KEY_1, "2": KEY_2, "3": KEY_3,
    "4": KEY_4, "5": KEY_5, "6": KEY_6, "7": KEY_7,
    "8": KEY_8, "9": KEY_9, "a": KEY_A, "b": KEY_B,
    "c": KEY_C, "d": KEY_D, "e": KEY_E, "f": KEY_F,
}


class UinputInjector(Injector):
    """真实设备实现，通过 python-evdev 的 UInput 注入字符

    中文字符通过 Ctrl+Shift+U + hex + Enter 序列注入（Unicode 输入法），
    按键码通过 EV_KEY 事件直接注入。
    """

    def __init__(self, uinput_device: UInput | None = None) -> None:  # type: ignore[valid-type]
        if evdev is None:
            raise RuntimeError("evdev 不可用，无法创建 UinputInjector")
        if uinput_device is not None:
            self._ui: UInput = uinput_device  # type: ignore[valid-type]
        else:
            self._ui = UInput()

    def _press_key(self, code: int) -> None:
        """注入单个按键的按下和释放事件"""
        self._ui.write(EV_KEY, code, 1)
        self._ui.syn()
        self._ui.write(EV_KEY, code, 0)
        self._ui.syn()

    def _hold_key(self, code: int) -> None:
        """按下按键"""
        self._ui.write(EV_KEY, code, 1)
        self._ui.syn()

    def _release_key(self, code: int) -> None:
        """释放按键"""
        self._ui.write(EV_KEY, code, 0)
        self._ui.syn()

    def inject_char(self, char: str) -> None:
        """通过 Ctrl+Shift+U 序列注入 Unicode 字符"""
        hex_str = format(ord(char), "x")
        # 按下 Ctrl+Shift
        self._hold_key(KEY_LEFTCTRL)
        self._hold_key(KEY_LEFTSHIFT)
        # 按 U
        self._press_key(KEY_U)
        # 释放 Shift+Ctrl
        self._release_key(KEY_LEFTSHIFT)
        self._release_key(KEY_LEFTCTRL)
        # 输入十六进制数字
        for digit in hex_str:
            self._press_key(_HEX_KEY_MAP[digit])
        # 按 Enter 确认
        self._press_key(KEY_ENTER)

    def inject_key(self, code: int) -> None:
        """直接注入 EV_KEY 事件"""
        self._press_key(code)

    def close(self) -> None:
        self._ui.close()
