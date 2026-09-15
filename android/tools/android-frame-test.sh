#!/bin/sh
# android-frame-test.sh — 判定「画面定格」到底卡在哪一段
#
# 上一轮已经确认: Android 上层是健康的 (boot_completed=1, 无崩溃/无 ANR, 桌面在前台,
# surfaceflinger 与 hwcomposer 都在跑), 但显示桥自开机以来只收到过 1 帧。
# 所以"死机"= 画面不再更新, 而不是系统死了。只剩两种可能, 本脚本分开验证:
#   A. Android 不产生新帧 (合成/HWC → 桥 这一段断了)
#   B. Android 产生帧但触摸压根没送进去 (触摸 → Android 这一段断了)
#
# 用法 (设备处于"定格"的 Android 里, 插数据线):
#   ssh -i <助手密钥> root@10.11.99.1 'sh -s' < android-frame-test.sh > frame-test.txt
# 脚本中途会提示"现在请用手指在屏幕上划几下", 看到提示后请在设备上划 10 秒。
set -u

BR=/android-data/local/tmp/native-epd-bridge.log
RELAY=/native-touch-relay.log

frames() { grep -c "coalesced frame" "$BR" 2>/dev/null || echo 0; }
counters() { grep "coalesced frame" "$BR" 2>/dev/null | tail -n 1 | sed 's/.*\(received=[0-9]*\).*\(displayed=[0-9]*\).*/\1 \2/' ; }
relaylines() { wc -l < "$RELAY" 2>/dev/null || echo 0; }

echo "== 起点 =="
date
echo "uptime=$(cut -d' ' -f1 /proc/uptime)s charger_online=$(cat /sys/class/power_supply/max77818-charger/online 2>/dev/null)"
echo "本次开机时是否插着线: $(grep -m1 'USB Type-C recovery' "$BR" 2>/dev/null | cut -c1-120)"
F0=$(frames); R0=$(relaylines)
echo "桥帧记录条数=$F0  计数器: $(counters)"
echo "触摸中继日志行数=$R0"

if [ ! -d /android ]; then echo "(当前不是 Android 模式)"; exit 0; fi

ADBD=""
for _p in /proc/[0-9]*; do
  [ "$(cat "$_p/comm" 2>/dev/null)" = "adbd" ] && ADBD=${_p#/proc/} && break
done
[ -z "$ADBD" ] && { echo "(找不到 adbd, 命令通道不可用)"; exit 0; }
poke() { /home/root/propset "/proc/$ADBD/root/dev/socket/property_service" paper.exec "ft$(date +%s)" >/dev/null 2>&1; }

echo
echo "== A: 从 Android 内部主动制造画面变化 (不碰触摸) =="
cat > /android-data/local/tmp/exec.sh <<'EOS'
#!/system/bin/sh
{
  echo "-- 变化前的前台 --"
  dumpsys activity activities 2>/dev/null | grep -m 2 -E "mResumedActivity|topResumedActivity"
  echo "-- 显示状态 --"
  dumpsys display 2>/dev/null | grep -m 6 -E "mScreenState|mDisplayState|state=|mBrightness"
  echo "-- SurfaceFlinger 层数 --"
  dumpsys SurfaceFlinger 2>/dev/null | grep -m 6 -E "Display 0|layers|Visible|refresh"
  echo "-- 发 HOME 键 --"; input keyevent KEYCODE_HOME; sleep 2
  echo "-- 打开设置 --"; am start -W -a android.settings.SETTINGS 2>&1 | head -n 5; sleep 3
  echo "-- 变化后的前台 --"
  dumpsys activity activities 2>/dev/null | grep -m 2 -E "mResumedActivity|topResumedActivity"
  echo "-- 模拟滑动 --"; input swipe 480 1200 480 500 300; sleep 2
  echo "-- 再发一次 HOME --"; input keyevent KEYCODE_HOME; sleep 2
} > /data/local/tmp/frametest-a.txt 2>&1
EOS
rm -f /android-data/local/tmp/frametest-a.txt
poke; sleep 16
cat /android-data/local/tmp/frametest-a.txt 2>/dev/null || echo "(Android 没回应)"
F1=$(frames)
echo "A 之后: 桥帧记录条数=$F1 (起点 $F0)  计数器: $(counters)"

echo
echo "== B: 请现在用手指在设备屏幕上连续划 10 秒 =="
echo "(脚本等 15 秒后继续)"
sleep 15
F2=$(frames); R2=$(relaylines)
echo "B 之后: 桥帧记录条数=$F2  计数器: $(counters)"
echo "触摸中继日志行数=$R2 (起点 $R0)"
echo "-- 触摸中继日志尾 --"
tail -n 6 "$RELAY" 2>/dev/null

echo
echo "== B2: Android 侧有没有收到那些触摸 =="
cat > /android-data/local/tmp/exec.sh <<'EOS'
#!/system/bin/sh
{
  echo "-- 输入设备 --"
  dumpsys input 2>/dev/null | grep -E "Device [0-9]+:|Name:|Sources|Enabled|KeyboardType" | head -n 40
  echo "-- 最近事件队列 --"
  dumpsys input 2>/dev/null | grep -A 10 -E "RecentQueue|Recent events" | head -n 24
  echo "-- 触摸相关统计 --"
  dumpsys input 2>/dev/null | grep -E "TouchStates|mTouchStates|Motion|DownTime" | head -n 10
} > /data/local/tmp/frametest-b.txt 2>&1
EOS
rm -f /android-data/local/tmp/frametest-b.txt
poke; sleep 12
cat /android-data/local/tmp/frametest-b.txt 2>/dev/null || echo "(Android 没回应)"

echo
echo "== 桥日志新增部分 =="
if [ "$F2" -gt "$F0" ]; then
  grep "coalesced frame" "$BR" | tail -n $((F2 - F0)) | cut -c1-190
else
  echo "(整个测试期间桥一帧都没收到)"
fi

echo
echo "== 判定 =="
if [ "$F1" -gt "$F0" ]; then
  echo "A 段通: Android 能产生新帧, 桥也能显示 → 问题在触摸没送到 Android (看 B 段)"
elif [ "$F2" -gt "$F0" ]; then
  echo "A 段不通但 B 段有帧: 只有真实触摸才出帧, 合成链路正常"
else
  echo "A 段与 B 段都没有新帧: Android 根本不再合成画面 (合成器/HWC → 桥 这一段的问题)"
fi
echo "=== 结束 ==="
