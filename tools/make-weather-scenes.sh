#!/bin/sh
# make-weather-scenes.sh — 把天气插画原稿转成设备用的 JPEG
#
# 原稿约定: 文件名 <季节>-<天气>.png, 画幅 2:1。
# 2:1 是刻意的: 首页把插画放在下半幅、大号温度压在它上面的白底里, 两者不重叠,
# 所以不需要任何渐隐或蒙版。
#
# 历史: 早先的原稿是竖幅、整屏铺底、文字压在画上, 为此在图顶烤过一层渐隐白罩
# (sigmoidal 肩部留台阶、噪声毛边被闪黑刷成锯齿……前后折腾了五版)。
# 换成 2:1 之后这些问题的前提没有了 —— 不重叠就不需要过渡, 这段逻辑整个删掉。
# 要翻旧账看 git log 里 make-weather-scenes.sh 的历史版本。
#
# 用法: tools/make-weather-scenes.sh <原稿目录> [输出目录]
set -eu
SRC=${1:?用法: $0 <原稿目录> [输出目录]}
OUT=${2:-$(dirname "$0")/../space/apps/weather/assets/scenes}
WIDTH=${WIDTH:-1200}    # 设备短边 954, 留一点余量; 再大只是白占空间
QUALITY=${QUALITY:-86}
BAND_KEEP=${BAND_KEEP:-45}   # 横幅保留画面下部的百分比 (首页大卡用, 天空那段用不上)

command -v magick >/dev/null || { echo "需要 ImageMagick (brew install imagemagick)"; exit 1; }
mkdir -p "$OUT"

n=0
for f in "$SRC"/*; do
  [ -f "$f" ] || continue
  b=$(basename "$f" | sed -E 's/\.(png|jpe?g|PNG|JPE?G)[[:space:]]*$//')
  [ "$b" = "$(basename "$f")" ] && { echo "跳过 $b (不是 png/jpg)"; continue; }
  case "$b" in
    spring-*|summer-*|autumn-*|winter-*) ;;
    *) echo "跳过 $b (文件名须是 <季节>-<天气>)"; continue ;;
  esac

  magick "$f" -resize "${WIDTH}x>" -quality "$QUALITY" "$OUT/$b.jpg"

  # 首页大卡的横幅: 只取画面下部, 天空那段在横带里就是一片白
  h=$(magick identify -format '%h' "$f")
  bh=$((h * BAND_KEEP / 100))
  magick "$f" -crop "x${bh}+0+$((h - bh))" +repage \
    -resize "${WIDTH}x>" -quality "$QUALITY" "$OUT/$b-band.jpg"
  n=$((n + 1))
done
echo "✓ $n 张 → $OUT (${WIDTH}px 宽, 无渐隐)"
