#!/bin/sh
# android-tree-check.sh — 对拍 Android 系统树与发布包 (v1.2.1 android-system.tar.gz)
#
# 背景: 原来的诊断只比对宿主侧那几个二进制, 没有比对 Android 系统树本身。
# IDC、init rc、hwcomposer、桌面 APK 全在树里, 旧版树会导致"进 Android 画面定格"这类问题。
# 本脚本只读不写, 两台机器各跑一次, 把输出发过来对比即可。
#
# 用法 (reMarkable 模式或 Android 模式都行):
#   ssh -i <助手密钥> root@10.11.99.1 'sh -s' < android-tree-check.sh > tree-check.txt
set -u

BASE=/home/root/android-system
[ -d "$BASE" ] || BASE=/android
echo "== 树根 = $BASE =="
echo "机器: $(cat /sys/firmware/devicetree/base/model 2>/dev/null | tr -d '\0')"
echo "固件: $(grep -m1 IMG_VERSION /usr/share/remarkable/update.conf 2>/dev/null || cat /etc/version 2>/dev/null)"
echo

# 发布包 v1.2.1 里的期望值 (由 android-system.tar.gz 算出)
exp_redroid_rc=ec115a11e54ca789fe9fdffb38bd30ec
exp_hwc=615b92d257c89d55a3dce6f92502106b
exp_idc_touch=7ad3fb6adcc8af4d19cce73fa91d31bc
exp_idc_marker=da21187d84a9e20bbed4a7e8d6c03158
exp_tuning=f3225cdcecabb75bc92061cd6a0d48d2

chk() { # chk <相对路径> <期望md5> <说明>
  f="$BASE/$1"
  if [ ! -f "$f" ]; then printf '%-52s 缺失          %s\n' "$1" "$3"; return; fi
  m=$(md5sum "$f" 2>/dev/null | cut -d' ' -f1)
  if [ "$m" = "$2" ]; then printf '%-52s 一致          %s\n' "$1" "$3"
  else printf '%-52s 不一致 %s  %s\n' "$1" "$m" "$3"; fi
}

echo "== 关键文件比对 =="
chk vendor/etc/init/redroid.common.rc      "$exp_redroid_rc" "容器 init 配置 (曾清空输入节点)"
chk vendor/lib64/hw/hwcomposer.redroid.so  "$exp_hwc"        "合成器 → 显示桥"
chk system/usr/idc/rm_Android_touch_relay.idc "$exp_idc_touch"  "触摸中继被当成触摸屏的依据"
chk system/usr/idc/Elan_marker_input.idc      "$exp_idc_marker" "笔被当成笔而不是鼠标的依据"
chk system/bin/paper-tuning.sh             "$exp_tuning"     "开机调优 (打过亮屏热修的会不一致, 正常)"

echo
echo "== IDC 目录清单 =="
ls -1 "$BASE/system/usr/idc/" 2>/dev/null | tr '\n' ' '; echo

echo
echo "== 容器 init rc 清单 (rmkit 自加的) =="
ls -1 "$BASE/system/etc/init/" 2>/dev/null | grep -i paper | tr '\n' ' '; echo
ls -1 "$BASE/vendor/etc/init/" 2>/dev/null | grep -iE "redroid|rmkit|paper" | tr '\n' ' '; echo

echo
echo "== rmkit 自带的 Android 侧文件 =="
for f in system/bin/paper-tuning.sh system/bin/paper-touchheal.sh system/bin/paper-adbfw.sh \
         system/etc/init/paper-touchheal.rc system/usr/idc/rm_Android_touch_relay.idc; do
  if [ -f "$BASE/$f" ]; then printf '%-46s %s  %s\n' "$f" "$(md5sum "$BASE/$f" | cut -d' ' -f1)" "$(stat -c %y "$BASE/$f" 2>/dev/null | cut -c1-19)"; fi
done

echo
echo "== 桌面与常驻 APK =="
for d in system/priv-app system/app system/product/app; do
  [ -d "$BASE/$d" ] || continue
  ls -1 "$BASE/$d" 2>/dev/null | grep -iE "launcher|paper|home|nav|statusbar" | while read -r a; do
    ap=$(ls "$BASE/$d/$a"/*.apk 2>/dev/null | head -n 1)
    [ -n "$ap" ] && printf '%-40s %s\n' "$d/$a" "$(md5sum "$ap" | cut -d' ' -f1)"
  done
done

echo
echo "== 宿主侧组件 (原诊断已覆盖, 这里记时间戳便于判断新旧) =="
for f in /home/root/rm-epd-bridge /home/root/rm-touch-relay /home/root/rm-android-init-ss \
         /home/root/rm-native-controls /home/root/boot-android.sh /home/root/propset; do
  [ -f "$f" ] && printf '%-34s %s  %s\n' "$(basename "$f")" "$(md5sum "$f" | cut -d' ' -f1)" "$(stat -c %y "$f" 2>/dev/null | cut -c1-19)"
done

echo
echo "== Android 数据分区里可能覆盖系统的东西 =="
ls -1 /android-data/local/tmp/ 2>/dev/null | head -n 20 | tr '\n' ' '; echo
echo "=== 结束 ==="
