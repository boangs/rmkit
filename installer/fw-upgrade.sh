#!/bin/bash
# 固件升级后自动重编 qmd 并部署所有静态资源
# 触发条件：rmkit-cn-version.path 监听到 /etc/version 变化 → rmkit-cn-version.service 调用本脚本
FW_NOW=$(cat /etc/version 2>/dev/null)
FW_LAST=$(cat /home/root/rmkit-cn/.last_fw_version 2>/dev/null)
HASHTAB=/home/root/xovi/exthome/qt-resource-rebuilder/hashtab
QMD_DEPLOY=/home/root/xovi/exthome/qt-resource-rebuilder
QMD_TOOL=/home/root/rmkit-cn/bin/qmd-tool
QMD_SRC=/home/root/rmkit-cn/qmd-src
QMD_CACHE=/home/root/rmkit-cn/compiled-qmd
STATIC=/home/root/rmkit-cn/static

echo "[fw-upgrade] 当前版本: $FW_NOW / 上次版本: $FW_LAST"
[ "$FW_NOW" = "$FW_LAST" ] && echo "[fw-upgrade] 版本未变化，跳过" && exit 0

echo "[fw-upgrade] 固件版本变化: $FW_LAST → $FW_NOW"

switch_qmd() {
    local version="$1"
    local cache_dir="$QMD_CACHE/$version"
    if [ -d "$cache_dir" ] && ls "$cache_dir"/*.qmd >/dev/null 2>&1; then
        echo "[fw-upgrade] 使用缓存: $version"
        rm -f "$QMD_DEPLOY"/*.qmd
        cp "$cache_dir"/*.qmd "$QMD_DEPLOY/"
        return 0
    fi
    return 1
}

deploy_static() {
    echo "[fw-upgrade] 部署静态资源..."
    # pinyin_interceptor.qmd + zh_CN.rcc → qt-resource-rebuilder
    [ -f "$STATIC/pinyin_interceptor.qmd" ] && \
        cp "$STATIC/pinyin_interceptor.qmd" "$QMD_DEPLOY/" && echo "[fw-upgrade] ✓ pinyin_interceptor.qmd"
    [ -f "$STATIC/zh_CN.rcc" ] && \
        cp "$STATIC/zh_CN.rcc" "$QMD_DEPLOY/" && echo "[fw-upgrade] ✓ zh_CN.rcc"
    # reMarkable_zh_CN.qm → 系统翻译目录（RMPP overlayfs: 写上层 tmpfs, 重启前有效）
    if [ -f "$STATIC/reMarkable_zh_CN.qm" ]; then
        mount -o remount,rw / 2>/dev/null || true
        mkdir -p /usr/share/remarkable/xochitl/translations
        cp "$STATIC/reMarkable_zh_CN.qm" /usr/share/remarkable/xochitl/translations/
        echo "[fw-upgrade] ✓ reMarkable_zh_CN.qm"
    fi
}

# 有缓存且 hashtab 版本也匹配 → 直接用
# (hashtab 版本不匹配时不能走捷径: A/B 来回切固件时缓存 qmd 在但 hashtab 是另一版的,
#  qmldiff 会 Cached 0 entries → 孤儿 hash panic。此时落到下面完整流程重生成 hashtab)
if switch_qmd "$FW_NOW" && [ "$(cat "$HASHTAB.fw_version" 2>/dev/null)" = "$FW_NOW" ]; then
    deploy_static
    echo "$FW_NOW" > /home/root/rmkit-cn/.last_fw_version
    # 复位熔断 + 重建 symlink (同成功分支)
    rm -f /home/root/rmkit-cn/.fuse_tripped /home/root/rmkit-cn/.starts
    mkdir -p /home/root/rmkit-cn/active
    ln -sf /home/root/xovi/xovi.so /home/root/rmkit-cn/active/xovi.so
    ln -sf /home/root/rmkit-cn/bin/ime_hook.so /home/root/rmkit-cn/active/ime_hook.so
    systemctl start xochitl.service
    echo "[fw-upgrade] ✓ 完成 (命中缓存)"
    exit 0
fi

echo "[fw-upgrade] 无缓存，生成新 hashtab..."
rm -f "$QMD_DEPLOY"/*.qmd

# 用 QMLDIFF_HASHTAB_CREATE 强制 xochitl 生成新 hashtab
systemctl stop xochitl.service 2>/dev/null
START_TIME=$(date +%s)
echo "[fw-upgrade] 启动 xochitl 生成 hashtab (T=$START_TIME)..."
QMLDIFF_HASHTAB_CREATE="$HASHTAB" \
  QML_DISABLE_DISK_CACHE=1 \
  LD_PRELOAD=/home/root/xovi/xovi.so \
  /usr/bin/xochitl > /tmp/xochitl_hash.log 2>&1 &
XPID=$!

HASHTAB_FOUND=false
for i in $(seq 1 60); do
    if [ -f "$HASHTAB" ]; then
        MTIME=$(date +%s -r "$HASHTAB" 2>/dev/null || echo 0)
        SIZE=$(wc -c < "$HASHTAB" 2>/dev/null || echo 0)
        if [ "$MTIME" -gt "$START_TIME" ] && [ "$SIZE" -gt 10000 ]; then
            echo "[fw-upgrade] ✓ hashtab 已生成 (size=$SIZE)"
            HASHTAB_FOUND=true
            break
        fi
    fi
    sleep 5
done
kill $XPID 2>/dev/null; sleep 2

if [ "$HASHTAB_FOUND" = "false" ]; then
    echo "[fw-upgrade] 错误: hashtab 未生成，回退旧版本" >&2
    switch_qmd "$FW_LAST"
    deploy_static
    systemctl start xochitl.service
    exit 1
fi

# 标记 hashtab 对应的固件版本 (precheck.sh 启动前校验此标记 == /etc/version 才放行注入)
echo "$FW_NOW" > "$HASHTAB.fw_version"

# 编译到版本缓存
CACHE_NEW="$QMD_CACHE/$FW_NOW"
mkdir -p "$CACHE_NEW"
echo "[fw-upgrade] 编译 qmd..."
OK=true
for src in "$QMD_SRC"/*.qmd; do
    [ -f "$src" ] || continue
    base=$(basename "$src")
    # 3.28 (build 20260629+) 重构了 Sidebar QML, 老固件用 compat 旧语法源 (输出名不变)
    if [ "$base" = "advanced_panel.qmd" ] \
       && [ "$FW_NOW" -lt 20260629000000 ] 2>/dev/null \
       && [ -f "$QMD_SRC/compat/advanced_panel@pre-3.28.qmd" ]; then
        src="$QMD_SRC/compat/advanced_panel@pre-3.28.qmd"
        echo "[fw-upgrade] (固件 $FW_NOW < 3.28, advanced_panel 用 compat 源)"
    fi
    if "$QMD_TOOL" hash -hashtab "$HASHTAB" "$src" > "$CACHE_NEW/$base.tmp" 2>/dev/null; then
        mv "$CACHE_NEW/$base.tmp" "$CACHE_NEW/$base"
        echo "[fw-upgrade] ✓ $base"
    else
        rm -f "$CACHE_NEW/$base.tmp"
        echo "[fw-upgrade] ✗ $base 失败" >&2
        OK=false
    fi
done

if [ "$OK" = "false" ]; then
    rm -rf "$CACHE_NEW"
    echo "[fw-upgrade] 编译失败，回退旧版本" >&2
    switch_qmd "$FW_LAST"
    deploy_static
    systemctl start xochitl.service
    exit 1
fi

switch_qmd "$FW_NOW"
deploy_static
echo "$FW_NOW" > /home/root/rmkit-cn/.last_fw_version

# 重编成功 = 新固件已适配: 复位熔断 + 重建 active symlink, 让 precheck 重新放行注入
# (这是 "OTA 后 precheck 摘除注入 → fw-upgrade 自动重编 → 自动恢复" 闭环的最后一环)
rm -f /home/root/rmkit-cn/.fuse_tripped /home/root/rmkit-cn/.starts
mkdir -p /home/root/rmkit-cn/active
ln -sf /home/root/xovi/xovi.so /home/root/rmkit-cn/active/xovi.so
ln -sf /home/root/rmkit-cn/bin/ime_hook.so /home/root/rmkit-cn/active/ime_hook.so

systemctl start xochitl.service
echo "[fw-upgrade] ✓ 全部完成"
