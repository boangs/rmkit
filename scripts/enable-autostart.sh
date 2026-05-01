#!/bin/sh
# 将 rmkit-cn 写入真实 rootfs 的 /etc，实现重启后自动加载。
#
# 原理：reMarkable Paper Pro 上 /etc 是 overlayfs（upperdir 在 tmpfs），重启即清空。
# 参考 xovi-tripletap：先 remount rw /，再 umount -R /etc 卸掉 overlay，
# 此后对 /etc 的写入会直接落到只读 rootfs 被覆盖前的真实目录，持久化。
#
# 代价：OTA 系统更新会重建 rootfs，届时需要重跑本脚本一次。
set -e

RMKIT_DIR="/home/root/rmkit-cn"
XOVI_DIR="/home/root/xovi"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
cyan()  { printf '\033[36m%s\033[0m\n' "$*"; }

[ "$(id -u)" = 0 ] || { red "需要 root 权限"; exit 1; }

MODEL=$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo "")
case "$MODEL" in
  *Ferrari*|*Chiappa*) ;;
  *) red "仅适用于 reMarkable Paper Pro 家族（检测到: $MODEL）"; exit 1 ;;
esac

cyan "→ 卸载 /etc overlay 并挂载 rootfs 为可写..."
mount -o remount,rw /
umount -R /etc 2>/dev/null || true

cyan "→ 写入 xochitl drop-in（LD_PRELOAD + ime-server 启动）..."
mkdir -p /etc/systemd/system/xochitl.service.d
cat > /etc/systemd/system/xochitl.service.d/rmkit-cn.conf <<EOF
[Service]
ExecStart=
ExecStart=$XOVI_DIR/xochitl-xovi
EOF

cyan "→ 写入 ime-server 服务单元..."
cat > /etc/systemd/system/rmkit-cn-ime.service <<EOF
[Unit]
Description=rmkit-cn 拼音输入法 HTTP 服务
After=network.target

[Service]
Type=simple
ExecStart=$RMKIT_DIR/bin/ime-server
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cyan "→ 重载 systemd 并启用..."
systemctl daemon-reload
systemctl enable rmkit-cn-ime.service
systemctl restart rmkit-cn-ime.service

green ""
green "✓ 持久化启用完成。重启后 rmkit-cn 会自动加载。"
echo "  · OTA 系统更新后需要重跑: $RMKIT_DIR/scripts/enable-autostart.sh"
