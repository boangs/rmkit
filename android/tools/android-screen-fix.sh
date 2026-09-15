#!/bin/sh
# rmkit 单槽 Android 热修: "不插线进 Android 一会儿就卡死、按电源键没反应"
# 原因: Android 的亮屏超时设置 (screen_off_timeout 等) 由 paper-tuning.sh 在开机后写入, settings 服务起得慢时
# 首次写入会静默失败, 超时停在默认值 → 到点 Android 熄屏, 墨水屏停在最后一帧, 触摸无反应。插着线时 Android 有
# "充电时保持唤醒" 兜底所以不死。修法: 写后读回校验, 失败重试。
# 用法 (reMarkable 模式或 Android 模式都行):  ssh root@10.11.99.1 'sh -s' < android-screen-fix.sh
for F in /home/root/android-system/system/bin/paper-tuning.sh /android/system/bin/paper-tuning.sh; do
  [ -f "$F" ] || continue
  if grep -q put_verified "$F"; then echo "已经修过: $F"; continue; fi
  cp "$F" "$F.bak-screenfix"
  sed -i 's|^\$S put system screen_off_timeout 2147483647$|put_verified() { for _t in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do $S put "$1" "$2" "$3" 2>/dev/null; [ "$($S get "$1" "$2" 2>/dev/null)" = "$3" ] \&\& { echo "ok $1 $2=$3"; return 0; }; sleep 3; done; echo "FAIL $1 $2"; return 1; }\nput_verified system screen_off_timeout 2147483647|; s|^\$S put secure sleep_timeout -1$|put_verified secure sleep_timeout -1|; s|^\$S put global stay_on_while_plugged_in 3$|put_verified global stay_on_while_plugged_in 3|' "$F"
  echo "已修: $F ($(grep -c put_verified "$F") 处)"
done
echo "下次进 Android 生效。若正在 Android 里, 可立即补写一次:"
if [ -d /android ] && [ "$(cat /proc/1/comm)" != systemd ]; then
  cat > /android-data/local/tmp/exec.sh <<'EOS'
#!/system/bin/sh
S=/system/bin/settings
$S put system screen_off_timeout 2147483647; $S put secure sleep_timeout -1; $S put global stay_on_while_plugged_in 3
echo "now: screen_off_timeout=$($S get system screen_off_timeout) sleep_timeout=$($S get secure sleep_timeout)" > /data/local/tmp/screenfix.txt
EOS
  ADBD=""; for _p in /proc/[0-9]*; do [ "$(cat $_p/comm 2>/dev/null)" = "adbd" ] && ADBD=${_p#/proc/} && break; done; [ -n "$ADBD" ] && /home/root/propset /proc/$ADBD/root/dev/socket/property_service paper.exec "fix$(date +%s)" >/dev/null 2>&1; sleep 5; cat /android-data/local/tmp/screenfix.txt 2>/dev/null
fi
