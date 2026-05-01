import QtQuick
import QtQuick.Layouts

import com.remarkable
import common
import device.global
import device.ui.headers
import device.ui.controls
import device.ui.text

import device.system
import device.view.experimental
import device.view.settings as SettingsView
import device.view.syncserviceexplorer
import xofm.libs.onboarding
import xofm.libs.dialogs
import xofm.libs.homescreen as HomeScreen

import com.remarkable.devicetelemetry
import com.remarkable.telemetry as Telemetry

import ark.controls as ArkControls
import ark.tokens as ArkTokens

import xofm.libs.qtgui
import xofm.libs.orientation
import xofm.libs.user
import xofm.libs.devicescreen
import xofm.libs.explorer // TreeExplorer, ViewManager, ExportManager
import xofm.libs.navigation // Entity.Type
import xofm.libs.retail
import xofm.libs.search.ui // SearchIndexStatus
import xofm.libs.system // SyncProgressBar
import xofm.libs.notificationbar // NotificationQueue
import xofm.libs.analytics.ui
import xofm.libs.settings // SettingsPage

/**
    Navigator is the main view, showing the users Documents and Collections

    Makes it possible to navigate around and open files.
*/
FocusScope {
    id: root
    signal requestOpenDocumentOnPage(var entry, var page)

    property bool sidebarOpen: false
    property alias sidebar: _sidebar
    property alias actionHeader: _actionHeader
    property var statusIndicators
    property var createWidgets
    property WindowNavigator windowNavigator
    required property PageSelection movePageSelection
    required property Orientation orientation
    required property RetailSettings retailSettings
    required property SearchIndexStatus searchIndexStatus
    required property NotificationQueue notificationQueue

    // Consider renaming from movingEntities to selectingTargetFolder
    readonly property bool movingEntities: actionHeader.state === "Moving" || actionHeader.state === "Exporting"
    readonly property bool loadingEntities: actionHeader.loadingEntities
    readonly property string importExportSourceId: actionHeader.importExportSourceId
    readonly property string importExportTargetId: actionHeader.importExportTargetId

    property PopupOverlay popupOverlay

    readonly property bool isSubdialogOpen: movePageActionBar.visible
                                            || searchLoader.active
                                            || Library.documentSelection.hasContent
                                            || popupOverlay && popupOverlay.activePopup && popupOverlay.activePopup.visible
    readonly property size gridSize: Values.gridSize(root.width - 2 * Values.viewHorizontalMargin, Math.round(Values.visibleGridColumns * Values.responsiveLayoutScale))

    readonly property TreeExplorer explorer: NavigationManager.treeExplorerForNavigation
    readonly property ExportManager exportManager: NavigationManager.exportManager

    readonly property bool hasActiveNavigation: NavigationManager.activeNavigationId !== Strings.invalidId
    onHasActiveNavigationChanged: {
        if (hasActiveNavigation && NavigationManager.activeNavigationId === Strings.libraryExplorerId) {
            explorer.update();
        }
    }

    Keys.onDownPressed: Global.keyboardNavigationController.focusVisibleView(KeyboardNavigationHandler.Direction.Down)
    Keys.onUpPressed: Global.keyboardNavigationController.focusVisibleView(KeyboardNavigationHandler.Direction.Up)
    Keys.onRightPressed: Global.keyboardNavigationController.focusVisibleView(KeyboardNavigationHandler.Direction.Right)
    Keys.onLeftPressed: Global.keyboardNavigationController.focusVisibleView(KeyboardNavigationHandler.Direction.Left)
    Keys.onTabPressed: Global.keyboardNavigationController.focusVisibleView(KeyboardNavigationHandler.Direction.None)

    readonly property alias navigatorTelemetry: _navigatorTelemetry

    property Analytics analytics

    Component.onCompleted: popupOverlay.verticalOffset = _actionHeader.height

    CloseShortcut {
        enabled: root.visible && !root.isSubdialogOpen
        objectName: "nav-close"
        onActivated: {
            if (_sidebar.activeView !== ViewManager.View.Tags) {
                treeExplorerComponent.navigateUp();
            }
        }
    }

    QtObject {
        id: _longPressEntryOnboarding
        OnboardingStateProp.group: OnboardingManager.Group.Tooltips
        OnboardingStateProp.domain: ""
        OnboardingStateProp.key: "Long_Press_Entry"
    }

    function showSearch() {
        let filterName = qsTr("All");
        switch (ViewManager.activeView) {
        case ViewManager.View.Notebooks:
            filterName = qsTr("Notebooks");
            break;
        case ViewManager.View.Pdfs:
            filterName = qsTr("PDFs");
            break;
        case ViewManager.View.Ebooks:
            filterName = qsTr("Ebooks");
            break;
        case ViewManager.View.Favorites:
            filterName = qsTr("Favorites");
            break;
        }

        if (root.movingEntities) {
            filterName = qsTr("Folders");
        } else if (!root.movePageSelection.isEmpty) {
            filterName = qsTr("Notebooks");
        }

        ViewManager.activeView = ViewManager.View.Search;
        if (searchLoader.item) {
            searchLoader.item.showFilter = true;
            if (root.movingEntities) {
                searchLoader.item.showFilter = false; // "Folders" is the only option => hide the filter so that the user cannot change it
            }
            searchLoader.item.updateFiltersModel(!root.movePageSelection.isEmpty);
            searchLoader.item.populateInitialState(filterName);
        }
    }

    function hideSearch() {
        if (ViewManager.activeView === ViewManager.View.Search) {
            openExplorer(ViewManager.previousView);
        }
    }

    // Resets all state, called as part of retail demo reset.
    function reset() {
        Library.documentSelection.clear();
        movePageActionBar.cancel();
        _actionHeader.cancel();
        _sidebar.hide();
        hideSearch();
        ViewManager.activeView = ViewManager.View.MyFiles;
    }

    function clearDocumentSelections() {
        explorer.selection.clear();
        explorer.clearTagSelection();
    }

    /*
        filter: Enum ViewManager.View
        navigationId: the id of the navigation (Used for distinguishing between integrations)
    */
    function openExplorer(filter, navigationId = Strings.libraryExplorerId) {
        NavigationManager.activeNavigationId = navigationId;
        ViewManager.activeView = filter;

        if (filter !== ViewManager.View.MyFiles && filter !== ViewManager.View.Integrations) {
            explorer.filterView(filter);
        }
    }

    function closeExplorer() {
        openExplorer(ViewManager.View.MyFiles);
    }

    /*
    folderId: the id of the folder to open in the current explorer
     */
    function openFolder(folderId) {
        if (explorer && explorer.isFolder(folderId)) {
            explorer.open(folderId);
        }
    }

    function openFolderFromMyFiles(id) {
        ViewManager.activeView = ViewManager.View.MyFiles;
        explorer.open(id);
    }

    // Helper function for BatteryManager onDisplayStateChanged
    function wasSleepingAndIsAwake(previous, next) {
        const wasSleeping = BatteryManager.DeepSleep === previous || BatteryManager.LightSleep === previous;
        const isAwake = BatteryManager.Normal === next;
        return isAwake && wasSleeping;
    }

    NavigatorTelemetry {
        id: _navigatorTelemetry
        dispatcher: Telemetry.Dispatcher

        function documentOpened(inFolder) {
            documentOpenedFromResolveQmlWrapper(sidebar.activeView, inFolder);
        }
    }

    DocumentConfiguratorTelemetry {
        id: _documentConfiguratorTelemetry
        dispatcher: Telemetry.Dispatcher
    }

    ContentHeader {
        id: contentHeader
        width: parent.width
        anchors.top: parent.top
        enabled: !root.isSubdialogOpen

        onMenuClicked: (fromKeyboard) => {
            _sidebar.toggle(fromKeyboard);
        }

        onLogoClicked: {
            root.openExplorer(ViewManager.View.MyFiles);
            root.explorer.openRoot();
        }

        onStatusIndicatorClicked: {
            if (_longPressEntryOnboarding.OnboardingStateProp.completed && !quickSettingsToolTip.OnboardingStateProp.completed) {
                quickSettingsToolTip.readyToShow = true;
            } else {
                root.windowNavigator.open("settings/window/quicksettings");
            }
        }
    }

    TreeExplorerView {
        id: treeExplorerComponent
        anchors {
            topMargin: _actionHeader.height
            fill: parent
        }
        visible: _sidebar.activeView !== ViewManager.View.Tags
        explorer: root.explorer
        movingEntities: root.movingEntities
        loadingEntities: root.loadingEntities
        orientation: root.orientation
    }

    TagExplorerView {
        id: tagExplorerComponent
        anchors {
            topMargin: _actionHeader.height
            fill: parent
        }
        visible: !treeExplorerComponent.visible
        explorer: root.explorer
        movingEntities: root.movingEntities
        windowNavigator: root.windowNavigator
        orientation: root.orientation
        enabled: _sidebar.activeView === ViewManager.View.Tags
        onOpenTreeExplorer: (id) => {
                                ViewManager.activeView = ViewManager.View.MyFiles;
                                root.explorer.open(id);
                            }
    }

    ToolTip {
        id: quickSettingsToolTip

        //: Recommended character limit for translation: 20
        caption: qsTr("Quick settings")
        positionHint: ArkControls.Tooltip.Position.Below
        pointTo: Item {
            // Point to an item outside of the content header so that the tooltip is shown above
            // the other navigator content.
            parent: root
            x: contentHeader.topStatusIndication.x -contentHeader.topStatusIndicationRightMargin
            y: contentHeader.topStatusIndication.y
            width: contentHeader.topStatusIndication.width
            height: contentHeader.topStatusIndication.height
        }
        OnboardingStateProp.key: "QuickSettings"

        Connections {
            target: BatteryManager
            enabled: !quickSettingsToolTip.OnboardingStateProp.completed
            function onDisplayStateChanged(previous, next) {
                if (root.wasSleepingAndIsAwake(previous, next) && _longPressEntryOnboarding.OnboardingStateProp.completed) {
                    quickSettingsToolTip.readyToShow = true;
                }
                // remove the search UI as it will interfere with the light sleep banner
                if (next === BatteryManager.LightSleep) {
                    root.hideSearch();
                }
            }
        }
        parent: pointTo.parent
        container: pointTo.parent
    }

    ToolTip {
        id: quicksheetsToolTip

        //: Recommended character limit for translation: 30
        caption: qsTr("Long-press for quick sheet")
        positionHint: ArkControls.Tooltip.Position.Above
        pointTo: Item {
            parent: createMenu
            // This tooltip should be implemented in the LibraryActions widget. For now we hardcode an offset to point to the quicksheet button.
            x: createMenu.x + 48
            y: createMenu.y - height
            width: createMenu.width
            height: createMenu.height * 0.1
        }
        OnboardingStateProp.key: "QuickSheetsOnLongPress"

        Connections {
            target: BatteryManager
            enabled: createMenu.visible && !quicksheetsToolTip.OnboardingStateProp.completed && ViewManager.activeView === ViewManager.View.MyFiles
            function onDisplayStateChanged(previous, next) {
                if (root.wasSleepingAndIsAwake(previous, next) && quickSettingsToolTip.OnboardingStateProp.completed && _longPressEntryOnboarding.OnboardingStateProp.completed) {
                    quicksheetsToolTip.readyToShow = Qt.binding(() => createMenu.view !== "trash");
                }
            }
        }
        parent: createMenu.parent
        container: createMenu.parent
    }

    ToolTip {
        id: documentDrawerTooltip

        //: Recommended character limit for translation: 20
        caption: qsTr("Document drawer")
        OnboardingStateProp.key: "DocumentDrawer"

        pointTo: Item {
            parent: root
            height: contentHeader.height / 6 // We want some spacing above the tooltip
            anchors {
                top: parent.top
                left: parent.left
                right: parent.right
            }
        }
        positionHint: ArkControls.Tooltip.Position.Below

        Connections {
            target: BatteryManager
            enabled: ViewManager.activeView === ViewManager.View.MyFiles

            function onDisplayStateChanged(previous, next) {
                const docsInLib = root.explorer.entityTypesCount([Entity.Type.File]);

                if (root.wasSleepingAndIsAwake(previous, next) && docsInLib > 3
                        && quickSettingsToolTip.OnboardingStateProp.completed
                        && quicksheetsToolTip.OnboardingStateProp.completed
                        && !documentDrawerTooltip.OnboardingStateProp.completed) {
                    documentDrawerTooltip.readyToShow = true;
                }
            }
        }
        parent: pointTo.parent
        container: pointTo.parent
    }

    ToolTip {
        id: retailToolTip

        // Completed state resets every time retail resets
        readyToShow: root.retailSettings.enabled && createMenu.visible && ViewManager.activeView !== ViewManager.View.Trash
        onReadyToShowChanged: {
            if (!readyToShow) {
                readyToShow = Qt.binding(() => root.retailSettings.enabled && createMenu.visible && ViewManager.activeView !== ViewManager.View.Trash);
            }

        }
        //: Recommended character limit for translation: 30
        caption: qsTr("Organize your notes")
        OnboardingStateProp.key: "RetailCreateMenu"
        positionHint: ArkControls.Tooltip.Position.Above
        pointTo: Item {
            parent: createMenu
            x: createMenu.x
            y: createMenu.y - height
            width: createMenu.width
            height: createMenu.height * 0.1
        }
        parent: createMenu.parent
        container: createMenu.parent
    }

    HomeScreen.CreateMenu {
        id: createMenu
        showCreateMenu: root.movePageSelection.isEmpty
                && root.explorer.selection.size === 0
                && !root.movingEntities

        view: {
            const view = ViewManager.activeView;
            switch(view) {
            case ViewManager.View.MyFiles:
                return "myfiles";
            case ViewManager.View.Pdfs:
            case ViewManager.View.Ebooks:
            case ViewManager.View.Tags:
            case ViewManager.View.Favorites:
                return "filter";
            case ViewManager.View.Notebooks:
                return "notebook-filter";
            case ViewManager.View.Trash:
                return treeExplorerComponent.emptyView ? "" : "trash";
            }
            return ""
        }

        popupOverlay: root.popupOverlay
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: Values.createMenuBottomMargin

        createWidgets: root.createWidgets

    }

    OnboardingDialogue {
        id: hwsPopup

        OnboardingStateProp.group: OnboardingManager.Group.Dialogs
        OnboardingStateProp.domain: ""
        OnboardingStateProp.key: "HWS_Connect_Popup"

        visible: root.searchIndexStatus.initialIndexCompleted && !OnboardingStateProp.completed
        initialModel: [{
            image: "qrc:/onboarding/illustrations/handwriting_search",
            title: qsTr("Handwriting search"),
            body: [{ "description":
                qsTr("Find what you're looking for by searching for keywords in your handwritten notes and digital text inside notebooks and documents.")}],
        }]
        rightButtonText: qsTr("Search now")
        onRightButtonClicked: {
            if (!root.movingEntities && root.movePageSelection.isEmpty) {
                root.clearDocumentSelections();
            }
            root.showSearch();
            hwsPopup.close();
        }

        closeOption: true
        onQuitButtonClicked: {
            OnboardingStateProp.completed = true;
        }
    }

    RetailDemoIndicator {
        visible: RetailDemo.enabled
    }

    SyncProgressBar {
        id: syncProgress
        documentSync: DocumentSync
        anchors {
            bottom: parent.bottom
            right: parent.right
            left: parent.left
        }
    }

    NotificationBar {
        anchors {
            bottom: parent.bottom
            left: parent.left
            right: parent.right
        }
        notificationQueue: root.notificationQueue
    }

    Sidebar {
        id: _sidebar
        width: Values.navigatorSidebarWidth
        height: parent.height
        visible: false
        onVisibleChanged: root.sidebarOpen = visible
        retailDemoEnabled: RetailDemo.enabled
        wifiOnline: LinkProvider.isOnline
        windowNavigator: root.windowNavigator
        navigatorTelemetry: root.navigatorTelemetry

        onShowIntegrationEmptyState: {
            _sidebar.hide();
            root.windowNavigator.open("integrations-storage/window/empty-view");
        }
        onShowIntegrationRetailPopup: root.windowNavigator.open("retail/window/popup", {
                                                                         imageUrl: "qrc:/onboarding/illustrations/integrations",
                                                                         title: qsTr("Integrations"),
                                                                         bodyList: [
                                                                             qsTr("Access Google Drive, Dropbox, and OneDrive right from your <nobr>paper tablet</nobr> to improve your workflow. Locate stored files, import them to your reMarkable, and export documents directly to your chosen service."),
                                                                             Strings.notAvailableInRetailString,
                                                                         ]
                                                                     });
        onOpenExplorer: function(view) {
            if (ViewManager.activeView === view) {
                return;
            }
            root.openExplorer(view);
        }
        onOpenExplorerWithNavigationId: function(view, navigationId) {
            root.openExplorer(view, navigationId);
        }
        onSidebarMenuClicked: function(text) {
            root.navigatorTelemetry.sidebarMenuClicked(text);
        }
        onEmptyStateShown: function(text) {
            root.navigatorTelemetry.emptyStateShown(text);
        }
    }

    Item {
        id: actionHeaderOverlay
        width: root.width
        height: root.height
    }

    ActionHeader {
        id: _actionHeader
        foldoutOverlay: actionHeaderOverlay
        anchors.top: root.top
        visible: root.explorer.selection.size > 0 || _actionHeader.state !== "" || root.explorer.selectedTags.length > 0
        width: parent.width
        explorer: root.explorer
        selection: root.explorer.selection
        navigationManager: NavigationManager
        notificationQueue: root.notificationQueue
        navigatorTelemetry: root.navigatorTelemetry
        retailSettingsEnabled: root.retailSettings.enabled
        popupOverlay: root.popupOverlay
        orientation: root.orientation
        windowNavigator: root.windowNavigator
        canArchive: DocumentSync.canArchive
        activeView: ViewManager.activeView
        onStateChanged: {
            if (_actionHeader.state === "Moving") {
                _actionHeader.sourceFolder = root.explorer.selectedEntityParentId();

                if (ViewManager.activeView !== ViewManager.View.MyFiles) {
                    // enable option to move files anywhere when moving a multiple selection from a filter view
                    // and we want to move to My files when moving
                    root.openExplorer(ViewManager.View.MyFiles);
                    if (root.explorer.selection.size > 1) {
                        _actionHeader.sourceFolder = "";
                    }
                    return;
                }
            }
        }
        onSwitchIntegration: (id) => { root.openExplorer(ViewManager.View.Integrations, id); }
        onRejected: {
            root.explorer.selection.selectionClearIsNew();
            root.explorer.selection.clear();
            root.explorer.clearTagSelection();
        }
        onExportSelection: (selection, fileType) => {
            exportManager.selectionExport(root.importExportSourceId,
                                          selection.selectedIds,
                                          root.importExportTargetId,
                                          root.explorer.currentFolderId,
                                          fileType);
            selection.clear();
        }
        onOpenMyFiles: root.openExplorer(ViewManager.View.MyFiles)
        onOpenExplorer: (filter, id) => { root.openExplorer(filter, id); }
        onOpenFolder: (folderId) => { root.openFolder(folderId); }
        onCreateCollection: root.createCollection("action header")
        onShowSearch: root.showSearch()
        onDeleteTrashClicked: root.deleteFilesFromTrash()
        onDeleteTags: root.deleteTags()
    }

    ActionBarBase {
        id: movePageActionBar

        property bool _moreFoldoutShown: false

        function cancel() {
            root.movePageSelection.cancelMovePagesAction();
        }

        visible: !root.movePageSelection.isEmpty
        height: _actionHeader.height
        width: parent.width
        //: Recommended character limit for translation: 30
        title: qsTr("Select where to place the page", "Move page in my files")
        actionButtons: [
            ArkControls.ActionBar.ActionButton {
                text: qsTr("More")
                iconSource: "qrc:/ark/icons/three_dots_vertical"
                selected: movePageActionBar._moreFoldoutShown
                onClicked: movePageActionBar._moreFoldoutShown = !movePageActionBar._moreFoldoutShown

                Loader {
                    id: moreFoldoutLoader
                    objectName: "moreFoldoutLoader"
                    anchors {
                        top: parent.bottom
                        topMargin: -moreFoldoutLoader.item?.background?.border.width
                        right: parent.right
                    }
                    active: movePageActionBar._moreFoldoutShown
                    sourceComponent: Component {
                        MoveSelectFoldout {
                            onNotebookClicked: root.createNotebook()
                            onSearchClicked: root.showSearch()
                        }
                    }
                }
            }
        ]
        onCancelClicked: movePageActionBar.cancel()
    }

    CloseShortcut {
        anchors.fill: movePageActionBar
        objectName: "page-selection-info-close"
        onActivated: movePageActionBar.cancel()
    }


    Component {
        id: searchComponent
        ExplorerSearch {
            id: searchExplorer

            treeExplorer: root.explorer
            orientation: root.orientation
            searchIndexStatus: root.searchIndexStatus
            windowNavigator: root.windowNavigator

            function navigateToFolder(id) {
                clearSearch();
                root.openExplorer(ViewManager.View.MyFiles);
                root.explorer.open(id);
            }
            function openDocument(id) {
                root.navigatorTelemetry.documentOpenedFromSearch();
                root.explorer.open(id);
            }
            function clearSearch()
            {
                root.hideSearch();
                root.explorer.clearTagFilterSelection()
            }

            onCancel: clearSearch();
            onHwsConnectTooltipCompleted: {
                hwsPopup.OnboardingStateProp.completed = true;
            }

            onEntityClicked: (id, type) => {
                /*** Behaviour - OnClick
                *   No selection:
                *       Folder: navigate to folder
                *       Document: open document
                *   Selected state:
                *       Folder: navigate to folder, clear selection
                *       Document: open document, clear selection
                *   Move state:
                *       Folder: navigate to folder, do not clear selection
                *       Document: do nothing
                *   Page move state:
                *       Folder: navigate to folder, do not clear
                *       Document: open document in page overview, do not clear
                */

                if (root.movingEntities) {
                    if (type === Entity.Type.Folder) {
                        searchExplorer.navigateToFolder(id);
                    }
                    return;
                }
                if (explorer.selection.size > 0) {
                    root.clearDocumentSelections();
                    if (type === Entity.Type.File) {
                        searchExplorer.openDocument(id);
                    } else if (type === Entity.Type.Folder) {
                        searchExplorer.navigateToFolder(id);
                    }
                    return;
                }
                // BOTH No state andS page move state
                if (type === Entity.Type.Folder) {
                    searchExplorer.navigateToFolder(id);
                } else if (type === Entity.Type.File) {
                    searchExplorer.openDocument(id);
                } else if (type === Entity.Type.Page) {
                    searchExplorer.openDocument(id);
                } else if (type === Entity.Type.Content) {
                    searchExplorer.openDocument(id);
                }
            }
            onEntityPressAndHold: (id, type) => {
                /*** Behaviour - OnPressedAndHold
                *   No selection:
                *       Folder: navigate to parent, select folder
                *       Document: navigate to parent, select document
                *   Selected state:
                *       Folder: navigate to parent, select folder
                *       Document: navigate to parent, select document
                *   Move state:
                *       Folder: navigate to folder, do not clear
                *       Document: do nothing
                *   Page move state:
                *       Folder: navigate to folder, do not clear
                *       Document: open document in page overview, do not clear
                */
                if (root.movingEntities) {
                    if (type === Entity.Type.Folder) {
                        searchExplorer.navigateToFolder(id);
                    }
                    return;
                }
                if (!root.movePageSelection.isEmpty) {
                    if (type === Entity.Type.File) {
                        searchExplorer.openDocument(id);
                    } else if (type === Entity.Type.Folder) {
                        searchExplorer.navigateToFolder(id);
                    }
                    return;
                }
                if (type === Entity.Type.Page) {
                    searchExplorer.clearSearch();
                    // TODO: This should go to page overview and select instead
                    searchExplorer.openDocument(id);
                } else {
                    root.clearDocumentSelections();
                    searchExplorer.navigateToFolder(explorer.parentForEntity(id));
                    root.explorer.selection.add(id);
                }

            }
        }
    }

    Connections {
        // Covers export-related integration messages
        target: exportManager

        function onStatusMessage(navigationId, message) {
            // The action is to navigate to the navigation we're NOT already on, either source or target
            // Note: we can't use identity-compare between strings and NavigationIds
            const actionNavigationId = NavigationManager.activeNavigationId == root.importExportSourceId
                ? root.importExportTargetId : root.importExportSourceId;
            const name = NavigationManager.navigationName(actionNavigationId);
            const viewType = name === "My files" ? ViewManager.View.MyFiles : ViewManager.View.Integrations;
            // Do not show the action button if the import is still in the "Importing document' step
            // (we want to wait for the import to be complete before displaying the action)
            const shouldShowAction = navigationId != root.importExportSourceId;
            const backToSource = actionNavigationId === root.importExportSourceId;
            //: %1 is the place to navigate back to, for instance "My Dropbox"
            const navigateText = backToSource ? qsTr("Back to %1").arg(name)
                //: %1 is the place to navigate to, for instance "My Dropbox"
                : qsTr("Open %1").arg(name);
            const actionText = shouldShowAction ? navigateText : "";

            root.notificationQueue.clear();
            root.notificationQueue.enqueue({
                "text": message,
                "style": Notification.Secondary,
                "actionText": actionText,
                "onClicked": () => {
                    root.openExplorer(viewType, actionNavigationId);
                },
            });
        }

        function onErrorMessage(navigationId, message) {
            root.notificationQueue.clear();
            root.notificationQueue.enqueue({
                "text": message,
                "id": "integrationErrorMessage",
            });
        }
    }

    Connections {
        // Covers non-export-related integration messages
        target: NavigationManager

        function onStatusMessage(navigationId, message) {
            root.notificationQueue.enqueue({
                "text": message,
                "style": Notification.Secondary,
            });
        }

        function onErrorMessage(navigationId, message) {
            root.notificationQueue.enqueue({
                "text": message,
                "id": "integrationErrorMessage",
            });
        }
    }

    Loader {
        id: searchLoader
        anchors.fill: parent
        active: ViewManager.activeView === ViewManager.View.Search
        onActiveChanged: {
            // Make sure the ExplorerSearch item is focused when opening search.
            if (active) {
                searchLoader.item.forceActiveFocus();
            }
        }
        visible: active
        focus: visible
        sourceComponent: searchComponent
    }

    function createCollection(trigger) {
        windowNavigator.open("library-ui/window/create-collection", {
            trigger: trigger,
            parentFolderId: explorer.currentFolderId,
            onCreated: (id) => {
                if(!root.movingEntities) {
                    return;
                }
                windowNavigator.open("legacydevice/window/main", {folderId: id});
            }
        });
    }

    function createNotebook() {
        windowNavigator.open("library-ui/window/create-notebook", {
            currentFolderId: explorer.currentFolderId,
            onCreated: (id) => {
                windowNavigator.open("legacydevice/window/main", {documentId: id});
            }
        });
    }

    function emptyTrash() {
        root.windowNavigator.open("library-ui/window/confirm-delete-trash", {
            onAccepted: () => {
                const numFilesTrashed = explorer.removeAllTrashed();
                root.notificationQueue.enqueue({
                    "text": qsTr("%n item(s) were deleted", "", numFilesTrashed),
                    "style": Notification.Secondary,
                });
            },
        });
    }

    function deleteFilesFromTrash() {
        root.windowNavigator.open("library-ui/window/confirm-delete-trash", {
            onAccepted: () => {
                const numFilesTrashed = explorer.selection.size;
                explorer.selection.selectionRemove();
                _actionHeader.cancel();
                root.notificationQueue.enqueue({
                    "text": qsTr("%n item(s) were deleted", "", numFilesTrashed),
                    "style": Notification.Secondary,
                });
            },
        });
    }

    function deleteTags() {
        root.windowNavigator.open("tags/window/confirm-delete-tags", {
            numOfTags: explorer.selectedTags.length,
            onAccepted: () => {
                root.notificationQueue.enqueue({
                    "text": qsTr("%n tag(s) were deleted", "", explorer.selectedTags.length),
                    "style": Notification.Secondary,
                });
                explorer.deleteSelectedTags();
                _actionHeader.cancel();
            },
        });
    }
}
