# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 格式,
版本号遵循 [SemVer](https://semver.org/lang/zh-CN/).

## [Unreleased]

### Changed

- **install.sh 走 tarball 单次流式传输**: 把原来 56 次 `scp` + 多次 `ssh` 调用
  收口成"本地构造 staging → `tar -czf - | ssh tar -xzf -` 1 次连接"
  - 部署体积: 30 MB (raw) → **13.6 MB** (gzip 流式, -55%)
  - SSH 连接数: ~60 次 → **2 次** (-97%)
  - 实测部署时间预计: 60-120s → **8-20s**
  - systemd unit 仍走 bind-mount 双写 (lower 持久 + upper 立即生效)
- **Go 二进制本地 build 强制 strip**: 新增 `ime-go/Makefile` 和
  `upload-server-go/Makefile`, 与 CI 命令一致 (`-trimpath -ldflags="-s -w"`).
  CONTRIBUTING.md / docs/devices.md 改为 `make build` 入口.
  实测 `dist/upload-server-aarch64` 9.2M → **6.3M** (-31%).
  (开发者本地裸 `go build` 漏 strip 是历史 dist 肿胀的根因.)

### Removed

- **早期 Python 拼音 IME 全部下线归档**: 早已被 Go `ime-server` + `ime_hook.so`
  + `pinyin_interceptor.qmd` 取代, 但仓库一直没归档. 本次清理:
  - `ime/` (整个 Python 实现 + tests) → `legacy/ime-py/`
  - `systemd/rmkit-cn-ime.service` (`ExecStart=python3 main.py ...`) → `legacy/ime-py/systemd/`
  - `systemd/rmkit-cn-ime-udev.service` (USB 键盘插拔触发器, Python IME 配套) → 同上
  - `systemd/99-rmkit-cn-ime.rules` (udev 规则, 触发上面那条) → 同上
  - `systemd/rmkit-cn-ime-go.service` 直接删除 (跟 `rmkit-cn-ime-http.service`
    内容完全重复, install.sh 也不引用 — 是历史孤儿)
  - `installer/install.sh` 删除 Python IME staging 分支
  - `installer/install.sh --uninstall` 仍 `stop/disable` 老 unit (兼容旧设备残留)
  - `installer/install.sh` 不再部署 `scripts/apply-font.sh` / `apply-screen.sh` 到设备 —
    这两个原本就不在生产路径上 (web UI 的 `/api/fonts` 接管了字体管理),
    脚本留在仓库 `scripts/` 给开发者本地引用即可
  - `legacy/ime-py/README.md` 写归档说明
  - 部署文件数: 58 → **52**

### Fixed

- **xochitl drop-in 部署缺失** (历史遗留, v0.1.0 漏): `systemd/zz-rmkit-cn.conf`
  从未入库, `installer/install.sh` 也未部署. 现象: 重启后只有 zh_CN.qm
  原生翻译生效 (xochitl.conf `language=zh_CN` 走 Qt 自带 i18n), 而 IME /
  AI / 高级面板 / qmldiff 全失效 (因都靠 LD_PRELOAD 注入 xovi+ime_hook).
  历史上设备能 work 完全靠手工/老 install 留在 ext4 lowerdir 的"野文件",
  OTA 切到干净 B slot 即崩盘.
  - 新增 `systemd/zz-rmkit-cn.conf` 模板 (After=home.mount + LD_PRELOAD +
    QT_RESOURCE_REBUILDER_PATH + WatchdogSec=0 + QML_XHR_*)
  - `install.sh` bind-mount 双写 lowerdir + upperdir, 顺手清
    `zz-rmkit-cn.conf.bak*` / `.old` 残留 (避免 #DEBUG_DISABLED 之类炸弹)
  - `install.sh --uninstall` 也走 bind-mount 双清

---

## [0.1.0] - 2026-05-01

首个工程化基线版本. 把过去半年散落在多次提交里的功能整合, 把口头/memory 里的
经验固化成项目级文档和 CI 校验.

### Added

#### 中文化
- 系统语言菜单注入 "中文 (简体)" 选项 (qmd-src/language_zh_cn.qmd)
- 注入 zh_CN.qm + 完整翻译 (qmd/zh_CN/, dist/reMarkable_zh_CN.qm)
- Cell 类的翻译 context 修正 (xxxCellItem 而不是 SettingsModel)

#### 拼音 IME
- xochitl 输入法 hook (intercept/, C++, ime_hook.so)
- Go pinyin daemon (ime-go/)
  - rime-frost FST 词库 + 高频词
  - HTTP 控制接口
  - 浮动候选栏 (qmd/pinyin_interceptor.qmd, 从键盘弹层移到屏幕)
  - 零宽空格哨兵处理退格

#### AI / 笔记增强
- 笔记编辑器 AI 按钮 (qmd-src/ai_text_button.qmd)
- 高级面板 AI 配置 (advanced_panel.qmd)
  - OpenAI 兼容协议
  - enable_thinking 思考模式开关
  - 多端点支持 (阿里云 dashscope / DeepSeek / 自建 vLLM)
- AI 配置存到 ~/.local/share/rmkit-cn/ai_config.json

#### 上传服务器 (Go 重写)
- /api/screens — 截图列表/上传/下载/删除
- /api/fonts — 字体管理 (含用户字体注入)
- /api/ai/config — AI 端点配置
- /api/version — 版本信息 + path watcher 推送
- web UI: index.html (管理) + qr.html (扫码上传 + AI 配置)
- 三机型交叉编译 (aarch64 + armv7)

#### 高级面板 (advanced_panel.qmd)
- 字体管理入口
- 截图管理入口
- AI 配置入口
- 华容道 (滑块拼图小游戏)
- AI/链接 SVG 图标 (assets/chess/)

#### 文件热导入
- librarian + xovi-message-broker 集成
- /run/xovi-mb 命名管道协议
- 不重启 xochitl 的热加载 importDocument

#### 工具链
- tools/hash-qmd.py — qmd-src/*.qmd → dist/*.qmd 编译, 把 identifier
  替换为 hashtab 里的 u64 hash
- tools/qmd_hash_check.py — 扫 qmd 引用 hash, 校验全部命中 hashtabs
- tools/create_rcc.go — Qt qrc 资源打包
- 多机型 hashtab 快照 (rm2 / rmpp-ferrari / rmpp-pp / rmpp-chiappa)

#### 部署
- installer/install.sh — 三机型自动识别, 部署前预检 dist/*.qmd 不是
  Python traceback, systemd unit 用 bind-mount 持久化绕过 /etc overlayfs
- installer/uninstall.sh — 配套清理
- installer/diagnose.sh — 升级前 pre-flight (8 项检查)
- installer/apply-and-restart.sh — 立即生效模式, 带备份 + 回滚 + 监控

#### 工程化
- 严格目录分层: src / assets / vendor / tools / dist:
  - dist/ 整个 gitignore (纯构建产物)
  - assets/ — 静态图标
  - vendor/extensions/ — 上游 .so
  - vendor/xovi/ — xovi 第三方 release
  - tools/hashtabs/ — 按机型/版本分类 hashtab 快照
  - legacy/ — 历史归档 (Python upload-server)
- README + CONTRIBUTING + docs/{architecture,devices,upgrade-sop}.md
  覆盖全部"踩坑经验"
- GitHub Actions CI:
  - bash -n + shellcheck (severity: error)
  - py_compile Python 工具
  - tools/qmd_hash_check.py 校验 qmd hash 命中
  - go vet + go test + cross-compile aarch64/armv7
- tools/hashtab 改为运行时缓存 (gitignore + 缺失自动从 hashtabs/ 拷种子)

### Fixed (历史修复, 提及作存档)

- xochitl drop-in `Requires=home.mount` 炸弹 (rm2 卡 multi-user.target)
  → 改 `After=home.mount` 软排序
- hash-qmd.py KEYWORDS 漏 string 类型关键字 → 修补
- xovi extensions.d/ .bak 残留 → 部署不留同目录备份
- pinyin_input.qmd 含孤儿 hash 导致 RMPP A/B 切换 (2026-05-01) → 移到
  qmd/_obsolete/, 改用 pinyin_interceptor.qmd
- dist/upload-server-static/ 漂移 → install.sh 直接读 upload-server-go/static/
- Qt 6 信号处理器隐式参数失效 → 改用显式 (mouse) => {...}
- qsTr 在 qmldiff INSERT 块查不到翻译 → 改 qsTranslate 或硬编码 unicode

### Removed

- 早期 Python 版上传服务器 → 归档到 legacy/upload-server-py/
- 误入 git 的 Go 编译产物 (ime-go/{ime-arm64, ime-server-arm64,
  bin/ime-server}) — git rm --cached
- dist/install.sh 重复副本
- dist/upload-server-static/ 漂移产物

---

## 后续 release 计划 (路线图建议)

### 0.2.0 (proposed)

- [ ] 完善 docs/troubleshooting.md (常见问题排查决策树)
- [ ] systemd unit 加 `systemd-analyze verify` 到 CI
- [ ] qmd_hash_check.py 支持按机型分别校验 (而不是只取并集)
- [ ] release 自动打包 (installer + dist 产物 → GitHub Release tarball)
- [ ] CHANGELOG 自动从 conventional commit 生成 (例如 git-cliff)

### 0.3.0+

- [ ] 第三方 AI 端点配置预设 (一键填好 dashscope / DeepSeek 等常见服务)
- [ ] 拼音词库个人化 (用户高频词学习)
- [ ] 笔记 AI 助手扩展 (摘要 / 翻译 / 改写)

---

[Unreleased]: https://github.com/boangs/rmkit/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/boangs/rmkit/releases/tag/v0.1.0
