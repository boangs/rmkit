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

# ─── 选架构对应二进制/扩展 ───────────────────────────────────
case "$ARCH" in
  aarch64)
    UPLOAD_BIN_NAME="upload-server-aarch64"
    IME_BIN_NAME="ime-server"
    IME_HOOK_NAME="ime_hook.so"
    EXT_ARCH="aarch64"
    ;;
  armv7l)
    UPLOAD_BIN_NAME="upload-server-armv7"
    IME_BIN_NAME="ime-server-armv7"
    IME_HOOK_NAME="ime_hook-armv7.so"
    EXT_ARCH="armv7"
    ;;
  *)
    echo "✗ 不支持的架构: $ARCH (本项目仅支持 aarch64 / armv7l)" >&2
    exit 1
    ;;
esac

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
    echo "正在同步设备 hashtab..."
    REMOTE_HASHTAB=$(ssh "$DEVICE_USER@$DEVICE_IP" "ls -d /home/root/xovi/exthome/qt-resource-rebuilder*/hashtab 2>/dev/null | head -n 1" || true)
    if [ -n "$REMOTE_HASHTAB" ]; then
      scp -q "$DEVICE_USER@$DEVICE_IP:$REMOTE_HASHTAB" "$HASHTAB_LOCAL"
      echo "  → tools/hashtab 已同步设备版本 ($REMOTE_HASHTAB)"
    elif [ -f "$HASHTAB_LOCAL" ]; then
      echo "警告: 设备未找到 hashtab, 沿用本地 tools/hashtab (hash 可能不命中)"
    else
      echo "✗ 致命: tools/hashtab 不存在且未能从设备同步, 也无可用种子" >&2
      exit 1
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

# ─── qmd 校验 ────────────────────────────────────────────────
# hash-qmd.py 历史上 stderr 当 stdout 写入过 Python traceback 当 .qmd,
# 部署前必须验证 dist/*.qmd 是真 qmd 不是 traceback
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
  "$PAYLOAD/home/root/xovi/exthome/qt-resource-rebuilder/chess" \
  "$PAYLOAD/home/root/xovi/extensions.d" \
  "$PAYLOAD/usr/share/remarkable/xochitl/translations" \
  "$PAYLOAD/tmp/rmkit-cn-systemd-staging"

# /home/root/rmkit-cn/bin/  Go binary + IME hook .so + version-switcher
# 注: scripts/apply-font.sh / apply-screen.sh 不再部署到设备 — 用户态字体
# 与屏幕已经由 upload-server web UI 接管, 这两个脚本只在仓库 scripts/ 留给
# 开发者本地引用 (设备上没人调用过它们).
cp "$SCRIPT_DIR/scripts/version-switcher.sh" "$PAYLOAD/home/root/rmkit-cn/bin/"
cp "$DIST_DIR/$IME_BIN_NAME"  "$PAYLOAD/home/root/rmkit-cn/bin/ime-server"
cp "$DIST_DIR/$IME_HOOK_NAME" "$PAYLOAD/home/root/rmkit-cn/bin/ime_hook.so"
chmod +x "$PAYLOAD/home/root/rmkit-cn/bin/"*

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
tar -czf - -C "$PAYLOAD" . | ssh "$DEVICE_USER@$DEVICE_IP" '
  set -e
  mount -o remount,rw / 2>/dev/null || true
  mkdir -p /home/root/.local/share/rmkit-cn/fonts \
           /home/root/.local/share/rmkit-cn/screens \
           /home/root/.local/share/fonts \
           /usr/share/remarkable/xochitl/translations \
           /home/root/xovi/exthome/qt-resource-rebuilder
  cd / && tar -xzf -
'
ELAPSED=$(( $(date +%s) - START_TS ))
echo "  传输完成 (${ELAPSED}s)"

# ─── 设备端: bind-mount 双写 systemd + enable + start + version 链接 ───
# /etc 是 overlayfs, tar 解出来的 systemd 文件已经落在 /tmp/rmkit-cn-systemd-staging/,
# 这里把它们 bind-mount 双写到 /etc 上层 (立即生效) + 下层 (重启保留).
echo "正在配置系统服务 + 启动..."
ssh "$DEVICE_USER@$DEVICE_IP" "
  set -e
  STAGE=/tmp/rmkit-cn-systemd-staging
  MNT=/tmp/rmkit-cn-rootfs
  mkdir -p \$MNT
  mount --bind / \$MNT
  trap 'umount -l \$MNT 2>/dev/null || true; rmdir \$MNT 2>/dev/null || true' EXIT
  # 双写: \$1=源文件, \$2=目标相对路径(无前导 /, 基于 rootfs 根)
  # BusyBox 无 install(1), 用 cp + chmod 替代
  install_both() {
    mkdir -p \"\$MNT/\$(dirname \"\$2\")\" \"/\$(dirname \"\$2\")\"
    cp \"\$1\" \"\$MNT/\$2\" && chmod 644 \"\$MNT/\$2\"
    cp \"\$1\" \"/\$2\"      && chmod 644 \"/\$2\"
  }
  for f in \$STAGE/*.service \$STAGE/*.path; do
    [ -f \"\$f\" ] || continue
    install_both \"\$f\" \"etc/systemd/system/\$(basename \"\$f\")\"
  done
  if [ -f \$STAGE/zz-rmkit-cn.conf ]; then
    install_both \$STAGE/zz-rmkit-cn.conf \"etc/systemd/system/xochitl.service.d/zz-rmkit-cn.conf\"
    # 清历史调试残留 (避免 #DEBUG_DISABLED / Requires=home.mount 之类炸弹复活)
    rm -f \$MNT/etc/systemd/system/xochitl.service.d/zz-rmkit-cn.conf.bak* \
          /etc/systemd/system/xochitl.service.d/zz-rmkit-cn.conf.bak* \
          \$MNT/etc/systemd/system/xochitl.service.d/zz-rmkit-cn.conf.old \
          /etc/systemd/system/xochitl.service.d/zz-rmkit-cn.conf.old 2>/dev/null || true
  fi
  rm -rf \$STAGE

  systemctl daemon-reload
  systemctl enable rmkit-cn-upload.service rmkit-cn-version.path
  systemctl start  rmkit-cn-upload.service rmkit-cn-version.path
  if [ -f /etc/systemd/system/rmkit-cn-ime-http.service ]; then
    systemctl enable rmkit-cn-ime-http.service
    systemctl start  rmkit-cn-ime-http.service
  fi
  udevadm control --reload-rules 2>/dev/null || true

  # 初始化 QMD 版本链接 (qmd/current → qmd/<fw 版本>)
  RMKIT_DIR=$REMOTE_BASE VERSION_FILE=/etc/version XOVI_DIR=/home/root/xovi \
    $REMOTE_BASE/bin/version-switcher.sh 2>/dev/null || echo '(QMD 版本切换跳过)'
"


# ─── 完成 ─────────────────────────────────────────────────────
WIFI_IP=$(ssh "$DEVICE_USER@$DEVICE_IP" "ip route get 8.8.8.8 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print \$2}'" 2>/dev/null || echo "")

echo ""
echo "✓ rmkit-cn 安装完成！"
echo ""
echo "访问管理界面："
echo "  USB:  http://10.11.99.1:8080"
[ -n "$WIFI_IP" ] && echo "  WiFi: http://$WIFI_IP:8080"
