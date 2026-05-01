import QtQuick

import QtQuick.Window
import ark.tokens as ArkTokens
import ark.controls as ArkControls

import com.remarkable
import common

import device.system
import device.global
import device.ui.text
import device.ui.controls
import device.ui.headers
import com.remarkable.devicetelemetry
import com.remarkable.telemetry as Telemetry

import device.view.navigator
import device.view.documentview
import xofm.libs.onboarding
import device.view.settings
import device.view.dialogs
import device.view.experimental

import xofm.libs.gestures
import xofm.libs.qtgui
import xofm.libs.retail
import xofm.libs.sceneview
import xofm.libs.peninput
import xofm.libs.toolbar as ToolbarControl
import xofm.libs.batterymanager
import xofm.libs.epaper as Epaper
import xofm.libs.epub
import xofm.libs.explorer // ViewManager, TreeExplorer
import xofm.libs.navigation //ISelectiveSync
import xofm.libs.orientation
import xofm.libs.documentorientation
import xofm.libs.search.ui // SearchIndexStatus
import xofm.libs.sharebyurl
import xofm.libs.settings // SettingsPage
import xofm.libs.notificationbar // NotificationQueue
import xofm.libs.analytics.ui
import xofm.libs.pincode

Background {
    id: root
    focus: true

    property Window window: Window.window
    property alias rootItem: rootItem

    property var statusIndicators
    property var insecureSettings
    property var documentViewListener
    property Orientation orientation
    property DocumentOrientation documentOrientation
    required property var ghostBuster
    required property var pageSelection
    required property TextColumn textColumn
    required property PenInput penInput
    required property ToolbarControl.Config toolbarConfiguration;
    required property ToolbarControl.ToolbarProvider toolbarProvider
    required property DocumentState documentState
    required property EpubSettings epubSettings
    required property SearchIndexStatus searchIndexStatus
    required property ShareByUrl shareByUrl
    required property NotificationQueue notificationQueue
    required property Analytics analytics
    required property PasscodeHandler passcodeHandler
    required property var createWidgets

    property var allTags: []
    property WindowNavigator windowNavigator
    property WindowLayout windowLayout
    property bool documentViewActive: !!documentView.item?.documentLoaded
    readonly property TreeExplorer explorer: NavigationManager.treeExplorerForNavigation

    property alias content: viewRoot

    function onOpened(args) {
        navigator?.popupOverlay?.hideAllPopups();
        const { documentId, folderId, settings, page, pageHighlightDetails, showSearch } = args;
        if (!!documentId) {
            const document = Library.entryForId(documentId);

            const { openedFrom, analyticsDetails } = args;
            reportDocumentOpened(document, openedFrom, analyticsDetails);

            const openDocument_cb = (page == null || page < 0) ? () => documentView.item.openDocument(document)
                                                        : () => documentView.item.openDocumentOnPage(document, page, pageHighlightDetails);

            openDocument_helper(document, openDocument_cb);
            return;
        }

        if (!!folderId) {
            navigator.openFolderFromMyFiles(folderId);
            documentView.item?.close();
            return;
        }
        if(showSearch) {
            navigator.showSearch();
            return;
        }
    }

    // Analytics
    function reportDocumentOpened(entry, openFrom = "", additionalProperties = {}) {
        if (!entry || !openFrom) {
            return;
        }

        // Setting default properties
        const properties = Object.assign({
            "document_id": entry.id,
            "parent_id": entry.parentId,
            "device_orientation": AnalyticsUtils.enumToString(root.orientation?.orientation, "xofm::libs::qtgui::WindowLayout::Orientation"),
            "document_type": AnalyticsUtils.enumToString(entry.fileType, "Document::FileType"),
            "is_quick_sheets": entry.isQuickSheet(),
            "document_from_methods": entry.isMethodsContent,
            "open_on_page": entry.lastOpenedPage,
            "number_of_pages": entry.pageCount,
            "last_modified_at": entry.lastModified,
            "last_opened_at": entry.lastOpened === 0 ? entry.lastModified : entry.lastOpened,
            "created_at": entry.createdTime,
            "trigger": openFrom
        }, additionalProperties);

        root.analytics.sendEvent("Document Opened", properties);
    }

    function resolveSearchDetails(pageNumber, highlightDetails) {
        const matchesOn = [];
        if (highlightDetails?.hasHandwritingOnPage(pageNumber)) {
            matchesOn.push("handwriting");
        }
        if (highlightDetails?.hasDigitalOnPage(pageNumber)) {
            matchesOn.push("digital");
        }
        if (!matchesOn.length) {
            // no need to return an object with empty array
            return {};
        }
        // We can also do lookup to see if it matches on title or tags here.

        return { "search_details": matchesOn };
    }

    Connections {
        target: LibraryExplorer
        function onOpenDocument(entry, pageNumber, pageHighlightDetails) {

                const openedFrom = (() => {
                    switch (ViewManager.activeView) {
                    case ViewManager.View.Notebooks:
                    case ViewManager.View.Pdfs:
                    case ViewManager.View.Ebooks:
                        return {
                            trigger: "filters",
                            details: { "filter_details": AnalyticsUtils.enumToString(ViewManager.activeView, "xofm::libs::explorer::ViewManager::View") }
                            };
                    default:
                        return {
                            trigger: AnalyticsUtils.enumToString(ViewManager.activeView, "xofm::libs::explorer::ViewManager::View")
                        };
                    }
                })();

            // Resolve additional search analytics
            const searchDetails = resolveSearchDetails(pageNumber, pageHighlightDetails);
            const analyticsDetails = Object.assign({}, openedFrom?.details, searchDetails);

            if (pageNumber >= 0) {
                root.windowNavigator.open("legacydevice/window/main", {
                    documentId: entry.id,
                    page: pageNumber,
                    pageHighlightDetails: pageHighlightDetails,
                    openedFrom: openedFrom.trigger,
                    analyticsDetails: analyticsDetails
                });
                return;
            }

            root.windowNavigator.open("legacydevice/window/main", {
                documentId: entry.id,
                openedFrom: openedFrom.trigger,
                analyticsDetails: analyticsDetails
            });
        }

        function onSendMail(entry) {

            const openAction = (args) => {
                root.windowNavigator.open("sendmail/window/email-dialog", args);
            }

            if (entry.lockedByPassword) {
                windowNavigator.open("document/window/unlock", {
                    documentToUnlock: entry,
                    action: (password) => {
                        openAction({document: entry, password: password});
                    }
                });
                return;
            }
            openAction({document: entry});
        }

        function onRenameEntry(entry) {
            root.windowNavigator.open("library-ui/window/rename", {
                id: entry.id,
            });
        }
    }

    Connections {
        target: documentView.item
        function onDocumentClosed() {
            orientation.requestOrientationCheck();
        }
    }

    Binding {
        target: documentOrientation
        property: "activeDocumentOrientation"
        value: {
            if (documentView.visible) {
                return documentView.item?.documentOrientation;
            } else {
                return Qt.Vertical;
            }
        }
    }

    Component.onCompleted: {
        Values.accessibilityRightHanded = Settings.rightHandMode;
        Values.accessibilityMode = Settings.accessibilityMode;
        ArkTokens.Settings.accessibility = Settings.accessibilityMode;
        ArkTokens.Settings.landscape = Qt.binding(() => { return !orientation.isPortraitOrientation; });

        Values._rootSize = Qt.binding(() => { return Qt.size(root.width, root.height); });
        Values.isPortraitOrientation = Qt.binding(() => { return orientation.isPortraitOrientation; });

        Values.navigatorContentGridItemLabelHeight =
                Qt.binding(() => Values.accessibilityMode ? 95 : 80);

        root.documentState.globalGesturesDisabled = Qt.binding(() => documentView.item?.hasCustomGestures)
    }

    function openDocument_helper(entry, openCall) {
        if (documentView.status !== Loader.Ready) {
            // In case we try opening a document before Loader is ready
            documentView.deferOpenEntry = entry;
            documentView.deferCallback = openCall;
            return;
        }

        const shareEmailPath = "sendmail/window/email-dialog";
        if (root.windowLayout?.contains(shareEmailPath)) {
            root.windowNavigator.close(shareEmailPath);
        }

        if (entry.archived) {
            if (!Authentication.loggedIn) {
                root.notificationQueue.enqueue({
                    "text": qsTr("Unable to retrieve without a cloud connection"),
                    "icon": "qrc:/ark/icons/cloud_x",
                    "timeout": 3000
                });
            } else {
                root.explorer.requestLocality(entry.id, ISelectiveSync.Locality.Synced);
            }
        } else if (entry.loadError && entry.loadErrorType !== DocumentIO.LoadErrorType.PotentiallyUnstable) {
            if (entry.loadErrorType === DocumentIO.LoadErrorType.UnsupportedFormatVersion) {
                windowNavigator.open("document/window/update-software");
            } else {
                windowNavigator.open("document/window/load-error", {reason: entry.loadErrorDescription});
            }
        } else if (entry.lockedByPassword) {
            windowNavigator.open("document/window/unlock", {
                documentToUnlock: entry,
                action: (password) => {
                    documentView.item.password = password;
                    openCall();
                }
            });
        } else {
            openCall();
        }
    }


    FocusScope {
        id: rootItem
        focus: true
        anchors.fill: parent
        visible: BatteryManager.displayState !== BatteryManager.DeepSleep

        // Global shortcuts
        Shortcut {
            sequence: "Ctrl+Shift+S"
            enabled: !Settings.isDevice
            onActivated: RetailDemo.pendingLibraryReset();
        }


        function retailDemoReset() {
            const carouselPath = "retail/window/carousel";
            if (!windowLayout.contains(carouselPath)) {
                windowNavigator.open(carouselPath, { screensaverPaths: RetailDemo.screensaverPaths });
            }

            // Reset settings
            root.passcodeHandler.unlock();
            OnboardingManager.setCompletedForAllKeys(true);
            OnboardingManager.setCompletedForKey(OnboardingManager.Group.Tooltips, "", "RetailCreateMenu", false);
            navigator.reset();
            documentView.item?.close();
        }

        Connections {
            target: RetailDemo
            enabled: RetailDemo.enabled
            function onPendingLibraryReset() {
                // Close any access of entries as to not hog it before reset of library
                // Tell RetailDemo when idle
                documentView.item?.close();
                RetailDemo.qmlIsIdle();
            }

            function onResetQmlComponentsToDefault() {
                rootItem.retailDemoReset();
            }
        }

        Connections {
            target: BatteryManager

            function onDisplayStateChanged(previous, next) {
                let isAwake = next === BatteryManager.Normal;
                let wasAwake = previous === BatteryManager.Normal;

                if (isAwake !== wasAwake) {
                    // Clear the screen to avoid leaking contents (when going to sleep),
                    // or to avoid keeping remnants of the sleep screen (when waking up).
                    //
                    // We explicitly want to avoid ghost-busting when we return to
                    // Normal from Standby, as that would make the feature rather
                    // annoying.
                    EPFramebuffer.scheduleGhostRemoval();

                }
            }
        }

        FocusScope {
            id: viewRoot
            focus: true

            anchors.fill: parent
            states: [
                State {
                    name: "UnlockDialog"
                    when: root.passcodeHandler.userLocked
                    PropertyChanges {
                        target: navigator
                        visible: false
                    }
                    PropertyChanges {
                        target: ScreenShare
                        allowUpdates: false
                    }
                },
                State {
                    name: "DocumentView"
                    when: documentView.item.documentLoaded
                    PropertyChanges {
                        target: documentView
                        visible: true
                    }
                    PropertyChanges {
                        target: navigator
                        visible: false
                    }
                }
            ]


            Navigator {
                id: navigator
                anchors.fill: parent
                statusIndicators: root.statusIndicators
                createWidgets: root.createWidgets
                windowNavigator: root.windowNavigator
                focus: visible && !_popupOverlay.active
                popupOverlay: _popupOverlay
                movePageSelection: root.pageSelection
                orientation: root.orientation
                retailSettings: RetailDemo.settings
                notificationQueue: root.notificationQueue
                searchIndexStatus: root.searchIndexStatus
                analytics: root.analytics

                onRequestOpenDocumentOnPage: (entry, page) => {
                    windowNavigator.open("legacydevice/window/main", { documentId: entry.id, page: page });
                }

                Component.onCompleted: {
                    documentView.sourceComponent = documentViewComponent;
                    // library is ready at this point due to module awaiting ready
                }
            }

            Loader {
                objectName: "DocumentView"
                id: documentView
                asynchronous: true
                visible: false
                focus: visible
                anchors.centerIn: parent
                width: rootItem.width
                height: rootItem.height
                Component.onCompleted: Global.documentViewLoader = documentView
                Component.onDestruction: Global.documentViewLoader = null

                // For when we try opening a document before the loader is ready
                property var deferOpenEntry: null
                property var deferCallback: () => { documentView.item.openDocument(deferOpenEntry); }
                onLoaded: {
                    if (!!deferOpenEntry) {
                        openDocument_helper(deferOpenEntry, deferCallback);
                        documentView.deferOpenEntry = null;
                    }
                }
            }

            Component {
                id: documentViewComponent
                DocumentView {
                    id: documentViewItem

                    penInput: root.penInput
                    toolbarConfiguration: root.toolbarConfiguration
                    toolbarProvider: root.toolbarProvider
                    documentTelemetry: _documentTelemetry
                    penClose: PenClosenessMonitor.penWasClose
                    textColumn: root.textColumn
                    windowNavigator: root.windowNavigator
                    movePageSelection: root.pageSelection
                    retailSettings: RetailDemo.settings
                    documentDrawerVisible: documentDrawer.visible
                    epubSettings: root.epubSettings
                    orientation: root.orientation
                    shareByUrl: root.shareByUrl
                    searchIndexStatus: root.searchIndexStatus
                    analytics: root.analytics
                    ghostBuster: root.ghostBuster
                    notificationQueue: root.notificationQueue

                    focus: true // Loader is a focus scope. This translates to having focus whenever the loader does.
                    onSearchRequested: {
                        navigator.showSearch();
                    }

                    Connections {
                        target: Library
                        function onEntriesDeleted(ids) {
                            if (document && ids.includes(document.id)) {
                                documentView.item.close();
                            }
                        }
                    }

                    onOpenDocumentDrawer: documentDrawer.show()
                    onDocumentFailedToLoad: (description) => {
                        loadErrorDialog.infoText = description;
                        loadErrorDialog.visible = true;
                    }

                    onCloseQuickSettings: {
                        if (root.windowLayout.contains("settings/window/quicksettings")) {
                            root.windowNavigator.close("settings/window/quicksettings");
                        }
                    }

                    onDocumentChanged: {
                        documentViewListener.openedDocumentId = document ? document.id : "";
                    }

                    SlumberInhibit {
                        id: documentViewSlumberInhibit
                        powerState: PowerState
                        name: "xochitl.document.view"
                        canSuspend: !documentView.visible || !documentViewItem.isLoading
                    }
                }
            }

            DocumentTelemetry {
                id: _documentTelemetry
                document: documentView.item?.document
                dispatcher: Telemetry.Dispatcher

                Component.onCompleted: {
                    closeMethod.setDeviceType(DeviceInfo.deviceType);
                }
            }

            Item {
                id: connectivityNotifierContainer
                anchors.fill: parent

                Header {
                    id: connectivityNotifier

                    width: parent.width
                    blackOnWhite: false
                    timeout: 4000
                    hideOnDismiss: true
                    text: {
                        if (Authentication.loggedIn || (LinkProvider.availability === LinkProvider.Offline)) {
                            //: Logged in or require Wi-Fi; recommended character limit for translation: 30
                            return qsTr("This function requires a network connection")
                        } else {
                            //: Not logged in and does not require Wi-Fi; recommended character limit for translation: 30
                            return qsTr("This function requires a paired account");
                        }
                    }
                    rejectText: qsTr("Cancel")
                    acceptText: qsTr("Open settings")
                    acceptEnabled: true

                    CloseShortcut {
                        onActivated: connectivityNotifier.dismiss()
                    }

                    onAccepted: {
                        // Close open document
                        documentView.item.close();

                        // Show settings
                        if (Authentication.loggedIn || (LinkProvider.availability === LinkProvider.Offline)) {
                            root.windowNavigator.open("settings/window/main", { index: SettingsPage.Wifi });
                        } else {
                            root.windowNavigator.open("settings/window/main", { index: SettingsPage.General });
                        }
                    }
                }
            }

            PopupOverlay {
                id: _popupOverlay

                anchors.fill: parent

                focus: active
            }
        }

        Item {
            id: documentDrawer
            visible: false

            Connections {
                target: root.windowNavigator
                function onWindowOpened(name) {
                    if (name === "documentdrawer/window/main") {
                        documentDrawer.visible = true;
                    }
                }
                function onWindowClosed(name) {
                    if (name === "documentdrawer/window/main") {
                        documentDrawer.visible = false;
                    }
                }
            }

            function hide() {
                root.windowNavigator.close("documentdrawer/window/main");
            }

            function toggle() {
                if (root.windowLayout.contains("documentdrawer/window/main")) {
                    root.windowNavigator.close("documentdrawer/window/main");
                } else {
                    documentDrawer.show();
                }
            }

            function show() {
                let ignoreIds = [];
                let openDocument = documentView.item?.document;
                if (openDocument) {
                    // Filter out currently open document
                    ignoreIds = [openDocument.id];
                }
                windowNavigator.open("documentdrawer/window/main", { ignoreIds: ignoreIds });
            }
        }

        DebugInfo {
            id: debugWindow
            readonly property bool enableSystemInfo: Settings.rawValue("Debug", "SystemInfo") ?? false
            active: enableSystemInfo && documentView.item && !documentView.item.fullscreen
            anchors.bottom: parent.bottom
            anchors.right: parent.right
        }
        Connections {
            target: PowerManager
            function onPowerButtonShortPress() {
                if (RetailDemo.enabled) {
                    RetailDemo.pendingLibraryReset();
                }
                documentView.item?.storeExtraProperties();
            }
        }

        DiskCorruptedDialog {
            anchors.fill: parent
        }

        // Note: FocusItemDebug has moved to the ItemInspector module
        //       and can be activated by Ctrl+Shift+D
    }

    Connections {
        target: Library
        enabled: Library.isReady
        function onEntryAdded(entryId) {
            const entry = Library.entryForId(entryId);
            if (!entry) {
                return;
            }

            if (entry.isMethodsContent && entry.isNew) {
                const entryType = Entry.Type.Document === entry.type ? "workbook" : "template";

                if ("workbook" === entryType) {
                    root.notificationQueue.enqueue({
                        "text": qsTr("\"%1\" was imported as a workbook").arg(entry.visibleName),
                        "icon": "qrc:/ark/icons/document",
                        //: Recommended character limit for translation: 10
                        "actionText": qsTr("<b>Open</b>"),
                        "onClicked": () => openDocument_helper(entry, () => documentView.item.openDocument(entry)),
                        "timeout": 5000,
                    });
                    return;
                }
                if ("template" === entryType) {
                    root.notificationQueue.enqueue({
                        "text": qsTr("\"%1\" was imported as a template").arg(entry.visibleName),
                        "icon": "qrc:/ark/icons/template",
                        //: Recommended character limit for translation: 25
                        "actionText": qsTr("<b>Open in a new notebook</b>"),
                        "onClicked": () => {
                            root.windowNavigator.open("library-ui/window/create-notebook", {
                                currentFolderId: root.explorer.currentFolderId,
                                onCreated: (id) => {
                                    root.windowNavigator.open("legacydevice/window/main", {documentId: id});
                                }
                            });
                        },
                        "timeout": 5000,
                    });
                    return;
                }
            }
        }
    }

    Epaper.ScreenModeItem {
        id: globalScreenMode
        visible: {
            if (!documentView.item) {
                return false;
            }
            const mode = documentView.item.globalScreenMode;
            return mode !== undefined;
        }
        mode: {
            if (documentView.item && documentView.item.globalScreenMode) {
                return documentView.item.globalScreenMode;
            }
            return Epaper.ScreenModeItem.UI;
        }
        anchors.fill: parent
        objectName: "global"
    }
}
