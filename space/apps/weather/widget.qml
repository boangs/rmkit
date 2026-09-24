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

    // ── 插画: 整宽铺在卡片下缘 ──────────────────────────────────────
    // 素材的上缘渐隐是烤在图里的, 所以取渐隐末尾往下那一段, 顶边自然化开,
    // 与卡片白底连成一片, 不需要在屏幕上做半透明合成。
    Item {
        id: band
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
        height: Math.round(parent.height * 0.42)
        clip: true
        Image {
            id: bandImg
            readonly property bool useFallback: String(source).indexOf("/scenes/") < 0
            readonly property real sw: sourceSize.width > 0 ? sourceSize.width : 1
            readonly property real sh: sourceSize.height > 0 ? sourceSize.height : 1
            width: parent.width
            height: useFallback ? parent.height : Math.round(width * sh / sw)
            y: useFallback ? 0 : -Math.round(height * 0.325)
            fillMode: useFallback ? Image.PreserveAspectFit : Image.Stretch
            sourceSize.width: 900
            property var chain: w.wx ? W.sceneChain(w.wx, w.now) : []
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

    // ── 文字: 压在卡片上半 ──────────────────────────────────────────
    Column {
        anchors.left: parent.left; anchors.leftMargin: w.u(32)
        anchors.top: parent.top; anchors.topMargin: w.u(24)
        spacing: w.u(2)

        Text {
            text: w.now.toLocaleDateString(Qt.locale("zh_CN"), "M月d日 dddd") + "   " + Qt.formatTime(w.now, "HH:mm")
            font.pixelSize: w.f(22); color: "#1F1E1B"
        }
        Row {
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
            spacing: w.u(4)
            Text { text: w.wx ? String(w.t(w.wx.temp)) : "--"; font.pixelSize: w.f(88); font.weight: Font.Light; color: "#000000" }
            Text {
                text: W.unitSign(w.cfg ? w.cfg.unit : "c"); font.pixelSize: w.f(26); color: "#000000"
                anchors.top: parent.top; anchors.topMargin: w.f(16)
            }
        }
        Text {
            text: w.wx ? w.wx.text : (w.err !== "" ? "暂无天气数据" : "获取中…")
            font.pixelSize: w.f(30); font.weight: Font.Bold; color: "#000000"
        }
        Text {
            visible: !!w.wx
            text: w.wx ? ("↑ " + w.t(w.wx.hi) + "°   ↓ " + w.t(w.wx.lo) + "°   湿度 " + w.wx.humidity + "%") : ""
            font.pixelSize: w.f(22); color: "#000000"
        }
    }

    // 一句话建议: 贴在插画上缘那段化开的白里
    Text {
        anchors.left: parent.left; anchors.leftMargin: w.u(32)
        anchors.right: parent.right; anchors.rightMargin: w.u(32)
        anchors.bottom: band.top; anchors.bottomMargin: w.u(10)
        text: w.wx ? w.wx.advice : (w.err !== "" ? w.err + "，点这里重试" : "")
        font.pixelSize: w.f(22); color: "#000000"; elide: Text.ElideRight
    }

    // 天气图标: 卡片右上, 压在天空上
    Image {
        anchors.right: parent.right; anchors.rightMargin: w.u(36)
        anchors.top: parent.top; anchors.topMargin: w.u(28)
        width: w.u(110); height: width
        sourceSize.width: 220; sourceSize.height: 220
        source: w.wx ? (w.dir + W.codeIcon(w.wx.code, w.wx.day) + ".svg") : (w.dir + "w-sun.svg")
        fillMode: Image.PreserveAspectFit
    }

    MouseArea {
        anchors.fill: parent
        onClicked: { if (!w.wx && w.cfg) w.refresh(); else space.openApp(app.id) }
    }
}
