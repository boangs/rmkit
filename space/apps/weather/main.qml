// 天气 — 「空间」内置应用。整屏接管 (space.chrome = false), 自带顶栏与底部标签。
// 版式按概念图: 首页(插画大卡) / 预报(逐小时·未来7天) / 生活(指数·详情) / 城市 / 设置。
// 尺寸不写死: 一律走 space.unit (版式) 与 space.fontScale (字号), Move 与 Paper Pro 通用。
import QtQuick
import QtQuick.Layouts
import "weather.js" as W

Item {
    id: root
    property var space
    anchors.fill: parent

    readonly property string dir: "file://" + space.appDir + "/assets/"
    readonly property real fs: space.fontScale
    readonly property real un: space.unit
    function f(n) { return Math.round(n * root.fs) }
    function u(n) { return Math.round(n * root.un) }

    // 墨水屏没有背光, 浅色底要靠抖动铺, 看起来就发灰。一律纯白, 层次交给描边。
    readonly property color paper: "#FFFFFF"
    readonly property color card: "#FFFFFF"
    readonly property color line: "#D8D5CE"
    readonly property color ink: "#2B2B2B"
    readonly property color ink2: "#7C786F"

    property var cfg: null            // {cities:[…], current, unit, refresh}
    property var cache: ({})          // cityKey → wx
    property var wx: null           // 当前城市的天气
    property string tab: "home"       // home | forecast | life | city | setting
    property string fcTab: "hourly"   // hourly | daily
    property string status: ""
    property bool busy: false
    property var results: []          // 城市检索结果

    function city() { return (cfg && cfg.cities.length) ? cfg.cities[Math.min(cfg.current, cfg.cities.length - 1)] : W.DEFAULT_CITY }
    function unit() { return cfg ? cfg.unit : "c" }
    function t(c) { return W.toUnit(c, unit()) }          // 摄氏 → 显示值
    function icon(code, day) { return dir + W.codeIcon(code, day) + ".svg" }

    // ─── 数据 ───
    function load() {
        space.dataGet(space.appId, "config", function(st, r) {
            cfg = (st === 200 && r && r.cities && r.cities.length) ? r : W.DEFAULT_CONFIG
            space.dataGet(space.appId, "cache", function(st2, r2) {
                cache = (st2 === 200 && r2) ? r2 : ({})
                show()
                if (!wx || Date.now() - wx.at > cfg.refresh * 1000) refresh()
            })
        })
    }
    function show() {
        var c = cache[W.cityKey(city())]
        wx = (c && c.temp !== undefined) ? c : null
    }
    // 提交配置: 换一个新对象, 否则 QML 认为 var 属性没变, 界面不刷新
    function commit() { cfg = Object.assign({}, cfg, { cities: cfg.cities.slice() }) }
    function saveCfg(cb) { space.dataPut(space.appId, "config", cfg, cb) }
    function refresh() {
        if (busy || !cfg) return
        busy = true; status = "正在获取 " + city().name + " 的天气…"
        W.fetchCity(space, city(), function(d, e) {
            busy = false
            if (!d) { status = e + (wx ? "，下面是上次的数据" : ""); return }
            status = ""
            var c = cache; c[W.cityKey(city())] = d; cache = c; wx = d
            space.dataPut(space.appId, "cache", cache, null)
        })
    }
    function selectCity(i) {
        cfg.current = i; commit()
        saveCfg(null); show(); tab = "home"
        if (!wx || Date.now() - wx.at > cfg.refresh * 1000) refresh()
    }
    function addCity(c) {
        for (var i = 0; i < cfg.cities.length; i++)
            if (W.cityKey(cfg.cities[i]) === W.cityKey(c)) { selectCity(i); return }
        cfg.cities.push(c); cfg.current = cfg.cities.length - 1; commit()
        saveCfg(null); results = []; searchInput.text = ""; show(); refresh()
    }
    function removeCity(i) {
        if (cfg.cities.length <= 1) { status = "至少保留一个城市"; return }
        cfg.cities.splice(i, 1)
        if (cfg.current >= cfg.cities.length) cfg.current = cfg.cities.length - 1
        commit(); saveCfg(null); show()
    }
    function search() {
        var q = searchInput.text.trim()
        if (q === "") return
        busy = true; status = "正在查找 " + q + "…"
        W.geocode(space, q, function(list, e) { busy = false; results = list; status = e })
    }

    Component.onCompleted: {
        space.chrome = false
        space.onBack = function() { if (root.tab !== "home") { root.tab = "home"; return true } return false }
        load()
    }
    Component.onDestruction: space.onBack = null
    Timer {   // 到点自动刷新 (设置里可调)
        interval: 60000; repeat: true; running: root.visible
        onTriggered: if (root.cfg && root.wx && Date.now() - root.wx.at > root.cfg.refresh * 1000) root.refresh()
    }

    Rectangle { anchors.fill: parent; color: root.paper }

    // ═══ 顶栏 ═══
    Item {
        id: header
        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
        height: root.u(132)

        Image {
            id: backBtn
            x: root.u(28); anchors.verticalCenter: parent.verticalCenter
            width: root.f(34); height: width; sourceSize.width: width; sourceSize.height: width
            source: root.dir + "i-back.svg"; fillMode: Image.PreserveAspectFit
            MouseArea { anchors.fill: parent; anchors.margins: -root.u(18); onClicked: root.tab === "home" ? space.exit() : root.tab = "home" }
        }
        Text {
            anchors.centerIn: parent
            text: root.tab === "home" ? "" : (root.tab === "forecast" ? "预报" : root.tab === "life" ? "生活指数" : root.tab === "city" ? "城市管理" : "设置")
            font.pixelSize: root.f(30); font.weight: Font.Medium; color: root.ink
        }
        // 首页顶栏: 城市 + 日期居中 (其它页在中间显示页名, 右上角显示城市)
        Column {
            visible: root.tab === "home"
            anchors.centerIn: parent
            spacing: 2
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: root.u(8)
                Image {
                    width: root.f(26); height: width; sourceSize.width: width; sourceSize.height: width
                    anchors.verticalCenter: parent.verticalCenter
                    source: root.dir + "i-pin.svg"; fillMode: Image.PreserveAspectFit; opacity: 0.75
                }
                Text { text: root.city().name; font.pixelSize: root.f(30); font.weight: Font.Medium; color: root.ink
                       anchors.verticalCenter: parent.verticalCenter }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.wx ? (root.wx.date.substring(5, 7) + "月" + root.wx.date.substring(8, 10) + "日 " + W.weekday(root.wx.date)) : ""
                font.pixelSize: root.f(21); color: root.ink2
            }
        }
        Text {
            visible: root.tab !== "home" && root.tab !== "city" && root.tab !== "setting"
            anchors.right: refreshBtn.left; anchors.rightMargin: root.u(20); anchors.verticalCenter: parent.verticalCenter
            text: root.city().name; font.pixelSize: root.f(24); color: root.ink2
        }
        Image {
            id: refreshBtn
            anchors.right: parent.right; anchors.rightMargin: root.u(28); anchors.verticalCenter: parent.verticalCenter
            width: root.f(32); height: width; sourceSize.width: width; sourceSize.height: width
            source: root.dir + (root.tab === "city" ? "i-plus.svg" : "i-refresh.svg"); fillMode: Image.PreserveAspectFit
            opacity: root.busy ? 0.35 : 0.85
            MouseArea {
                anchors.fill: parent; anchors.margins: -root.u(18)
                onClicked: { if (root.tab === "city") searchInput.forceActiveFocus(); else root.refresh() }
            }
        }
    }

    // 状态提示条 (4 秒自动消失)
    Rectangle {
        id: toast
        visible: root.status !== ""
        z: 5
        anchors.top: header.bottom; anchors.left: parent.left; anchors.right: parent.right
        anchors.leftMargin: root.u(28); anchors.rightMargin: root.u(28)
        height: toastText.implicitHeight + root.u(16)
        color: "#2B2B2B"; radius: 8
        Text { id: toastText; anchors.fill: parent; anchors.margins: root.u(8)
               text: root.status; color: "white"; font.pixelSize: root.f(21); wrapMode: Text.WordWrap }
        Timer { interval: 4000; repeat: false; running: root.status !== "" && !root.busy; onTriggered: root.status = "" }
    }

    // ═══ 内容区 ═══
    Item {
        id: content
        anchors.top: header.bottom; anchors.bottom: tabbar.top
        anchors.left: parent.left; anchors.right: parent.right
        anchors.leftMargin: root.u(28); anchors.rightMargin: root.u(28)

        // ─────── 首页 (版式按概念图: 大温度 + 大图标 / 整块插画 / 三项速览 / 一句建议) ───────
        ColumnLayout {
            visible: root.tab === "home"
            anchors.fill: parent
            spacing: root.u(14)

            // 温度 + 大天气图标
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: root.u(8)
                ColumnLayout {
                    spacing: 2
                    RowLayout {
                        spacing: root.u(8)
                        Text {
                            text: root.wx ? String(root.t(root.wx.temp)) : "--"
                            font.pixelSize: root.f(92); font.weight: Font.Light; color: root.ink
                        }
                        Text {
                            Layout.alignment: Qt.AlignTop; Layout.topMargin: root.f(18)
                            text: W.unitSign(root.unit()); font.pixelSize: root.f(28); color: root.ink
                        }
                    }
                    Text {
                        text: root.wx ? root.wx.text : (root.busy ? "获取中…" : "暂无数据")
                        font.pixelSize: root.f(34); font.weight: Font.Medium; color: root.ink
                    }
                    Text {
                        visible: !!root.wx
                        text: root.wx ? ("体感 " + root.t(root.wx.feels) + "°   ↑ " + root.t(root.wx.hi) + "°  ↓ " + root.t(root.wx.lo) + "°") : ""
                        font.pixelSize: root.f(22); color: root.ink2
                    }
                }
                Item { Layout.fillWidth: true }
                Image {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.rightMargin: root.u(10)
                    Layout.preferredWidth: root.u(150); Layout.preferredHeight: root.u(150)
                    sourceSize.width: 300; sourceSize.height: 300
                    source: root.wx ? root.icon(root.wx.code, root.wx.day) : root.dir + "w-sun.svg"
                    fillMode: Image.PreserveAspectFit
                }
            }

            // 插画: 吃掉所有剩余高度, 页面不留空白
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: root.u(260)
                radius: 14; color: root.card; border.color: root.line; border.width: 1; clip: true
                Image {
                    id: sceneImg
                    anchors.fill: parent
                    // 自带的矢量插画是横条, 拉满会糊; 只有真素材才铺满裁切
                    fillMode: source == fallback ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                    sourceSize.width: 1200
                    // 选图顺序由 sceneChain 给出: 夜间图 → 同款白天 → 邻近季节同款 → 矢量插画
                    property var chain: W.sceneChain(root.wx, root.space.localNow())
                    property int step: 0
                    property string fallback: root.dir + "scene.svg"
                    source: root.dir + chain[0]
                    onChainChanged: { step = 0; source = root.dir + chain[0] }
                    onStatusChanged: {
                        if (status !== Image.Error) return
                        if (step + 1 >= chain.length) return
                        step += 1
                        source = root.dir + chain[step]
                    }
                }
            }

            // 三项速览
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: root.u(110)
                radius: 14; color: root.card; border.color: root.line; border.width: 1
                RowLayout {
                    anchors.fill: parent; anchors.margins: root.u(10); spacing: 0
                    Repeater {
                        model: [
                            { ic: "i-wind", label: root.wx ? W.windDir(root.wx.windDeg) : "风", val: root.wx ? (W.windLevel(root.wx.wind) + " 级") : "--" },
                            { ic: "i-humidity", label: "湿度", val: root.wx ? (root.wx.humidity + "%") : "--" },
                            { ic: "i-leaf", label: "空气质量", val: (root.wx && root.wx.aqi !== null) ? (W.aqiText(root.wx.aqi) + " " + root.wx.aqi) : "--" }
                        ]
                        delegate: Item {
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true; Layout.fillHeight: true
                            Row {
                                anchors.centerIn: parent; spacing: root.u(10)
                                Image {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: root.f(30); height: width; sourceSize.width: width; sourceSize.height: width
                                    source: root.dir + modelData.ic + ".svg"; fillMode: Image.PreserveAspectFit; opacity: 0.8
                                }
                                Column {
                                    spacing: 2
                                    Text { text: modelData.label; font.pixelSize: root.f(20); color: root.ink2 }
                                    Text { text: modelData.val; font.pixelSize: root.f(24); font.weight: Font.Medium; color: root.ink }
                                }
                            }
                            Rectangle {
                                visible: index > 0
                                anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                width: 1; height: parent.height * 0.5; color: root.line
                            }
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                Layout.bottomMargin: root.u(6)
                text: root.wx ? root.wx.advice : ""
                font.pixelSize: root.f(22); color: root.ink2; wrapMode: Text.WordWrap
            }
        }

        // ─────── 预报 ───────
        Item {
            visible: root.tab === "forecast"
            anchors.fill: parent

            Row {   // 段控
                id: seg
                anchors.top: parent.top; anchors.topMargin: root.u(10)
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: root.u(10)
                Repeater {
                    model: [{ k: "hourly", n: "逐小时预报" }, { k: "daily", n: "未来 7 天" }]
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool sel: root.fcTab === modelData.k
                        width: root.f(200); height: root.f(58); radius: height / 2
                        color: sel ? root.ink : "transparent"
                        border.color: sel ? root.ink : root.line; border.width: 1
                        Text { anchors.centerIn: parent; text: modelData.n; font.pixelSize: root.f(23)
                               color: parent.sel ? "white" : root.ink2 }
                        MouseArea { anchors.fill: parent; onClicked: root.fcTab = modelData.k }
                    }
                }
            }
            Text {
                id: fcDate
                anchors.top: seg.bottom; anchors.topMargin: root.u(14)
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.fcTab === "hourly" && !!root.wx
                text: root.wx ? (root.wx.date.substring(5, 7) + "月" + root.wx.date.substring(8, 10) + "日 " + W.weekday(root.wx.date)) : ""
                font.pixelSize: root.f(21); color: root.ink2
            }
            Rectangle {
                anchors.top: fcDate.visible ? fcDate.bottom : seg.bottom
                anchors.topMargin: root.u(12)
                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                anchors.bottomMargin: root.u(10)
                radius: 14; color: root.card; border.color: root.line; border.width: 1; clip: true

                // 逐小时
                Flickable {
                    visible: root.fcTab === "hourly"
                    anchors.fill: parent; anchors.margins: root.u(6)
                    contentWidth: width; contentHeight: hourCol.height; clip: true
                    Column {
                        id: hourCol
                        width: parent.width
                        Repeater {
                            model: root.wx ? root.wx.hours : []
                            delegate: Item {
                                required property var modelData
                                required property int index
                                width: hourCol.width; height: root.u(78)
                                Text { x: root.u(24); anchors.verticalCenter: parent.verticalCenter
                                       text: modelData.time; font.pixelSize: root.f(24); color: index === 0 ? root.ink : root.ink2 }
                                Image {
                                    anchors.centerIn: parent
                                    width: root.f(40); height: width; sourceSize.width: 80; sourceSize.height: 80
                                    source: root.icon(modelData.code, modelData.day); fillMode: Image.PreserveAspectFit
                                }
                                Text {
                                    anchors.right: parent.right; anchors.rightMargin: root.u(24); anchors.verticalCenter: parent.verticalCenter
                                    text: root.t(modelData.temp) + "°"; font.pixelSize: root.f(25); color: root.ink
                                }
                                Rectangle { anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right
                                            anchors.leftMargin: root.u(20); anchors.rightMargin: root.u(20)
                                            height: 1; color: root.line; visible: index < (root.wx ? root.wx.hours.length - 1 : 0) }
                            }
                        }
                    }
                }

                // 未来 7 天
                Flickable {
                    visible: root.fcTab === "daily"
                    anchors.fill: parent; anchors.margins: root.u(6)
                    contentWidth: width; contentHeight: dayCol.height; clip: true
                    Column {
                        id: dayCol
                        width: parent.width
                        Repeater {
                            model: root.wx ? root.wx.days : []
                            delegate: Item {
                                required property var modelData
                                required property int index
                                width: dayCol.width; height: root.u(104)
                                Column {
                                    x: root.u(24); anchors.verticalCenter: parent.verticalCenter; spacing: 2
                                    Text { text: index === 0 ? "今天" : W.weekday(modelData.date); font.pixelSize: root.f(25); color: root.ink }
                                    Text { text: W.mmdd(modelData.date); font.pixelSize: root.f(19); color: root.ink2 }
                                }
                                Image {
                                    anchors.horizontalCenter: parent.horizontalCenter; anchors.horizontalCenterOffset: -root.u(40)
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: root.f(44); height: width; sourceSize.width: 88; sourceSize.height: 88
                                    source: root.icon(modelData.code, true); fillMode: Image.PreserveAspectFit
                                }
                                Column {
                                    anchors.right: parent.right; anchors.rightMargin: root.u(24)
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 2
                                    Text { anchors.right: parent.right
                                           text: root.t(modelData.lo) + "° / " + root.t(modelData.hi) + "°"
                                           font.pixelSize: root.f(24); color: root.ink }
                                    Text { anchors.right: parent.right; text: W.codeText(modelData.code)
                                           font.pixelSize: root.f(20); color: root.ink2 }
                                }
                                Rectangle { anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right
                                            anchors.leftMargin: root.u(20); anchors.rightMargin: root.u(20)
                                            height: 1; color: root.line; visible: index < (root.wx ? root.wx.days.length - 1 : 0) }
                            }
                        }
                    }
                }
            }
        }

        // ─────── 生活 (指数 + 详情) ───────
        Flickable {
            visible: root.tab === "life"
            anchors.fill: parent
            contentWidth: width; contentHeight: lifeCol.height + root.u(20); clip: true
            ColumnLayout {
                id: lifeCol
                width: parent.width
                spacing: root.u(14)

                GridLayout {
                    Layout.fillWidth: true; Layout.topMargin: root.u(10)
                    columns: 3; rowSpacing: root.u(12); columnSpacing: root.u(12)
                    Repeater {
                        model: W.indices(root.wx)
                        delegate: Rectangle {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.preferredHeight: root.u(150)
                            radius: 14; color: root.card; border.color: root.line; border.width: 1
                            Column {
                                anchors.centerIn: parent; spacing: root.u(6)
                                Image {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: root.f(38); height: width; sourceSize.width: width; sourceSize.height: width
                                    source: root.dir + modelData.icon + ".svg"; fillMode: Image.PreserveAspectFit; opacity: 0.85
                                }
                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.name
                                       font.pixelSize: root.f(22); color: root.ink }
                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.level
                                       font.pixelSize: root.f(20); color: root.ink2 }
                            }
                        }
                    }
                }

                Text { Layout.topMargin: root.u(6); text: "天气详情"; font.pixelSize: root.f(26); font.weight: Font.Medium; color: root.ink }
                GridLayout {
                    Layout.fillWidth: true
                    columns: 2; rowSpacing: root.u(12); columnSpacing: root.u(12)
                    Repeater {
                        model: root.wx ? [
                            { ic: "i-temp", n: "体感温度", v: root.t(root.wx.feels) + W.unitSign(root.unit()) },
                            { ic: "i-humidity", n: "相对湿度", v: root.wx.humidity + "%" },
                            { ic: "i-wind", n: "风向风速", v: W.windDir(root.wx.windDeg) + " " + W.windLevel(root.wx.wind) + " 级" },
                            { ic: "i-leaf", n: "空气质量", v: root.wx.aqi !== null ? (W.aqiText(root.wx.aqi) + " " + root.wx.aqi) : "暂无" },
                            { ic: "i-eye", n: "能见度", v: root.wx.visibility !== null ? (root.wx.visibility + " 公里") : "暂无" },
                            { ic: "i-uv", n: "紫外线", v: W.uvText(root.wx.uv) + " " + root.wx.uv }
                        ] : []
                        delegate: Rectangle {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.preferredHeight: root.u(130)
                            radius: 14; color: root.card; border.color: root.line; border.width: 1
                            Column {
                                anchors.centerIn: parent; spacing: root.u(6)
                                Image {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: root.f(34); height: width; sourceSize.width: width; sourceSize.height: width
                                    source: root.dir + modelData.ic + ".svg"; fillMode: Image.PreserveAspectFit; opacity: 0.85
                                }
                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.n
                                       font.pixelSize: root.f(21); color: root.ink2 }
                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.v
                                       font.pixelSize: root.f(24); font.weight: Font.Medium; color: root.ink }
                            }
                        }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true; Layout.topMargin: root.u(4)
                    Text { text: root.wx ? ("日出 " + root.wx.sunrise) : ""; font.pixelSize: root.f(21); color: root.ink2 }
                    Item { Layout.fillWidth: true }
                    Text { text: root.wx ? ("日落 " + root.wx.sunset) : ""; font.pixelSize: root.f(21); color: root.ink2 }
                }
            }
        }

        // ─────── 城市管理 ───────
        Flickable {
            visible: root.tab === "city"
            anchors.fill: parent
            contentWidth: width; contentHeight: cityCol.height + root.u(20); clip: true
            ColumnLayout {
                id: cityCol
                width: parent.width
                spacing: root.u(12)

                RowLayout {
                    Layout.fillWidth: true; Layout.topMargin: root.u(10)
                    spacing: root.u(10)
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: root.f(60)
                        radius: 10; color: root.card
                        border.color: searchInput.activeFocus ? root.ink : root.line; border.width: 1
                        TextInput {
                            id: searchInput
                            anchors.fill: parent; anchors.leftMargin: root.u(16); anchors.rightMargin: root.u(16)
                            verticalAlignment: TextInput.AlignVCenter
                            font.pixelSize: root.f(23); color: root.ink
                            selectByMouse: true; clip: true
                            onAccepted: root.search()
                        }
                        Text {
                            anchors.left: parent.left; anchors.leftMargin: root.u(16); anchors.verticalCenter: parent.verticalCenter
                            visible: searchInput.text === "" && !searchInput.activeFocus
                            text: "输入城市名，如 北京"; font.pixelSize: root.f(23); color: "#B5B0A6"
                        }
                    }
                    Rectangle {
                        Layout.preferredWidth: root.f(120); Layout.preferredHeight: root.f(60)
                        radius: 10; color: root.ink
                        Text { anchors.centerIn: parent; text: "搜索"; font.pixelSize: root.f(23); color: "white" }
                        MouseArea { anchors.fill: parent; onClicked: root.search() }
                    }
                }

                // 检索结果
                Column {
                    Layout.fillWidth: true
                    visible: root.results.length > 0
                    Repeater {
                        model: root.results
                        delegate: Rectangle {
                            required property var modelData
                            width: cityCol.width; height: root.u(88)
                            color: "transparent"
                            Text {
                                x: root.u(16); anchors.verticalCenter: parent.verticalCenter
                                text: modelData.name + "   " + modelData.admin + (modelData.country && modelData.country !== "中国" ? " · " + modelData.country : "")
                                font.pixelSize: root.f(24); color: root.ink
                            }
                            Text { anchors.right: parent.right; anchors.rightMargin: root.u(16); anchors.verticalCenter: parent.verticalCenter
                                   text: "添加"; font.pixelSize: root.f(22); color: root.ink2 }
                            Rectangle { anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right; height: 1; color: root.line }
                            MouseArea { anchors.fill: parent; onClicked: root.addCity(modelData) }
                        }
                    }
                }

                Text { text: "我的城市"; font.pixelSize: root.f(24); font.weight: Font.Medium; color: root.ink; Layout.topMargin: root.u(6) }
                Column {
                    Layout.fillWidth: true
                    Repeater {
                        model: root.cfg ? root.cfg.cities : []
                        delegate: Rectangle {
                            required property var modelData
                            required property int index
                            readonly property var cd: root.cache[W.cityKey(modelData)]
                            width: cityCol.width; height: root.u(112)
                            radius: 12
                            color: index === root.cfg.current ? "#F0EEE8" : root.card
                            border.color: root.line; border.width: 1
                            Column {
                                x: root.u(20); anchors.verticalCenter: parent.verticalCenter; spacing: 4
                                Row {
                                    spacing: root.u(8)
                                    Text { text: modelData.name; font.pixelSize: root.f(26); font.weight: Font.Medium; color: root.ink }
                                    Image {
                                        visible: index === root.cfg.current
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: root.f(20); height: width; sourceSize.width: width; sourceSize.height: width
                                        source: root.dir + "i-star-fill.svg"; fillMode: Image.PreserveAspectFit
                                    }
                                }
                                Text { text: modelData.admin || ""; font.pixelSize: root.f(19); color: root.ink2 }
                            }
                            Row {
                                anchors.right: parent.right; anchors.rightMargin: root.u(20); anchors.verticalCenter: parent.verticalCenter
                                spacing: root.u(16)
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: cd ? (root.t(cd.lo) + "° / " + root.t(cd.hi) + "°") : "—"
                                    font.pixelSize: root.f(23); color: root.ink2
                                }
                                Image {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: root.f(38); height: width; sourceSize.width: 76; sourceSize.height: 76
                                    source: cd ? root.icon(cd.code, true) : root.dir + "w-cloud.svg"
                                    fillMode: Image.PreserveAspectFit; opacity: cd ? 1 : 0.3
                                }
                                Image {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: root.cfg.cities.length > 1
                                    width: root.f(28); height: width; sourceSize.width: width; sourceSize.height: width
                                    source: root.dir + "i-trash.svg"; fillMode: Image.PreserveAspectFit; opacity: 0.55
                                    MouseArea { anchors.fill: parent; anchors.margins: -root.u(12); onClicked: root.removeCity(index) }
                                }
                            }
                            MouseArea {
                                anchors.fill: parent; anchors.rightMargin: root.u(70)
                                onClicked: root.selectCity(index)
                            }
                        }
                    }
                }

                Text { text: "常用城市"; font.pixelSize: root.f(24); font.weight: Font.Medium; color: root.ink; Layout.topMargin: root.u(8) }
                Flow {
                    Layout.fillWidth: true
                    spacing: root.u(10)
                    Repeater {
                        model: W.COMMON_CITIES
                        delegate: Rectangle {
                            required property var modelData
                            width: root.f(112); height: root.f(58); radius: height / 2
                            color: root.card; border.color: root.line; border.width: 1
                            Text { anchors.centerIn: parent; text: modelData.name; font.pixelSize: root.f(22); color: root.ink }
                            MouseArea { anchors.fill: parent; onClicked: root.addCity(modelData) }
                        }
                    }
                }
            }
        }

        // ─────── 设置 ───────
        Flickable {
            visible: root.tab === "setting"
            anchors.fill: parent
            contentWidth: width; contentHeight: setCol.height + root.u(20); clip: true
            ColumnLayout {
                id: setCol
                width: parent.width
                spacing: 0

                Item { Layout.preferredHeight: root.u(10); Layout.fillWidth: true }

                // 温度单位
                Item {
                    Layout.fillWidth: true; Layout.preferredHeight: root.u(104)
                    Text { x: root.u(6); anchors.verticalCenter: parent.verticalCenter; text: "温度单位"
                           font.pixelSize: root.f(25); color: root.ink }
                    Row {
                        anchors.right: parent.right; anchors.rightMargin: root.u(6); anchors.verticalCenter: parent.verticalCenter
                        spacing: root.u(8)
                        Repeater {
                            model: [{ k: "c", n: "°C" }, { k: "f", n: "°F" }]
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool sel: root.unit() === modelData.k
                                width: root.f(84); height: root.f(54); radius: height / 2
                                color: sel ? root.ink : "transparent"; border.color: sel ? root.ink : root.line; border.width: 1
                                Text { anchors.centerIn: parent; text: modelData.n; font.pixelSize: root.f(22)
                                       color: parent.sel ? "white" : root.ink2 }
                                MouseArea { anchors.fill: parent; onClicked: { root.cfg.unit = modelData.k; root.commit(); root.saveCfg(null) } }
                            }
                        }
                    }
                    Rectangle { anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right; height: 1; color: root.line }
                }
                // 更新频率
                Item {
                    Layout.fillWidth: true; Layout.preferredHeight: root.u(104)
                    Text { x: root.u(6); anchors.verticalCenter: parent.verticalCenter; text: "更新频率"
                           font.pixelSize: root.f(25); color: root.ink }
                    Row {
                        anchors.right: parent.right; anchors.rightMargin: root.u(6); anchors.verticalCenter: parent.verticalCenter
                        spacing: root.u(8)
                        Repeater {
                            model: [{ s: 1800, n: "30 分钟" }, { s: 3600, n: "1 小时" }, { s: 10800, n: "3 小时" }]
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool sel: root.cfg && root.cfg.refresh === modelData.s
                                width: root.f(112); height: root.f(54); radius: height / 2
                                color: sel ? root.ink : "transparent"; border.color: sel ? root.ink : root.line; border.width: 1
                                Text { anchors.centerIn: parent; text: modelData.n; font.pixelSize: root.f(21)
                                       color: parent.sel ? "white" : root.ink2 }
                                MouseArea { anchors.fill: parent; onClicked: { root.cfg.refresh = modelData.s; root.commit(); root.saveCfg(null) } }
                            }
                        }
                    }
                    Rectangle { anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right; height: 1; color: root.line }
                }
                // 只读信息行
                Repeater {
                    model: [
                        { n: "数据来源", v: "Open-Meteo" },
                        { n: "当前城市", v: root.city().name },
                        { n: "最近更新", v: root.wx ? Qt.formatDateTime(new Date(root.wx.at), "MM-dd HH:mm") : "还没有数据" }
                    ]
                    delegate: Item {
                        required property var modelData
                        Layout.fillWidth: true; Layout.preferredHeight: root.u(104)
                        Text { x: root.u(6); anchors.verticalCenter: parent.verticalCenter; text: modelData.n
                               font.pixelSize: root.f(25); color: root.ink }
                        Text { anchors.right: parent.right; anchors.rightMargin: root.u(6); anchors.verticalCenter: parent.verticalCenter
                               text: modelData.v; font.pixelSize: root.f(23); color: root.ink2 }
                        Rectangle { anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right; height: 1; color: root.line }
                    }
                }
                Text {
                    Layout.fillWidth: true; Layout.topMargin: root.u(20)
                    text: "天气数据来自 Open-Meteo（open-meteo.com），空气质量为 US AQI 口径。\n设备联网时按上面的频率更新，离线时显示最近一次结果。"
                    font.pixelSize: root.f(20); color: root.ink2; wrapMode: Text.WordWrap
                }
            }
        }
    }

    // ═══ 底部标签栏 ═══
    Rectangle {
        id: tabbar
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
        height: root.u(120)
        color: root.paper
        Rectangle { anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right; height: 1; color: root.line }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: root.u(20); anchors.rightMargin: root.u(20)
            spacing: 0
            Repeater {
                model: [
                    { k: "home", n: "首页", ic: "house", kit: true },
                    { k: "forecast", n: "预报", ic: "i-cloudtab", kit: false },
                    { k: "life", n: "生活", ic: "i-life", kit: false },
                    { k: "city", n: "城市", ic: "i-pin", kit: false },
                    { k: "setting", n: "设置", ic: "gear", kit: true }
                ]
                delegate: Item {
                    id: tabItem
                    required property var modelData
                    readonly property bool sel: root.tab === modelData.k
                    Layout.fillWidth: true; Layout.fillHeight: true
                    Column {
                        anchors.centerIn: parent; spacing: root.u(6)
                        Image {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: root.f(36); height: width; sourceSize.width: width; sourceSize.height: width
                            source: (tabItem.modelData.kit ? space.kitDir + "/icons/" : root.dir) + tabItem.modelData.ic + ".svg"
                            fillMode: Image.PreserveAspectFit
                            opacity: tabItem.sel ? 1 : 0.5
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: tabItem.modelData.n; font.pixelSize: root.f(21)
                            font.weight: tabItem.sel ? Font.Medium : Font.Normal
                            color: tabItem.sel ? root.ink : root.ink2
                        }
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: root.f(26); height: 3
                            color: tabItem.sel ? root.ink : "transparent"
                        }
                    }
                    MouseArea { anchors.fill: parent; onClicked: root.tab = tabItem.modelData.k }
                }
            }
        }
    }
}
