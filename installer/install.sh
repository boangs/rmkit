#!/usr/bin/env bash
# installer/install.sh
# 在用户电脑上运行，通过 SSH 将 rmkit-cn 部署到 reMarkable 设备
# 用法：bash install.sh [--uninstall]
set -euo pipefail

DEVICE_IP="${DEVICE_IP:-10.11.99.1}"
DEVICE_USER="root"
REMOTE_BASE="/home/root/rmkit-cn"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ─── 卸载模式 ───────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
  echo "=== rmkit-cn 卸载 ==="
  ssh "$DEVICE_USER@$DEVICE_IP" "
    systemctl stop    rmkit-cn-upload.service rmkit-cn-version.path rmkit-cn-ime-http.service 2>/dev/null || true
    systemctl disable rmkit-cn-upload.service rmkit-cn-version.path rmkit-cn-ime-http.service 2>/dev/null || true
    # 历史 Python IME unit (现已归档到 legacy/ime-py/), 老设备上可能残留, 一并清
    systemctl stop    rmkit-cn-ime.service rmkit-cn-ime-udev.service 2>/dev/null || true
    systemctl disable rmkit-cn-ime.service rmkit-cn-ime-udev.service 2>/dev/null || true
    rm -rf $REMOTE_BASE
    # 清 upper (overlay 上层 tmpfs) + lower (ext4) 的 unit / drop-in
    mount -o remount,rw / 2>/dev/null || true
    MNT=/tmp/rmkit-cn-uninst-rootfs
    mkdir -p \$MNT && mount --bind / \$MNT 2>/dev/null || true
    for D in /etc \$MNT/etc; do
      rm -f \$D/systemd/system/rmkit-cn-*.service \$D/systemd/system/rmkit-cn-*.path
      rm -f \$D/systemd/system/xochitl.service.d/zz-rmkit-cn.conf \
            \$D/systemd/system/xochitl.service.d/zz-rmkit-cn.conf.bak* \
            \$D/systemd/system/xochitl.service.d/zz-rmkit-cn.conf.old
      rmdir \$D/systemd/system/xochitl.service.d 2>/dev/null || true
    done
    if mountpoint -q \$MNT 2>/dev/null; then sync; umount -l \$MNT 2>/dev/null || true; rmdir \$MNT 2>/dev/null || true; fi
    rm -f /etc/udev/rules.d/99-rmkit-cn-ime.rules
    # 清理 XOVI QMD 文件
    rm -f /home/root/xovi/exthome/qt-resource-rebuilder/pinyin_input.qmd
    rm -f /home/root/xovi/exthome/qt-resource-rebuilder/advanced_panel.qmd
    rm -f /home/root/xovi/exthome/qt-resource-rebuilder/language_zh_cn.qmd
    rm -f /home/root/xovi/exthome/qt-resource-rebuilder/ai_text_button.qmd
    rm -f /home/root/xovi/exthome/qt-resource-rebuilder/zh_CN.rcc
    rm -rf /home/root/xovi/exthome/qt-resource-rebuilder/zh_CN
    # 清理 xovi 扩展
    rm -f /home/root/xovi/extensions.d/librarian.so /home/root/xovi/extensions.d/xovi-message-broker.so
    # 清理中文翻译 qm
    mount -o remount,rw / 2>/dev/null || true
    rm -f /usr/share/remarkable/xochitl/translations/reMarkable_zh_CN.qm
    systemctl daemon-reload
    udevadm control --reload-rules 2>/dev/null || true
    echo '卸载完成'
  "
  exit 0
fi

# ─── 前置检查 ────────────────────────────────────────────────
echo "=== rmkit-cn 安装程序 ==="
echo ""
echo "请确认："
echo "  1. 已用 USB 线连接 reMarkable"
echo "  2. Settings → General → About → Copyrights 最底部可找到 SSH 密码"
echo ""
read -rp "按 Enter 继续，或 Ctrl+C 退出..."

for cmd in ssh scp; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "错误：需要 $cmd，请先安装" >&2
    exit 1
  fi
done

# ─── 连接并检测设备 ──────────────────────────────────────────
echo ""
echo "正在连接设备 $DEVICE_IP..."
ssh -o ConnectTimeout=10 "$DEVICE_USER@$DEVICE_IP" "echo '连接成功'" || {
  echo "错误：无法连接设备，请确认 USB 已连接且 SSH 已启用" >&2
  exit 1
}

ARCH=$(ssh "$DEVICE_USER@$DEVICE_IP" "uname -m")
FW_VERSION=$(ssh "$DEVICE_USER@$DEVICE_IP" "cat /etc/version 2>/dev/null | head -n 1 | tr -d '[:space:]'")
RESOLUTION=$(ssh "$DEVICE_USER@$DEVICE_IP" "cat /sys/class/graphics/fb0/virtual_size 2>/dev/null || echo 'unknown'" || echo "unknown")

echo "设备架构：$ARCH"
echo "固件版本：$FW_VERSION"
echo "屏幕分辨率：${RESOLUTION:-unknown}"
echo ""

RESOLUTION="${RESOLUTION:-unknown}"

case "$RESOLUTION" in
  "1404,1872") DEVICE_MODEL="reMarkable 2" ;;
  "2160,2880") DEVICE_MODEL="Paper Pro" ;;
  "1696,954")  DEVICE_MODEL="Paper Pro Move" ;;
  *)           DEVICE_MODEL="未知型号（${RESOLUTION:-未知}）" ;;
esac
echo "检测到设备：$DEVICE_MODEL"

