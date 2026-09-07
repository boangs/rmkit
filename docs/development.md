# 开发者说明

面向使用者的内容在 [README.md](../README.md)；这里是原 README 里的开发者部分。

## 从源码安装

```bash
git clone https://github.com/boangs/rmkit
cd rmkit
bash installer/install.sh
```

`dist/` 在 .gitignore 里（预编译二进制不入 git）。install.sh 检测到缺失时自动从最新 Release 下载 `dist.tar.gz` 补齐。

建议先 `ssh-copy-id root@10.11.99.1`，否则脚本内的多次 ssh/scp 每次都要输密码。

`install.sh` 的步骤：

1. 检测设备架构 + 固件版本
2. 检查 xovi（缺失时自动解压 `vendor/xovi/xovi-{arch}.tar.gz` 部署）
3. 编译 `qmd-src/*.qmd` 到对应固件 hashtab
4. tar 流式推送 payload（含 IME / AI / 字体 / 高级面板）
5. 写入 systemd unit + xochitl drop-in（双写 ext4 lower 持久化，含 wants symlink）
6. 首次启动：临时 `LD_PRELOAD xochitl` 生成 hashtab → 设备端在线编译 .qmd
7. `systemctl restart xochitl` 让 LD_PRELOAD 生效

桌面助手 `desktop/` 把第 1、2、4 步的主机侧逻辑移植成 Go，设备端六阶段脚本原样内嵌（`desktop/internal/scripts/`），改动 install.sh 的设备端段落时两边要同步。

## AI 配置（SSH 方式）

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

## 代码架构

```
.
├── installer/           部署脚本
│   ├── install.sh        主机端部署（六阶段防砖）
│   ├── reenable.sh       OTA 后一键恢复
│   ├── fw-upgrade.sh     固件升级触发的 qmd 重编
│   ├── precheck.sh       fail-open 启动预检
│   └── diagnose.sh       诊断脚本
├── desktop/              rmkit 助手（Go + Wails，Mac / Windows）
├── qmd-src/              qmldiff 注入源代码
│   ├── advanced_panel.qmd     高级面板（字体/AI/游戏/...）
│   ├── ai_text_button.qmd     文字选区 AI 按钮
│   ├── glyph_selection_ai.qmd 手写选区 AI 按钮 + 笔迹模拟
│   └── language_zh_cn.qmd     系统中文化
├── qmd/                  不经编译的 qmldiff
├── ime-go/               拼音 IME 引擎（Go + rime-frost FST）
├── intercept/            xochitl IME hook + 运行时 QML 注入（C++）
├── upload-server-go/     文件上传 + AI 后端 + 截图（Go）
├── tools/qmd-tool/       qmd 编译 + hash 校验（Go）
├── systemd/              *.service / *.path / *.timer
├── assets/chess/         游戏图标资源
├── vendor/               xovi tarball、librarian / xovi-message-broker
└── docs/                 architecture / upgrade-sop / devices / development
```

## 升级安全规则（铁律）

历史多次砖机事故全部源于不当的部署与重启时序：

1. 永远不要在同一个 SSH session 里“部署 + 立即 restart xochitl”
2. install.sh 先写 `.last_fw_version`，再调 reenable.sh（防 fw-upgrade.sh race）
3. 所有 .qmd 部署前用 `qmd-tool check` 校验 hash 命中
4. xochitl drop-in 用 `After=home.mount` + `ConditionPathExists=` 守卫
5. systemd unit + `multi-user.target.wants/` symlink 双写 ext4 lower（mount --bind / 后必须 remount,rw）
6. `daemon-reload` 必须在 `umount /tmp/lc` 之后
7. tar 推 payload 用 `--uid 0 --gid 0` + `--no-same-owner`，chown 兜底只限 rmkit / xovi 目录，绝不 `chown -R /home/root`（单槽 Android 的系统与数据也在那里）

详见 [upgrade-sop.md](upgrade-sop.md) 与 [architecture.md](architecture.md)。

## 已知限制

| 问题 | 现象 | 状态 |
|---|---|---|
| 手写 AI 多行选区文字插入位置 | 光标默认在第一行底部，多行选区时文字与剩余行重叠 | 待修（无公开 view→scene API） |
| 手写时真笔靠近屏幕画 ghost 射线 | 真笔 hover 与虚拟笔事件共享 event2 | 写字时笔离屏 10cm 以上 |
| OTA 升级后修改丢失 | rootfs 重刷 | 重跑安装即可 |

## 贡献

见 [CONTRIBUTING.md](../CONTRIBUTING.md)：改 `.qmd` 先 `dist/qmd-tool check`；改 Go 跑 `go vet ./... && go test ./...`；改 systemd unit 跑 `systemd-analyze verify`；提交前 `bash -n` + `shellcheck`。
