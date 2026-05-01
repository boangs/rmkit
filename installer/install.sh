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
    systemctl stop rmkit-cn-upload.service rmkit-cn-version.path rmkit-cn-ime.service rmkit-cn-ime-udev.service rmkit-cn-ime-http.service 2>/dev/null || true
    systemctl disable rmkit-cn-upload.service rmkit-cn-version.path rmkit-cn-ime.service rmkit-cn-ime-udev.service rmkit-cn-ime-http.service 2>/dev/null || true
    rm -rf $REMOTE_BASE
    rm -f /etc/systemd/system/rmkit-cn-*.service /etc/systemd/system/rmkit-cn-*.path
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
FW_VERSION=$(ssh "$DEVICE_USER@$DEVICE_IP" "cat /etc/version | grep -oE '^[0-9]+' | head -n 1")
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

# ─── 创建远端目录 ─────────────────────────────────────────────
echo ""
echo "正在创建目录结构..."
ssh "$DEVICE_USER@$DEVICE_IP" "
  mkdir -p $REMOTE_BASE/{qmd,bin,upload-server/static}
  mkdir -p /home/root/.local/share/rmkit-cn/{fonts,screens}
  mkdir -p /home/root/.local/share/fonts
  mkdir -p /home/root/xovi/exthome/qt-resource-rebuilder
  # 迁移旧的 ime 二进制到 bin/
  if [ -f $REMOTE_BASE/ime ] && [ ! -d $REMOTE_BASE/ime ]; then
    mv $REMOTE_BASE/ime $REMOTE_BASE/bin/ime 2>/dev/null || true
  fi
"

# ─── 部署文件 ─────────────────────────────────────────────────
echo "正在部署脚本..."
scp "$SCRIPT_DIR/scripts/apply-font.sh" "$DEVICE_USER@$DEVICE_IP:$REMOTE_BASE/bin/"
scp "$SCRIPT_DIR/scripts/apply-screen.sh" "$DEVICE_USER@$DEVICE_IP:$REMOTE_BASE/bin/"
scp "$SCRIPT_DIR/scripts/version-switcher.sh" "$DEVICE_USER@$DEVICE_IP:$REMOTE_BASE/bin/"
ssh "$DEVICE_USER@$DEVICE_IP" "chmod +x $REMOTE_BASE/bin/*.sh"

echo "正在部署上传服务 (Go 二进制)..."
case "$ARCH" in
  aarch64) UPLOAD_BIN="upload-server-aarch64" ;;
  armv7l)  UPLOAD_BIN="upload-server-armv7" ;;
  *)
    UPLOAD_BIN=""
    echo "警告: 架构 $ARCH 无对应 upload-server Go 二进制"
    ;;
esac
if [ -n "$UPLOAD_BIN" ] && [ -f "$SCRIPT_DIR/dist/$UPLOAD_BIN" ]; then
  scp "$SCRIPT_DIR/dist/$UPLOAD_BIN" "$DEVICE_USER@$DEVICE_IP:$REMOTE_BASE/upload-server/upload-server"
  ssh "$DEVICE_USER@$DEVICE_IP" "chmod +x $REMOTE_BASE/upload-server/upload-server"
fi
# static 直接从 upload-server-go/static/ 走 (这是工程师改的源, 历史 dist/upload-server-static/ 不会自动同步导致漂移)
scp "$SCRIPT_DIR/upload-server-go/static/index.html" "$DEVICE_USER@$DEVICE_IP:$REMOTE_BASE/upload-server/static/"
scp "$SCRIPT_DIR/upload-server-go/static/qr.html" "$DEVICE_USER@$DEVICE_IP:$REMOTE_BASE/upload-server/static/"

