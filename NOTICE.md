# 第三方代码致谢与许可证

本项目使用了以下开源项目的代码 / 二进制 / 数据。各项目原 LICENSE 全文见
[`third-party-licenses/`](third-party-licenses/) 目录。

---

## 1. asivery/xovi — GPL-3.0

**用途**：xovi 是 reMarkable 上 `LD_PRELOAD` + qmldiff 注入框架。我们项目所有 .qmd
注入都依赖 `xovi.so` + `qt-resource-rebuilder.so`。

**包含的文件**：
- `vendor/xovi/xovi-aarch64.tar.gz` — 上游官方发布的 RMPP/RMPPM 二进制
- `vendor/xovi/xovi-arm32.tar.gz` — 上游官方发布的 rm2 二进制
- `vendor/xovi/xochitl-xovi` — 上游官方 launcher 脚本

**项目地址**：https://github.com/asivery/xovi
**License 全文**：[`third-party-licenses/LICENSE.asivery_xovi`](third-party-licenses/LICENSE.asivery_xovi)

GPL-3.0 要求衍生作品也用 GPL-3.0 — 这也是我们项目用 GPL-3.0 的原因。

---

## 2. asivery/rm-appload — GPL-3.0

**用途**：xovi 的应用加载器扩展，让 reMarkable 能启动第三方 GUI 应用（如 KOReader）。

**包含的文件**：
- `appload.so` — 由用户从 https://github.com/asivery/rm-appload/releases 下载安装
- `qtfb-shim.so` — 跟 KOReader 一起部署，桥接 RM1 风格 framebuffer 到 RMPP QTFB

⚠️ rm-appload 二进制**不直接打包在仓库**，由 install.sh 在设备端按需下载。

**项目地址**：https://github.com/asivery/rm-appload
**License 全文**：[`third-party-licenses/LICENSE.asivery_rm-appload`](third-party-licenses/LICENSE.asivery_rm-appload)

---

## 3. awwaiid/ghostwriter — MIT

**用途**：reMarkable AI 手写交互参考实现。我们的"手写选区 AI"和"笔迹模拟"功能
直接参考它的 Rust 实现重写为 Go（`upload-server-go/internal/handwriting/`）。

**衍生使用**：
- `upload-server-go/internal/handwriting/handstrokes.json` — 完整 fork 自 ghostwriter 的
  `fonts/handstrokes.json`（约 6700 个汉字的笔画采样数据，用于笔迹模拟）
- `upload-server-go/internal/handwriting/handwriting.go` — 参考 ghostwriter 的
  `src/handwriting.rs` 和 `src/pen.rs` 改写

**项目地址**：https://github.com/awwaiid/ghostwriter
**License 全文**：[`third-party-licenses/LICENSE.awwaiid_ghostwriter`](third-party-licenses/LICENSE.awwaiid_ghostwriter)

MIT 要求保留 copyright notice — 我们在源代码注释中保留对 ghostwriter 的引用。

---

## 4. FouzR/xovi-extensions — GPL-3.0

**用途**：reMarkable qmldiff 注入的参考代码集合。我们的 `glyph_selection_ai.qmd`
中 toolbar 注入用的 `selectPen("primary")` API 路径就是从他们的 `gestures.qmd`
逆向出来的（GPL-3.0 hash 编码）。

**衍生使用**：
- 没有直接 fork 文件
- `qmd-src/glyph_selection_ai.qmd` 中的 selection toolbar TRAVERSE 路径 + selectPen
  调用方式参考自 FouzR 的 `selectionErase.qmd` 和 `gestures.qmd`

**项目地址**：https://github.com/FouzR/xovi-extensions
**License 全文**：[`third-party-licenses/LICENSE.FouzR_xovi-extensions`](third-party-licenses/LICENSE.FouzR_xovi-extensions)

---

## 5. gaboolic/rime-frost — GPL-3.0

**用途**：拼音 IME 的中文词库（基于中州韵 rime 生态的雾凇拼音方案，转换成 FST 格式）。

**包含的文件**：
- `ime-go/pinyin/dict/abbrev.fst` — 由 `gaboolic/rime-frost` cn_dicts 转换而来
- `ime-go/pinyin/dict/phrases.fst` — 由 `gaboolic/rime-frost` cn_dicts 转换而来
- `ime-go/tools/build_dict/main.go` — 词库转换工具，从 `gaboolic/rime-frost` cn_dicts 目录读取原始 rime 词典生成 FST

ime-server 二进制 (`dist/ime-server`) 通过 Go embed 内嵌上述 FST 文件。

**项目地址**：https://github.com/gaboolic/rime-frost
**License 全文**：[`third-party-licenses/LICENSE.gaboolic_rime-frost`](third-party-licenses/LICENSE.gaboolic_rime-frost)

GPL-3.0 与本项目 LICENSE 兼容。

---

## 6. librarian / xovi-message-broker — GPL-3.0（asivery）

**用途**：xovi 扩展。librarian 处理文档导入，xovi-message-broker 处理跨进程 IPC。

**包含的文件**：
- `vendor/extensions/librarian-aarch64.so` / `librarian-armv7.so`
- `vendor/extensions/xovi-message-broker-aarch64.so` / `xovi-message-broker-armv7.so`

二进制来源是 asivery 的 xovi 配套扩展，均为 GPL-3.0。

---

## 我们项目本身的 License

本项目整体采用 **GNU General Public License v3.0** —— 见 [`LICENSE`](LICENSE)。

GPL-3.0 是因为我们使用了 GPL-3.0 协议下的 xovi / rm-appload / xovi-extensions
二进制，根据 GPL "传染" 条款，衍生作品必须用兼容协议。

---

## 报告许可证问题

如果你认为本项目错误使用 / 引用了你的代码，或者上述 license 标注有误，请提
issue 或邮件联系 xurx@me.com，我们会立即更正或下架。
