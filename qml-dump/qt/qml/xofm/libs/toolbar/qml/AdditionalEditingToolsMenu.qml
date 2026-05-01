import QtQuick
import QtQuick.Layouts

import xofm.libs.onboarding
import xofm.libs.toolbar

import ark.controls as ArkControls
import ark.tokens as ArkTokens

ToolbarTool {
    id: root
    objectName: "additionalEditingToolsMenu"

    type: ToolbarTool.Type.FoldoutButton

    label: qsTr("More tools")
    iconSource: "qrc:/ark/icons/plus"
    foldoutBottomDivider: true

    shown: root.toolbar.showExtraEditingTools

    onPressed: root.select(root)

    component ToolLoader: Loader {
            property var toolType: model.tool
            property url sourceUrl: model.component
            visible: item?.shown ?? false
            Layout.fillWidth: true
            asynchronous: !root.toolbar.visible
            onSourceUrlChanged: {
                if (sourceUrl === "") {
                    return;
                }
                const requiredProperties = { toolbar : root.toolbar, type : ToolbarTool.Type.FoldoutButton };
                setSource(sourceUrl, requiredProperties);
            }

            onLoaded: {
                    item.selected = Qt.binding(() => { return visible && root.activeTool === item && root.activeTool.hasFoldout});
                    item.foldoutPosition = Qt.binding(() => { return root.foldout.position === ToolbarFoldout.Position.Right
                                                          ? ToolbarFoldout.Position.Right
                                                          : ToolbarFoldout.Position.Left });
            }

            Connections {
                target: item

                function onSelect(tool) {
                    root.select(tool);
                }
            }
    }

    foldoutContent: ColumnLayout {
        spacing: 0
        Repeater {
            model: ToolbarProxyModel {
                sourceModel: root.toolbar.toolbarProvider.tools
                filter: ToolbarModel.ToolGroup.ExtraEditing
            }
            delegate: ToolLoader {
                id: toolLoader
            }
        }

        ArkControls.FoldoutDivider {
            Layout.fillWidth: true
        }

        Repeater {
            model: ToolbarProxyModel {
                sourceModel: root.toolbar.toolbarProvider.tools
                filter: ToolbarModel.ToolGroup.Toggle
            }
            delegate: ToolLoader {
                id: toggleToolLoader
            }
        }
    }
}
