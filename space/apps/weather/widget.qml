// 天气 — 「空间」首页整宽大卡 (hero 小组件)
// 版式参考概念图首页: 日期 / 城市 / 大温度 / 天气 / 高低温 / 一句话 + 右侧插画与天气图标。
import QtQuick
import "weather.js" as W

Item {
    id: w
    property var space
    property var app            // 本应用的注册表条目 (id / appDir / iconUrl)
    anchors.fill: parent

    readonly property string dir: app ? "file://" + app.dir + "/assets/" : ""
    readonly property real fs: space ? space.fontScale : 1
    readonly property real un: space ? space.unit : 1
    function f(n) { return Math.round(n * w.fs) }
    function u(n) { return Math.round(n * w.un) }

    property var cfg: null
    property var wx: null
    property string err: ""
    property date now: space ? space.localNow() : new Date()

    Timer { interval: 30000; running: w.visible; repeat: true; onTriggered: w.now = space.localNow() }

    function city() { return (cfg && cfg.cities && cfg.cities.length) ? cfg.cities[Math.min(cfg.current, cfg.cities.length - 1)] : W.DEFAULT_CITY }
    function t(c) { return W.toUnit(c, cfg ? cfg.unit : "c") }

    function load() {
        space.dataGet(app.id, "config", function(st, r) {
            cfg = (st === 200 && r && r.cities && r.cities.length) ? r : W.DEFAULT_CONFIG
            space.dataGet(app.id, "cache", function(st2, r2) {
                var c = (st2 === 200 && r2) ? r2[W.cityKey(city())] : null
                if (c && c.temp !== undefined) wx = c
                if (!wx || Date.now() - wx.at > cfg.refresh * 1000) refresh()
            })
        })
    }
    function refresh() {
        W.fetchCity(space, city(), function(d, e) {
            if (!d) { err = e; return }
            err = ""; wx = d
            space.dataGet(app.id, "cache", function(st, r) {
                var all = (st === 200 && r) ? r : ({})
                all[W.cityKey(city())] = d
                space.dataPut(app.id, "cache", all, null)
            })
        })
    }
    Component.onCompleted: load()

    // ── 插画横幅: 整宽铺在卡片下缘 ────────────────────────────────
    // 用 *-band.jpg (画面下部裁出的横幅, 上缘渐隐已烤在图里)。
    // 竖构图的整图塞进这么扁的带子只能取到天空那一片白, 所以单独出了横幅素材。
    Item {
        id: band
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
        height: Math.round(parent.height * 0.47)
        clip: true
        Image {
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            sourceSize.width: 1100
            property var chain: {
                if (!w.wx) return []
                var base = W.sceneChain(w.wx, w.now)
                var out = []
                for (var i = 0; i < base.length; ++i)
                    if (base[i].indexOf(".jpg") > 0) out.push(base[i].replace(".jpg", "-band.jpg"))
                return out.concat(base)
            }
            property int step: 0
            source: chain.length ? w.dir + chain[0] : ""
            visible: status === Image.Ready
            onChainChanged: { step = 0; source = chain.length ? w.dir + chain[0] : "" }
            onStatusChanged: {
                if (status !== Image.Error) return
                if (step + 1 >= chain.length) return
                step += 1
                source = w.dir + chain[step]
            }
        }
    }

    // 盖掉横幅在圆角外露出的方角
    Rectangle {
        anchors.fill: parent
        color: "transparent"
        radius: 12
        border.color: "white"; border.width: 6
    }
    Rectangle {
        anchors.fill: parent
        color: "transparent"
        radius: 12
        border.color: "#B4AFA6"; border.width: 1
    }

    // ── 左: 日期 + 时间 + 一句话 ──────────────────────────────────
    Column {
        anchors.left: parent.left; anchors.leftMargin: w.u(32)
        anchors.top: parent.top; anchors.topMargin: w.u(26)
        width: parent.width * 0.5
        spacing: w.u(2)
        Text {
            text: w.now.toLocaleDateString(Qt.locale("zh_CN"), "M月d日 dddd")
            font.pixelSize: w.f(24); color: "#000000"
        }
        Text {
            text: Qt.formatTime(w.now, "HH:mm")
            font.pixelSize: w.f(92); font.weight: Font.Light; color: "#000000"
        }
        Text {
            width: parent.width
            text: w.wx ? w.wx.advice : (w.err !== "" ? w.err + "，点这里重试" : "")
            font.pixelSize: w.f(22); color: "#000000"; elide: Text.ElideRight
        }
    }

    // ── 右: 城市 + 天气 ───────────────────────────────────────────
    Column {
        anchors.right: parent.right; anchors.rightMargin: w.u(36)
        anchors.top: parent.top; anchors.topMargin: w.u(26)
        spacing: w.u(4)
        Row {
            anchors.right: parent.right
            spacing: w.u(8)
            Image {
                anchors.verticalCenter: parent.verticalCenter
                width: w.f(26); height: width; sourceSize.width: width; sourceSize.height: width
                source: w.dir + "i-pin-fill.svg"; fillMode: Image.PreserveAspectFit
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: w.city().name; font.pixelSize: w.f(30); font.weight: Font.Medium; color: "#000000"
            }
        }
        Row {
            anchors.right: parent.right
            spacing: w.u(10)
            Image {
                anchors.verticalCenter: parent.verticalCenter
                width: w.u(76); height: width
                sourceSize.width: 160; sourceSize.height: 160
                source: w.wx ? (w.dir + W.codeIcon(w.wx.code, w.wx.day) + ".svg") : (w.dir + "w-sun.svg")
                fillMode: Image.PreserveAspectFit
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: (w.wx ? String(w.t(w.wx.temp)) : "--") + W.unitSign(w.cfg ? w.cfg.unit : "c")
                font.pixelSize: w.f(52); font.weight: Font.Light; color: "#000000"
            }
        }
        Text {
            anchors.right: parent.right
            text: w.wx ? w.wx.text : (w.err !== "" ? "暂无天气数据" : "获取中…")
            font.pixelSize: w.f(28); font.weight: Font.Bold; color: "#000000"
        }
        Text {
            anchors.right: parent.right
            visible: !!w.wx
            text: w.wx ? ("↑ " + w.t(w.wx.hi) + "°   ↓ " + w.t(w.wx.lo) + "°") : ""
            font.pixelSize: w.f(22); color: "#000000"
        }
    }

    MouseArea {
        anchors.fill: parent
        onClicked: { if (!w.wx && w.cfg) w.refresh(); else space.openApp(app.id) }
    }
}
