// 个性化 — 「空间」内置设置项: 字体 + 休眠壁纸 (从旧高级面板迁出)
import QtQuick
import QtQuick.Layouts
import device.ui.controls

Item {
    id: root
    property var space          // 外壳注入的 API 对象 (见 space/README.md)
    anchors.fill: parent

    // 已生效 (从后端拉到) vs 选中 (用户在页内的临时选择)
    property string _rmhAppliedFont: ""
    property string _rmhAppliedScreen: ""
    property string _rmhSelectedFont: ""
    property string _rmhSelectedScreen: ""
    readonly property bool _rmhDirty:
        _rmhSelectedFont !== _rmhAppliedFont ||
        _rmhSelectedScreen !== _rmhAppliedScreen
    ListModel { id: _rmhFontsModel }
    ListModel { id: _rmhScreensModel }

    Component.onCompleted: { refreshFonts(); refreshScreens() }

    // 有变更时右上角出"应用" (放在外壳标题那一行的右侧)
    IconButton {
        id: _rmhApply
        visible: root._rmhDirty
        z: 2
        anchors.bottom: parent.top
        anchors.bottomMargin: Math.round(48 * root.space.unit)
        anchors.right: parent.right
        iconSource: "qrc:/ark/icons/checkmark"
        title: "\u5e94\u7528"
        onClicked: _rmhConfirmApply.visible = true
    }

    Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: _rmhPersCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: _rmhPersCol
            width: parent.width
            spacing: 24

            // ─── 字体 ────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: "\u5b57\u4f53"
                    font.pixelSize: 32
                    font.weight: Font.Medium
                }
                Item { Layout.fillWidth: true }
                IconButton {
                    iconSource: "qrc:/ark/icons/restore"
                    title: "\u5237\u65b0"
                    onClicked: root.refreshFonts()
                }
            }

            Text {
                visible: _rmhFontsModel.count === 0
                text: "\u6682\u65e0\u5b57\u4f53\uff0c\u8bf7\u5148\u626b\u7801\u4e0a\u4f20"
                font.pixelSize: 24
                Layout.fillWidth: true
            }

            Repeater {
                model: _rmhFontsModel
                delegate: Item {
                    id: _rmhFontRow
                    required property string rowName
                    Layout.fillWidth: true
                    Layout.preferredHeight: 96

                    readonly property bool rowSelected:
                        root._rmhSelectedFont === rowName
                    readonly property bool rowApplied:
                        root._rmhAppliedFont === rowName

                    Rectangle {
                        anchors.fill: parent
                        radius: 6
                        color: _rmhFontRow.rowSelected ? "#eeeeee" : "transparent"
                        border.color: _rmhFontRow.rowSelected ? "#333333" : "#e0e0e0"
                        border.width: 1
                    }

                    RowLayout {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 24
                        anchors.rightMargin: 12
                        spacing: 16

                        Text {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            text: _rmhFontRow.rowName
                            font.pixelSize: 26
                            font.weight: _rmhFontRow.rowSelected ? Font.Medium : Font.Normal
                            elide: Text.ElideMiddle
                            verticalAlignment: Text.AlignVCenter
                        }
                        Text {
                            Layout.alignment: Qt.AlignVCenter
                            visible: _rmhFontRow.rowApplied
                            text: "\u5f53\u524d\u751f\u6548"
                            font.pixelSize: 22
                            verticalAlignment: Text.AlignVCenter
                        }
                        IconButton {
                            Layout.alignment: Qt.AlignVCenter
                            iconSource: "qrc:/ark/icons/trashcan"
                            title: ""
                            onClicked: root.deleteFont(_rmhFontRow.rowName)
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        // 给 trashcan 按钮区域留点击空间 (右侧 96px)
                        anchors.rightMargin: 96
                        onClicked: root._rmhSelectedFont = _rmhFontRow.rowName
                    }
                }
            }

            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: "#e0e0e0" }

            // ─── 壁纸 ────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: "\u4f11\u7720\u58c1\u7eb8"
                    font.pixelSize: 32
                    font.weight: Font.Medium
                }
                Item { Layout.fillWidth: true }
                IconButton {
                    iconSource: "qrc:/ark/icons/restore"
                    title: "\u5237\u65b0"
                    onClicked: root.refreshScreens()
                }
            }

            Text {
                visible: _rmhScreensModel.count === 0
                text: "\u6682\u65e0\u58c1\u7eb8\uff0c\u8bf7\u5148\u626b\u7801\u4e0a\u4f20"
                font.pixelSize: 24
                Layout.fillWidth: true
            }

            Flow {
                Layout.fillWidth: true
                spacing: 20

                Repeater {
                    model: _rmhScreensModel
                    delegate: Rectangle {
                        id: _rmhScreenCell
                        required property string rowName
                        width: 240
                        height: 380
                        radius: 8
                        clip: true

                        readonly property bool rowSelected:
                            root._rmhSelectedScreen === rowName
                        readonly property bool rowApplied:
                            root._rmhAppliedScreen === rowName

                        color: _rmhScreenCell.rowSelected ? "#eeeeee" : "transparent"
                        border.color: _rmhScreenCell.rowSelected ? "#333333" : "#cccccc"
                        border.width: _rmhScreenCell.rowSelected ? 3 : 1

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 12
                            spacing: 8

                            Image {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 200
                                source: root.space.baseUrl
                                    + "/screens/" + _rmhScreenCell.rowName + "/preview"
                                cache: false
                                fillMode: Image.PreserveAspectFit
                            }

                            Text {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: _rmhScreenCell.rowName
                                font.pixelSize: 18
                                font.weight: _rmhScreenCell.rowSelected ? Font.Medium : Font.Normal
                                elide: Text.ElideMiddle
                                wrapMode: Text.NoWrap
                            }

                            Text {
                                visible: _rmhScreenCell.rowApplied
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: "\u5f53\u524d\u751f\u6548"
                                font.pixelSize: 16
                                color: "#666666"
                            }

                            Item { Layout.fillHeight: true }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                Item { Layout.fillWidth: true }
                                IconButton {
                                    iconSource: "qrc:/ark/icons/trashcan"
                                    title: ""
                                    onClicked: root.deleteScreen(_rmhScreenCell.rowName)
                                }
                            }
                        }

                        // 卡片整体点击 = 选中 (避开底部删除按钮区域)
                        MouseArea {
                            anchors.fill: parent
                            anchors.bottomMargin: 72
                            onClicked: root._rmhSelectedScreen = _rmhScreenCell.rowName
                        }
                    }
                }
            }

            Item { Layout.preferredHeight: 40 }
        }

    }

    // ─── 应用确认对话框 ─────────────────────────────────────────
    Rectangle {
        id: _rmhConfirmApply
        anchors.fill: parent
        color: "#80000000"
        visible: false
        z: 1
        MouseArea { anchors.fill: parent }

        Rectangle {
            anchors.centerIn: parent
            width: 540
            height: 280
            radius: 8
            color: "white"
            border.color: "#cccccc"

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 24
                spacing: 12

                Text {
                    text: "\u5e94\u7528\u66f4\u6539"
                    font.pixelSize: 26
                    font.weight: Font.Medium
                }
                Text {
                    visible: root._rmhSelectedFont !== root._rmhAppliedFont
                    text: "\u5b57\u4f53: " + root._rmhSelectedFont
                    font.pixelSize: 20
                    color: "#444444"
                    wrapMode: Text.WordWrap
                    elide: Text.ElideMiddle
                    Layout.fillWidth: true
                }
                Text {
                    visible: root._rmhSelectedScreen !== root._rmhAppliedScreen
                    text: "\u58c1\u7eb8: " + root._rmhSelectedScreen
                    font.pixelSize: 20
                    color: "#444444"
                    wrapMode: Text.WordWrap
                    elide: Text.ElideMiddle
                    Layout.fillWidth: true
                }
                Text {
                    text: "\u786e\u8ba4\u540e\u5c06\u91cd\u542f\u754c\u9762"
                    font.pixelSize: 22
                    Layout.fillWidth: true
                }
                Item { Layout.fillHeight: true }
                RowLayout {
                    Layout.alignment: Qt.AlignRight
                    spacing: 12
                    IconButton {
                        iconSource: "qrc:/ark/icons/chevron_left"
                        title: "\u53d6\u6d88"
                        onClicked: _rmhConfirmApply.visible = false
                    }
                    IconButton {
                        iconSource: "qrc:/ark/icons/checkmark"
                        title: "\u786e\u8ba4\u5e94\u7528"
                        onClicked: {
                            _rmhConfirmApply.visible = false
                            root.applyAll()
                        }
                    }
                }
            }
        }
    }

    function refreshFonts() {
        var x = new XMLHttpRequest()
        x.onreadystatechange = function() {
            if (x.readyState !== 4) return
            _rmhFontsModel.clear()
            if (x.status !== 200) return
            try {
                var arr = JSON.parse(x.responseText)
                var active = ""
                for (var i = 0; i < arr.length; i++) {
                    _rmhFontsModel.append({ rowName: arr[i].name })
                    if (arr[i].active) active = arr[i].name
                }
                root._rmhAppliedFont = active
                root._rmhSelectedFont = active
            } catch (e) {}
        }
        x.open("GET", root.space.baseUrl + "/fonts")
        x.send()
    }
    function refreshScreens() {
        var x = new XMLHttpRequest()
        x.onreadystatechange = function() {
            if (x.readyState !== 4) return
            _rmhScreensModel.clear()
            if (x.status !== 200) return
            try {
                var arr = JSON.parse(x.responseText)
                var active = ""
                for (var i = 0; i < arr.length; i++) {
                    _rmhScreensModel.append({ rowName: arr[i].name })
                    if (arr[i].active) active = arr[i].name
                }
                root._rmhAppliedScreen = active
                root._rmhSelectedScreen = active
            } catch (e) {}
        }
        x.open("GET", root.space.baseUrl + "/screens")
        x.send()
    }
    function deleteFont(name) {
        var x = new XMLHttpRequest()
        x.onreadystatechange = function() {
            if (x.readyState !== 4) return
            refreshFonts()
        }
        x.open("DELETE", root.space.baseUrl + "/fonts/" + encodeURIComponent(name))
        x.send()
    }
    function deleteScreen(name) {
        var x = new XMLHttpRequest()
        x.onreadystatechange = function() {
            if (x.readyState !== 4) return
            refreshScreens()
        }
        x.open("DELETE", root.space.baseUrl + "/screens/" + encodeURIComponent(name))
        x.send()
    }
    function applyAll() {
        var body = {}
        if (root._rmhSelectedFont !== root._rmhAppliedFont) {
            body.font = root._rmhSelectedFont
        }
        if (root._rmhSelectedScreen !== root._rmhAppliedScreen) {
            body.screen = root._rmhSelectedScreen
        }
        if (!body.font && !body.screen) return
        var x = new XMLHttpRequest()
        x.open("POST", root.space.baseUrl + "/apply")
        x.setRequestHeader("Content-Type", "application/json")
        x.send(JSON.stringify(body))
        // xochitl 即将重启, 先把启动台关掉避免视觉残留
        root.space.closeSpace()
    }
    }
