# 架构

reMarkable 的 xochitl 是 Qt/QML 写的 ROM 应用, ROM 是 ext4 ro mount, 不能直接改.

rmkit-cn **不改 ROM**, 而是通过 [xovi](https://github.com/asivery/xovi) 在用户空间叠加修改:

```
xochitl (ROM, ro)
   │
   ├── LD_PRELOAD=xovi.so:ime_hook.so   ← drop-in 注入
   │      │
   │      ├── xovi.so       —— hooking 框架, 加载 extensions.d/*.so
   │      │      │
   │      │      ├── qt-resource-rebuilder   —— 把 qrc:/ 资源包改造成可注入
   │      │      │      └── 读 exthome/qt-resource-rebuilder/*.qmd
   │      │      ├── librarian.so            —— 笔记/文档热导入
   │      │      └── xovi-message-broker.so  —— 命名管道 IPC
   │      │
   │      └── ime_hook.so   —— rmkit-cn 写的 IME 输入拦截
   │             └── unix socket → ime-server (Go daemon)
   │
   └── /home/root/xovi/   ← 全部覆盖物在这里 (用户分区, 持久)
          ├── extensions.d/*.so       (xovi 扩展)
          ├── exthome/qt-resource-rebuilder/
          │     ├── *.qmd             (qmldiff 注入指令)
          │     ├── chess/*.svg|png   (assets/chess 部署到此)
          │     └── zh_CN.rcc + zh_CN/  (Qt 翻译资源)
          ├── xochitl-xovi            (xovi 包装的 xochitl 启动脚本)
          └── xovi.so                 (主 hook lib)
```

---

## 核心机制 1: LD_PRELOAD 注入

`/etc/systemd/system/xochitl.service.d/zz-rmkit-cn.conf`:

```ini
[Unit]
After=home.mount

[Service]
Environment="LD_PRELOAD=/home/root/xovi/xovi.so:/home/root/rmkit-cn/bin/ime_hook.so"
```

xochitl 启动时 ld.so 处理 LD_PRELOAD, 把这两个 .so 提前加载. xovi 扫描 `extensions.d/` 加载所有扩展, ime_hook 通过 `dlsym` 拦截 Qt 输入法相关函数.

### 失败模式

| 现象 | 根因 |
|---|---|
| 高级面板 / IME / 中文全没了 | LD_PRELOAD 静默 ignore (`/home` 没挂好就启动 xochitl, .so 找不到; journal: `cannot open shared object file: ignored`) |
| xochitl 永远 inactive, sshd 不起 | drop-in 用了 `Requires=home.mount`, rm2 上没这个 unit → 卡 multi-user.target |
| xochitl crash loop, A/B 切换 | 某个 .so ABI 不兼容; 看 `journalctl -u xochitl -b -1 \| grep -iE "preload\|cannot open"` |

详见 `docs/upgrade-sop.md` + memory `feedback_xochitl_dropin_after_home`.

---

## 核心机制 2: qmldiff 注入

xochitl 的 UI 是 Qt qrc:/ 内嵌资源 (read-only). qt-resource-rebuilder 在加载时**重构 qrc 树**, 用 `*.qmd` 指令补丁原 .qml.

### qmd 指令格式

```
AFFECT [[<MainView_class_hash>]]
TRAVERSE [[<children_hash>]]
LOCATE [[<rectangle_hash>]]
INSERT BEFORE {
    Item {
        // 任意 QML 代码
    }
}
END
```

`[[hash]]` 是 u64 BE, 由 `tools/hash-qmd.py` 把 identifier 名 (`MainView` / `children` / ...) 查 `hashtab` 替换得来.

### hashtab 是什么

`hashtab` 是 xovi qt-resource-rebuilder 维护的 identifier → hash 映射表. **每个 reMarkable 系统版本可能不一样**, 所以 `tools/hashtabs/` 按机型+版本分了快照.

### 失败模式 (历史 A/B 切换主因)

| 现象 | 根因 |
|---|---|
| 注入 silent skip (功能消失但不 crash) | hash-qmd.py 漏处理某关键字, 错把保留字 hash 化, 破坏 typeof 比较表达式 |
| xochitl crash → A/B 切换 | qmd 引用的 hash 在 device 当前 hashtab 里**不存在** ("孤儿 hash"), qmldiff Rust panic |
| dist/*.qmd 是 Python traceback | hash-qmd.py 失败时, 调用方把 stderr 重定向到 stdout, traceback 当 .qmd 写入 dist/ |

CI 兜底:
- `tools/qmd_hash_check.py` 校验所有 qmd hash 在任一 hashtab 命中
- `installer/install.sh` 部署前 `qmd_is_valid()` 拒绝 traceback 文本

---

## 核心机制 3: 中文 IME 数据流

```
笔/键盘 触摸 → xochitl Qt 文本框
                  │
                  ▼ (Qt 信号)
          ime_hook.so 拦截 commitInputMethod
                  │
                  ▼ (unix socket /tmp/rmkit-cn-ime.sock)
            ime-server (Go daemon)
                  │
                  ├── 拼音引擎 (FST + 高频词词库, rime-frost)
                  ├── 候选生成
                  └── 状态机 (输入 / 候选 / 翻页 / 退格)
                  │
                  ▼ (JSON over socket 回写)
          ime_hook.so → Qt replaceComposeText
                  │
                  ▼
              UI 更新候选栏 + 文本框
```

候选栏 UI 是 `qmd/pinyin_interceptor.qmd` 注入的 **detached 浮动 popup** (从键盘弹层移到屏幕上, 自由位置), 不是 Qt 系统 InputMethod 的默认行为.

退格特殊处理: 用 **U+200B 零宽空格**作为哨兵, ime_hook 检测到 backspace 在零宽空格上时知道这是 IME 自定义清除, 而不是真删除原文 (见 memory `project_rmkit_cn_ime`).

---

## 核心机制 4: upload-server (扫码上传 / AI / 字体 / 截图)

独立 Go HTTP daemon (端口 8080), 与 xochitl 解耦. systemd unit `rmkit-cn-upload.service` 管理.

```
http://10.11.99.1:8080/
   ├── /              → static/index.html (管理控制台)
   ├── /qr            → static/qr.html    (扫码上传 + AI 配置)
   ├── /api/screens   → 截图 list/upload/download/delete
   ├── /api/fonts     → 字体管理
   ├── /api/ai/config → AI 端点配置 (OpenAI 兼容)
   └── /api/version   → 版本信息 (path watcher 触发推送)
```

AI 配置写到 `/home/root/.local/share/rmkit-cn/ai_config.json`, advanced_panel.qmd 的 AI 按钮读这个文件.

---

## 部署单元清单

`installer/install.sh` 部署到设备的目标位置:

| 来源 | 目标 |
|---|---|
| `dist/ime-server` (cross-built) | `/home/root/rmkit-cn/bin/ime-server` |
| `dist/ime_hook.so` | `/home/root/rmkit-cn/bin/ime_hook.so` |
| `dist/upload-server-aarch64` | `/home/root/rmkit-cn/bin/upload-server` |
| `dist/*.qmd` (qmd-src 编译产物) | `/home/root/xovi/exthome/qt-resource-rebuilder/` |
| `qmd/pinyin_interceptor.qmd` (无需编译) | 同上 |
| `qmd/zh_CN.rcc` + `qmd/zh_CN/` | 同上 |
| `assets/chess/*.svg` `*.png` | `/home/root/xovi/exthome/qt-resource-rebuilder/chess/` |
| `vendor/extensions/<ext>-<arch>.so` | `/home/root/xovi/extensions.d/<ext>.so` |
| `dist/reMarkable_zh_CN.qm` | `/usr/share/remarkable/xochitl/translations/` |
| `systemd/*.service` `*.path` | `/etc/systemd/system/` (bind-mount 持久化) |
| `systemd/zz-rmkit-cn.conf` | `/etc/systemd/system/xochitl.service.d/` (LD_PRELOAD 注入入口) |

`/etc` 是 overlayfs (lowerdir=ext4 ro, upperdir=tmpfs), 直接写会随 systemctl daemon-reload 丢. install.sh 用 `mount --bind /` 临时暴露下层 ext4, 写到下层做持久化.
