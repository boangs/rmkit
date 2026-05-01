import QtQuick
import QtQuick.Layouts
import com.remarkable
import com.remarkable.devicetelemetry
import common
import device.ui.controls
import device.ui.text
import ark.tokens as ArkTokens
import ark.controls as ArkControls

import xofm.libs.settings
import xofm.libs.qtgui

DeviceKeyboardNavigationHandler {
    id: root
    objectName: "LanguageAndKeyboard"
    navigationModel: []
    firstNavigationIndex: 1

    signal close

    required property WindowNavigator windowNavigator
    required property var keyboardItems
    required property var languageSettings

    onActivated: (element) => {
        if (element) {
            element.clicked();
        }
    }

    Background {
        anchors.fill: parent
    }

    ArkControls.NavigationBar {
        id: navigationBar
        type: ArkTokens.NavigationBar.secondary
        width: parent.width

        ArkControls.NavigationBar.Button {
            id: back
            text: qsTr("Back")
            textPosition: ArkControls.Button.TextPosition.Right
            iconSource: "qrc:/ark/icons/chevron_left"
            onClicked: root.close()
            Component.onCompleted: navigationModel[0] = back
            showFocus: root.current === back
        }
    }

    ArkControls.Title {
        id: header
        type: ArkControls.Title.Large
        anchors.top: navigationBar.bottom
        anchors.left: parent.left
        anchors.leftMargin: ArkControls.Values.settings.horizontalMargin.secondLevel
        text: qsTr("Language and keyboard")
    }

    ColumnLayout {
        id: column
        anchors {
            top: header.bottom
            topMargin: ArkControls.Values.platform.spacing.x2large
            left: parent.left
            leftMargin: ArkControls.Values.settings.horizontalMargin.secondLevel
            right: parent.right
            rightMargin: ArkControls.Values.settings.horizontalMargin.secondLevel
        }

        spacing: ArkControls.Values.platform.spacing.x2large

        ArkControls.Cell {
            id: languages
            title: qsTr("Languages")
            Layout.fillWidth: true
            ArkControls.CellItem {
                id: cell1
                text: qsTr("System language")
                objectName: "SystemLanguage"
                status: root.languageSettings.getLanguageDisplayName(languageSettings.languageCode)
                onClicked: subpageLoader.sourceComponent = languageDialog
                Component.onCompleted: navigationModel[1] = cell1
                showFocus: root.current === cell1
            }
            ArkControls.CellItem {
                id: cell2
                text: qsTr("On-screen keyboard")
                status: qsTr(root.languageSettings.languageName(Settings.keyboardLanguage))
                onClicked: subpageLoader.sourceComponent = keyboardDialog
                Component.onCompleted: navigationModel[2] = cell2
                showFocus: root.current === cell2
            }
            ArkControls.CellItem {
                id: cell3
                text: qsTr("Handwriting conversion")
                status: qsTr(HandwritingLanguageModel.language(Settings.handwritingConversionLanguage))
                onClicked: subpageLoader.sourceComponent = handwritingDialog
                Component.onCompleted: navigationModel[3] = cell3
                showFocus: root.current === cell3
            }
            ArkControls.CellItem {
                id: cell4
                text: qsTr("Type Folio")
                status: qsTr(TypeFolioLanguageModel.language(Settings.inputLocale))
                visible: Settings.seabirdSetup
                onClicked: subpageLoader.sourceComponent = inputLocaleDialog
                Component.onCompleted: navigationModel[4] = cell4
                showFocus: root.current === cell4
            }
        }

        ArkControls.Cell {
            title: qsTr("Keyboard")
            Layout.fillWidth: true
            visible: Settings.seabirdSetup
            ArkControls.CellItem {
                id: cell5
                text: qsTr("Specifications and shortcuts")
                onClicked: root.windowNavigator.open("keyboardui/window/settings")
                Component.onCompleted: navigationModel[5] = cell5
                showFocus: root.current === cell5
            }
        }

        ColumnLayout {
            spacing: ArkControls.Values.spacing.large

            Repeater {
                id: repeater

                property int navOffset: Settings.seabirdSetup ? 4 : 2

                model: root.keyboardItems
                delegate: WidgetLoader {
                    id: widgetLoader
                    active: Settings.seabirdSetup
                    Layout.fillWidth: true
                    onLoaded: {
                        navigationModel[repeater.navOffset++] = widgetLoader.item;
                    }
                }
            }
        }
    }

    Loader {
        id: subpageLoader
        anchors.fill: parent
    }

    Component {
        id: handwritingDialog
        SelectionComponent {
            //: Recommended character limit for translation: 30
            title: qsTr("Handwriting conversion language")
            model: HandwritingLanguageModel.languageNames()
            display: (modelData) => {
                return qsTr(modelData);
            }
            selectedIndex: HandwritingLanguageModel.getLanguageNameIndex(HandwritingLanguageModel.language(Settings.handwritingConversionLanguage))
            onSelected: (selection) => {
                Settings.handwritingConversionLanguage = HandwritingLanguageModel.languageCode(selection);
                SystemTelemetry.hwcLanguageChanged(Settings.handwritingConversionLanguage);
                subpageLoader.sourceComponent = null;
            }
            onRejected: subpageLoader.sourceComponent = null
        }
    }

    Component {
        id: languageDialog
        SelectionComponent {
            title: qsTr("System language")
            objectName: "SystemLanguageDialog"
            model: languageSettings.availableLanguageCodes
            selectedIndex: model.indexOf(languageSettings.languageCode);
            display: (modelData) => {
                return root.languageSettings.getLanguageDisplayName(modelData);
            }
            onSelected: (selection) => {
                languageSettings.languageCode = selection;
                subpageLoader.sourceComponent = null;
            }
            onRejected: subpageLoader.sourceComponent = null
        }
    }
    Component {
        id: keyboardDialog
        SelectionComponent {
            title: qsTr("On-screen keyboard")
            model: KeyboardSettings.availableLayouts
            selectedIndex: model.indexOf(Settings.keyboardLanguage);
            display: (modelData) => {
                return qsTr(languageSettings.languageName(modelData));
            }
            onSelected: (selection) => {
                Settings.keyboardLanguage = selection;
                subpageLoader.sourceComponent = null;
            }
            onRejected: subpageLoader.sourceComponent = null
        }
    }
    Component {
        id: inputLocaleDialog
        SelectionComponent {
            title: qsTr("Type Folio language")
            model: TypeFolioLanguageModel.languageNames()
            selectedIndex: TypeFolioLanguageModel.getLanguageNameIndex(TypeFolioLanguageModel.language(Settings.inputLocale))
            onSelected: (selection) => {
                Settings.inputLocale = TypeFolioLanguageModel.languageCode(selection);
                subpageLoader.sourceComponent = null;
            }
            onRejected: subpageLoader.sourceComponent = null
        }
    }
}
