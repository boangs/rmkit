// STile — 应用磁贴 (图标 + 名字), 首页"我的应用"用小号, "应用"页用中号
import QtQuick
import QtQuick.Layouts

Rectangle {
    id: tile
    property url iconSource
    property string label: ""
    property bool dimmed: false
    property int iconSize: 48
    property int labelSize: 22
    signal clicked()

    color: mouse.pressed ? "#eeeeee" : "white"
    border.color: "#d0d0d0"
    border.width: 1
    radius: 10
    opacity: dimmed ? 0.4 : 1

    ColumnLayout {
        anchors.centerIn: parent
        spacing: 10
        Image {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: tile.iconSize
            Layout.preferredHeight: tile.iconSize
            source: tile.iconSource
            fillMode: Image.PreserveAspectFit
            sourceSize.width: tile.iconSize
            sourceSize.height: tile.iconSize
        }
        Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.maximumWidth: tile.width - 16
            text: tile.label
            font.pixelSize: tile.labelSize
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
        }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        onClicked: tile.clicked()
    }
}
