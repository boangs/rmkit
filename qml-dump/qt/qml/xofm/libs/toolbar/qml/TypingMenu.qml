import QtQuick
import QtQuick.Layouts

import xofm.libs.onboarding
import xofm.libs.toolbar

import ark.controls as ArkControls
import ark.tokens as ArkTokens

ToolbarTool {
    id: root
    objectName: "typingMenu"
    type: ToolbarTool.Type.ToolbarButton

    // Input properties
    property real textWidth: toolbar.textWidth
    property int columnTextWidth: toolbar.columnTextWidth
    property int documentLength: toolbar.documentLength
    property bool typingModeEnabled: toolbar.typingModeEnabled
    property TextWidthModel textWidthModel: toolbar.textWidthModel
    readonly property bool autoReflowActive: textWidthModel.isAutoLayout(columnTextWidth)
    readonly property bool autoReflowEnabled: toolbar.autoReflowEnabled

    property Item currentlyActive: null

    // Signals
    signal typingModeSelected
    signal textWidthSelected(real width)
    signal textColumnWidthSelected(int columnWidth)
    signal enableAutoReflow
    signal disableAutoReflow

    label: qsTr("Typing")
    iconSource: "qrc:/ark/icons/typing"
    visible: toolbar.typingModeVisible
    shown: toolbar.typingModeVisible
    hasMinimumFoldoutWidth: type === ToolbarTool.Type.FoldoutButton

    // Reimplemented state from ToolbarTool

    // The actual foldout submenu
    foldoutContent: ColumnLayout {
        id: content
        spacing: 0

        ArkControls.FoldoutItem {
            antialiasing: root.antialiasing
            focusPolicy: Qt.NoFocus
            label: root.documentLength > 0 ? qsTr("Edit text") : qsTr("Add text")
            iconSource: "qrc:/ark/icons/keyboard"
            visible: !root.typingModeEnabled

            Layout.fillWidth: true

            onClicked: root.typingModeSelected()
        }
        ArkControls.FoldoutDivider {
            visible: !root.typingModeEnabled
            Layout.fillWidth: true
        }
        ArkControls.FoldoutItem {
            antialiasing: root.antialiasing
            visible: root.autoReflowEnabled
            focusPolicy: Qt.NoFocus
            label: qsTr("Automatic reflow")
            Layout.fillWidth: true
            ArkControls.Toggle {
                id: autoReflowToggle
                anchors.rightMargin: root.item ? root.item.leftPadding : parent.leftPadding
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: textWidthModel.isAutoLayout(root.columnTextWidth)
                enabled: !root.toolbar.hasPageAnnotations
                onClicked: {
                    if (checked) {
                        root.enableAutoReflow();
                    } else {
                        root.disableAutoReflow();
                    }
                }
            }
        }
        ArkControls.FoldoutDivider {
            Layout.fillWidth: true
            visible: root.autoReflowEnabled
        }
        ArkControls.FoldoutSectionHeader {
            label: qsTranslate("xofm::libs::toolbar::TextWidthModel", textWidthModel.nameForWidth(root.currentlyActive ? root.currentlyActive.layout : root.columnTextWidth))
            antialiasing: root.antialiasing
            Layout.fillWidth: true
        }

        ArkControls.FoldoutGrid {
            columns: textWidthModel.entriesCount
            Layout.fillWidth: true

            Repeater {
                model: textWidthModel
                delegate: ArkControls.FoldoutItem {
                    id: columnOption
                    required property int layout
                    required property real textWidth
                    required property string iconUrl
                    readonly property bool active: (root.autoReflowActive && root.textWidth === textWidth) || selected
                    iconSource: iconUrl
                    selected: {
                        if (root.autoReflowEnabled) {
                            return !root.autoReflowActive && (root.columnTextWidth === layout || root.currentlyActive === columnOption);
                        }
                        return root.textWidth === textWidth;
                    }

                    onActiveChanged: {
                        if (active) {
                            root.currentlyActive = columnOption;
                        }
                    }
                    antialiasing: root.antialiasing
                    focusPolicy: Qt.NoFocus
                    onPressed: root.textColumnWidthSelected(layout)
                    visible: !textWidthModel.isAutoLayout(layout)
                    enabled: !textWidthModel.isAutoLayout(layout) || !root.toolbar.hasPageAnnotations

                    Rectangle {
                        width: parent.width
                        height: 4
                        color: "black"
                        anchors.bottom: parent.bottom
                        visible: columnOption.active
                    }
                }
            }
        }
    }

    toolTip: ToolTip {
        id: typingToolTip
        type: ArkTokens.Tooltip.secondary
        //: Recommended character limit for translation: 20
        caption: qsTr("Typed text")
        positionHint: root.toolbar.tooltipPositionHint
        parent: root.toolbar.tooltipOverlay
        container: root.toolbar.tooltipContainer
        pointTo: root.mapToItem(root.toolbar.tooltipOverlay, root.foldout.x, root.foldout.y, root.foldout.width, root.foldout.height)
        OnboardingStateProp.key: "Tools_Typing"
    }

    onPressed: root.select(root)
    onTypingModeSelected: root.toolbar.typingModeSelected()
    onTextWidthSelected: (width) => { root.toolbar.textWidthSelected(width); }
    onTextColumnWidthSelected: (columnWidth) => { root.toolbar.textColumnWidthSelected(columnWidth); }
    onEnableAutoReflow: root.toolbar.enableAutoReflow()
    onDisableAutoReflow: (columnWidth) => { root.toolbar.disableAutoReflow(root.currentlyActive.layout); }
}
