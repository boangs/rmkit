#!/bin/sh
# make-weather-scenes.sh — 把天气插画原稿转成设备用的 JPEG, 并把上缘渐隐烤进图里
#
# 为什么要烤进去: 首页是整幅铺底、文字压在画上。如果在 QML 里盖一层半透明白色做渐隐,
# 墨水屏要为这片中间调做抖动, 又是局部刷新, 结果是又脏又留上一屏的残影。
# 把渐变直接画进 JPEG, 屏幕上就是一张普通的不透明图, 没有合成, 也就没有这些问题。
#
# 用法: tools/make-weather-scenes.sh <原稿目录> [输出目录]
set -eu
SRC=${1:?用法: $0 <原稿目录> [输出目录]}
OUT=${2:-$(dirname "$0")/../space/apps/weather/assets/scenes}
FADE=${FADE:-260}     # 上缘渐隐高度 (原稿像素), 原稿高 1448 时约占一成八
QUALITY=${QUALITY:-85}

command -v magick >/dev/null || { echo "需要 ImageMagick (brew install imagemagick)"; exit 1; }
mkdir -p "$OUT"

n=0
for f in "$SRC"/*; do
  [ -f "$f" ] || continue
  # 原稿文件名偶尔带尾随空格 (导出工具留的), 扩展名后面也可能有
  b=$(basename "$f" | sed -E 's/\.(png|jpe?g|PNG|JPE?G)[[:space:]]*$//')
  [ "$b" = "$(basename "$f")" ] && { echo "跳过 $b (不是 png/jpg)"; continue; }
  case "$b" in
    spring-*|summer-*|autumn-*|winter-*) ;;
    *) echo "跳过 $b (文件名须是 <季节>-<天气>)"; continue ;;
  esac
  w=$(magick identify -format '%w' "$f")
  magick "$f" \
    \( -size "${w}x${FADE}" gradient:white-none \
       -channel A -sigmoidal-contrast 4,50% +channel \) \
    -gravity north -composite \
    -quality "$QUALITY" "$OUT/$b.jpg"
  n=$((n + 1))
done
echo "✓ $n 张 → $OUT (上缘 ${FADE}px 渐隐已烤入)"
