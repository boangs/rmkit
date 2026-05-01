import QtQuick
import com.remarkable
import common
import xofm.libs.sceneview
import xofm.libs.devicesceneview.impl

Item {
    id: textHandler

    required property ScenePenInputHandler penHandler
    property SceneTileManager tileManager
    /// current position in view coords since the transform can change independently
    property var currentTextPosition
    readonly property int gestureId: ScenePenInputHandler.TextSelectGesture
    readonly property bool active: textSelectUpdate.running && !cursorMoveDelay.pending

    signal gestureFinished();
    signal textSelectStarted(point pos);
    signal textSelectMoved(point pos);
    signal textSelectEnded(point pos);

    function startGesture(data) {
        textSelectStarted(tileManager.viewToScene(mapFromItem(null, data.pos)));
        currentTextPosition = data.pos;
        cursorMoveDelay.trigger();
        textSelectUpdate.start();
    }

    Timer {
        id: textSelectUpdate
        interval: 100
        repeat: true
        onTriggered: textSelectMoved(tileManager.viewToScene(mapFromItem(null, currentTextPosition)));
    }

    DeferredAction {
        // Don't report the gesture as being active until after the worker thread has had an opportunity
        // to update the cursor state based on the initial position.
        id: cursorMoveDelay
        worker: tileManager?.worker
    }

    Connections {
        target: penHandler

        function onGestureMoved (pos) {
            currentTextPosition = pos;
        }
        function onGestureEnded (pos) {
            textSelectUpdate.stop();
            currentTextPosition = pos;
            textSelectEnded(tileManager.viewToScene(mapFromItem(null, currentTextPosition)));
            textHandler.gestureFinished();
        }
    }
}
