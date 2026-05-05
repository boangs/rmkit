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
    EXT_ARCH="aarch64"
    QMD_TOOL_NAME="qmd-tool-aarch64"
    ;;
  armv7l)
    UPLOAD_BIN_NAME="upload-server-armv7"
    IME_BIN_NAME="ime-server-armv7"
    IME_HOOK_NAME="ime_hook-armv7.so"
    EXT_ARCH="armv7"
    QMD_TOOL_NAME="qmd-tool-armv7"
    ;;
  *)
    echo "✗ 不支持的架构: $ARCH (本项目仅支持 aarch64 / armv7l)" >&2
    exit 1
    ;;
esac

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
    ZZ_UNIT_HEADER=""
    ;;
  aarch64)
    ZZ_UNIT_HEADER="[Unit]
After=home.mount"
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

# 版本缓存：当前固件版本编译产物，OTA 后首次启动可直接命中缓存
for qmd in advanced_panel.qmd language_zh_cn.qmd ai_text_button.qmd; do
  cp "$DIST_DIR/$qmd" "$PAYLOAD/home/root/rmkit-cn/compiled-qmd/$FW_VERSION/"
done

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

# ─── 生成架构专用的 zz-rmkit-cn.conf ────────────────────────────
# 写入 staging 目录里 (tar 已经传过去了), 或直接在设备端用 heredoc 写
ZZ_CONF_CONTENT="${ZZ_UNIT_HEADER}
[Service]
ExecStartPre=/bin/sh -c 'FW=\$(cat /etc/version 2>/dev/null); CACHE=/home/root/rmkit-cn/compiled-qmd/\$FW; DEPLOY=/home/root/xovi/exthome/qt-resource-rebuilder; rm -f \"\$DEPLOY\"/*.qmd; [ -d \"\$CACHE\" ] && ls \"\$CACHE\"/*.qmd >/dev/null 2>&1 && cp \"\$CACHE\"/*.qmd \"\$DEPLOY/\"; LAST=\$(cat /home/root/rmkit-cn/.last_fw_version 2>/dev/null); if [ \"\$FW\" != \"\$LAST\" ]; then nohup bash /home/root/rmkit-cn/bin/fw-upgrade.sh >/tmp/fw-upgrade.log 2>&1 & fi; exit 0'
WatchdogSec=0
Environment=\"QML_DISABLE_DISK_CACHE=1\"
Environment=\"QML_XHR_ALLOW_FILE_WRITE=1\"
Environment=\"QML_XHR_ALLOW_FILE_READ=1\"
Environment=\"LD_PRELOAD=/home/root/xovi/xovi.so:/home/root/rmkit-cn/bin/ime_hook.so\"
Environment=\"QT_RESOURCE_REBUILDER_PATH=/home/root/xovi/exthome/qt-resource-rebuilder/zh_CN.rcc\""

