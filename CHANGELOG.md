# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 格式,
版本号遵循 [SemVer](https://semver.org/lang/zh-CN/).

## [Unreleased]

## [1.2.1] - 2026-09-12

### Added

- 助手: Android 启动诊断按钮 (固件/槽位/错误计数/内核链接/包装状态 + /native-boot.log + 内核日志摘要, 保存为文件方便发 Issue); 进 Android 前自动打开内核日志采集。
- 助手: 记住密码 (系统钥匙串)、连接断开自动重连、下载支持代理与取消。

### Fixed

- 助手: 计划空列表序列化为 null 导致预览报错; WebView 不支持 confirm() 导致按钮无反应, 改原生对话框。
- Android 安装脚本: 模板文件名 (.tmpl) 引用错误; rootfs 下层绑定挂载残留导致二次安装失败。
- 单槽 Android: rm-native-controls 三处 `mmc bootpart enable 1 0` 会把设备切到另一个槽 (PaperHome 回原厂 / 健康探针 / 定时返回), 已移除; rm-android-init-ss 改基于 v8 重建 (宿主接管 Wi-Fi 用 reMarkable 已保存网络、ashmem、去 memfd 标志)。
- 微信读书秒退: 模块包补 ashmem_linux + depmod, 关 redroid memfd 自愈, /dev/ashmem 权限兜底。
- 联网探测 URL 改国内可达, 避免 Android 判定网络受限。

## [1.2.0] - 2026-09-07

### Added

- **桌面助手 `desktop/` (Go + Wails)**: Mac / Windows 双击即用的安装器。只走 USB / 局域网直连,
  没有服务器、没有遥测; 连接后只读探测机型/固件/槽位/空间, 不进用户文档目录; 每条远端命令与
  写入的文件都记在本机审计日志。功能: 安装/更新/卸载 rmkit-cn, RMPPM 单槽 Android 安装/卸载/
  进出 Android/重置数据/安装 APK。载荷包为 zip + manifest, 逐文件校验 sha256。
  同一内核另有命令行版 `assistant-cli`。
- **RMPPM 单槽 Android**: reMarkable 与 Android 共用当前槽, 重启不切槽; Android 系统与数据放
  共享的 /home, rootfs 只多 ~27MB; `/sbin/init` 包装按开机标志分流, 任何失败都回到 reMarkable。
  高级面板的 Android 按钮改走单槽启动器 (缺组件时拒绝并列出缺失, 不再 `rootdev --switch`)。
- **rm2 整句输入 (librime) + 五笔 86**: armv7 交叉编译的 librime 后端; 高级面板设置区可切换
  拼音 / 五笔方案; 物理键盘五笔连打修复 (光标反推旁路默认关)。
- 动态区分物理 / 虚拟键盘, 自动开关光标推断; rm2 冷启动注入自动恢复的 systemd 单元。
- 高级面板横屏跟随设备方向; 小屏可滚动。

### Changed

- 显示桥 v55 适配固件 3.28 (5.8.x) 的 libqsgepaper (去掉 EPContentMap, 成员偏移 -0x20)。

### Fixed

- **install.sh 不再 `chown -R root:root /home/root`** (收窄为 rmkit / xovi 目录): 单槽 Android 的
  系统与 /data 也在 /home/root 下, 整树 chown 会毁掉应用数据属主并清 setuid 位。
- rm2 输入法无候选框 + bad_alloc: 陈旧 dist 后端无 /rime 路由导致 404 死循环; 前端加退避。
- rm2 3.28 上 librarian 漏堆, 不再部署到 armv7。

### 之前累积在 Unreleased 的改动

### Changed

- **`tools/hash-qmd.py` + `tools/qmd_hash_check.py` Go 重写为 `tools/qmd-tool/`**:
  ime-server 18M 是 rime-frost 词库 embed 的 Go 二进制, 设备上能跑;
  原 Python 工具在 reMarkable Paper Pro Move (`imx93-chiappa`) 上**没有** Python3
  可用 (`/usr/bin/python*` 不存在). 这导致设备端 OTA "本机重编 .qmd 对齐当前 hashtab"
  这一步走不通 — 这是 OTA 的关键阻塞.
  - 新增 `tools/qmd-tool/` (Go, 0 外部依赖, 纯标准库), 单一二进制提供 `hash` / `check` 子命令
  - 三平台 cross-compile (host / aarch64 / armv7), 各 ~2 MB
  - golden 单测 (`compile_test.go`) 用真实 `qmd-src/*.qmd` + 现役 hashtab 对比 dist 产物,
    保证 byte-for-byte 与 Python 版完全一致
  - `installer/install.sh` 不再 require `python3`, 改调 `dist/qmd-tool hash`
  - `.github/workflows/ci.yml` 用 `qmd-tool check` 替代旧 `python3 tools/qmd_hash_check.py`
  - 旧 `tools/hash-qmd.py` + `tools/qmd_hash_check.py` 归档到 `legacy/qmd-tool-py/`
  - 文档 (README / CONTRIBUTING / docs/architecture / docs/devices / docs/upgrade-sop) 同步
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
- [ ] qmd-tool check 支持按机型分别校验 (而不是只取并集)
- [ ] release 自动打包 (installer + dist 产物 → GitHub Release tarball)
- [ ] CHANGELOG 自动从 conventional commit 生成 (例如 git-cliff)

### 0.3.0+

- [ ] 第三方 AI 端点配置预设 (一键填好 dashscope / DeepSeek 等常见服务)
- [ ] 拼音词库个人化 (用户高频词学习)
- [ ] 笔记 AI 助手扩展 (摘要 / 翻译 / 改写)

---

[Unreleased]: https://github.com/boangs/rmkit/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/boangs/rmkit/releases/tag/v0.1.0
