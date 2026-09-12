#!/bin/sh
# 单槽 Android 启动器: 本槽重启进 Android (不切槽)。
# /sbin/init 包装见到 /.boot-android-mode 会先一次性复位 (删标志+内核链接回出厂) 再进 Android。
# 用法: boot-android.sh          检查并重启进 Android
#       boot-android.sh --check  只检查本槽组件是否齐全 (给高级面板/脚本用), 不重启
STOCK_KERNEL_GLOB="/boot/fitImage.ahab-6.12.49+git-imx93-chiappa-g*"
missing=""
for p in /boot/fitImage.ahab-android /usr/bin/rm-android-init-ss /usr/bin/rm-touch-relay /usr/bin/rm-epd-bridge \
         /lib/modules/6.12.49+git+f21cbcc9ed9a/modules.dep /home/root/android-system/system/bin/init \
         /home/root/native-android-data-v1/.paper-expanded-data-v1 /android /android-data /etc/paperhome/udhcpd-usb.conf; do
    [ -e "$p" ] || missing="$missing $p"
done
grep -q boot-android-mode /sbin/init 2>/dev/null || missing="$missing /sbin/init(非单槽包装)"
if [ -n "$missing" ]; then
    echo "本槽 $(rootdev 2>/dev/null) 缺少单槽 Android 组件:$missing"
    echo "单槽 Android 装在 p3 (root_b); 若当前在 p2, 先 rootdev --switch && reboot 回 p3"
    exit 1
fi
[ "$1" = "--check" ] && { echo "ok: 本槽 $(rootdev 2>/dev/null) 单槽 Android 组件齐全"; exit 0; }
set -e
mount -o remount,rw / 2>/dev/null || true
touch /.boot-android-mode
ln -sf fitImage.ahab-android /boot/fitImage.ahab
sync
echo "已置 Android 模式, 3 秒后重启本槽 $(rootdev 2>/dev/null)"
sleep 3
reboot
