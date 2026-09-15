#!/bin/sh
# android-sf-diag.sh — 「进 Android 一会儿画面定格」深挖诊断
#
# 前一轮诊断已经排除了熄屏与整机休眠 (亮屏设置已生效、mWakefulness=Awake、内核 suspend 次数为 0),
# 真正的现象是 Android 的画面合成器 surfaceflinger 在开机几十秒后没了, 显示桥收不到新帧 → 画面定格。
# 本脚本专门抓"它为什么死、有没有被内存杀掉、init 还在不在、上层是不是在反复重启"。
#
# 用法 (在电脑上, 设备处于"已经定格"的 Android 里, 插上数据线):
#   ssh -i <助手密钥> root@10.11.99.1 'sh -s' < android-sf-diag.sh > sf-diag.txt
set -u

echo "== 时间 / 电源 =="
date
echo "uptime=$(cut -d' ' -f1 /proc/uptime)s"
echo "charger_online=$(cat /sys/class/power_supply/max77818-charger/online 2>/dev/null)"
for b in /sys/class/power_supply/*battery*/capacity; do [ -f "$b" ] && echo "battery=$(cat "$b")%"; done
echo "autosleep=$(cat /sys/power/autosleep 2>/dev/null) suspend_ok/fail=$(cat /sys/power/suspend_stats/success 2>/dev/null)/$(cat /sys/power/suspend_stats/fail 2>/dev/null)"

echo
echo "== 关键进程 (0 = 已经死了) =="
PROCS=" rm-android-init rm-epd-bridge rm-touch-relay rm-native-controls init surfaceflinger zygote64 zygote system_server adbd lmkd servicemanager hwservicemanager vold logd "
ALL=""
for d in /proc/[0-9]*; do
  c=$(cat "$d/comm" 2>/dev/null) || continue
  ALL="$ALL $c"
done
for p in $PROCS; do
  n=0
  for c in $ALL; do [ "$c" = "$p" ] && n=$((n + 1)); done
  echo "$p=$n"
done
echo "-- 占内存最多的 10 个进程 (KB) --"
for d in /proc/[0-9]*; do
  rss=$(awk '/^VmRSS/{print $2}' "$d/status" 2>/dev/null)
  [ -n "$rss" ] && echo "$rss $(cat "$d/comm" 2>/dev/null)"
done | sort -rn | head -n 10

echo
echo "== 内存 =="
grep -E "^(MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree|Committed_AS)" /proc/meminfo 2>/dev/null
cat /proc/pressure/memory 2>/dev/null

echo
echo "== 内核日志: 被杀 / OOM / 合成器 / init 重启服务 =="
if [ -f /native-kmsg.log ]; then
  echo "zygote 启动次数=$(grep -c "starting service 'zygote'" /native-kmsg.log 2>/dev/null)"
  echo "surfaceflinger 启动次数=$(grep -c "surfaceflinger" /native-kmsg.log 2>/dev/null)"
  sed 's/^[0-9]*,[0-9]*,\([0-9]*\),-;/\1 /' /native-kmsg.log \
    | grep -iE "out of memory|oom-kill|killed process|lowmemory|surfaceflinger|hwcomposer|init: Service|init: cannot|reboot|panic|Oops|watchdog|thermal|throttl" \
    | tail -n 50
else
  echo "(没有 /native-kmsg.log)"
fi

echo
echo "== 显示桥日志尾 (最后一帧的时间 = 画面定格的时刻) =="
tail -n 20 /android-data/local/tmp/native-epd-bridge.log 2>/dev/null | cut -c1-190

echo
echo "== 开机包装日志尾 =="
tail -n 25 /native-boot.log 2>/dev/null

echo
echo "== Android 内部 (经 paper.exec 通道, 等 12 秒) =="
if [ -d /android ]; then
  cat > /android-data/local/tmp/exec.sh <<'EOS'
#!/system/bin/sh
{
  echo "-- init 服务状态 --"
  getprop | grep -E "init\.svc\.(surfaceflinger|zygote|system_server|adbd|vendor\.)|sys\.boot_completed|sys\.sysctl|ro\.build\.version\.release"
  echo "-- 崩溃缓冲区 (最后 100 行) --"
  logcat -d -b crash -t 100 2>/dev/null | tail -n 100
  echo "-- 主日志: 合成器 / 致命 / 被杀 (最后 60 条) --"
  logcat -d -t 800 2>/dev/null | grep -iE "surfaceflinger|composer|FATAL|died|Watchdog|lmkd|am_proc_died|am_crash|Reason" | tail -n 60
  echo "-- tombstones --"
  ls -l /data/tombstones 2>/dev/null | tail -n 8
  echo "-- ANR --"
  ls -l /data/anr 2>/dev/null | tail -n 5
  echo "-- HOME 应用解析 (空 = 桌面缺失) --"
  cmd package resolve-activity -c android.intent.category.HOME -a android.intent.action.MAIN 2>/dev/null | head -n 12
  echo "-- 显示状态 --"
  dumpsys window displays 2>/dev/null | head -n 12
} > /data/local/tmp/sfdiag.txt 2>&1
EOS
  rm -f /android-data/local/tmp/sfdiag.txt
  ADBD=""
  for _p in /proc/[0-9]*; do
    [ "$(cat "$_p/comm" 2>/dev/null)" = "adbd" ] && ADBD=${_p#/proc/} && break
  done
  if [ -n "$ADBD" ]; then
    /home/root/propset "/proc/$ADBD/root/dev/socket/property_service" paper.exec "sf$(date +%s)" >/dev/null 2>&1
    sleep 12
    cat /android-data/local/tmp/sfdiag.txt 2>/dev/null || echo "(Android 侧没有回应: 命令通道也死了)"
  else
    echo "(找不到 adbd: Android 上层已经整个没了)"
  fi
else
  echo "(当前不是 Android 模式, 请在 Android 里跑)"
fi
echo
echo "=== 结束 ==="
