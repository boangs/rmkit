#!/system/bin/sh
# [rmkit] e-ink 上一切动画都是负担：过渡动画在墨水屏上只会拖慢响应且看不清
LOG=/data/local/tmp/paper-tuning.log
exec >> $LOG 2>&1
echo "=== $(date) tuning 开始 ==="

S=/system/bin/settings
# --- 动画与特效全部关闭 ---
$S put global window_animation_scale 0
$S put global transition_animation_scale 0
$S put global animator_duration_scale 0
$S put global disable_window_blurs 1
$S put secure accessibility_display_animation_scale 0
# --- 屏幕常亮（e-ink 不耗电，且唤醒要重刷整屏）---
$S put system screen_off_timeout 2147483647
$S put secure sleep_timeout -1
$S put global stay_on_while_plugged_in 3
# --- 关掉自动亮度/自适应（无背光屏无意义且耗 CPU）---
$S put system screen_brightness_mode 0
# --- 深色主题关闭（反射式墨水屏上深色=一片黑）---
for _i in 1 2 3 4 5 6 7 8; do
    $S put secure ui_night_mode 1 2>/dev/null
    [ "$($S get secure ui_night_mode 2>/dev/null)" = "1" ] && break
    sleep 3
done
/system/bin/cmd uimode night no 2>/dev/null
# --- 关掉触感反馈与音效（无马达无扬声器）---
$S put system haptic_feedback_enabled 0
$S put system sound_effects_enabled 0
# --- 关掉动态壁纸服务 ---
/system/bin/cmd wallpaper set-dim-amount 0 2>/dev/null
/system/bin/pm disable-user --user 0 com.android.systemui/.ImageWallpaper 2>/dev/null
# --- 记录结果 ---
echo "window_animation_scale=$($S get global window_animation_scale)"
echo "transition_animation_scale=$($S get global transition_animation_scale)"
echo "animator_duration_scale=$($S get global animator_duration_scale)"
echo "ui_night_mode=$($S get secure ui_night_mode)"
echo "当前 launcher: $(/system/bin/cmd package resolve-activity -c android.intent.category.HOME --user 0 2>/dev/null | grep -i packageName | head -n 1)"
echo "=== tuning 结束 ==="

# [rmkit] FrontlightGestureView 添加窗口时抛 IllegalStateException，
# 疑似残留一个非透明的全屏黑窗口盖住界面（触摸可穿透，故按钮仍生效）。
# 先禁用整个显示控制服务验证；代价是失去下滑调前光。
/system/bin/pm enable com.android.launcher3/.paper.DisplayControlService 2>&1
echo "DisplayControlService 已禁用"

# [rmkit] PaperHome 的导航栏是无障碍服务实现的，必须显式启用，
# 否则它画不出自家导航栏、露出系统导航栏，且主界面按错误边距布局。
NAV=com.android.launcher3/com.android.launcher3.paper.PaperNavigationAccessibilityService
/system/bin/settings put secure enabled_accessibility_services "$NAV"
/system/bin/settings put secure accessibility_enabled 1
echo "无障碍导航: $(/system/bin/settings get secure enabled_accessibility_services)"

# [rmkit] e-ink 配置：fast=快波形(约5ms)，mono=不做彩色稳定(免去2.2s等待+1.4s整屏重刷)
D=/data/data/com.android.launcher3/files
mkdir -p "$D"
echo -n balanced > "$D/paper-display-mode"
echo -n auto > "$D/paper-color-mode"
echo -n complete > "$D/paper-quality-profile-v1"
chown $(stat -c %u /data/data/com.android.launcher3):$(stat -c %g /data/data/com.android.launcher3) "$D"/paper-display-mode "$D"/paper-color-mode "$D"/paper-quality-profile-v1 2>/dev/null
echo "eink: $(cat $D/paper-display-mode)/$(cat $D/paper-color-mode)"

# [rmkit] 中文输入法：AOSP LatinIME 不支持中文，装 Trime（开源/离线/Rime 引擎/无 GMS 依赖）
# 签名从作者 key 换成 testkey（关硬件加速重打包），首次需卸载旧版
[ -f /data/local/tmp/.trime-swrender-done ] || { /system/bin/pm uninstall com.osfans.trime 2>/dev/null; touch /data/local/tmp/.trime-swrender-done; echo "Trime 旧版已卸载，将装 swrender 版"; }
if [ -f /data/local/tmp/Trime.apk ] && ! /system/bin/pm list packages 2>/dev/null | grep -q com.osfans.trime; then
    /system/bin/pm install -r -g /data/local/tmp/Trime.apk
    echo "Trime 安装: $?"
