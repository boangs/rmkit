# 设备矩阵

rmkit-cn 在编码期必须**同时兼容三台设备**, 任何只能在一台跑的代码都视为 bug.

## 矩阵

| 字段 | rm2 | rmpp-ferrari | rmpp-chiappa |
|---|---|---|---|
| 商品名 | reMarkable 2 | reMarkable Paper Pro | reMarkable Paper Pro Move |
| 内核架构 | armv7l (32-bit) | aarch64 | aarch64 |
| Go GOARCH | `arm` (GOARM=7) | `arm64` | `arm64` |
| C 工具链前缀 | `arm-linux-gnueabihf-` | `aarch64-linux-gnu-` | `aarch64-linux-gnu-` |
| A/B 双分区 | ✗ (单分区) | ✓ | ✓ |
| 失败兜底 | 无 → "假性砖机" | A/B 自动切换 | A/B 自动切换 |
| `/home` 挂载方式 | fstab + initramfs (无 `home.mount` unit) | systemd `home.mount` | systemd `home.mount` |
| 屏幕 | E-ink, 1404×1872 | E-ink, 1620×2160 | E-ink, 1620×2160 (折叠) |

## SSH 入口

- USB-C 直连, 设备 IP `10.11.99.1`, 用户 `root`
- 命令: `ssh root@10.11.99.1`
- **不要用** `ssh remarkable` 这种 host 别名 (历史误指向其他设备的事故)

## A/B 分区机制 (RMPP)

RMPP/RMPPM 有 root_a / root_b 双分区, 出厂的 `OnFailure=emergency.target` + errcnt 计数让"启动失败 3 次"自动切到备用 slot.

- 当前 slot: `rootdev --active`
- 错误计数: `cat /sys/devices/platform/lpgpr/root{a,b}_errcnt`
- 主动切换: `rootdev --switch` (注意**不是** `fw_setenv`, RMPP 无 u-boot env)
- 清错误计数: `echo 0 > /sys/devices/platform/lpgpr/root{a,b}_errcnt`

详见 memory `reference_rmpp_slot_switching` (如使用 Claude Code).

### errcnt 累计 = 自动 A/B 切换

xochitl crash 一次 → errcnt += 1. 累 3 触发自动切换. 这就是为什么:

- 不能"5 分钟内 restart 8 次" (qmldiff 调试风暴)
- 不能"改文件 + 立即 restart" (升级风暴)
- 重启间隔最好 ≥ 1 分钟, 给 errcnt 自然衰减空间

## rm2 风险更高

- **没 A/B 兜底** → 失败直接卡死, 屏幕停在 "Paper tablet is starting"
- 表面看是砖机, 实际 SSH 还可能没起来 (例如 `multi-user.target` 卡住)
- 修复路径: 先确认 USB ethernet 通 → 再确认 sshd 起来 → 没起来才考虑拆机刷 pogo

具体见 memory `feedback_xochitl_dropin_after_home` 的 2026-04-30 事故复盘.

## 架构相关代码点

### Go 交叉编译

走 Makefile (跟 CI 一致, 自动 `-trimpath -ldflags="-s -w"`):

```bash
cd ime-go && make build              # 同时 aarch64 + armv7 → ../dist/
cd upload-server-go && make build    # 同上
```

`installer/install.sh` 在 `case "$ARCH"` 分支自动选: aarch64 → `*-aarch64` 后缀, armv7l → `*-armv7` 后缀.

### xovi 扩展 .so 命名

`vendor/extensions/{librarian,xovi-message-broker}-{aarch64,armv7}.so`

部署时改名为 `librarian.so` / `xovi-message-broker.so` (xovi 不认架构后缀).

### hashtab 按机型分

`tools/hashtabs/`:
- `hashtab-rm2-3.26.0.68`
- `hashtab-rmpp-ferrari-3.26.0.68`
- `hashtab-rmpp-pp-3.26.0.68` (社区/老固件版本)
- `hashtab-rmpp-chiappa-3.26.0.68`

`tools/qmd_hash_check.py` 取所有的并集做"宽松校验": 任何 qmd 引用的 hash 至少在某一台设备的 hashtab 里. 严格校验 (按机型分别校验) 看后续是否要做.

### systemd unit 写法

- `xochitl.service.d/zz-rmkit-cn.conf` 的 `[Unit]` 段:
  - **必须**: `After=home.mount` (排序约束)
  - **绝对不要**: `Requires=home.mount` (硬依赖, rm2 上没这个 unit name → 卡 multi-user.target → 假性砖机)

详见 memory `feedback_xochitl_dropin_after_home`.
