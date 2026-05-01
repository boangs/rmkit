import QtQuick

import com.remarkable
import common

import ark.controls as ArkControls
import QtQuick.Layouts
import xofm.modules.virtualkeyboard
import xofm.libs.epaper as Epaper
import xofm.libs.models

Rectangle {
    id: root

    // Input
    required property SceneController sceneController
    required property var selectedParagraphStyle
    required property var formattingOptions

    // Output
    readonly property int buttonSize: 80

    // Internal
    readonly property int topMargin: 8
    readonly property int leftMargin: 20

    property bool canUndo: !!sceneController?.undoAvailable
    property bool canRedo: !!sceneController?.redoAvailable

    height: buttonSize + topMargin
    color: "black"

    KeyboardButton {
        id: undoButton
        anchors {
            left: parent.left
            leftMargin: root.leftMargin
            bottom: parent.bottom
        }
        width: root.buttonSize
        enabled: root.canUndo
        iconSource: root.canUndo ? "qrc:/ark/icons/undo" : "qrc:/ark/icons/undo_disabled"
        onClicked: root.sceneController.undo()
    }

    KeyboardButton {
        id: redoButton
        anchors {
            left: undoButton.right
            bottom: parent.bottom
        }
        width: root.buttonSize
        enabled: root.canRedo
        iconSource: root.canRedo ? "qrc:/ark/icons/redo" : "qrc:/ark/icons/redo_disabled"
        onClicked: root.sceneController.redo()
    }

    Item {
        width: root.width
        height: root.buttonSize

        anchors {
            left: redoButton.right
            right: closeButton.left
            bottom: parent.bottom
        }

        Row {
            id: menuRow

            anchors.centerIn: parent
            spacing: 0

            Repeater {
                model: ArrayModel {
                    array: root.formattingOptions
                    roles: ["iconSource", "style"]
                    identity: ["iconSource"]
                }
                FormatMenuButton {
                    inverted: true
                    buttonSize: root.buttonSize
                    selectedStyle: root.selectedParagraphStyle
                    onClicked: (style) => {
                        root.sceneController.cycleParagraphStyle(style);
                    }
                }
            }
        }
    }

    KeyboardButton {
        id: closeButton
        // Delay allows the pressed state to complete
        // which helps with ghosting
        activationDelay: 50
        anchors {
            right: parent.right
            rightMargin: 20
            bottom: parent.bottom
        }
        text: qsTr("Close")
        onActivated: Qt.inputMethod.hide()
    }

    Epaper.ScreenModeItem {
        id: screenMode
        anchors.fill: parent
        mode: Epaper.ScreenModeItem.Animation
        objectName: "vkb-format-menu"
    }
}
