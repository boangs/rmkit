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

    // ── 整屏常驻一个刷新波形标记 ──────────────────────────────────────────
    // 症状: 进出本应用时, 只有插画那一块被整块闪黑重刷, 四周 (顶栏/速览/标签栏)
    // 走的是另一种波形, 于是两者交界处被刷出一道撕裂的硬边。
    // 原因不在图片边缘做得够不够柔 (直边、毛边、模糊都试过), 而在于屏幕把这块
    // 彩色照片和周围的白底文字分给了不同的刷新波形, 边界就是波形区的边界。
    // 办法: 整屏挂一个常驻 ScreenModeItem, 全屏同一种波形, 就没有交界可撕。
    // 模式取 UI: 原厂 MainView 的全局标记默认就是这一档 (见 qml-dump 的
    // globalScreenMode), 空间首页也跑在它上面 —— 又快、彩色正常、不留残影。
    // 走过的弯路: Animation 档不闪但没有灰阶抗锯齿, 照片被压成无彩色的粗颗粒;
    // Content 档画质满但慢, 且进应用会把上一屏的残影带进来。
    // 几何必须零变化 (anchors.fill 根节点), 模式图每变一次几何就整屏重新合成。
    // 固件若没有这个类型 (非原厂 libqsgepaper), try/catch 静默降级。
    property var _screenMode: null
    function _markScreenMode() {
        try {
            _screenMode = Qt.createQmlObject(
                'import QtQuick; import xofm.libs.epaper; ' +
                'ScreenModeItem { anchors.fill: parent; mode: ScreenModeItem.UI }',
                root, "weatherScreenMode")
        } catch (e) {
            console.warn("[weather] ScreenModeItem 不可用, 沿用默认刷新: " + e)
        }
    }


    // 墨水屏没有背光, 浅色底要靠抖动铺, 看起来就发灰。一律纯白, 层次交给描边。
    readonly property color paper: "#FFFFFF"
    readonly property color card: "#FFFFFF"
    readonly property color line: "#B4AFA6"   // 原 #D8D5CE 亮度 85%, 墨水屏上几乎看不见
    readonly property color ink: "#2B2B2B"
    readonly property color ink2: "#46443E"   // 墨水屏本身偏灰, 次要文字也要够深

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
    // 本地缓存读完才算"可以画了"。在此之前首页整块不显示:
    // 否则先画一次没数据的空壳, 缓存回来再重排一次, 墨水屏就白闪一遍。
    property bool ready: false
    function load() {
        space.dataGet(space.appId, "config", function(st, r) {
            cfg = (st === 200 && r && r.cities && r.cities.length) ? r : W.DEFAULT_CONFIG
            space.dataGet(space.appId, "cache", function(st2, r2) {
                cache = (st2 === 200 && r2) ? r2 : ({})
                show()
                ready = true
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
        _markScreenMode()
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
        height: root.u(260)

        Image {
            id: backBtn
            x: root.u(28); y: root.u(60)
            width: root.f(34); height: width; sourceSize.width: width; sourceSize.height: width
            source: root.dir + "i-back.svg"; fillMode: Image.PreserveAspectFit
            MouseArea { anchors.fill: parent; anchors.margins: -root.u(18); onClicked: root.tab === "home" ? space.exit() : root.tab = "home" }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            y: root.u(64)
            text: root.tab === "home" ? "" : (root.tab === "forecast" ? "预报" : root.tab === "life" ? "生活指数" : root.tab === "city" ? "城市管理" : "设置")
            font.pixelSize: root.f(30); font.weight: Font.Medium; color: root.ink
        }
        // 首页顶栏: 城市 + 日期居中 (其它页在中间显示页名, 右上角显示城市)
        Column {
            // 宽度必须显式给满: 子项又按父宽居中、父宽又由子项撑开的话,
            // 两边互相依赖, 居中会算偏。
            visible: root.tab === "home"
            anchors.left: parent.left; anchors.right: parent.right
            y: root.u(118)
            spacing: 2
            // 城市名自己居中, 定位图标挂在它左边。
            // 图标若和文字一起算进居中范围, 文字就会被推得偏右, 看着不齐。
            Item {
                width: parent.width; height: cityName.height
                Text {
                    id: cityName
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.city().name; font.pixelSize: root.f(54)
                    font.weight: Font.Medium; color: root.ink
                }
                Image {
                    anchors.right: cityName.left; anchors.rightMargin: root.u(10)
                    anchors.verticalCenter: cityName.verticalCenter
                    width: root.f(40); height: width; sourceSize.width: width; sourceSize.height: width
                    // 实心版 (Phosphor map-pin-fill): 顶栏这颗要压得住加粗的城市名;
                    // 底部"城市"页签仍用描边版 i-pin.svg, 与其它页签统一。
                    source: root.dir + "i-pin-fill.svg"; fillMode: Image.PreserveAspectFit
                }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.wx ? (root.wx.date.substring(5, 7) + "月" + root.wx.date.substring(8, 10) + "日 " + W.weekday(root.wx.date)) : ""
                font.pixelSize: root.f(34); color: root.ink2
            }
        }
        Text {
            visible: root.tab !== "home" && root.tab !== "city" && root.tab !== "setting"
            anchors.right: refreshBtn.left; anchors.rightMargin: root.u(20); y: root.u(64)
            text: root.city().name; font.pixelSize: root.f(24); color: root.ink2
        }
        Image {
            id: refreshBtn
            anchors.right: parent.right; anchors.rightMargin: root.u(28); y: root.u(58)
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

        // ─────── 首页 (版式按概念图: 插画整幅铺底, 温度与文字压在天空上) ───────
        Item {
            visible: root.tab === "home" && root.ready
            anchors.fill: parent

            // 插画: 从内容区顶部一直铺到速览行, 顶部对齐 (画的上半是天, 正好垫文字)
            Item {
                id: sceneBox
                anchors.top: parent.top
                anchors.left: parent.left; anchors.right: parent.right
                anchors.bottom: statRow.top; anchors.bottomMargin: root.u(14)
                clip: true
                Image {
                    id: sceneImg
                    // 真素材都在 scenes/ 下; 用路径判断, 不受候选链更新时序影响
                    readonly property bool useFallback: String(source).indexOf("/scenes/") < 0
                    readonly property real sw: sourceSize.width > 0 ? sourceSize.width : 1
                    readonly property real sh: sourceSize.height > 0 ? sourceSize.height : 1
                    // 素材的上缘渐隐是烤在图里的 (见 tools/make-weather-scenes.sh),
                    // 所以顶边要对齐显示, 把这段白留全; 多出来的高度一律裁在下边。
                    readonly property real cover: Math.max(parent.width / sw, parent.height / sh)
                    width: useFallback ? parent.width : Math.round(sw * cover)
                    height: useFallback ? parent.height : Math.round(sh * cover)
                    x: useFallback ? 0 : Math.round((parent.width - width) / 2)
                    y: 0
                    fillMode: useFallback ? Image.PreserveAspectFit : Image.Stretch
                    // 选图顺序由 sceneChain 给出: 本季本款 → 本季近似 → 邻近季节 → 矢量插画
                    // 天气没回来时直接给空链 (不依赖 weather.js 的新版本:
                    // .js 按 URL 缓存, 不重启 xochitl 不生效)
                    property var chain: root.wx ? W.sceneChain(root.wx, root.space.localNow()) : []
                    property int step: 0
                    // 天气没回来时不给 source: 空着不画, 避免先上占位图再换真图多刷一次
                    visible: status === Image.Ready
                    source: chain.length ? root.dir + chain[0] : ""
                    onChainChanged: { step = 0; source = chain.length ? root.dir + chain[0] : "" }
                    onStatusChanged: {
                        if (status !== Image.Error) return
                        if (step + 1 >= chain.length) return
                        step += 1
                        source = root.dir + chain[step]
                    }
                }

            }

            // 温度 + 大天气图标: 压在插画的天空部分上
            RowLayout {
                // 上移 5mm: 屏幕 229 DPI, 1mm ≈ 9px, 所以 88 - 45 = 43
                anchors.top: sceneBox.top; anchors.topMargin: root.u(43)
                anchors.left: parent.left; anchors.right: parent.right
                ColumnLayout {
                    Layout.leftMargin: root.u(70)
                    spacing: 2
                    RowLayout {
                        spacing: root.u(8)
                        Text {
                            text: root.wx ? String(root.t(root.wx.temp)) : "--"
                            font.pixelSize: root.f(210); font.weight: Font.Light; color: root.ink
                        }
                        Text {
                            Layout.alignment: Qt.AlignTop; Layout.topMargin: root.f(42)
                            text: W.unitSign(root.unit()); font.pixelSize: root.f(46); color: root.ink
                        }
                    }
                    Text {
                        text: root.wx ? root.wx.text : (root.busy ? "获取中…" : "暂无数据")
                        font.pixelSize: root.f(48); font.weight: Font.Bold; color: root.ink
                    }
                    Text {
                        visible: !!root.wx
                        text: root.wx ? ("体感 " + root.t(root.wx.feels) + "°   ↑ " + root.t(root.wx.hi) + "°  ↓ " + root.t(root.wx.lo) + "°") : ""
                        font.pixelSize: root.f(34); color: root.ink2
                    }
                }
                Item { Layout.fillWidth: true }
            }

            // 三项速览
            Rectangle {
                id: statRow
                anchors.left: parent.left; anchors.right: parent.right
                anchors.bottom: adviceRule.top; anchors.bottomMargin: root.u(20)
                height: root.u(150)
                color: "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.topMargin: root.u(16); anchors.bottomMargin: root.u(6)
                    spacing: 0
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
                                anchors.centerIn: parent; spacing: root.u(24)
                                Image {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: root.f(56); height: width; sourceSize.width: width; sourceSize.height: width
                                    source: root.dir + modelData.ic + ".svg"; fillMode: Image.PreserveAspectFit; opacity: 0.9
                                }
                                Column {
                                    spacing: 2
                                    Text { text: modelData.label; font.pixelSize: root.f(30); color: root.ink }
                                    Text { text: modelData.val; font.pixelSize: root.f(32); font.weight: Font.Medium; color: root.ink }
                                }
                            }
                            Rectangle {
                                visible: index > 0
                                anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                width: 1; height: parent.height * 0.62; color: root.line
                            }
                        }
                    }
                }
            }

            // 书页式: 插画下面不压线, 只在最后这句建议上面压一条, 像注释的分界
            Rectangle {
                id: adviceRule
                anchors.left: parent.left; anchors.right: parent.right
                anchors.bottom: adviceText.top; anchors.bottomMargin: root.u(20)
                height: 1; color: root.line
            }

            Text {
                id: adviceText
                anchors.left: parent.left; anchors.right: parent.right
                anchors.bottom: parent.bottom; anchors.bottomMargin: root.u(20)
                // 高度写死一行: 文字空着时高度归零会把上面那条细线拽下去,
                // 数据回来又弹回去, 等于多刷一次屏。
                height: root.f(36) * 1.5
                verticalAlignment: Text.AlignVCenter
                text: root.wx ? root.wx.advice : ""
                font.pixelSize: root.f(36); color: root.ink; wrapMode: Text.WordWrap
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