# ─── 选架构对应二进制/扩展 ───────────────────────────────────
case "$ARCH" in
  aarch64)
    UPLOAD_BIN_NAME="upload-server-aarch64"
    IME_BIN_NAME="ime-server"
    IME_HOOK_NAME="ime_hook.so"
    EXT_ARCH="aarch64"             # vendor/extensions/*-aarch64.so
    XOVI_ARCH="aarch64"            # vendor/xovi/xovi-aarch64.tar.gz
    QMD_TOOL_NAME="qmd-tool-aarch64"
    ;;
  armv7l)
    UPLOAD_BIN_NAME="upload-server-armv7"
    IME_BIN_NAME="ime-server-armv7"
    IME_HOOK_NAME="ime_hook-armv7.so"
    EXT_ARCH="armv7"               # vendor/extensions/*-armv7.so
    XOVI_ARCH="arm32"              # vendor/xovi/xovi-arm32.tar.gz (xovi 上游用 arm32 命名)
    QMD_TOOL_NAME="qmd-tool-armv7"
    ;;
  *)
    echo "✗ 不支持的架构: $ARCH (本项目仅支持 aarch64 / armv7l)" >&2
    exit 1
    ;;
esac

# ─── 确保 dist/ 预编译产物可用 (clone 后 dist/ 为空时自动从 GitHub Release 下载) ──
# dist/ 在 .gitignore 里, 普通用户 git clone 后没有二进制。这里检测缺失并自动下载,
# 让用户无需本地 Go 工具链即可部署。开发者本地自行 build 时跳过下载 (文件已存在)。
DIST_DIR_CHECK="$SCRIPT_DIR/dist"
DIST_RELEASE_URL="${DIST_RELEASE_URL:-https://github.com/boangs/rmkit/releases/latest/download/dist.tar.gz}"
NEED_FILES=(
  "$DIST_DIR_CHECK/$UPLOAD_BIN_NAME"
  "$DIST_DIR_CHECK/$IME_BIN_NAME"
  "$DIST_DIR_CHECK/$IME_HOOK_NAME"
  "$DIST_DIR_CHECK/$QMD_TOOL_NAME"
  "$DIST_DIR_CHECK/reMarkable_zh_CN.qm"
  "$DIST_DIR_CHECK/zh_CN.rcc"
)
DIST_OK=1
for f in "${NEED_FILES[@]}"; do
  [ -f "$f" ] || { DIST_OK=0; break; }
