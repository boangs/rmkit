# qml-inject — 运行时 QML 注入原型（实验中，未验证）

验证一条能让 rmkit-cn **摆脱 qmldiff 变砖** 的路线：用 LD_PRELOAD
插桩 `QQmlEngine::rootContext()`，拿到活的 QML 引擎，**运行时**往场景树注入节点，
而不是 qmldiff 那样编译期打补丁（要 hashtab、怕 QML 结构变、孤儿 hash → panic → 砖）。

跟 `../ime_hook.cpp` 同一原理（Qt 符号插桩 + RTLD_NEXT 转发 + LD_PRELOAD），只是从
IME 扩到 QML 注入。SDK、工具链、部署链路全复用。

## 分阶段

- **STAGE 1（本原型）**：只证明机制能通——抓到 engine，延迟 3s 后往第一个
  `QQuickWindow` 的 `contentItem` 注入一个醒目红块 `HOOK OK 高级`。
  **屏幕上看到红块 = 整条路验证成功**（插桩生效 + 能进活引擎 + 能运行时挂 QML 节点）。
- **STAGE 2（通过后再做）**：定位 Sidebar 真实目标节点，注入真正的「高级」按钮，
  把 `advanced_panel` 迁离 qmldiff。已知难点：Sidebar 锚点是 QML `id`（非
  `objectName`），`findChild(name)` 找不到，得靠类型/结构启发式定位。

## 测试步骤（务必在 3.28 slot 上做，不要在另一个 3.27 slot）

1. 设备切到 3.28 + rmkit-cn 的 slot：`rootdev --switch && reboot`，等起来确认 rmkit-cn 正常
2. 编译：
   ```
   scp -r intercept/qml-inject boangs@192.168.64.4:/tmp/
   ssh boangs@192.168.64.4 'cd /tmp/qml-inject && make'
   scp boangs@192.168.64.4:/tmp/qml-inject/qml_inject-aarch64.so <本机>
   ```
3. 部署到设备（**只临时测试，别写进 drop-in 持久化**）：
   ```
   scp qml_inject-aarch64.so root@10.11.99.1:/home/root/rmkit-cn/bin/
   # 临时把它加进 xochitl 的 LD_PRELOAD 手动重启一次测试
   ```
4. 看屏幕有没有红块 + `journalctl -u xochitl | grep qml-inject` 看日志
5. 测完移除，别留在持久化配置里（原型未经充分验证，防砖）

## 安全前提

- 只在 3.28 slot、只临时 LD_PRELOAD 测试，不进 drop-in
- 有我们的 fail-open 预检兜底 + A/B 回滚，崩了切回来即可
- 别在另一个 3.27 slot 上碰任何东西
