#!/usr/bin/env bash
# installer/apply-and-restart.sh
# 立即生效模式 — 部署 + restart xochitl + 启动验证 + 失败自动回滚.
#
# 默认升级流程是延迟生效 (跑 install.sh 后等用户冷启动), 那是更安全的路径.
# 本脚本严格按 docs/upgrade-sop.md 铁律 #4 实现 8 步保护:
#   1. 备份 extensions.d/ 和 qt-resource-rebuilder/ 到 xovi 外部
#   2. 备份 ime_hook.so / 当前 .qmd 等热路径文件
#   3. 记录 rootdev / errcnt / version 基线
#   4. 提示用户另开 SSH 跑 journalctl -u xochitl -f
#   5. systemctl restart xochitl 后等 15s
#   6. 检查 active / LD_PRELOAD 注入 / journal 无关键报错
#   7. 失败立即回滚 (备份还原 + errcnt 清零 + 再 restart 验证)
#   8. 重启间隔 ≥ 1 分钟
#
# 用法:
#   bash installer/apply-and-restart.sh
#   DEVICE_IP=192.168.x.x bash installer/apply-and-restart.sh
set -euo pipefail

DEVICE_IP="${DEVICE_IP:-10.11.99.1}"
DEVICE_USER="root"
SSH_OPTS="-o ConnectTimeout=8 -o ServerAliveInterval=10 -o ServerAliveCountMax=3"
SSH="ssh $SSH_OPTS $DEVICE_USER@$DEVICE_IP"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/home/root/xovi-backup/$TS"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
hr()     { printf '%.0s─' {1..60}; echo; }
ok()   { green "  ✓ $*"; }
bad()  { red   "  ✗ $*"; }
warn() { yellow "  ! $*"; }

confirm() {
  printf '%s [y/N]: ' "$1"
  read -r ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "已取消"; exit 1; }
}

# ─── 0. 警告 + diagnose pre-flight ─────────────────────
hr
red "=== rmkit-cn apply-and-restart (立即生效) ==="
yellow "WARNING: 这会主动 restart xochitl, 比默认延迟生效风险高."
yellow "推荐做法: 跑 install.sh 后让用户自然冷启动."
yellow "本脚本带回滚保护, 但失败时仍可能 errcnt += 1."
echo
confirm "确认继续?"

echo
echo "[0] pre-flight diagnose..."
if ! bash "$SCRIPT_DIR/diagnose.sh"; then
  bad "diagnose.sh 失败 — 设备状态不健康, 终止"
  exit 1
fi

# ─── 1. 设备上备份 ────────────────────────────────────
echo
echo "[1] 备份 extensions.d/ + qt-resource-rebuilder/ 到 $BACKUP_DIR ..."
$SSH "
  set -e
  mkdir -p '$BACKUP_DIR'
  if [ -d /home/root/xovi/extensions.d ]; then
    cp -a /home/root/xovi/extensions.d '$BACKUP_DIR/extensions.d.before'
  fi
  if [ -d /home/root/xovi/exthome/qt-resource-rebuilder ]; then
    cp -a /home/root/xovi/exthome/qt-resource-rebuilder '$BACKUP_DIR/qt-resource-rebuilder.before'
  fi
  if [ -d /home/root/rmkit-cn/bin ]; then
    cp -a /home/root/rmkit-cn/bin '$BACKUP_DIR/rmkit-cn-bin.before'
  fi
" || { bad "备份失败, 终止"; exit 1; }
ok "备份完成 — 失败回滚源在 $BACKUP_DIR"

# ─── 2. 基线记录 ──────────────────────────────────────
echo
echo "[2] 记录 rootdev / errcnt / version 基线..."
SLOT_BEFORE=$($SSH "rootdev --active" 2>/dev/null || echo unknown)
ERRA_BEFORE=$($SSH "cat /sys/devices/platform/lpgpr/roota_errcnt 2>/dev/null" || echo n/a)
ERRB_BEFORE=$($SSH "cat /sys/devices/platform/lpgpr/rootb_errcnt 2>/dev/null" || echo n/a)
VER_BEFORE=$($SSH "cat /etc/version 2>/dev/null" || echo n/a)
echo "    slot=$SLOT_BEFORE  errcnt: a=$ERRA_BEFORE b=$ERRB_BEFORE  version=$VER_BEFORE"

# ─── 3. 部署 (调 install.sh) ──────────────────────────
echo
echo "[3] 部署 (跑 installer/install.sh)..."
bash "$SCRIPT_DIR/install.sh"
ok "部署完成"

# ─── 4. 提示用户另开终端观察 journal ───────────────────
echo
hr
yellow "请在 *另一个* 终端窗口跑:"
echo
echo "    ssh root@$DEVICE_IP 'journalctl -u xochitl -f'"
echo
yellow "(确保你能看到 xochitl 的实时日志, 一旦有 'cannot open' / 'panic' 立即"
yellow " 在那个窗口能看到, 用来辅助决策回滚.)"
echo
confirm "另一终端的 journal 已开, 按 y 触发 restart"

# ─── 5. restart xochitl ───────────────────────────────
echo
echo "[5] systemctl restart xochitl ..."
$SSH "systemctl restart xochitl" || warn "restart 命令返回非零 (但 SSH 通)"
echo "    等 15s 让 xochitl 启动 + LD_PRELOAD 加载 + qmldiff 解析..."
sleep 15

