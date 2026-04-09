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
    systemctl stop rmkit-cn-upload.service rmkit-cn-version.path rmkit-cn-ime.service rmkit-cn-ime-udev.service 2>/dev/null || true
    systemctl disable rmkit-cn-upload.service rmkit-cn-version.path rmkit-cn-ime.service rmkit-cn-ime-udev.service 2>/dev/null || true
    rm -rf $REMOTE_BASE
    rm -f /etc/systemd/system/rmkit-cn-*.service /etc/systemd/system/rmkit-cn-*.path
    rm -f /etc/udev/rules.d/99-rmkit-cn-ime.rules
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
FW_VERSION=$(ssh "$DEVICE_USER@$DEVICE_IP" "head -1 /etc/remarkable/version | grep -oE '^[0-9]+\.[0-9]+'")
RESOLUTION=$(ssh "$DEVICE_USER@$DEVICE_IP" "cat /sys/class/graphics/fb0/virtual_size 2>/dev/null || echo 'unknown'")

echo "设备架构：$ARCH"
echo "固件版本：$FW_VERSION"
echo "屏幕分辨率：$RESOLUTION"
echo ""

case "$RESOLUTION" in
  "1404,1872") DEVICE_MODEL="reMarkable 2" ;;
  "2160,2880") DEVICE_MODEL="Paper Pro" ;;
  "1696,954")  DEVICE_MODEL="Paper Pro Move" ;;
  *)           DEVICE_MODEL="未知型号（$RESOLUTION）" ;;
esac
echo "检测到设备：$DEVICE_MODEL"

# ─── 创建远端目录 ─────────────────────────────────────────────
echo ""
echo "正在创建目录结构..."
ssh "$DEVICE_USER@$DEVICE_IP" "
  mkdir -p $REMOTE_BASE/{qmd,bin,ime,upload-server/static}
  mkdir -p /home/root/.local/share/rmkit-cn/{fonts,screens}
  mkdir -p /home/root/.local/share/fonts
"

# ─── 部署文件 ─────────────────────────────────────────────────
echo "正在部署脚本..."
scp "$SCRIPT_DIR/scripts/apply-font.sh" "$DEVICE_USER@$DEVICE_IP:$REMOTE_BASE/bin/"
scp "$SCRIPT_DIR/scripts/apply-screen.sh" "$DEVICE_USER@$DEVICE_IP:$REMOTE_BASE/bin/"
scp "$SCRIPT_DIR/scripts/version-switcher.sh" "$DEVICE_USER@$DEVICE_IP:$REMOTE_BASE/bin/"
ssh "$DEVICE_USER@$DEVICE_IP" "chmod +x $REMOTE_BASE/bin/*.sh"

echo "正在部署上传服务..."
scp "$SCRIPT_DIR/upload-server/main.py" "$DEVICE_USER@$DEVICE_IP:$REMOTE_BASE/upload-server/"
scp "$SCRIPT_DIR/upload-server/requirements.txt" "$DEVICE_USER@$DEVICE_IP:$REMOTE_BASE/upload-server/"
scp "$SCRIPT_DIR/upload-server/static/index.html" "$DEVICE_USER@$DEVICE_IP:$REMOTE_BASE/upload-server/static/"

# 部署 QMD 文件集（如果存在）
if [ -d "$SCRIPT_DIR/qmd" ] && [ "$(ls -A "$SCRIPT_DIR/qmd" 2>/dev/null)" ]; then
  echo "正在部署 QMD 文件..."
  scp -r "$SCRIPT_DIR/qmd/"* "$DEVICE_USER@$DEVICE_IP:$REMOTE_BASE/qmd/"
fi

# 部署 IME（如果存在）
if [ -d "$SCRIPT_DIR/ime" ] && [ "$(ls -A "$SCRIPT_DIR/ime" 2>/dev/null)" ]; then
  echo "正在部署输入法..."
  ssh "$DEVICE_USER@$DEVICE_IP" "mkdir -p $REMOTE_BASE/ime/dict"
  scp "$SCRIPT_DIR/ime/pinyin.py" "$SCRIPT_DIR/ime/keyboard.py" "$SCRIPT_DIR/ime/injector.py" "$SCRIPT_DIR/ime/overlay.py" "$SCRIPT_DIR/ime/main.py" "$SCRIPT_DIR/ime/build_dict.py" "$DEVICE_USER@$DEVICE_IP:$REMOTE_BASE/ime/"
  scp "$SCRIPT_DIR/ime/dict/chars.json" "$DEVICE_USER@$DEVICE_IP:$REMOTE_BASE/ime/dict/" 2>/dev/null || true
fi

# ─── 安装 Python 依赖 ─────────────────────────────────────────
echo "正在安装 Python 依赖..."
ssh "$DEVICE_USER@$DEVICE_IP" "
  pip3 install fastapi uvicorn python-multipart pypinyin pillow 2>&1 | tail -5
"

# ─── 部署 systemd 服务 ────────────────────────────────────────
echo "正在配置系统服务..."
scp "$SCRIPT_DIR/systemd/rmkit-cn-upload.service" "$DEVICE_USER@$DEVICE_IP:/etc/systemd/system/"
scp "$SCRIPT_DIR/systemd/rmkit-cn-version.path" "$DEVICE_USER@$DEVICE_IP:/etc/systemd/system/"
scp "$SCRIPT_DIR/systemd/rmkit-cn-version.service" "$DEVICE_USER@$DEVICE_IP:/etc/systemd/system/"

# 部署 IME 服务（如果存在）
if [ -f "$SCRIPT_DIR/systemd/rmkit-cn-ime.service" ]; then
  scp "$SCRIPT_DIR/systemd/rmkit-cn-ime.service" "$DEVICE_USER@$DEVICE_IP:/etc/systemd/system/"
fi
if [ -f "$SCRIPT_DIR/systemd/rmkit-cn-ime-udev.service" ]; then
  scp "$SCRIPT_DIR/systemd/rmkit-cn-ime-udev.service" "$DEVICE_USER@$DEVICE_IP:/etc/systemd/system/"
fi
if [ -f "$SCRIPT_DIR/systemd/99-rmkit-cn-ime.rules" ]; then
  scp "$SCRIPT_DIR/systemd/99-rmkit-cn-ime.rules" "$DEVICE_USER@$DEVICE_IP:/etc/udev/rules.d/"
fi

ssh "$DEVICE_USER@$DEVICE_IP" "
  systemctl daemon-reload
  systemctl enable rmkit-cn-upload.service rmkit-cn-version.path
  systemctl start rmkit-cn-upload.service rmkit-cn-version.path
  udevadm control --reload-rules 2>/dev/null || true
"

# ─── 初始化 QMD 版本链接 ──────────────────────────────────────
ssh "$DEVICE_USER@$DEVICE_IP" "
  RMKIT_DIR=$REMOTE_BASE VERSION_FILE=/etc/remarkable/version XOVI_DIR=/home/root/xovi \
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
