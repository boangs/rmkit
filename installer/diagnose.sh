#!/usr/bin/env bash
# installer/diagnose.sh
# 升级前 pre-flight 检查 — 在开发机上跑 (通过 SSH 远程查设备状态),
# 不修改设备任何文件.
#
# 用法:
#   bash installer/diagnose.sh                  # 默认连 10.11.99.1
#   DEVICE_IP=192.168.x.x bash installer/diagnose.sh
#
# 退出码:
#   0  全部检查通过, 可以放心跑 install.sh
#   1  发现潜在风险, 终端有 ✗ 行
set -euo pipefail

DEVICE_IP="${DEVICE_IP:-10.11.99.1}"
DEVICE_USER="root"
SSH="ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new $DEVICE_USER@$DEVICE_IP"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
hr()     { printf '%.0s─' {1..60}; echo; }

PASS=0
FAIL=0
WARN=0
ok()   { green "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { red   "  ✗ $*"; FAIL=$((FAIL+1)); }
warn() { yellow "  ! $*"; WARN=$((WARN+1)); }

# ─── 0. SSH 通 ─────────────────────────────────────────
hr
echo "[0] SSH 连通性 ($DEVICE_IP)"
if ! $SSH true 2>/dev/null; then
  bad "无法连接 $DEVICE_USER@$DEVICE_IP — 检查 USB-C / VPN 抢路由"
  echo
  echo "结果: SSH 不通, 后续检查无法进行."
  exit 1
fi
ok "SSH OK"

# ─── 1. 机型识别 ───────────────────────────────────────
echo "[1] 机型识别"
ARCH=$($SSH "uname -m" 2>/dev/null || echo unknown)
HOSTNAME=$($SSH "cat /etc/hostname" 2>/dev/null || echo unknown)
VERSION=$($SSH "cat /etc/version 2>/dev/null || echo unknown")
case "$ARCH" in
  aarch64) ok "架构: $ARCH (RMPP / RMPPM)" ;;
  armv7l)  warn "架构: $ARCH (rm2 — 无 A/B 兜底, 失败风险更高)" ;;
  *)       bad "未知架构: $ARCH" ;;
esac
echo "    hostname=$HOSTNAME  version=$VERSION"

# ─── 2. A/B slot 状态 (仅 RMPP) ────────────────────────
echo "[2] A/B slot 状态"
if [ "$ARCH" = "aarch64" ]; then
  ACTIVE_SLOT=$($SSH "rootdev --active 2>/dev/null" || echo unknown)
  ERRCNT_A=$($SSH "cat /sys/devices/platform/lpgpr/roota_errcnt 2>/dev/null" || echo n/a)
  ERRCNT_B=$($SSH "cat /sys/devices/platform/lpgpr/rootb_errcnt 2>/dev/null" || echo n/a)
  case "$ACTIVE_SLOT" in
    *roota*|*rootA*) ok "当前 slot: $ACTIVE_SLOT (a)" ;;
    *rootb*|*rootB*) warn "当前 slot: $ACTIVE_SLOT (备用 b — 上次升级可能已切过, 先排查再升级)" ;;
    *)               warn "当前 slot 未识别: $ACTIVE_SLOT" ;;
  esac
  if [ "$ERRCNT_A" = "0" ] && [ "$ERRCNT_B" = "0" ]; then
    ok "errcnt: a=$ERRCNT_A b=$ERRCNT_B"
  else
    warn "errcnt: a=$ERRCNT_A b=$ERRCNT_B (非零, 建议先 echo 0 清空再升级)"
  fi
else
  warn "rm2 无 A/B 分区, 跳过 — 升级失败将导致假性砖机"
fi

# ─── 3. xovi 状态 ──────────────────────────────────────
echo "[3] xovi 状态"
if $SSH "test -d /home/root/xovi" 2>/dev/null; then
  ok "/home/root/xovi 存在"
  if $SSH "test -f /home/root/xovi/xovi.so" 2>/dev/null; then
    ok "xovi.so 存在"
  else
    bad "xovi.so 不存在 — 设备未安装 xovi"
  fi
else
  bad "/home/root/xovi 目录不存在 — 设备未安装 xovi (需先 bootstrap, 见 vendor/xovi/)"
fi

# ─── 4. extensions.d 杂质检查 ───────────────────────────
echo "[4] /home/root/xovi/extensions.d 杂质 (.bak/.old/.tmp/.new)"
EXT_LIST=$($SSH "ls /home/root/xovi/extensions.d/ 2>/dev/null" || true)
JUNK=$(echo "$EXT_LIST" | grep -E '\.(bak|old|tmp|new)$' || true)
if [ -z "$JUNK" ]; then
  ok "无杂质"
