import QtQuick

import com.remarkable
import common
import xofm.libs.peninput

import device.global

Item {
    id: handleManager

    required property PenInput penInput
    required property SceneView sceneView
    required property SceneController sceneController
    required property SceneTileManager tileManager

    property bool handlesVisible: false // setting visible directly would break the mouse areas
    property bool hasSelection
    property real sceneScale

    readonly property bool dragging: endHandle.dragging || startHandle.dragging
    property point dragPosition

    // This property blocks cursor tracking so that we dont force the
    // bottom of the selection into view when you interact with a handle
    // It is unlocked whenever a key is pressed
    property bool blockCursorTracking: false

    signal selectionUpdatedByHandle // emitted when the user moves a selection handle

    onDraggingChanged: {
        if (dragging) {
            blockCursorTracking = true;
        }
    }

    function updateHandlePositions() {
        startHandle.updatePosition();
        endHandle.updatePosition();
    }

    Connections {
        target: sceneView
        function onSceneKeyActionReceived(action) {
            blockCursorTracking = false;
        }
    }

    Connections {
        target: tileManager
        function onTransformChanged() {
            updateHandlePositions();
        }
    }

    Connections {
        target: sceneController
        function onTextCursorPositionChanged() {
            if (!dragging) {
                updateHandlePositions();
            }
        }
        function onTextCursorAnchorPositionChanged() {
            if (!dragging) {
                updateHandlePositions();
            }
        }
    }

    TextSelectionHandle {
        id: startHandle
        property int endIndex // Store cursor index while dragging
        property bool selectionOnDrag: hasSelection // MoveAnchor temporarily disables hasSelection so store while dragging
        objectName: "startSelectionHandle"
        theme: selectionHandleTheme
        visible: selectionOnDrag || dragging
        sceneScale: handleManager.sceneScale
        handleEdge: cursorAfterAnchor() ? Qt.LeftEdge : Qt.RightEdge
        lineHeight: sceneController ? sceneController.textAnchorLineHeight : 0
        targetPosition: sceneController ? sceneController.textCursorAnchorPosition : Qt.point(0, 0)
        onDraggingChanged: {
            if (dragging) {
                selectionOnDrag = hasSelection;
                endIndex = sceneController.textCursorIndex;
            } else {
                selectionOnDrag = Qt.binding(()=>{ return hasSelection; })
            }
        }
        onPosChanged: {
            if (dragging && !endHandle.dragging) { // Dont allow moving both handles at the same time
                const point = dragPoint();
                if (selectionOnDrag) {
                    sceneController.selectTextRange(tileManager.viewToScene(point), endIndex);
                } else {
                    sceneController.setCursorPosition(tileManager.viewToScene(point), SceneController.MoveAnchor);
                }
                handleManager.dragPosition = point;
                selectionUpdatedByHandle();
            }
        }
    }

    TextSelectionHandle {
        id: endHandle
        objectName: "endSelectionHandle"
        theme: selectionHandleTheme
        visible: hasSelection || dragging
        sceneScale: handleManager.sceneScale
        handleEdge: cursorAfterAnchor() ? Qt.RightEdge : Qt.LeftEdge
        lineHeight: sceneController ? sceneController.textLineHeight : 0
        targetPosition: sceneController ? sceneController.textCursorPosition : Qt.point(0, 0)
        onPosChanged: {
            if (dragging && !startHandle.dragging) { // Dont allow moving both handles at the same time
                const point = dragPoint();
                sceneController.setCursorPosition(tileManager.viewToScene(point), SceneController.KeepAnchor);
                handleManager.dragPosition = point;
                selectionUpdatedByHandle();
            }
        }
    }

    Component {
        id: selectionHandleTheme
        // Component used to render text selection handles
        Rectangle {
            color: Values.colorBlack
            width: 4
            y: - lineHeight * 0.27 * sceneScale
            height: parent.height - 4

            // The PenInputBlockers are to increase the size of
            // the pen draggable area

            PenInputBlocker {
                // selectionDragMargin
                anchors.fill: parent
                anchors.margins: -5
                manager: handleManager.penInput.surfaceManager
            }

            Rectangle {
                id: handle
                radius: width / 2
                color: parent.color
                width: hgrabMargin * 0.35
                height: hgrabMargin * 0.35
                antialiasing: false
                anchors.horizontalCenter: parent.horizontalCenter
                y: (handleEdge === Qt.LeftEdge ? - height : parent.height)

                PenInputBlocker {
                    // handleDragMargin
                    anchors.fill: parent
                    anchors.margins: -10
                    manager: handleManager.penInput.surfaceManager
                }
            }
        }
    }
}
