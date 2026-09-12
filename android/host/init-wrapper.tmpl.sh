#!/bin/sh
# rmkit 单槽 Android init 包装。无标志 = 原样起 systemd (与出厂完全一致)。
# 有标志 = 先一次性复位 (删标志+内核链接回出厂), 复位成功才进 Android, 防循环。
if [ -e /.boot-android-mode ]; then
    # PID1 起步时 /proc /sys 未挂; busybox remount 靠 /proc 找根设备 (rm-android-init 容忍已挂载)
    mount -t proc proc /proc 2>/dev/null
    mount -t sysfs sysfs /sys 2>/dev/null
    mount -o remount,rw / 2>/dev/null
    if rm -f /.boot-android-mode && ln -sf @STOCK_KERNEL@ /boot/fitImage.ahab; then
        sync
        # 等价原厂 rm-reset-boot-count.sh: 清本槽 u-boot 错误计数, 连续多次 Android 开机也不会被踢到另一槽
        part=$(cat /sys/devices/platform/lpgpr/root_part 2>/dev/null)
        [ -n "$part" ] && echo 0 > /sys/devices/platform/lpgpr/root${part}_errcnt 2>/dev/null
        exec /usr/bin/rm-android-init-ss
    fi
    # 复位失败: 拒绝进 Android 防循环, 走 stock
fi
exec /lib/systemd/systemd "$@"
