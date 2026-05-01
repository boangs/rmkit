# 贡献指南

rmkit-cn 是面向 reMarkable 用户的中文化 / IME / AI 工具集. 本文规定开发流程,
保证三机型 (rm2 / rmpp-ferrari / rmpp-chiappa) 都不掉链子, 升级不再触发 A/B
回滚 (历史已发生 6 次).

---

## 开发前置

- macOS 或 Linux 开发机
- Go ≥ 1.24 (`brew install go` 或对应包管理器)
- Python 3
- `gh` CLI (用于 PR / repo 管理)
- USB-C 连接 reMarkable 设备
- ssh 到 `root@10.11.99.1` 已配通

---

## 修改不同模块的注意点

### 改 `.qmd` 注入 (qmd-src/ 或 qmd/)

1. 改完跑 `tools/qmd_hash_check.py` 校验所有 hash 命中:
   ```bash
   python3 tools/qmd_hash_check.py
   ```
2. 如新引用了 identifier, 跑一遍 `tools/hash-qmd.py qmd-src/foo.qmd` 看输出有没有
   `WARN: identifier <name> not in hashtab` (没在 hashtab 里就会被原样保留, 注入会
   silent skip).
3. 不是改 qmd-src 而是改 qmd 已 hash 化的成品 (例如 `qmd/pinyin_interceptor.qmd`):
   只能改 `INSERT { ... }` 里的 QML 代码, **不要碰 `[[hash]]` 或 `~&hash&~`**, 它们
   是与 hashtab 对齐过的, 改了就 panic.

### 改 Go (ime-go/ 或 upload-server-go/)

```bash
cd ime-go && go vet ./... && go test ./...

# cross-compile 看本地能不能编 — 用 Makefile 跟 CI 完全一致
# (-trimpath -ldflags="-s -w", 产物落 ../dist/, 比裸 go build 立省 30%)
make build           # 同时 aarch64 + armv7
make aarch64         # 只 aarch64
make armv7           # 只 armv7
make clean           # 清 dist/
```

**不要**裸跑 `go build` (没 strip, dist 会肿 30%, install.sh 部署量也跟着肿).

任何时候**避免 cgo** (除非有明确理由); cross-compile 静态二进制是首要约束, cgo 让
跨架构构建复杂 10 倍.

### 改 systemd unit

```bash
systemd-analyze verify systemd/*.service systemd/*.path 2>&1
```

xochitl 的 drop-in (`xochitl.service.d/zz-rmkit-cn.conf`) 改之前必读
`docs/upgrade-sop.md` + memory `feedback_xochitl_dropin_after_home`:

- `[Unit]` 段**只能**用 `After=home.mount` 软排序
- **绝对不要**用 `Requires=home.mount` (rm2 无此 unit, 卡 multi-user.target = 假性砖机)

### 改 `installer/install.sh`

1. `bash -n installer/install.sh` 语法
2. `shellcheck installer/install.sh` (CI 也跑)
3. 改完**绝不**自动 `systemctl restart xochitl` — 部署默认延迟生效
4. 任何新部署的资源要先在 `qmd_is_valid()` / 文件存在性 / 架构匹配 三处加预检

### 改 hashtab (替换 `tools/hashtab` / 加新 `tools/hashtabs/<机型>-<版本>`)

`tools/hashtab` 是 install.sh 同步用的工作副本, 一般不手改.

升级 reMarkable 系统大版本时:
1. 先在设备上跑 xovi 自带的 `rebuild_hashtable` (重新生成新版本的 hashtab)
2. `scp root@10.11.99.1:/home/root/xovi/exthome/qt-resource-rebuilder/hashtab tools/hashtabs/hashtab-<机型>-<版本>`
3. 跑 `tools/qmd_hash_check.py` 看 qmd 是否还命中
4. 不命中 → 改 qmd-src 重编

---

## 提交规范

[Conventional Commits](https://www.conventionalcommits.org/) 风格:

```
<type>(<scope>): <subject>

<body>

<footer>
```

`type`:
- `feat`     新功能
- `fix`      bug 修复
- `docs`     文档
- `chore`    项目结构 / 工具链 / gitignore / 依赖更新
- `refactor` 不改行为的重组
- `ci`       CI / GitHub Actions
- `perf`     性能优化
- `test`     测试

`scope` (可选): `ime` / `qmldiff` / `upload-server` / `installer` / `systemd` /
`tools` / `assets` / `vendor` 等.

示例:
```
feat(ime): 拼音浮动候选栏从键盘弹层移到屏幕

之前候选栏跟着 Qt 系统输入法弹层走, 在小屏被遮挡. 改用 detached popup,
通过 [parent: rootWindow] 脱离键盘 overlay, 浮动到屏幕中央.

详见 qmd/pinyin_interceptor.qmd.
```

---

## PR 流程

1. fork / 切分支: `feature/<short-name>` 或 `fix/<short-name>`
2. 一个 PR 一件事 — 别把"功能 + 重构 + 修 bug"塞一起, 不利于 bisect 和 review
3. CI 全绿才能 merge:
   - `bash -n` + `shellcheck`
   - `tools/qmd_hash_check.py` 全过
   - `go vet` + `go test` + cross-compile aarch64/armv7
   - `py_compile` Python 脚本
4. PR 描述写清楚: 改了什么 / 为什么 / 如何测试 / 影响哪些机型

---

## 升级前 checklist

任何动 install.sh 或部署链的 PR, 描述里必须勾选:

```
- [ ] 读过 docs/upgrade-sop.md 全文
- [ ] 没有让 install.sh 自动 restart xochitl
- [ ] 三机型 (rm2 / rmpp-ferrari / rmpp-chiappa) 部署路径都验证过
- [ ] CI 全绿 (qmd hash + shell + go + python)
- [ ] 改 systemd 时跑了 systemd-analyze verify
- [ ] 改 .qmd 时 qmd_hash_check.py 通过
```

---

## 常见陷阱速查

| 现象 | 90% 是这个原因 |
|---|---|
| 部署后中文/IME/高级面板全没了 | LD_PRELOAD 静默 ignore: `journalctl -u xochitl -b 0 \| grep "cannot open"` |
| RMPP 升级后回滚到旧固件 | A/B 切换: `rootdev --active` 看是不是在备用 slot, errcnt 是否 ≥ 3 |
| rm2 升级后 SSH 不通, 屏幕卡 starting | drop-in 写了 `Requires=home.mount`, 卡 multi-user.target |
| qmd 注入失败但 xochitl 还正常 | hash 不命中 → qmldiff silent skip; 跑 qmd_hash_check 验证 |
| qmd 注入失败 + xochitl crash | hash 不命中**且**触发 panic 路径; dist/*.qmd 可能是 Python traceback |
| 截图按钮 / AI 按钮 hover 无响应 | QML 信号处理器漏写显式参数: `(mouse) => ...` 而不是 `mouse => ...` |
| 翻译没生效 | qsTr 在 qmldiff INSERT 块里查不到 → 用 qsTranslate 或硬编码 unicode |

完整对照表见 `docs/architecture.md` 失败模式表.
