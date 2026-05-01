import QtQuick
import ark.controls as ArkControls

Row {
    id: root
    spacing: 0

    property alias text: button.text
    property alias iconSource: button.iconSource
    property alias selected: button.selected
    property alias focusPolicy: button.focusPolicy

    // Set this if you need to override the visibility of the divider
    property bool dividerVisible: visible

    signal clicked()

    ArkControls.ContextualMenu.Button {
        id: button
        visible: parent.visible
        focusPolicy: Qt.NoFocus
        onClicked: parent.clicked()
    }

    ArkControls.ContextualMenu.Divider {
        id: divider
        visible: parent.dividerVisible
    }
}