done
if [ "$DIST_OK" = "0" ]; then
  echo ""
  echo "dist/ 预编译产物缺失, 从 GitHub Release 下载..."
  echo "  URL: $DIST_RELEASE_URL"
  mkdir -p "$DIST_DIR_CHECK"
  TMP_TGZ="$(mktemp -t rmkit-dist.XXXXXX.tgz)"
  trap 'rm -f "$TMP_TGZ"' EXIT
  if ! curl -fL --progress-bar -o "$TMP_TGZ" "$DIST_RELEASE_URL"; then
    echo "✗ 下载失败。可手动下载并解压到 dist/:" >&2
    echo "    curl -fL -o dist.tar.gz $DIST_RELEASE_URL" >&2
    echo "    tar -xzf dist.tar.gz -C dist/" >&2
    exit 1
  fi
  tar -xzf "$TMP_TGZ" -C "$DIST_DIR_CHECK"
  chmod +x "$DIST_DIR_CHECK"/* 2>/dev/null || true
  rm -f "$TMP_TGZ"; trap - EXIT
  echo "  ✓ 预编译产物已就绪"
fi

# ─── xovi 自动部署 (全新设备 / 出厂 reset 后必备) ──────────────
# install.sh 装的 .qmd 注入和 LD_PRELOAD 都依赖 /home/root/xovi/xovi.so 存在,
# 缺失时不能直接装 drop-in (xochitl crash → A/B 回滚)。先无条件确保 xovi 在位。
echo ""
echo "正在检查 xovi..."
HAVE_XOVI=$(ssh "$DEVICE_USER@$DEVICE_IP" "[ -f /home/root/xovi/xovi.so ] && echo yes || echo no")
if [ "$HAVE_XOVI" = "no" ]; then
  XOVI_TARBALL="$SCRIPT_DIR/vendor/xovi/xovi-${XOVI_ARCH}.tar.gz"
  XOVI_LAUNCHER="$SCRIPT_DIR/vendor/xovi/xochitl-xovi"
  if [ ! -f "$XOVI_TARBALL" ] || [ ! -f "$XOVI_LAUNCHER" ]; then
    echo "✗ 设备缺 xovi 但本地 vendor/xovi/ 不全, 无法自动部署" >&2
    echo "  需要: $XOVI_TARBALL 和 $XOVI_LAUNCHER" >&2
    exit 1
  fi
  echo "  设备无 xovi, 自动部署中..."
  scp -q "$XOVI_TARBALL" "$XOVI_LAUNCHER" "$DEVICE_USER@$DEVICE_IP:/tmp/"
  ssh "$DEVICE_USER@$DEVICE_IP" "set -e
    cd /home/root
    tar -xzf /tmp/xovi-${XOVI_ARCH}.tar.gz --no-same-owner --no-same-permissions
    cp /tmp/xochitl-xovi /home/root/xovi/xochitl-xovi
    chmod +x /home/root/xovi/xochitl-xovi
    chown -R root:root /home/root/xovi
    rm /tmp/xovi-${XOVI_ARCH}.tar.gz /tmp/xochitl-xovi
  "
  echo "  ✓ xovi 部署完成"
else
  echo "  ✓ xovi 已存在"
fi

# ─── 架构相关: zz-rmkit-cn.conf 和 systemd 安装方式 ─────────────
# rm2 (armv7l):
#   - /etc 不是 overlay (直接 ext4), 不需要 bind-mount 双写
#   - /home 在 xochitl 之后挂 (fstab x-systemd.after=xochitl), After=home.mount 会造成循环
#   - 用 xovi-reenable.service 在 home.mount 后 restart xochitl
# aarch64 (RMPP/RMPPM):
#   - /etc 是 overlay, 需要 bind-mount 双写
#   - /home 是 LUKS 加密, After=home.mount 安全且必要
case "$ARCH" in
  armv7l)
    # rm2: fstab 让 /home 在 xochitl.service 之后挂载 (x-systemd.after=xochitl.service)。
    # ConditionPathExists 检查 /home/root/.so 在冷启动时永远 fail → xochitl skip →
    # /home 不挂 → 死锁砖。所以 rm2 上**不能**用 ConditionPathExists 守卫。
    # 冷启动 LD_PRELOAD 的 .so 路径不存在时, glibc 行为是 warn + skip (memory feedback_xochitl_dropin_after_home)
    # → xochitl 默认启动(无 rmkit-cn 注入), /home 挂上来, 设备能用但 rmkit-cn 失效, 不砖。
    # 用户 ssh 后 restart xochitl 一次可恢复注入。
    ZZ_UNIT_HEADER="[Unit]"
    ;;
  aarch64)
    # rmpp/rmppm: 有 home.mount unit, After 让 xochitl 等 /home 挂好再启动。
    # ConditionPathExists 此时安全可用 (xovi 未装时不加 LD_PRELOAD 防砖)
    ZZ_UNIT_HEADER="[Unit]
After=home.mount
ConditionPathExists=/home/root/xovi/xovi.so
ConditionPathExists=/home/root/rmkit-cn/bin/ime_hook.so"
    ;;
esac

# ─── 同步设备 hashtab 并重新编译 qmd-src/*.qmd → dist/ ────────
# 必须每次部署前重编, 因为: ① qmd-src 是源, dist 是产物; ② 设备 hashtab 可能与本地不同步,
# 用过时 hashtab 编译会导致 identifier hash 不命中, 注入 silent skip, 高级面板/AI 等功能消失
# 注: 重编工具是 dist/qmd-tool (Go), 替代了原 tools/hash-qmd.py — 设备端 OTA 时同样
# 复用同一二进制, 0 Python 依赖.
QMD_SRC_DIR="$SCRIPT_DIR/qmd-src"
DIST_DIR="$SCRIPT_DIR/dist"
HASH_TOOL="$SCRIPT_DIR/dist/qmd-tool"
HASHTAB_LOCAL="$SCRIPT_DIR/tools/hashtab"

if [ -d "$QMD_SRC_DIR" ]; then
  if [ ! -x "$HASH_TOOL" ]; then
    echo "✗ 致命: $HASH_TOOL 不存在或不可执行" >&2
    echo "  跑一遍 'cd tools/qmd-tool && make build' 重编" >&2
    exit 1
  fi

  # tools/hashtab 不入 git (是工作副本), 缺失时从 tools/hashtabs/ 按架构选种子
  if [ ! -f "$HASHTAB_LOCAL" ]; then
    case "$ARCH" in
      aarch64) SEED_NAME="hashtab-rmpp-ferrari-3.26.0.68" ;;
      armv7l)  SEED_NAME="hashtab-rm2-3.26.0.68" ;;
      *)       SEED_NAME="" ;;
    esac
    if [ -n "$SEED_NAME" ] && [ -f "$SCRIPT_DIR/tools/hashtabs/$SEED_NAME" ]; then
      cp "$SCRIPT_DIR/tools/hashtabs/$SEED_NAME" "$HASHTAB_LOCAL"
      echo "tools/hashtab 缺失, 已用 hashtabs/$SEED_NAME 作种子初始化"
    fi
  fi

  echo ""
  echo "正在检查设备 hashtab..."
  REMOTE_HASHTAB=$(ssh "$DEVICE_USER@$DEVICE_IP" "ls -d /home/root/xovi/exthome/qt-resource-rebuilder*/hashtab 2>/dev/null | head -n 1" || true)
  NEED_RECOMPILE=true
  if [ -n "$REMOTE_HASHTAB" ]; then
    # 对比本地和远端 hashtab md5，相同则跳过重编
    REMOTE_MD5=$(ssh "$DEVICE_USER@$DEVICE_IP" "md5sum '$REMOTE_HASHTAB' 2>/dev/null | cut -d' ' -f1" || true)
    LOCAL_MD5=""
    [ -f "$HASHTAB_LOCAL" ] && LOCAL_MD5=$(md5sum "$HASHTAB_LOCAL" 2>/dev/null | cut -d' ' -f1 || true)
    if [ -n "$REMOTE_MD5" ] && [ "$REMOTE_MD5" = "$LOCAL_MD5" ]; then
      echo "  → hashtab 未变化，跳过重编 (使用缓存 dist/*.qmd)"
      NEED_RECOMPILE=false
    else
      scp -q "$DEVICE_USER@$DEVICE_IP:$REMOTE_HASHTAB" "$HASHTAB_LOCAL"
      echo "  → tools/hashtab 已同步设备版本 ($REMOTE_HASHTAB)"
    fi
  elif [ -f "$HASHTAB_LOCAL" ]; then
    echo "警告: 设备未找到 hashtab, 沿用本地 tools/hashtab (hash 可能不命中)"
  else
    echo "✗ 致命: tools/hashtab 不存在且未能从设备同步, 也无可用种子" >&2
    exit 1
  fi

  if [ "$NEED_RECOMPILE" = "true" ]; then
    echo "正在用 qmd-tool (Go) 重编 qmd-src/*.qmd..."
    mkdir -p "$DIST_DIR"
    for src in "$QMD_SRC_DIR"/*.qmd; do
      [ -f "$src" ] || continue
      base=$(basename "$src")
      out="$DIST_DIR/$base"
      if "$HASH_TOOL" hash -hashtab "$HASHTAB_LOCAL" "$src" > "$out.tmp"; then
        mv "$out.tmp" "$out"
        echo "  ✓ $base"
      else
        rm -f "$out.tmp"
        echo "  ✗ $base 编译失败" >&2
        exit 1
      fi
    done
  fi
fi

# ─── qmd 校验 ────────────────────────────────────────────────
# 历史 hash-qmd.py 失败时曾把 stderr 当 stdout 写入过 Python traceback 到 dist/*.qmd,
# 现在 qmd-tool (Go) 已经走 stderr 报错 + 非零退出码, 但保留 magic-byte 兜底校验.
qmd_is_valid() {
  local f="$1"
  [ -f "$f" ] || return 1
  [ "$(wc -c < "$f")" -gt 100 ] || return 1
  local head1
  head1=$(head -c 16 "$f" 2>/dev/null || true)
  case "$head1" in
    *Traceback*|*Error*|*FileNotFound*) return 1 ;;
  esac
  return 0
}
for qmd in advanced_panel.qmd language_zh_cn.qmd ai_text_button.qmd; do
  qmd_is_valid "$SCRIPT_DIR/dist/$qmd" || {
    echo "✗ dist/$qmd 校验失败 (空文件 / traceback / 损坏), 中止部署" >&2
    exit 1
  }
done

# ─── 校验所有需部署的 binary 在本地都存在 ───────────────────────
DIST_DIR="$SCRIPT_DIR/dist"
for f in "$DIST_DIR/$UPLOAD_BIN_NAME" "$DIST_DIR/$IME_BIN_NAME" "$DIST_DIR/$IME_HOOK_NAME" \
         "$DIST_DIR/$QMD_TOOL_NAME" \
         "$SCRIPT_DIR/vendor/extensions/librarian-${EXT_ARCH}.so" \
         "$SCRIPT_DIR/vendor/extensions/xovi-message-broker-${EXT_ARCH}.so"; do
  [ -f "$f" ] || { echo "✗ 缺失: $f" >&2; exit 1; }
done

# ─── 构造本地 staging (镜像设备文件树) ─────────────────────────
# 把所有要部署的文件复制到 staging 临时目录, 按设备真实路径组织,
# 然后整树 tar -c | ssh tar -x 一次过, 替代 56 次 scp.
echo ""
echo "正在构造部署 payload..."
PAYLOAD=$(mktemp -d -t rmkit-cn-payload.XXXXXX)
trap 'rm -rf "$PAYLOAD"' EXIT

mkdir -p \
  "$PAYLOAD/home/root/rmkit-cn/bin" \
  "$PAYLOAD/home/root/rmkit-cn/upload-server/static" \
  "$PAYLOAD/home/root/rmkit-cn/qmd/zh_CN" \
  "$PAYLOAD/home/root/rmkit-cn/qmd-src" \
  "$PAYLOAD/home/root/rmkit-cn/compiled-qmd/$FW_VERSION" \
  "$PAYLOAD/home/root/rmkit-cn/static" \
  "$PAYLOAD/home/root/xovi/exthome/qt-resource-rebuilder/chess" \
  "$PAYLOAD/home/root/xovi/extensions.d" \
  "$PAYLOAD/usr/share/remarkable/xochitl/translations" \
  "$PAYLOAD/tmp/rmkit-cn-systemd-staging"

# /home/root/rmkit-cn/bin/  Go binary + IME hook .so + version-switcher
# 注: scripts/apply-font.sh / apply-screen.sh 不再部署到设备 — 用户态字体
# 与屏幕已经由 upload-server web UI 接管, 这两个脚本只在仓库 scripts/ 留给
# 开发者本地引用 (设备上没人调用过它们).
cp "$SCRIPT_DIR/scripts/version-switcher.sh" "$PAYLOAD/home/root/rmkit-cn/bin/"
cp "$SCRIPT_DIR/installer/reenable.sh"    "$PAYLOAD/home/root/rmkit-cn/bin/reenable.sh"
cp "$SCRIPT_DIR/installer/fw-upgrade.sh"  "$PAYLOAD/home/root/rmkit-cn/bin/fw-upgrade.sh"
cp "$DIST_DIR/$IME_BIN_NAME"  "$PAYLOAD/home/root/rmkit-cn/bin/ime-server"
cp "$DIST_DIR/$IME_HOOK_NAME" "$PAYLOAD/home/root/rmkit-cn/bin/ime_hook.so"
cp "$DIST_DIR/$QMD_TOOL_NAME" "$PAYLOAD/home/root/rmkit-cn/bin/qmd-tool"
chmod +x "$PAYLOAD/home/root/rmkit-cn/bin/"*

# qmd-src/: fw-upgrade.sh 在 OTA 后从此重编
for qmd in "$QMD_SRC_DIR"/*.qmd; do
  [ -f "$qmd" ] || continue
  cp "$qmd" "$PAYLOAD/home/root/rmkit-cn/qmd-src/"
done

# 版本缓存：当前固件版本编译产物。reenable.sh 的 ExecStartPre 每次启动会:
#   rm -f $DEPLOY/*.qmd && cp $CACHE/*.qmd $DEPLOY/
# 所以**所有**需要持久注入的 .qmd 都必须在 cache 里, 漏了会被 silent 删 (历史 bug:
# 漏 pinyin_interceptor.qmd → 设备 restart 后没候选框)
for qmd in advanced_panel.qmd language_zh_cn.qmd ai_text_button.qmd glyph_selection_ai.qmd; do
  [ -f "$DIST_DIR/$qmd" ] && cp "$DIST_DIR/$qmd" "$PAYLOAD/home/root/rmkit-cn/compiled-qmd/$FW_VERSION/"
done
# pinyin_interceptor.qmd 不走 qmd-src 重编 (是预 hash 化的 qmd/ 成品), 但也必须进 cache
[ -f "$SCRIPT_DIR/qmd/pinyin_interceptor.qmd" ] && \
  cp "$SCRIPT_DIR/qmd/pinyin_interceptor.qmd" "$PAYLOAD/home/root/rmkit-cn/compiled-qmd/$FW_VERSION/"

# static/: fw-upgrade.sh 的 deploy_static() 读取这些静态资源
[ -f "$SCRIPT_DIR/qmd/pinyin_interceptor.qmd" ] && \
  cp "$SCRIPT_DIR/qmd/pinyin_interceptor.qmd" "$PAYLOAD/home/root/rmkit-cn/static/"
[ -f "$SCRIPT_DIR/qmd/zh_CN.rcc" ] && \
  cp "$SCRIPT_DIR/qmd/zh_CN.rcc" "$PAYLOAD/home/root/rmkit-cn/static/"
[ -f "$DIST_DIR/reMarkable_zh_CN.qm" ] && \
  cp "$DIST_DIR/reMarkable_zh_CN.qm" "$PAYLOAD/home/root/rmkit-cn/static/"

# /home/root/rmkit-cn/upload-server/  Go binary + 静态 web
cp "$DIST_DIR/$UPLOAD_BIN_NAME" "$PAYLOAD/home/root/rmkit-cn/upload-server/upload-server"
chmod +x "$PAYLOAD/home/root/rmkit-cn/upload-server/upload-server"
cp "$SCRIPT_DIR/upload-server-go/static/index.html" \
   "$SCRIPT_DIR/upload-server-go/static/qr.html" \
   "$PAYLOAD/home/root/rmkit-cn/upload-server/static/"

# /home/root/rmkit-cn/qmd/  rmkit 自身参考用的中间存储 (排除 _obsolete/)
[ -f "$SCRIPT_DIR/qmd/pinyin_interceptor.qmd" ] && \
  cp "$SCRIPT_DIR/qmd/pinyin_interceptor.qmd" "$PAYLOAD/home/root/rmkit-cn/qmd/"
[ -f "$SCRIPT_DIR/qmd/zh_CN.rcc" ] && \
  cp "$SCRIPT_DIR/qmd/zh_CN.rcc" "$PAYLOAD/home/root/rmkit-cn/qmd/"
[ -f "$SCRIPT_DIR/qmd/zh_CN/keyboard_layout.json" ] && \
  cp "$SCRIPT_DIR/qmd/zh_CN/keyboard_layout.json" "$PAYLOAD/home/root/rmkit-cn/qmd/zh_CN/"

# /home/root/xovi/exthome/qt-resource-rebuilder/  qmldiff 真正加载位置
for qmd in advanced_panel.qmd language_zh_cn.qmd ai_text_button.qmd; do
  cp "$DIST_DIR/$qmd" "$PAYLOAD/home/root/xovi/exthome/qt-resource-rebuilder/"
done
[ -f "$SCRIPT_DIR/qmd/pinyin_interceptor.qmd" ] && \
  cp "$SCRIPT_DIR/qmd/pinyin_interceptor.qmd" "$PAYLOAD/home/root/xovi/exthome/qt-resource-rebuilder/"
[ -f "$SCRIPT_DIR/qmd/zh_CN.rcc" ] && \
  cp "$SCRIPT_DIR/qmd/zh_CN.rcc" "$PAYLOAD/home/root/xovi/exthome/qt-resource-rebuilder/"

# 棋类资源 (assets/chess/*.svg + *.png)
if [ -d "$SCRIPT_DIR/assets/chess" ]; then
  cp "$SCRIPT_DIR/assets/chess/"*.svg "$SCRIPT_DIR/assets/chess/"*.png \
     "$PAYLOAD/home/root/xovi/exthome/qt-resource-rebuilder/chess/" 2>/dev/null || true
fi

# /home/root/xovi/extensions.d/  librarian + xovi-message-broker
cp "$SCRIPT_DIR/vendor/extensions/librarian-${EXT_ARCH}.so" \
   "$PAYLOAD/home/root/xovi/extensions.d/librarian.so"
cp "$SCRIPT_DIR/vendor/extensions/xovi-message-broker-${EXT_ARCH}.so" \
   "$PAYLOAD/home/root/xovi/extensions.d/xovi-message-broker.so"
chmod +x "$PAYLOAD/home/root/xovi/extensions.d/"*.so

# /usr/share/remarkable/xochitl/translations/  中文 qm
[ -f "$DIST_DIR/reMarkable_zh_CN.qm" ] && \
  cp "$DIST_DIR/reMarkable_zh_CN.qm" "$PAYLOAD/usr/share/remarkable/xochitl/translations/"

# /tmp/rmkit-cn-systemd-staging/  systemd unit + xochitl drop-in
# (不直接放到 /etc, 因为 /etc 是 overlayfs, 必须设备端 bind-mount 双写)
for f in "$SCRIPT_DIR"/systemd/*.service "$SCRIPT_DIR"/systemd/*.path; do
  [ -f "$f" ] || continue
  cp "$f" "$PAYLOAD/tmp/rmkit-cn-systemd-staging/"
done
[ -f "$SCRIPT_DIR/systemd/zz-rmkit-cn.conf" ] && \
  cp "$SCRIPT_DIR/systemd/zz-rmkit-cn.conf" "$PAYLOAD/tmp/rmkit-cn-systemd-staging/"

PAYLOAD_SIZE=$(du -sh "$PAYLOAD" | awk '{print $1}')
echo "  payload 总量: $PAYLOAD_SIZE  $(find "$PAYLOAD" -type f | wc -l | tr -d ' ') 文件"

# ─── 单次流式传输 (本地 tar -c | ssh "tar -x") ────────────────
echo ""
echo "正在传输 (gzip 流式, 单次 SSH)..."
START_TS=$(date +%s)
tar -czf - --uid 0 --gid 0 -C "$PAYLOAD" . | ssh "$DEVICE_USER@$DEVICE_IP" '
  set -e
  mount -o remount,rw / 2>/dev/null || true
  mkdir -p /home/root/.local/share/rmkit-cn/fonts \
           /home/root/.local/share/rmkit-cn/screens \
           /home/root/.local/share/fonts \
           /usr/share/remarkable/xochitl/translations \
           /home/root/xovi/exthome/qt-resource-rebuilder
  # --no-same-owner 防止 tar 把 macOS 端打包时的 uid (xurx=502) 还原到设备文件,
  # 否则 /home/root owner 被改成 502 导致 sshd PAM/xochitl home 访问全卡死, 设备砖机
  cd / && tar -xzf - --no-same-owner --no-same-permissions
  # 兜底: 强制把 /home/root 整树 owner 设回 root, 防御任何残留 502
  chown -R root:root /home/root
  chmod 755 /home/root
  [ -d /home/root/.ssh ] && chmod 700 /home/root/.ssh
  [ -f /home/root/.ssh/authorized_keys ] && chmod 600 /home/root/.ssh/authorized_keys
'
ELAPSED=$(( $(date +%s) - START_TS ))
echo "  传输完成 (${ELAPSED}s)"

# 关键: 必须在 reenable.sh 之前写 .last_fw_version!
# reenable.sh 末尾会 nohup 后台启动 fw-upgrade.sh, 后者读 .last_fw_version 判断是否重编 hashtab。
# 如果文件不存在或值过旧, fw-upgrade.sh 会启动一个临时 LD_PRELOAD xochitl 写 hashtab,
# 跟主 xochitl 进程或 systemctl restart xochitl 冲突, 反复 fail → bootloader 切 slot → 砖。
ssh "$DEVICE_USER@$DEVICE_IP" "printf '%s' '$FW_VERSION' > /home/root/rmkit-cn/.last_fw_version"
echo "✓ .last_fw_version 已写入 ($FW_VERSION) — 防止 fw-upgrade.sh 误触发"

# ─── 设备端: 6 阶段防砖部署 (2026-05-14 重写, 砖机预防) ───────────────
# 设计原则: xochitl 保持出厂状态直到所有 hash 都验证命中, 任何中间步骤失败都不影响默认启动
#
# 阶段顺序:
#   1) 装 systemd unit (rmkit-cn-upload/ime-http) — 不依赖 xochitl
#   2) 清旧 .qmd → 生成 hashtab (强制版本匹配 /etc/version) → 写版本标记
#   3) 用新 hashtab 编译 .qmd
#   4) 验证: 所有 .qmd 编译成功 (hash 命中) — 否则 exit 1, 不写 drop-in
#   5) 写最终 drop-in (含 ime_hook + zh_CN.rcc) — 必须在验证通过后!
#   6) 启动 services + start xochitl (此时 drop-in 第一次生效, 安全)
#
# 历史砖机教训 (2026-05-13 rm2):
#   - 旧 install.sh 在阶段 4b 装"最小 drop-in", 阶段 4c hashtab 跳过条件不查版本
#   - OTA 后旧 hashtab 还在, install.sh 跳过 hashtab 重生, 用旧 hashtab 编译 .qmd
#   - xochitl 加载新固件 + 旧 hashtab → qt-resource-rebuilder skip → Cached 0 entries → panic
#   - 砖机.

echo ""
echo "正在配置系统服务 + 编译 + 启动..."
# 把 ZZ_UNIT_HEADER 展平到单一字符串 (用 \n 字面表示换行), 设备端 printf %b 还原
ZZ_HEADER_FLAT="$(printf '%s' "$ZZ_UNIT_HEADER" | awk 'BEGIN{ORS="\\n"} {print}' | sed 's/\\n$//')"
ssh "$DEVICE_USER@$DEVICE_IP" "FW_VERSION='$FW_VERSION' ZZ_HEADER_FLAT='$ZZ_HEADER_FLAT' bash -s" <<'REMOTE_EOF'
set -e

HASHTAB=/home/root/xovi/exthome/qt-resource-rebuilder/hashtab
HASHTAB_FW=/home/root/xovi/exthome/qt-resource-rebuilder/hashtab.fw_version
DEPLOY=/home/root/xovi/exthome/qt-resource-rebuilder
QMD_TOOL=/home/root/rmkit-cn/bin/qmd-tool
QMD_SRC=/home/root/rmkit-cn/qmd-src
RMKIT_DIR=/home/root/rmkit-cn
DROPIN=/etc/systemd/system/xochitl.service.d/zz-rmkit-cn.conf

# 失败时回退: 删除任何已写入的 drop-in, 让 xochitl 走出厂默认启动
abort_safe() {
  local reason="$1"
  echo "  ✗ $reason"
  echo "  → 回退: 删除 drop-in (如有), 让 xochitl 走出厂默认"
  rm -f $DROPIN
  mkdir -p /tmp/lc && mount --bind / /tmp/lc 2>/dev/null || true
  mount -o remount,rw /tmp/lc 2>/dev/null || true
  rm -f /tmp/lc$DROPIN
  sync; umount -l /tmp/lc 2>/dev/null || true; rmdir /tmp/lc 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  systemctl start xochitl.service 2>/dev/null || true  # 保证 xochitl 默认起来
  exit 1
}

# ───── 阶段 1: 装 systemd .service unit (双写 + wants symlink 双写) ─────
echo "  → 阶段 1/6: 装 systemd service units..."
mkdir -p /tmp/lc && mount --bind / /tmp/lc 2>/dev/null || true
mount -o remount,rw /tmp/lc 2>/dev/null || true
mkdir -p /etc/systemd/system /tmp/lc/etc/systemd/system
mkdir -p /etc/systemd/system/multi-user.target.wants /tmp/lc/etc/systemd/system/multi-user.target.wants
for f in /tmp/rmkit-cn-systemd-staging/*.service /tmp/rmkit-cn-systemd-staging/*.path; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  cp "$f" /etc/systemd/system/$base; chmod 644 /etc/systemd/system/$base
  cp "$f" /tmp/lc/etc/systemd/system/$base; chmod 644 /tmp/lc/etc/systemd/system/$base
  case "$base" in
    rmkit-cn-upload.service|rmkit-cn-ime-http.service|rmkit-cn-version.path)
      ln -sf /etc/systemd/system/$base /etc/systemd/system/multi-user.target.wants/$base
      ln -sf /etc/systemd/system/$base /tmp/lc/etc/systemd/system/multi-user.target.wants/$base
      ;;
  esac
done
sync; umount -l /tmp/lc 2>/dev/null || true; rmdir /tmp/lc 2>/dev/null || true
systemctl daemon-reload

# ───── 阶段 2: 清旧 .qmd + 生成 hashtab (版本必须匹配 /etc/version) ─────
echo "  → 阶段 2/6: hashtab (固件 $FW_VERSION)..."

# 强制清空 $DEPLOY 旧 .qmd! 否则临时 xochitl 加载它们时,
# 旧 .qmd hash 跟新 hashtab 不匹配 → qmldiff Rust panic → 临时 xochitl 死 → hashtab 没写出
echo "    清空旧 .qmd (避免临时 xochitl 加载旧 hash 时 panic)..."
mkdir -p $DEPLOY
rm -f $DEPLOY/*.qmd $DEPLOY/*.rcc

# 判断是否需要重生 hashtab
NEEDS_REGEN=0
REGEN_REASON=""
if [ ! -f "$HASHTAB" ]; then
  NEEDS_REGEN=1; REGEN_REASON="hashtab 不存在"
elif [ "$(wc -c < $HASHTAB)" -lt 100000 ]; then
  NEEDS_REGEN=1; REGEN_REASON="hashtab 损坏 (<100KB)"
elif [ ! -f "$HASHTAB_FW" ]; then
  NEEDS_REGEN=1; REGEN_REASON="hashtab 缺版本标记 (老版本残留)"
elif [ "$(cat $HASHTAB_FW 2>/dev/null)" != "$FW_VERSION" ]; then
  NEEDS_REGEN=1; REGEN_REASON="hashtab 版本 $(cat $HASHTAB_FW 2>/dev/null) ≠ 固件 $FW_VERSION (OTA 升级了)"
fi

if [ $NEEDS_REGEN -eq 1 ]; then
  echo "    → 重生 hashtab (原因: $REGEN_REASON)"
  systemctl stop xochitl.service 2>/dev/null || true
  sleep 1
  pidof xochitl >/dev/null 2>&1 && kill -15 $(pidof xochitl) 2>/dev/null || true
  sleep 2
  rm -f $HASHTAB $HASHTAB_FW
  # 临时 xochitl 跑 LD_PRELOAD=xovi.so + QMLDIFF_HASHTAB_CREATE, qt-resource-rebuilder 会写 hashtab
  # 此时 $DEPLOY 里已经没有 .qmd, 不会 panic
  QMLDIFF_HASHTAB_CREATE=$HASHTAB QML_DISABLE_DISK_CACHE=1 \
    LD_PRELOAD=/home/root/xovi/xovi.so /usr/bin/xochitl > /tmp/hashtab_gen.log 2>&1 &
  XPID=$!
  for i in $(seq 1 90); do
    if [ -f "$HASHTAB" ] && [ "$(wc -c < $HASHTAB)" -gt 100000 ]; then
      sleep 2; break
    fi
    sleep 1
  done
  kill -15 $XPID 2>/dev/null || true; sleep 3; kill -9 $XPID 2>/dev/null || true
  if [ ! -f "$HASHTAB" ] || [ "$(wc -c < $HASHTAB)" -lt 100000 ]; then
    abort_safe "hashtab 生成失败! 看 /tmp/hashtab_gen.log"
  fi
  # 写版本标记 — 关键! 这是下次跑 install.sh 判断 hashtab 是否过期的依据
  echo "$FW_VERSION" > $HASHTAB_FW
  echo "    ✓ hashtab ($(wc -c < $HASHTAB) bytes, 标记固件版本 $FW_VERSION)"
else
  echo "    → hashtab 已存在且版本匹配 ($(wc -c < $HASHTAB) bytes, 固件 $FW_VERSION)"
fi

# ───── 阶段 3: 用新 hashtab 编译 .qmd → inject 目录 + cache ─────
echo "  → 阶段 3/6: 编译 .qmd..."
CACHE=$RMKIT_DIR/compiled-qmd/$FW_VERSION
mkdir -p $CACHE
COMPILE_FAILED=0
COMPILED=0
for src in $QMD_SRC/*.qmd; do
  [ -f "$src" ] || continue
  base=$(basename $src)
  if $QMD_TOOL hash -hashtab $HASHTAB $src > $DEPLOY/$base 2>/tmp/qmd-$base.err; then
    cp $DEPLOY/$base $CACHE/$base
    COMPILED=$((COMPILED+1))
    echo "    ✓ $base ($(wc -c < $DEPLOY/$base) bytes)"
  else
    rm -f $DEPLOY/$base
    COMPILE_FAILED=$((COMPILE_FAILED+1))
    echo "    ✗ $base 编译失败:"
    head -n 3 /tmp/qmd-$base.err 2>/dev/null | sed 's/^/        /'
  fi
done
# 静态资源
[ -f $RMKIT_DIR/static/pinyin_interceptor.qmd ] && cp $RMKIT_DIR/static/pinyin_interceptor.qmd $DEPLOY/
[ -f $RMKIT_DIR/static/zh_CN.rcc ] && cp $RMKIT_DIR/static/zh_CN.rcc $DEPLOY/

# ───── 阶段 4: 验证 — 编译失败计数为 0 才能继续 ─────
echo "  → 阶段 4/6: 验证 .qmd hash 命中..."
if [ $COMPILE_FAILED -gt 0 ]; then
  abort_safe "$COMPILE_FAILED 个 .qmd 编译失败 (hash 不命中), 拒绝写 drop-in"
fi
if [ $COMPILED -eq 0 ]; then
  abort_safe "没有任何 .qmd 编译成功 ($QMD_SRC 是空的?)"
fi
echo "    ✓ $COMPILED 个 .qmd 全部 hash 命中"

# ───── 阶段 5: 写最终 drop-in (验证通过后才写, 含 ime_hook + zh_CN.rcc) ─────
echo "  → 阶段 5/6: 写最终 drop-in..."
mkdir -p /etc/systemd/system/xochitl.service.d
mkdir -p /tmp/lc && mount --bind / /tmp/lc
mount -o remount,rw /tmp/lc
mkdir -p /tmp/lc/etc/systemd/system/xochitl.service.d
cat > /tmp/zz-rmkit-cn-final.conf <<EOF
$(printf '%b' "$ZZ_HEADER_FLAT")

[Service]
WatchdogSec=0
Environment="QML_DISABLE_DISK_CACHE=1"
Environment="QML_XHR_ALLOW_FILE_WRITE=1"
Environment="QML_XHR_ALLOW_FILE_READ=1"
Environment="LD_PRELOAD=/home/root/xovi/xovi.so:/home/root/rmkit-cn/bin/ime_hook.so"
Environment="QT_RESOURCE_REBUILDER_PATH=/home/root/xovi/exthome/qt-resource-rebuilder/zh_CN.rcc"
EOF
cp /tmp/zz-rmkit-cn-final.conf $DROPIN
cp /tmp/zz-rmkit-cn-final.conf /tmp/lc$DROPIN
chmod 644 $DROPIN /tmp/lc$DROPIN
sync; umount -l /tmp/lc 2>/dev/null || true; rmdir /tmp/lc 2>/dev/null || true
rm -f /tmp/zz-rmkit-cn-final.conf
systemctl daemon-reload
echo "    ✓ drop-in 写入 (tmpfs + ext4 lower 双写持久化)"

# ───── 阶段 6: 启动 services + xochitl ─────
echo "  → 阶段 6/6: 启动服务..."
systemctl start rmkit-cn-upload.service rmkit-cn-ime-http.service 2>/dev/null || true
[ -f /etc/systemd/system/rmkit-cn-version.path ] && systemctl start rmkit-cn-version.path 2>/dev/null || true

# 阶段 2 stop 了 xochitl, 现在 start (drop-in 首次生效)
# 如果阶段 2 没 stop (hashtab 跳过), xochitl 在跑出厂版本, 这里 restart 让 drop-in 生效
echo "    → start xochitl (drop-in 首次生效)..."
if pidof xochitl >/dev/null 2>&1; then
  systemctl restart xochitl.service
else
  systemctl start xochitl.service
fi
sleep 5
# 安全验证: xochitl 必须真的活着, 否则立即回退删 drop-in
# (start-limit 锁死之前抓住 → 避免冷启动 ConditionPathExists 死锁)
XPID=$(pidof xochitl 2>/dev/null)
if [ -z "$XPID" ]; then
  echo "    ✗ xochitl 没启动起来! 立即回退..."
  echo "    journal 倒数 20 行:"
  journalctl -u xochitl.service --no-pager -n 20 2>&1 | sed 's/^/      /' || true
  abort_safe "xochitl 启动失败 (.qmd 验证通过但运行时 panic? 看 journal)"
fi
# 再等 5 秒确认稳定 (避免起来又 crash)
sleep 5
XPID2=$(pidof xochitl 2>/dev/null)
if [ -z "$XPID2" ] || [ "$XPID" != "$XPID2" ]; then
  echo "    ✗ xochitl 起来但很快 crash/重启 (PID $XPID → $XPID2)!"
  journalctl -u xochitl.service --no-pager -n 30 2>&1 | sed 's/^/      /' || true
  abort_safe "xochitl crash loop"
fi
echo "    ✓ xochitl (PID $XPID, 稳定 10 秒) — xovi: $(grep -c xovi /proc/$XPID/maps 2>/dev/null), ime_hook: $(grep -c ime_hook /proc/$XPID/maps 2>/dev/null)"

rm -rf /tmp/rmkit-cn-systemd-staging
echo "  ✓ 部署完成"
REMOTE_EOF

# ─── 完成 ─────────────────────────────────────────────────────
WIFI_IP=$(ssh "$DEVICE_USER@$DEVICE_IP" "ip route get 8.8.8.8 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print \$2}'" 2>/dev/null || echo "")

echo ""
echo "✓ rmkit-cn 安装完成！"
echo ""
echo "访问管理界面："
echo "  USB:  http://10.11.99.1:8080"
[ -n "$WIFI_IP" ] && echo "  WiFi: http://$WIFI_IP:8080"