fi
if /system/bin/pm list packages 2>/dev/null | grep -q com.osfans.trime; then
    echo "--- trime pkg state ---"; /system/bin/dumpsys package com.osfans.trime 2>&1 | grep -E "stopped|enabled=|targetSdk|flags=|Service|InputMethod|pkgFlags" | head -n 15
    echo "--- ime list -a ---"; /system/bin/ime list -a 2>&1 | head -n 40
    for _w in $(seq 1 36); do /system/bin/ime list -a 2>/dev/null | grep -q "com.osfans.trime" && break; sleep 5; done
    echo "Trime 进入 IME 列表用时: $((_w*5))s"
    # Trime 要往 /sdcard/rime 写词库和主题，需 MANAGE_EXTERNAL_STORAGE（AppOps，pm grant 给不了）
    # Trime 默认把 build 写到 /sdcard/rime 但 FUSE 配额拒绝；改用户数据目录到应用私有外存
    U=$(stat -c %u /data/data/com.osfans.trime); mkdir -p /data/data/com.osfans.trime/shared_prefs; chown $U:$U /data/data/com.osfans.trime/shared_prefs; chmod 771 /data/data/com.osfans.trime/shared_prefs; P=/data/data/com.osfans.trime/shared_prefs/com.osfans.trime_preferences.xml; grep -q profile_user_data_dir $P 2>/dev/null || { mkdir -p $(dirname $P); printf x27<?xml version="1.0" encoding="utf-8" standalone="yes" ?>\n<map>\n    <string name="profile_user_data_dir">/storage/emulated/0/Android/data/com.osfans.trime/files</string>\n</map>\nx27 > $P; chown $(stat -c %u /data/data/com.osfans.trime):$(stat -c %u /data/data/com.osfans.trime) $P; }
    # 默认简体拼音（Trime 出厂是繁体的朙月拼音）
    R=/data/media/0/Android/data/com.osfans.trime/files; mkdir -p $R; [ -f $R/default.custom.yaml ] || { printf "patch:\n  schema_list:\n    - schema: luna_pinyin_simp\n    - schema: luna_pinyin\n" > $R/default.custom.yaml; chown $(stat -c %u /data/data/com.osfans.trime):$(stat -c %u /data/data/com.osfans.trime) $R/default.custom.yaml; }
    /system/bin/appops set com.osfans.trime MANAGE_EXTERNAL_STORAGE allow 2>&1
    /system/bin/appops set com.osfans.trime READ_EXTERNAL_STORAGE allow 2>&1
    /system/bin/appops set com.osfans.trime WRITE_EXTERNAL_STORAGE allow 2>&1
    echo "Trime 存储权限: $(/system/bin/appops get com.osfans.trime MANAGE_EXTERNAL_STORAGE 2>&1 | tail -n 1)"
    /system/bin/ime enable com.osfans.trime/.ime.core.TrimeInputMethodService 2>&1
    /system/bin/ime set com.osfans.trime/.ime.core.TrimeInputMethodService 2>&1
    echo "输入法: $(/system/bin/settings get secure default_input_method)"
fi

# [latency-probe] 开机 3 分钟后采一次 Trime 图层的帧延迟统计（用户此时大概率已在打字）

# gfx-probe: 90s 后采帧统计（setsid 脱离 oneshot）
echo "gfx-probe 启动 $(date)"; /system/bin/setsid /system/bin/sh /data/local/tmp/gfx-probe.sh >/data/local/tmp/gfx-probe.err 2>&1 &
/system/bin/appops set com.android.launcher3 SYSTEM_ALERT_WINDOW allow 2>/dev/null
# [auto-install-apps] /data/local/tmp/apps/*.apk 里未装的自动装（按包名判断，已装则跳过）
for _apk in /data/local/tmp/apps/*.apk; do
    [ -f "$_apk" ] || continue
    _pkg=$(/system/bin/aapt dump badging "$_apk" 2>/dev/null | grep -oE "package: name=\x27[^\x27]+" | cut -d"\x27" -f2)
    [ -z "$_pkg" ] && _pkg=$(basename "$_apk" .apk)
    [ -f "/data/local/tmp/apps/.installed-$(basename $_apk)" ] && continue
    /system/bin/pm install -r -g "$_apk" >/dev/null 2>&1 && { touch "/data/local/tmp/apps/.installed-$(basename $_apk)"; echo "已装 $(basename $_apk)"; } || echo "安装失败 $(basename $_apk)"
done

# [rmkit] 宿主 home 已由 rm-android-init 挂到 /data/media/0/rmppm-home (ro);
# vold 的 pass_through 是非递归 bind 不带子挂载, FUSE 守护进程看不到,
# 需在 Android 命名空间内补一次 bind (挂载传播 shared, 会进各应用命名空间)。
(
  for _i in $(seq 1 20); do
    if mountpoint -q /mnt/pass_through/0/emulated 2>/dev/null && [ -d /data/media/0/rmppm-home ]; then
      mountpoint -q /mnt/pass_through/0/emulated/0/rmppm-home 2>/dev/null || \
        mount -o bind /data/media/0/rmppm-home /mnt/pass_through/0/emulated/0/rmppm-home
      break
    fi
    sleep 3
  done
) &
