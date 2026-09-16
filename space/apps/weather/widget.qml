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

    // ── 左侧文字 ──
    Column {
        anchors.left: parent.left; anchors.leftMargin: w.u(32)
        anchors.verticalCenter: parent.verticalCenter
        spacing: w.u(4)

        Row {
            spacing: w.u(8)
            Image {
                anchors.verticalCenter: parent.verticalCenter
                width: w.f(24); height: width; sourceSize.width: width; sourceSize.height: width
                source: w.dir + "i-pin.svg"; fillMode: Image.PreserveAspectFit; opacity: 0.7
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: w.city().name; font.pixelSize: w.f(26); font.weight: Font.Medium; color: "#2B2B2B"
            }
        }
        Text {
            text: w.now.toLocaleDateString(Qt.locale("zh_CN"), "M月d日 dddd") + "   " + Qt.formatTime(w.now, "HH:mm")
            font.pixelSize: w.f(21); color: "#7C786F"
        }
        Row {
            spacing: w.u(4)
            Text { text: w.wx ? String(w.t(w.wx.temp)) : "--"; font.pixelSize: w.f(78); font.weight: Font.Light; color: "#2B2B2B" }
            Text {
                text: W.unitSign(w.cfg ? w.cfg.unit : "c"); font.pixelSize: w.f(24); color: "#2B2B2B"
                anchors.top: parent.top; anchors.topMargin: w.f(14)
            }
        }
        Text {
            text: w.wx ? w.wx.text : (w.err !== "" ? "暂无天气数据" : "获取中…")
            font.pixelSize: w.f(28); font.weight: Font.Medium; color: "#2B2B2B"
        }
        Text {
            visible: !!w.wx
            text: w.wx ? ("↑ " + w.t(w.wx.hi) + "°   ↓ " + w.t(w.wx.lo) + "°   湿度 " + w.wx.humidity + "%") : ""
            font.pixelSize: w.f(20); color: "#7C786F"
        }
        Text {
            width: w.width * 0.55
            text: w.wx ? w.wx.advice : (w.err !== "" ? w.err + "，点这里重试" : "")
            font.pixelSize: w.f(20); color: "#7C786F"; elide: Text.ElideRight
        }
    }

    // ── 右侧插画 + 天气图标 ──
    Item {
        anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
        width: parent.width * 0.42
        clip: true
        Image {
            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
            height: width * 0.375          // 与插画 400x150 的比例一致, 不裁不变形
            source: w.dir + "scene.svg"
            fillMode: Image.Stretch
            sourceSize.width: 600
        }
        Image {
            anchors.right: parent.right; anchors.rightMargin: w.u(28)
            anchors.top: parent.top; anchors.topMargin: w.u(24)
            width: w.u(96); height: width
            sourceSize.width: 200; sourceSize.height: 200
            source: w.wx ? (w.dir + W.codeIcon(w.wx.code, w.wx.day) + ".svg") : (w.dir + "w-sun.svg")
            fillMode: Image.PreserveAspectFit
        }
    }

    MouseArea {
        anchors.fill: parent
        onClicked: { if (!w.wx && w.cfg) w.refresh(); else space.openApp(app.id) }
    }
}
