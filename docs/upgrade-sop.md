# 升级 SOP

> 历史 6 次升级事故的共同模式: **改文件 + 立即重启 xochitl** → 注入加载失败 → `OnFailure=emergency.target` (出厂 override 无法删) → errcnt 累 3 → A/B 自动切换 (RMPP) 或假性砖机 (rm2 无 A/B).
>
> 本文是把这套经验固化成项目级流程, 任何升级 / 改 install.sh / 动 xochitl 启动方式之前必须先读完.

---

## 历史事故清单

| # | 触发 | 后果 |
|---|---|---|
| 1 | 启用 inactive `appload.so` 后重启 xochitl | A/B 回滚 3.26→3.25 |
| 2 | deploy 脚本备份 .bak 留在 `extensions.d/` → 重启 | xovi fatal → errcnt 累 3 → A/B |
| 3 | qmldiff 调试 5 分钟内 restart xochitl 8+ 次 | restart 风暴 → A/B |
| 4 | dist 双目录漂移 + hash-qmd 关键字 bug | 功能集体消失 (没 A/B 但等同事故) |
| 5 | rm2 加 `Requires=home.mount` 后重启 | rm2 无 A/B → 真砖 SSH 不通 |
| 6 | 全套部署 + 立即 `systemctl restart xochitl` | A/B 自动切换 (RMPP Ferrari) |

---

## 铁律 (按优先级)

### 1. 升级前必读 checklist

任何 rmkit-cn 升级 / 改 `installer/install.sh` / 动 xochitl 启动方式之前, 必须先读完:

- 本文档
- `docs/devices.md` — 三机型差异
- `docs/architecture.md` — xovi / qmldiff / LD_PRELOAD 的失败模式
- `~/.claude/projects/-Users-xurx-tmp/memory/feedback_xovi_*.md` (如使用 Claude Code)

把里面"不要 X"和"X 之前先 Y"的规则全列出来作 checklist, 不靠直觉.

### 2. **永远不要**在同一个 SSH session 里"部署 + restart xochitl"

- **部署**(覆写 `.so` / `.qmd`) 本身**不影响**运行中的 xochitl (inode 替换), 是**安全**的.
- **危险动作**是**主动让 xochitl 加载新代码**(`systemctl restart xochitl`):
  - 任何 `.so` ABI 不兼容 / `.qmd` hash 不命中 → xochitl crash
  - → `OnFailure=emergency.target` (出厂 override, 无法删)
  - → errcnt 累 3 → RMPP 自动 A/B 切换 / rm2 假性砖机

### 3. 升级默认策略 = 延迟生效

**部署后不重启 xochitl**, 让用户**自然冷启动 / 下次开关机**让新代码加载.

好处:
- 用户场景下加载失败由 RMPP A/B 兜底, 走的是设计预期路径, 不是事故
- 即使失败, 用户 SSH 还能进 (没在 SSH session 中触发)

`installer/install.sh` 当前末尾**不**调用 `restart xochitl`, 是对的. **永远不要给它加自动 restart**.

### 4. 立即生效 = 必须带回滚 + 监控

如果用户明确要求"现在就生效", 走独立 `installer/apply-and-restart.sh` (待写), 必须满足:

1. 备份 `/home/root/xovi/extensions.d/` 到 **xovi 外部目录** (例如 `/home/root/xovi-backup/<ts>/`, 绝对不留同目录)
2. 备份 `/home/root/xovi/exthome/qt-resource-rebuilder/*.qmd` 同上
3. 记录 `rootdev --active` / `cat /sys/devices/platform/lpgpr/root{a,b}_errcnt` / `cat /etc/version`
4. **另开一个 SSH session** 跑 `journalctl -u xochitl -f` 实时观察
5. `systemctl restart xochitl` 后等 15s, 检查:
   - `systemctl is-active xochitl` = active
   - `/proc/$(pgrep -f /usr/bin/xochitl)/environ` 含 `LD_PRELOAD`
   - `journalctl -u xochitl -b 0 | grep -iE "error|cannot open|preload"` 为空
6. 失败立即回滚: 把备份覆盖回 `extensions.d/qt-resource-rebuilder`, `echo 0 > /sys/devices/platform/lpgpr/root{a,b}_errcnt`, **再**重启 xochitl 验证回滚成功
7. 重启间隔 ≥ **1 分钟**, 防止累 errcnt 触发自动 A/B
8. SSH 一旦开始 timeout / 拒绝 / `Connection closed by remote host` → **立即停手**

### 5. 三台设备都按这个走

rm2 (无 A/B) 风险更高, RMPP/RMPPM 有 A/B 兜底但 errcnt 累 3 仍切换. 流程对三台一致.

---

## 实操 checklist (升级一台设备前)

```
□ 读完铁律 #1 列的文档
□ SSH 进设备跑 installer/diagnose.sh (或手工跑等价命令):
    rootdev --active                           # 看是否在主 slot
    cat /sys/devices/platform/lpgpr/root{a,b}_errcnt   # 应为 0
    ls /home/root/xovi/extensions.d/           # 不应有 .bak/.old/.tmp/.new
    cat /etc/systemd/system/xochitl.service.d/*.conf   # 不应有 Requires= 炸弹
□ 跑 installer/install.sh (只部署, 不重启 xochitl)
□ 验证独立 service:
    systemctl is-active rmkit-cn-upload rmkit-cn-ime-http rmkit-cn-version.path
    浏览器访问 http://10.11.99.1:8080
□ 告诉用户"新代码已部署, 下次冷启动生效"; 不要主动 restart xochitl
□ (可选) 用户要求立即生效 → installer/apply-and-restart.sh, 严格按铁律 #4
```

## 实操 checklist (升级出问题, A/B 切了)

```
□ 不要再操作设备, 让 errcnt 自然不再增加
□ 看 docs/devices.md "RMPP A/B slot 切换" 找回滚命令
□ 排查必看:
   - extensions.d 有无重名文件 (.bak / .old)
   - qmd hash 是否对得上 (跑 tools/qmd_hash_check.py)
   - drop-in 有无 Requires= 炸弹 (After= 才对)
□ 修问题 → 清 errcnt → 切回主 slot → reboot 验证
```

---

## CI 自动化兜底

`.github/workflows/ci.yml` 在每次 push / PR 时跑:

- `bash -n` + `shellcheck` 校验所有 shell
- `tools/qmd_hash_check.py` 校验 qmd 引用的 hash 全部命中 hashtab (孤儿 hash 是历史 A/B 切换根因)
- `go vet` + `go test` + cross-compile aarch64/armv7

任何一项 fail 都会卡 PR, 部署链上**不会**再出现 hash-qmd.py 失败时 stderr 当 stdout 写入的 Python traceback 进入 dist/ 这种事.
