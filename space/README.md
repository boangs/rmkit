# 空间 (SPACE) — rmkit-cn 启动台

「空间」是 reMarkable 上属于你的数字空间：一个首页（时间、天气、今日计划、正在进行）、一组应用、一个应用商店。
它取代原来的「高级」面板，成为 rmkit-cn 所有功能的统一入口。

设计目标只有一句话：**外壳小而稳，应用各自独立，装卸不重启。**

```
侧栏 「空间」 ──▶ 外壳 Space.qml ──▶ 首页 / 应用 / 发现 / 我的
                       │
                       ├── GET /space/apps ──▶ upload-server internal/space (注册表)
                       │                          ├── /home/root/rmkit-cn/space/apps/<id>/           内置应用 (安装器管理)
                       │                          └── /home/root/.local/share/rmkit-cn/space/apps/<id>/  用户应用 (绿色安装)
                       │
                       └── 点应用 ──▶ Qt.createComponent(file://…/main.qml) ──▶ 应用根 Item (property var space)
                                          └── 声明了 service ──▶ POST /space/apps/<id>/service/start ──▶ 应用自带后台进程
```

## 分层与边界

| 层 | 位置 | 职责 | 不做什么 |
|---|---|---|---|
| 注入器 | `intercept/qml-inject/qml_inject_impl.cpp` | 在侧栏放一个入口；有 `space/.primary` 标记就加载外壳，否则加载旧面板 | 不认识任何应用 |
| 外壳 | `space/shell/Space.qml` | 首页/标签页、应用的创建与销毁、给应用的 API 对象 | 不含任何业务功能 |
| 组件库 | `space/kit/` | 磁贴、按钮、单选、列表行、时钟、线性图标 | 不含状态 |
| 后端 | `upload-server-go/internal/space/` | 扫描清单、绿色安装/卸载、托管应用后台进程、转发商店索引 | 不认识任何应用 |
| 应用 | `space/apps/<id>/`（内置）或用户目录 | 一个目录：清单 + QML + 图标 + 可选后台 | 不碰外壳内部 id |

外壳与应用之间只有两条线：注册表 JSON（后端 → 外壳）和 `space` API 对象（外壳 → 应用）。
应用与自己的后台之间直接走 `space.serviceUrl`，不经过 upload-server；upload-server 只负责拉起和收掉它。

## 应用包

```
<id>/
  manifest.json     清单 (必须)
  main.qml          界面入口 (entry)
  icon.svg          图标
  widget.qml        首页小组件 (可选)
  bin/<service>     自带后台 (可选, 解压时自动加可执行位)
  assets/…          随意
```

`manifest.json` 字段（`upload-server-go/internal/space/manifest.go` 是唯一权威）：

```json
{
  "id": "music",                 // 小写字母/数字/-/_, 1-32 位, 也是目录名
  "name": "音乐", "name_en": "Music", "version": "1.0.0",
  "description": "一句话说明",
  "icon": "icon.svg",            // 相对路径 / 绝对路径 / qrc: 或 file: URL
  "entry": "main.qml",           // 界面入口; 与 launch 至少有一个
  "widget": "widget.qml",        // 首页小组件 (可选)
  "widget_size": "half",         // half (半宽卡) / hero (首页顶部整宽大卡, 如天气)
  "category": "tool",            // system / settings / reader / tool / game / other
  "order": 10,                   // 同类内排序
  "arch": ["aarch64"],           // 支持的架构, 空 = 都支持 (rm2 是 armv7)
  "min_shell": 1,                // 需要的外壳契约版本
  "service": {                   // 自带后台 (可选)
    "exec": "bin/music-server", "args": [], "port": 9100, "health": "/health",
    "keepalive": true,           // 退出界面后继续跑 (后台播放)
    "autostart": false           // upload-server 启动时自动拉起
  },
  "launch": {                    // 外部程序型应用 (无 QML 界面, 点图标即启动)
    "type": "post",              // post: 向 upload-server 发 POST; appload: 走 xovi appload 单例
    "path": "/apps/android/launch", "id": "external::koreader",
    "confirm": "将重启进入 Android，确定？"   // 非空则先弹确认
  }
}
```

后台进程收到的环境变量：`SPACE_APP_ID` `SPACE_APP_DIR` `SPACE_DATA_DIR` `SPACE_PORT` `SPACE_BASE_URL`。
标准输出/错误写到 `SPACE_DATA_DIR/service.log`。进程组整体收，别自己 fork 出去。

## 应用界面契约 (外壳版本 1)

根元素是一个 `Item`，声明 `property var space`，外壳创建时注入；`anchors.fill: parent` 即占满内容区。

```qml
import QtQuick
import "file:///home/root/rmkit-cn/space/kit" as Kit   // 共享组件 (可选)

Item {
    id: root
    property var space
    anchors.fill: parent
    Component.onCompleted: space.get("/bt/status", function(st, r) { … })
}
```

