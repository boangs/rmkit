#!/bin/sh
# android-touch-heal.sh — 装一个「触摸自愈」开机服务, 根治"进 Android 画面定格"
#
# 诊断结论 (三轮日志):
#   - 触摸节点与 IDC 配置在磁盘上都在, 什么都不缺 (touch-fix 显示"补过东西: 0");
#   - 但出故障那次 Android 的窗口配置里是 -touch, 即 Android 的输入系统没认到触摸屏;
#   - 一旦重启 Android 框架 (stop; start), 触摸立刻恢复, 画面也恢复刷新。
#   → 这是启动时序竞态: Android 的 InputReader 第一次枚举输入设备时没拿到中继设备,
#     之后就不会再回扫。插着数据线开机时时序不同, 刚好躲开, 所以"插线就不死"。
#
# 修法: 在 Android 里装一个开机后自检的服务。开机完成 25 秒后看一眼窗口配置,
#       只有真的没认到触摸屏时才重启一次框架 (约一分钟), 正常启动什么都不做。
#       用属性做一次性标记, 不会反复重启。
#
# 用法 (reMarkable 模式或 Android 模式都行, 建议在 reMarkable 模式下跑):
#   ssh -i <助手密钥> root@10.11.99.1 'sh -s' < android-touch-heal.sh
set -u

HEAL_SH='#!/system/bin/sh
# 触摸自愈: 开机后确认 Android 真的认到了触摸屏, 没认到就重启一次框架。
# 由 paper-touchheal.rc 在 sys.boot_completed=1 时拉起。
[ "$(getprop paper.touchheal.done)" = "1" ] && exit 0
sleep 25
CFG=$(dumpsys window displays 2>/dev/null | grep -m1 overrideConfig)
setprop paper.touchheal.done 1
case "$CFG" in
  *-touch*)
    log -t paper-touchheal "no touchscreen in config, restarting framework: $CFG"
    echo "$(date) no touchscreen, restarting framework" >> /data/local/tmp/paper-touchheal.log
    stop
    sleep 3
    start
    ;;
  *)
    log -t paper-touchheal "touchscreen ok"
    echo "$(date) touchscreen ok: $CFG" >> /data/local/tmp/paper-touchheal.log
    ;;
esac
'

HEAL_RC='service paper-touchheal /system/bin/sh /system/bin/paper-touchheal.sh
    class late_start
    user root
    group root log
    oneshot
    disabled

on property:sys.boot_completed=1
    start paper-touchheal
'

n=0
for BASE in /home/root/android-system /android; do
  [ -d "$BASE/system/bin" ] || continue
  printf '%s' "$HEAL_SH" > "$BASE/system/bin/paper-touchheal.sh" 2>/dev/null || { echo "写不进 $BASE (只读?)"; continue; }
  chmod 0755 "$BASE/system/bin/paper-touchheal.sh"
  mkdir -p "$BASE/system/etc/init" 2>/dev/null
  printf '%s' "$HEAL_RC" > "$BASE/system/etc/init/paper-touchheal.rc" 2>/dev/null
  chmod 0644 "$BASE/system/etc/init/paper-touchheal.rc" 2>/dev/null
  echo "已装: $BASE/system/bin/paper-touchheal.sh + etc/init/paper-touchheal.rc"
  n=$((n + 1))
done
[ "$n" = 0 ] && { echo "✗ 没找到 Android 系统目录, 什么都没做"; exit 1; }

echo
echo "下次开机生效。效果: 正常启动无感; 万一又没认到触摸, 开机约 90 秒后自己重启一次界面就能用。"
echo "自愈记录在 Android 的 /data/local/tmp/paper-touchheal.log (宿主路径 /android-data/local/tmp/paper-touchheal.log)。"

if [ -d /android ] && [ "$(cat /proc/1/comm)" != systemd ]; then
  echo
  echo "当前就在 Android 里, 立刻自检一次:"
  cat > /android-data/local/tmp/exec.sh <<'EOS'
#!/system/bin/sh
{ dumpsys window displays 2>/dev/null | grep -m1 overrideConfig; } > /data/local/tmp/touchnow.txt 2>&1
EOS
  ADBD=""
  for _p in /proc/[0-9]*; do
    [ "$(cat "$_p/comm" 2>/dev/null)" = "adbd" ] && ADBD=${_p#/proc/} && break
  done
  [ -n "$ADBD" ] && /home/root/propset "/proc/$ADBD/root/dev/socket/property_service" paper.exec "tn$(date +%s)" >/dev/null 2>&1
  sleep 6
  CFG=$(cat /android-data/local/tmp/touchnow.txt 2>/dev/null)
  echo "$CFG" | cut -c1-200
  case "$CFG" in
    *-touch*) echo "→ 当前这次启动没认到触摸屏 (下次开机会自愈)" ;;
    *finger*) echo "→ 当前这次启动认到触摸屏了, 正常" ;;
    *) echo "→ 读不到配置 (框架可能正在重启)" ;;
  esac
fi
