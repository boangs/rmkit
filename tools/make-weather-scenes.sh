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
FADE=${FADE:-80}      # 上缘渐隐的高度 (原稿像素)。这是个取舍: 见下面的说明
                      #
                      # 这个值是在两件坏事之间取平衡, 两头都不能要:
                      #  - 渐隐越长, 静态看上缘越柔和; 但渐隐区里画面是一点点显出来的,
                      #    与纯白的差别小到一定程度就不算"变了", 墨水屏刷新时只挑
                      #    够深的那些行去刷, 边界就成了一条虚线似的怪边 (实拍可见)。
                      #  - 渐隐为 0 时刷新范围是干净的矩形; 但这套素材顶端亮度约 85%,
                      #    紧挨纯白页面会现出一条 15% 的硬台阶, 静态很显眼。
                      # 80 是折中: 过渡区只有原稿的 5%, 虚边很窄, 硬台阶也被抹掉。
                      # 文字压不压得住不靠它 —— 素材本身左上角就留了干净的天空。
ROUGH=${ROUGH:-0}     # 噪声占比 (%), 越大毛边越碎; 0 = 一条直的渐变 (默认)
                      # 默认关掉的原因: 墨水屏整屏闪黑时, 变黑的范围跟着画面的
                      # 实际边缘走, 毛边就被刷成一圈锯齿状的黑, 观感比直边差很多。
                      # 直渐变时闪黑范围是干净的矩形。
QUALITY=${QUALITY:-85}

# mkmask <宽> <高> <噪声模糊半径> <输出>
# 造一张"上不透明、下全透、边缘不规则"的白色罩子。
#
# 两端必须是准确的 1 和 0, 这正是上一版的毛病: 噪声是"混"进去的 (blend),
# 于是顶端到不了 1 (画面在最上沿就透出来, 与白底之间现出一条边),
# 底端也到不了 0 (整幅蒙着约 4% 的白纱, 到罩子高度处戛然而止, 又是一条边)。
# 改成"乘"进去: 噪声只在 0.75~1.25 之间缩放那条线性渐变,
#   底端 渐变=0 → 乘完仍是 0, 接得上;
#   顶端 再用 -level 把 ≥0.8 的全部压成 1, 保证完全不透明;
#   最后 pow 2 缓出, 归零处斜率为 0。
mkmask() {
  _w=$1; _h=$2; _blur=$3; _out=$4
  magick -size "${_w}x${_h}" xc:white \
    \( -size "${_w}x${_h}" gradient:white-black \
       \( -size "${_w}x${_h}" plasma:fractal -colorspace gray -auto-level \
          -blur "0x${_blur}" -auto-level \
          -evaluate multiply "$(awk -v r="$ROUGH" 'BEGIN{printf "%.3f", r/100}')" \
          -evaluate add "$(awk -v r="$ROUGH" 'BEGIN{printf "%d%%", 100 - r/2}')" \) \
       -compose multiply -composite \
       -level 0%,80% \
       -evaluate pow 2 \) \
    -alpha off -compose CopyOpacity -composite "$_out"
}

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
  mkmask "$w" "$FADE" 12 "$TMP/overlay.png"
  magick "$f" "$TMP/overlay.png" -gravity north -compose over -composite \
    -quality "$QUALITY" "$OUT/$b.jpg"

  # 首页大卡用的横幅: 竖图塞进 4.45:1 的横带只能取很薄一片, 取在天空那段就是一片白。
  # 所以单独裁画面下部内容最实的一段, 再给它自己烤一条上缘渐隐。
  h=$(magick identify -format '%h' "$f")
  bh=$((h * 18 / 100))                 # 横幅高度约占原图一成八
  by=$((h * 68 / 100))                 # 从纵向 68% 处起裁 (远山与近景之间)
  bf=$((bh * 45 / 100))                # 渐隐占横幅高度的四成五
  mkmask "$w" "$bf" 8 "$TMP/boverlay.png"
  magick "$f" -crop "${w}x${bh}+0+${by}" +repage \
    "$TMP/boverlay.png" -gravity north -compose over -composite \
    -quality "$QUALITY" "$OUT/$b-band.jpg"
  n=$((n + 1))
done
echo "✓ $n 张 → $OUT (上缘 ${FADE}px 渐隐已烤入 (毛边噪声 ${ROUGH}%))"