# ─── 6. 验证 ──────────────────────────────────────────
echo
echo "[6] 启动验证..."
ALL_OK=1

if $SSH "systemctl is-active xochitl" 2>/dev/null | grep -q '^active$'; then
  ok "xochitl is-active"
else
  bad "xochitl 未 active"
  ALL_OK=0
fi

XOCHITL_PID=$($SSH "pgrep -f /usr/bin/xochitl" 2>/dev/null | head -n 1 || true)
if [ -n "$XOCHITL_PID" ]; then
  if $SSH "tr '\\0' '\\n' < /proc/$XOCHITL_PID/environ 2>/dev/null | grep -q '^LD_PRELOAD='"; then
    ok "LD_PRELOAD 注入成功"
  else
    bad "xochitl 运行但 LD_PRELOAD 未注入 (drop-in 没生效或 .so 找不到)"
    ALL_OK=0
  fi
else
  bad "xochitl 进程不存在"
  ALL_OK=0
fi

ERRORS=$($SSH "journalctl -u xochitl -b 0 2>/dev/null | grep -iE 'cannot open|panic|qmldiff' | head -n 5" || true)
if [ -z "$ERRORS" ]; then
  ok "journal 本启动无关键报错"
else
  bad "journal 关键报错:"
  echo "$ERRORS" | sed 's/^/      /'
  ALL_OK=0
fi

ERRA_AFTER=$($SSH "cat /sys/devices/platform/lpgpr/roota_errcnt 2>/dev/null" || echo n/a)
ERRB_AFTER=$($SSH "cat /sys/devices/platform/lpgpr/rootb_errcnt 2>/dev/null" || echo n/a)
if [ "$ERRA_AFTER" = "$ERRA_BEFORE" ] && [ "$ERRB_AFTER" = "$ERRB_BEFORE" ]; then
  ok "errcnt 未增加 (a=$ERRA_AFTER b=$ERRB_AFTER)"
else
  bad "errcnt 增加 (a=$ERRA_BEFORE→$ERRA_AFTER b=$ERRB_BEFORE→$ERRB_AFTER), 累 3 会自动 A/B"
  ALL_OK=0
fi

# ─── 7. 失败回滚 ──────────────────────────────────────
if [ "$ALL_OK" -eq 0 ]; then
  echo
  red "*** 启动验证失败, 立即回滚 ***"
  $SSH "
    set -e
    if [ -d '$BACKUP_DIR/extensions.d.before' ]; then
      rm -rf /home/root/xovi/extensions.d
      cp -a '$BACKUP_DIR/extensions.d.before' /home/root/xovi/extensions.d
    fi
    if [ -d '$BACKUP_DIR/qt-resource-rebuilder.before' ]; then
      rm -rf /home/root/xovi/exthome/qt-resource-rebuilder
      cp -a '$BACKUP_DIR/qt-resource-rebuilder.before' /home/root/xovi/exthome/qt-resource-rebuilder
    fi
    if [ -d '$BACKUP_DIR/rmkit-cn-bin.before' ]; then
      rm -rf /home/root/rmkit-cn/bin
      cp -a '$BACKUP_DIR/rmkit-cn-bin.before' /home/root/rmkit-cn/bin
    fi
    echo 0 > /sys/devices/platform/lpgpr/roota_errcnt 2>/dev/null || true
    echo 0 > /sys/devices/platform/lpgpr/rootb_errcnt 2>/dev/null || true
  " || { red "回滚命令失败 — 立即手工介入"; exit 2; }
  ok "备份已还原, errcnt 已清零"

  echo "    等 60s 防止累 errcnt 触发 A/B (铁律 #7 重启间隔 ≥ 1 分钟)..."
  sleep 60

  echo "    再 restart xochitl 验证回滚成功..."
  $SSH "systemctl restart xochitl" || true
  sleep 15
  if $SSH "systemctl is-active xochitl" 2>/dev/null | grep -q '^active$'; then
    ok "回滚后 xochitl 已恢复"
    yellow "升级未完成. 排查 journal + extensions.d 后重新跑."
    exit 1
  else
    red "回滚后 xochitl 仍异常 — 立即手工介入, 不要再操作设备"
    red "  备份位置: $BACKUP_DIR"
    red "  当前 slot: $($SSH 'rootdev --active' 2>/dev/null || echo unknown)"
    exit 2
  fi
fi

# ─── 8. 成功 ──────────────────────────────────────────
echo
hr
green "=== 部署 + restart 成功 ==="
echo "  备份保留在 $BACKUP_DIR (确认稳定一段时间后可删:"
echo "    ssh root@$DEVICE_IP 'rm -rf /home/root/xovi-backup'"
echo "  )"
SLOT_AFTER=$($SSH "rootdev --active" 2>/dev/null || echo unknown)
echo "  当前 slot: $SLOT_AFTER (升级前: $SLOT_BEFORE)"
if [ "$SLOT_AFTER" != "$SLOT_BEFORE" ]; then
  red "  ! slot 已变化 — 自动 A/B 切换发生过, 需要人工排查"
  exit 1
fi
