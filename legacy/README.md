# legacy/

历史代码归档. **不再部署、不再维护**, 仅作:

- 功能对照参考 (新实现是否覆盖了所有旧功能)
- 代码考古 (查"为什么过去这么做"的实现细节)
- 平移测试 fixture (Python 测试用例可以参考)

## 归档清单

### `legacy/upload-server-py/` — 早期 Python 上传服务器

- 时期: 2026-04 之前
- 替代: [`upload-server-go/`](../upload-server-go/) (Go 重写, 2026-04-25 后)
- 替代理由:
  - Go 静态编译单二进制, 启动更快, 部署体积更小
  - 三机型 (rm2 / rmpp-ferrari / rmpp-chiappa) 交叉编译方便
  - 设备上不再需要 Python 运行时和 venv
- 功能映射: 旧 main.py 的 API 路由 / 字体上传 / 截图管理 全部已在
  upload-server-go/internal/server/server.go 重写

不被 `installer/install.sh` 引用, 不被 `systemd/rmkit-cn-upload.service`
引用, CI 也不跑它的测试.

如果某天发现 Go 版本漏了什么, 来这里翻 Python 代码确认期望行为.
