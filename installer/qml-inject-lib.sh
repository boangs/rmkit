# shellcheck shell=sh
# 运行时 QML 注入的共享判据 —— 被 precheck.sh 与 fw-upgrade.sh 同时 source。
# 部署路径: /home/root/rmkit-cn/bin/qml-inject-lib.sh
#
# 为什么要共享而不是各写一份: "哪些功能已由运行时注入接管"这个列表同时决定
#   ① precheck 启动时摘掉哪些 qmd (否则同一功能双注入)
#   ② fw-upgrade 在 OTA 后不把哪些 qmd 的编译失败当作"固件未适配"
# 两处漂移会直接导致功能重影或 OTA 恢复卡死, 所以只留一个真相源。
#
# 注意: source 方必须自带 fallback —— precheck.sh 的契约是"永远 exit 0", 不能
# 因为这个文件缺失 (老版本升级上来、部署残缺) 就炸。

RMKIT_LIB_BASE=${RMKIT_LIB_BASE:-/home/root/rmkit-cn}

# 已从 qmd 迁到运行时 QML 注入的功能, 对应的 qmd 文件名。
# pinyin_interceptor.qmd 不在此列 —— 拼音候选框仍走 qmldiff。
MIGRATED_QMDS="advanced_panel.qmd ai_text_button.qmd glyph_selection_ai.qmd language_zh_cn.qmd"

# 运行时注入产物是否齐全。缺任一项都当没有 —— 瘦 hook 找不到胖库不会崩, 但
# 功能不会生效, 此时必须让 qmd 路径继续负责 (rm2/armv7 永远走这条)。
qml_inject_ready() {
    [ -f "$RMKIT_LIB_BASE/bin/qml_inject.so" ] &&
        [ -f "$RMKIT_LIB_BASE/bin/qml_inject_impl.so" ] &&
        [ -f "$RMKIT_LIB_BASE/bin/adv_panel.qml" ]
}

# 某个 qmd 是否已被运行时注入接管 (仅在产物齐全时成立)
qmd_is_migrated() { # $1=qmd 文件名
    qml_inject_ready || return 1
    for _m in $MIGRATED_QMDS; do
        [ "$1" = "$_m" ] && return 0
    done
    return 1
}
