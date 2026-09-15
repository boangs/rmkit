// SButton — 墨水屏风格按钮: 主按钮实心黑, 次按钮描边
import QtQuick

Rectangle {
    id: btn
    property string text: ""
    property bool primary: false
    property real ui: 1            // 字号/尺寸缩放 (外壳传 space.fontScale)
    signal clicked()

    implicitWidth: Math.max(Math.round(160 * ui), label.implicitWidth + Math.round(48 * ui))
    implicitHeight: Math.round(64 * ui)
    radius: 8
    color: !btn.enabled ? "#eeeeee"
         : btn.primary ? (mouse.pressed ? "#444444" : "#222222")
         : (mouse.pressed ? "#eeeeee" : "transparent")
    border.color: btn.primary ? "transparent" : "#333333"
    border.width: btn.primary ? 0 : 1

    Text {
        id: label
        anchors.centerIn: parent
        text: btn.text
        font.pixelSize: Math.round(24 * btn.ui)
        color: !btn.enabled ? "#888888" : (btn.primary ? "#ffffff" : "#111111")
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        enabled: btn.enabled
        onClicked: btn.clicked()
    }
}
