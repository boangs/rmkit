import QtQuick
import ark.controls as ArkControls

ArkControls.ContextualMenu {
    id: root

    // The area of the screen available for the menu to be placed in
    property rect availableRect

    // The selection our menu should be positioned relative to
    property rect selectionRect

    // The page bounds, used to avoid placing menu outside page in desktop mode
    property rect pageBounds

    // if true, menu will try to position itself above the selection if possible, falling back to below
    property bool preferAbove: false
    readonly property bool isDevice: Values.isDevice
    readonly property real devicePixelRatio: Math.max(1, Math.min(2, Screen.devicePixelRatio))

    // Gap between menu and screen edge or selection
    property real gap: Values.iconSizeMedium * (isDevice ? 1 : devicePixelRatio + 0.1)

    // Prevent flashing by keeping the menu invisible until positioned
    property bool positioned: false

    signal menuRendered()

    scale: root.isDevice ? 1 : root.devicePixelRatio
    uniformSize: false

    // Opacity is used to ensure the menu is hidden until the position has been computed fully
    // a custom opacity can be set using menuOpacity
    property real menuOpacity: 1
    opacity: root.visible && root.positioned ? Math.min(1, root.menuOpacity) : 0

    // If any of these properties change, a menu reposition is scheduled
    readonly property var positionDeps: [
        height,
        availableRect,
        selectionRect,
        pageBounds,
        scale,
        gap, preferAbove,
        isDevice, devicePixelRatio
    ]
    onPositionDepsChanged: Qt.callLater(performPositionUpdate)

    function performPositionUpdate() {
        // Height of the menu is used throughout the position calculation, so wait until it is valid
        if (root.visible && root.height > 10) {
            const pos = computeMenuPosition();
            root.x = pos.x;
            root.y = pos.y;
            root.positioned = true;

            Qt.callLater(menuRendered);
        }
    }

    function computeMenuPosition() {
        if (!visible) {
            return Qt.point(0, 0);
        }

        // Find scene edges with a present toolbar
        const deviceLeftEdge  = availableRect.left + gap;
        const deviceRightEdge = availableRect.right - gap;

        // Finding left/right edges.
        const halfToolWidth = Math.round(width / 2);
        const leftEdge  = isDevice ? deviceLeftEdge  : Math.round(pageBounds.x + halfToolWidth);
        const rightEdge = isDevice ? deviceRightEdge : Math.round(pageBounds.x + pageBounds.width - halfToolWidth);

        let bottom = selectionRect.y + selectionRect.height + gap + height;

        // Put above selection if beyond view or configured to prefer above
        if (preferAbove || bottom > availableRect.bottom) {
            const menuTopWhenAbove = selectionRect.y - gap - height;
            const menuBottomWhenAbove = selectionRect.y - gap;

            // Only put above if menu won't overlap with selection and stays on screen
            if (menuBottomWhenAbove <= selectionRect.y && menuTopWhenAbove >= availableRect.top) {
                bottom = selectionRect.y - gap;
            }
        }

        // Initial x, y position.
        const halfSelectionWidth = selectionRect.x + Math.round(selectionRect.width / 2);
        let xPosition = halfSelectionWidth - halfToolWidth;
        let yPosition = bottom - height;

        const toolLeftPos = xPosition;
        const toolRightPos = toolLeftPos + width;
        const toolTopPos = yPosition;
        const toolBottomPos = toolTopPos + height;

        if (isDevice) {
            const viewportRightEdge = availableRect.x + availableRect.width - gap;
            const viewportLeftEdge = availableRect.x + gap;

            // Calculate position based on the viewport edges.
            if (toolLeftPos < viewportLeftEdge) {
                xPosition = viewportLeftEdge;
            } else if (toolRightPos > viewportRightEdge) {
                xPosition = viewportRightEdge - width;
            }

            // Top needs to be identified after left/right pos, in case moved out of top view.
            const topEdge = availableRect.y + gap;
            const bottomEdge = availableRect.y + availableRect.height;
            if (toolTopPos < topEdge) {
                yPosition = topEdge;
            } else if (toolBottomPos > bottomEdge) {
                yPosition = bottomEdge - height;
            }
        } else {
            // Calculate position based on the page width.
            if (toolLeftPos < leftEdge) {
                xPosition = leftEdge;
            } else if (toolRightPos > rightEdge) {
                xPosition = rightEdge - width;
            }
        }

        // When a selection is close to full screen, the tools menu has no place to go
        // and can in some cases it will be placed in the top but off screen.
        // To avoid that, we clamp it to a fixed position at the top of the screen with some margin.
        const topMargin = gap / 2;
        yPosition = yPosition < topMargin ? topMargin : yPosition;

        return Qt.point(xPosition, yPosition);
    }

    Component.onCompleted: {
        Qt.callLater(menuRendered);
    }

    onVisibleChanged: {
        root.positioned = false;
        Qt.callLater(performPositionUpdate);
    }
}
