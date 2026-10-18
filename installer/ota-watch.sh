#!/bin/sh
# rmkit-cn OTA hook — "跟随官方升级, 无需重装" 的核心
# 部署路径: /home/root/rmkit-cn/bin/ota-watch.sh
# 由 rmkit-cn-ota.timer 每 5 分钟调用 (oneshot)
#
# 原理: 官方 OTA 流程是 swupdate 把新固件完整写入 inactive slot → 置
# /sys/devices/platform/lpgpr/swu_status=1 → 用户重启时 rm-apply-ota 才切换分区。
# "新固件落盘后、重启前" 是任意长的窗口期: 此时 mount inactive 分区, 把当前
# 正在运行的 rmkit-cn systemd 配置原样拷进新 rootfs 的 /etc (磁盘上的 /etc 即
# overlay lower, 新系统启动后直接生效)。重启进新固件时钩子已就位:
#   precheck.sh (fail-open) 发现 hashtab 不匹配 → 原生启动 + 后台 fw-upgrade
#   重编 → 编译成功自动恢复中文。全程无需 SSH。
#
# 注入的只是"版本无关的钩子" (drop-in + service 单元, 指向 /home 下的脚本),
# 对任何固件版本安全 — 兼容性判断全部推迟到新系统首启的 precheck。
#
# "有没有待装的升级" 两种机型信号不同 (2026-10-18 起两种都认, 之前只认 Paper Pro 的,
# rm2 升级一次就得重装一次空间):
#   Paper Pro / Move: /sys/devices/platform/lpgpr/swu_status = 1
#   rm2:              u-boot 环境变量 upgrade_available = 1 (swupdate 写完新槽后置位,
#                     bootcmd 据此切到 active_partition; 用 fw_printenv 读, 绝不 fw_setenv)
#
# 用法: ota-watch.sh [--force]
#   --force: 跳过"有没有更新"的检查, 对 inactive slot 无条件注入 (测试/手动)

RMKIT=/home/root/rmkit-cn
SWU_STATUS=/sys/devices/platform/lpgpr/swu_status
INJECTED_MARK=$RMKIT/.ota_injected
MNT=/tmp/rmkit-ota-slot

log() { echo "[ota-watch] $*"; }

# ota_pending: 有待装的升级就输出信号来源并返回 0; 没有 (或读不到) 返回 1。
ota_pending() {
    if [ -e "$SWU_STATUS" ]; then
        [ "$(cat "$SWU_STATUS" 2>/dev/null)" = "1" ] && { echo "swu_status=1"; return 0; }
        return 1
    fi
    if command -v fw_printenv >/dev/null 2>&1; then
        # fw_printenv 一次只读一个变量时输出 "name=value"; 环境区损坏时它报错, 当作没有
        _v=$(fw_printenv upgrade_available 2>/dev/null | sed -n 's/^upgrade_available=//p' | tr -d '[:space:]')
        [ "$_v" = "1" ] && { echo "upgrade_available=1"; return 0; }
    fi
    return 1
}

# ── 1. 有 pending 更新吗 ────────────────────────────────────────
if [ "$1" != "--force" ]; then
    SIGNAL=$(ota_pending) || exit 0   # 无更新: 静默退出
    log "检测到 pending OTA ($SIGNAL)"
fi

command -v rootdev >/dev/null 2>&1 || { log "无 rootdev, 跳过"; exit 0; }
INACTIVE=$(rootdev --inactive 2>/dev/null)
[ -n "$INACTIVE" ] && [ -b "$INACTIVE" ] || { log "inactive 分区无效: $INACTIVE"; exit 0; }

