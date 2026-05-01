# legacy/ime-py/

历史 Python 拼音输入法实现. **不再部署、不再维护**.

## 归档时间

2026-05-01 (v0.1.0 之后清理)

## 替代

[`ime-go/`](../../ime-go/) — Go 重写, 2026-04 引入, FST 词库 (rime-frost),
HTTP 控制接口, 浮动候选栏在 `qmd/pinyin_interceptor.qmd` 实现.

## 归档清单

```
ime-py/
├── *.py                          原 Python 实现 (pinyin / keyboard / injector / overlay / main / build_dict)
├── dict/chars.json               原始字典 (低频 / 演示用)
├── tests/                        pytest 用例
├── pytest.ini, requirements.txt
└── systemd/
    ├── rmkit-cn-ime.service       ExecStart=python3 main.py /dev/input/...
    ├── rmkit-cn-ime-udev.service  USB 键盘插拔触发器
    └── 99-rmkit-cn-ime.rules      udev 规则
```

## 替代理由

- **物理键盘事件**改由 `intercept/ime_hook.so` 通过 `LD_PRELOAD` 拦截 Qt 输入法函数
  实现, 不再依赖 `/dev/input/by-path/...` + Python 后台进程
- **浮动候选栏 UI** 改由 `qmd/pinyin_interceptor.qmd` (qmldiff 注入到 xochitl QML) 实现,
  跟系统键盘融合, 不再单独画 overlay
- **拼音引擎** 改由 `ime-go/cmd/ime-server` (Go HTTP 服务) 提供, 加载 rime-frost FST,
  比纯 Python char-by-char 匹配快得多
- 设备上不再需要 Python 运行时和 venv
- 跨架构编译方便 (ime-server 静态编译 aarch64 / armv7)

## 不再被引用

`installer/install.sh` 不再部署 `*.py` / 死 unit.
`installer/install.sh --uninstall` 仍然 `stop/disable` 老的 `rmkit-cn-ime.service` /
`rmkit-cn-ime-udev.service`, 仅为兼容历史设备上残留.

CI 不跑这里的 pytest.

如果某天发现 Go 版本漏了什么行为细节, 来这里翻 Python 代码确认期望.
