#!/usr/bin/env bash
# rm2 砖机救援 + 取证主控脚本 (树莓派端跑)
#
# 完整流程 (自动化):
#   [用户] 关机 rm2, 接 B8 电阻 + pogo, USB 接树莓派, 开机
#   [脚本] 等 SDP (15a2:0076) → 提示"拔 B8 电阻"
#   [用户] 拔 B8 电阻
#   [脚本] 推 u-boot-ums.imx → 等 /dev/sda 出现 → 找 rootfs 分区
#   [脚本] 挂载 /mnt/rm2 → 备份证据到 ~/rm2-evidence/
#   [脚本] 删 drop-in → sync → umount → 提示"拔 pogo 重启"
#   [用户] 拔 pogo + 开机 rm2
#   [脚本] 等 SSH (10.11.99.1) → 抓 post-rescue journal → 输出根因报告
#
# 设计原则: 关键时刻日志清晰提示用户动什么硬件, 其余全自动

set -uo pipefail

# ============ 配置 ============
RM2_IP="${RM2_IP:-10.11.99.1}"
RM2_USER="${RM2_USER:-root}"
RM2_PASSWORD="${RM2_PASSWORD:-0VaVOsP9Qa}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"
EVIDENCE_DIR="${EVIDENCE_DIR:-$HOME/rm2-evidence}"

# u-boot 推送资源 (memory 记录: 在树莓派 /boot/firmware/)
UBOOT_IMX="/boot/firmware/u-boot-ums.imx"
UBOOT_CONF_DIR="/boot/firmware"

# rm2 端关键路径 (砖机时只读)
DROPIN_REL="etc/systemd/system/xochitl.service.d/zz-rmkit-cn.conf"
RMKIT_DIR_REL="home/root/rmkit-cn"
XOVI_DIR_REL="home/root/xovi"

# ============ 日志 ============
mkdir -p "$EVIDENCE_DIR"
LOG="$EVIDENCE_DIR/rescue.log"
: > "$LOG"

log() { local msg="[$(date '+%H:%M:%S')] $*"; echo "$msg" | tee -a "$LOG"; }
warn() { log "⚠ $*"; }
ok() { log "✓ $*"; }
err() { log "✗ $*"; }
prompt() { log ""; log "▶▶▶ $*"; log ""; }

# ============ 状态检测 ============
probe_state() {
  if ping -c 1 -W 1 "$RM2_IP" &>/dev/null; then
    if timeout 2 bash -c "echo > /dev/tcp/$RM2_IP/22" 2>/dev/null; then
      echo ssh_up; return
    fi
    echo ping_only; return
  fi
  if lsusb 2>/dev/null | grep -q "15a2:0076"; then echo sdp; return; fi
  if lsusb 2>/dev/null | grep -q "0525:a4a5"; then echo ums; return; fi
  if lsusb 2>/dev/null | grep -qi "reMarkable\|imx"; then echo other_usb; return; fi
  echo no_usb
}

ssh_rm2() {
  ssh $SSH_OPTS "$RM2_USER@$RM2_IP" "$@" 2>/dev/null && return 0
  command -v sshpass &>/dev/null && \
    sshpass -p "$RM2_PASSWORD" ssh $SSH_OPTS "$RM2_USER@$RM2_IP" "$@" || \
    ssh $SSH_OPTS "$RM2_USER@$RM2_IP" "$@"
}

scp_rm2() {
  scp $SSH_OPTS "$RM2_USER@$RM2_IP:$1" "$2" 2>/dev/null && return 0
  command -v sshpass &>/dev/null && \
    sshpass -p "$RM2_PASSWORD" scp $SSH_OPTS "$RM2_USER@$RM2_IP:$1" "$2" || \
    scp $SSH_OPTS "$RM2_USER@$RM2_IP:$1" "$2"
}