# ── 2. 挂载 inactive slot ───────────────────────────────────────
mkdir -p "$MNT"
cleanup() { umount "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null; }
trap cleanup EXIT

if ! mount "$INACTIVE" "$MNT" 2>/dev/null; then
    log "mount $INACTIVE 失败 (swupdate 可能正在写入), 下轮再试"
    exit 0
fi

NEWVER=$(cat "$MNT/etc/version" 2>/dev/null | tr -d '[:space:]')
if [ -z "$NEWVER" ]; then
    log "读不到新 slot 版本, 跳过"
    exit 0
fi
# 带上版本号: 3.29.0.152 → .153 构建时间相同, 只看 /etc/version 会当成"注入过了"而跳过
NEWIMG=$(sed -n 's/^IMG_VERSION=//p' "$MNT/etc/os-release" 2>/dev/null | tr -d '"[:space:]')
[ -n "$NEWIMG" ] && NEWVER="$NEWVER-$NEWIMG"

# ── 3. 已注入过这个版本? ────────────────────────────────────────
if [ "$(cat "$INJECTED_MARK" 2>/dev/null)" = "$NEWVER" ]; then
    exit 0
fi
log "注入钩子到新固件 $NEWVER ($INACTIVE)"

# ── 4. 把当前正在运行的 rmkit-cn systemd 配置原样拷入新 rootfs ───
# (零生成逻辑: 拷贝现状, 永远与当前配置一致, 不会漂移)
SRC_ETC=/etc/systemd/system
DST_ETC=$MNT/etc/systemd/system
FAIL=0

mkdir -p "$DST_ETC/xochitl.service.d" "$DST_ETC/multi-user.target.wants" || FAIL=1

# xochitl drop-in (只拷 zz-rmkit-cn.conf, 不拷调试用的 zzz-*)
if [ -f "$SRC_ETC/xochitl.service.d/zz-rmkit-cn.conf" ]; then
    cp "$SRC_ETC/xochitl.service.d/zz-rmkit-cn.conf" "$DST_ETC/xochitl.service.d/" || FAIL=1
else
    log "警告: 当前系统无 zz-rmkit-cn.conf (rmkit-cn 未安装?), 中止注入"
    exit 0
fi

# rmkit-cn 服务单元 + wants symlink (拷"当前启用的现状")
for f in "$SRC_ETC"/rmkit-cn-*.service "$SRC_ETC"/rmkit-cn-*.path "$SRC_ETC"/rmkit-cn-*.timer; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    cp "$f" "$DST_ETC/$base" || FAIL=1
    if [ -e "$SRC_ETC/multi-user.target.wants/$base" ] || [ -e "/etc/systemd/system/timers.target.wants/$base" ]; then
        ln -sf "../$base" "$DST_ETC/multi-user.target.wants/$base" || FAIL=1
    fi
done

# 空间 (后加的, 原清单漏了它: 2026-10-13 实测 3.28→3.29 升级后空间后端消失)
if [ -f "$SRC_ETC/xochitl.service.d/zz-space.conf" ]; then
    cp "$SRC_ETC/xochitl.service.d/zz-space.conf" "$DST_ETC/xochitl.service.d/" || FAIL=1
fi
if [ -f "$SRC_ETC/remarkable-space.service" ]; then
    cp "$SRC_ETC/remarkable-space.service" "$DST_ETC/" || FAIL=1
    if [ -f "$SRC_ETC/remarkable-space.service.d/10-store-api.conf" ]; then
        mkdir -p "$DST_ETC/remarkable-space.service.d" || FAIL=1
        cp "$SRC_ETC/remarkable-space.service.d/10-store-api.conf" "$DST_ETC/remarkable-space.service.d/" || FAIL=1
    fi
    if [ -e "$SRC_ETC/multi-user.target.wants/remarkable-space.service" ]; then
        ln -sf "../remarkable-space.service" "$DST_ETC/multi-user.target.wants/remarkable-space.service" || FAIL=1
    fi
fi

if [ "$FAIL" != "0" ]; then
    log "警告: 部分文件写入失败, 不记录注入标记 (下轮重试; 最坏情况新系统出厂启动, reenable.sh 兜底)"
    exit 0
fi

sync
echo "$NEWVER" > "$INJECTED_MARK"
log "✓ 完成: 新固件 $NEWVER 已带 rmkit-cn 钩子, 重启后 precheck+fw-upgrade 自动适配"
exit 0