else
  bad "发现杂质 (xovi 会 'processed more than once' fatal → A/B 切换):"
  echo "$JUNK" | sed 's/^/      /'
  echo "    修复: ssh root@$DEVICE_IP 'rm /home/root/xovi/extensions.d/*.{bak,old,tmp,new}'"
fi

# ─── 5. xochitl drop-in 炸弹检查 ────────────────────────
echo "[5] xochitl drop-in (Requires=home.mount 炸弹)"
DROPIN=$($SSH "cat /etc/systemd/system/xochitl.service.d/*.conf 2>/dev/null" || true)
if echo "$DROPIN" | grep -q "Requires=home.mount"; then
  bad "drop-in 含 'Requires=home.mount' — rm2 会卡 multi-user.target → 假性砖机"
  echo "    立即修复: ssh root@$DEVICE_IP 'sed -i \"/Requires=home.mount/d\" /etc/systemd/system/xochitl.service.d/*.conf'"
elif echo "$DROPIN" | grep -q "After=home.mount"; then
  ok "drop-in 用 After=home.mount (正确)"
else
  warn "drop-in 未配 home.mount 排序 — 冷启动可能 ld.so 找不到 .so (高级面板/IME 会失效)"
fi

# ─── 6. xochitl 当前 LD_PRELOAD 注入状态 ────────────────
echo "[6] xochitl 进程 LD_PRELOAD"
XOCHITL_PID=$($SSH "pgrep -f /usr/bin/xochitl" 2>/dev/null | head -n 1 || true)
if [ -n "$XOCHITL_PID" ]; then
  ENV_PRELOAD=$($SSH "tr '\\0' '\\n' < /proc/$XOCHITL_PID/environ 2>/dev/null | grep ^LD_PRELOAD" || true)
  if [ -n "$ENV_PRELOAD" ]; then
    ok "$ENV_PRELOAD"
    if echo "$ENV_PRELOAD" | grep -q xovi.so; then ok "  含 xovi.so"; else bad "  未含 xovi.so"; fi
    if echo "$ENV_PRELOAD" | grep -q ime_hook.so; then ok "  含 ime_hook.so"; else warn "  未含 ime_hook.so (IME 不会生效)"; fi
  else
    bad "xochitl 运行中但无 LD_PRELOAD — drop-in 没生效"
  fi
else
  warn "xochitl 未运行 (是不是处于 emergency.target?)"
fi

# ─── 7. extensions.d 加载日志检查 ──────────────────────
echo "[7] xochitl journal 关键报错"
# "qmldiff" 关键字每条正常日志都带, 要求后面跟实际错误词才算; 同时补抓
# "id is not unique" / "Type X unavailable" 这两类 QML load fatal.
ERRORS=$($SSH "journalctl -u xochitl -b 0 2>/dev/null | grep -iE 'cannot open|LD_PRELOAD.*not found|panic|qmldiff.*(failed|error|panic|cannot)|id is not unique|Type .+ unavailable' | grep -v 'Failed to load.*\\._' | tail -n 5" || true)
if [ -z "$ERRORS" ]; then
  ok "本次启动无 LD_PRELOAD / qmldiff 报错"
else
  bad "本次启动有报错 (前 5 条):"
  echo "$ERRORS" | sed 's/^/      /'
fi

# ─── 8. systemd unit 状态 ──────────────────────────────
echo "[8] rmkit-cn 独立 service 状态"
for unit in rmkit-cn-upload rmkit-cn-ime-go rmkit-cn-ime-http; do
  STATE=$($SSH "systemctl is-active $unit.service 2>/dev/null" || echo absent)
  case "$STATE" in
    active)   ok "$unit: active" ;;
    inactive) warn "$unit: inactive (是否禁用了开机自启?)" ;;
    failed)   bad "$unit: failed (journalctl -u $unit 看原因)" ;;
    absent)   warn "$unit: 未安装 (首次部署正常, 升级时不正常)" ;;
    *)        warn "$unit: $STATE" ;;
  esac
done

# ─── 总结 ─────────────────────────────────────────────
hr
echo "结果: PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  red "✗ 存在严重风险, 不建议直接升级. 先按上面的修复建议处理."
  exit 1
fi
if [ "$WARN" -gt 0 ]; then
  yellow "! 有警告项, 升级可继续, 但建议先解释清楚每条"
fi
green "✓ 设备状态健康, 可以跑 installer/install.sh"
