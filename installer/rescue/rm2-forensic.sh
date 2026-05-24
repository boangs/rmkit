#!/bin/sh
# rm2 端根因取证脚本
# 在 rm2 本机跑 (sftp/scp 推上来后 sh rm2-forensic.sh)
#
# 流程:
#   1. 不修改任何文件, 只读取系统状态
#   2. 把 ime_hook.so + xovi.so + Qt 库的版本信息 dump 出来
#   3. 真正做 LD_DEBUG 实验, 让 dlopen 失败原因暴露
#
# 注意: 跑这个脚本会停一次 xochitl, 但不删 drop-in, 跑完会重启 xochitl

set -u
OUT_DIR="${OUT_DIR:-/tmp/rm2-forensic-$(date +%H%M%S)}"
mkdir -p "$OUT_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
section() { echo; echo "===== $* ====="; }

cd "$OUT_DIR" || exit 1

log "输出目录: $OUT_DIR"

# ---------- 1. 系统基线 ----------
section "1. 系统基线"
{
  echo "--- uname ---"; uname -a
  echo "--- /etc/version ---"; cat /etc/version
  echo "--- rootdev ---"; rootdev 2>&1
  echo "--- mount ---"; mount
  echo "--- uptime ---"; uptime
} > 01-baseline.log 2>&1
cat 01-baseline.log

# ---------- 2. xochitl drop-in 现状 ----------
section "2. xochitl drop-in 现状"
{
  echo "--- 目录列表 ---"
  ls -la /etc/systemd/system/xochitl.service.d/ 2>&1
  echo
  echo "--- drop-in 内容 ---"
  for f in /etc/systemd/system/xochitl.service.d/*.conf; do
    echo "### $f ###"
    cat "$f" 2>&1
    echo
  done
} > 02-dropin.log 2>&1
cat 02-dropin.log

# ---------- 3. xochitl 当前状态 ----------
section "3. xochitl 进程/服务状态"
{
  echo "--- pgrep ---"
  pgrep xochitl
  echo "--- systemctl status ---"
  systemctl status xochitl.service --no-pager -l 2>&1
  echo "--- journalctl xochitl (最近 100 行) ---"
  journalctl -u xochitl.service --no-pager -n 100 2>&1
} > 03-xochitl-status.log 2>&1

tail -30 03-xochitl-status.log

# ---------- 4. ime_hook.so / xovi.so 二进制取证 ----------
section "4. .so 二进制信息"
{
  for so in /home/root/rmkit-cn/bin/ime_hook.so /home/root/xovi/xovi.so; do
    [ -f "$so" ] || { echo "MISSING: $so"; continue; }
    echo "=== $so ==="
    ls -la "$so"
    file "$so" 2>/dev/null || echo "(file 不可用)"

    # 看 NEEDED 依赖
    if command -v readelf >/dev/null 2>&1; then
      echo "--- NEEDED libs ---"
      readelf -d "$so" 2>&1 | grep -E 'NEEDED|SONAME'
      echo "--- 导出符号数 ---"
      readelf -Ws "$so" 2>&1 | wc -l
    fi

    # busybox 没 readelf 时用 strings 凑活
    echo "--- 链接到的 Qt 库名 ---"
    strings "$so" 2>/dev/null | grep -E "^libQt[56]" | sort -u
    echo "--- 引用的 Qt 符号样本 (前 10) ---"
    strings "$so" 2>/dev/null | grep -E "^_ZN[0-9]+Q" | head -10
    echo
  done
} > 04-binaries.log 2>&1
cat 04-binaries.log

# ---------- 5. xochitl 二进制的 Qt 链接情况 ----------
section "5. xochitl 二进制的 Qt 依赖"
{
  echo "--- ldd /usr/bin/xochitl ---"
  ldd /usr/bin/xochitl 2>&1 | grep -E 'libQt|not found'
  echo
  echo "--- Qt5/6Core SONAME ---"
  ls -la /usr/lib/libQt*Core* 2>&1
} > 05-xochitl-qt.log 2>&1
cat 05-xochitl-qt.log

# ---------- 6. 终极实验: 用 LD_DEBUG 启动 xochitl, 看真实失败原因 ----------
section "6. LD_DEBUG 实验 (核心步骤!)"
log "停止 xochitl..."
systemctl stop xochitl.service 2>&1
sleep 2

log "用 LD_PRELOAD + LD_DEBUG=symbols,bindings 手动跑 xochitl 5 秒..."

# 一次只 PRELOAD 一个 .so, 隔离问题:

log "--- 实验 A: 只 PRELOAD xovi.so ---"
LD_DEBUG=libs,bindings \
LD_PRELOAD=/home/root/xovi/xovi.so \
  timeout 5 /usr/bin/xochitl > 06a-xovi-only.log 2>&1
log "  xovi.so dlopen 结果 (看是否有 undefined symbol):"
grep -iE 'undefined|error|cannot|fatal' 06a-xovi-only.log | head -20
log "  → 完整日志: $OUT_DIR/06a-xovi-only.log"

sleep 1

log "--- 实验 B: 只 PRELOAD ime_hook.so ---"
LD_DEBUG=libs,bindings \
LD_PRELOAD=/home/root/rmkit-cn/bin/ime_hook.so \
  timeout 5 /usr/bin/xochitl > 06b-ime-only.log 2>&1
log "  ime_hook.so dlopen 结果:"
grep -iE 'undefined|error|cannot|fatal' 06b-ime-only.log | head -20
log "  → 完整日志: $OUT_DIR/06b-ime-only.log"

sleep 1

log "--- 实验 C: PRELOAD 两者 (模拟 drop-in 实际配置) ---"
LD_DEBUG=libs,bindings \
LD_PRELOAD=/home/root/xovi/xovi.so:/home/root/rmkit-cn/bin/ime_hook.so \
  timeout 5 /usr/bin/xochitl > 06c-both.log 2>&1
log "  组合实验结果:"
grep -iE 'undefined|error|cannot|fatal' 06c-both.log | head -20
log "  → 完整日志: $OUT_DIR/06c-both.log"

sleep 1

log "--- 实验 D: 不 PRELOAD 任何东西 (验证 xochitl 本身能不能跑) ---"
timeout 5 /usr/bin/xochitl > 06d-vanilla.log 2>&1
log "  原生 xochitl 输出 (最后 20 行):"
tail -20 06d-vanilla.log

# ---------- 7. 让 xochitl 回到 systemd 控制 ----------
section "7. 重启 xochitl"
systemctl start xochitl.service 2>&1
sleep 3
if pgrep xochitl >/dev/null; then
  log "✓ xochitl 已通过 systemd 启动"
else
  log "✗ xochitl 启动失败! 立即 journalctl -u xochitl 查看"
fi

# ---------- 8. 报告 ----------
section "证据收集完成"
log "证据目录: $OUT_DIR"
log
log "把这个目录 scp 回树莓派分析:"
log "    scp -r root@10.11.99.1:$OUT_DIR ~/rm2-forensic/"
log
log "关键文件:"
ls -la "$OUT_DIR" | awk 'NR>1 {print "  ", $NF, $5, "bytes"}'
