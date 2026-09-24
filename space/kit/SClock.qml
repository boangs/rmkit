// SClock — 首页时钟小组件 (外壳自带, 不依赖网络)
import QtQuick

Rectangle {
    id: clock
    property date now: new Date()
    border.color: "#B4AFA6"
    border.width: 1
    radius: 8
    color: "transparent"

    Timer {
        interval: 1000
        running: clock.visible
        repeat: true
        onTriggered: clock.now = new Date()
    }
    Column {
        anchors.centerIn: parent
        spacing: 6
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatTime(clock.now, "HH:mm")
            font.pixelSize: 96
            font.weight: Font.Light
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: clock.now.toLocaleDateString(Qt.locale("zh_CN"), "yyyy年M月d日 dddd")
            font.pixelSize: 26
            color: "#262626"
        }
    }
}
