#!/bin/sh
# android-touch-fix.sh — 「进 Android 画面定格」的定位 + 现场修复
#
# 证据: 上一轮 dumpsys window 的配置里写着 -touch, 意思是 Android 认为这台机器
# 没有触摸屏。触摸中继在宿主侧一直在工作 (日志里有坐标), 但 Android 收不到,
# 于是桌面永远不重绘 → 画面定格在开机第一帧, 看起来就是"死机"。
#
# 已知原因 (老问题): Android 起来时会重建 /dev, 把宿主先建好的 uinput 节点抹掉,
# 而 ueventd 不会回扫已存在的设备; 另外 InputReader 需要 /system/usr/idc 下的
# rm_Android_touch_relay.idc 才会把它当触摸屏。
#
# 本脚本会: 查节点 → 查 IDC → 缺什么补什么 → 重启 Android 框架让它重新扫描 → 复查。
# 用法 (设备在"定格"的 Android 里, 插数据线):
#   ssh -i <助手密钥> root@10.11.99.1 'sh -s' < android-touch-fix.sh > touch-fix.txt
set -u

echo "== 基本 =="
date; echo "uptime=$(cut -d' ' -f1 /proc/uptime)s"
[ -d /android ] || { echo "(当前不是 Android 模式, 请在 Android 里跑)"; exit 0; }

ADBD=""
for p in /proc/[0-9]*; do
  [ "$(cat "$p/comm" 2>/dev/null)" = "adbd" ] && ADBD=${p#/proc/} && break
done
[ -z "$ADBD" ] && { echo "找不到 adbd, 无法进入 Android 命名空间"; exit 1; }
AR="/proc/$ADBD/root"
echo "Android 根 = $AR (adbd pid=$ADBD)"

echo
echo "== 1. 宿主侧的触摸中继设备 =="
EV=$(awk '/rm Android touch relay/{f=1} f&&/Handlers=/{print $0; exit}' /proc/bus/input/devices 2>/dev/null)
echo "handlers: ${EV:-（/proc/bus/input/devices 里找不到 rm Android touch relay）}"
NODE=$(echo "$EV" | tr ' ' '\n' | grep -m1 '^event')
echo "节点名: ${NODE:-无}"
if [ -n "$NODE" ] && [ -e "/dev/input/$NODE" ]; then
  ls -l "/dev/input/$NODE"
  MAJMIN=$(ls -l "/dev/input/$NODE" | awk '{gsub(",","",$5); print $5" "$6}')
  echo "主次设备号: $MAJMIN"
else
  echo "宿主 /dev/input/$NODE 不存在"
  MAJMIN=""
fi

echo
echo "== 2. Android 容器里看得到吗 =="
echo "-- $AR/dev/input --"
ls -l "$AR/dev/input/" 2>/dev/null || echo "(容器里没有 /dev/input 目录)"

echo
echo "== 3. IDC 配置文件 =="
IDC_REL="system/usr/idc/rm_Android_touch_relay.idc"
for base in "$AR" /home/root/android-system; do
  if [ -f "$base/$IDC_REL" ]; then echo "有: $base/$IDC_REL"; else echo "缺: $base/$IDC_REL"; fi
done

echo
echo "== 4. 缺什么补什么 =="
FIXED=0
# 4a. 节点
if [ -n "$NODE" ] && [ -n "$MAJMIN" ] && [ ! -e "$AR/dev/input/$NODE" ]; then
  mkdir -p "$AR/dev/input"
  # shellcheck disable=SC2086
  if mknod "$AR/dev/input/$NODE" c $MAJMIN 2>/dev/null; then
    chown 0:1004 "$AR/dev/input/$NODE" 2>/dev/null
    chmod 0660 "$AR/dev/input/$NODE" 2>/dev/null
    echo "已在容器里补建 /dev/input/$NODE ($MAJMIN)"
    FIXED=1
  else
    echo "补建节点失败"
  fi
else
  echo "节点无需补建"
fi
# 4b. IDC (写宿主侧的 android-system 树, 容器只读时也能下次生效)
IDC_BODY='# Android InputReader configuration for the uinput device created by
# rm-touch-relay before Android init starts.
device.internal = 1
touch.deviceType = touchScreen
touch.orientationAware = 1
touch.wake = 1'
for base in /home/root/android-system "$AR"; do
  d="$base/system/usr/idc"
  [ -d "$d" ] || continue
  if [ ! -f "$d/rm_Android_touch_relay.idc" ]; then
    if printf '%s\n' "$IDC_BODY" > "$d/rm_Android_touch_relay.idc" 2>/dev/null; then
      chmod 0644 "$d/rm_Android_touch_relay.idc" 2>/dev/null
      echo "已补写 $d/rm_Android_touch_relay.idc"
      FIXED=1
    else
      echo "写不进 $d (只读)"
    fi
  fi
done

echo
echo "== 5. 重启 Android 框架, 让输入系统重新扫描 (约 60 秒) =="
cat > /android-data/local/tmp/exec.sh <<'EOS'
#!/system/bin/sh
{ echo "restarting framework at $(date)"; stop; sleep 3; start; } > /data/local/tmp/touchfix.txt 2>&1
EOS
/home/root/propset "$AR/dev/socket/property_service" paper.exec "tf$(date +%s)" >/dev/null 2>&1
sleep 60

echo
echo "== 6. 复查: Android 现在认到触摸屏了吗 =="
cat > /android-data/local/tmp/exec.sh <<'EOS'
#!/system/bin/sh
{
  echo "-- 输入设备 --"
  dumpsys input 2>/dev/null | grep -E "Device [0-9]+:|Name:|Sources|Classes|Enabled" | head -n 40
  echo "-- 窗口配置里的 touchscreen (finger = 认到了; -touch = 还是没有) --"
  dumpsys window displays 2>/dev/null | grep -m 2 -E "overrideConfig|mCurrentFocus"
  echo "-- 前台 --"
  dumpsys activity activities 2>/dev/null | grep -m 2 -E "mResumedActivity|topResumedActivity"
} > /data/local/tmp/touchcheck.txt 2>&1
EOS
rm -f /android-data/local/tmp/touchcheck.txt
/home/root/propset "$AR/dev/socket/property_service" paper.exec "tc$(date +%s)" >/dev/null 2>&1
sleep 12
cat /android-data/local/tmp/touchcheck.txt 2>/dev/null || echo "(Android 没回应)"

echo
echo "== 7. 桥的帧计数 (重启框架后应该有新帧) =="
grep "coalesced frame" /android-data/local/tmp/native-epd-bridge.log 2>/dev/null | tail -n 3 | cut -c1-190

echo
echo "补过东西: $FIXED (1 = 确实缺了, 这就是原因)"
echo "=== 结束: 现在请在设备上点一下屏幕, 看画面动不动 ==="
