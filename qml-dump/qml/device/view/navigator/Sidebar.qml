import QtQuick
import QtQuick.Layouts

import com.remarkable
import common

import device.global
import device.ui.controls
import device.view.experimental
import xofm.libs.explorer // ViewManager, NavigationSortedListModel
import xofm.libs.settings // SettingsPage
import xofm.libs.navigation // IIntegration

/**
    The Sidebar is the menu that opens with the top left menu button.

    It contains the filtering options (by file type), integrations, trash and settings.
*/
DeviceKeyboardNavigationHandler {
    id: root
    objectName: "Sidebar"
    navigationModel: [filterMyFiles, filters, filterPinned, filterTags, integrations, filterTrashed, quickHelp, settingsButton]
    canAcceptTabActivation: true
    keyOverrideHandler: overrideNavigation.bind(this)
    property int activeView: ViewManager.activeView
    required property bool retailDemoEnabled
    required property bool wifiOnline
    required property var windowNavigator
    required property var navigatorTelemetry

    focus: visible

    signal showIntegrationEmptyState
    signal showIntegrationRetailPopup
    signal openExplorer(int view)
    signal openExplorerWithNavigationId(int view, string fieldId)
    signal sidebarMenuClicked(string text)
    signal emptyStateShown(string text)

    onRetailDemoEnabledChanged: navigationListModel.updateModel()
    onWifiOnlineChanged: {
        navigationListModel.updateModel();
        // since the initial network connection happens BEFORE this component is loaded,
        // isDisabled should be bounded to !isOnline for initial startup of the device.
        // Afterwards, we need to break this binding, because if the user puts the device on
        // flight mode or loses connection for some reason, we don't want the button to be disabled anymore.
        if (!wifiOnline) {
            integrations.isDisabled = false;
        }
    }

    onTabCycle: {
        Global.keyboardNavigationController.focusOtherHandler(root);
        root.resetFocusIndex();
        hide();
    }
    Rectangle {
        anchors.fill: parent
        color: Values.colorWhite
    }
    onActivated: (element) => element?.activate()

    function overrideNavigation(event) {
        // Handle expanding the foldout and focusing it.
        if (event.key === Qt.Key_Right) {
            let activeHandler;

            if (root.current instanceof SidebarFoldoutItem &&
                root.current.parent instanceof DeviceKeyboardNavigationHandler) {
                activeHandler = root.current.parent;
            }
            if (activeHandler) {
                if (activeHandler.isOpen) {
                    root.focus = false;
                    activeHandler.forceActiveFocus();
                    activeHandler.navigate();
                } else {
                    activeHandler.open();
                    root.focus = false;
                    activeHandler.forceActiveFocus();
                    activeHandler.navigate();
                }
            }
            return true;
        } else if (event.key === Qt.Key_Left) {
            return true;
        }
        return false;
    }

    function overrideFoldoutNavigation(event) {
        // Handle navigating back to the sidebar again.
        if (event.key === Qt.Key_Left) {
            filterHandler.focus = false;
            integrationsHandler.focus = false;
            root.forceActiveFocus();
            root.hideFoldouts();
            return true;
        }
        return false;
    }

    function toggle(fromKeyboard = false) {
        visible = !visible;
        hideFoldouts();
        // sidebar must always have focus when it's open due to keyboard navigation
        if (visible) {
            forceActiveFocus();
            if (fromKeyboard) {
                root.navigate();
            }
        } else {
            focus = false;
        }
    }

    function hide() {
        focus = false;
        visible = false;
        hideFoldouts();
    }

    function hideFoldouts() {
        filters.isOpen = false;
        integrations.isOpen = false;
    }

    ListModel {
        id: retailListModel

        function onClicked(name) {
            root.showIntegrationRetailPopup();
        }

        ListElement {
            name: qsTr("Google Drive")
            iconSource: "qrc:/ark/icons/google_drive"
        }
        ListElement {
            name: qsTr("Dropbox")
            iconSource: "qrc:/ark/icons/dropbox"
        }
        ListElement {
            name: qsTr("OneDrive")
            iconSource: "qrc:/ark/icons/onedrive"
        }
    }

    NavigationSortedListModel {
        id: navigationSortedModel
        property var listModel: NavigationManager.navigationView
        onListModelChanged: navigationListModel.updateModel()
        onListChanged: navigationListModel.updateModel()
        list: listModel
        filter: Strings.libraryExplorerId
    }

    ListModel {
        id: navigationListModel
        function onClicked(_name, id) {
            toggle();
            let integration = find(id);
            integrations.activeChild = integration;
            root.openExplorerWithNavigationId(ViewManager.View.Integrations, integration.id);
        }

        function find(navigationId) {
            for (let i = 0; i < navigationListModel.count; ++i) {
                let navigation = navigationSortedModel.get(i);
                if (navigationId === navigation.id) {
                    return navigation;
                }
            }
            return;
        }

        function updateModel() {
            clear();
            for (let i = 0; i < navigationSortedModel.rowCount(); ++i) {
                let navigation = navigationSortedModel.get(i);
                append({"name": navigation.name,
                        "provider": navigation.provider,
                        "id": navigation.id,
                        "iconSource": navigation.iconSource,
                        "errorText": qsTr(getErrorText(navigation, integrations.isDisabled))});
            }
        }
    }

    function getErrorText(navigation, isDisabled) {
        if (isDisabled || (NavigationManager.isIntegrationAvailable && !wifiOnline)) {
            return QT_TR_NOOP("Currently offline");
        } else if (!!navigation && navigation.state === IIntegration.State.ErrorAuthentication) {
            return QT_TR_NOOP("Authorization removed");
        } else if (!!navigation && navigation.state === IIntegration.State.ErrorGeneric) {
            return QT_TR_NOOP("Something went wrong");
        }
        return "";
    }

    MouseArea {
        height: parent.height
        width: Values.deviceWidth - parent.width
        anchors.left: parent.right
        onClicked: root.toggle()
    }

    ColumnLayout {
        id: filterColumn
        anchors.fill: parent
        spacing: 0

        SidebarFilterItem {
            id: filterMyFiles
            objectName: "filterMyFiles"
            //: Recommended character limit for translation: 12
            title: qsTr("My files")
            iconSource: "qrc:/ark/icons/my_files"
            active: activeView === ViewManager.View.MyFiles
            enabled: true
            onClicked: {
                activate();
                root.resetFocusIndex();
            }
            Layout.preferredHeight: Values.navigatorSidebarItemHeight
            Layout.preferredWidth: parent.width
            navigationHandler: root

            function activate() {
                toggle();
                root.sidebarMenuClicked("My Files");
                root.openExplorer(ViewManager.View.MyFiles);
            }
        }

        DeviceKeyboardNavigationHandler {
            id: filterHandler
            navigationModel: filters.foldoutItems
            Layout.preferredHeight: Values.navigatorSidebarItemHeight
            Layout.preferredWidth: parent.width
            property alias isOpen: filters.isOpen
            keyOverrideHandler: root.overrideFoldoutNavigation.bind(this)

            onActivated: (element) => element?.activate()

            function open() {
                filters.open();
            }

            SidebarFoldoutItem {
                id: filters
                objectName: "filters"
                //: Recommended character limit for translation: 12
                title: !!activeChild ? activeChild.name : qsTr("Filter by")
                iconSource: !!activeChild ? activeChild.iconSource : "qrc:/ark/icons/filter"
                height: parent.height
                width: parent.width
                onClicked: {
                    activate();
                    root.resetFocusIndex();
                }
                navigationHandler: root
                subItemNavigationHandler: filterHandler

                function activate() {
                    integrations.isOpen = false;
                    isOpen = !isOpen;
                }

                function open() {
                    integrations.isOpen = false;
                    isOpen = true
                }

                ListModel {
                    id: filterModel
                    function onClicked(name) {
                        toggle();

                        //: Menu item in the 'Filter by' section
                        if (name === qsTr("Notebooks", "filter")) {
                            root.sidebarMenuClicked("Filter Notebooks");
                            root.openExplorer(ViewManager.View.Notebooks);
                        }
                        //: Menu item in the 'Filter by' section
                        else if (name === qsTr("PDFs", "filter")) {
                            root.sidebarMenuClicked("Filter PDFs");
                            root.openExplorer(ViewManager.View.Pdfs);
                        }
                        //: Menu item in the 'Filter by' section
                        else if (name === qsTr("Ebooks", "filter")) {
                            root.sidebarMenuClicked("Filter Ebooks");
                            root.openExplorer(ViewManager.View.Ebooks);
                        }
                    }

                    function find(activeView) {
                      for (let i = 0; i < filterModel.count; ++i) {
                          if (filterModel.get(i).id === activeView) {
                              return filterModel.get(i)
                          }
                      }
                      return;
                    }

                    ListElement {
                        //: Recommended character limit for translation: 12
                        name: qsTr("Notebooks")
                        iconSource: "qrc:/ark/icons/notebook"
                    }
                    ListElement {
                        //: Recommended character limit for translation: 12
                        name: qsTr("PDFs")
                        iconSource: "qrc:/ark/icons/document"
                    }
                    ListElement {
                        //: Recommended character limit for translation: 12
                        name: qsTr("Ebooks")
                        iconSource: "qrc:/ark/icons/ebook"
                    }
                }

                model: filterModel
                activeChild: filterModel.find(activeView)
            }
        }

        SidebarFilterItem {
            id: filterPinned
            objectName: "filterPinned"
            //: Recommended character limit for translation: 12
            title: qsTr("Favorites")
            iconSource: "qrc:/ark/icons/star"
            active: activeView === ViewManager.View.Favorites
            onClicked: {
                activate();
                root.resetFocusIndex();
            }
            Layout.preferredHeight: Values.navigatorSidebarItemHeight
            Layout.preferredWidth: parent.width
            navigationHandler: root

            function activate() {
                toggle();
                root.sidebarMenuClicked("Filter Favorites");
                root.openExplorer(ViewManager.View.Favorites);
            }
        }

        SidebarFilterItem {
            id: filterTags
            objectName: "filterTags"
            //: Recommended character limit for translation: 12
            title: qsTr("Tags")
            active: activeView === ViewManager.View.Tags
            iconSource: "qrc:/ark/icons/tag"
            onClicked: {
                activate();
                root.resetFocusIndex();
            }
            Layout.preferredHeight: Values.navigatorSidebarItemHeight
            Layout.preferredWidth: parent.width
            navigationHandler: root

            function activate() {
                toggle();
                root.sidebarMenuClicked("Tags");
                root.openExplorer(ViewManager.View.Tags);
            }
        }

        DeviceKeyboardNavigationHandler {
            id: integrationsHandler
            navigationModel: integrations.foldoutItems
            Layout.preferredHeight: Values.navigatorSidebarItemHeight
            Layout.preferredWidth: parent.width
            property alias isOpen: integrations.isOpen
            keyOverrideHandler: root.overrideFoldoutNavigation.bind(this)

            onActivated: (element) => element?.activate();

            function open() {
                integrations.open();
            }

            SidebarFoldoutItem {
                id: integrations
                objectName: "integrations"
                property bool integrationActive: root.activeView === ViewManager.View.Integrations
                property bool isDisabled: !root.retailDemoEnabled ? !root.wifiOnline : false

                states: [
                    State {
                        name: "activeIntegration"
                        when: !!integrations.activeChild

                        PropertyChanges {
                            target: integrations
                            title: qsTr("Import from")
                            description: integrations.activeChild.name
                            iconSource: integrations.activeChild.iconSource
                        }
                    },
                    State {
                        name: "hasIntegrations"
                        when: integrations.model.count > 0

                        PropertyChanges {
                            target: integrations
                            title: qsTr("Import files")
                            //: Recommended character limit for translation: 12
                            description: integrations.model.count === 1
                                ? integrations.model.get(0).name
                                : qsTr("%n storage integration(s)", "", integrations.model.count)
                            iconSource: "qrc:/ark/icons/cloud"
                        }
                    },
                    State {
                        name: "noIntegrations"
                        when: integrations.model.count <= 0

                        PropertyChanges {
                            target: integrations
                            //: Recommended character limit for translation: 12
                            title: qsTr("Import files")
                            description: qsTr("Add storage integration")
                            iconSource: "qrc:/ark/icons/cloud"
                        }
                    }
                ]
                height: parent.height
                width: parent.width
                foldoutArrowVisible: integrations.model.count > 1
                active: integrationActive || isOpen
                onActiveChanged: {
                    if (!active) {
                        integrations.activeChild = null;
                    }
                }
                errorText: qsTr(root.getErrorText(activeChild, integrations.isDisabled))
                model: root.retailDemoEnabled ? retailListModel : navigationListModel
                onClicked: {
                    if (!isDisabled) {
                        activate();
                    }
                }
                navigationHandler: root
                subItemNavigationHandler: integrationsHandler

                function activate() {
                    filters.isOpen = false;
                    root.sidebarMenuClicked("Integrations");
                    root.resetFocusIndex();

                    if(!NavigationManager.isIntegrationAvailable && !retailDemoEnabled) {
                        showIntegrationEmptyState();
                    }

                    if (model.count === 1) {
                        navigationListModel.onClicked(integrations.title, integrations.model.get(0).id);
                    }

                    isOpen = !isOpen;
                }

                function open() {
                    filters.isOpen = false;
                    isOpen = true
                }

                Connections {
                    target: NavigationManager
                    enabled: integrations.integrationActive
                    function onNavigationViewChanged(changeType, navigationId) {
                        if (IIntegration.ChangedType.Removed === changeType &&
                            integrations.activeChild.id === navigationId.toString()) {
                            integrations.activeChild = null;
                        }
                    }
                }
            }
        }

        Background {
            id: spacer
            Layout.fillHeight: true
            Layout.alignment: Qt.AlignLeft
            Layout.preferredWidth: parent.width
        }

        SidebarFilterItem {
            id: filterTrashed
            objectName: "filterTrashed"
            //: Recommended character limit for translation: 12
            title: qsTr("Trash")
            iconSource: "qrc:/ark/icons/trashcan"
            active: activeView === ViewManager.View.Trash
            onClicked: {
                activate();
                root.resetFocusIndex();
            }
            Layout.preferredHeight: Values.navigatorSidebarItemHeight
            Layout.preferredWidth: parent.width
            navigationHandler: root

            function activate() {
                toggle();
                root.sidebarMenuClicked("Trash");
                root.openExplorer(ViewManager.View.Trash);
            }
        }

        Item {
            Layout.preferredWidth: parent.width
            height: 2

            Rectangle {
                anchors.fill: parent
                color: Values.colorBlack
            }
        }

        IconButton {
            id: quickHelp
            width: parent.width
            enabled: visible
            iconSource: "qrc:/ark/icons/compass"
            //: Recommended character limit for translation: 12
            title: qsTr("Guides")
            font.weight: Font.Medium
            Layout.preferredHeight: Values.navigatorSidebarItemHeight
            Layout.preferredWidth: parent.width
            navigationHandler: root
            onClicked: {
                activate();
                root.resetFocusIndex();
            }

            function activate() {
                root.windowNavigator.open("onboarding-ui/window/guides");
                toggle();
                root.sidebarMenuClicked("Guides");
            }
        }

        IconButton {
            id: settingsButton
            objectName: "settingsButton"
            width: parent.width
            iconSource: "qrc:/ark/icons/cog"
            //: Recommended character limit for translation: 12
            title: qsTr("Settings")
            font.weight: Font.Medium
            onClicked: {
                activate();
                root.resetFocusIndex();
            }
            Layout.preferredHeight: Values.navigatorSidebarItemHeight
            Layout.preferredWidth: parent.width
            navigationHandler: root

            function activate() {
                root.windowNavigator.open("settings/window/main", { index: SettingsPage.General });
                toggle();
                root.sidebarMenuClicked("Settings");
            }
        }
    }
    Rectangle {
        anchors.right: parent.right
        height: parent.height
        width: Values.outlineSize
        color: Values.colorBlack
    }
}