# ─── 设备端: 安装 systemd + 启动 ──────────────────────────────────
# rm2 (armv7l): /etc 直接在 ext4, 直接写, 无需 bind-mount
# aarch64 (RMPP/RMPPM): /etc 是 overlay, 需要 bind-mount 双写
# 两者 OTA 后都通过 reenable.sh 一键恢复, 逻辑统一
echo "正在配置系统服务 + 启动..."
if [ "$ARCH" = "armv7l" ]; then
  # rm2: 直接写 /etc (无 overlay)
  ssh "$DEVICE_USER@$DEVICE_IP" "
    set -e
    STAGE=/tmp/rmkit-cn-systemd-staging

    # 修复 /home/root owner (rm2 出厂重置后会设成 uid 502, 导致 SSH 公钥失效)
    chown root:root /home/root 2>/dev/null || true

    # 安装 service/path units
    for f in \$STAGE/*.service \$STAGE/*.path; do
      [ -f \"\$f\" ] || continue
      cp \"\$f\" /etc/systemd/system/\$(basename \"\$f\")
      chmod 644 /etc/systemd/system/\$(basename \"\$f\")
    done

    # zz-rmkit-cn.conf (rm2: 无 After=home.mount, 含 ExecStartPre 版本缓存)
    mkdir -p /etc/systemd/system/xochitl.service.d/
    cat > /etc/systemd/system/xochitl.service.d/zz-rmkit-cn.conf << 'CONFEOF'
$ZZ_CONF_CONTENT
CONFEOF
    chmod 644 /etc/systemd/system/xochitl.service.d/zz-rmkit-cn.conf

    rm -rf \$STAGE
    systemctl daemon-reload
    systemctl enable rmkit-cn-upload.service rmkit-cn-version.path rmkit-cn-version.service
    systemctl start  rmkit-cn-upload.service rmkit-cn-version.path
    if [ -f /etc/systemd/system/rmkit-cn-ime-http.service ]; then
      systemctl enable rmkit-cn-ime-http.service
      systemctl start  rmkit-cn-ime-http.service
    fi
    udevadm control --reload-rules 2>/dev/null || true
  "
else
  # aarch64 (RMPP/RMPPM): /etc 是 overlay, 需要 bind-mount 双写
  ssh "$DEVICE_USER@$DEVICE_IP" "
    set -e
    STAGE=/tmp/rmkit-cn-systemd-staging
    MNT=/tmp/rmkit-cn-rootfs
    mkdir -p \$MNT
    mount --bind / \$MNT
    trap 'umount -l \$MNT 2>/dev/null || true; rmdir \$MNT 2>/dev/null || true' EXIT
    install_both() {
      mkdir -p \"\$MNT/\$(dirname \"\$2\")\" \"/\$(dirname \"\$2\")\"
      cp \"\$1\" \"\$MNT/\$2\" && chmod 644 \"\$MNT/\$2\"
      cp \"\$1\" \"/\$2\"      && chmod 644 \"/\$2\"
    }
    for f in \$STAGE/*.service \$STAGE/*.path; do
      [ -f \"\$f\" ] || continue
      install_both \"\$f\" \"etc/systemd/system/\$(basename \"\$f\")\"
    done
    # 安装含 After=home.mount 的 zz-rmkit-cn.conf (aarch64 安全)
    cat > \$STAGE/zz-rmkit-cn.conf << 'CONFEOF'
$ZZ_CONF_CONTENT
CONFEOF
    install_both \$STAGE/zz-rmkit-cn.conf \"etc/systemd/system/xochitl.service.d/zz-rmkit-cn.conf\"
    rm -f \$MNT/etc/systemd/system/xochitl.service.d/zz-rmkit-cn.conf.bak* \
          /etc/systemd/system/xochitl.service.d/zz-rmkit-cn.conf.bak* 2>/dev/null || true
    rm -rf \$STAGE

    systemctl daemon-reload
    systemctl enable rmkit-cn-upload.service rmkit-cn-version.path
    systemctl start  rmkit-cn-upload.service rmkit-cn-version.path
    if [ -f /etc/systemd/system/rmkit-cn-ime-http.service ]; then
      systemctl enable rmkit-cn-ime-http.service
      systemctl start  rmkit-cn-ime-http.service
    fi
    udevadm control --reload-rules 2>/dev/null || true
    RMKIT_DIR=$REMOTE_BASE VERSION_FILE=/etc/version XOVI_DIR=/home/root/xovi \
      $REMOTE_BASE/bin/version-switcher.sh 2>/dev/null || echo '(QMD 版本切换跳过)'
  "
fi


# 写入基准固件版本，fw-upgrade.sh 以此判断 OTA 后是否需要重编
ssh "$DEVICE_USER@$DEVICE_IP" "printf '%s' '$FW_VERSION' > /home/root/rmkit-cn/.last_fw_version"
echo "✓ .last_fw_version 已写入 ($FW_VERSION)"

# ─── 完成 ─────────────────────────────────────────────────────
WIFI_IP=$(ssh "$DEVICE_USER@$DEVICE_IP" "ip route get 8.8.8.8 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print \$2}'" 2>/dev/null || echo "")

echo ""
echo "✓ rmkit-cn 安装完成！"
echo ""
echo "访问管理界面："
echo "  USB:  http://10.11.99.1:8080"
[ -n "$WIFI_IP" ] && echo "  WiFi: http://$WIFI_IP:8080"
