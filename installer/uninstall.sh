#!/bin/sh
# rmkit-cn 卸载脚本
set -e

[ "$(id -u)" = 0 ] || { echo "需要 root 权限"; exit 1; }

RMKIT_DIR="/home/root/rmkit-cn"
QMD_DIR="/home/root/xovi/exthome/qt-resource-rebuilder"
SD_DIR="/etc/systemd/system/xochitl.service.d"

echo "=== rmkit-cn 卸载 ==="

systemctl stop rmkit-cn-ime.service 2>/dev/null || true
systemctl disable rmkit-cn-ime.service 2>/dev/null || true

# 清当前（overlay）/etc 上的文件
rm -f /etc/systemd/system/rmkit-cn-ime.service
rm -f "$SD_DIR/zz-rmkit-cn.conf" "$SD_DIR/rmkit-cn.conf" "$SD_DIR/xovi.conf"
rmdir "$SD_DIR" 2>/dev/null || true

# 用 `mount --bind / /mnt` 清真实 rootfs 上的持久化副本（不断 ssh）
mount -o remount,rw /
mount --bind / /mnt 2>/dev/null || true
if mountpoint -q /mnt 2>/dev/null; then
  rm -f /mnt/etc/systemd/system/rmkit-cn-ime.service
  rm -f /mnt/etc/systemd/system/xochitl.service.d/zz-rmkit-cn.conf \
        /mnt/etc/systemd/system/xochitl.service.d/rmkit-cn.conf \
        /mnt/etc/systemd/system/xochitl.service.d/xovi.conf
  rm -f /mnt/etc/systemd/system/multi-user.target.wants/rmkit-cn-ime.service
  rmdir /mnt/etc/systemd/system/xochitl.service.d 2>/dev/null || true
  sync
  umount /mnt
fi

rm -f "$QMD_DIR/pinyin_interceptor.qmd" "$QMD_DIR/zh_CN.rcc" "$QMD_DIR/hashtab"
rm -f "$QMD_DIR/advanced_panel.qmd" "$QMD_DIR/language_zh_cn.qmd"

# 清中文翻译 qm
mount -o remount,rw / 2>/dev/null || true
rm -f /usr/share/remarkable/xochitl/translations/reMarkable_zh_CN.qm

rm -rf "$RMKIT_DIR"

systemctl daemon-reload
systemctl restart xochitl

echo "✓ rmkit-cn 已卸载（XOVI 保留未动）"
