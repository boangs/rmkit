# 单槽 Android 卸载: 还原 /sbin/init, 删本槽 rootfs 上的内核/模块/二进制/配置。
# env: REMOVE_DATA=1 同时删 /home 里的 Android 系统与数据 (默认保留, 重装可续用)。
set -e
[ "$(cat /proc/1/comm 2>/dev/null)" = "systemd" ] || { echo "  ✗ 请先回到 reMarkable 系统再卸载"; exit 1; }
mount -o remount,rw / 2>/dev/null || true
if [ -e /sbin/init.systemd-orig ]; then
  mv -f /sbin/init.systemd-orig /sbin/init
  echo "  ✓ /sbin/init 已还原为 systemd"
fi
rm -f /.boot-android-mode
STOCK=$(ls /boot/ | grep '^fitImage.ahab-6' | grep -v android | head -n 1)
[ -n "$STOCK" ] && ln -sf "$STOCK" /boot/fitImage.ahab
rm -f /boot/fitImage.ahab-android /usr/bin/rm-android-init-ss /usr/bin/rm-touch-relay /usr/bin/rm-epd-bridge /usr/bin/rm-native-controls
rm -rf /lib/modules/6.12.49+git+f21cbcc9ed9a
LOWER=/tmp/rmkit-lower
# 上次中途失败可能留下叠层挂载, 先清干净再挂
while mountpoint -q $LOWER 2>/dev/null; do umount -l $LOWER || break; done
mkdir -p $LOWER && mount --bind / $LOWER && mount -o remount,rw,bind $LOWER
for base in $LOWER/etc /etc; do
  rm -f $base/paperhome/udhcpd-usb.conf $base/systemd/system/android-kernel-revert.service \
        $base/systemd/system/sysinit.target.wants/android-kernel-revert.service
  rmdir $base/paperhome 2>/dev/null || true
done
sync; umount -l $LOWER 2>/dev/null || true; rmdir $LOWER 2>/dev/null || true
systemctl daemon-reload
rmdir /android /android-data 2>/dev/null || true
rm -f /home/root/boot-android.sh /home/root/propset
if [ "${REMOVE_DATA:-0}" = "1" ]; then
  rm -rf /home/root/android-system /home/root/native-android-data-v1
  echo "  ✓ 已删除 /home 里的 Android 系统与数据"
else
  echo "  · 保留 /home/root/android-system 与 native-android-data-v1 (重装可续用)"
fi
sync
echo "  ✓ 单槽 Android 已卸载, 出厂链接 -> $(readlink /boot/fitImage.ahab)"
