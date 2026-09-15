#!/bin/sh
# rmkit Android 诊断 (界面不响应 / 进不去 Android 时用)。在 reMarkable 或 Android 模式下都能跑。
# 用法 (电脑上, USB 连着设备):  ssh root@10.11.99.1 'sh -s' < android-diag.sh > diag.txt 2>&1
# 然后把 diag.txt 整个发过来。
echo "== 版本核对 (与 v1.2.1 Android 包比对, 不一致 = 装的不是最新包) =="
exp() { a=$(md5sum "$2" 2>/dev/null | cut -d' ' -f1); [ -z "$a" ] && a=missing; [ "$a" = "$1" ] && r=ok || r="MISMATCH($a)"; printf '%-22s %s\n' "$(basename $2)" "$r"; }
exp 359dd527fea00b818e173166d1d23b27 /usr/bin/rm-epd-bridge
exp 630103aed456aac8e25ed2e333d20239 /usr/bin/rm-touch-relay
exp 5b012a4abc6c57eb32eff1019e4e28b5 /usr/bin/rm-android-init-ss
exp 1a75572e66e858bffebde043c177a112 /usr/bin/rm-native-controls
exp f139e14d0281809bf9f52dd284d8db21 /home/root/boot-android.sh
exp fb07c8f1bdc19ccfa5fc42cada7b089a /boot/fitImage.ahab-android
echo "fw=$(cat /etc/version 2>/dev/null)  (显示桥 v55 只适配 3.28 固件; 3.27 固件上会全白/不响应)"
exp d34d71f223d7b37f1952d5fa1e61fb58 /usr/lib/plugins/scenegraph/libqsgepaper.so
echo "(libqsgepaper MISMATCH = 固件版本与 3.28.0.169 不同, 显示桥 v55 按这个库的内存布局写的, 换固件就会全白/不响应)"
echo
echo "== 基本 =="
echo "fw=$(cat /etc/version 2>/dev/null) pid1=$(cat /proc/1/comm) uptime=$(cut -d. -f1 /proc/uptime)s"
echo "slot=$(rootdev 2>/dev/null) boot_part=$(cat /sys/bus/mmc/devices/mmc0:0001/boot_part 2>/dev/null) errcnt a/b=$(cat /sys/devices/platform/lpgpr/roota_errcnt 2>/dev/null)/$(cat /sys/devices/platform/lpgpr/rootb_errcnt 2>/dev/null) secboot=$(cat /sys/devices/platform/lpgpr/secboot 2>/dev/null)"
echo "kernel_link=$(readlink /boot/fitImage.ahab 2>/dev/null) android_kernel=$(stat -c %s /boot/fitImage.ahab-android 2>/dev/null)B flag=$([ -e /.boot-android-mode ] && echo present || echo absent)"
echo "init_wrapper=$(grep -c boot-android-mode /sbin/init 2>/dev/null) init_ss=$(stat -c %s /usr/bin/rm-android-init-ss 2>/dev/null)B bridge=$(stat -c %s /usr/bin/rm-epd-bridge 2>/dev/null)B relay=$(stat -c %s /usr/bin/rm-touch-relay 2>/dev/null)B"
echo "modules=$(ls /lib/modules/ 2>/dev/null | tr '\n' ' ') ashmem=$(grep -c ashmem /lib/modules/6.12.49+git+f21cbcc9ed9a/modules.dep 2>/dev/null)"
echo "system=$([ -e /home/root/android-system/system/bin/init ] && echo ok || echo missing) data_sentinel=$([ -e /home/root/native-android-data-v1/.paper-expanded-data-v1 ] && echo ok || echo missing) udhcpd=$([ -e /etc/paperhome/udhcpd-usb.conf ] && echo ok || echo missing)"
echo "root_free=$(df -kP / | awk 'END{print $4}')KB home_free=$(df -kP /home | awk 'END{print $4}')KB"
echo "== rmkit-cn 熔断 (高级面板消失时看这里) =="
echo "fuse_tripped=$(cat /home/root/rmkit-cn/.fuse_tripped 2>/dev/null || echo 无) starts_600s=$(awk -v n=$(date +%s) 'n-$1<600' /home/root/rmkit-cn/.starts 2>/dev/null | wc -l) active_dir=$(ls /home/root/rmkit-cn/active 2>/dev/null | tr '\n' ' ')"
echo "upload_server_launcher=$(grep -c boot-android.sh /home/root/rmkit-cn/upload-server/upload-server 2>/dev/null) (0 = 旧版 upload-server, 面板 Android 按钮会切槽! 请用助手更新 rmkit-cn)"
echo "== 网络 (Android 模式下才有意义) =="
echo "saved_wifi_networks: NetworkManager=$(ls /home/root/.config/NetworkManager/system-connections/*.nmconnection 2>/dev/null | wc -l) legacy=$(grep -c '^network=' /home/root/.config/remarkable/wifi_networks.conf 2>/dev/null || echo 0) (都是 0 = reMarkable 里从没连过 Wi-Fi, 先回原厂系统连一次)"
[ -f /run/rmkit-wifi.conf ] && echo "rmkit-wifi.conf networks=$(grep -c '^network=' /run/rmkit-wifi.conf)" || echo "rmkit-wifi.conf: 不存在 (旧版 rm-android-init 或不在 Android 模式)"
ip addr 2>/dev/null | grep -E "^[0-9]+: (eth0|wlan0|usb)|inet 10\.|inet 192\.|inet 172\." | sed 's/^ *//' || echo "(无 eth0/wlan0)"
echo "wpa_supplicant=$(pgrep -f 'wpa_supplicant.*eth0' >/dev/null 2>&1 && echo running || echo not-running)"
for i in eth0 wlan0; do wpa_cli -i $i status 2>/dev/null | grep -E "^wpa_state|^ssid|^ip_address" | sed "s/^/$i: /"; done
echo "default_route=$(ip route show default 2>/dev/null | head -n 1)"
echo "host_ping_223.5.5.5=$(ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 && echo ok || echo fail)"
grep -iE "wpa|wlan|eth0" /native-boot.log 2>/dev/null | tail -n 4
echo "== 两个槽 (A/B 都可能装过 Android, 固件也可能不同) =="
ROOTDEV=$(sed -n 's/.*root=\([^ ]*\).*/\1/p' /proc/cmdline); echo "current_root=$ROOTDEV"
case "$ROOTDEV" in *p2) OTHER=/dev/mmcblk0p3;; *p3) OTHER=/dev/mmcblk0p2;; *) OTHER="";; esac
echo "this_slot: fw=$(cat /etc/version 2>/dev/null) img=$(sed -n 's/^IMG_VERSION=//p' /etc/os-release 2>/dev/null) wrapper=$(grep -c boot-android-mode /sbin/init 2>/dev/null) android_kernel=$([ -f /boot/fitImage.ahab-android ] && echo yes || echo no) init_ss=$([ -x /usr/bin/rm-android-init-ss ] && echo yes || echo no) bridge=$(stat -c %s /usr/bin/rm-epd-bridge 2>/dev/null)B"
if [ -n "$OTHER" ]; then
  M=/tmp/rmkit-diag-other; mkdir -p $M
  if mount -o ro "$OTHER" $M 2>/dev/null; then
    echo "other_slot ($OTHER): fw=$(cat $M/etc/version 2>/dev/null) img=$(sed -n 's/^IMG_VERSION=//p' $M/etc/os-release 2>/dev/null) wrapper=$(grep -c boot-android-mode $M/sbin/init 2>/dev/null) android_kernel=$([ -f $M/boot/fitImage.ahab-android ] && echo yes || echo no) init_ss=$([ -x $M/usr/bin/rm-android-init-ss ] && echo yes || echo no) bridge=$(stat -c %s $M/usr/bin/rm-epd-bridge 2>/dev/null)B kernel_link=$(readlink $M/boot/fitImage.ahab 2>/dev/null)"
    umount $M 2>/dev/null
  else
    echo "other_slot ($OTHER): 无法挂载"
  fi
  rmdir $M 2>/dev/null
