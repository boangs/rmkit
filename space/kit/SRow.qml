// SRow — 设置风格的列表行: 图标 + 文字 + 右箭头, 底部细分隔线
import QtQuick
import QtQuick.Layouts

Item {
    id: row
    property url iconSource
    property string text: ""
    property string detail: ""
    property bool showArrow: true
    property real ui: 1            // 字号/尺寸缩放 (外壳传 space.fontScale)
    signal clicked()

    implicitHeight: Math.round(96 * ui)
    Rectangle { anchors.fill: parent; color: mouse.pressed ? "#eeeeee" : "transparent" }
    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        spacing: 20
        Image {
            visible: row.iconSource.toString() !== ""
            Layout.preferredWidth: Math.round(36 * row.ui)
            Layout.preferredHeight: Math.round(36 * row.ui)
            source: row.iconSource
            fillMode: Image.PreserveAspectFit
            sourceSize.width: Math.round(36 * row.ui)
            sourceSize.height: Math.round(36 * row.ui)
        }
        Text {
            Layout.fillWidth: true
            text: row.text
            font.pixelSize: Math.round(28 * row.ui)
            elide: Text.ElideRight
        }
        Text {
            visible: row.detail !== ""
            text: row.detail
            font.pixelSize: Math.round(22 * row.ui)
            color: "#4A4842"
        }
        Image {
            visible: row.showArrow
            Layout.preferredWidth: 24
            Layout.preferredHeight: 24
            source: "file:///home/root/rmkit-cn/space/kit/icons/caret-right.svg"
            fillMode: Image.PreserveAspectFit
            sourceSize.width: 24
            sourceSize.height: 24
            opacity: 0.6
        }
    }
    Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: "#C4BFB6" }
    MouseArea { id: mouse; anchors.fill: parent; onClicked: row.clicked() }
}
