# rm2 砖机救援流程

`installer/rescue/` 目录下两个脚本配合救一台 rm2 (reMarkable 2) 设备。

## 文件说明

- **`rm2-rescue.sh`** — 树莓派 (或任何 Linux 主机) 上跑。状态机监控 rm2 USB+SSH, 自动抓证据, 一键救活
- **`rm2-forensic.sh`** — rm2 内部跑 (SSH 通了之后 scp 上去)。`LD_DEBUG` 实验, 暴露 ime_hook.so/xovi.so dlopen 真实失败原因

## 当前砖机状态判断

```
rm2 砖了
 ├─ SSH 完全不通 + USB 也没设备 → 主板可能没启动, 长按电源 5 秒重置
 ├─ SSH 不通 + USB 出现 NXP 15a2:0076 → SDP 模式 (BootROM 等推 u-boot)
 ├─ SSH 不通 + USB gadget 在 → xochitl crash 但内核活, sshd 可能也死
 └─ SSH 通了 → 设备可用, 直接抓证据 + 救活
```

## 救援流程 (按顺序)

### Step 1 — 把脚本推到树莓派

在你的 macOS 上:

```bash
cd /Users/xurx/tmp/rmkit-cn
scp installer/rescue/rm2-rescue.sh installer/rescue/rm2-forensic.sh pi@<树莓派IP>:~/
```

(或用 SD 卡, 或直接在树莓派 git clone 这个仓库)

### Step 2 — 树莓派启动监控

USB-C 连接树莓派 ↔ rm2 之后, 树莓派上跑:

```bash
chmod +x rm2-rescue.sh rm2-forensic.sh
bash rm2-rescue.sh        # 默认 monitor 模式, 持续检测状态
```

脚本会在状态变化时打印, 例如:

```
[14:23:01] === rm2 救砖监控 ===
[14:23:01] 工作目录: /home/pi/rm2-evidence-20260513-142301
[14:23:01] 目标: root@10.11.99.1
[14:23:04] 状态变化: <初始> → no_usb
[14:23:34] 状态变化: no_usb → usb_gadget
[14:23:37] 状态变化: usb_gadget → ping_only
[14:24:10] 状态变化: ping_only → ssh_up
[14:24:10] ✓ SSH 端口开放, 立即抓证据
[14:24:11] ✓   system-info.txt
[14:24:13] ✓   journal-xochitl.log (1234 行)
...
```

### Step 3 — 根据状态对应操作

**Case A: 状态停在 `ssh_up`** (相对幸运)

证据已自动抓到 `~/rm2-evidence-xxx/`。看脚本输出:

- 如果"xochitl 进程在跑" → 设备其实没真死, drop-in 可能因 ConditionPathExists 守卫被 systemd 跳过了。读 `~/rm2-evidence-xxx/journal-xochitl.log` 看具体原因
- 如果"xochitl 进程不存在" → 这就是砖机现场。**先确认根因再救活**:

  ```bash
  # 上 rm2 跑 LD_DEBUG 实验
  scp ~/rm2-forensic.sh root@10.11.99.1:/tmp/
  ssh root@10.11.99.1 'sh /tmp/rm2-forensic.sh'
  # 把证据拉回来
  scp -r root@10.11.99.1:/tmp/rm2-forensic-* ~/
  ```

  然后救活:
  ```bash
  bash rm2-rescue.sh rescue
  ```

**Case B: 状态停在 `sdp`** (设备真砖)

脚本会打印完整的 `ddvk recovery` 流程指引。需要:

- 安装 `imx_usb_loader`: `sudo apt install imx-usb-loader`
- clone `https://github.com/ddvk/remarkable2-recovery`
- 跑 `sudo ./recover.sh` 推 u-boot

推完后 rm2 进 recovery Linux, 自动转入 Case A 流程。

**Case C: 状态停在 `ping_only`** (xochitl 死了 sshd 也死了)

观察 30 秒看 systemd 会不会重启 sshd。如果一直停在 ping_only, 需要硬件触发 SDP (走 Case B)。

**Case D: 状态停在 `no_usb`** (USB 都没出来)

检查线材、USB 端口供电。`dmesg | tail -20` 看插拔事件。

### Step 4 — 救活之后分析根因

证据齐了之后:

```bash
bash rm2-rescue.sh analyze ~/rm2-evidence-xxx
```

会输出每一类故障证据 + 推荐下一步。

## 救活原理

`install.sh` 写的 drop-in 文件:

```
/etc/systemd/system/xochitl.service.d/zz-rmkit-cn.conf
    └── Environment="LD_PRELOAD=xovi.so:ime_hook.so"
```

砖机当时 xochitl 走这个 drop-in → `dlopen(ime_hook.so)` 触发 constructor → constructor 访问 Qt 内部符号 → 新固件 Qt layout 变了 → segfault → systemd 反复重启 → 进 `start-limit-burst` → 死循环。

**救活 = 删掉 drop-in**, 让 xochitl 走默认 unit, 不加载任何 `.so`, 等同于"从来没装过 rmkit-cn"。

`/home/root/rmkit-cn/` 和 `/home/root/xovi/` 的文件**不删**, 保留给后续 forensic + 重装。

## 关键注意

1. **千万不要 fsck rm2 分区** — 会清掉 reMarkable 私有 xattr。脚本默认不会跑 fsck
2. **救活后不要立刻重装 rmkit-cn** — 先用 forensic 脚本确认 ime_hook.so 在当前固件上 dlopen 不死才能装回去
3. **/etc 是 tmpfs overlay** — 救活脚本会同时清 tmpfs upper 和 ext4 lower, 重启后 drop-in 也不会再回来
4. **rm2 没有 A/B 分区自救** — 砖了只能硬件救, 这是为什么我们要 forensic 出确凿根因
5. **rm2 SSH 密码** 在脚本里默认 `0VaVOsP9Qa` (最近 Settings 里看到的)。如果改过密码改环境变量:
   ```bash
   RM2_PASSWORD=xxx bash rm2-rescue.sh
   ```

## SSH 通了之后人工救活 (不用脚本)

如果脚本卡住或网络不稳, 手动两条命令救活:

```bash
ssh root@10.11.99.1
# 在 rm2 内:
rm /etc/systemd/system/xochitl.service.d/zz-rmkit-cn.conf
mount --bind / /tmp/lc && mount -o remount,rw /tmp/lc
rm -f /tmp/lc/etc/systemd/system/xochitl.service.d/zz-rmkit-cn.conf
sync && umount -l /tmp/lc && rmdir /tmp/lc
systemctl daemon-reload
systemctl start xochitl
```

## 预期结果

- Step 2 启动监控 ≈ 5 秒
- Step 3 自动抓证据 ≈ 30 秒 (取决于 journal 大小)
- Step 3 救活动作 ≈ 10 秒
- Step 4 跑 forensic 实验 ≈ 30 秒

全程 < 2 分钟 (前提 SSH 已通)。如果走 SDP recovery 路径多 15-30 分钟 (推 u-boot + 启动 recovery Linux)。
