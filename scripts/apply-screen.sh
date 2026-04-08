#!/usr/bin/env bash
# scripts/apply-screen.sh
# 用法：apply-screen.sh <PNG 图片绝对路径>
set -euo pipefail

IMAGE_PATH="${1:?用法: apply-screen.sh <图片路径>}"

if [ ! -f "$IMAGE_PATH" ]; then
  echo "错误：文件不存在 $IMAGE_PATH" >&2
  exit 1
fi

EXT="${IMAGE_PATH##*.}"
if [[ ! "$EXT" =~ ^(png|PNG)$ ]]; then
  echo "错误：仅支持 .png 文件" >&2
  exit 1
fi

CONF="$HOME/.config/remarkable/xochitl.conf"

# 确保配置目录存在
mkdir -p "$(dirname "$CONF")"

# 如果配置文件不存在，创建最小配置
if [ ! -f "$CONF" ]; then
  printf '[General]\n' > "$CONF"
fi

# 跨平台 sed -i 辅助函数
_sed_inplace() {
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# 更新或追加 SleepScreenPath
if grep -q "^SleepScreenPath=" "$CONF"; then
  _sed_inplace "s|^SleepScreenPath=.*|SleepScreenPath=$IMAGE_PATH|" "$CONF"
else
  _sed_inplace "/^\[General\]/a\\
SleepScreenPath=$IMAGE_PATH" "$CONF"
fi

echo "休眠屏已设置：$(basename "$IMAGE_PATH")"
echo "下次休眠时生效，无需重启"
