// 蓝牙 — 「空间」内置应用: 耳机扫描 / 配对 / 连接 (后端 upload-server /bt/*)
import QtQuick
import QtQuick.Layouts
import device.ui.controls

Item {
    id: root
    property var space          // 外壳注入的 API 对象 (见 space/README.md)
    anchors.fill: parent

    property var _rmhBtDevices: []
    property string _rmhBtStatus: ""
    property bool _rmhBtBusy: false

    Component.onCompleted: btLoad()

    function btRequest(method, path, body, cb) {
        var x = new XMLHttpRequest()
        x.onreadystatechange = function() {
            if (x.readyState !== 4) return
            var r = null
            try { r = JSON.parse(x.responseText) } catch (e) { r = null }
            cb(x.status, r)
        }
        x.open(method, root.space.baseUrl + path)
        x.setRequestHeader("Content-Type", "application/json")
        x.send(body ? JSON.stringify(body) : null)
    }
    function btLoad() {
        btRequest("GET", "/bt/status", null, function(st, r) {
            if (st !== 200 || !r) { root._rmhBtStatus = "\u540e\u7aef\u672a\u54cd\u5e94 (" + st + ")"; return }
            root._rmhBtDevices = r.devices || []
            root._rmhBtStatus = r.adapter === "powered" ? "" : (r.adapter === "absent" ? "\u84dd\u7259\u672a\u542f\u7528\uff0c\u70b9\u201c\u626b\u63cf\u201d\u4f1a\u81ea\u52a8\u5f00\u542f" : "\u84dd\u7259\u672a\u4e0a\u7535")
            if (!r.audioReady) root._rmhBtStatus += (root._rmhBtStatus ? "\uff1b" : "") + "\u672a\u5b89\u88c5\u97f3\u9891\u7ec4\u4ef6\uff0c\u53ea\u80fd\u914d\u5bf9\u4e0d\u80fd\u51fa\u58f0"
        })
    }
    function btScan() {
        root._rmhBtBusy = true
        root._rmhBtStatus = "\u626b\u63cf\u4e2d (10 \u79d2)\u2026 \u8ba9\u8033\u673a\u8fdb\u5165\u914d\u5bf9\u6a21\u5f0f"
        btRequest("POST", "/bt/scan?seconds=10", null, function(st, r) {
            root._rmhBtBusy = false
            if (st !== 200 || !r) { root._rmhBtStatus = "\u626b\u63cf\u5931\u8d25: " + (r && r.detail ? r.detail : st); return }
            root._rmhBtDevices = r.devices || []
            root._rmhBtStatus = (r.devices || []).length ? "" : "\u6ca1\u626b\u5230\u5e26\u540d\u5b57\u7684\u8bbe\u5907\uff0c\u786e\u8ba4\u8033\u673a\u5728\u914d\u5bf9\u6a21\u5f0f\u540e\u518d\u626b"
        })
    }
    function btAction(action, mac) {
        root._rmhBtBusy = true
        root._rmhBtStatus = (action === "pair" ? "\u914d\u5bf9\u4e2d\u2026" : action === "connect" ? "\u8fde\u63a5\u4e2d\u2026" : "\u5904\u7406\u4e2d\u2026")
        btRequest("POST", "/bt/" + action, { mac: mac }, function(st, r) {
            root._rmhBtBusy = false
            root._rmhBtStatus = (st === 200) ? "" : ((r && r.detail) ? r.detail : ("\u5931\u8d25 (" + st + ")"))
            root.btLoad()
        })
    }

    ColumnLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 20

        RowLayout {
            Layout.fillWidth: true
            Text { text: "\u8033\u673a"; font.pixelSize: 32; font.weight: Font.Medium }
            Item { Layout.fillWidth: true }
            Rectangle {
                Layout.preferredWidth: 200; Layout.preferredHeight: 64; radius: 8
                color: root._rmhBtBusy ? "#eeeeee" : "#222222"
                Text { anchors.centerIn: parent; color: root._rmhBtBusy ? "#888888" : "#ffffff"; font.pixelSize: 24; text: "\u626b\u63cf\u8bbe\u5907" }
                MouseArea { anchors.fill: parent; enabled: !root._rmhBtBusy; onClicked: root.btScan() }
            }
        }
        Text {
            visible: root._rmhBtStatus !== ""
            text: root._rmhBtStatus
            font.pixelSize: 22; color: "#555555"; wrapMode: Text.WordWrap; Layout.fillWidth: true
        }
        Text {
            visible: root._rmhBtDevices.length === 0
            text: "\u8fd8\u6ca1\u6709\u8bbe\u5907\u3002\u628a\u8033\u673a\u8c03\u5230\u914d\u5bf9\u6a21\u5f0f\uff0c\u70b9\u53f3\u4e0a\u89d2\u201c\u626b\u63cf\u8bbe\u5907\u201d\u3002"
            font.pixelSize: 24; color: "#555555"; wrapMode: Text.WordWrap; Layout.fillWidth: true
        }
        Repeater {
            model: root._rmhBtDevices
            delegate: Item {
                id: _rmhBtRow
                required property var modelData
                Layout.fillWidth: true
                Layout.preferredHeight: 96
                Rectangle { anchors.fill: parent; radius: 6; color: _rmhBtRow.modelData.connected ? "#eeeeee" : "transparent"; border.color: "#e0e0e0"; border.width: 1 }
                RowLayout {
                    anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 24; anchors.rightMargin: 24; spacing: 16
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 2
                        Text { text: _rmhBtRow.modelData.name; font.pixelSize: 26; elide: Text.ElideRight; Layout.fillWidth: true }
                        Text { text: _rmhBtRow.modelData.mac + (_rmhBtRow.modelData.connected ? "  \u5df2\u8fde\u63a5" : (_rmhBtRow.modelData.paired ? "  \u5df2\u914d\u5bf9" : "")); font.pixelSize: 20; color: "#777777" }
                    }
                    Rectangle {
                        Layout.preferredWidth: 150; Layout.preferredHeight: 56; radius: 6
                        color: "transparent"; border.color: "#333333"; border.width: 1
                        Text { anchors.centerIn: parent; font.pixelSize: 22; text: _rmhBtRow.modelData.connected ? "\u65ad\u5f00" : (_rmhBtRow.modelData.paired ? "\u8fde\u63a5" : "\u914d\u5bf9") }
                        MouseArea { anchors.fill: parent; enabled: !root._rmhBtBusy; onClicked: root.btAction(_rmhBtRow.modelData.connected ? "disconnect" : (_rmhBtRow.modelData.paired ? "connect" : "pair"), _rmhBtRow.modelData.mac) }
                    }
                    Rectangle {
                        visible: _rmhBtRow.modelData.paired && !_rmhBtRow.modelData.connected
                        Layout.preferredWidth: 110; Layout.preferredHeight: 56; radius: 6
                        color: "transparent"; border.color: "#bbbbbb"; border.width: 1
                        Text { anchors.centerIn: parent; font.pixelSize: 22; color: "#777777"; text: "\u5fd8\u8bb0" }
                        MouseArea { anchors.fill: parent; enabled: !root._rmhBtBusy; onClicked: root.btAction("remove", _rmhBtRow.modelData.mac) }
                    }
                }
            }
        }
    }
}
