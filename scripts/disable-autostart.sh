#!/bin/sh
# 撤销 enable-autostart.sh 的持久化修改。
set -e

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
cyan()  { printf '\033[36m%s\033[0m\n' "$*"; }

[ "$(id -u)" = 0 ] || { red "需要 root 权限"; exit 1; }

cyan "→ 停止并禁用服务..."
systemctl disable --now rmkit-cn-ime.service 2>/dev/null || true

cyan "→ 卸载 /etc overlay 并以 rw 操作 rootfs..."
mount -o remount,rw /
umount -R /etc 2>/dev/null || true

cyan "→ 清理 rmkit-cn 留下的 systemd 文件..."
rm -f /etc/systemd/system/rmkit-cn-ime.service
rm -f /etc/systemd/system/xochitl.service.d/rmkit-cn.conf
rmdir /etc/systemd/system/xochitl.service.d 2>/dev/null || true

systemctl daemon-reload

green ""
green "✓ 已撤销持久化。下次重启后 xochitl 将回到 stock 状态。"
