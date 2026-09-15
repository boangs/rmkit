// 扫码上传 — 「空间」内置设置项 (从旧高级面板迁出)
import QtQuick
import QtQuick.Layouts
import device.ui.controls

Item {
    id: root
    property var space          // 外壳注入的 API 对象 (见 space/README.md)
    anchors.fill: parent

    Component.onCompleted: refreshQr()

    ColumnLayout {
        anchors.fill: parent
        spacing: 24

        RowLayout {
            Layout.fillWidth: true
            Text {
                text: "\u624b\u673a\u626b\u7801\u4e0a\u4f20\u6587\u6863\u3001\u5b57\u4f53\u3001\u58c1\u7eb8\uff08\u9700\u4e0e\u624b\u673a\u540c Wi-Fi\uff09"
                font.pixelSize: 24
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
            IconButton {
                iconSource: "qrc:/ark/icons/restore"
                title: "\u5237\u65b0"
                onClicked: root.refreshQr()
            }
        }

        Image {
            id: _rmhQrImage
            Layout.preferredWidth: 360
            Layout.preferredHeight: 360
            Layout.alignment: Qt.AlignHCenter
            cache: false
            fillMode: Image.PreserveAspectFit
            visible: false
        }
        Text {
            id: _rmhQrUrl
            Layout.alignment: Qt.AlignHCenter
            font.pixelSize: 22
            color: "#444444"
            visible: _rmhQrImage.visible
        }
        Text {
            id: _rmhQrEmpty
            Layout.alignment: Qt.AlignHCenter
            text: "\u8bf7\u5148\u8fde\u63a5 Wi-Fi"
            font.pixelSize: 22
            color: "#c62828"
            visible: !_rmhQrImage.visible
        }
        Item { Layout.fillHeight: true }

    }

    function refreshQr() {
        var x = new XMLHttpRequest()
        x.onreadystatechange = function() {
            if (x.readyState !== 4) return
            if (x.status === 200) {
                try {
                    var info = JSON.parse(x.responseText)
                    if (info.available) {
                        _rmhQrUrl.text = info.url
                        _rmhQrImage.source = root.space.baseUrl + "/qr.png?t=" + Date.now()
                        _rmhQrImage.visible = true
                        return
                    }
                } catch (e) {}
            }
            _rmhQrImage.visible = false
        }
        x.open("GET", root.space.baseUrl + "/qr-info")
        x.send()
    }
    }