# ============ 阶段 1: 等 SDP ============
stage_wait_sdp() {
  prompt "阶段 1/6 — 等待 rm2 进 SDP 模式"
  log "请确认: B8 ↔ A12 电阻已接, pogo pin 已贴 rm2 背面, USB-C 接好"
  log "然后: 长按 Power 5 秒 → 松开 → 设备应该进 SDP"
  log "(监控 USB 设备, 每秒探测)"

  local waited=0
  while true; do
    if lsusb 2>/dev/null | grep -q "15a2:0076"; then
      ok "SDP 设备出现 (NXP SE Blank ULT1, VID:PID 15a2:0076)"
      return 0
    fi
    sleep 1
    waited=$((waited+1))
    if [ $((waited % 10)) -eq 0 ]; then
      log "  等了 ${waited} 秒, 还没看到 SDP..."
      if [ $waited -eq 30 ]; then
        log "  USB 当前状态:"
        lsusb 2>&1 | sed 's/^/    /' | tee -a "$LOG"
      fi
    fi
  done
}

# ============ 阶段 2-3: 推 u-boot 直到 UMS 出现 (合并 + 重试) ============
stage_get_ums() {
  prompt "阶段 2-3/6 — 反复推 u-boot 直到 /dev/sda (UMS) 出现"
  log "⚠ 如果一直 recovery loop (每秒 disconnect/reconnect), 说明 B8 电阻没拔"
  log "(脚本会持续重试, 你拔电阻后下一轮就成功)"

  if [ ! -f "$UBOOT_IMX" ]; then
    err "u-boot-ums.imx 不存在: $UBOOT_IMX"
    return 1
  fi

  local attempt=0 max_attempts=15
  while [ $attempt -lt $max_attempts ]; do
    attempt=$((attempt+1))

    # 1. 等 SDP 设备出现 (recovery loop 中每秒重连, 应该很快)
    log "[第 $attempt 次] 等 SDP (15a2:0076)..."
    local found_sdp=0
    for i in $(seq 1 20); do
      if lsusb 2>/dev/null | grep -q "15a2:0076"; then found_sdp=1; break; fi
      sleep 0.5
    done

    if [ $found_sdp -eq 0 ]; then
      warn "[第 $attempt 次] SDP 10 秒没出现 — 设备可能挂了或断开"
      warn "  如果 rm2 屏幕没亮, 长按 Power 5 秒重新进 SDP"
      sleep 5
      continue
    fi

    # 2. 推 u-boot
    log "[第 $attempt 次] 推 u-boot..."
    local out
    out=$(cd "$UBOOT_CONF_DIR" && sudo imx_usb "$UBOOT_IMX" 2>&1)
    if ! echo "$out" | grep -q "jumping"; then
      warn "[第 $attempt 次] imx_usb 失败:"
      echo "$out" | tail -5 | sed 's/^/    /' | tee -a "$LOG"
      sleep 3
      continue
    fi
    ok "[第 $attempt 次] u-boot 已跳转 (jumping to 0x00910400)"

    # 3. 等 UMS (sda) 出现, 最多 40 秒
    log "[第 $attempt 次] 等 /dev/sda (mass storage)..."
    local found_sda=0
    for i in $(seq 1 80); do
      if [ -b /dev/sda ]; then found_sda=1; break; fi
      sleep 0.5
      [ $((i % 20)) -eq 0 ] && log "  已等 $((i/2)) 秒..."
    done

    if [ $found_sda -eq 1 ]; then
      ok "✓ /dev/sda 出现!"
      sleep 2  # 等内核读分区表
      log "  分区表:"; lsblk /dev/sda | tee -a "$LOG"
      return 0
    fi

    # 4. UMS 没出现, 诊断
    warn "[第 $attempt 次] /dev/sda 40 秒没出现"
    if lsusb 2>/dev/null | grep -q "15a2:0076"; then
      err "  → SDP 设备 (15a2:0076) 还在, 说明在 recovery loop"
      err "  → B8 电阻没拔! 现在拔, 下一轮重试..."
    elif lsusb 2>/dev/null | grep -q "0525:a4a5"; then
      warn "  → UMS 设备 (0525:a4a5) 出现了但 /dev/sda 没就绪"
      warn "  → 内核 USB 子系统问题, 重试..."
    else
      warn "  → SDP 和 UMS 都不在, 设备状态未知"
      warn "  → 长按 rm2 Power 5 秒重新进 SDP"
    fi
    sleep 5
  done

  err "重试 $max_attempts 次都失败, 放弃"
  return 1
}