fi
echo "== Android 运行状态 (Android 模式下才有意义) =="
if [ -d /android ] && [ "$(cat /proc/1/comm)" != systemd ]; then
  echo "uptime=$(cut -d. -f1 /proc/uptime)s"
  echo "processes: $(for p in rm-epd-bridge rm-touch-relay rm-native-controls surfaceflinger zygote64 system_server; do printf '%s=%s ' $p $(pgrep -x $p 2>/dev/null | wc -l | tr -d " "); done)"
  echo "ready_markers: display=$([ -e /native-display-ready ] && echo yes || echo no) touch=$([ -e /native-touch-ready ] && echo yes || echo no)"
  echo "input_devices: $(grep '^N: Name=' /proc/bus/input/devices 2>/dev/null | sed 's/N: Name=//' | tr '\n' ' ')"
  echo "-- touch relay log 尾 --"; tail -n 4 /native-touch-relay.log 2>/dev/null
  echo "-- bridge log 尾 (received/displayed 帧数) --"; tail -n 6 /android-data/local/tmp/native-epd-bridge.log 2>/dev/null | cut -c1-200
  echo "-- Android init 服务重启 (zygote 循环则很大) --"; echo "zygote_restarts=$(grep -c "starting service 'zygote'" /native-kmsg.log 2>/dev/null)"
  echo "-- 最近 Android 崩溃 --"; grep -iE 'FATAL|beginning of crash|ANR in' /android-data/local/tmp/*.log 2>/dev/null | tail -n 3 | cut -c1-160
else
  echo "(当前是 reMarkable 模式)"
fi
echo "== 电源/休眠 (不插线才死 = 看这里) =="
echo "charger_online=$(cat /sys/class/power_supply/max77818-charger/online 2>/dev/null) autosleep=$(cat /sys/power/autosleep 2>/dev/null) wake_lock=[$(cat /sys/power/wake_lock 2>/dev/null)]"
echo "kernel_suspend success/fail=$(cat /sys/power/suspend_stats/success 2>/dev/null)/$(cat /sys/power/suspend_stats/fail 2>/dev/null) (Android 模式下 >0 = 整机睡过)"
if [ -d /android ] && [ "$(cat /proc/1/comm)" != systemd ]; then
  echo "-- paper-tuning 日志尾 (亮屏设置有没有写进去) --"; tail -n 8 /android-data/local/tmp/paper-tuning.log 2>/dev/null || echo "(没有日志: paper-tuning 从没跑过)"
  echo "-- Android 内实际设置 (经 paper.exec 通道, 等 8 秒) --"
  cat > /android-data/local/tmp/exec.sh <<'EOS'
#!/system/bin/sh
{ echo "screen_off_timeout=$(/system/bin/settings get system screen_off_timeout)"
  echo "sleep_timeout=$(/system/bin/settings get secure sleep_timeout)"
  echo "stay_on_while_plugged_in=$(/system/bin/settings get global stay_on_while_plugged_in)"
  echo "boot_completed=$(getprop sys.boot_completed)"
  /system/bin/dumpsys power 2>/dev/null | grep -E "mWakefulness=|mScreenState|mHoldingDisplay|mUserActivityTimeoutOverride|Display Power: state" | head -n 6
} > /data/local/tmp/diag-android.txt 2>&1
EOS
  rm -f /android-data/local/tmp/diag-android.txt; ADBD=""; for _p in /proc/[0-9]*; do [ "$(cat $_p/comm 2>/dev/null)" = "adbd" ] && ADBD=${_p#/proc/} && break; done; [ -n "$ADBD" ] && /home/root/propset /proc/$ADBD/root/dev/socket/property_service paper.exec "diag$(date +%s)" >/dev/null 2>&1; sleep 8
  cat /android-data/local/tmp/diag-android.txt 2>/dev/null || echo "(Android 没有响应命令通道: 上层已死或 boot 未完成)"
fi
echo "== boot-android.sh --check =="; sh /home/root/boot-android.sh --check 2>&1
echo "== /native-boot.log 最后一轮 =="
if [ -f /native-boot.log ]; then awk '/native Android boot wrapper started/{n++} {l[NR]=$0; s[NR]=n} END{for(i=1;i<=NR;i++) if(s[i]==n) print l[i]}' /native-boot.log | tail -n 60; else echo "(没有 /native-boot.log: android 内核从未起来过, 或包装脚本没进 Android 分支)"; fi
echo "== /native-kmsg.log 摘要 =="
if [ -f /native-kmsg.log ]; then sed 's/^[0-9]*,[0-9]*,\([0-9]*\),-;/\1 /' /native-kmsg.log | grep -iE "Linux version|Machine model|lpspi|lpi2c|elants|rm-android-init|panic|Oops|watchdog|init: Service .zygote|symbol lookup" | tail -n 40; else echo "(无内核日志; 下次进 Android 前助手会自动打开采集)"; fi