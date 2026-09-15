// Space.qml — 「空间 (SPACE)」启动台外壳
//
// 职责只有三件事, 别往这里塞功能:
//   1. 首页与标签页: 空间 (小组件 + 我的应用) / 应用 (全部) / 发现 (商店) / 设置 (设置类应用列表)
//      数据全部来自 upload-server 的 /space/* (注册表、商店索引), 外壳不认任何具体应用
//   2. 打开/关闭应用: 按注册表里的 file:// 入口动态创建组件, 退出即销毁; 声明了后台的先拉起后台
//   3. 给应用一个稳定的 API 对象 (space): 基址、目录、标题/边框控制、返回拦截、HTTP 帮手
import QtQuick
import QtQuick.Layouts
import device.ui.controls
import "file:///home/root/rmkit-cn/space/kit" as Kit

Rectangle {
    id: space
    objectName: "_rmkitSpace"
    anchors.fill: parent
    color: "white"
    visible: true
    z: 99999

    readonly property int shellVersion: 1
    readonly property string kitDir: "file:///home/root/rmkit-cn/space/kit"
    property string baseUrl: "http://127.0.0.1:8080"
    // ─── 尺寸基准: 不写死任何机型 ───
    // 以 Paper Pro Move 竖屏短边 954px 为 1.0; Paper Pro (1620x2160) 竖屏约 1.7。横屏时短边不变, 版式靠宽度自适应。
    // 两台机器 DPI 接近 (229 / 264), 所以字号只温和放大 (fs), 边距/卡片高度按 unit 放大, 列数按内容宽度算。
    readonly property real unit: Math.max(0.6, Math.min(width, height) / 954)
    readonly property real fs: 1 + (unit - 1) * 0.35
    readonly property bool largeScreen: unit > 1.4
    readonly property int margin: Math.round(64 * unit)
    function px(n) { return Math.round(n * unit) }      // 版式尺寸
    function fpx(n) { return Math.round(n * fs) }       // 字号
    function cols(contentWidth, minTile) { return Math.max(2, Math.floor(contentWidth / (minTile * fs))) }

    property string tab: "home"       // home / apps / discover / settings
    property var apps: []
    property string listError: ""
    property var storeApps: []
    property string storeError: ""
    property bool storeLoaded: false
    property int tzOffset: 480            // 后端给的本地时区偏移 (分钟); 设备系统时区是 UTC
    property bool devMode: false          // 后端 .dev 标记: 打开应用绕过 QML 组件缓存
    property date now: new Date()
    // 本地时间 = 当前时刻按 tzOffset 平移后, 用进程时区 (UTC) 的表示来显示; 若进程时区不是 UTC 也能纠正
    function localNow() { return new Date(now.getTime() + (tzOffset + now.getTimezoneOffset()) * 60000) }

    property var current: null        // 正在打开的应用 (注册表条目)
    property var currentItem: null    // 应用根 Item
    property string appError: ""      // 应用加载失败原因 (给开发者看)
    property string appTitle: ""
    property bool chrome: true        // false = 应用全屏 (自己画导航)
    property string toastText: ""
    property string busyText: ""
    property var confirmApp: null

    // ─── 给应用的 API ─────────────────────────────────────────────────
    QtObject {
        id: api
        readonly property int shellVersion: space.shellVersion
        readonly property string baseUrl: space.baseUrl
        readonly property string kitDir: space.kitDir
        readonly property bool largeScreen: space.largeScreen
        readonly property real unit: space.unit           // 版式缩放基准 (Move 竖屏 = 1)
        readonly property real fontScale: space.fs        // 字号缩放基准
        readonly property real screenWidth: space.width
        readonly property real screenHeight: space.height
        property string appId: ""
        property string appDir: ""       // 应用目录 (绝对路径)
        property string dataDir: ""      // 应用私有数据目录 (卸载不删)
        property string serviceUrl: ""   // 应用自带后台的 http://127.0.0.1:<port>, 没有则空
        property string title: ""        // 改它 = 改外壳大标题
        property bool chrome: true       // false = 外壳隐藏导航栏和标题, 应用全屏
        property var onBack: null        // function(): 返回 true 表示应用自己消费了返回键

        onTitleChanged: space.appTitle = title
        onChromeChanged: space.chrome = chrome

        function exit() { space.closeApp() }              // 退出应用回到原标签页
        function closeSpace() { space.close() }           // 连启动台一起关
        function toast(msg) { space.showToast(msg) }
        function openApp(id) { space.openById(id) }       // 应用间跳转 (如小组件点开自己的应用)
        function request(method, url, body, cb) { space.request(method, url, body, cb) }
        function get(path, cb) { space.request("GET", space.baseUrl + path, null, cb) }
        function post(path, body, cb) { space.request("POST", space.baseUrl + path, body, cb) }
        function svcGet(path, cb) { space.request("GET", serviceUrl + path, null, cb) }
        function svcPost(path, body, cb) { space.request("POST", serviceUrl + path, body, cb) }
    }

    // ─── 逻辑 ─────────────────────────────────────────────────────────
    function request(method, url, body, cb) {
        var x = new XMLHttpRequest()
        x.onreadystatechange = function() {
            if (x.readyState !== 4) return
            var r = null
            try { r = JSON.parse(x.responseText) } catch (e) { r = null }
            if (cb) cb(x.status, r)
        }
        x.open(method, url)
        var hasBody = body !== null && body !== undefined
        if (hasBody) x.setRequestHeader("Content-Type", "application/json")
        x.send(hasBody ? JSON.stringify(body) : null)
    }

    function reload() {
        listError = ""
        request("GET", baseUrl + "/space/apps", null, function(st, r) {
            if (st !== 200 || !r) { listError = "后端未响应 (" + st + ")"; return }
            apps = r.apps || []
            if (r.tzOffset !== undefined) tzOffset = r.tzOffset
            devMode = !!r.dev
        })
    }

    // 开发模式下给 file:// 加时间戳查询串: 引擎按完整 URL 缓存编译单元, 换个查询串就会重新读盘
    function bust(url) { return devMode ? url + "?t=" + Date.now() : url }

    function loadStore(refresh) {
        storeError = ""
        request("GET", baseUrl + "/space/store" + (refresh ? "?refresh=1" : ""), null, function(st, r) {
            storeLoaded = true
            if (st !== 200 || !r) { storeError = (r && r.error) ? r.error : ("连不上应用商店 (" + st + ")"); storeApps = []; return }
            storeApps = r.apps || []
        })
    }

    function installedVersion(id) {
        for (var i = 0; i < apps.length; i++) if (apps[i].id === id) return apps[i].version || "?"
        return ""
    }

    function installFromStore(item) {
        busyText = "正在安装 " + item.name + "…"
        request("POST", baseUrl + "/space/apps/install-url", { url: item.zip, sha256: item.sha256 || "" }, function(st, r) {
            busyText = ""
            if (st !== 200) { showToast((r && r.error) ? r.error : ("安装失败 (" + st + ")")); return }
            showToast(item.name + " 已安装")
            reload()
        })
    }

    function filterApps(pred) {
        var out = []
        for (var i = 0; i < apps.length; i++) if (pred(apps[i])) out.push(apps[i])
        return out
    }
    function heroWidgetApp() {
        var l = filterApps(function(a) { return a.widgetUrl && a.widget_size === "hero" && !a.error })
        return l.length ? l[0] : null
    }
    function halfWidgetApps() {
        return filterApps(function(a) { return a.widgetUrl && a.widget_size !== "hero" && !a.error })
    }
    // "应用" = 非设置类 (设置类只出现在"设置"标签)
    function isSetting(a) { return a.category === "settings" || a.category === "system" }
    function userApps() { return filterApps(function(a) { return !isSetting(a) }) }
    function homeApps() {
        var l = filterApps(function(a) { return !a.error && !isSetting(a) })
        var n = homeGrid.columns * 2   // 首页只放两行, 其余在"应用"页
        return l.length > n ? l.slice(0, n) : l
    }
    function settingsApps() { return filterApps(isSetting) }

    function openById(id) {
        for (var i = 0; i < apps.length; i++) if (apps[i].id === id) { open(apps[i]); return }
        showToast("没有安装 " + id)
    }

    function open(app) {
        if (app.error) { showToast(app.error); return }
        if (!app.entryUrl) { launch(app); return }
        if (app.service) {
            busyText = "正在启动 " + app.name + " 的后台…"
            request("POST", baseUrl + "/space/apps/" + app.id + "/service/start", null, function(st, r) {
                busyText = ""
                if (st !== 200) { showToast((r && r.error) ? r.error : ("后台启动失败 (" + st + ")")); return }
                mount(app, (r && r.url) ? r.url : (app.serviceUrl || ""))
            })
            return
        }
        mount(app, "")
    }

    function mount(app, serviceUrl) {
        api.appId = app.id
        api.appDir = app.dir
        api.dataDir = app.dataDir
        api.serviceUrl = serviceUrl
        api.onBack = null
        api.title = app.name
        api.chrome = true
        appTitle = app.name
        chrome = true
        appError = ""
        current = app
        var c = Qt.createComponent(bust(app.entryUrl))
        if (c.status === Component.Error) { appError = c.errorString(); return }
        var obj = c.createObject(appHost, { "space": api })
        if (!obj) { appError = "createObject 失败: " + c.errorString(); return }
        currentItem = obj
    }

    function closeApp(closing) {
        if (currentItem) { currentItem.destroy(); currentItem = null }
        var app = current
        current = null
        appError = ""
        chrome = true
        appTitle = ""
        if (app && app.service && !app.service.keepalive)
            request("POST", baseUrl + "/space/apps/" + app.id + "/service/stop", null, null)
        // 小组件可能要反映应用里的变化; 但整个启动台正在关闭时不刷 —— 回调会在外壳销毁后才回来
        if (!closing) reload()
    }

    function back() {
        if (!current) return
        if (api.onBack && api.onBack()) return
        closeApp()
    }

    function close() {
        closeApp(true)
        space.visible = false
        space.destroy()
    }

    // 外部程序型应用 (KOReader / 微信读书 / Android): 没有 QML 界面, 点图标即启动
    function launch(app) {
        var l = app.launch
        if (!l) { showToast("这个应用没有入口"); return }
        if (l.confirm && confirmApp !== app) { confirmApp = app; return }
        confirmApp = null
        if (l.type === "appload") {
            var helper = null
            try {
                helper = Qt.createQmlObject(
                    'import QtQuick;\nimport net.asivery.AppLoad;\n' +
                    'QtObject { function go(id){ AppLoadLauncher.launchApplication(id, [], ({}), false) } }',
                    space, "space_appload_launcher")
            } catch (e) { helper = null }
            if (helper) {
                space.visible = false
                helper.go(l.id)
                helper.destroy()
                close()
                return
            }
            if (!l.path) { showToast("appload 未启用"); return }
        }
        // post (或 appload 兜底): 交给 upload-server, 面板先收起来 (重启类操作后面没有界面了)。
        // 只隐藏不销毁: 请求还在路上, 销毁会把发请求的 JS 上下文一起收掉。
        var x = new XMLHttpRequest()
        x.open("POST", baseUrl + l.path)
        x.send()
        space.visible = false
    }

    function showToast(msg) { toastText = msg; toastTimer.restart() }
    function tabTitle() {
        if (tab === "apps") return "应用"
        if (tab === "discover") return "发现"
        if (tab === "settings") return "设置"
        return "空间"
    }
    function tabSubtitle() {
        if (tab === "apps") return "所有应用，一目了然"
        if (tab === "discover") return "发现更多可能"
        if (tab === "settings") return "简单 · 实用 · 不打扰"
        return "专注当下，记录生活"
    }
    function dateLine() {
        return localNow().toLocaleDateString(Qt.locale("zh_CN"), "M月d日 dddd")
    }

    Timer { id: toastTimer; interval: 4000; repeat: false; onTriggered: space.toastText = "" }
    Timer { interval: 15000; running: space.visible; repeat: true; onTriggered: space.now = new Date() }

    Component.onCompleted: reload()
    onTabChanged: { if (tab === "discover" && !storeLoaded) loadStore(false) }

    // ─── 应用内导航栏 (返回 + 标题) ───────────────────────────────────
    Item {
        id: appNav
        visible: space.chrome && space.current !== null
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: space.px(72)
        IconButton {
            anchors.top: parent.top
            anchors.topMargin: 10
            anchors.left: parent.left
            anchors.leftMargin: 10
            iconSource: "qrc:/ark/icons/chevron_left"
            title: "返回"
            onClicked: space.back()
        }
    }
    Text {
        id: appTitleText
        visible: space.chrome && space.current !== null
        anchors.top: appNav.bottom
        anchors.topMargin: space.px(56)
        anchors.left: parent.left
        anchors.leftMargin: space.margin
        text: space.current ? (space.appTitle || space.current.name) : ""
        font.pixelSize: space.fpx(56)
        font.weight: Font.Medium
    }

    // ─── 标签页页眉 (大标题 + 副标题 + 齿轮) ──────────────────────────
    Item {
        id: pageHeader
        visible: space.chrome && space.current === null
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: space.margin
        anchors.rightMargin: space.margin
        height: space.px(250)
        IconButton {
            anchors.top: parent.top
            anchors.topMargin: 10
            anchors.left: parent.left
            anchors.leftMargin: 10 - space.margin
            iconSource: "qrc:/ark/icons/chevron_left"
            title: "返回"
            onClicked: space.close()
        }
        Text {
            id: pageTitle
            y: space.px(104)
            text: space.tabTitle()
            font.pixelSize: space.fpx(56)
            font.weight: Font.Medium
        }
        Text {
            anchors.top: pageTitle.bottom
            anchors.topMargin: 6
            text: space.tabSubtitle()
            font.pixelSize: space.fpx(24)
            color: "#666666"
        }
        Image {
            visible: space.tab === "home"
            anchors.right: parent.right
            y: space.px(112)
            width: space.fpx(44); height: width
            source: space.kitDir + "/icons/gear.svg"
            fillMode: Image.PreserveAspectFit
            sourceSize.width: width; sourceSize.height: width
            MouseArea { anchors.fill: parent; anchors.margins: -16; onClicked: space.tab = "settings" }
        }
        Image {
            visible: space.tab !== "home"
            anchors.right: parent.right
            y: space.px(112)
            width: space.fpx(44); height: width
            source: "qrc:/ark/icons/restore"
            fillMode: Image.PreserveAspectFit
            MouseArea {
                anchors.fill: parent; anchors.margins: -16
                onClicked: { space.reload(); if (space.tab === "discover") space.loadStore(true) }
            }
        }
    }

    // 提示条: 4 秒自动消失, 盖在内容区顶部, 不挤动布局
    Rectangle {
        visible: space.toastText !== ""
        z: 5
        anchors.top: content.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: space.margin
        anchors.rightMargin: space.margin
        height: toastLabel.implicitHeight + 24
        color: "#222222"
        radius: 8
        Text {
            id: toastLabel
            anchors.fill: parent
            anchors.margins: 12
            text: space.toastText
            font.pixelSize: space.fpx(24)
            color: "white"
            wrapMode: Text.WordWrap
        }
    }

    // ─── 内容区 ───────────────────────────────────────────────────────
    Item {
        id: content
        anchors.top: !space.chrome ? parent.top : (space.current ? appTitleText.bottom : pageHeader.bottom)
        anchors.topMargin: !space.chrome ? 0 : (space.current ? space.px(48) : 0)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: (space.chrome && space.current === null) ? tabBar.top : parent.bottom
        anchors.leftMargin: space.chrome ? space.margin : 0
        anchors.rightMargin: space.chrome ? space.margin : 0
        anchors.bottomMargin: space.chrome ? space.px(24) : 0

        // ── 空间 (首页) ──
        Flickable {
            visible: space.current === null && space.tab === "home"
            anchors.fill: parent
            contentWidth: width
            contentHeight: homeCol.height + space.px(24)
            clip: true
            ColumnLayout {
                id: homeCol
                width: parent.width
                spacing: space.px(24)

                // 顶部大卡: 日期 + 时间; 装了 hero 小组件 (如天气) 则由它整卡接管
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: space.px(260)
                    radius: 12
                    border.color: "#d0d0d0"
                    border.width: 1
                    color: "white"
                    clip: true
                    Item {
                        anchors.fill: parent
                        visible: space.heroWidgetApp() === null
                        Column {
                            anchors.left: parent.left
                            anchors.leftMargin: space.px(32)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 8
                            Text { text: space.dateLine(); font.pixelSize: space.fpx(26); color: "#444444" }
                            Text { text: Qt.formatTime(space.localNow(), "HH:mm"); font.pixelSize: space.fpx(88); font.weight: Font.Light }
                            Text { text: "今天也是安静的一天。"; font.pixelSize: space.fpx(22); color: "#777777" }
                        }
                        Rectangle {
                            anchors.right: parent.right
                            anchors.rightMargin: space.px(40)
                            anchors.verticalCenter: parent.verticalCenter
                            width: space.px(120); height: width; radius: width / 2
                            color: "#e4e4e4"
                        }
                    }
                    Loader {
                        anchors.fill: parent
                        active: space.heroWidgetApp() !== null
                        onActiveChanged: { if (active) setSource(space.bust(space.heroWidgetApp().widgetUrl), { "space": api, "app": space.heroWidgetApp() }) }
                        Component.onCompleted: { if (active) setSource(space.bust(space.heroWidgetApp().widgetUrl), { "space": api, "app": space.heroWidgetApp() }) }
                    }
                }

                // 半宽小组件: 今日计划 / 正在进行 …… 由各应用的 widget.qml 提供
                GridLayout {
                    Layout.fillWidth: true
                    columns: space.largeScreen ? 3 : 2
                    rowSpacing: space.px(24)
                    columnSpacing: space.px(24)
                    visible: space.halfWidgetApps().length > 0
                    Repeater {
                        model: space.halfWidgetApps()
                        delegate: Rectangle {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.preferredHeight: space.px(220)
                            radius: 12
                            border.color: "#d0d0d0"
                            border.width: 1
                            color: "white"
                            clip: true
                            Loader {
                                anchors.fill: parent
                                // 小组件拿到自己的注册表条目 (app.serviceUrl 等), 因为 api 对象上的 serviceUrl 是"正在打开的应用"的
                                Component.onCompleted: setSource(space.bust(modelData.widgetUrl), { "space": api, "app": modelData })
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 8
                    Text { text: "我的应用"; font.pixelSize: space.fpx(32); font.weight: Font.Medium }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: "全部应用 ›"
                        font.pixelSize: space.fpx(24)
                        color: "#555555"
                        MouseArea { anchors.fill: parent; anchors.margins: -12; onClicked: space.tab = "apps" }
                    }
                }
                Text {
                    visible: space.listError !== ""
                    text: space.listError
                    font.pixelSize: space.fpx(24)
                    color: "#a00000"
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                }
                Text {
                    visible: space.listError === "" && space.apps.length === 0
                    text: "还没有应用。到「发现」安装，或用手机扫码上传应用包 (zip)。"
                    font.pixelSize: space.fpx(24)
                    color: "#555555"
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                }
                GridLayout {
                    id: homeGrid
                    Layout.fillWidth: true
                    columns: space.cols(width, 200)
                    rowSpacing: space.px(20)
                    columnSpacing: space.px(20)
                    Repeater {
                        model: space.homeApps()
                        delegate: Kit.STile {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.preferredHeight: space.px(120)
                            iconSize: space.fpx(44)
                            labelSize: space.fpx(22)
                            iconSource: modelData.iconUrl || ""
                            label: modelData.name
                            onClicked: space.open(modelData)
                        }
                    }
                }
            }
        }

        // ── 应用 (全部) ──
        Flickable {
            visible: space.current === null && space.tab === "apps"
            anchors.fill: parent
            contentWidth: width
            contentHeight: appsGrid.height + space.px(24)
            clip: true
            GridLayout {
                id: appsGrid
                width: parent.width
                columns: space.cols(width, 270)
                rowSpacing: space.px(24)
                columnSpacing: space.px(24)
                Repeater {
                    model: space.userApps()
                    delegate: Kit.STile {
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.preferredHeight: space.px(170)
                        iconSize: space.fpx(56)
                        labelSize: space.fpx(24)
                        iconSource: modelData.iconUrl || ""
                        label: modelData.name
                        dimmed: !!modelData.error
                        onClicked: space.open(modelData)
                    }
                }
            }
        }

        // ── 发现 (应用商店) ──
        Flickable {
            visible: space.current === null && space.tab === "discover"
            anchors.fill: parent
            contentWidth: width
            contentHeight: storeCol.height + space.px(24)
            clip: true
            ColumnLayout {
                id: storeCol
                width: parent.width
                spacing: 0
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: space.px(150)
                    Layout.bottomMargin: space.px(24)
                    radius: 12
                    color: "#f0f0f0"
                    Column {
                        anchors.centerIn: parent
                        spacing: 8
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "让好工具"; font.pixelSize: space.fpx(34); font.weight: Font.Medium }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "陪伴更好的你"; font.pixelSize: space.fpx(24); color: "#666666" }
                    }
                }
                Text {
                    visible: !space.storeLoaded
                    text: "正在获取应用列表…"
                    font.pixelSize: space.fpx(24); color: "#666666"
                }
                Text {
                    visible: space.storeError !== ""
                    Layout.fillWidth: true
                    text: space.storeError + "\n应用商店需要联网。也可以用手机扫码上传应用包 (zip) 安装。"
                    font.pixelSize: space.fpx(24); color: "#666666"; wrapMode: Text.WordWrap
                }
                Text {
                    visible: space.storeLoaded && space.storeError === "" && space.storeApps.length === 0
                    text: "商店里还没有应用。"
                    font.pixelSize: space.fpx(24); color: "#666666"
                }
                Repeater {
                    model: space.storeApps
                    delegate: Item {
                        id: storeRow
                        required property var modelData
                        readonly property string installed: space.installedVersion(modelData.id)
                        Layout.fillWidth: true
                        Layout.preferredHeight: space.px(120)
                        RowLayout {
                            anchors.fill: parent
                            spacing: space.px(20)
                            Rectangle {
                                Layout.preferredWidth: space.fpx(72); Layout.preferredHeight: space.fpx(72); radius: 12
                                color: "#f0f0f0"
                                Text { anchors.centerIn: parent; text: (storeRow.modelData.name || "?").charAt(0); font.pixelSize: space.fpx(32) }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 4
                                Text { text: storeRow.modelData.name || storeRow.modelData.id; font.pixelSize: space.fpx(28); elide: Text.ElideRight; Layout.fillWidth: true }
                                Text {
                                    text: (storeRow.modelData.description || "") + "  v" + (storeRow.modelData.version || "")
                                    font.pixelSize: space.fpx(22); color: "#777777"; elide: Text.ElideRight; Layout.fillWidth: true
                                }
                            }
                            Kit.SButton {
                                ui: space.fs
                                enabled: storeRow.installed !== storeRow.modelData.version
                                text: storeRow.installed === "" ? "获取" : (storeRow.installed === storeRow.modelData.version ? "已安装" : "更新")
                                primary: storeRow.installed === ""
                                onClicked: space.installFromStore(storeRow.modelData)
                            }
                        }
                        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: "#e0e0e0" }
                    }
                }
            }
        }

        // ── 设置 (设置类应用的行列表) ──
        Flickable {
            visible: space.current === null && space.tab === "settings"
            anchors.fill: parent
            contentWidth: width
            contentHeight: mineCol.height + space.px(24)
            clip: true
            ColumnLayout {
                id: mineCol
                width: parent.width
                spacing: 0
                Repeater {
                    model: space.settingsApps()
                    delegate: Kit.SRow {
                        required property var modelData
                        Layout.fillWidth: true
                        ui: space.fs
                        iconSource: modelData.iconUrl || ""
                        text: modelData.name
                        onClicked: space.open(modelData)
                    }
                }
                Kit.SRow {
                    Layout.fillWidth: true
                    ui: space.fs
                    iconSource: space.kitDir + "/icons/squares-four.svg"
                    text: "关于空间"
                    detail: "外壳 v" + space.shellVersion
                    showArrow: false
                    onClicked: space.showToast("空间 (SPACE) 外壳契约 v" + space.shellVersion + "，应用 " + space.apps.length + " 个")
                }
            }
        }

        // ── 应用宿主: 应用根 Item 会以它为父, 自己 anchors.fill: parent ──
        Item {
            id: appHost
            anchors.fill: parent
            visible: space.current !== null
        }
        Text {
            visible: space.appError !== ""
            anchors.fill: parent
            text: "应用加载失败：\n" + space.appError
            font.pixelSize: space.fpx(24)
            color: "#a00000"
            wrapMode: Text.WrapAnywhere
        }
    }

    // ─── 底部标签栏 ───────────────────────────────────────────────────
    Rectangle {
        id: tabBar
        visible: space.chrome && space.current === null
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: space.px(120)
        color: "white"
        Rectangle { anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right; height: 1; color: "#dddddd" }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: space.margin
            anchors.rightMargin: space.margin
            spacing: 0
            Repeater {
                model: [
                    { key: "home", label: "空间", icon: "house" },
                    { key: "apps", label: "应用", icon: "squares-four" },
                    { key: "discover", label: "发现", icon: "compass" },
                    { key: "settings", label: "设置", icon: "gear" }
                ]
                delegate: Item {
                    id: tabItem
                    required property var modelData
                    readonly property bool active: space.tab === modelData.key
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Column {
                        anchors.centerIn: parent
                        spacing: 6
                        Image {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: space.fpx(40); height: width
                            source: space.kitDir + "/icons/" + tabItem.modelData.icon + ".svg"
                            fillMode: Image.PreserveAspectFit
                            sourceSize.width: width; sourceSize.height: width
                            opacity: tabItem.active ? 1 : 0.55
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: tabItem.modelData.label
                            font.pixelSize: space.fpx(22)
                            font.weight: tabItem.active ? Font.Medium : Font.Normal
                            color: tabItem.active ? "#000000" : "#777777"
                        }
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 28; height: 3
                            color: tabItem.active ? "#000000" : "transparent"
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: space.tab = tabItem.modelData.key
                    }
                }
            }
        }
    }

    // ─── 遮罩: 后台启动中 / 安装中 ─────────────────────────────────────
    Rectangle {
        visible: space.busyText !== ""
        anchors.fill: parent
        z: 10
        color: "#ccffffff"
        MouseArea { anchors.fill: parent }
        Text {
            anchors.centerIn: parent
            text: space.busyText
            font.pixelSize: space.fpx(30)
        }
    }

    // ─── 确认框 (重启进 Android 之类) ────────────────────────────────────
    Rectangle {
        visible: space.confirmApp !== null
        anchors.fill: parent
        z: 10
        color: "#88000000"
        MouseArea { anchors.fill: parent }
        Rectangle {
            anchors.centerIn: parent
            width: Math.min(parent.width - space.px(160), space.px(900))
            height: confirmCol.implicitHeight + space.px(96)
            color: "white"
            radius: 12
            ColumnLayout {
                id: confirmCol
                anchors.centerIn: parent
                width: parent.width - 96
                spacing: 40
                Text {
                    Layout.fillWidth: true
                    text: space.confirmApp ? space.confirmApp.launch.confirm : ""
                    font.pixelSize: space.fpx(30)
                    wrapMode: Text.WordWrap
                }
                RowLayout {
                    Layout.alignment: Qt.AlignRight
                    spacing: 24
                    Kit.SButton { ui: space.fs; text: "取消"; onClicked: space.confirmApp = null }
                    Kit.SButton { ui: space.fs; text: "确定"; primary: true; onClicked: space.launch(space.confirmApp) }
                }
            }
        }
    }
}