# 部署 QMD 资源到 $REMOTE_BASE/qmd/ 中间存储 (排除 _obsolete/ 历史孤儿文件, 避免污染部署链)
if [ -d "$SCRIPT_DIR/qmd" ]; then
  echo "正在部署 QMD 资源..."
  ssh "$DEVICE_USER@$DEVICE_IP" "mkdir -p $REMOTE_BASE/qmd"
  for f in "$SCRIPT_DIR/qmd"/*.qmd "$SCRIPT_DIR/qmd"/*.rcc; do
    [ -f "$f" ] || continue
    scp "$f" "$DEVICE_USER@$DEVICE_IP:$REMOTE_BASE/qmd/"
  done
  if [ -d "$SCRIPT_DIR/qmd/zh_CN" ]; then
    scp -r "$SCRIPT_DIR/qmd/zh_CN" "$DEVICE_USER@$DEVICE_IP:$REMOTE_BASE/qmd/"
  fi
fi

# ─── 部署 Go IME HTTP 服务 ────────────────────────────────────
case "$ARCH" in
  aarch64) IME_BIN="$SCRIPT_DIR/dist/ime-server" ;;
  armv7l)  IME_BIN="$SCRIPT_DIR/dist/ime-server-armv7" ;;
  *)       IME_BIN="" ; echo "警告: 架构 $ARCH 无对应 ime-server 二进制" ;;
esac
if [ -n "$IME_BIN" ] && [ -f "$IME_BIN" ]; then
  echo "正在部署 Go 拼音输入法服务 ($(basename "$IME_BIN"))..."
  ssh "$DEVICE_USER@$DEVICE_IP" "systemctl stop rmkit-cn-ime-http 2>/dev/null || true; rm -f $REMOTE_BASE/bin/ime-server"
  scp "$IME_BIN" "$DEVICE_USER@$DEVICE_IP:$REMOTE_BASE/bin/ime-server"
  ssh "$DEVICE_USER@$DEVICE_IP" "chmod +x $REMOTE_BASE/bin/ime-server"
fi

# 部署 ime_hook.so (xochitl LD_PRELOAD 注入, 拦截输入框聚焦事件)
case "$ARCH" in
  aarch64) IME_HOOK="$SCRIPT_DIR/dist/ime_hook.so" ;;
  armv7l)  IME_HOOK="$SCRIPT_DIR/dist/ime_hook-armv7.so" ;;
  *)       IME_HOOK="" ;;
esac
if [ -n "$IME_HOOK" ] && [ -f "$IME_HOOK" ]; then
  echo "正在部署 IME hook ($(basename "$IME_HOOK"))..."
  scp "$IME_HOOK" "$DEVICE_USER@$DEVICE_IP:$REMOTE_BASE/bin/ime_hook.so"
  ssh "$DEVICE_USER@$DEVICE_IP" "chmod +x $REMOTE_BASE/bin/ime_hook.so"
fi

# ─── 同步设备 hashtab 并重新编译 qmd-src/*.qmd → dist/ ────────
# 必须每次部署前重编, 因为: ① qmd-src 是源, dist 是产物; ② 设备 hashtab 可能与本地不同步,
# 用过时 hashtab 编译会导致 identifier hash 不命中, 注入 silent skip, 高级面板/AI 等功能消失
QMD_SRC_DIR="$SCRIPT_DIR/qmd-src"
DIST_DIR="$SCRIPT_DIR/dist"
HASH_TOOL="$SCRIPT_DIR/tools/hash-qmd.py"
HASHTAB_LOCAL="$SCRIPT_DIR/tools/hashtab"

if [ -d "$QMD_SRC_DIR" ] && [ -f "$HASH_TOOL" ]; then
  if ! command -v python3 &>/dev/null; then
    echo "警告: 未找到 python3, 跳过 .qmd 重编, 直接用 dist/ 现有版本 (可能过时)"
  else
    echo ""
    echo "正在同步设备 hashtab..."
    REMOTE_HASHTAB=$(ssh "$DEVICE_USER@$DEVICE_IP" "ls -d /home/root/xovi/exthome/qt-resource-rebuilder*/hashtab 2>/dev/null | head -n 1" || true)
    if [ -n "$REMOTE_HASHTAB" ]; then
      cp "$HASHTAB_LOCAL" "$HASHTAB_LOCAL.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
      scp -q "$DEVICE_USER@$DEVICE_IP:$REMOTE_HASHTAB" "$HASHTAB_LOCAL"
      echo "  → tools/hashtab 已同步设备版本 ($REMOTE_HASHTAB)"
    else
      echo "警告: 设备未找到 hashtab, 沿用本地 tools/hashtab (hash 可能不命中)"
    fi

    echo "正在用 hash-qmd.py 重编 qmd-src/*.qmd..."
    mkdir -p "$DIST_DIR"
    for src in "$QMD_SRC_DIR"/*.qmd; do
      [ -f "$src" ] || continue
      base=$(basename "$src")
      out="$DIST_DIR/$base"
      if python3 "$HASH_TOOL" "$src" > "$out.tmp"; then
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

# 部署 Advanced 面板 & 系统语言汉化 & AI 文字工具栏 QMD (dist 里是已哈希版本)
# 预检: hash-qmd.py 历史失败时把 stderr 当 stdout 写入过 traceback 当 .qmd, 部署前必须验
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
  if qmd_is_valid "$SCRIPT_DIR/dist/$qmd"; then
    scp "$SCRIPT_DIR/dist/$qmd" "$DEVICE_USER@$DEVICE_IP:/home/root/xovi/exthome/qt-resource-rebuilder/"
  else
    echo "✗ dist/$qmd 校验失败 (空文件 / traceback / 损坏), 中止部署" >&2
    exit 1
  fi
done

# 部署拼音 IME 拦截 qmd (qmd/ 是源, 不经 dist 编译, hash 已对齐当前 hashtab)
if [ -f "$SCRIPT_DIR/qmd/pinyin_interceptor.qmd" ]; then
  scp "$SCRIPT_DIR/qmd/pinyin_interceptor.qmd" "$DEVICE_USER@$DEVICE_IP:/home/root/xovi/exthome/qt-resource-rebuilder/"
fi

# 部署中文键盘布局 RCC
if [ -f "$SCRIPT_DIR/qmd/zh_CN.rcc" ]; then
  scp "$SCRIPT_DIR/qmd/zh_CN.rcc" "$DEVICE_USER@$DEVICE_IP:/home/root/xovi/exthome/qt-resource-rebuilder/"
fi

# 部署高级面板游戏图标 (advanced_panel.qmd 用 file:// 加载) + AI/链接 SVG + 华容道棋子 PNG
# 资产源在 assets/chess/ (svg/png 是手画/收集来的, 不是构建产物)
if [ -d "$SCRIPT_DIR/assets/chess" ]; then
  ssh "$DEVICE_USER@$DEVICE_IP" "mkdir -p /home/root/xovi/exthome/qt-resource-rebuilder/chess"
  scp "$SCRIPT_DIR/assets/chess/"*.svg "$SCRIPT_DIR/assets/chess/"*.png "$DEVICE_USER@$DEVICE_IP:/home/root/xovi/exthome/qt-resource-rebuilder/chess/"
fi

# ─── 部署 xovi-message-broker + librarian (供扫码上传热导入文档用) ─
case "$ARCH" in
  aarch64) EXT_ARCH="aarch64" ;;
  armv7l)  EXT_ARCH="armv7" ;;
  *)
    EXT_ARCH=""
    echo "警告: 架构 $ARCH 无对应 xovi 扩展, 跳过 librarian/xovi-mb"
    ;;
esac

if [ -n "$EXT_ARCH" ]; then
  echo "正在部署 xovi 扩展 (xovi-message-broker, librarian; $EXT_ARCH)..."
  ssh "$DEVICE_USER@$DEVICE_IP" "mkdir -p /home/root/xovi/extensions.d"
  for ext in xovi-message-broker librarian; do
    src="$SCRIPT_DIR/vendor/extensions/${ext}-${EXT_ARCH}.so"
    if [ -f "$src" ]; then
      scp "$src" "$DEVICE_USER@$DEVICE_IP:/home/root/xovi/extensions.d/${ext}.so"
      ssh "$DEVICE_USER@$DEVICE_IP" "chmod +x /home/root/xovi/extensions.d/${ext}.so"
    else
      echo "警告: $src 不存在, 跳过 $ext"
    fi
  done
fi

# 部署中文系统翻译 qm
if [ -f "$SCRIPT_DIR/dist/reMarkable_zh_CN.qm" ]; then
  echo "正在部署中文翻译 qm..."
  ssh "$DEVICE_USER@$DEVICE_IP" 'mount -o remount,rw / && mkdir -p /usr/share/remarkable/xochitl/translations'
  scp "$SCRIPT_DIR/dist/reMarkable_zh_CN.qm" "$DEVICE_USER@$DEVICE_IP:/usr/share/remarkable/xochitl/translations/"
fi

# 部署旧版 Python IME（如果存在，向后兼容）
if [ -d "$SCRIPT_DIR/ime" ] && find "$SCRIPT_DIR/ime" -maxdepth 1 -name "*.py" -print -quit 2>/dev/null | grep -q .; then
  echo "正在部署旧版输入法..."
  ssh "$DEVICE_USER@$DEVICE_IP" "mkdir -p $REMOTE_BASE/ime/dict"
  scp "$SCRIPT_DIR/ime/pinyin.py" "$SCRIPT_DIR/ime/keyboard.py" "$SCRIPT_DIR/ime/injector.py" "$SCRIPT_DIR/ime/overlay.py" "$SCRIPT_DIR/ime/main.py" "$SCRIPT_DIR/ime/build_dict.py" "$DEVICE_USER@$DEVICE_IP:$REMOTE_BASE/ime/"
  scp "$SCRIPT_DIR/ime/dict/chars.json" "$DEVICE_USER@$DEVICE_IP:$REMOTE_BASE/ime/dict/" 2>/dev/null || true
fi

# ─── 部署 systemd 服务 ────────────────────────────────────────
# /etc 是 overlayfs (lowerdir=ext4 ro, upperdir=tmpfs), 直接 scp 到 /etc 只落 tmpfs upperdir, 重启全丢。
# 必须 bind-mount / 暴露真 lowerdir 写一份持久, 同时 overlay upperdir 也写一份立即可见。
echo "正在配置系统服务 (bind-mount 双写: lowerdir 持久 + upperdir 立即可见)..."
ssh "$DEVICE_USER@$DEVICE_IP" "mkdir -p /tmp/rmkit-cn-systemd-staging"
scp "$SCRIPT_DIR/systemd/rmkit-cn-upload.service" "$DEVICE_USER@$DEVICE_IP:/tmp/rmkit-cn-systemd-staging/"
scp "$SCRIPT_DIR/systemd/rmkit-cn-version.path" "$DEVICE_USER@$DEVICE_IP:/tmp/rmkit-cn-systemd-staging/"
scp "$SCRIPT_DIR/systemd/rmkit-cn-version.service" "$DEVICE_USER@$DEVICE_IP:/tmp/rmkit-cn-systemd-staging/"
for unit in rmkit-cn-ime-http.service rmkit-cn-ime.service rmkit-cn-ime-udev.service; do
  if [ -f "$SCRIPT_DIR/systemd/$unit" ]; then
    scp "$SCRIPT_DIR/systemd/$unit" "$DEVICE_USER@$DEVICE_IP:/tmp/rmkit-cn-systemd-staging/"
  fi
done
if [ -f "$SCRIPT_DIR/systemd/99-rmkit-cn-ime.rules" ]; then
  scp "$SCRIPT_DIR/systemd/99-rmkit-cn-ime.rules" "$DEVICE_USER@$DEVICE_IP:/tmp/rmkit-cn-systemd-staging/"
fi

ssh "$DEVICE_USER@$DEVICE_IP" "
  set -e
  STAGE=/tmp/rmkit-cn-systemd-staging
  MNT=/tmp/rmkit-cn-rootfs
  mkdir -p \$MNT
  mount --bind / \$MNT
  trap 'umount \$MNT 2>/dev/null || true; rmdir \$MNT 2>/dev/null || true' EXIT
  for f in \$STAGE/*.service \$STAGE/*.path; do
    [ -f \"\$f\" ] || continue
    install -m 644 \"\$f\" \$MNT/etc/systemd/system/\$(basename \"\$f\")
    install -m 644 \"\$f\" /etc/systemd/system/\$(basename \"\$f\")
  done
  if [ -f \$STAGE/99-rmkit-cn-ime.rules ]; then
    install -m 644 \$STAGE/99-rmkit-cn-ime.rules \$MNT/etc/udev/rules.d/99-rmkit-cn-ime.rules
    install -m 644 \$STAGE/99-rmkit-cn-ime.rules /etc/udev/rules.d/99-rmkit-cn-ime.rules
  fi
  rm -rf \$STAGE
"

ssh "$DEVICE_USER@$DEVICE_IP" "
  systemctl daemon-reload
  systemctl enable rmkit-cn-upload.service rmkit-cn-version.path
  systemctl start rmkit-cn-upload.service rmkit-cn-version.path
  # 启用 Go IME HTTP 服务（如果已部署）
  if [ -f /etc/systemd/system/rmkit-cn-ime-http.service ]; then
    systemctl enable rmkit-cn-ime-http.service
    systemctl start rmkit-cn-ime-http.service
    echo 'Go 拼音输入法服务已启用'
  fi
  udevadm control --reload-rules 2>/dev/null || true
"

# ─── 初始化 QMD 版本链接 ──────────────────────────────────────
ssh "$DEVICE_USER@$DEVICE_IP" "
  RMKIT_DIR=$REMOTE_BASE VERSION_FILE=/etc/version XOVI_DIR=/home/root/xovi \
    $REMOTE_BASE/bin/version-switcher.sh 2>/dev/null || echo '(QMD 版本切换跳过：XOVI 未安装或无 QMD 文件)'
"


# ─── 完成 ─────────────────────────────────────────────────────
WIFI_IP=$(ssh "$DEVICE_USER@$DEVICE_IP" "ip route get 8.8.8.8 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print \$2}'" 2>/dev/null || echo "")

echo ""
echo "✓ rmkit-cn 安装完成！"
echo ""
echo "访问管理界面："
echo "  USB:  http://10.11.99.1:8080"
[ -n "$WIFI_IP" ] && echo "  WiFi: http://$WIFI_IP:8080"
