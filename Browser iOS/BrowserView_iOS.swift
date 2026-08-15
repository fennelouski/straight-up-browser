//
//  BrowserView_iOS.swift
//  Browser (iPadOS)
//
//  The universal mobile browser: an adaptive tab sidebar plus a full-bleed web view
//  with no persistent chrome — the omnibar is summoned on demand (⌘L / new tab) as
//  a floating overlay and progress shows on the window edges, matching the Mac
//  app's "the web is the app" spirit. Reuses the shared TabManager / WebViewManager
//  / NavigationManager / BookmarkManager exactly as the Mac ContentView does.
//
//  Keyboard commands are posted as notifications by the app's .commands block
//  (BrowserApp_iOS) and handled here — the same decoupling the Mac app uses.
//

import SwiftUI
import SwiftData
import WebKit
import Combine
import GameController  // GCKeyboard: detect a hardware keyboard to gate the touch guide

private enum BrowserAccessibilityFocus_iOS: Hashable {
    case page
    case sidebar
    case omnibar
}

private enum MobileClearRequest_iOS: Identifiable {
    case site(String)
    case session
    case all

    var id: String {
        switch self {
        case .site(let host): "site-\(host)"
        case .session: "session"
        case .all: "all"
        }
    }

    var title: String {
        switch self {
        case .site(let host): "Clear data for \(host)?"
        case .session: "Clear this session’s data?"
        case .all: "Clear all browsing data?"
        }
    }

    var message: String {
        switch self {
        case .site:
            "Removes cookies, cache, and storage for this site in the current session. This can’t be undone."
        case .session:
            "Wipes all cookies, cache, and storage in the current tab’s session. This can’t be undone."
        case .all:
            "Removes cookies, cache, and storage from normal browsing and every container. This can’t be undone."
        }
    }
}

