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

# 摘除全部注入, 本次原生启动
disable_all() { # $1=reason
    rm -f "$ACTIVE"/*.so 2>/dev/null
    rm -f "$DEPLOY"/*.qmd 2>/dev/null
    write_status disabled "$1" ""
    echo "[precheck] DISABLED: $1 — xochitl 将以原生状态启动" >&2
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
[ -f "$HASHTAB" ] || disable_all "hashtab-missing"
HTFW=$(cat "$HASHTAB_FW" 2>/dev/null)
[ "$HTFW" = "$FW" ] || disable_all "hashtab-mismatch (hashtab=$HTFW fw=$FW, 等 fw-upgrade 重编)"

# ── 4. 依赖 .so 齐全 (防: LD_PRELOAD 半残 / xovi 没装) ──────────
for so in "$XOVI/xovi.so" "$RMKIT/bin/ime_hook.so"; do
    [ -f "$so" ] || disable_all "missing-so ($so)"
done

# ── 5. extensions.d 干净 (防: 同名 .bak → xovi 重名 fatal → 回滚) ──
if [ -d "$XOVI/extensions.d" ]; then
    for f in "$XOVI/extensions.d"/*; do
        [ -e "$f" ] || continue
        case "$f" in
            *.so|*.so.conf) ;;
            *) disable_all "extensions-dirty ($(basename "$f") 不是 .so/.so.conf, 会触发 xovi 重名 fatal)" ;;
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
write_status ok "" "$QUAR_LIST"
echo "[precheck] OK fw=$FW quarantined=[${QUAR_LIST:-无}]" >&2
exit 0
