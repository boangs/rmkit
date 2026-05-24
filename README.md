# rmkit-cn

reMarkable 平板的中文化、AI、IME 与扩展工具集。

通过 [xovi](https://github.com/asivery/xovi) 的 `LD_PRELOAD` + qmldiff 机制注入，
不修改 ROM、不破坏 OTA、与系统 A/B 分区机制兼容。

---

## 功能

- 🇨🇳 **系统中文化**：UI 文字翻译（设置 / 文件夹 / 工具栏）+ 中文键盘
- ⌨️ **拼音输入法**：手写键盘 → 拼音浮动候选栏，FST 词库 (rime-frost)
- 🤖 **文本 AI**：选中文字 → 润色 / 翻译 / 总结 / 问答（OpenAI 兼容）
- ✍️ **手写 AI**：选中手写笔迹 → 视觉识别 → AI 回答 → 文字插入 OR 模拟笔迹回写
- 📥 **手机扫码上传**：reMarkable 网页二维码 → 手机推送 PDF/字体/壁纸 → 设备自动应用
- 🎨 **高级面板**：字体管理、壁纸切换、自定义启动器、AI 配置
- 🎮 **小游戏**：象棋、五子棋、华容道、跳棋
- 📚 **KOReader 启动器**：通过 [appload](https://github.com/asivery/rm-appload) 集成

---

## 设备支持

| 代号 | 机型 | 架构 | 验证状态 |
|---|---|---|---|
| `rmpp-chiappa` | **reMarkable Paper Pro Move** | aarch64 | ✅ 主力测试 |
| `rmpp-ferrari` | reMarkable Paper Pro | aarch64 | ⚠️ 同 aarch64 路径，未单独验证 |
| `rm2` | reMarkable 2 | armv7l | ⚠️ 代码支持，未近期实测 |

所有功能依赖 [xovi](https://github.com/asivery/xovi)（已自动检测安装）。

---

## 安装方式

**前置条件**：
1. reMarkable 设备已开启 Developer Mode（**注意：这会清空设备所有数据**）
   - Settings → General → About → Copyrights → 最底部记录 SSH 密码
   - Settings → General → Software → Enable Developer mode
2. 设备已 USB-C 连接电脑，能 `ssh root@10.11.99.1`

### 推荐：下载 Release 完整包（无需 git / Go 工具链）

```bash
curl -fLO https://github.com/boangs/rmkit/releases/latest/download/rmkit-cn-v1.0.0.tar.gz
tar -xzf rmkit-cn-v1.0.0.tar.gz
cd rmkit-cn-v1.0.0
bash installer/install.sh
```

完整包 (~77MB) 包含 install.sh、所有架构预编译产物 (`dist/`)、xovi 依赖 (`vendor/`)。

### 开发者：git clone

```bash
git clone https://github.com/boangs/rmkit
cd rmkit
bash installer/install.sh
```

`dist/` 在 .gitignore 里 (80MB 二进制不入 git)。install.sh 检测到缺失时自动从最新 Release 下载 `dist.tar.gz` (~34MB) 补齐。

`install.sh` 自动完成 7 步：
1. 检测设备架构 + 固件版本
2. 检查 xovi（缺失时自动解压 `vendor/xovi/xovi-{arch}.tar.gz` 部署）
3. 编译 `qmd-src/*.qmd` 到对应固件 hashtab
4. tar 流式推送 31MB payload（含 IME / AI / 字体 / 高级面板）
5. 写入 systemd unit + xochitl drop-in（**双写 ext4 lower 持久化**，含 wants symlink）
6. 第一次启动：临时 `LD_PRELOAD xochitl` 生成 hashtab → 设备端在线编译 .qmd
7. `systemctl restart xochitl` 让 LD_PRELOAD 立即生效

整个过程 **0 砖机**（详见下文砖机修复历史）。

安装完成后几秒内可用：
- 任意输入框点击 → 切换 "中文" 布局 → 拼音输入
- 选中文字 → "AI" 按钮 → 选操作（润色/翻译/总结/问答）
- 选中手写笔迹 → "AI" 按钮 → 同上
- Settings 顶部多了 "高级" 入口（字体、壁纸、AI 配置）

**OTA 升级后**：reMarkable 固件升级会重刷 rootfs，需要重跑一次 `bash installer/install.sh`。

### 卸载

```bash
bash installer/install.sh --uninstall
```

---

## AI 功能配置

安装完成后默认 AI 配置为空。需要配置 OpenAI 兼容服务（dashscope / 千问 / OpenAI 等）：

**方法 1：扫码 Web UI（最简单）**

设备 Settings → 高级 → 显示二维码 → 手机扫码 → 网页填入：
- API URL：如 `https://dashscope.aliyuncs.com/compatible-mode/v1`
- API Key：`sk-...`
- Model：`qwen3.6-plus`（或你的 vision 兼容模型）

**方法 2：SSH 直接改**

```bash
ssh root@10.11.99.1 'cat > /home/root/rmkit-cn/upload-server/ai-config.json' <<EOF
{
  "kind": "openai",
  "url": "https://api.openai.com/v1",
  "key": "sk-...",
  "model": "gpt-4o-mini"
}
EOF
ssh root@10.11.99.1 'systemctl restart rmkit-cn-upload'
```

---

## 已知问题与限制

| 问题 | 现象 | 状态 |
|---|---|---|
| 手写 AI 多行选区文字插入位置 | typingMode 默认把光标放第一行底部，多行选区时文字插入跟剩余行重叠 | 待修（reMarkable 没公开 view→scene API 转换） |
| 手写过程中真笔靠近屏幕画 ghost 射线 | 真笔 hover events 跟我们虚拟笔 events 共享 event2，xochitl 状态机混淆 | 写字时建议笔放屏幕 10cm 外（reMarkable 单笔状态机的硬限制） |
| OTA 升级后所有修改丢失 | rootfs 重刷 | 重跑 `install.sh` 一键恢复 |
| 启用 Developer Mode 强制清数据 | reMarkable 安全设计 | 笔记建议先 cloud sync 备份 |

---

## 代码架构

```
.
├── installer/           部署脚本
│   ├── install.sh        macOS 端开发者部署（7 阶段，含砖机修复）
│   ├── uninstall.sh
│   ├── reenable.sh       OTA 后一键恢复
│   ├── fw-upgrade.sh     固件升级触发的 qmd 重编
│   └── diagnose.sh       预检脚本
├── qmd-src/              qmldiff 注入源代码
│   ├── advanced_panel.qmd     高级面板（字体/AI/华容道/...）
│   ├── ai_text_button.qmd     文字选区 AI 按钮
│   ├── glyph_selection_ai.qmd 手写选区 AI 按钮 + 笔迹模拟
│   └── language_zh_cn.qmd     系统中文化
├── qmd/                  不经编译的 qmldiff
│   ├── pinyin_interceptor.qmd
│   └── zh_CN.rcc
├── ime-go/               拼音 IME 引擎（Go + rime-frost FST）
├── intercept/            xochitl IME hook（C++ → ime_hook.so）
├── upload-server-go/     文件上传 + AI 后端 + 截图（Go）
│   ├── internal/handwriting/   笔迹模拟引擎（hover 状态机）
│   ├── internal/server/        ai_glyph / screenshot_rmpp / evdev_input
│   └── static/                 Web UI（qr.html / index.html）
├── tools/qmd-tool/       qmd 编译 + hash 校验（Go）
├── systemd/              *.service / *.path
├── assets/chess/         游戏图标资源
├── vendor/
│   ├── xovi/             上游 xovi tarball
│   └── extensions/       librarian / xovi-message-broker
└── docs/                 architecture / upgrade-sop / devices
```

---

## 升级安全规则（铁律）

历史 N 次砖机事故全部源于**不当的部署+重启时序**。规则：

1. **永远不要**在同一个 SSH session 里"部署 + 立即 restart xochitl"
2. install.sh 先写 `.last_fw_version`，**再**调 reenable.sh（防 fw-upgrade.sh race）
3. 所有 .qmd 部署前用 `qmd-tool check` 校验 hash 命中
4. xochitl drop-in 用 `After=home.mount` + `ConditionPathExists=` 守卫
5. systemd unit + `multi-user.target.wants/` symlink **双写 ext4 lower**（mount --bind / 后必须 remount,rw）
6. `daemon-reload` 必须在 `umount /tmp/lc` **之后**（mount 期间会 dbus race）
7. tar 推 payload 用 `--uid 0 --gid 0` + `--no-same-owner` + chown 兜底（防 /home/root owner 被 macOS uid 502 污染）

详见 [`docs/upgrade-sop.md`](docs/upgrade-sop.md) 和 [`docs/architecture.md`](docs/architecture.md)。

---

## 贡献

详见 [`CONTRIBUTING.md`](CONTRIBUTING.md)：

- 改 `.qmd`：先 `dist/qmd-tool check` 校验 hash 命中
- 改 Go：`cd ime-go && go vet ./... && go test ./...`（或 upload-server-go / tools/qmd-tool）
- 改 systemd unit：`systemd-analyze verify systemd/*.service`
- 提交前 `bash -n` + `shellcheck`

---

## 第三方代码致谢

本项目使用了以下开源代码，详细 license 标注与归属见 [`NOTICE.md`](NOTICE.md)：

| 项目 | License | 用途 |
|---|---|---|
| [asivery/xovi](https://github.com/asivery/xovi) | GPL-3.0 | LD_PRELOAD + qmldiff 注入框架 |
| [asivery/rm-appload](https://github.com/asivery/rm-appload) | GPL-3.0 | 应用加载器 + qtfb-shim（KOReader） |
| [awwaiid/ghostwriter](https://github.com/awwaiid/ghostwriter) | MIT | 笔迹模拟参考 + handstrokes.json 字体源 |
| [FouzR/xovi-extensions](https://github.com/FouzR/xovi-extensions) | GPL-3.0 | qmldiff 注入参考代码 |
| [gaboolic/rime-frost](https://github.com/gaboolic/rime-frost) | GPL-3.0 | 雾凇拼音词库 (FST 转换源) |

各上游 LICENSE 全文存放在 [`third-party-licenses/`](third-party-licenses/) 目录。

---

## License

本项目采用 [**GNU General Public License v3.0**](LICENSE)。

选择 GPL-3.0 的原因：我们的项目通过 `LD_PRELOAD` 装载 GPL-3.0 协议的 xovi.so，
根据 GPL "传染"条款衍生作品也必须使用兼容协议。
