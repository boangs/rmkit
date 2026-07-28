# qml-inject — 运行时 QML 注入

让 rmkit-cn **摆脱 qmldiff 变砖**的注入层。qmldiff 是编译期打补丁：要 hashtab、
怕 QML 结构变、孤儿 hash → Rust panic → xochitl crash → A/B 分区回滚（6 次砖机的
主要根因）。这里改成 LD_PRELOAD 插桩 `QQmlEngine::rootContext()` 拿到**活的** QML
引擎，运行时往场景树插节点 —— 不读 hashtab、不碰系统二进制、可逆。

另一条常见路线是 shim + patch xochitl 的 DT_NEEDED：按正常依赖顺序加载、更可靠，
但每次 OTA 都要重打二进制补丁；我们选了更轻的一条，不碰系统文件。

## 已迁移的功能

全部五项已从 qmd 迁到运行时注入，真机验证通过（RMPPM 3.28 / Qt 6.10.3）：

| 功能 | 注入点 | 对应旧 qmd |
| --- | --- | --- |
| 侧栏「高级」入口 + 高级面板 | `Sidebar` 下的 `ColumnLayout`，排到「指南」上方 | `advanced_panel.qmd` |
| 系统语言列表加「中文（简体）」 | `SelectionComponent`（`objectName=SystemLanguageDialog`） | `language_zh_cn.qmd` |
| 手写选区工具栏 AI 按钮 | `SceneSelectionHandler` 下的 `SelectionContextualMenu` | `glyph_selection_ai.qmd` |
| 文本选择菜单 AI 按钮 | `TextSelectionMenu` 下的 `SelectionContextualMenu` | `ai_text_button.qmd` |
| 拼音候选框（`pinyin_ime.qml`） | 主窗口 `contentItem`（等价原 MainView `FocusScope#rootItem`） | `pinyin_interceptor.qmd` |

至此 qmldiff 链路上没有任何在用功能（zh_CN.rcc 键盘布局走 qt-resource-rebuilder
的 rcc 替换，与 qmd/hashtab 无关）。拼音迁移的 Timer 替代方案见 `pinyin_ime.qml`
文件头注释（C++ 250ms `imeTick` 心跳 + `onTextChanged` 信号）。

## 架构：瘦 hook + 胖库

```
xochitl 启动
  └─ LD_PRELOAD: active/qml_inject.so   ← 瘦 hook, 绝不链接 Qt
       ├─ 插桩 QQmlEngine::rootContext() (dlsym RTLD_NEXT 纯转发), 抓 engine 指针
       └─ pthread worker: sleep 2s → dlopen bin/qml_inject_impl.so → pw_inject(engine)
            └─ 胖库 (链 Qt6): invokeMethod 到 GUI 主线程
                 └─ QTimer 每 1s 幂等扫描注入 (见下"为什么是轮询")
```

**为什么必须拆两层**：链接 Qt 的 `.so` 一旦进 `LD_PRELOAD`，Qt 会在 xochitl 自己的
静态初始化之前被加载，破坏初始化顺序 → 启动即崩。实测链 Qt 的崩、不链的存活；
`ime_hook` 能工作正是因为它手读 QString 布局、不链 Qt。胖库延后到 Qt 起来后
`dlopen`，等价于 Qt 插件的加载时机，安全。

**为什么是每秒轮询而不是一次注入**：目标节点大多不在启动时存在 —— `Sidebar` 只在
文件列表视图才实例化（启动早期整棵树才 ~22 个节点），语言对话框、两个选区工具栏
更是用户操作时才创建，且会被反复销毁重建。所以胖库起一个 1s 的 `QTimer`，每轮对
四个目标做幂等注入（按 `objectName` 判重）。整棵树很大（文件网格 4000+ 节点），
所以一律用 `findByClass` 定向查找，不做全量遍历。

## 构建

在**远程 Linux 编译机**上（macOS 没有 chiappa SDK）：

```sh
scp -r intercept/qml-inject boangs@192.168.64.4:/tmp/
ssh   boangs@192.168.64.4 'cd /tmp/qml-inject && make'
scp   'boangs@192.168.64.4:/tmp/qml-inject/qml_inject*-aarch64.so' dist/
```

产物名就是 `dist/` 里的名字，拷过去不用改名 —— `install.sh` 按
`qml_inject-aarch64.so` / `qml_inject_impl-aarch64.so` 找文件，改名会让它静默跳过部署。

只有 aarch64 产物。**rm2 (armv7) 没有**，那四项功能在 rm2 上继续走 qmd 路径 —— 这是
`precheck.sh` 自动判断的，不需要为 rm2 做任何额外配置。

## 部署链路

- `install.sh`：产物存在才部署，并按此决定 `qml_inject.so` 要不要进 `LD_PRELOAD`
  （armv7 写进去只会让 ld.so 每次启动刷 `cannot be preloaded` 警告）。
  胖库和 QML 资源都落 `/home/root/rmkit-cn/bin/` —— **胖库里 hardcode 了
  `file:///home/root/rmkit-cn/bin/*.qml`**，改路径要同步改 `qml_inject_impl.cpp`。
- `precheck.sh`：运行时注入与 qmldiff 链**解耦**。hashtab 不匹配 / qmd 坏 / xovi 没装
  只摘 qmldiff 那套（`mode=degraded`），运行时注入照常挂 —— OTA 后等 fw-upgrade 重编
  hashtab 的窗口期里，上表四项功能不再一起消失。只有 crashloop 熔断才一视同仁全摘
  （崩因可能就是它自己）。它生效时会摘掉上表的 qmd，避免同一功能双注入。
  改这段逻辑请先跑 `bash installer/test-precheck.sh`。

## 调试

- **按需 dump 整棵树**：设备上 `touch /tmp/rmkit-dump`，下一轮扫描会把所有顶层窗口的
  完整场景树写到 `/tmp/rmkit-dump.txt` 并删掉标志文件。定位新注入点就靠它。
- **stderr 必须无缓冲**：重定向到文件后会变块缓冲，segfault 时日志全丢。胖库在
  constructor 里 `setvbuf(stderr, 0, _IONBF, 0)`。
- **安全测法**（别再犯以前的错）：未验证的改动用手动一次性启动测，不经 systemd、
  不写 drop-in → 崩了没有 crashloop 计数、没有 errcnt、无持久化：
  ```sh
  systemctl stop xochitl
  env ... LD_PRELOAD=...xovi.so:...ime_hook.so:...qml_inject.so /usr/bin/xochitl --system >/tmp/x.log 2>&1 &
  # 看效果, 然后
  kill %1; systemctl start xochitl
  ```
  也别在同一轮里"改文件 + 立刻 restart xochitl"——历史上 6 次升级事故都是这么来的。

## 文件

| 文件 | 说明 |
| --- | --- |
| `thin_hook.cpp` | 瘦 hook，不链 Qt。`exports.version` 只导出 rootContext |
| `qml_inject_impl.cpp` | 胖库，链 Qt6，四个 `doInject*` + 1s 轮询。`exports-impl.version` 只导出 `pw_inject` |
| `adv_panel.qml` | 高级面板本体（从 `advanced_panel.qmd` 抽出的纯 QML） |
| `glyph_ai_button.qml` / `text_ai_button.qml` | 两个 AI 按钮 |
| `icon_ai.svg` | 侧栏「高级」图标 |
| `qml_inject.cpp` | **已废弃的单体版**（链 Qt 却进 LD_PRELOAD → 启动即崩）。留作教训，不再构建 |
| `noqt_probe.cpp` | 历史探针，`make probe` 可单独编，排查插桩本身是否生效 |
