# ime/overlay.py
from __future__ import annotations

import mmap
import struct
from abc import ABC, abstractmethod
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:  # pragma: no cover – Pillow 不一定在设备外可用
    Image = None  # type: ignore[assignment]
    ImageDraw = None  # type: ignore[assignment]
    ImageFont = None  # type: ignore[assignment]


class Overlay(ABC):
    """Framebuffer 覆盖层抽象基类"""

    @abstractmethod
    def show_candidates(
        self, pinyin: str, candidates: list[str], selected: int = 0
    ) -> None:
        """显示候选词列表"""

    @abstractmethod
    def clear(self) -> None:
        """清除覆盖层"""

    @abstractmethod
    def close(self) -> None:
        """关闭/释放资源"""


class MockOverlay(Overlay):
    """用于测试的 Mock 覆盖层，记录最后一次调用参数"""

    def __init__(self) -> None:
        self.last_pinyin: str = ""
        self.last_candidates: list[str] = []
        self.last_selected: int = 0
        self.cleared: bool = False

    def show_candidates(
        self, pinyin: str, candidates: list[str], selected: int = 0
    ) -> None:
        self.last_pinyin = pinyin
        self.last_candidates = candidates
        self.last_selected = selected
        self.cleared = False

    def clear(self) -> None:
        self.cleared = True

    def close(self) -> None:
        pass


class FramebufferOverlay(Overlay):
    """reMarkable 2 真实设备实现 (8-bit 灰度 Y8 framebuffer)"""

    # 覆盖栏高度 (px)
    _BAR_HEIGHT: int = 60
    # 字体大小
    _FONT_SIZE: int = 28

    def __init__(
        self,
        fb_path: str = "/dev/fb0",
        screen_width: int = 1404,
        screen_height: int = 1872,
    ) -> None:
        self._fb_path = Path(fb_path)
        self._screen_width = screen_width
        self._screen_height = screen_height
        # rM2: 8-bit 灰度，每像素 1 字节
        self._fb_size = screen_width * screen_height
        # 记住上次绘制区域，供 clear 时恢复
        self._saved_region: bytes | None = None

        # 尝试加载字体
        self._font: object | None = None
        if ImageFont is not None:  # pragma: no branch
            try:
                self._font = ImageFont.truetype(
                    "/usr/share/fonts/ttf/noto/NotoSansCJKsc-Regular.otf",
                    self._FONT_SIZE,
                )
            except OSError:
                try:
                    self._font = ImageFont.truetype(
                        "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
                        self._FONT_SIZE,
                    )
                except OSError:
                    self._font = ImageFont.load_default()

    # ------------------------------------------------------------------
    # 公开接口
    # ------------------------------------------------------------------

    def show_candidates(
        self, pinyin: str, candidates: list[str], selected: int = 0
    ) -> None:
        if Image is None or ImageDraw is None:
            return

        bar_y = self._screen_height - self._BAR_HEIGHT

        # 1) 保存即将覆盖的区域
        self._save_region(bar_y)

        # 2) 生成候选词栏图片 (灰度)
        bar_img = self._render_bar(pinyin, candidates, selected)

        # 3) 写入 framebuffer
        self._write_bar(bar_img, bar_y)

    def clear(self) -> None:
        if self._saved_region is None:
            return
        bar_y = self._screen_height - self._BAR_HEIGHT
        self._restore_region(self._saved_region, bar_y)
        self._saved_region = None

    def close(self) -> None:
        self.clear()

    # ------------------------------------------------------------------
    # 内部方法
    # ------------------------------------------------------------------

    def _render_bar(
        self, pinyin: str, candidates: list[str], selected: int
    ) -> Image.Image:
        """生成底部候选栏的灰度图片"""
        img = Image.new("L", (self._screen_width, self._BAR_HEIGHT), 255)
        draw = ImageDraw.Draw(img)

        # 半透明黑色背景 → 灰度 230 (接近白，浅灰)
        draw.rectangle(
            [0, 0, self._screen_width - 1, self._BAR_HEIGHT - 1], fill=230
        )

        # 构造文字: "pinyin | 1:字1 2:字2 ..."
        parts: list[str] = [f" {pinyin} |"]
        for i, c in enumerate(candidates):
            marker = ">" if i == selected else " "
            parts.append(f"{marker}{i + 1}:{c}")
        text = " ".join(parts)

        # 绘制文字 (黑色 = 0)
        draw.text((8, 14), text, fill=0, font=self._font)
        return img

    def _save_region(self, bar_y: int) -> None:
        """读取并保存 framebuffer 中即将被覆盖的区域"""
        try:
            with open(self._fb_path, "r+b") as f:
                with mmap.mmap(f.fileno(), self._fb_size, access=mmap.ACCESS_READ) as mm:
                    start = bar_y * self._screen_width
                    end = start + self._BAR_HEIGHT * self._screen_width
                    self._saved_region = mm[start:end]
        except OSError:
            # 设备文件不存在 (Mock 环境)，用全白填充
            self._saved_region = b"\xff" * (
                self._BAR_HEIGHT * self._screen_width
            )

    def _restore_region(self, data: bytes, bar_y: int) -> None:
        """将之前保存的区域写回 framebuffer"""
        try:
            with open(self._fb_path, "r+b") as f:
                with mmap.mmap(f.fileno(), self._fb_size, access=mmap.ACCESS_WRITE) as mm:
                    start = bar_y * self._screen_width
                    mm[start : start + len(data)] = data
                    mm.flush()
        except OSError:
            pass  # 非设备环境，静默跳过

    def _write_bar(self, bar_img: Image.Image, bar_y: int) -> None:
        """将灰度图片写入 framebuffer 对应行"""
        # 将图片转为原始灰度字节
        raw = bar_img.tobytes()

        try:
            with open(self._fb_path, "r+b") as f:
                with mmap.mmap(f.fileno(), self._fb_size, access=mmap.ACCESS_WRITE) as mm:
                    start = bar_y * self._screen_width
                    mm[start : start + len(raw)] = raw
                    mm.flush()
        except OSError:
            pass  # 非设备环境，静默跳过
