import QtQuick

import com.remarkable
import common

import ark.controls as ArkControls
import xofm.libs.models

MouseArea {
    id: root

    // Input
    required property var selectedParagraphStyle
    required property var formattingOptions
    required property SceneTileManager tileManager
    required property SceneController sceneController
    required property Item viewItem

    property bool expanded: false
    property real expandedHeight: expandMenu.height
    property bool textHighlighted: false

    // Output
    readonly property alias formatMenuFrame: formatMenu
    readonly property alias hideTimerRunning: hideTimer.running

    // The mousearea covers the entire screen and is used to collapse the menu
    // when clicking outside it. When we're not expanded however, we should
    // let input go through. Hence this mouse area should only be enabled
    // when we're expanded.
    enabled: expanded

    onClicked: expanded = false

    function contract() { expanded = false; }

    Timer {
        id: hideTimer
        interval: 1500
    }

    function startHideInterval() {
        hideTimer.restart();
    }

    Rectangle {
        id: formatMenu
        width: 80
        height: 80
        visible: root.visible && (x || y) // Make sure we don't show the format menu at the middle of the screen.

        readonly property bool foldDown: {
            const virtualKeyboardVisible = !KeyboardInfo.keyboardConnected && Qt.inputMethod.visible;
            const bottom = viewItem.height - (virtualKeyboardVisible ? Qt.inputMethod.keyboardRectangle.height : 0);
            return formatMenu.y < (bottom - (formatMenu.width * (formattingOptions.length + 1)));
        }

        onYChanged: expanded = false

        onVisibleChanged: {
            if (!visible) {
                expanded = false;
            }
        }

        onFoldDownChanged: {
            frame.anchors.top = undefined;
            frame.anchors.bottom = undefined;
            if (foldDown) {
                frame.anchors.top = menuIcon.bottom;
            } else {
                frame.anchors.bottom = menuIcon.top;
            }
        }

        function toggleExpand() { expanded = !expanded; }
        function show() { visible = true; }
        function hide() { visible = false; }

        function updatePosition() {
            if (!tileManager) {
                return;
            }
            const paragraphBounds = tileManager.sceneToView(sceneController.textParagraphBounds);
            const offset = root.selectedParagraphStyle && root.selectedParagraphStyle.matchesButtonStyle(ParagraphStyle.Type.Title) ? 0 : 20;
            const newY = paragraphBounds.y - offset;

            const yOutsideTopView = newY < 0;
            const paragraphOutsideTopView = paragraphBounds.y < -paragraphBounds.height;
            formatMenu.y = (yOutsideTopView && !paragraphOutsideTopView) ? 20 : newY;
            formatMenu.x = paragraphBounds.x - (width + 30);
        }

        Connections {
            target: sceneController
            function onTextParagraphBoundsChanged() {
                formatMenu.updatePosition();
            }
        }

        Connections {
            target: tileManager
            function onTransformChanged() {
                formatMenu.updatePosition();
            }
        }

        Connections {
            target: viewItem
            function onCurrentPageChanged() {
                formatMenu.updatePosition();
            }
        }

        Rectangle {
            id: menuIcon
            anchors.centerIn: parent
            width: formatMenu.width
            height: formatMenu.height
            ArkControls.Icon {
                source: "qrc:/ark/icons/formatting_menu"
                anchors.centerIn: parent
                antialiasing: false
                size: ArkControls.Values.iconSize.medium
                color: Values.colorBlack
            }
            MouseArea {
                anchors.fill: parent
                onClicked: formatMenu.toggleExpand()
            }
        }

        Rectangle {
            id: frame
            anchors.topMargin: -1
            anchors.left: formatMenu.left
            width: formatMenu.width
            height: formatMenu.height * root.formattingOptions.length
            color: "transparent"
            border.color: Values.colorBlack
            visible: expanded

            Column {
                id: expandMenu
                visible: expanded
                width: formatMenu.width
                z: frame.z - 1

                Repeater {
                    model: ArrayModel {
                        array: root.formattingOptions
                        roles: ["iconSource", "style"]
                        identity: ["iconSource"]
                    }
                    FormatMenuButton {
                        buttonSize: formatMenu.width
                        selectedStyle: root.selectedParagraphStyle
                        onClicked: (style) => {
                            root.sceneController.cycleParagraphStyle(style);
                            formatMenu.toggleExpand();
                        }
                    }
                }
            }
        }
    }
}
