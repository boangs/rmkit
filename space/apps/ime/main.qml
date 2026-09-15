// 输入法 — 「空间」内置设置项: 拼音 / 五笔方案切换 (直连 ime-server)
import QtQuick
import QtQuick.Layouts
import device.ui.controls

Item {
    id: root
    property var space          // 外壳注入的 API 对象 (见 space/README.md)
    anchors.fill: parent

    property var _rmhImeSchemas: []
    property string _rmhImeSchema: ""
    property string _rmhImeStatus: ""

    Component.onCompleted: imeLoadSchema()

    ColumnLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 24

        RowLayout {
            Layout.fillWidth: true
            Text {
                text: "\u8f93\u5165\u65b9\u6848"
                font.pixelSize: 32
                font.weight: Font.Medium
            }
            Item { Layout.fillWidth: true }
            IconButton {
                iconSource: "qrc:/ark/icons/restore"
                title: "\u5237\u65b0"
                onClicked: root.imeLoadSchema()
            }
        }

        Text {
            visible: root._rmhImeStatus !== ""
            text: root._rmhImeStatus
            font.pixelSize: 24
            Layout.fillWidth: true
        }

        Repeater {
            model: root._rmhImeSchemas
            delegate: Item {
                id: _rmhImeRow
                required property var modelData
                Layout.fillWidth: true
                Layout.preferredHeight: 96
                readonly property bool rowApplied:
                    root._rmhImeSchema === modelData.id

                Rectangle {
                    anchors.fill: parent
                    radius: 6
                    color: _rmhImeRow.rowApplied ? "#eeeeee" : "transparent"
                    border.color: _rmhImeRow.rowApplied ? "#333333" : "#e0e0e0"
                    border.width: 1
                }
                RowLayout {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 24
                    anchors.rightMargin: 24
                    spacing: 16
                    Text {
                        Layout.fillWidth: true
                        text: _rmhImeRow.modelData.name + "  (" + _rmhImeRow.modelData.id + ")"
                        font.pixelSize: 26
                        font.weight: _rmhImeRow.rowApplied ? Font.Medium : Font.Normal
                        elide: Text.ElideMiddle
                    }
                    Text {
                        visible: _rmhImeRow.rowApplied
                        text: "\u5f53\u524d\u751f\u6548"
                        font.pixelSize: 22
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: root.imeSelectSchema(_rmhImeRow.modelData.id)
                }
            }
        }

        Text {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            font.pixelSize: 22
            color: "#555555"
            text: "\u70b9\u9009\u5373\u5207\u6362\uff0c\u7acb\u5373\u751f\u6548\uff0c\u91cd\u542f\u540e\u4fdd\u6301\u3002\u4e94\u7b14\u4e3a\u767d\u971c 86 \u7248\u7801\u8868\uff1b\u4e94\u7b14\u4e0b\u8f93\u5165 z \u53ef\u4e34\u65f6\u62fc\u97f3\u53cd\u67e5\u3002"
        }
    }

    function imeLoadSchema() {
        var x = new XMLHttpRequest()
        x.onreadystatechange = function() {
            if (x.readyState !== XMLHttpRequest.DONE) return
            if (x.status !== 200) {
                root._rmhImeStatus = "\u8f93\u5165\u6cd5\u670d\u52a1\u672a\u54cd\u5e94"
                return
            }
            try {
                var r = JSON.parse(x.responseText)
                root._rmhImeSchemas = r.available || []
                root._rmhImeSchema = r.schema || ""
                root._rmhImeStatus = ""
            } catch (e) {
                root._rmhImeStatus = "\u89e3\u6790\u5931\u8d25"
            }
        }
        x.open("GET", "http://127.0.0.1:19876/rime/schema")
        x.send()
    }
    function imeSelectSchema(id) {
        if (!id || id === root._rmhImeSchema) return
        root._rmhImeStatus = "\u5207\u6362\u4e2d..."
        var x = new XMLHttpRequest()
        x.onreadystatechange = function() {
            if (x.readyState !== XMLHttpRequest.DONE) return
            var ok = false
            try { ok = x.status === 200 && JSON.parse(x.responseText).ok === true } catch (e) {}
            root._rmhImeStatus = ok ? "" : "\u5207\u6362\u5931\u8d25"
            root.imeLoadSchema()
        }
        x.open("GET", "http://127.0.0.1:19876/rime/schema?id=" + encodeURIComponent(id))
        x.send()
    }
    }