# ============ 阶段 4: 挂载 + 找 active rootfs (含 drop-in 的) ============
ROOTFS_PART=""
stage_mount() {
  prompt "阶段 4/6 — 挂载 rm2 active rootfs (找含 drop-in 的分区)"
  sudo mkdir -p /mnt/rm2
  sudo umount /mnt/rm2 2>/dev/null || true

  # 第一轮: 找含 drop-in 的分区 (=install.sh 装过的 = active)
  local best_part="" best_ver=""
  for part in /dev/sda2 /dev/sda3; do
    [ -b "$part" ] || continue
    log "  探测 $part (找 drop-in)..."
    if sudo mount -t ext4 -o ro "$part" /mnt/rm2 2>/dev/null; then
      local ver
      ver=$(sudo cat /mnt/rm2/etc/version 2>/dev/null || echo "?")
      if sudo test -f "/mnt/rm2/$DROPIN_REL"; then
        log "    ✓ 版本 $ver, 有 drop-in → 这是 active"
        sudo umount /mnt/rm2
        best_part="$part"
        best_ver="$ver"
        break
      else
        log "    版本 $ver, 无 drop-in"
        sudo umount /mnt/rm2
      fi
    fi
  done

  # 第二轮: 都没 drop-in, 选第一个有 xochitl 的
  if [ -z "$best_part" ]; then
    warn "两个分区都没 drop-in, 挂第一个含 xochitl 的"
    for part in /dev/sda2 /dev/sda3; do
      [ -b "$part" ] || continue
      if sudo mount -t ext4 -o ro "$part" /mnt/rm2 2>/dev/null; then
        if [ -f /mnt/rm2/usr/bin/xochitl ]; then
          best_part="$part"
          best_ver=$(sudo cat /mnt/rm2/etc/version 2>/dev/null || echo "?")
          sudo umount /mnt/rm2
          break
        fi
        sudo umount /mnt/rm2
      fi
    done
  fi

  if [ -z "$best_part" ]; then
    err "找不到任何 rootfs 分区"
    return 1
  fi

  sudo mount -t ext4 -o rw "$best_part" /mnt/rm2 || { err "rw 挂载失败"; return 1; }
  ROOTFS_PART="$best_part"
  ok "已挂载 $best_part 到 /mnt/rm2 (版本 $best_ver, rw)"
  return 0
}

