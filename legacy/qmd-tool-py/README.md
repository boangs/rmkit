# legacy/qmd-tool-py/

历史 Python 实现的 qmldiff 编译 + 校验工具. **不再使用、不再维护**.

## 归档时间

2026-05-01

## 替代

[`tools/qmd-tool/`](../../tools/qmd-tool/) — Go 重写, 单一二进制提供两个子命令:

- `qmd-tool hash [-hashtab path] <src.qmd>` 替代 `hash-qmd.py`
- `qmd-tool check [-hashtabs dir] [-qmd dir]` 替代 `qmd_hash_check.py`

## 替代理由

- **设备端 OTA**: reMarkable Paper Pro Move (`imx93-chiappa`) 实测无 `/usr/bin/python3`,
  Python 工具在设备上无法运行. Go 静态编译跨架构 (aarch64/armv7),
  `dist/qmd-tool-{aarch64,armv7}` 可塞 OTA payload 设备本机执行,
  设备从此 0 Python 依赖.
- **PC 端**: 同一二进制 host 平台版本被 `installer/install.sh` 调用,
  减少 Python 工具链依赖 (用户不再需要 `python3`).
- **行为对齐**: Go 版有 byte-for-byte golden 单测 (`compile_test.go`),
  保证输出与 Python 版完全一致.

## 归档清单

```
qmd-tool-py/
├── hash-qmd.py        把 qmd-src/*.qmd 编译成 dist/*.qmd (identifier → hash)
└── qmd_hash_check.py  扫 qmd/*.qmd, 校验 hash 都在 tools/hashtabs/ 任一 hashtab 命中
```

## 历史价值

留作:

1. 行为参考 — Go 版本如有疑问, 看这边 Python 实现确认期望
2. 字典格式 docstring — `hash-qmd.py` 头部注释精确描述了 hashtab 二进制布局, Go 版 `hashtab.go` 抄过来了
3. 不含可执行 fallback — `installer/install.sh` 现在硬依赖 `dist/qmd-tool`, 不会再尝试 fallback 到 Python
