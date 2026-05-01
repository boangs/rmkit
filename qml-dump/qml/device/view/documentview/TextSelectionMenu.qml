import QtQuick

import com.remarkable
import common
import device.ui.controls

import ark.controls as ArkControls
import ark.tokens as ArkTokens

/*
    The text selection menu is shown when tapping the 'CursorTouchArea', and positions
    above or below the cursor depending on its position in the view.

    Provides options for text selection and cut/copy/paste.
*/

Loader {
    id: root

    property rect availableSceneRect: Qt.rect(0, 0, width, height)

    /*!
     * Opens the text selection menu right away, without delay, regardless of
     * whether there is a selection or not.
     *
     * This is used to show non-selection stuff, like the 'select all' buttons
       and the likes.
     */
    function openNow() {
        openLaterTimer.stop();
        sourceComponent = menuComponent;
        openRightAwayWithSelection = false;
    }

    /*!
     * Schedules the menu to open as soon as there is a selection available.
     */
    function openWhenHasSelection() {
        openRightAwayWithSelection = true;
        openLater();
    }

    /*!
     * Schedules the menu to open in the near future, say 1 second, from now.
     *
     * In addition, if this is called shortly after a call to
     * openWhenHasSelection() and there is a selection now, it will show
     * right away.
     */
    function openLater() {
        if (openRightAwayWithSelection && controller && controller.hasSelection) {
            openNow();
        } else {
            openLaterTimer.start();
        }
    }

    /*!
     * Closes the menu and resets all internal states.
     */
    function close() {
        openLaterTimer.stop();
        sourceComponent = undefined;
        openRightAwayWithSelection = false;
    }

    // Internal stuff
    property bool openRightAwayWithSelection: false

    signal requestKeyboard()

    Component {
        id: menuComponent

        SelectionContextualMenu {
            availableRect: root.availableSceneRect
            selectionRect: {
                tileManager.sceneToViewTransform;

                // Selection rect is either the selected text bounds, or a 1px wide box at the cursor position
                if (controller.hasSelection) {
                    return MathUtils.sceneToViewAligned(tileManager, controller.textSelectionBounds);
                }

                const pos = controller.textCursorPosition;
                // NOTE: If the rootDocument is empty the default textLineHeight is 'Title'.
                return MathUtils.sceneToViewAligned(tileManager, Qt.rect(pos.x, pos.y - controller.textLineHeight, 1, controller.fontPixelSize));
            }
            preferAbove: true

            MenuButtonWithDivider {
                id: selectButton
                text: qsTr("Select")
                visible: !controller.hasSelection
                onClicked: controller.selectText(SceneParticipant.SelectWord)
            }

            MenuButtonWithDivider {
                id: selectAllButton
                text: qsTr("Select all")
                visible: !controller.hasSelection
                onClicked: controller.selectText(SceneParticipant.SelectAll)
            }

            MenuButtonWithDivider {
                id: cutButton
                iconSource: "qrc:/ark/icons/cut"
                visible: controller.hasSelection
                onClicked: {
                    controller.cutSelectedText();
                    controller.clearSelectedText();
                }
            }

            MenuButtonWithDivider {
                id: copyButton
                iconSource: "qrc:/ark/icons/copy"
                visible: controller.hasSelection
                onClicked: {
                    controller.copySelectedText();
                    controller.clearSelectedText();
                }
            }

            MenuButtonWithDivider {
                id: pasteButton
                iconSource: "qrc:/ark/icons/paste"
                visible: Clipboard.hasText
                onClicked: {
                    controller.pasteText(Clipboard.text);
                    controller.clearSelectedText();
                    root.close();
                }
            }

            MenuButtonWithDivider {
                id: boldButton
                iconSource: "qrc:/ark/icons/bold"
                selected: TextFormattingUtils.checkTextStyle(controller, TextFormatting.TextStyle.Bold)
                onClicked: controller.setTextStyle(TextFormatting.TextStyle.Bold)
            }

            MenuButtonWithDivider {
                id: italicButton
                iconSource: "qrc:/ark/icons/italic"
                selected: TextFormattingUtils.checkTextStyle(controller, TextFormatting.TextStyle.Italic)
                dividerVisible: !Qt.inputMethod.visible && !KeyboardInfo.keyboardConnected
                onClicked: controller.setTextStyle(TextFormatting.TextStyle.Italic)
            }

            MenuButtonWithDivider {
                id: showKeyboard
                text: qsTr("Edit")
                visible: !Qt.inputMethod.visible && !KeyboardInfo.keyboardConnected
                dividerVisible: false // End of the list, no divider necessary
                onClicked: root.requestKeyboard()
            }
        }
    }

    Timer {
        id: openLaterTimer
        interval: 1000
        running: false
        repeat: false
        onTriggered: root.openNow()
    }
}