# ============ 阶段 5: 备份证据 + 删 drop-in ============
stage_backup_and_fix() {
  prompt "阶段 5/6 — 备份证据 + 删 drop-in"

  local snap="$EVIDENCE_DIR/snapshot-$(date +%H%M%S)"
  mkdir -p "$snap"

  # ----- 备份 (在删之前!) -----
  log "备份现场到 $snap/"

  # 1. drop-in 内容 (砖机直接证据)
  if [ -f "/mnt/rm2/$DROPIN_REL" ]; then
    sudo cp "/mnt/rm2/$DROPIN_REL" "$snap/zz-rmkit-cn.conf"
    sudo chown $(id -u):$(id -g) "$snap/zz-rmkit-cn.conf"
    ok "  zz-rmkit-cn.conf ($(stat -c%s "$snap/zz-rmkit-cn.conf") bytes)"
  else
    warn "  drop-in 不存在? 路径: /mnt/rm2/$DROPIN_REL"
  fi

  # 2. drop-in 目录全部内容
  if [ -d "/mnt/rm2/etc/systemd/system/xochitl.service.d" ]; then
    sudo ls -la /mnt/rm2/etc/systemd/system/xochitl.service.d/ > "$snap/dropin-dir.txt"
    ok "  dropin-dir.txt"
  fi

  # 3. xochitl service 文件 + wants symlink 状态
  sudo ls -la /mnt/rm2/etc/systemd/system/multi-user.target.wants/ 2>/dev/null > "$snap/wants-symlinks.txt"
  sudo cp /mnt/rm2/lib/systemd/system/xochitl.service "$snap/xochitl.service.original" 2>/dev/null

  # 4. ime_hook.so + xovi.so (验证 symbol 用)
  for f in $RMKIT_DIR_REL/bin/ime_hook.so $XOVI_DIR_REL/xovi.so; do
    [ -f "/mnt/rm2/$f" ] || continue
    local name=$(basename "$f")
    sudo cp "/mnt/rm2/$f" "$snap/$name"
    sudo chown $(id -u):$(id -g) "$snap/$name"
    ok "  $name ($(stat -c%s "$snap/$name") bytes)"
  done

  # 5. xochitl 二进制 (对照 symbol 用)
  sudo cp /mnt/rm2/usr/bin/xochitl "$snap/xochitl.bin" 2>/dev/null
  sudo chown $(id -u):$(id -g) "$snap/xochitl.bin" 2>/dev/null
  [ -f "$snap/xochitl.bin" ] && ok "  xochitl.bin ($(stat -c%s "$snap/xochitl.bin") bytes)"

  # 6. /etc/version + fstab + rmkit-cn 状态
  sudo cat /mnt/rm2/etc/version > "$snap/etc-version" 2>/dev/null
  sudo cat /mnt/rm2/etc/fstab > "$snap/fstab" 2>/dev/null
  sudo ls -la /mnt/rm2/home/root/rmkit-cn/ 2>/dev/null > "$snap/rmkit-cn-ls.txt"
  ok "  etc-version, fstab, rmkit-cn-ls.txt"

  # 7. journal 历史 (如果 persistent)
  if [ -d /mnt/rm2/var/log/journal ]; then
    sudo cp -r /mnt/rm2/var/log/journal "$snap/journal" 2>/dev/null
    sudo chown -R $(id -u):$(id -g) "$snap/journal" 2>/dev/null
    ok "  journal/ ($(du -sh "$snap/journal" | cut -f1))"
  else
    log "  (rm2 journal 非 persistent, 砖机时日志已丢)"
  fi

  ok "证据备份完成: $snap"
  log

  # ----- 删 drop-in -----
  log "===== 现在删 drop-in ====="
  if [ -f "/mnt/rm2/$DROPIN_REL" ]; then
    sudo rm -f "/mnt/rm2/$DROPIN_REL"
    ok "  已删 /mnt/rm2/$DROPIN_REL"
  else
    log "  (drop-in 不存在, 跳过)"
  fi

  # 同时清理空 .d 目录
  sudo rmdir /mnt/rm2/etc/systemd/system/xochitl.service.d 2>/dev/null && \
    log "  已清理空 .d 目录" || true

  # ----- sync 写盘 -----
  log "sync + umount..."
  sync
  sudo umount /mnt/rm2 || { err "umount 失败!"; return 1; }
  ok "rootfs 已 umount, 修改持久化"
  return 0
}

# ============ 阶段 6: 重启 + 等 SSH ============
stage_wait_reboot() {
  prompt "阶段 6/6 — 拔 pogo + 长按 Power 开机 rm2"
  log "(脚本继续监控 SSH, SSH 通就抓 post-rescue 证据)"

  local waited=0
  while true; do
    if timeout 2 bash -c "echo > /dev/tcp/$RM2_IP/22" 2>/dev/null; then
      ok "rm2 SSH 已恢复! (等了 ${waited} 秒)"
      return 0
    fi
    sleep 3
    waited=$((waited+3))
    if [ $((waited % 30)) -eq 0 ]; then
      log "  等了 ${waited} 秒, SSH 还没通... (rm2 启动约需 60-90 秒)"
    fi
    if [ $waited -ge 300 ]; then
      err "5 分钟没等到 SSH, 救援可能不完整"
      err "登录 rm2 屏幕确认状态"
      return 1
    fi
  done
}

# ============ 阶段 7: 抓 post-rescue 证据 ============
stage_post_rescue_evidence() {
  prompt "抓救援后证据 (验证 xochitl 是否真正起来了)"

  local snap="$EVIDENCE_DIR/post-rescue-$(date +%H%M%S)"
  mkdir -p "$snap"

  ssh_rm2 'uptime; rootdev 2>&1; cat /etc/version; pgrep -l xochitl' > "$snap/system-info.txt" 2>&1 \
    && ok "  system-info.txt"

  ssh_rm2 'journalctl -u xochitl.service --no-pager -n 200' > "$snap/journal-xochitl.log" 2>&1 \
    && ok "  journal-xochitl.log"

  ssh_rm2 'systemctl status xochitl.service --no-pager -l' > "$snap/xochitl-status.txt" 2>&1

  if ssh_rm2 'pgrep xochitl' >/dev/null 2>&1; then
    ok "✓✓✓ xochitl 进程在跑, 设备恢复正常 ✓✓✓"
  else
    err "✗ xochitl 没跑! 救援不完整, 看 $snap/journal-xochitl.log"
  fi
}

