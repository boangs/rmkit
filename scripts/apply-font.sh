#!/usr/bin/env bash
# scripts/apply-font.sh
# 用法：apply-font.sh <字体文件绝对路径>
set -euo pipefail

FONT_PATH="${1:?用法: apply-font.sh <字体路径>}"

if [ ! -f "$FONT_PATH" ]; then
  echo "错误：文件不存在 $FONT_PATH" >&2
  exit 1
fi

EXT="${FONT_PATH##*.}"
if [[ ! "$EXT" =~ ^(ttf|otf|TTF|OTF)$ ]]; then
  echo "错误：仅支持 .ttf/.otf 文件" >&2
  exit 1
fi

FONTS_ACTIVE_DIR="$HOME/.local/share/fonts"
mkdir -p "$FONTS_ACTIVE_DIR"

# 清除旧的 rmkit-cn 激活字体
rm -f "$FONTS_ACTIVE_DIR"/rmkit-cn-active.*

# 创建新符号链接
ln -sf "$FONT_PATH" "$FONTS_ACTIVE_DIR/rmkit-cn-active.$EXT"

# 刷新字体缓存（仅在设备上有效，开发机可能无此命令）
command -v fc-cache >/dev/null 2>&1 && fc-cache -fv || echo "fc-cache 不可用，跳过"

# 重启 xochitl（仅在设备上有效）
command -v systemctl >/dev/null 2>&1 && systemctl restart xochitl || echo "systemctl 不可用，跳过"

echo "字体已应用：$(basename "$FONT_PATH")"
