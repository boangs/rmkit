// SRadio — 单选项 (圆点 + 文字)
import QtQuick
import QtQuick.Layouts

Item {
    id: radio
    property string text: ""
    property bool checked: false
    signal clicked()

    implicitWidth: row.implicitWidth
    implicitHeight: 56

    RowLayout {
        id: row
        anchors.fill: parent
        spacing: 10
        Rectangle {
            Layout.preferredWidth: 28
            Layout.preferredHeight: 28
            Layout.alignment: Qt.AlignVCenter
            radius: 14
            border.width: 2
            border.color: "black"
            color: "white"
            Rectangle {
                anchors.centerIn: parent
                width: 16; height: 16
                radius: 8
                color: "black"
                visible: radio.checked
            }
        }
        Text {
            text: radio.text
            font.pixelSize: 26
            verticalAlignment: Text.AlignVCenter
            Layout.alignment: Qt.AlignVCenter
        }
    }
    MouseArea {
        anchors.fill: parent
        onClicked: radio.clicked()
    }
}