# ============ 监控模式 (SSH 通时直接抓证据) ============
handle_ssh_up_directly() {
  local snap="$EVIDENCE_DIR/ssh-up-$(date +%H%M%S)"
  mkdir -p "$snap"

  ssh_rm2 'uptime; rootdev; cat /etc/version; pgrep -l xochitl 2>&1' > "$snap/system-info.txt" 2>&1
  ssh_rm2 'journalctl -u xochitl.service --no-pager --since "2 days ago"' > "$snap/journal-xochitl.log" 2>&1
  ssh_rm2 'dmesg' > "$snap/dmesg.log" 2>&1
  ssh_rm2 "cat /etc/systemd/system/xochitl.service.d/*.conf 2>&1; echo '---'; ls -la /etc/systemd/system/xochitl.service.d/ 2>&1" > "$snap/drop-in.txt" 2>&1
  scp_rm2 "/home/root/rmkit-cn/bin/ime_hook.so" "$snap/ime_hook.so" 2>/dev/null
  scp_rm2 "/home/root/xovi/xovi.so" "$snap/xovi.so" 2>/dev/null

  ok "证据保存到 $snap/"

  if ssh_rm2 "pgrep xochitl" >/dev/null 2>&1; then
    ok "xochitl 在跑, 设备正常"
  else
    err "xochitl 没跑! drop-in 还在生效, 立即跑救援: bash $0 ssh-rescue"
  fi
}

# ============ 通过 SSH 救活 (rm2 还能 SSH 进时用) ============
cmd_ssh_rescue() {
  if ! timeout 2 bash -c "echo > /dev/tcp/$RM2_IP/22" 2>/dev/null; then
    err "rm2 SSH 不通, 不能走 SSH 救援"
    err "用 SDP 救援: bash $0"
    return 1
  fi
  prompt "通过 SSH 救活 (rm2 SSH 还通时优先用这条路径)"

  # 备份 + 删 drop-in (rm2 内部操作)
  ssh_rm2 "
    set -e
    DROPIN=/etc/systemd/system/xochitl.service.d/zz-rmkit-cn.conf
    if [ -f \$DROPIN ]; then
      cp \$DROPIN /tmp/zz-rmkit-cn.conf.backup
      rm -f \$DROPIN
    fi

    # tmpfs upper 同时清理 ext4 lower
    mkdir -p /tmp/lc
    mount --bind / /tmp/lc 2>/dev/null
    mount -o remount,rw /tmp/lc 2>/dev/null || true
    rm -f /tmp/lc\$DROPIN
    sync
    umount -l /tmp/lc
    rmdir /tmp/lc

    systemctl daemon-reload
    echo CLEANUP_OK
  " > "$EVIDENCE_DIR/ssh-cleanup.log" 2>&1

  if ! grep -q CLEANUP_OK "$EVIDENCE_DIR/ssh-cleanup.log"; then
    err "清理失败, 看 $EVIDENCE_DIR/ssh-cleanup.log"
    return 1
  fi

  scp_rm2 "/tmp/zz-rmkit-cn.conf.backup" "$EVIDENCE_DIR/zz-rmkit-cn.conf.before-rescue" 2>/dev/null && \
    ok "  备份: zz-rmkit-cn.conf.before-rescue"

  ok "drop-in 已删 (tmpfs + ext4 lower 都清干净)"

  log "重启 xochitl..."
  ssh_rm2 "systemctl restart xochitl.service" 2>&1 | tee -a "$LOG"
  sleep 5
  if ssh_rm2 "pgrep xochitl" >/dev/null 2>&1; then
    ok "✓ xochitl 已启动, 救援完成"
  else
    err "✗ xochitl 启动失败, 看 journalctl -u xochitl"
  fi
}