struct BrowserView_iOS: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var externalURLRouter: ExternalURLRouter_iOS
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Tab.orderIndex) private var tabs: [Tab]
    @Query(sort: \TabGroup.orderIndex) private var tabGroups: [TabGroup]
    @Query(sort: \BrowserSession.createdAt) private var browserSessions: [BrowserSession]
    @Query(sort: \Bookmark.createdAt, order: .reverse) private var bookmarks: [Bookmark]
    @Query(sort: \NewspaperArticle.addedAt, order: .reverse)
    private var newspaperArticles: [NewspaperArticle]

    @StateObject private var tabManager = TabManager()
    @ObservedObject private var protectionStore = PageProtectionStore.shared
    @ObservedObject private var browsingHistory = BrowsingHistoryStore.shared
    @ObservedObject private var downloadManager = DownloadManager.shared
    @StateObject private var pageTranslator = PageTranslator()
    @StateObject private var fastForward = FastForward()
    @State private var webViewManager: WebViewManager?
    @State private var navigationManager: NavigationManager?
    @State private var bookmarkManager: BookmarkManager?
    @State private var managersInitialized = false

    // WebView bindings
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var currentTitle = ""
    @State private var isLoading = false
    @State private var progressValue = 0.0
    @State private var hasRenderedContent = false
    @State private var showProgressBar = false

    // Omnibar
    @State private var omnibarText = ""
    @State private var selectedSuggestion = -1
    @FocusState private var omnibarFocused: Bool
    @State private var showOmnibar = false

    @State private var showSidebar = false
    @State private var showShortcutSheet = false
    @State private var showGestureGuide = false
    @State private var showSettings = false
    @State private var showLibrary = false
    @State private var showNewspaper = false
    @State private var showScratchPad = false
    @State private var showDownloads = false
    @State private var librarySection = BrowserLibrarySection.bookmarks
    @State private var downloadFailureMessage: String?
    @State private var pageActionError: String?
    @State private var activityItems: [Any] = []
    @State private var showActivitySheet = false
    @State private var readerPresentation: ReaderPresentation_iOS?
    @State private var clearRequest: MobileClearRequest_iOS?
    @AccessibilityFocusState private var accessibilityFocus:
        BrowserAccessibilityFocus_iOS?

    // Group / workspace dialogs
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var showNewContainer = false
    @State private var newContainerName = ""
    @State private var showSaveWorkspace = false
    @State private var workspaceName = ""
    @State private var savedWorkspaces: [SavedWorkspace] = []
    @State private var containerDeletionError: String?

    @AppStorage("progressBarTop") private var progressBarTop = true
    @AppStorage("progressBarBottom") private var progressBarBottom = false
    @AppStorage("progressBarLeft") private var progressBarLeft = false
    @AppStorage("progressBarRight") private var progressBarRight = false
    @AppStorage("progressFaviconRing") private var progressFaviconRing = false
    @AppStorage("memorySaverEnabled") private var memorySaverEnabled = false
    @AppStorage("theme") private var theme = "System"
    @AppStorage("javaScriptEnabled") private var javaScriptEnabled = true
    @AppStorage("adBlockEnabled") private var adBlockEnabled = false
    @AppStorage("iPadTabRailVisibility") private var tabRailVisibility = TabRailVisibility_iOS.off.rawValue
    @AppStorage("iPadTabRailPortraitEdge") private var tabRailPortraitEdge = PortraitTabRailEdge_iOS.top.rawValue
    @AppStorage("iPadTabRailLandscapeEdge") private var tabRailLandscapeEdge = LandscapeTabRailEdge_iOS.left.rawValue

    // MARK: Derived

    // Working set: persisted (normal/container) tabs plus in-memory incognito tabs.
    // Everything that selects, switches, closes, or renders a tab uses this so
    // incognito tabs (never in @Query) are first-class. Mirrors ContentView.allTabs.
    private var allTabs: [Tab] { tabs + tabManager.incognitoTabs }

    private var activeTab: Tab? { allTabs.first { $0.id == tabManager.selectedTabId } }
    private var supportsSplitPanes: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var isDownloadFailurePresented: Binding<Bool> {
        Binding(
            get: { downloadFailureMessage != nil },
            set: { isPresented in
                if !isPresented {
                    downloadFailureMessage = nil
                }
            }
        )
    }

    private var isContainerDeletionErrorPresented: Binding<Bool> {
        Binding(
            get: { containerDeletionError != nil },
            set: { isPresented in
                if !isPresented {
                    containerDeletionError = nil
                }
            }
        )
    }

    private var pageProtectionSummary: PageProtectionSummary? {
        guard let tab = activeTab, tab.url != nil else { return nil }
        return PageProtectionSummary(
            securityLevel: tab.securityLevel,
            contentBlocking: .resolve(
                enabled: adBlockEnabled,
                active: protectionStore.isContentBlockingActive(for: tab.id)
            ),
            javaScriptEnabled: javaScriptEnabled
        )
    }

    // Tabs shown on this device: drops open-only local closes (their records stay
    // in the cloud so they remain open on your other devices). Incognito isn't
    // synced, so it bypasses the visibility filter and always shows.
    private var visibleTabs: [Tab] { TabSync.visible(tabs) + tabManager.incognitoTabs }
    private var visibleTabOrder: [Tab] {
        BrowserTabOrder.flattened(tabs: visibleTabs, groups: tabGroups)
    }

    // A tab's isolated-session tint (nil for normal): a container's chosen color,
    // or an auto hue for an incognito session.
    private func sessionColor(for tab: Tab) -> Color? {
        switch tab.sessionKind {
        case .normal: return nil
        case .incognito: return tab.sessionId.map(BrowserSession.incognitoColor(for:))
        case .container: return browserSessions.first { $0.id == tab.sessionId }?.color
        }
    }

    private var bookmarkPairs: [(title: String, url: URL)] {
        bookmarks.map { (title: $0.title, url: $0.url) }
    }

    private var suggestions: [Suggestion] {
        guard showOmnibar else { return [] }
        return omnibarSuggestions(
            input: omnibarText,
            tabs: tabs,
            bookmarks: bookmarkPairs,
            durableHistory: browsingHistory.recentVisits.map(\.url)
        )
    }

    private var colorScheme: ColorScheme? {
        switch theme { case "Light": return .light; case "Dark": return .dark; default: return nil }
    }

    private var webViewURLBinding: Binding<URL?> {
        Binding(get: { activeTab?.url },
                set: { if let url = $0 { activeTab?.url = url } })
    }

    private var webViewTitleBinding: Binding<String> {
        Binding(get: { currentTitle },
                set: { currentTitle = $0; activeTab?.title = $0 })
    }

    // MARK: Body

    var body: some View {
        eventContent
    }

    private var browserLayout: some View {
        // Custom immersive layout (not NavigationSplitView, whose detail wouldn't
        // instantiate the WKWebView representable): full-bleed web with the sidebar
        // and omnibar as summoned overlays, so the chrome truly disappears.
        ZStack(alignment: .leading) {
            Color(.systemBackground).ignoresSafeArea()

            if managersInitialized {
                TabWebView(url: webViewURLBinding,
                           canGoBack: $canGoBack,
                           canGoForward: $canGoForward,
                           title: webViewTitleBinding,
                           isLoading: $isLoading,
                           progressValue: $progressValue,
                           hasRenderedContent: $hasRenderedContent,
                           webViewManager: webViewManager,
                           tabManager: tabManager,
                           fastForward: fastForward,
                           tabs: allTabs,
                           activeTabId: tabManager.selectedTabId,
                           splitTabIds: supportsSplitPanes ? tabManager.splitTabIds : [],
                           onURLChange: { _ in },
                           onPageFinished: { pageTranslator.maybeAutoTranslate(webView: $0) })
                    .ignoresSafeArea()
                    .accessibilityHidden(
                        BrowserAccessibility.backgroundIsHidden(
                            sidebarPresented: showSidebar,
                            omnibarPresented: showOmnibar,
                            modalPresented: false
                        )
                    )
                    .accessibilityFocused(
                        $accessibilityFocus,
                        equals: .page
                    )
            }

            EdgeProgressBar(progress: progressValue, show: showProgressBar,
                            top: progressBarTop, bottom: progressBarBottom,
                            left: progressBarLeft, right: progressBarRight)

            // Keep the browser discoverable without giving up its full-screen
            // character. These sit alongside the sensor housing on modern
            // iPhones, and in the same slim top strip on every other device.
            GeometryReader { geometry in
                let railPlacement = desiredTabRailPlacement(for: geometry.size)
                if managersInitialized && !showOmnibar && !showSidebar {
                    topBrowserControls(showsTabsMenu: railPlacement == nil)
                }
                if managersInitialized {
                    adaptiveTabRail(
                        desiredPlacement: showOmnibar || showSidebar ? nil : railPlacement
                    )
                }
            }

            // Touch's stand-in for the keyboard (iPhone has no ⌘L / ⌘T). Hidden
            // whenever the omnibar or sidebar is already up.
            if managersInitialized && !showOmnibar && !showSidebar {
                bottomGestureBar
            }

            // Slide-in tab sidebar (⇧⌘L), dim backdrop, tap-out to close.
            if showSidebar {
                Color.black.opacity(0.25).ignoresSafeArea()
                    .onTapGesture { withAnimation { showSidebar = false } }
                    .accessibilityHidden(true)
                sidebarPanel.transition(.move(edge: .leading))
            }

            if showOmnibar {
                omnibarOverlay.transition(.opacity)
            }
        }
    }

    private var configuredBrowser: some View {
        browserLayout
        .preferredColorScheme(colorScheme)
        .transaction {
            if reduceMotion { $0.disablesAnimations = true }
        }
        // Maximize screen real estate: hide the status bar and auto-hide the home
        // indicator so the web fills every pixel.
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .translationTask(pageTranslator.configuration) { session in
            await pageTranslator.perform(session: session)
        }
        .onAppear(perform: firstAppear)
        .onChange(of: tabManager.selectedTabId) { _, newValue in
            tabManager.updateActiveTab(in: allTabs)
            webViewManager?.setActiveTab(newValue)
            syncOmnibarToActiveTab()
            withAnimation { showSidebar = false }  // picking a tab dismisses the panel
        }
        .onChange(of: activeTab?.url) { _, _ in if !showOmnibar { syncOmnibarToActiveTab() } }
        .onChange(of: showSidebar) { _, isShowing in
            DispatchQueue.main.async {
                accessibilityFocus = isShowing ? .sidebar : .page
            }
        }
        .onChange(of: showOmnibar) { _, isShowing in
            DispatchQueue.main.async {
                accessibilityFocus = isShowing ? .omnibar : .page
            }
        }
        .onChange(of: isLoading) { _, loading in withAnimation { showProgressBar = loading } }
        .onChange(of: tabs) { _, newTabs in
            // Keep restored container tabs' sessions registered, and keep a valid
            // selection across the merged working set (incognito included).
            webViewManager?.syncSessions(from: newTabs)
            tabManager.ensureSelectedTab(from: TabSync.visible(newTabs) + tabManager.incognitoTabs)
        }
        .onChange(of: externalURLRouter.pendingURL) { _, url in
            guard url != nil else { return }
            openPendingExternalURLIfReady()
        }
    }

    private var alertContent: some View {
        configuredBrowser
        .alert("New Group", isPresented: $showNewGroup) {
            TextField("Group name", text: $newGroupName)
            Button("Create") { createGroup(newGroupName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Container", isPresented: $showNewContainer) {
            TextField("Container name", text: $newContainerName)
            Button("Create") { createContainer(newContainerName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("An isolated, persistent session with its own cookies and logins — stay signed in under a different account, side by side.")
        }
        .alert("Save Workspace", isPresented: $showSaveWorkspace) {
            TextField("Workspace name", text: $workspaceName)
            Button("Save") { saveWorkspace(workspaceName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Container Data Couldn’t Be Removed",
            isPresented: isContainerDeletionErrorPresented
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(containerDeletionError ?? "")
        }
        .alert(
            "Download Failed",
            isPresented: isDownloadFailurePresented
        ) {
            Button("View Downloads") { showDownloads = true }
            Button("Dismiss", role: .cancel) {}
        } message: {
            Text(downloadFailureMessage ?? "")
        }
        .alert(
            "Page Action Failed",
            isPresented: Binding(
                get: { pageActionError != nil },
                set: { if !$0 { pageActionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pageActionError ?? "")
        }
        .confirmationDialog(
            clearRequest?.title ?? "Clear Browsing Data?",
            isPresented: Binding(
                get: { clearRequest != nil },
                set: { if !$0 { clearRequest = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Clear Data", role: .destructive) {
                if let request = clearRequest { performClear(request) }
                clearRequest = nil
            }
            Button("Cancel", role: .cancel) { clearRequest = nil }
        } message: {
            Text(clearRequest?.message ?? "")
        }
    }

    private var sheetContent: some View {
        alertContent
        .sheet(isPresented: $showShortcutSheet) { ShortcutCheatSheet_iOS() }
        .sheet(isPresented: $showGestureGuide) {
            GestureGuide_iOS().presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSettings) { Settings_iOS() }
        .sheet(isPresented: $showDownloads) {
            Downloads_iOS()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showActivitySheet) {
            ActivitySheet_iOS(items: activityItems)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $readerPresentation) { presentation in
            ReaderMode_iOS(article: presentation.article, onOpen: openFromLibrary)
        }
        .fullScreenCover(isPresented: $showNewspaper) {
            NewspaperView(
                onOpenOriginal: openFromNewspaper,
                onClose: { showNewspaper = false }
            )
        }
        .sheet(isPresented: $showLibrary) {
            BrowserLibrary_iOS(
                bookmarks: bookmarks,
                initialSection: librarySection,
                onOpen: openFromLibrary,
                onUpdateBookmark: { bookmark, title, url, category in
                    bookmarkManager?.updateBookmark(
                        bookmark,
                        title: title,
                        url: url,
                        category: category
                    )
                },
                onDeleteBookmark: { bookmarkManager?.removeBookmark($0) },
                onImportBookmarks: { bookmarkManager?.importBookmarks($0) ?? 0 },
                onDeleteHistory: removeHistory,
                onClearHistory: clearHistory
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showScratchPad) {
            ScratchPad_iOS(pageTitle: currentTitle, pageURL: activeTab?.url)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var eventContent: some View {
        sheetContent
        // Keyboard commands (posted by BrowserApp_iOS.commands), handled through
        // one merged publisher — a chain of ~16 .onReceive modifiers overwhelms
        // the SwiftUI type-checker.
        .onReceive(commandPublisher) { handleCommand($0) }
        .onChange(of: downloadManager.activeDownloads) { previous, current in
            guard let message = DownloadFailureFeedback.newMessage(
                previous: previous,
                current: current
            ) else { return }
            downloadFailureMessage = message
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoryPressure)) { note in
            handleMemoryPressure(
                critical: note.userInfo?["critical"] as? Bool ?? false
            )
        }
    }

    private var commandPublisher: AnyPublisher<Notification, Never> {
        let center = NotificationCenter.default
        return Publishers.MergeMany(
            BrowserPlatformCommandRegistry.iPadNotificationNames.map {
                center.publisher(for: $0)
            }
        )
        .eraseToAnyPublisher()
    }

    private func handleCommand(_ note: Notification) {
        guard let entry = BrowserPlatformCommandRegistry.iPadEntry(
            notification: note.name,
            userInfo: note.userInfo
        ) else { return }

        switch entry.action {
        case .newTab: createNewTab()
        case .newIncognitoTab: _ = tabManager.createIncognitoTab(); focusOmnibar()
        case .closeTab: closeActiveTab()
        case .closeTabSet: tabManager.closeTabSet(tabs: visibleTabs)
        case .reopenTab: _ = tabManager.reopenLastClosedTab()
        case .openLocation: focusOmnibar()
        case .back: webViewManager?.goBack()
        case .forward: webViewManager?.goForward()
        case .reload: reloadOrStop()
        case .hardReload: webViewManager?.activeWebView?.reloadFromOrigin()
        case .reloadAll: webViewManager?.reloadAllTabs()
        case .findNext: webViewManager?.activeWebView?.findInteraction?.findNext()
        case .findPrevious: webViewManager?.activeWebView?.findInteraction?.findPrevious()
        case .printPage: printActivePage()
        case .exportPDF: exportActivePagePDF()
        case .toggleTranslation:
            pageTranslator.toggle(webView: webViewManager?.activeWebView)
        case .translateInSplit: translateActiveInSplit()
        case .readerMode: showReaderMode()
        case .screenshotVisible: exportSnapshot(fullPage: false)
        case .screenshotFullPage: exportSnapshot(fullPage: true)
        case .nextTab: tabManager.switchToNextTab(tabs: visibleTabOrder)
        case .previousTab: tabManager.switchToPreviousTab(tabs: visibleTabOrder)
        case .switchTab(let index):
            tabManager.switchToTab(at: index - 1, tabs: visibleTabOrder)
        case .addBookmark: toggleBookmark()
        case .showBookmarks: presentLibrary(.bookmarks)
        case .showHistory: presentLibrary(.history)
        case .showDownloads: showDownloads = true
        case .clearSiteData: requestClearSiteData()
        case .convertToIncognito: convertActiveToIncognito()
        case .showAllTabs:
            if !showSidebar { showSidebar = true }
        case .zoomIn: zoom(by: 1.1)
        case .zoomOut: zoom(by: 1 / 1.1)
        case .actualSize: setZoom(1)
        case .toggleSidebar: toggleSidebar()
        case .shortcutOverlay: showShortcutSheet.toggle()
        case .settings: showSettings = true
        case .findInPage:
            presentFindOnPage()
        }
    }

    // MARK: Top browser controls

    private func topBrowserControls(showsTabsMenu: Bool) -> some View {
        TopBrowserControls_iOS(
            activeTab: activeTab,
            showsTabsMenu: showsTabsMenu,
            allowsSplitPanes: supportsSplitPanes,
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            isLoading: isLoading,
            canReopenTab: !tabManager.closedTabs.isEmpty,
            isCurrentBookmarked: isCurrentBookmarked,
            isCurrentInNewspaper: isCurrentInNewspaper,
            actions: browserControlActions
        )
    }

    private var browserControlActions: BrowserControlActions_iOS {
        BrowserControlActions_iOS(
            showTabs: toggleSidebar,
            newTab: createNewTab,
            newRegularTab: createNewRegularTab,
            newIncognitoTab: createNewIncognitoTab,
            reopenTab: { _ = tabManager.reopenLastClosedTab() },
            nextTab: { tabManager.switchToNextTab(tabs: visibleTabOrder) },
            previousTab: { tabManager.switchToPreviousTab(tabs: visibleTabOrder) },
            duplicateTab: duplicateActiveTab,
            toggleSplit: toggleActiveSplit,
            togglePinned: { if let activeTab { togglePinned(activeTab) } },
            toggleMuted: { if let activeTab { toggleMuted(activeTab) } },
            closeTab: closeActiveTab,
            closeTabSet: { tabManager.closeTabSet(tabs: visibleTabs) },
            changeURL: focusOmnibar,
            back: { webViewManager?.goBack() },
            forward: { webViewManager?.goForward() },
            reloadOrStop: reloadOrStop,
            hardReload: { webViewManager?.activeWebView?.reloadFromOrigin() },
            reloadAll: { webViewManager?.reloadAllTabs() },
            find: presentFindOnPage,
            zoomIn: { zoom(by: 1.1) },
            zoomOut: { zoom(by: 1 / 1.1) },
            actualSize: { setZoom(1) },
            readerMode: showReaderMode,
            addToNewspaper: addCurrentPageToNewspaper,
            toggleTranslation: { pageTranslator.toggle(webView: webViewManager?.activeWebView) },
            translateInSplit: translateActiveInSplit,
            toggleBookmark: toggleBookmark,
            shareURL: shareActiveURL,
            sharePageImage: sharePrimaryPageImage,
            sharePageText: sharePageText,
            printPage: printActivePage,
            exportPDF: exportActivePagePDF,
            screenshotVisible: { exportSnapshot(fullPage: false) },
            screenshotFullPage: { exportSnapshot(fullPage: true) },
            screenshotFullPageJPEG: {
                exportSnapshot(fullPage: true, format: .jpeg)
            },
            showBookmarks: { presentLibrary(.bookmarks) },
            showHistory: { presentLibrary(.history) },
            showNewspaper: presentNewspaper,
            showDownloads: { showDownloads = true },
            newContainer: { newContainerName = ""; showNewContainer = true },
            convertToIncognito: convertActiveToIncognito,
            clearSiteData: requestClearSiteData,
            clearSessionData: { clearRequest = .session },
            clearAllData: { clearRequest = .all },
            showSettings: { showSettings = true },
            showShortcuts: { showShortcutSheet = true },
            showGestures: { showGestureGuide = true }
        )
    }

    private func adaptiveTabRail(
        desiredPlacement: TabRailPlacement_iOS?
    ) -> some View {
        AdaptiveTabRail_iOS(
            desiredPlacement: desiredPlacement,
            tabs: visibleTabOrder,
            selectedTabId: tabManager.selectedTabId,
            progressValue: progressValue,
            isLoading: isLoading,
            showFaviconProgress: progressFaviconRing,
            sessionColor: sessionColor,
            onSelect: { tabManager.selectedTabId = $0.id },
            onNewTab: createNewTab,
            onClose: { tabManager.closeTab($0, tabs: visibleTabs) },
            onDuplicate: { _ = tabManager.duplicateTab($0) },
            onTogglePinned: togglePinned,
            onToggleMuted: toggleMuted,
            onToggleSplit: { tabManager.toggleSplitMembership($0, tabs: visibleTabs) },
            onReorder: { source, target in
                tabManager.reorderTabs(sourceTabId: source, targetTabId: target, tabs: visibleTabOrder)
            }
        )
    }

    private func desiredTabRailPlacement(for size: CGSize) -> TabRailPlacement_iOS? {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return nil }
        let isLandscape = size.width > size.height
        let visibility = TabRailVisibility_iOS(rawValue: tabRailVisibility) ?? .off
        guard visibility.isVisible(isLandscape: isLandscape) else { return nil }
        if isLandscape {
            let edge = LandscapeTabRailEdge_iOS(rawValue: tabRailLandscapeEdge) ?? .left
            return edge == .left ? .left : .right
        }
        let edge = PortraitTabRailEdge_iOS(rawValue: tabRailPortraitEdge) ?? .top
        return edge == .top ? .top : .bottom
    }

    // MARK: Sidebar panel (summoned overlay)

    private var sidebarPanel: some View {
        NavigationStack {
            TabSidebar_iOS(
                tabManager: tabManager,
                tabs: visibleTabs,
                tabGroups: tabGroups,
                sessionColor: sessionColor,
                progressValue: progressValue,
                isLoading: isLoading,
                showFaviconProgress: progressFaviconRing,
                downloads: downloadManager.activeDownloads,
                onNewTab: createNewTab,
                onCloseTab: { tabManager.closeTab($0, tabs: visibleTabs) },
                onTogglePinned: togglePinned,
                onToggleMuted: toggleMuted,
                onNewGroup: { newGroupName = ""; showNewGroup = true },
                onDeleteGroup: deleteGroup,
                onMoveTab: { $0.groupId = $1 },
                onSaveWorkspace: { workspaceName = ""; showSaveWorkspace = true },
                onLibrary: { presentLibrary(.bookmarks) },
                onScratchPad: {
                    withAnimation { showSidebar = false }
                    showScratchPad = true
                },
                onDownloads: { showDownloads = true },
                onSettings: { showSettings = true },
                onShortcuts: { showShortcutSheet = true },
                onGestures: { withAnimation { showSidebar = false }; showGestureGuide = true },
                workspaceMenu: AnyView(workspaceMenu),
                containersMenu: AnyView(containersMenu)
            )
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .ignoresSafeArea(edges: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
        .accessibilityIdentifier("browser.tabSidebar")
        .accessibilityAddTraits(.isModal)
        .accessibilityFocused(
            $accessibilityFocus,
            equals: .sidebar
        )
        .onKeyPress(.escape) {
            withAnimation { showSidebar = false }
            return .handled
        }
    }

    // Floating omnibar summoned over the page (the Mac app's model) so the chrome
    // vanishes whenever you're not typing an address.
    private var omnibarOverlay: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture { dismissOmnibar() }
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                omnibarCard
                if !suggestions.isEmpty {
                    SuggestionsPanel(suggestions: suggestions, selectedIndex: selectedSuggestion) { pick in
                        omnibarText = pick.url.absoluteString
                        navigateFromOmnibar()
                    }
                }
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Address and Search")
        .accessibilityAddTraits(.isModal)
        .onKeyPress(.escape) {
            dismissOmnibar()
            return .handled
        }
    }

    private var omnibarCard: some View {
        HStack(spacing: 10) {
            Button { dismissOmnibar(); withAnimation { showSidebar = true } } label: {
                Image(systemName: "square.stack").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Show Tabs")
            if let pageProtectionSummary {
                PageProtectionButton(summary: pageProtectionSummary)
            }
            Image(systemName: isLoading ? "arrow.triangle.2.circlepath" : "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search or enter address", text: $omnibarText)
                .accessibilityIdentifier("browser.omnibar")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .focused($omnibarFocused)
                .onSubmit(navigateFromOmnibar)
                .onKeyPress(.downArrow) {
                    if !suggestions.isEmpty { selectedSuggestion = min(selectedSuggestion + 1, suggestions.count - 1); return .handled }
                    return .ignored
                }
                .onKeyPress(.upArrow) {
                    if selectedSuggestion >= 0 { selectedSuggestion -= 1; return .handled }
                    return .ignored
                }
                .onKeyPress(.escape) { dismissOmnibar(); return .handled }
            if activeTab?.url != nil {
                Button(action: toggleBookmark) {
                    Image(systemName: isCurrentBookmarked ? "star.fill" : "star")
                        .foregroundStyle(isCurrentBookmarked ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(isCurrentBookmarked ? "Remove Bookmark" : "Add Bookmark")
                .accessibilityHint("Change the bookmark for the current page")
            }
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .onChange(of: omnibarText) { _, _ in selectedSuggestion = -1 }
        .accessibilityFocused(
            $accessibilityFocus,
            equals: .omnibar
        )
    }

    // MARK: Bottom gesture bar (touch's stand-in for the keyboard)

    // The one bit of persistent chrome for touch: a slim bottom handle that hosts
    // the gestures a keyboard would drive. Tap → omnibar, swipe up → tab list,
    // swipe ←/→ → next/previous tab, long-press → new tab. Back/forward stay on
    // WebKit's native edge-swipe; reload is pull-to-refresh (see WebView_iOS).
    // ponytail: always visible; auto-hide on scroll-down is the upgrade path if it
    // reads as too much chrome.
    private var bottomGestureBar: some View {
        VStack {
            Spacer()
            Capsule()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 140, height: 5)
                .padding(.vertical, 20)      // at least a 44-point touch target
                .padding(.horizontal, 40)
                .contentShape(Rectangle())
                .onTapGesture { focusOmnibar() }
                .onLongPressGesture(minimumDuration: 0.4) { createNewTab() }
                .highPriorityGesture(DragGesture(minimumDistance: 20).onEnded(handleBarSwipe))
                .accessibilityElement()
                .accessibilityLabel("Browser Controls")
                .accessibilityValue(activeTab?.title ?? activeTab?.url?.host ?? String(localized: "New Tab"))
                .accessibilityHint("Activate for the address bar. Swipe up for tabs, or left and right to change tabs.")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("browser.controls")
                .accessibilityAction { focusOmnibar() }
                .accessibilityAction(named: "New Tab") { createNewTab() }
                .accessibilityAction(named: "Show Tabs") { toggleSidebar() }
                .accessibilityAction(named: "Next Tab") {
                    tabManager.switchToNextTab(tabs: visibleTabOrder)
                }
                .accessibilityAction(named: "Previous Tab") {
                    tabManager.switchToPreviousTab(tabs: visibleTabOrder)
                }
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment:
                        tabManager.switchToNextTab(tabs: visibleTabOrder)
                    case .decrement:
                        tabManager.switchToPreviousTab(tabs: visibleTabOrder)
                    @unknown default:
                        break
                    }
                }
                .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // Dominant axis wins; the thresholds keep a near-still tap from reading as a
    // swipe. ponytail: tune distances on device if the axes misfire.
    private func handleBarSwipe(_ value: DragGesture.Value) {
        let dx = value.translation.width, dy = value.translation.height
        if dy < -30, abs(dy) > abs(dx) {
            toggleSidebar()                                    // up → all tabs
        } else if dx < -30, abs(dx) > abs(dy) {
            tabManager.switchToNextTab(tabs: visibleTabOrder)  // left → next tab
        } else if dx > 30, abs(dx) > abs(dy) {
            tabManager.switchToPreviousTab(tabs: visibleTabOrder)  // right → previous tab
        }
    }

    // MARK: Workspace menu

    @ViewBuilder
    private var workspaceMenu: some View {
        if savedWorkspaces.isEmpty {
            Text("No saved workspaces")
        } else {
            ForEach(savedWorkspaces) { ws in
                Button(ws.name) { loadWorkspace(ws) }
            }
        }
    }

    // Incognito + containers, injected into the sidebar menu (mirrors the Mac's
    // person.2 menu). Incognito is ephemeral; containers are named persistent jars.
    @ViewBuilder
    private var containersMenu: some View {
        Button { _ = tabManager.createIncognitoTab(); focusOmnibar() } label: {
            Label("New Incognito Tab", systemImage: "eye.slash")
        }
        Divider()
        ForEach(browserSessions) { session in
            Menu(session.name) {
                Button("Open Tab") { _ = tabManager.createTab(inheriting: (.container, session.id)); focusOmnibar() }
                Button(role: .destructive) { deleteContainer(session) } label: { Text("Delete Container & Data") }
            }
        }
        if !browserSessions.isEmpty { Divider() }
        Button { newContainerName = ""; showNewContainer = true } label: {
            Label("New Container…", systemImage: "person.2")
        }
    }

    // MARK: Actions

    private func firstAppear() {
        guard !managersInitialized else { return }
        if TabSync.clearLegacySessionStorage(in: tabs) > 0 {
            try? modelContext.save()
        }
        let wvm = WebViewManager()
        webViewManager = wvm
        navigationManager = NavigationManager()
        bookmarkManager = BookmarkManager(modelContext: modelContext)
        tabManager.setModelContext(modelContext)
        tabManager.setWebViewManager(wvm)
        tabManager.fastForward = fastForward
        fastForward.configure(
            tabManager: tabManager,
            webViewManager: wvm,
            tabs: { allTabs }
        )
        // Register restored container tabs' sessions before their web views build,
        // so each resumes in its own data store (not the default one).
        wvm.syncSessions(from: tabs)
        managersInitialized = true
        savedWorkspaces = SavedWorkspace.loadAll()
        if !supportsSplitPanes {
            tabManager.splitTabIds = []
        }

        // An incoming browser URL always wins over onboarding and omnibar focus,
        // including a cold first launch from the system default-browser route.
        let openedExternalURL = openPendingExternalURLIfReady()
        let showingGuide = openedExternalURL ? false : maybeShowGestureGuide()

        if openedExternalURL {
            syncOmnibarToActiveTab()
        } else if visibleTabs.isEmpty {
            let t = tabManager.createNewTab()
            #if DEBUG
            if let url = debugLaunchURL() { t.navigateTo(url) }
            else if !showingGuide { DispatchQueue.main.async { focusOmnibar() } }
            #else
            if !showingGuide { DispatchQueue.main.async { focusOmnibar() } }
            #endif
        } else {
            tabManager.selectedTabId = visibleTabs.first(where: { $0.isActive })?.id ?? visibleTabs.first?.id
            if supportsSplitPanes {
                tabManager.restoreSplit(from: visibleTabs)
            }
            #if DEBUG
            if let url = debugLaunchURL(), let t = visibleTabs.first(where: { $0.id == tabManager.selectedTabId }) { t.navigateTo(url) }
            #endif
            syncOmnibarToActiveTab()
        }
    }

    @discardableResult
    private func openPendingExternalURLIfReady() -> Bool {
        guard managersInitialized,
              let url = externalURLRouter.takePendingURL()
        else { return false }

        let destination: Tab
        if let activeTab, activeTab.url == nil,
           activeTab.sessionKind == .normal {
            destination = activeTab
            destination.navigateTo(url)
            destination.updateTitleFromURL()
        } else {
            destination = tabManager.createNewTab(url: url)
        }
        tabManager.selectedTabId = destination.id
        dismissBrowserOverlaysForExternalNavigation()
        syncOmnibarToActiveTab()
        return true
    }

    private func dismissBrowserOverlaysForExternalNavigation() {
        showSidebar = false
        showOmnibar = false
        showShortcutSheet = false
        showGestureGuide = false
        showSettings = false
        showLibrary = false
        showNewspaper = false
        showDownloads = false
        showActivitySheet = false
        readerPresentation = nil
        clearRequest = nil
        showNewGroup = false
        showNewContainer = false
        showSaveWorkspace = false
        downloadFailureMessage = nil
        pageActionError = nil
        containerDeletionError = nil
    }

    #if DEBUG
    // Test hook: `simctl launch … -openURL https://example.com` loads that page
    // into the initial tab so web rendering can be verified without UI typing.
    private func debugLaunchURL() -> URL? {
        guard let i = CommandLine.arguments.firstIndex(of: "-openURL"), i + 1 < CommandLine.arguments.count else { return nil }
        return URL(string: CommandLine.arguments[i + 1])
    }
    #endif

    // Show the touch guide on first launch when no hardware keyboard is attached
    // (GCKeyboard) — the point is teaching the gestures that replace the chrome,
    // which a keyboard user doesn't need. Shown once; reopen from the sidebar menu.
    // Returns whether it will show, so firstAppear can skip the omnibar auto-focus.
    // ponytail: drop the hasSeenGestureGuide check to show it on every launch.
    @discardableResult
    private func maybeShowGestureGuide() -> Bool {
        guard GCKeyboard.coalesced == nil,
              !UserDefaults.standard.bool(forKey: "hasSeenGestureGuide") else { return false }
        UserDefaults.standard.set(true, forKey: "hasSeenGestureGuide")
        DispatchQueue.main.async { showGestureGuide = true }
        return true
    }

    private func createNewTab() {
        for empty in tabs where empty.url == nil && empty.id != tabManager.selectedTabId {
            tabManager.closeTab(empty, tabs: allTabs)
        }
        // Inherit the active tab's session so a new tab stays in the current
        // container/incognito (a fresh incognito comes from ⇧⌘N).
        _ = tabManager.createTab(inheriting: activeSession())
        focusOmnibar()
    }

    private func createNewRegularTab() {
        _ = tabManager.createNewTab()
        focusOmnibar()
    }

    private func createNewIncognitoTab() {
        _ = tabManager.createIncognitoTab()
        focusOmnibar()
    }

    private func duplicateActiveTab() {
        guard let activeTab else { return }
        _ = tabManager.duplicateTab(activeTab)
    }

    private func toggleActiveSplit() {
        guard supportsSplitPanes, let activeTab else { return }
        tabManager.toggleSplitMembership(activeTab, tabs: visibleTabs)
    }

    private func translateActiveInSplit() {
        guard supportsSplitPanes, let activeTab, let webViewManager else { return }
        pageTranslator.translateIntoSplitPane(
            tab: activeTab,
            tabManager: tabManager,
            webViewManager: webViewManager,
            tabs: visibleTabs
        )
    }

    private func convertActiveToIncognito() {
        guard let activeTab, activeTab.sessionKind != .incognito else { return }
        tabManager.convertToIncognito(activeTab)
    }

    // The active tab's session, so a new tab (⌘T / +) stays in the same container.
    private func activeSession() -> (kind: SessionKind, sessionId: UUID?) {
        guard let active = activeTab else { return (.normal, nil) }
        return (active.sessionKind, active.sessionId)
    }

    private func closeActiveTab() { if let t = activeTab { tabManager.closeTab(t, tabs: visibleTabs) } }

    private func reloadOrStop() {
        if isLoading { webViewManager?.stopLoading() } else { webViewManager?.reload() }
    }

    private func presentFindOnPage() {
        guard let webView = webViewManager?.activeWebView else { return }
        webView.isFindInteractionEnabled = true
        webView.becomeFirstResponder()
        webView.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    private func showReaderMode() {
        guard let webView = webViewManager?.activeWebView else { return }
        webView.evaluateJavaScript(ReaderMode.extractionScript) { value, error in
            if let article = ReaderMode.article(from: value) {
                readerPresentation = ReaderPresentation_iOS(article: article)
            } else {
                pageActionError = error?.localizedDescription
                    ?? String(localized: "This page does not contain readable text.")
            }
        }
    }

    private func addCurrentPageToNewspaper() {
        guard let tab = activeTab else { return }
        guard tab.sessionKind != .incognito else {
            pageActionError = String(localized: "Saving an article would persist its title, source, and readable text. Open it in a regular tab first.")
            return
        }
        guard let url = tab.url,
              url.scheme == "http" || url.scheme == "https",
              let webView = webViewManager?.existingWebView(for: tab.id) else { return }

        let store = NewspaperStore(modelContext: modelContext)
        let result = store.enqueue(url: url, title: tab.title)
        NewspaperCaptureCoordinator.capture(
            result.article,
            from: webView,
            expectedURL: url,
            store: store
        )
    }

    private func printActivePage() {
        guard let webView = webViewManager?.activeWebView else { return }
        MobilePageActions_iOS.printPage(webView)
    }

    private func shareActiveURL() {
        guard let url = webViewManager?.activeWebView?.url ?? activeTab?.url else { return }
        presentExportResult(.success([url]))
    }

    private func sharePrimaryPageImage() {
        guard let webView = webViewManager?.activeWebView else { return }
        MobilePageActions_iOS.exportPrimaryPageImage(webView) { result in
            presentExportResult(result.map { [$0] })
        }
    }

    private func sharePageText() {
        guard let webView = webViewManager?.activeWebView else { return }
        MobilePageActions_iOS.extractPageText(webView) { result in
            presentExportResult(result.map { [$0] })
        }
    }

    private func exportActivePagePDF() {
        guard let webView = webViewManager?.activeWebView else { return }
        MobilePageActions_iOS.exportPDF(webView) { result in
            presentExportResult(result.map { [$0] })
        }
    }

    private func exportSnapshot(
        fullPage: Bool,
        format: MobilePageActions_iOS.ImageFormat = .png
    ) {
        guard let webView = webViewManager?.activeWebView else { return }
        MobilePageActions_iOS.exportSnapshot(
            webView,
            fullPage: fullPage,
            format: format
        ) { result in
            presentExportResult(result.map { [$0] })
        }
    }

    private func presentExportResult(_ result: Result<[Any], Error>) {
        switch result {
        case .success(let items):
            activityItems = items
            showActivitySheet = true
        case .failure(let error):
            pageActionError = error.localizedDescription
        }
    }

    private func requestClearSiteData() {
        guard let host = webViewManager?.activeWebView?.url?.host else { return }
        clearRequest = .site(host)
    }

    private func performClear(_ request: MobileClearRequest_iOS) {
        switch request {
        case .site(let host):
            guard let webView = webViewManager?.activeWebView else { return }
            BrowsingDataCleaner.clearSite(
                host: host,
                in: webView.configuration.websiteDataStore
            ) {
                DispatchQueue.main.async { webView.reloadFromOrigin() }
            }
        case .session:
            guard let webView = webViewManager?.activeWebView else { return }
            BrowsingDataCleaner.clearStore(webView.configuration.websiteDataStore) {
                DispatchQueue.main.async { webView.reloadFromOrigin() }
            }
        case .all:
            BrowsingDataCleaner.clearEverything(
                containerIdentifiers: browserSessions.map(\.id)
            )
        }
    }

    private func focusOmnibar() {
        omnibarText = activeTab?.url?.absoluteString ?? ""
        selectedSuggestion = -1
        withAnimation(.easeOut(duration: 0.15)) { showOmnibar = true }
        DispatchQueue.main.async { omnibarFocused = true }
    }

    private func dismissOmnibar() {
        omnibarFocused = false
        selectedSuggestion = -1
        withAnimation(.easeOut(duration: 0.15)) { showOmnibar = false }
    }

    private func syncOmnibarToActiveTab() {
        omnibarText = activeTab?.url?.absoluteString ?? ""
        selectedSuggestion = -1
    }

    private func navigateFromOmnibar() {
        let text = (selectedSuggestion >= 0 && selectedSuggestion < suggestions.count)
            ? suggestions[selectedSuggestion].url.absoluteString
            : omnibarText
        guard let resolved = OmnibarInput.resolve(text),
              let url = navigationManager?.navigateToURL(resolved, activeTab: activeTab) else { return }
        _ = url
        dismissOmnibar()
    }

    private var isCurrentBookmarked: Bool {
        guard let url = activeTab?.url else { return false }
        return bookmarks.contains { $0.url.absoluteString == url.absoluteString }
    }

    private var isCurrentInNewspaper: Bool {
        guard let url = activeTab?.url else { return false }
        let key = NewspaperStore.sourceKey(for: url)
        return newspaperArticles.contains { $0.sourceKey == key }
    }

    private func toggleBookmark() {
        guard let tab = activeTab, let url = tab.url, let bm = bookmarkManager else { return }
        if let existing = bookmarks.first(where: {
            $0.url.absoluteString == url.absoluteString
        }) {
            bm.removeBookmark(existing)
        } else {
            _ = bm.addBookmark(from: tab)
        }
    }

    private func presentLibrary(_ section: BrowserLibrarySection) {
        librarySection = section
        showSidebar = false
        showLibrary = true
    }

    private func presentNewspaper() {
        showSidebar = false
        showLibrary = false
        showNewspaper = true
    }

    private func openFromNewspaper(_ url: URL) {
        showNewspaper = false
        openFromLibrary(url)
    }

    private func openFromLibrary(_ url: URL) {
        if let activeTab {
            _ = navigationManager?.navigateToURL(url.absoluteString, activeTab: activeTab)
        } else {
            let tab = tabManager.createNewTab()
            _ = navigationManager?.navigateToURL(url.absoluteString, activeTab: tab)
        }
        showLibrary = false
    }

    private func removeHistory(_ url: URL) {
        browsingHistory.remove(url: url)
        BrowserLibrary.removeHistory(url: url, from: tabs)
        try? modelContext.save()
    }

    private func clearHistory() {
        BrowsingDataCleaner.clearHistory(in: tabs)
    }

    private func handleMemoryPressure(critical: Bool) {
        guard memorySaverEnabled else { return }
        let displayedTabIDs = Set(
            tabManager.splitTabIds.count >= 2 && supportsSplitPanes
                ? tabManager.splitTabIds
                : [tabManager.selectedTabId].compactMap { $0 }
        )
        for tab in allTabs where !displayedTabIDs.contains(tab.id)
            && BrowserResourcePolicy.shouldUnload(tab.memoryPolicy, critical: critical) {
            webViewManager?.unloadWebView(for: tab.id)
        }
    }

    private func zoom(by factor: Double) {
        guard let tab = activeTab else { return }
        setZoom(min(3.0, max(0.5, tab.zoomLevel * factor)))
    }

    private func setZoom(_ level: Double) {
        activeTab?.zoomLevel = level
        webViewManager?.activeWebView?.pageZoom = level
    }

    private func togglePinned(_ tab: Tab) {
        tab.isPinned.toggle()
        try? modelContext.save()
    }

    private func toggleMuted(_ tab: Tab) {
        tab.isMuted.toggle()
        webViewManager?.setMuted(tab.isMuted, for: tab.id)
        try? modelContext.save()
    }

    private func toggleSidebar() {
        withAnimation(.easeOut(duration: 0.2)) { showSidebar.toggle() }
    }

    private func createGroup(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        modelContext.insert(TabGroup(name: trimmed, color: .blue, orderIndex: tabGroups.count))
    }

    private func createContainer(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let session = BrowserSession(name: trimmed, color: autoContainerColor(for: trimmed))
        modelContext.insert(session)
        _ = tabManager.createTab(inheriting: (.container, session.id))
        focusOmnibar()
    }

    private func deleteContainer(_ session: BrowserSession) {
        // Close its tabs, forget the definition, and wipe its on-disk jar.
        for tab in tabs where tab.sessionKind == .container && tab.sessionId == session.id {
            tabManager.closeTab(tab, tabs: allTabs)
        }
        let id = session.id
        tabManager.purgeClosedTabs(forSession: id)
        ContainerStoreRemoval.remove(identifier: id) { result in
            switch result {
            case .success:
                modelContext.delete(session)
            case .failure(let error):
                containerDeletionError = error.localizedDescription
            }
        }
    }

    // Auto tint from the name (djb2) so containers read as distinct without a
    // color picker — the alert can't host one. ponytail: add a picker if asked.
    private func autoContainerColor(for name: String) -> Color {
        var hash = 5381
        for scalar in name.unicodeScalars { hash = ((hash << 5) &+ hash) &+ Int(scalar.value) }
        return Color(hue: Double(abs(hash) % 360) / 360.0, saturation: 0.55, brightness: 0.75)
    }

    private func deleteGroup(_ group: TabGroup) {
        for tab in tabs where tab.groupId == group.id { tab.groupId = nil }
        modelContext.delete(group)
    }

    private func saveWorkspace(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        savedWorkspaces.append(SavedWorkspace(name: trimmed, groups: tabGroups, tabs: tabs))
        SavedWorkspace.saveAll(savedWorkspaces)
    }

    private func loadWorkspace(_ workspace: SavedWorkspace) {
        tabManager.discardTabsForWorkspaceLoad(tabs)
        for group in tabGroups { modelContext.delete(group) }
        for sg in workspace.groups {
            let g = TabGroup(name: sg.name, color: Color(hex: sg.colorHex) ?? .blue, orderIndex: sg.orderIndex)
            g.id = sg.id
            modelContext.insert(g)
        }
        var restoredTabs: [Tab] = []
        for st in workspace.tabs {
            let t = st.makeTab()
            modelContext.insert(t)
            restoredTabs.append(t)
        }
        webViewManager?.syncSessions(from: restoredTabs)
        DispatchQueue.main.async {
            tabManager.selectedTabId = (try? modelContext.fetch(FetchDescriptor<Tab>()))?.first?.id
        }
    }
}

// A compact, keyboard-first shortcut reference (⇧⌘H), rendered from the shared
// ShortcutStore so it reflects the current (customizable) bindings.
struct ShortcutCheatSheet_iOS: View {
    @Environment(\.dismiss) private var dismiss
    private let store = ShortcutStore.shared

    var body: some View {
        NavigationStack {
            List {
                ForEach(ShortcutSection.allCases, id: \.self) { section in
                    Section {
                        ForEach(store.cheatRows(for: section)) { row in
                            HStack {
                                Text(row.keys).font(.system(.body, design: .monospaced))
                                    .frame(width: 120, alignment: .leading)
                                Text(row.title).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text(section.title)
                    }
                }
            }
            .navigationTitle("Keyboard Shortcuts")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// The touch cheat sheet: how to drive the chromeless browser with no keyboard.
// Auto-shown on first launch when no hardware keyboard is attached, and reopenable
// from the sidebar menu. Mirrors the handle's gestures in BrowserView_iOS plus the
// native ones (edge-swipe back/forward, pull-to-refresh).
struct GestureGuide_iOS: View {
    @Environment(\.dismiss) private var dismiss

    private struct Move: Identifiable {
        let id = UUID(); let icon: String; let gesture: LocalizedStringKey; let action: LocalizedStringKey
    }
    private let moves: [Move] = [
        .init(icon: "globe",                  gesture: "Tap the site icon",      action: "Show, open, or close tabs"),
        .init(icon: "ellipsis",               gesture: "Tap the page menu",     action: "Navigate, share, find, edit the URL, or lock rotation"),
        .init(icon: "hand.tap",               gesture: "Tap the bar",            action: "Search or type a URL"),
        .init(icon: "square.stack",           gesture: "Swipe up on the bar",    action: "Show all tabs"),
        .init(icon: "arrow.left.arrow.right", gesture: "Swipe the bar sideways", action: "Switch tabs"),
        .init(icon: "plus.square",            gesture: "Long-press the bar",     action: "New tab"),
        .init(icon: "chevron.backward",       gesture: "Swipe from the screen edge", action: "Back and forward"),
        .init(icon: "arrow.clockwise",        gesture: "Pull the page down",     action: "Reload"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("The web fills the whole screen. The two small menus at the top cover everyday browser actions; the handle at the bottom offers quick gestures.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    ForEach(moves) { move in
                        HStack(spacing: 16) {
                            Image(systemName: move.icon)
                                .font(.system(size: 22))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(move.gesture).font(.body.weight(.medium))
                                Text(move.action).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Getting Around")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Got It") { dismiss() } } }
        }
    }
}

// Loading progress drawn on the chosen window edges (top/bottom/left/right) —
// the Mac app's approach, so there's feedback without a chrome bar.
struct EdgeProgressBar: View {
    let progress: Double
    let show: Bool
    let top: Bool, bottom: Bool, left: Bool, right: Bool

    var body: some View {
        GeometryReader { geo in
            if show {
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    if top { bar.frame(width: w * progress, height: 3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
                    if bottom { bar.frame(width: w * progress, height: 3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading) }
                    if left { bar.frame(width: 3, height: h * progress)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
                    if right { bar.frame(width: 3, height: h * progress)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing) }
                }
                .animation(.linear(duration: 0.15), value: progress)
            }
        }
        .allowsHitTesting(false)
    }

    private var bar: some View { Rectangle().fill(Color.accentColor) }
}
