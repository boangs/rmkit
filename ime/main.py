# ime/main.py
"""IME 主循环：键盘事件 → 拼音引擎 → 候选词显示 → 字符注入"""
from __future__ import annotations

import signal
import sys

from keyboard import Keyboard, KeyAction, KeyEvent, EvdevKeyboard
from injector import Injector, UinputInjector
from overlay import Overlay, FramebufferOverlay
from pinyin import PinyinEngine

# evdev 按键码常量 (Linux input-event-codes.h)
KEY_ESC = 1
KEY_BACKSPACE = 14
KEY_ENTER = 28
KEY_SPACE = 57
KEY_1 = 2
KEY_2 = 3
KEY_3 = 4
KEY_4 = 5
KEY_5 = 6
KEY_A = 30
KEY_Z = 44

# 选词键映射: KEY_1~KEY_5 → 索引 0~4
_SELECT_KEYS: dict[int, int] = {
    KEY_1: 0,
    KEY_2: 1,
    KEY_3: 2,
    KEY_4: 3,
    KEY_5: 4,
}

# 字母键码 → 小写字母
_KEY_TO_CHAR: dict[int, str] = {i: chr(ord("a") + i - KEY_A) for i in range(KEY_A, KEY_Z + 1)}


class ImeSession:
    """IME 会话：组合键盘、引擎、覆盖层、注入器"""

    def __init__(
        self,
        keyboard: Keyboard,
        engine: PinyinEngine,
        overlay: Overlay,
        injector: Injector,
    ) -> None:
        self._kb = keyboard
        self._engine = engine
        self._overlay = overlay
        self._injector = injector
        self._running = False

    def stop(self) -> None:
        self._running = False

    def run(self) -> None:
        """主事件循环，阻塞直到 stop() 被调用"""
        self._running = True
        while self._running:
            event = self._kb.read_event()
            if event is None:
                continue
            if event.action != KeyAction.PRESS:
                continue
            self._handle_key(event)

    def _handle_key(self, event: KeyEvent) -> None:
        code = event.code

        # ESC → 退出
        if code == KEY_ESC:
            self.stop()
            return

        # 退格
        if code == KEY_BACKSPACE:
            if self._engine.buffer:
                self._engine.backspace()
                self._refresh_overlay()
            else:
                self._injector.inject_key(code)
            return

        # Enter / Space → 确认第一个候选 / 原样注入
        if code in (KEY_ENTER, KEY_SPACE):
            if self._engine.buffer and self._engine.candidates:
                self._select_candidate(0)
            else:
                self._injector.inject_key(code)
            return

        # 数字键 1-5 → 选词
        if code in _SELECT_KEYS and self._engine.buffer:
            idx = _SELECT_KEYS[code]
            cands = self._engine.candidates
            if idx < len(cands):
                self._select_candidate(idx)
            return

        # 字母键 → 追加到拼音缓冲区
        if code in _KEY_TO_CHAR:
            ch = _KEY_TO_CHAR[code]
            self._engine.append(ch)
            self._refresh_overlay()
            return

        # 其他键原样注入
        self._injector.inject_key(code)

    def _select_candidate(self, idx: int) -> None:
        cands = self._engine.candidates
        if idx >= len(cands):
            return
        self._injector.inject_char(cands[idx])
        self._engine.clear()
        self._overlay.clear()

    def _refresh_overlay(self) -> None:
        cands = self._engine.candidates
        if cands:
            self._overlay.show_candidates(self._engine.buffer, cands)
        else:
            self._overlay.clear()


def main() -> None:
    device_path = sys.argv[1] if len(sys.argv) > 1 else "/dev/input/event1"

    kb = EvdevKeyboard(device_path)
    engine = PinyinEngine()
    overlay = FramebufferOverlay()
    injector = UinputInjector()

    session = ImeSession(kb, engine, overlay, injector)

    # 优雅退出
    def _signal_handler(signum: int, frame: object) -> None:
        session.stop()

    signal.signal(signal.SIGTERM, _signal_handler)
    signal.signal(signal.SIGINT, _signal_handler)

    try:
        session.run()
    finally:
        kb.close()
        overlay.close()
        injector.close()


if __name__ == "__main__":
    main()
