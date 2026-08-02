#!/bin/sh
# rmkit-cn 启动预检 (fail-open 核心) — xochitl.service ExecStartPre=- 调用
# 部署路径: /home/root/rmkit-cn/bin/precheck.sh
#
# 职责: 每次 xochitl 启动前决定"本次注入什么"。任何检查不过 → 摘除对应注入,
# xochitl 以原生状态启动 (功能暂时缺失但绝不砖)。对应 6 次砖机复盘的全部根因。
#
# fail-open 机制:
#   drop-in 的 LD_PRELOAD 指向 /home/root/rmkit-cn/active/*.so (symlink)。
#   预检通过 → symlink 指向真实 .so; 不通过 → 删 symlink → glibc 对不存在的
#   LD_PRELOAD 条目 warn+skip → xochitl 纯原生启动。
#   /home 未挂载时本脚本不存在 (ExecStartPre=- 忽略) 且 symlink 不存在 → 同样安全。
#
# 本脚本必须:
#   - POSIX sh (BusyBox ash 兼容), 不依赖 bash
#   - 永远 exit 0 (即使内部错误; ExecStartPre=- 是第二道保险)
#   - 版本无关: 不 hardcode 任何固件相关内容

RMKIT=/home/root/rmkit-cn
XOVI=/home/root/xovi
DEPLOY=$XOVI/exthome/qt-resource-rebuilder
ACTIVE=$RMKIT/active
QUAR=$RMKIT/quarantine
STATUS=$RMKIT/inject-status.json
HASHTAB=$DEPLOY/hashtab
HASHTAB_FW=$DEPLOY/hashtab.fw_version
QMD_TOOL=$RMKIT/bin/qmd-tool
STARTS=$RMKIT/.starts
FUSE=$RMKIT/.fuse_tripped

FW=$(cat /etc/version 2>/dev/null)
NOW=$(date +%s)

mkdir -p "$ACTIVE" "$QUAR" 2>/dev/null

# 写状态 JSON (upload-server 网页展示; 单行, 无外部 json 工具依赖)
write_status() { # $1=mode $2=reason $3=quarantined(逗号分隔)
    printf '{"ts":%s,"fw":"%s","mode":"%s","reason":"%s","quarantined":"%s"}\n' \
        "$NOW" "$FW" "$1" "$2" "$3" > "$STATUS" 2>/dev/null
}

