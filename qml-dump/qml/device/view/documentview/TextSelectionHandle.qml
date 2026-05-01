import QtQuick

import com.remarkable
import common

Item {
    id: handle

    property int hGrabMargin: 40
    property int vGrabMargin: 40

    property int lineHeight
    property int handleEdge: Qt.LeftEdge
    property bool dragging: dragHandle.pressed
    property real sceneScale: tileManager.scale

    property point pos
    property point targetPosition
    property point initialOffset
    property Component theme

    signal updatePosition
    signal tapped(var mouse)

    width: 1
    height: (1.3 * lineHeight) * sceneScale

    onVisibleChanged: {
        if (visible) {
            updatePosition(); // reset on initial show
        }
        dragHandle.x = handle.x - hGrabMargin;
        dragHandle.y = handle.y - vGrabMargin;
    }

    onDraggingChanged: {
        if (!dragging) {
            updatePosition(); // snap on grab release
        }
    }

    onUpdatePosition: {
        if (!tileManager) {
            return;
        }
        setPosition(tileManager.sceneToView(targetPosition));
    }

    MouseArea {
        id: dragHandle

        parent: handle.parent
        visible: handle.visible

        width: 2 * hGrabMargin
        height: 40 * sceneScale + 2 * vGrabMargin
        x: handle.x - hGrabMargin
        y: handle.y - vGrabMargin

        // The right hand side handle should have z priority so
        // by default you grab that when overlapping
        z: handleEdge === Qt.LeftEdge ? 0 : 1
        readonly property point pos: Qt.point(x + handle.x, y + handle.y)
        onPosChanged: limitTimer.start()
        drag.target: dragHandle
        drag.threshold: 10 // Override 30 px global qpa threshold

        Timer {
            id: limitTimer
            interval: 10
            onTriggered: {
                handle.pos = dragHandle.pos;
            }
        }
    }

    Loader {
        id: themeLoader
        sourceComponent: theme
        height: parent.height

        // Forward some properties to the theme component
        property alias vGrabMargin: handle.vGrabMargin
        property alias hgrabMargin: handle.hGrabMargin
        property alias handleEdge: handle.handleEdge
        property alias lineHeight: handle.lineHeight
        property alias sceneScale: handle.sceneScale
        visible: handlesVisible
    }

    function dragPoint() {
        let currentOffset = tileManager.viewToScene(Qt.point(0, 0));
        let difference = initialOffset.y - currentOffset.y;
        return Qt.point(dragHandle.x + dragHandle.width / 2, dragHandle.y + dragHandle.height / 2);
    }

    function setPosition(point) {
        x = point.x - width / 2;
        y = point.y - height / 2;
        dragHandle.x = point.x - dragHandle.width / 2;
        dragHandle.y = point.y - dragHandle.height / 2 - vGrabMargin / 2;
    }

    function cursorAfterAnchor() {
        if (!sceneController) {
            return false;
        }
        const cPos = sceneController.textCursorPosition;
        const aPos = sceneController.textCursorAnchorPosition;
        return cPos.y > aPos.y || (cPos.y === aPos.y && cPos.x > aPos.x);
    }
}