`space` 对象：

| 成员 | 说明 |
|---|---|
| `baseUrl` | upload-server 地址 `http://127.0.0.1:8080` |
| `serviceUrl` | 应用自带后台地址（清单声明了 port 才有） |
| `appId` `appDir` `dataDir` `kitDir` | 目录与标识 |
| `unit` `fontScale` `largeScreen` `screenWidth` `screenHeight` | 尺寸基准（见下） |
| `title` | 改它 = 改外壳大标题 |
| `chrome` | 设为 false 外壳隐藏导航栏和标题，应用全屏自己画（音乐播放页那种） |
| `onBack` | 赋一个函数；返回 true 表示应用自己消费了返回键 |
| `exit()` `closeSpace()` `toast(msg)` `openApp(id)` | 退出 / 关启动台 / 提示 / 跳到别的应用 |
| `get/post(path, cb)` `svcGet/svcPost(path, cb)` `request(method, url, body, cb)` | HTTP 帮手，`cb(status, json)` |

小组件 (`widget.qml`) 契约相同：根 Item + `property var space`，外壳把它放进固定高度的卡片里；点开自己用 `space.openApp(space.appId)`。

### 尺寸不写死

两台机器（Paper Pro 1620×2160 @229ppi，Paper Pro Move 954×1696 @264ppi）DPI 接近但宽度差近一倍，横竖屏还会换。外壳的做法，应用照抄：

- `unit = min(width, height) / 954`：Move 竖屏 = 1，Paper Pro ≈ 1.7。边距、卡片高度、间距乘它。
- `fontScale = 1 + (unit − 1) × 0.35`：字号只温和放大（Paper Pro 24 → 30px）。
- 列数按内容宽度算：`floor(contentWidth / (最小磁贴宽 × fontScale))`，横屏自动变多列。

## 后端接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/space/apps` | 注册表：`{shell, arch, userDir, apps:[…]}`，每条含解析后的 `entryUrl` `iconUrl` `widgetUrl` `dataDir` `serviceUrl` `builtin` `error` |
| POST | `/space/apps` | 上传 zip 安装（multipart 字段 `file`，或 body 直接是 zip） |
| POST | `/space/apps/install-url` | `{"url", "sha256"}` 从网址安装 |
| DELETE | `/space/apps/{id}` | 卸载（仅用户目录；数据目录保留） |
| GET/POST | `/space/apps/{id}/service`, `…/service/start`, `…/service/stop` | 应用后台状态 / 拉起（就绪后返回）/ 收掉 |
| GET | `/space/store` | 商店索引（设备端拉取 + 缓存 10 分钟；`?refresh=1` 强刷） |

zip 里 `manifest.json` 在根或唯一顶级目录下都行；拒绝路径穿越与符号链接；解压到临时目录校验后原子替换，失败不影响已装版本；同名后台先收掉。

## 应用商店

索引是一份静态 JSON（默认 `-space-store` 指向 GitHub raw，可换成国内镜像）：

```json
{"apps": [{"id": "music", "name": "音乐", "version": "1.0.0", "description": "…",
           "category": "tool", "arch": ["aarch64"],
           "zip": "https://…/music-1.0.0.zip", "sha256": "…"}]}
```

「发现」页按 id 对比本机版本：未装显示「获取」，版本不同显示「更新」，一致显示「已安装」。

## 迁移路线

1. **已完成**：外壳 + 后端 + 组件库；旧面板全部页面已迁成内置应用 —— 设置类（扫码上传、个性化、AI 设置、输入法、蓝牙、Android）在「设置」标签按行列出，游戏/工具（五子棋、国际象棋、华容道、快艇骰子、函数绘图）与 KOReader / 微信读书 在「应用」。旧「高级」面板首页保留一个「空间」磁贴作为过渡入口。
2. 在设备上落 `/home/root/rmkit-cn/space/.primary`（已重编的注入器会据此把侧栏入口切成「空间」），之后删除 `adv_panel.qml` 与 qmd 版本（qmd/qmldiff 路径不再承载新功能）。
3. 音乐作为第一个第三方应用（源码在仓库外），验证 service/keepalive/widget 全链路。
4. 开发模式：`touch ~/.local/share/rmkit-cn/space/.dev` 后外壳打开应用会绕过 QML 组件缓存，改完 QML 重新点开即生效。

## 本地开发

- 外壳与应用都是 file:// 加载的普通 QML：改完 `scp` 到设备对应目录，重新打开「空间」即生效，不用重启 xochitl。
- 应用加载失败时外壳会把 `Component.errorString()` 直接显示在内容区。
- `qmllint space/shell/Space.qml` 会因为 Mac 上没有 `device.ui.controls` 和绝对路径 import 报一堆 warning，只看 `Error` 行。
- 后端：`cd upload-server-go && go test ./internal/space/`。
