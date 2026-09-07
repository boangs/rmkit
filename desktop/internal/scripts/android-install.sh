# 单槽 Android (RMPPM) 设备端安装: 载荷已由助手放到 $STAGE, 本脚本把它们落到本槽。
# 设计要点 (与 2026-09-06 跑通的手工安装一致):
#   - 只动当前槽 rootfs 的 /boot /lib/modules /usr/bin /sbin/init 与 rootfs 下层 /etc;
#     Android 系统与数据放共享的 /home, rootfs 只多 ~27MB。
#   - /sbin/init 换成包装脚本: 无标志 = 原样 exec systemd (出厂行为), 有标志 = 先复位再进 Android。
#     原链接备份为 /sbin/init.systemd-orig, 卸载即还原。
#   - 出厂链接 /boot/fitImage.ahab 全程不动, 直到用户点"进 Android" (boot-android.sh) 才临时指向
#     android 内核, 而包装脚本开机第一件事就是把它改回来 —— 任何失败都回到 reMarkable。
# env: STAGE (载荷目录) REPLACE_SYSTEM (1=覆盖已有 /home/root/android-system)
set -e
STAGE=${STAGE:-/tmp/rmkit-android-stage}
fail() { echo "  ✗ $*"; exit 1; }

[ -d "$STAGE" ] || fail "载荷目录 $STAGE 不存在"
[ "$(cat /proc/1/comm 2>/dev/null)" = "systemd" ] || fail "当前不是 reMarkable 系统 (PID1 非 systemd), 请先回原厂系统"
STOCK=$(readlink /boot/fitImage.ahab 2>/dev/null || true)
case "$STOCK" in
  ""|fitImage.ahab-android) fail "无法确定出厂内核 (/boot/fitImage.ahab -> '$STOCK')" ;;
esac
[ -f "/boot/$STOCK" ] || fail "出厂内核文件 /boot/$STOCK 不存在"
echo "  出厂内核: $STOCK"

mount -o remount,rw / 2>/dev/null || true

echo "  → 1/8 内核"
cp "$STAGE/fitImage.ahab-android" /boot/fitImage.ahab-android.new
sync; mv /boot/fitImage.ahab-android.new /boot/fitImage.ahab-android

echo "  → 2/8 内核模块"
T=$(mktemp -d /tmp/rmkit-mod.XXXXXX)
tar -xzf "$STAGE/modules.tar.gz" -C "$T"
DEP=$(find "$T" -name modules.dep | head -n 1)
[ -n "$DEP" ] || fail "模块包里没有 modules.dep"
MODDIR=$(dirname "$DEP"); MODNAME=$(basename "$MODDIR")
rm -rf "/lib/modules/$MODNAME"
mv "$MODDIR" "/lib/modules/$MODNAME"
rm -rf "$T"
echo "    /lib/modules/$MODNAME ($(find /lib/modules/$MODNAME -name '*.ko*' | wc -l) 个模块)"

echo "  → 3/8 宿主二进制"
for b in rm-android-init-ss rm-touch-relay rm-epd-bridge rm-native-controls; do
  [ -f "$STAGE/$b" ] || fail "载荷缺 $b"
  cp "$STAGE/$b" "/usr/bin/$b.new"; chmod 755 "/usr/bin/$b.new"; mv "/usr/bin/$b.new" "/usr/bin/$b"
done
cp "$STAGE/propset" /home/root/propset; chmod 755 /home/root/propset

echo "  → 4/8 rootfs 下层 /etc (Android 模式没有 overlay, 必须写到 ext4 本体)"
LOWER=/tmp/rmkit-lower
mkdir -p $LOWER && mount --bind / $LOWER && mount -o remount,rw,bind $LOWER
for base in $LOWER/etc /etc; do
  mkdir -p $base/paperhome $base/systemd/system/sysinit.target.wants
  cp "$STAGE/udhcpd-usb.conf" $base/paperhome/udhcpd-usb.conf
  sed "s|@STOCK_KERNEL@|$STOCK|g" "$STAGE/android-kernel-revert.service.tmpl" > $base/systemd/system/android-kernel-revert.service
  ln -sf /etc/systemd/system/android-kernel-revert.service $base/systemd/system/sysinit.target.wants/android-kernel-revert.service
done
sync; umount $LOWER; rmdir $LOWER
systemctl daemon-reload

echo "  → 5/8 挂载点与扩展数据目录"
mkdir -p /android /android-data; chmod 755 /android /android-data
D=/home/root/native-android-data-v1
mkdir -p "$D"; chmod 771 "$D"
[ -e "$D/.paper-expanded-data-v1" ] || echo "provisioned $(date -u +%FT%TZ) rmkit-desktop" > "$D/.paper-expanded-data-v1"

echo "  → 6/8 Android 系统 (/home/root/android-system)"
if [ -f "$STAGE/android-system.tar.gz" ]; then
  if [ -d /home/root/android-system ] && [ "${REPLACE_SYSTEM:-0}" != "1" ]; then
    echo "    已存在, 保留 (勾选'覆盖 Android 系统'可重装)"
  else
    rm -rf /home/root/android-system.new
    mkdir -p /home/root/android-system.new
    tar -xzf "$STAGE/android-system.tar.gz" -C /home/root/android-system.new --numeric-owner
    # 包根目录可能是 android-system/ 也可能直接是 system/ 等
    if [ -d /home/root/android-system.new/android-system ]; then
      mv /home/root/android-system.new/android-system /home/root/android-system.tmp
      rm -rf /home/root/android-system.new; mv /home/root/android-system.tmp /home/root/android-system.new
    fi
    [ -e /home/root/android-system.new/system/bin/init ] || fail "Android 系统包里没有 system/bin/init"
    rm -rf /home/root/android-system.old
    [ -d /home/root/android-system ] && mv /home/root/android-system /home/root/android-system.old
    mv /home/root/android-system.new /home/root/android-system
    rm -rf /home/root/android-system.old
    echo "    已解包"
  fi
else
  [ -e /home/root/android-system/system/bin/init ] || fail "载荷不含 Android 系统包, 设备上也没有 /home/root/android-system"
  echo "    载荷不含系统包, 沿用设备上已有的"
fi

echo "  → 7/8 /sbin/init 包装"
if [ -L /sbin/init ] && [ ! -e /sbin/init.systemd-orig ]; then
  cp -P /sbin/init /sbin/init.systemd-orig
fi
[ -e /sbin/init.systemd-orig ] || fail "/sbin/init 不是 symlink 且没有备份, 拒绝覆盖"
sed "s|@STOCK_KERNEL@|$STOCK|g" "$STAGE/init-wrapper.tmpl.sh" > /sbin/init.new
chmod 755 /sbin/init.new
sh -n /sbin/init.new || fail "init 包装语法错误"
grep -q "exec /lib/systemd/systemd" /sbin/init.new || fail "init 包装缺 systemd 回落路径"
mv /sbin/init.new /sbin/init
sync

echo "  → 8/8 启动器与自检"
cp "$STAGE/boot-android.sh" /home/root/boot-android.sh; chmod 755 /home/root/boot-android.sh
sync
sh /home/root/boot-android.sh --check
rm -rf "$STAGE"
echo "  ✓ 单槽 Android 安装完成 (本槽 $(rootdev 2>/dev/null), 出厂链接仍指向 $STOCK)"