# ============ 入口: 完整流程 ============
cmd_full() {
  log "=== rm2 救援完整流程 ==="
  log "工作目录: $EVIDENCE_DIR"
  log

  # 探测当前状态决定从哪开始
  local s=$(probe_state)
  log "rm2 当前状态: $s"

  case "$s" in
    ssh_up)
      log "rm2 SSH 已通 → 走 SSH 救援路径"
      handle_ssh_up_directly
      if ! ssh_rm2 "pgrep xochitl" >/dev/null 2>&1; then
        cmd_ssh_rescue
      fi
      ;;
    sdp)
      log "已在 SDP 模式, 跳过阶段 1"
      stage_get_ums && \
      stage_mount && \
      stage_backup_and_fix && \
      stage_wait_reboot && \
      stage_post_rescue_evidence
      ;;
    *)
      stage_wait_sdp && \
      stage_get_ums && \
      stage_mount && \
      stage_backup_and_fix && \
      stage_wait_reboot && \
      stage_post_rescue_evidence
      ;;
  esac

  log
  log "=== 流程结束 ==="
  log "全部证据: $EVIDENCE_DIR"
  log "分析: bash $0 analyze"
}

# ============ 监控模式 (只观察, 不动手) ============
cmd_monitor() {
  log "=== rm2 状态监控 (只观察) ==="
  log "工作目录: $EVIDENCE_DIR"

  local last=""
  while true; do
    local s=$(probe_state)
    if [ "$s" != "$last" ]; then
      log "状态: ${last:-初始} → $s"
      last="$s"
      [ "$s" = "ssh_up" ] && handle_ssh_up_directly
      [ "$s" = "sdp" ] && log "  ▶ rm2 进 SDP 模式, 可跑 bash $0 来自动救援"
    fi
    sleep 3
  done
}

# ============ 分析证据 ============
cmd_analyze() {
  local dir="${1:-$EVIDENCE_DIR}"
  log "=== 分析 $dir ==="
  echo

  echo "## 备份的 drop-in 内容:"
  for f in "$dir"/snapshot-*/zz-rmkit-cn.conf "$dir"/zz-rmkit-cn.conf*; do
    [ -f "$f" ] || continue
    echo "  --- $f ---"
    cat "$f" | sed 's/^/    /'
    echo
  done

  echo "## ime_hook.so / xovi.so 信息:"
  for f in "$dir"/snapshot-*/ime_hook.so "$dir"/snapshot-*/xovi.so "$dir"/*.so; do
    [ -f "$f" ] || continue
    echo "  $(basename $f): $(stat -c%s "$f") bytes"
    file "$f" 2>/dev/null | sed 's/^/    /'
    if command -v readelf &>/dev/null; then
      echo "    NEEDED:"
      readelf -d "$f" 2>/dev/null | awk '/NEEDED/ {gsub(/[\[\]]/, "", $NF); print "      "$NF}'
    fi
  done

  echo
  echo "## 推荐下一步:"
  echo "  1. 看 drop-in 内容, 确认 LD_PRELOAD 行是否包含 ime_hook.so"
  echo "  2. 在 rm2 上 (救活后) 用 LD_DEBUG 复现确认根因:"
  echo "     ssh root@$RM2_IP"
  echo "     systemctl stop xochitl"
  echo "     LD_DEBUG=symbols,bindings \\"
  echo "       LD_PRELOAD=/home/root/xovi/xovi.so:/home/root/rmkit-cn/bin/ime_hook.so \\"
  echo "       /usr/bin/xochitl 2>&1 | tee /tmp/ld-debug.log | head -200"
}

# ============ 入口 ============
case "${1:-full}" in
  full|rescue) cmd_full ;;
  monitor) cmd_monitor ;;
  ssh-rescue) cmd_ssh_rescue ;;
  analyze) shift; cmd_analyze "${1:-$EVIDENCE_DIR}" ;;
  help|-h|--help)
    cat <<EOF
rm2 救援工具

  bash $0              完整流程 (自动判断状态)
  bash $0 monitor      只监控状态, 不动手
  bash $0 ssh-rescue   rm2 SSH 还通时, 走 SSH 救援
  bash $0 analyze      分析已抓证据

环境变量:
  RM2_IP=$RM2_IP
  EVIDENCE_DIR=$EVIDENCE_DIR
EOF
    ;;
  *) err "未知子命令: $1"; exit 1 ;;
esac
