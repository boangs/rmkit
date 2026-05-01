# rmkit-cn

reMarkable 平板的中文化、AI、IME 与扩展工具集。

通过 [xovi](https://github.com/asivery/xovi) 的 LD_PRELOAD + qmldiff 机制注入，
不修改 ROM、不破坏 OTA、与系统 A/B 分区机制兼容。

---

## 设备支持矩阵

| 代号 | 机型 | 架构 | A/B 分区 |
|---|---|---|---|
| `rm2` | reMarkable 2 | armv7l | ✗ (假性砖机风险高) |
| `rmpp-ferrari` | reMarkable Paper Pro | aarch64 | ✓ |
| `rmpp-chiappa` | reMarkable Paper Pro Move | aarch64 | ✓ |

所有代码必须三机型兼容。详见 [`docs/devices.md`](docs/devices.md)。

---

## 目录结构

```
.
├── installer/           部署脚本 (install.sh / uninstall.sh / xochitl-xovi)
├── qmd-src/             qmldiff 注入源代码 (.qmd)
│                        ├── advanced_panel.qmd      高级面板 (字体/AI/华容道/...)
│                        ├── ai_text_button.qmd      笔记中 AI 按钮注入
│                        └── language_zh_cn.qmd      系统中文化注入
├── qmd/                 不经编译的 qmldiff (拼音 IME 拦截器, hash 已对齐)
│                        ├── pinyin_interceptor.qmd  拼音浮动候选栏
│                        ├── zh_CN.rcc               qrc 资源
│                        └── zh_CN/                  qm 翻译
├── ime-go/              拼音 IME 引擎 (Go, FST 词库)
├── intercept/           xochitl 输入法 hook (C++ → ime_hook.so)
├── upload-server-go/    扫码上传 / AI 配置 / 字体&截图管理后端 (Go)
│   └── static/          web UI (qr.html / index.html)
├── legacy/              历史归档 (不再部署, 仅供参考)
│   └── upload-server-py/   早期 Python 上传服务器
├── systemd/             *.service / *.path / udev 规则
├── scripts/             开发辅助 (apply-screen / version-switcher / 翻译批处理)
├── tools/               构建工具 (hash-qmd.py / create_rcc) + hashtab 当前副本
│   └── hashtabs/        按机型/版本分类的 hashtab 快照
├── assets/              静态资产 (chess/ 图标 svg/png)
├── vendor/              第三方源码副本
│   ├── extensions/      上游 librarian / xovi-message-broker .so
│   └── xovi/            上游 xovi tarball + bootstrap 脚本
├── qml-dump/            参考材料 (设备 QML 反编译)
├── docs/                架构 & 升级 SOP & 设备矩阵 (architecture / upgrade-sop / devices)
└── dist/                构建产物 (gitignore, 由 install.sh 现场编译)
```

---

## 构建 & 部署

### 前置

- macOS / Linux 开发机
- Go ≥ 1.22 (`brew install go`)
- Python 3 (用于 `tools/hash-qmd.py`)
- ssh 已配置到 `root@10.11.99.1` (USB-C)
- 设备已安装 [xovi](https://github.com/asivery/xovi) (一次性, 见 `vendor/xovi/`)

### 部署

```bash
bash installer/install.sh
```

`install.sh` 会:

1. 同步设备最新 hashtab → `tools/hashtab`
2. 用 `tools/hash-qmd.py` 重编 `qmd-src/*.qmd` → `dist/*.qmd`
3. **预检** `dist/*.qmd` 不是 Python traceback (历史事故根因)
4. 部署 .qmd / .so / IME / upload-server / 翻译 / 资产
5. 写入 systemd unit (bind-mount 持久化绕过 /etc overlayfs)
6. **不主动重启 xochitl** — 让用户冷启动自然加载

### 卸载

```bash
bash installer/install.sh --uninstall
# 或
bash installer/uninstall.sh
```

---

## 升级 SOP（必读）

历史 6 次升级事故全部源于"改文件 + 立即重启 xochitl"模式 →
xochitl crash → `OnFailure=emergency.target` → errcnt 累 3 → A/B 切换。

**铁律**:

1. **永远不要**在同一个 SSH session 里"部署 + restart xochitl"
2. 默认走**延迟生效**: 部署后让用户冷启动加载新代码
3. 立即生效必须走带回滚 + 监控的独立脚本 (`apply-and-restart.sh`, 待写)
4. 任何 `.qmd` 部署前必须 grep 验证所有 hash 命中当前 hashtab
5. xochitl drop-in 用 `After=home.mount`,**绝不**用 `Requires=`

详见 [`docs/upgrade-sop.md`](docs/upgrade-sop.md) 和 [`docs/architecture.md`](docs/architecture.md)。

立即生效模式 (带回滚):
```bash
bash installer/apply-and-restart.sh
```

升级前预检:
```bash
bash installer/diagnose.sh
```

---

## 已知风险点

| 风险 | 现象 | 缓解 |
|---|---|---|
| qmd hash 不命中 | qmldiff Rust panic → xochitl crash → A/B 切换 | install.sh 部署前重编 + magic-byte 预检 |
| `dist/*.qmd` 是 Python traceback | hash-qmd.py 失败时 stderr 当 stdout 写入 | install.sh `qmd_is_valid()` 预检 |
| /etc 是 overlayfs(tmpfs) | systemd unit 重启丢失 | bind-mount 持久化 |
| LD_PRELOAD 早于 /home 挂载 | .so 静默忽略 → 注入全失效 | drop-in `After=home.mount` |
| extensions.d/ 留 .bak | xovi "processed more than once" fatal → A/B | 备份只放 xovi 目录外 |

---

## 贡献流程

详见 [`CONTRIBUTING.md`](CONTRIBUTING.md).

- 改 `.qmd` 注入: 先 `python3 tools/qmd_hash_check.py` 校验 hash 命中
- 改 Go: `cd ime-go && go vet ./... && go test ./...` (或 `upload-server-go`)
- 改 systemd unit: 改完跑 `systemd-analyze verify systemd/*.service`
- 提交前 `bash -n` + `shellcheck` (CI 也会跑)
- CI: GitHub Actions 自动跑 shell + python + qmd hash + go 全套校验

---

## License

(待定)
