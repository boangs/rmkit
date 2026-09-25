#!/bin/sh
# make-weather-scenes.sh — 把天气插画原稿转成设备用的 JPEG, 并把上缘渐隐烤进图里
#
# 为什么要烤进去: 首页是整幅铺底、文字压在画上。如果在 QML 里盖一层半透明白色做渐隐,
# 墨水屏要为这片中间调做抖动, 又是局部刷新, 结果是又脏又留上一屏的残影。
# 把渐变直接画进 JPEG, 屏幕上就是一张普通的不透明图, 没有合成, 也就没有这些问题。
#
# 渐隐的曲线: 用 pow 2 (缓出), 不用 sigmoidal。
# sigmoidal 在末端有个肩部, 透明度到 0 时斜率不为零, 压在平坦的天空上就会留下
# 一条横贯整幅的淡台阶 (实测亮度从 916 跳到 894, 肉眼就是一条分界线)。
# pow 2 落到 0 时斜率也是 0, 接得上, 看不出边。
#
# 为什么边缘要做成不规则: 进出应用时墨水屏整屏闪黑刷新, 画面里任何一条直的明暗分界
# 都会在刷新过程中被撕成一道硬线。把渐变掺进云雾状噪声, 上缘变成水墨洇开的毛边,
# 没有直线可撕, 观感上画也像是从纸里长出来的。
#
# 用法: tools/make-weather-scenes.sh <原稿目录> [输出目录]
set -eu
SRC=${1:?用法: $0 <原稿目录> [输出目录]}
OUT=${2:-$(dirname "$0")/../space/apps/weather/assets/scenes}
FADE=${FADE:-560}     # 上缘洇开的高度 (原稿像素), 原稿高 1448 时约占四成
ROUGH=${ROUGH:-38}    # 噪声占比 (%), 越大毛边越碎; 0 就退回一条直的渐变
QUALITY=${QUALITY:-85}

command -v magick >/dev/null || { echo "需要 ImageMagick (brew install imagemagick)"; exit 1; }
mkdir -p "$OUT"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

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
  # 罩子: 纯白 + 「竖向渐变掺云雾噪声」当透明度, 上边不透明, 往下洇开到全透
  magick -size "${w}x${FADE}" xc:white \
    \( -size "${w}x${FADE}" gradient:white-black \
       \( -size "${w}x${FADE}" plasma:fractal -colorspace gray -auto-level -blur 0x12 -auto-level \) \
       -compose blend -define compose:args="$((100 - ROUGH)),${ROUGH}" -composite \
       -evaluate pow 2 \) \
    -alpha off -compose CopyOpacity -composite "$TMP/overlay.png"
  magick "$f" "$TMP/overlay.png" -gravity north -compose over -composite \
    -quality "$QUALITY" "$OUT/$b.jpg"

  # 首页大卡用的横幅: 竖图塞进 4.45:1 的横带只能取很薄一片, 取在天空那段就是一片白。
  # 所以单独裁画面下部内容最实的一段, 再给它自己烤一条上缘渐隐。
  h=$(magick identify -format '%h' "$f")
  bh=$((h * 18 / 100))                 # 横幅高度约占原图一成八
  by=$((h * 68 / 100))                 # 从纵向 68% 处起裁 (远山与近景之间)
  bf=$((bh * 45 / 100))                # 渐隐占横幅高度的四成五
  magick -size "${w}x${bf}" xc:white \
    \( -size "${w}x${bf}" gradient:white-black \
       \( -size "${w}x${bf}" plasma:fractal -colorspace gray -auto-level -blur 0x8 -auto-level \) \
       -compose blend -define compose:args="$((100 - ROUGH)),${ROUGH}" -composite \
       -evaluate pow 2 \) \
    -alpha off -compose CopyOpacity -composite "$TMP/boverlay.png"
  magick "$f" -crop "${w}x${bh}+0+${by}" +repage \
    "$TMP/boverlay.png" -gravity north -compose over -composite \
    -quality "$QUALITY" "$OUT/$b-band.jpg"
  n=$((n + 1))
done
echo "✓ $n 张 → $OUT (上缘 ${FADE}px 不规则洇开已烤入, 噪声 ${ROUGH}%)"