# 摘除全部注入, 本次完全原生启动。
# 只用于 crashloop 熔断 —— 崩的原因可能就是运行时注入自己, 熔断必须一视同仁。
disable_all() { # $1=reason
    rm -f "$ACTIVE"/*.so 2>/dev/null
    rm -f "$DEPLOY"/*.qmd 2>/dev/null
    write_status disabled "$1" ""
    echo "[precheck] DISABLED: $1 — xochitl 将以原生状态启动" >&2
    exit 0
}

# ── 运行时 QML 注入 (qml_inject): 与 qmldiff 链完全解耦 ──────────
# 瘦 hook 不链 Qt、不读 hashtab、不经 qmldiff、不扫 extensions.d —— 它往活的
# QML 场景树插节点。所以 qmldiff 侧任何不健康 (hashtab 不匹配 / qmd 坏 / xovi
# 没装) 都不该连坐它: 旧行为是 disable_all 一起摘, OTA 后等 fw-upgrade 重编
# hashtab 的窗口期里所有功能一起消失 ("暂时英文"); 现在这几项能继续用。
# 只有 armv7 (rm2) 没有这个产物 → 下面全部静默跳过, 那些功能继续走 qmd。
#
# MIGRATED_QMDS / qml_inject_ready 与 fw-upgrade.sh 共享同一真相源。lib 缺失
# (老版本升上来 / 部署残缺) 时用内联 fallback —— 本脚本契约是永远 exit 0。
RMKIT_LIB_BASE=$RMKIT
if [ -f "$RMKIT/bin/qml-inject-lib.sh" ]; then
    . "$RMKIT/bin/qml-inject-lib.sh" 2>/dev/null
fi
if [ -z "${MIGRATED_QMDS:-}" ]; then
    MIGRATED_QMDS="advanced_panel.qmd ai_text_button.qmd glyph_selection_ai.qmd language_zh_cn.qmd pinyin_interceptor.qmd"
    qml_inject_ready() {
        [ -f "$RMKIT/bin/qml_inject.so" ] && [ -f "$RMKIT/bin/qml_inject_impl.so" ] &&
            [ -f "$RMKIT/bin/adv_panel.qml" ] && [ -f "$RMKIT/bin/pinyin_ime.qml" ]
    }
fi

# 摘掉运行时注入已接管功能对应的 qmd (否则同一功能双注入)。幂等。
# 必须在步 6 逐个 verify 之前跑一次: 否则这些 qmd 在 hash 不命中时会被"隔离"进
# quarantine 并计入告警, 而它们其实早已无用 — 白报警 + 堆垃圾文件。
prune_migrated_qmds() {
    for q in $MIGRATED_QMDS; do
        rm -f "$DEPLOY/$q" 2>/dev/null
    done
}

# 挂运行时注入 + 摘已迁移 qmd
enable_qml_inject() {
    qml_inject_ready || return 1
    ln -sf "$RMKIT/bin/qml_inject.so" "$ACTIVE/qml_inject.so" 2>/dev/null
    prune_migrated_qmds
    return 0
}

# 摘除 qmldiff 注入链 (xovi + 全部 qmd), 但保留运行时注入。
# 取代原先这些场景下的 disable_all。
# ime_hook 的取舍: 它是纯 LD_PRELOAD hook, 不读 hashtab、与 qmldiff 无关。
#   - 运行时注入可用 (含已迁移的拼音候选框 pinyin_ime.qml) → 保留 ime_hook,
#     IME 在降级窗口尽可能继续可用 (zh 键盘布局若因 xovi 摘除而缺失, IME 只是
#     不激活, 无害)。
#   - 运行时注入不可用 (rm2 未部署产物) → 一起摘: 候选框 UI 还靠 qmd, 只留
#     hook 会变成"能拦按键但没候选框"的半残。
disable_qmldiff() { # $1=reason
    rm -f "$ACTIVE"/*.so 2>/dev/null
    rm -f "$DEPLOY"/*.qmd 2>/dev/null
    if enable_qml_inject; then
        [ -f "$RMKIT/bin/ime_hook.so" ] &&
            ln -sf "$RMKIT/bin/ime_hook.so" "$ACTIVE/ime_hook.so" 2>/dev/null
        write_status degraded "$1" "(qmd: all)"
        echo "[precheck] DEGRADED: $1 — qmldiff 注入已摘, 运行时 QML 注入保留" >&2
    else
        write_status disabled "$1" ""
        echo "[precheck] DISABLED: $1 — xochitl 将以原生状态启动" >&2
    fi
    exit 0
}

# ── 0. crash 熔断 ────────────────────────────────────────────
# 每次启动记时间戳; 600 秒内第 3 次启动 = crashloop → 熔断。
# 熔断标记 (.fuse_tripped) 由 fw-upgrade.sh 成功后 / install.sh / 用户手动清除。
# 稳定运行 120 秒后后台清空计数, 正常的偶发 restart 不会累积。
# 调试逃生口: touch /tmp/rmkit-no-fuse (tmpfs, 重启自动消失)
if [ ! -f /tmp/rmkit-no-fuse ]; then
    [ -f "$FUSE" ] && disable_all "fuse-tripped ($(cat "$FUSE" 2>/dev/null))"
    echo "$NOW" >> "$STARTS" 2>/dev/null
    RECENT=$(awk -v n="$NOW" 'n-$1<600' "$STARTS" 2>/dev/null | wc -l)
    if [ "$RECENT" -ge 3 ] 2>/dev/null; then
        echo "crashloop@$NOW fw=$FW" > "$FUSE"
        disable_all "crashloop (${RECENT}次/600s)"
    fi
    # 稳定 120s → 清计数 (nohup 脱离, 同 cgroup 存活至服务 stop)
    ( sleep 120; pidof xochitl >/dev/null 2>&1 && : > "$STARTS" ) >/dev/null 2>&1 &
fi

# ── 1. 从版本缓存重建 deploy 目录 (原 reenable.sh ExecStartPre 逻辑) ──
CACHE=$RMKIT/compiled-qmd/$FW
rm -f "$DEPLOY"/*.qmd 2>/dev/null
if [ -d "$CACHE" ] && ls "$CACHE"/*.qmd >/dev/null 2>&1; then
    cp "$CACHE"/*.qmd "$DEPLOY/" 2>/dev/null
fi
# cache 里仍带着已迁移功能的 qmd (老版本装的 / OTA 重编产出), 运行时注入可用时
# 立刻摘掉, 别让它们走到步 6 的 verify 去白白隔离报警。
qml_inject_ready && prune_migrated_qmds

# ── 2. 固件变化 → 后台触发重编 ──────────────────────────────────
# 不能直接 nohup fork: precheck 跑在 xochitl.service 的 cgroup 里, fw-upgrade
# 中途会 systemctl stop xochitl → systemd 按 cgroup 杀进程 → fw-upgrade 自杀,
# hashtab 永远生成不了 (2026-07-24 首次真实 OTA 实战踩坑)。
# 用 systemd-run 创建独立 transient unit (顺带隔离 LD_PRELOAD 环境不刷 ld.so 报错)。
LAST=$(cat "$RMKIT/.last_fw_version" 2>/dev/null)
if [ -n "$FW" ] && [ "$FW" != "$LAST" ] && [ -x "$RMKIT/bin/fw-upgrade.sh" ]; then
    if ! pgrep -f fw-upgrade.sh >/dev/null 2>&1; then
        if command -v systemd-run >/dev/null 2>&1; then
            systemd-run --unit=rmkit-cn-fwupgrade --collect \
                /bin/sh -c "exec bash $RMKIT/bin/fw-upgrade.sh >/tmp/fw-upgrade.log 2>&1" \
                >/dev/null 2>&1 || true
        else
            nohup bash "$RMKIT/bin/fw-upgrade.sh" >/tmp/fw-upgrade.log 2>&1 &
        fi
    fi
fi

# ── 3. hashtab 必须匹配当前固件 (防: 旧 hashtab + 新固件 → qmldiff panic) ──
[ -f "$HASHTAB" ] || disable_qmldiff "hashtab-missing"
HTFW=$(cat "$HASHTAB_FW" 2>/dev/null)
[ "$HTFW" = "$FW" ] || disable_qmldiff "hashtab-mismatch (hashtab=$HTFW fw=$FW, 等 fw-upgrade 重编)"

# ── 4. 依赖 .so 齐全 (防: LD_PRELOAD 半残 / xovi 没装) ──────────
for so in "$XOVI/xovi.so" "$RMKIT/bin/ime_hook.so"; do
    [ -f "$so" ] || disable_qmldiff "missing-so ($so)"
done

# ── 5. extensions.d 干净 (防: 同名 .bak → xovi 重名 fatal → 回滚) ──
if [ -d "$XOVI/extensions.d" ]; then
    for f in "$XOVI/extensions.d"/*; do
        [ -e "$f" ] || continue
        case "$f" in
            *.so|*.so.conf) ;;
            *) disable_qmldiff "extensions-dirty ($(basename "$f") 不是 .so/.so.conf, 会触发 xovi 重名 fatal)" ;;
        esac
    done
fi

# ── 6. qmd 逐个校验, 坏的隔离好的保留 (分级注入) ────────────────
QUAR_LIST=""
if [ -x "$QMD_TOOL" ]; then
    for q in "$DEPLOY"/*.qmd; do
        [ -f "$q" ] || continue
        if ! "$QMD_TOOL" verify -hashtab "$HASHTAB" "$q" >/dev/null 2>&1; then
            base=$(basename "$q")
            mv "$q" "$QUAR/$base.$FW.$NOW" 2>/dev/null
            QUAR_LIST="${QUAR_LIST}${QUAR_LIST:+,}$base"
            echo "[precheck] 隔离 $base (verify 失败)" >&2
        fi
    done
else
    # qmd-tool 缺失: 无法逐个校验, 保守起见全部不注入 qmd (xovi 本体仍可挂)
    rm -f "$DEPLOY"/*.qmd 2>/dev/null
    QUAR_LIST="(all: qmd-tool missing)"
fi

# ── 7. 全部通过 → 建 symlink, 注入生效 ──────────────────────────
ln -sf "$XOVI/xovi.so" "$ACTIVE/xovi.so" 2>/dev/null
ln -sf "$RMKIT/bin/ime_hook.so" "$ACTIVE/ime_hook.so" 2>/dev/null
# 运行时注入: 产物齐了才挂 (瘦 hook 找不到胖库不会崩, 但没意义), 顺带摘掉
# 它已接管功能的 qmd。armv7 无产物 → 返回非 0, 那些 qmd 原样保留继续生效。
if enable_qml_inject; then
    RT_NOTE="runtime-qml=on (已摘 qmd: $MIGRATED_QMDS)"
else
    RT_NOTE="runtime-qml=off (无产物, qmd 路径生效)"
fi
# ── 8. 恢复字体 alias ────────────────────────────────────────────
# /etc 是 upperdir 在 tmpfs (/var/volatile) 上的 overlay —— 写进去当场生效,
# 一重启整层蒸发。字体文件本身在 /home 下没事, 但让它生效的 fontconfig alias
# 没了, 表现为"重启后字体变回默认, 要去高级面板重新应用一次"。
# 应用字体时 upload-server 会在 $RMKIT/etc/ 留一份持久副本, 这里拷回去即可。
# 必须在 xochitl 启动**前**做: 晚了字体已经解析完, 补上也要等下次重启。
FONT_ALIAS_SRC=$RMKIT/etc/99-rmkit-cn-user-font.conf
FONT_ALIAS_DST=/etc/fonts/conf.d/99-rmkit-cn-user-font.conf
if [ -f "$FONT_ALIAS_SRC" ] && [ ! -f "$FONT_ALIAS_DST" ]; then
    mkdir -p /etc/fonts/conf.d 2>/dev/null
    if cp "$FONT_ALIAS_SRC" "$FONT_ALIAS_DST" 2>/dev/null; then
        # /var/cache 同样是 tmpfs overlay, 缓存每次开机都是空的, 必须重建一次,
        # 否则 fontconfig 读不到刚拷回来的 alias。
        command -v fc-cache >/dev/null 2>&1 && fc-cache -f >/dev/null 2>&1
        echo "[precheck] 已恢复字体 alias" >&2
    fi
fi

# ── 9. 自启 symlink 自愈 ─────────────────────────────────────────
# /etc/systemd/system/multi-user.target.wants/ 同样在 tmpfs overlay 上。
# 正常情况下 reenable.sh 已把 symlink 双写到底层, 这里只是兜底: 万一底层那份
# 丢了 (OTA / 手工 systemctl disable / 装了旧版脚本), 至少让本次开机把服务拉起来,
# 而不是等用户发现"中文和上传服务都没了"。
# 用 --no-block: ExecStartPre 里同步调 systemctl start 会和当前事务互等死锁。
for u in rmkit-cn-upload.service rmkit-cn-ime-http.service; do
    [ -f "/etc/systemd/system/$u" ] || continue
    if [ ! -e "/etc/systemd/system/multi-user.target.wants/$u" ]; then
        mkdir -p /etc/systemd/system/multi-user.target.wants 2>/dev/null
        ln -sf "/etc/systemd/system/$u" "/etc/systemd/system/multi-user.target.wants/$u" 2>/dev/null
        echo "[precheck] 自启 symlink 缺失, 已补建: $u" >&2
    fi
    systemctl is-active "$u" >/dev/null 2>&1 || systemctl start --no-block "$u" 2>/dev/null
done

write_status ok "" "$QUAR_LIST"
echo "[precheck] OK fw=$FW quarantined=[${QUAR_LIST:-无}] $RT_NOTE" >&2
exit 0
