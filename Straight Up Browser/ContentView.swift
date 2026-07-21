//
//  ContentView.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import SwiftData
import AppKit
import WebKit
import Combine
import UniformTypeIdentifiers

// Type alias to disambiguate our Tab model from SwiftUI's Tab view
typealias BrowserTab = Tab

// Floating favicon overlay for compact mode
struct FloatingFaviconOverlay: View {
    let tabs: [BrowserTab]
    let selectedTabId: UUID?
    let onTabSelect: (UUID) -> Void
    let onReorder: ((UUID, UUID) -> Void)?
    let tabManager: TabManager?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(tabs.indices, id: \.self) { index in
                let tab = tabs[index]
                let isSelected = tabManager?.selectedTabId == tab.id

                ZStack {
                    Button(action: {
                        onTabSelect(tab.id)
                    }) {
                        ZStack {
                            // Neutral background so favicons of any color stay
                            // readable; selection is a ring, not a colored fill
                            Circle()
                                .fill(Color(.windowBackgroundColor))
                                .frame(width: 26, height: 26)
                                .overlay(
                                    Circle()
                                        .stroke(isSelected ? Color.blue : Color.gray.opacity(0.4), lineWidth: isSelected ? 2 : 1)
                                )

                            // Favicon or default icon
                            if let faviconData = tab.favicon, let nsImage = NSImage(data: faviconData) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 18, height: 18)
                                    .clipped()
                            } else if tab.url != nil {
                                Image(systemName: "globe")
                                    .font(.system(size: 14))
                                    .foregroundColor(.primary)
                            } else {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 14))
                                    .foregroundColor(.primary)
                            }
                        }
                        .frame(width: 26, height: 26)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .shadow(color: Color.black.opacity(0.3), radius: 2, x: 0, y: 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onDrag {
                    Logger.log("FloatingFaviconOverlay onDrag called for tab: \(tab.id)", type: "ContentView")
                    // Provide the tab ID as the drag item
                    return NSItemProvider(object: tab.id.uuidString as NSString)
                }
                .onDrop(of: [UTType.text], delegate: TabDropDelegate(tabId: tab.id, onReorder: onReorder))
                .contentShape(Rectangle()) // Make the entire area droppable
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 3)
    }
}

// Workspace data structures for persistence
struct SavedWorkspace: Codable, Identifiable {
    let id: UUID
    let name: String
    let createdAt: Date
    let groups: [SavedTabGroup]
    let tabs: [SavedWorkspaceTab]

    init(name: String, groups: [TabGroup], tabs: [BrowserTab]) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.groups = groups.map { SavedTabGroup(from: $0) }
        self.tabs = tabs.map { SavedWorkspaceTab(from: $0) }
    }
}

struct SavedTabGroup: Codable {
    let id: UUID
    let name: String
    let colorHex: String
    let orderIndex: Int

    init(from group: TabGroup) {
        self.id = group.id
        self.name = group.name
        self.colorHex = group.colorHex
        self.orderIndex = group.orderIndex
    }
}

struct SavedWorkspaceTab: Codable {
    let id: UUID
    let title: String
    let urlString: String?
    let groupId: UUID?
    let isPinned: Bool
    let isMuted: Bool
    let zoomLevel: Double
    let orderIndex: Int

    init(from tab: Tab) {
        self.id = tab.id
        self.title = tab.title
        self.urlString = tab.url?.absoluteString
        self.groupId = tab.groupId
        self.isPinned = tab.isPinned
        self.isMuted = tab.isMuted
        self.zoomLevel = tab.zoomLevel
        self.orderIndex = tab.orderIndex
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BrowserTab.orderIndex) private var tabs: [BrowserTab]
    @Query(sort: \TabGroup.orderIndex) private var tabGroups: [TabGroup]
    @Query(sort: \Bookmark.createdAt, order: .reverse) private var allBookmarks: [Bookmark]
    @Query(sort: \BrowserSession.createdAt) private var browserSessions: [BrowserSession]

    // Managers
    @StateObject private var tabManager: TabManager
    @StateObject private var linkPreview = LinkPreviewManager()
    @State private var navigationManager: NavigationManager?
    @State private var notificationManager: NotificationManager?
    @State private var keyboardShortcutsManager: KeyboardShortcutsManager?
    @State private var bookmarkManager: BookmarkManager?
    @State private var webViewManager: WebViewManager?
    @State private var managersInitialized = false

    // UI State
    @State private var showOmnibar = false
    @State private var showFindBar = false
    @State private var findText = ""
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var currentTitle = ""
    @State private var isLoading = false
    @State private var isImportBookmarksDialogPresented = false
    @State private var availableBrowsers: [BrowserType] = []
    @State private var showCreateGroupDialog = false
    @State private var newGroupName = ""
    @State private var newGroupColor = Color.blue
    @State private var showCreateContainerDialog = false
    @State private var newContainerName = ""
    @State private var newContainerColor = Color.purple
    @State private var showWorkspaceMenu = false
    @State private var showSaveWorkspaceDialog = false
    @State private var workspaceName = ""
    @State private var savedWorkspaces: [SavedWorkspace] = []
    @AppStorage("tabBarWidth") private var tabBarWidth: Double = 200.0

    // Force view updates when tab selection changes
    @State private var tabSelectionRefreshTrigger = UUID()
    @State private var tabTitleDisplayRefreshTrigger = UUID()

    // Progress Bar State
    @State private var showProgressBar = false
    @State private var progressValue: Double = 0.0
    @State private var hasRenderedContent = false

    // Which window edges show the load progress bar (any combination)
    @AppStorage("progressBarTop") private var progressBarTop = true
    @AppStorage("progressBarBottom") private var progressBarBottom = false
    @AppStorage("progressBarLeft") private var progressBarLeft = false
    @AppStorage("progressBarRight") private var progressBarRight = false
    // Show progress as a ring around the favicon in the tab bar
    @AppStorage("progressFaviconRing") private var progressFaviconRing = false

    // Memory saving: release background tabs from RAM under memory pressure
    @AppStorage("memorySaverEnabled") private var memorySaverEnabled = false

    // Hold-Cmd+Q-to-quit HUD. quitHoldActive gates the overlay; quitHoldProgress
    // is animated 0→1 by Core Animation over the hold duration.
    @State private var quitHoldProgress: Double = 0
    @State private var quitHoldActive = false

    // Cmd+Shift+H shortcut cheat sheet
    @State private var showShortcutCheatSheet = false

    // Shutter flash marking what a screenshot just captured.
    @State private var flashRect: CGRect?
    @State private var flashOpacity: Double = 0

    private var currentURL: URL? { activeTab?.url }



    init() {
        // CLI is now initialized lazily when first used
        _tabManager = StateObject(wrappedValue: TabManager())
    }

    // MARK: - Memory pressure

    private func handleMemoryPressure(critical: Bool) {
        guard memorySaverEnabled else {
            maybeNudgeMemorySaver()
            return
        }
        // Exempt every displayed tab: in a split, the non-focused panes are
        // visible too and must not go blank under pressure.
        let displayed = displayedTabIds
        for tab in tabs where !displayed.contains(tab.id) && Self.shouldUnload(tab.memoryPolicy, critical: critical) {
            webViewManager?.unloadWebView(for: tab.id)
        }
    }

    // ponytail: macOS only exposes warning/critical, so "always" and "whenNeeded"
    // both release at warning; "lastResort" waits for critical; "never" never.
    static func shouldUnload(_ policy: MemoryPolicy, critical: Bool) -> Bool {
        switch policy {
        case .never: return false
        case .lastResort: return critical
        case .always, .whenNeeded: return true
        }
    }

    // At most once a week, when memory is tight and the feature is off, offer to enable it.
    private func maybeNudgeMemorySaver() {
        let key = "memorySaverPromptLastShown"
        let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 7 * 24 * 3600 else { return }
        UserDefaults.standard.set(Date(), forKey: key)

        let alert = NSAlert()
        alert.messageText = String(localized: "Running low on memory?")
        alert.informativeText = String(localized: "Browser can free up RAM by releasing background tabs you're not using and reloading them instantly when you return. You choose which tabs stay live. Turn on Memory Saving?")
        alert.addButton(withTitle: String(localized: "Enable Memory Saving"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                UserDefaults.standard.set(true, forKey: "memorySaverEnabled")
            }
        }
        if let window = webViewManager?.activeWebView?.window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }



    private var bookmarks: [Bookmark] {
        return bookmarkManager?.fetchAllBookmarks() ?? []
    }

    private var bookmarkSuggestions: [(title: String, url: URL)] {
        return bookmarks.map { (title: $0.title, url: $0.url) }
    }

    // The working set of tabs: persisted normal/container tabs (SwiftData) plus the
    // in-memory incognito tabs. Used for selection, switching, active-tab lookup, the
    // web view coordinator, and rendering — everywhere except SwiftData-only concerns
    // (empty-tab cleanup, workspace save) which stay on `tabs`.
    private var allTabs: [BrowserTab] { tabs + tabManager.incognitoTabs }

    // The tabs visible in the window: the split members, or just the focused tab.
    private var displayedTabIds: [UUID] {
        tabManager.splitTabIds.isEmpty ? [tabManager.selectedTabId].compactMap { $0 } : tabManager.splitTabIds
    }

    // The tint for a tab's isolated session (nil for a normal tab): a container's
    // chosen color, or an auto hue for an incognito session.
    private func sessionColor(for tab: BrowserTab) -> Color? {
        switch tab.sessionKind {
        case .normal: return nil
        case .incognito: return tab.sessionId.map(BrowserSession.incognitoColor(for:))
        case .container: return browserSessions.first { $0.id == tab.sessionId }?.color
        }
    }

    private var groupedTabs: [(group: TabGroup?, tabs: [BrowserTab])] {
        var result: [(group: TabGroup?, tabs: [BrowserTab])] = []

        // Group tabs by groupId (dropping open-only local closes, which keep their
        // CloudKit record so they stay open on other devices). Incognito tabs aren't
        // synced, so they bypass the visibility filter and always show.
        let groupedById = Dictionary(grouping: TabSync.visible(tabs) + tabManager.incognitoTabs) { $0.groupId }

        // Add tabs without groups first (ungrouped tabs)
        if let ungroupedTabs = groupedById[nil] {
            result.append((group: nil, tabs: ungroupedTabs.sorted(by: { $0.orderIndex < $1.orderIndex })))
        }

        // Add tabs with groups
        for group in tabGroups.sorted(by: { $0.orderIndex < $1.orderIndex }) {
            if let groupTabs = groupedById[group.id] {
                result.append((group: group, tabs: groupTabs.sorted(by: { $0.orderIndex < $1.orderIndex })))
            }
        }

        return result
    }

    private var isCurrentPageBookmarked: Bool {
        guard let currentURL = currentURL else { return false }
        return bookmarkManager?.isBookmarked(currentURL) ?? false
    }

    private var tabBarHeaderButtons: some View {
        HStack(spacing: 4) {
            Button(action: createNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Tab")

            Button(action: { showCreateGroupDialog = true }) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Group")

            Menu {
                Button("Save Workspace", action: { showSaveWorkspaceDialog = true })
                Divider()
                ForEach(savedWorkspaces) { workspace in
                    Button(workspace.name) {
                        loadWorkspace(workspace)
                    }
                }
                if savedWorkspaces.isEmpty {
                    Text("No saved workspaces")
                        .foregroundColor(.secondary)
                }
            } label: {
                Image(systemName: "square.stack")
                    .font(.system(size: 12))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("Workspaces")

            Menu {
                Button("New Incognito Tab") {
                    _ = tabManager.createIncognitoTab()
                    showOmnibar = true
                }
                Divider()
                ForEach(browserSessions) { session in
                    Menu(session.name) {
                        Button("Open Tab") {
                            _ = tabManager.createTab(inheriting: (.container, session.id))
                            showOmnibar = true
                        }
                        Button("Delete Container & Data", role: .destructive) {
                            deleteContainer(session)
                        }
                    }
                }
                if !browserSessions.isEmpty { Divider() }
                Button("New Container…") { showCreateContainerDialog = true }
            } label: {
                Image(systemName: "person.2")
                    .font(.system(size: 12))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("Containers & Incognito")

            Spacer(minLength: 0)
        }
        .frame(height: 32)
        .padding(.horizontal, 6)
        .background(Color(.windowBackgroundColor))
        .zIndex(10) // Ensure buttons are above overlay
    }

    private func groupHeaderView(for group: TabGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(group.color)
                    .frame(width: 8, height: 8)
                Text(group.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { deleteGroup(group) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Delete Group")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.controlBackgroundColor).opacity(0.5))
        }
        .padding(.vertical, 2)
    }

    private func tabListView(geometry: GeometryProxy) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                // Add a spacer at the top to allow dragging without scroll interference
                Color.clear.frame(height: 1)
                // Force refresh when tab selection or title display mode changes
                let _ = tabSelectionRefreshTrigger
                let _ = tabTitleDisplayRefreshTrigger
                ForEach(groupedTabs, id: \.group?.id) { groupSection in
                    if let group = groupSection.group {
                        groupHeaderView(for: group)
                    }

                    // Tabs in this group
                    ForEach(groupSection.tabs) { tab in
                        TabRowView(
                            tab: tab,
                            selectedTabId: tabManager.selectedTabId,
                            availableWidth: geometry.size.width,
                            showOnlyIcons: tabBarWidth <= 30,
                            tabBarWidth: tabBarWidth,
                            onSelect: {
                                // Shift-click toggles split pane membership; plain click selects
                                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                                    tabManager.toggleSplitMembership(tab, tabs: allTabs)
                                } else {
                                    Logger.log("Tab clicked: \(tab.id), setting selectedTabId", type: "ContentView")
                                    tabManager.selectedTabId = tab.id
                                }
                            },
                            onReorder: { sourceTabId, targetTabId in
                                tabManager.reorderTabs(sourceTabId: sourceTabId, targetTabId: targetTabId, tabs: allTabs)
                            },
                            loadingProgress: progressFaviconRing && showProgressBar
                                && tab.id == tabManager.selectedTabId ? progressValue : nil,
                            sessionColor: sessionColor(for: tab),
                            isIncognito: tab.sessionKind == .incognito,
                            isDisplayedInSplit: tabManager.splitTabIds.contains(tab.id)
                        )
                        .contextMenu {
                            Button("Close Tab", action: { tabManager.closeTab(tab, tabs: allTabs) })
                            Button("Duplicate Tab", action: { _ = tabManager.duplicateTab(tab) })
                            if tabManager.splitTabIds.contains(tab.id) {
                                Button("Remove from Split", action: { tabManager.toggleSplitMembership(tab, tabs: allTabs) })
                            } else if tabManager.splitTabIds.count < TabManager.maxSplitTabs {
                                Button(tabManager.splitTabIds.isEmpty ? "Open in Split" : "Add to Split",
                                       action: { tabManager.toggleSplitMembership(tab, tabs: allTabs) })
                            }
                            Divider()

                            // Move to group submenu
                            Menu("Move to Group") {
                                Button("Ungrouped") {
                                    moveTabToGroup(tab, groupId: nil)
                                }
                                ForEach(tabGroups.filter { $0.id != groupSection.group?.id }) { availableGroup in
                                    Button(availableGroup.name) {
                                        moveTabToGroup(tab, groupId: availableGroup.id)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var tabSidebar: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Tab bar header with buttons - only show when not in minimal mode
                if tabBarWidth > 30 {
                    tabBarHeaderButtons
                }

                // Tab list or vertical favicon stack
                if tabBarWidth <= 30 {
                    // Vertical favicon stack for compact mode
                    FloatingFaviconOverlay(
                        tabs: allTabs,
                        selectedTabId: tabManager.selectedTabId,
                        onTabSelect: { tabId in
                            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true,
                               let tab = allTabs.first(where: { $0.id == tabId }) {
                                tabManager.toggleSplitMembership(tab, tabs: allTabs)
                            } else {
                                tabManager.selectedTabId = tabId
                            }
                        },
                            onReorder: { sourceTabId, targetTabId in
                                tabManager.reorderTabs(sourceTabId: sourceTabId, targetTabId: targetTabId, tabs: allTabs)
                            },
                        tabManager: tabManager
                    )
                } else {
                    // Regular tab list view
                    tabListView(geometry: geometry)
                }
            }
            // Fill the width the call site sets (32 minimal / max(80, tabBarWidth) otherwise)
            // and pin content to the leading edge. A previous `minWidth: 80` here fought that
            // outer width in minimal mode and, on a persisted view (e.g. compact→minimal),
            // center-aligned the favicons off to the right. ponytail: leading fill, not minWidth.
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.windowBackgroundColor))
            .clipped() // Ensure content doesn't overflow beyond tab bar bounds
        }
        .background(Color(.windowBackgroundColor)) // Solid background to cover web view
    }

    private var webViewContent: some View {
        Group {
            if managersInitialized {
                WebView(url: webViewURLBinding,
                        canGoBack: webViewCanGoBackBinding,
                        canGoForward: webViewCanGoForwardBinding,
                        title: webViewTitleBinding,
                        isLoading: $isLoading,
                        progressValue: $progressValue,
                        hasRenderedContent: $hasRenderedContent,
                        webViewManager: webViewManager,
                        tabManager: tabManager,
                        tabs: allTabs,
                        activeTabId: tabManager.selectedTabId,
                        displayedTabIds: displayedTabIds,
                        onURLChange: { _ in })
                        .allowsHitTesting(true)
                        .focusable(true)
            } else {
                // Show loading state when managers are not yet initialized
                VStack {
                    Image(systemName: "globe")
                        .font(.system(size: 64))
                        .foregroundColor(.gray)
                    Text("Loading...")
                        .font(.title)
                        .foregroundColor(.gray)
                }
            }
        }
    }

    // The active tab's URL is the single source of truth for what the WebView
    // shows. (A separate @State copy meant omnibar/CLI navigation updated the
    // model but never reached the WebView.) WebView.updateNSView dedupes
    // against what the webview already displays, so this can't loop.
    private var webViewURLBinding: Binding<URL?> {
        Binding(
            get: { self.activeTab?.url },
            set: { newURL in
                // Update the tab URL directly, don't call navigateTo to avoid
                // recursion. The title comes from the page via webViewTitleBinding.
                if let url = newURL, let activeTab = self.activeTab {
                    activeTab.url = url
                }
            }
        )
    }

    private var webViewCanGoBackBinding: Binding<Bool> {
        Binding(
            get: { self.webViewManager?.canGoBack ?? false },
            set: { _ in }
        )
    }

    private var webViewCanGoForwardBinding: Binding<Bool> {
        Binding(
            get: { self.webViewManager?.canGoForward ?? false },
            set: { _ in }
        )
    }

    private var webViewTitleBinding: Binding<String> {
        Binding(
            get: { self.currentTitle },
            set: { newTitle in
                self.currentTitle = newTitle
                // Also update the active tab's title
                if let activeTab = self.activeTab {
                    activeTab.title = newTitle
                }
            }
        )
    }

    private var progressBarOverlay: some View {
        ZStack {
            if progressBarTop {
                VStack(spacing: 0) { horizontalProgressBar; Spacer() }
            }
            if progressBarBottom {
                VStack(spacing: 0) { Spacer(); horizontalProgressBar }
            }
            if progressBarLeft {
                HStack(spacing: 0) { verticalProgressBar; Spacer() }
            }
            if progressBarRight {
                HStack(spacing: 0) { Spacer(); verticalProgressBar }
            }
        }
        .edgesIgnoringSafeArea(.all)
    }

    private var newTabPageOverlay: some View {
        Group {
            if activeTab == nil {
                VStack {
                    Image(systemName: "globe")
                        .font(.system(size: 64))
                        .foregroundColor(.gray)
                    Text("New Tab")
                        .font(.title)
                        .foregroundColor(.gray)
                    Text("Press ⌃Space to navigate")
                        .font(.subheadline)
                        .foregroundColor(.gray.opacity(0.8))
                        .padding(.top, 8)
                }
            }
        }
    }

    // Fraction of the window height above the omnibar. Fixed (not centered)
    // so the bar never moves while suggestions appear below it.
    private var omnibarTopFraction: CGFloat {
        switch UserDefaults.standard.string(forKey: "omnibarPosition") {
        case "Top": return 0.08
        case "Center": return 0.45
        default: return 0.25 // "Upper": about 3/4 of the way up the window
        }
    }

    private var omnibarOverlay: some View {
        Group {
            if showOmnibar {
                ZStack {
                    // Background with tap to close
                    Color.black.opacity(0.3)
                        .edgesIgnoringSafeArea(.all)
                        .onTapGesture {
                            showOmnibar = false
                        }

                    GeometryReader { geometry in
                        VStack(spacing: 0) {
                            Spacer()
                                .frame(height: geometry.size.height * omnibarTopFraction)
                            OmnibarView(
                                isPresented: $showOmnibar,
                                urlString: .constant(currentURL?.absoluteString ?? ""),
                                onNavigate: { urlString in
                                    if let navigationManager = navigationManager {
                                        _ = navigationManager.navigateToURL(urlString, activeTab: activeTab)
                                        if let activeTab = activeTab {
                                            tabManager.updateTabTitle(activeTab)
                                        }
                                    }
                                },
                                errorMessage: navigationManager?.omnibarError,
                                tabs: tabs,
                                bookmarkSuggestions: bookmarkSuggestions
                            )
                            .allowsHitTesting(true)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var findBarOverlay: some View {
        Group {
            if showFindBar {
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 4) {
                            OmnibarTextField(
                                text: $findText,
                                placeholder: String(localized: "Find in page"),
                                shouldFocus: true,
                                onCommit: { performFind() },
                                onCancel: {
                                    showFindBar = false
                                    clearFindHighlights()
                                }
                            )
                            .frame(width: 200)

                            Button(action: { performFind(backwards: true) }) {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.plain)
                            .help("Previous Match")

                            Button(action: { performFind() }) {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.plain)
                            .help("Next Match")

                            Button(action: {
                                showFindBar = false
                                clearFindHighlights()
                            }) {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                            .help("Close")
                        }
                        .padding(8)
                        .background(Color(.windowBackgroundColor))
                        .cornerRadius(8)
                        .shadow(radius: 4)
                        .padding(.top, 8)
                        .padding(.trailing, 8)
                    }
                    Spacer()
                }
                .onChange(of: findText) { _, newValue in
                    if newValue.isEmpty {
                        clearFindHighlights() // emptied field: drop the highlight
                    } else {
                        performFind() // incremental find while typing
                    }
                }
            }
        }
    }

    private func performFind(backwards: Bool = false) {
        guard let webView = webViewManager?.activeWebView, !findText.isEmpty else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(findText, configuration: configuration) { result in
            if result.matchFound {
                flashFoundMatch(in: webView)
            }
        }
    }

    // Pulse a ring around the found match so the eye can locate it
    private func flashFoundMatch(in webView: WKWebView) {
        let js = """
        (function() {
            var sel = window.getSelection();
            if (!sel.rangeCount) return;
            var r = sel.getRangeAt(0).getBoundingClientRect();
            var d = document.createElement('div');
            d.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;' +
                'left:' + (r.left - 5) + 'px;top:' + (r.top - 5) + 'px;' +
                'width:' + (r.width + 10) + 'px;height:' + (r.height + 10) + 'px;' +
                'border:2px solid #FFD60A;border-radius:5px;box-shadow:0 0 12px #FFD60A;' +
                'opacity:1;transition:opacity 0.6s ease-out;';
            document.body.appendChild(d);
            setTimeout(function() { d.style.opacity = '0'; }, 400);
            setTimeout(function() { d.remove(); }, 1100);
        })();
        """
        webView.evaluateJavaScript(js)
    }

    // The native find API highlights via the selection; clearing it un-highlights
    private func clearFindHighlights() {
        webViewManager?.activeWebView?.evaluateJavaScript("window.getSelection().removeAllRanges()")
    }

    private var createGroupDialogOverlay: some View {
        Group {
            if showCreateGroupDialog {
                Color.black.opacity(0.5)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        showCreateGroupDialog = false
                    }

                VStack {
                    Spacer()
                    VStack(spacing: 20) {
                        Text("Create Tab Group")
                            .font(.title2)
                            .bold()

                        VStack(spacing: 16) {
                            TextField("Group Name", text: $newGroupName)
                                .textFieldStyle(.roundedBorder)
                                .padding(.horizontal)

                            ColorPicker("Group Color", selection: $newGroupColor)
                                .padding(.horizontal)
                        }

                        HStack(spacing: 16) {
                            Button("Cancel") {
                                showCreateGroupDialog = false
                                newGroupName = ""
                                newGroupColor = Color.blue
                            }
                            .buttonStyle(.bordered)

                            Button("Create") {
                                createTabGroup(name: newGroupName, color: newGroupColor)
                                showCreateGroupDialog = false
                                newGroupName = ""
                                newGroupColor = Color.blue
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(32)
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(12)
                    .shadow(radius: 20)
                    .frame(maxWidth: 300)
                    Spacer()
                }
            }
        }
    }

    private var createContainerDialogOverlay: some View {
        Group {
            if showCreateContainerDialog {
                Color.black.opacity(0.5)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture { showCreateContainerDialog = false }

                VStack {
                    Spacer()
                    VStack(spacing: 20) {
                        Text("New Container")
                            .font(.title2)
                            .bold()

                        Text("An isolated, persistent session with its own cookies and logins — stay signed in under a different account, side by side.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        VStack(spacing: 16) {
                            TextField("Container Name", text: $newContainerName)
                                .textFieldStyle(.roundedBorder)
                                .padding(.horizontal)

                            ColorPicker("Container Color", selection: $newContainerColor)
                                .padding(.horizontal)
                        }

                        HStack(spacing: 16) {
                            Button("Cancel") {
                                showCreateContainerDialog = false
                                newContainerName = ""
                                newContainerColor = Color.purple
                            }
                            .buttonStyle(.bordered)

                            Button("Create") {
                                createContainer(name: newContainerName, color: newContainerColor)
                                showCreateContainerDialog = false
                                newContainerName = ""
                                newContainerColor = Color.purple
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(newContainerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(32)
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(12)
                    .shadow(radius: 20)
                    .frame(maxWidth: 300)
                    Spacer()
                }
            }
        }
    }

    private var saveWorkspaceDialogOverlay: some View {
        Group {
            if showSaveWorkspaceDialog {
                Color.black.opacity(0.5)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        showSaveWorkspaceDialog = false
                    }

                VStack {
                    Spacer()
                    VStack(spacing: 20) {
                        Text("Save Workspace")
                            .font(.title2)
                            .bold()

                        TextField("Workspace Name", text: $workspaceName)
                            .textFieldStyle(.roundedBorder)
                            .padding(.horizontal)

                        HStack(spacing: 16) {
                            Button("Cancel") {
                                showSaveWorkspaceDialog = false
                                workspaceName = ""
                            }
                            .buttonStyle(.bordered)

                            Button("Save") {
                                saveCurrentWorkspace(name: workspaceName)
                                showSaveWorkspaceDialog = false
                                workspaceName = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(32)
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(12)
                    .shadow(radius: 20)
                    .frame(maxWidth: 300)
                    Spacer()
                }
            }
        }
    }


    private var importBookmarksDialogOverlay: some View {
        Group {
            if isImportBookmarksDialogPresented {
                Color.black.opacity(0.5)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        isImportBookmarksDialogPresented = false
                    }

                VStack {
                    Spacer()
                    VStack(spacing: 20) {
                        Text("Import Bookmarks")
                            .font(.title2)
                            .bold()

                        Text("Choose a browser to import bookmarks from:")
                            .multilineTextAlignment(.center)

                        VStack(spacing: 12) {
                            ForEach(availableBrowsers, id: \.self) { browser in
                                Button(action: {
                                    importBookmarks(from: browser)
                                }) {
                                    HStack {
                                        Image(systemName: "globe")
                                            .foregroundColor(.blue)
                                        Text(browser.displayName)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.gray)
                                    }
                                    .padding()
                                    .frame(maxWidth: .infinity)
                                    .background(Color(.controlBackgroundColor))
                                    .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)

                        Button("Cancel") {
                            isImportBookmarksDialogPresented = false
                        }
                        .padding(.top, 8)
                    }
                    .padding(32)
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(12)
                    .shadow(radius: 20)
                    .frame(maxWidth: 400)
                    Spacer()
                }
            }
        }
    }

    private var linkPreviewOverlay: some View {
        Group {
            if linkPreview.isShowing {
                ZStack {
                    Color.black.opacity(0.3)
                        .edgesIgnoringSafeArea(.all)
                        .onTapGesture {
                            linkPreview.dismiss()
                        }

                    StaticWebView(webView: linkPreview.webView)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(radius: 20)
                        .padding(60)
                }
            }
        }
    }

    private var quitHoldOverlay: some View {
        Group {
            if quitHoldActive {
                VStack(spacing: 12) {
                    Text("Keep holding ⌘Q to quit")
                        .font(.headline)
                    ProgressView(value: min(quitHoldProgress, 1))
                        .frame(width: 220)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 10)
            }
        }
    }

    // Screenshot shutter flash, sized to exactly what was captured. The rect
    // arrives in AppKit window coordinates (origin bottom-left); SwiftUI's root
    // fills the same content view but counts y downward, hence the flip.
    private var screenshotFlashOverlay: some View {
        GeometryReader { geo in
            if let rect = flashRect {
                Rectangle()
                    .fill(.white)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: geo.size.height - rect.midY)
                    .opacity(flashOpacity)
            }
        }
        .allowsHitTesting(false)
    }

    private var mainContent: some View {
        ZStack {
            webViewContent
                .zIndex(0)
        }
        .overlay(progressBarOverlay.zIndex(1))
        .overlay(newTabPageOverlay.zIndex(2))
        .overlay(linkPreviewOverlay.zIndex(3))
        .overlay(omnibarOverlay.zIndex(3))
        .overlay(findBarOverlay.zIndex(3))
        .overlay(createGroupDialogOverlay.zIndex(4))
        .overlay(createContainerDialogOverlay.zIndex(4))
        .overlay(saveWorkspaceDialogOverlay.zIndex(5))
        .overlay(importBookmarksDialogOverlay.zIndex(6))
        .overlay(quitHoldOverlay.zIndex(7))
        .overlay(shortcutCheatSheetOverlay.zIndex(8))
        .overlay(alignment: .bottomTrailing, content: { defaultBrowserOverlay.zIndex(9) })
    }

    private var defaultBrowserOverlay: some View {
        Group {
            if tabManager.offerDefaultBrowser {
                DefaultBrowserPrompt { tabManager.offerDefaultBrowser = false }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: tabManager.offerDefaultBrowser)
    }

    // Full shortcut reference, toggled with Cmd+Shift+H (or Esc/click to close)
    private var shortcutCheatSheetOverlay: some View {
        Group {
            if showShortcutCheatSheet {
                ZStack {
                    Color.black.opacity(0.25)
                        .contentShape(Rectangle())
                        .onTapGesture { showShortcutCheatSheet = false }

                    HStack(alignment: .top, spacing: 28) {
                        let sections = ShortcutSection.allCases
                        let mid = (sections.count + 1) / 2
                        ForEach([Array(sections.prefix(mid)), Array(sections.suffix(from: mid))], id: \.first) { column in
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(column, id: \.self) { section in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(section.title)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                            .textCase(.uppercase)
                                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                                            ForEach(ShortcutStore.shared.cheatRows(for: section)) { row in
                                                GridRow {
                                                    CheatSheetTitleCell(row: row)
                                                    CheatSheetKeysCell(row: row)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            .frame(width: 290, alignment: .topLeading)
                        }
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 14)
                }
                .transition(.opacity)
                .onExitCommand { showShortcutCheatSheet = false }
                .onAppear { LiveKeyState.shared.activate() }
                .onDisappear { LiveKeyState.shared.deactivate() }
            }
        }
    }

    private var colorScheme: ColorScheme? {
        SettingsManager.shared.colorScheme
    }

    private var horizontalProgressBar: some View {
        GeometryReader { geometry in
            if showProgressBar {
                ZStack(alignment: .leading) {
                    // Background track
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 1)

                    // Progress fill
                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: max(0, progressValue * geometry.size.width), height: 1)
                        .animation(.linear(duration: max(0.02, 0.1)), value: progressValue)
                }
                .transition(.opacity.animation(.easeIn(duration: max(0.02, 0.2))))
                .frame(height: 1)
            }
        }
        .frame(height: showProgressBar ? 1 : 0)
    }

    // Same bar rotated onto a side edge; fills top-down
    private var verticalProgressBar: some View {
        GeometryReader { geometry in
            if showProgressBar {
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 1)

                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: 1, height: max(0, progressValue * geometry.size.height))
                        .animation(.linear(duration: max(0.02, 0.1)), value: progressValue)
                }
                .transition(.opacity.animation(.easeIn(duration: max(0.02, 0.2))))
                .frame(width: 1)
            }
        }
        .frame(width: showProgressBar ? 1 : 0)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Main content (web view) - render first so it's behind
            HStack(spacing: 0) {
                if tabBarWidth > 0 {
                    Spacer()
                        .frame(width: tabBarWidth <= 30 ? 32 : max(80, tabBarWidth))
                }
                mainContent
                    .clipped()
            }

            // Tab bar - render on top with solid background
            if tabBarWidth > 0 {
                tabSidebar
                    .frame(width: tabBarWidth <= 30 ? 32 : max(80, tabBarWidth))
                    .background(Color(.windowBackgroundColor))
                    .clipped()
            }
        }
        .overlay(
            // Invisible drag handle for resizing tab bar - positioned below button area
            VStack(spacing: 0) {
                // Spacer to skip the button area (32px height + padding)
                Color.clear
                    .frame(height: tabBarWidth <= 30 ? 0 : 38) // Button area height (0 in minimal mode)
                    .allowsHitTesting(false) // Don't block buttons

                // Resize handle only on the right edge of the tab bar (5px wide)
                HStack(spacing: 0) {
                    // Main tab area - allow hits to pass through to buttons
                    Color.clear
                        .frame(width: max(0, (tabBarWidth <= 30 ? 32 : tabBarWidth) - 5))
                        .allowsHitTesting(false) // Don't interfere with tab clicks

                    // Resize handle only on the edge (5px wide)
                    Color.clear
                        .frame(width: 5)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let newWidth = max(0, min(400, tabBarWidth + value.translation.width))
                                    tabBarWidth = newWidth
                                    UserDefaults.standard.set(newWidth, forKey: "tabBarWidth")
                                }
                        )
                        .onHover { isHovering in
                            if isHovering {
                                NSCursor.resizeLeftRight.set()
                            } else {
                                NSCursor.arrow.set()
                            }
                        }

                    Spacer()
                }
                Spacer()
            }
        )
        .preferredColorScheme(colorScheme)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all) // Ignore safe areas to extend to edges
        .background(Color(.windowBackgroundColor)) // Set explicit background
        .overlay(screenshotFlashOverlay)
        .onAppear {
            // One-time setup; onAppear can fire again (window reopen) and must
            // not recreate managers or stack observers
            if !managersInitialized {
                initializeManagers()
                loadWorkspacesFromDisk()

                // Load favicons for all tabs BEFORE web views are loaded
                preloadFaviconsForAllTabs()

                // Setup observer for tab title display mode changes
                NotificationCenter.default.addObserver(
                    forName: .browserTabTitleDisplayModeChanged,
                    object: nil,
                    queue: .main
                ) { [self] _ in
                    tabTitleDisplayRefreshTrigger = UUID()
                }

                // Find in page (Cmd+F)
                NotificationCenter.default.addObserver(
                    forName: .browserFindInPage,
                    object: nil,
                    queue: .main
                ) { [self] _ in
                    showFindBar.toggle()
                    if !showFindBar {
                        clearFindHighlights()
                    }
                }

                // Cmd+G / Cmd+Shift+G cycle through matches
                NotificationCenter.default.addObserver(
                    forName: .browserFindNext,
                    object: nil,
                    queue: .main
                ) { [self] _ in
                    performFind()
                }

                NotificationCenter.default.addObserver(
                    forName: .browserFindPrevious,
                    object: nil,
                    queue: .main
                ) { [self] _ in
                    performFind(backwards: true)
                }

                // Hold-Cmd+Q progress HUD. The manager sends a target and the
                // hold duration; Core Animation sweeps the bar smoothly, so it
                // can't stutter the way the old per-frame feed did.
                NotificationCenter.default.addObserver(
                    forName: .browserQuitHoldProgress,
                    object: nil,
                    queue: .main
                ) { [self] notification in
                    let target = notification.userInfo?["progress"] as? Double ?? 0
                    let duration = notification.userInfo?["duration"] as? Double ?? 0
                    if target > 0 {
                        // Mount the HUD at 0, then animate to full next tick — a
                        // freshly inserted view won't animate from a value it
                        // never had, so it would otherwise snap straight to full.
                        quitHoldActive = true
                        quitHoldProgress = 0
                        DispatchQueue.main.async {
                            withAnimation(.linear(duration: duration)) { quitHoldProgress = 1 }
                        }
                    } else {
                        quitHoldActive = false
                        quitHoldProgress = 0
                    }
                }

                // Screenshot shutter flash
                NotificationCenter.default.addObserver(
                    forName: .browserScreenshotFlash,
                    object: nil,
                    queue: .main
                ) { [self] notification in
                    guard let rect = notification.userInfo?["rect"] as? CGRect else { return }
                    flashRect = rect
                    flashOpacity = 0.8
                    withAnimation(.easeOut(duration: 0.22)) { flashOpacity = 0 }
                }

                // Cmd+Shift+H shortcut cheat sheet
                NotificationCenter.default.addObserver(
                    forName: .browserToggleShortcutOverlay,
                    object: nil,
                    queue: .main
                ) { [self] _ in
                    showShortcutCheatSheet.toggle()
                }

                // Toggle tab bar between hidden and last visible width (Cmd+Shift+L)
                NotificationCenter.default.addObserver(
                    forName: .browserToggleTabBar,
                    object: nil,
                    queue: .main
                ) { [self] _ in
                    if tabBarWidth > 0 {
                        UserDefaults.standard.set(tabBarWidth, forKey: "lastTabBarWidth")
                        tabBarWidth = 0
                    } else {
                        let last = UserDefaults.standard.double(forKey: "lastTabBarWidth")
                        tabBarWidth = last > 0 ? last : 200
                    }
                }

                // Privacy & session commands (Privacy menu + ⇧⌘N / ⇧⌘E)
                NotificationCenter.default.addObserver(forName: .browserNewIncognitoTab, object: nil, queue: .main) { [self] _ in
                    _ = tabManager.createIncognitoTab()   // fresh, isolated private session
                    showOmnibar = true
                }
                NotificationCenter.default.addObserver(forName: .browserNewRegularTab, object: nil, queue: .main) { [self] _ in
                    _ = tabManager.createNewTab()          // force a normal tab, leaving any session
                    showOmnibar = true
                }
                NotificationCenter.default.addObserver(forName: .browserConvertTabToIncognito, object: nil, queue: .main) { [self] _ in
                    if let tab = allTabs.first(where: { $0.id == tabManager.selectedTabId }) {
                        tabManager.convertToIncognito(tab)
                    }
                }
                NotificationCenter.default.addObserver(forName: .browserClearSiteData, object: nil, queue: .main) { [self] _ in
                    clearActiveSite()
                }
                NotificationCenter.default.addObserver(forName: .browserClearSessionData, object: nil, queue: .main) { [self] _ in
                    clearActiveSession()
                }
                NotificationCenter.default.addObserver(forName: .browserClearAllData, object: nil, queue: .main) { [self] _ in
                    clearAllData()
                }

                // SwiftData is the session store: tabs are already loaded via @Query.
                // Register any restored container tabs' sessions before they activate.
                webViewManager?.syncSessions(from: tabs)
                // Select the tab that was active last time, tabs load lazily on selection.
                if tabs.isEmpty {
                    _ = tabManager.createNewTab()
                } else {
                    tabManager.selectedTabId = tabs.first(where: { $0.isActive })?.id ?? tabs.first?.id
                    // Restore last session's split (drops ids that no longer resolve)
                    tabManager.restoreSplit(from: tabs)
                }
            }

            // Safe to re-run: observer setup is balanced by cleanup/teardown in onDisappear
            notificationManager?.setupNotificationObservers()
            keyboardShortcutsManager?.setupKeyboardShortcuts()
        }
        .onChange(of: tabManager.selectedTabId) { oldValue, newValue in
            Logger.log("ContentView onChange selectedTabId: \(oldValue?.uuidString ?? "nil") -> \(newValue?.uuidString ?? "nil")", type: "ContentView")

            // Persist which tab is active so relaunch restores the selection
            tabManager.updateActiveTab(in: allTabs)

            // Update the WebViewManager with the new active tab. The WebView's
            // URL binding reads from the active tab, so nothing else to sync.
            webViewManager?.setActiveTab(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoryPressure)) { note in
            let critical = (note.userInfo?["critical"] as? Bool) ?? false
            handleMemoryPressure(critical: critical)
        }
        .onChange(of: isLoading) { oldValue, newValue in
            if newValue {
                // Page started loading: show the loading bar right away
                hasRenderedContent = false
                withAnimation(.easeIn(duration: 0.2)) {
                    showProgressBar = true
                }
            } else {
                // Page finished loading
                if showProgressBar {
                    // First animate progress to 100% if not already complete
                    if progressValue < 1.0 {
                        withAnimation(.linear(duration: max(0.02, 1.0 - progressValue) * 0.1)) {
                            self.progressValue = 1.0
                        }
                        // Then fade out after a brief delay to show 100%
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.easeOut(duration: 0.35)) {
                                self.showProgressBar = false
                            }
                        }
                    } else {
                        // Progress already at 100%, fade out immediately
                        withAnimation(.easeOut(duration: 0.35)) {
                            self.showProgressBar = false
                        }
                    }
                }
            }
        }
        .onChange(of: tabs) { oldTabs, newTabs in
            // Keep container-tab sessions registered, and keep a valid selection across
            // the merged working set (incognito tabs included).
            webViewManager?.syncSessions(from: newTabs)
            tabManager.ensureSelectedTab(from: allTabs)
        }
        .onDisappear {
            notificationManager?.cleanup()
            keyboardShortcutsManager?.teardown()
        }
        // Hides the traffic lights and titlebar on the window actually hosting this
        // view, once it has one — see WindowChrome for why this isn't done at onAppear.
        .background(WindowChrome())
    }

    private func initializeManagers() {
        let webViewManager = WebViewManager()
        let navigationManager = NavigationManager()
        self.webViewManager = webViewManager
        self.navigationManager = navigationManager
        tabManager.setModelContext(modelContext)
        tabManager.setWebViewManager(webViewManager)
        bookmarkManager = BookmarkManager(modelContext: modelContext)
        managersInitialized = true

        notificationManager = NotificationManager(
            tabManager: tabManager,
            navigationManager: navigationManager,
            webViewManager: webViewManager,
            showOmnibar: $showOmnibar,
            tabs: { self.allTabs },
            closeTabAction: { tab, tabs in
                // The omnibar edits the current tab's address; once that tab is
                // gone it's pointing at nothing, so dismiss it with the tab.
                self.showOmnibar = false
                tabManager.closeTab(tab, tabs: tabs)
            },
            createNewTabAction: {
                // Close empty tabs before creating a new one
                let emptyTabs = self.tabs.filter { $0.url == nil }
                for emptyTab in emptyTabs {
                    if emptyTab.id != tabManager.selectedTabId {
                        tabManager.closeTab(emptyTab, tabs: allTabs)
                    }
                }

                // Inherit the active tab's session so Cmd+T stays in the current
                // container/incognito (a fresh incognito comes from ⇧⌘N instead).
                _ = self.tabManager.createTab(inheriting: self.activeSession())
                // Show omnibar when creating a new tab
                self.showOmnibar = true
            },
            setTabBarWidth: { width in
                self.tabBarWidth = width
                UserDefaults.standard.set(width, forKey: "tabBarWidth")
            },
            switchToTabAction: { index in self.switchToTab(at: index) },
            switchToNextTabAction: { self.switchToNextTab() },
            switchToPreviousTabAction: { self.switchToPreviousTab() },
            addBookmarkAction: { self.toggleBookmark() },
            showBookmarksAction: { self.showBookmarks() },
            importBookmarksAction: { self.presentImportBookmarksDialog() }
        )

        keyboardShortcutsManager = KeyboardShortcutsManager(
            showOmnibar: $showOmnibar,
            reloadAction: { self.reload() },
            hardReloadAction: { self.hardReload() },
            reloadAllTabsAction: { self.reloadAllTabs() },
            goBackAction: { self.goBack() },
            goForwardAction: { self.goForward() }
        )
    }

    private func createNewTab() {
        // Close empty tabs before creating a new one
        let emptyTabs = tabs.filter { $0.url == nil }
        for emptyTab in emptyTabs {
            if emptyTab.id != tabManager.selectedTabId {
                tabManager.closeTab(emptyTab, tabs: allTabs)
            }
        }

        // Inherit the active tab's session (matches Cmd+T).
        _ = tabManager.createTab(inheriting: activeSession())
        // Show omnibar when creating a new tab
        showOmnibar = true
    }

    // The active tab's session, so a new tab (Cmd+T / +) stays in the same
    // container/incognito.
    private func activeSession() -> (kind: SessionKind, sessionId: UUID?) {
        guard let active = tabManager.getActiveTab(from: allTabs) else { return (.normal, nil) }
        return (active.sessionKind, active.sessionId)
    }

    // WebKit deletes are irreversible, so warn before any destructive clear.
    private func confirmClear(_ message: String, informative: String, perform: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Clear"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { perform() }
    }

    private func clearActiveSite() {
        guard let webView = webViewManager?.activeWebView, let host = webView.url?.host else { return }
        confirmClear(
            String(localized: "Clear data for \(host)?"),
            informative: String(localized: "Removes cookies, cache, and storage for this site in the current session. This can’t be undone.")
        ) {
            BrowsingDataCleaner.clearSite(host: host, in: webView.configuration.websiteDataStore) {
                DispatchQueue.main.async { webView.reloadFromOrigin() }
            }
        }
    }

    private func clearActiveSession() {
        guard let webView = webViewManager?.activeWebView else { return }
        confirmClear(
            String(localized: "Clear this session’s data?"),
            informative: String(localized: "Wipes all cookies, cache, and storage in the current tab’s session. This can’t be undone.")
        ) {
            BrowsingDataCleaner.clearStore(webView.configuration.websiteDataStore) {
                DispatchQueue.main.async { webView.reloadFromOrigin() }
            }
        }
    }

    private func clearAllData() {
        confirmClear(
            String(localized: "Clear all browsing data?"),
            informative: String(localized: "Removes cookies, cache, and storage for normal browsing. Container sessions keep their own data. This can’t be undone.")
        ) {
            BrowsingDataCleaner.clearDefaultEverything()
        }
    }

    private func createTabGroup(name: String, color: Color) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let newGroup = TabGroup(name: trimmedName, color: color, orderIndex: tabGroups.count)
        modelContext.insert(newGroup)
    }

    private func createContainer(name: String, color: Color) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let session = BrowserSession(name: trimmed, color: color)
        modelContext.insert(session)
        _ = tabManager.createTab(inheriting: (.container, session.id))
        showOmnibar = true
    }

    private func deleteContainer(_ session: BrowserSession) {
        // Close its tabs, forget the definition, and wipe its on-disk jar.
        let toClose = tabs.filter { $0.sessionKind == .container && $0.sessionId == session.id }
        for tab in toClose { tabManager.closeTab(tab, tabs: allTabs) }
        let id = session.id
        modelContext.delete(session)
        WKWebsiteDataStore.remove(forIdentifier: id) { _ in }
    }

    private func deleteGroup(_ group: TabGroup) {
        // Move all tabs in this group to ungrouped
        for tab in tabs where tab.groupId == group.id {
            tab.groupId = nil
        }
        modelContext.delete(group)
    }

    private func moveTabToGroup(_ tab: Tab, groupId: UUID?) {
        tab.groupId = groupId
    }

    private func saveCurrentWorkspace(name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let workspace = SavedWorkspace(name: trimmedName, groups: tabGroups, tabs: tabs)
        savedWorkspaces.append(workspace)
        saveWorkspacesToDisk()
    }

    private func loadWorkspace(_ workspace: SavedWorkspace) {
        // Clear existing tabs and groups
        for tab in tabs {
            modelContext.delete(tab)
        }
        for group in tabGroups {
            modelContext.delete(group)
        }

        // Restore groups
        var restoredGroups: [UUID: TabGroup] = [:]
        for savedGroup in workspace.groups {
            let group = TabGroup(name: savedGroup.name, color: Color(hex: savedGroup.colorHex) ?? Color.blue, orderIndex: savedGroup.orderIndex)
            group.id = savedGroup.id
            modelContext.insert(group)
            restoredGroups[group.id] = group
        }

        // Restore tabs
        for savedTab in workspace.tabs {
            let tab = BrowserTab(title: savedTab.title, url: nil, isActive: false)
            tab.id = savedTab.id
            tab.groupId = savedTab.groupId
            tab.isPinned = savedTab.isPinned
            tab.isMuted = savedTab.isMuted
            tab.zoomLevel = savedTab.zoomLevel
            tab.orderIndex = savedTab.orderIndex

            // Restore URL if valid
            if let urlString = savedTab.urlString, let url = URL(string: urlString) {
                tab.url = url
                tab.historyStrings = [url.absoluteString]
                tab.currentHistoryIndex = 0
            }

            modelContext.insert(tab)
        }

        // Select the first tab if available
        DispatchQueue.main.async {
            if let firstTab = try? modelContext.fetch(FetchDescriptor<Tab>()).first {
                tabManager.selectedTabId = firstTab.id
            }
        }
    }

    private func saveWorkspacesToDisk() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(savedWorkspaces) {
            UserDefaults.standard.set(data, forKey: "saved_workspaces")
            UserDefaults.standard.synchronize()
        }
    }

    private func loadWorkspacesFromDisk() {
        if let data = UserDefaults.standard.data(forKey: "saved_workspaces") {
            let decoder = JSONDecoder()
            if let workspaces = try? decoder.decode([SavedWorkspace].self, from: data) {
                savedWorkspaces = workspaces
            }
        }
    }

    private func preloadFaviconsForAllTabs() {
        Logger.log("Preloading favicons for all tabs before web views are loaded...", type: "ContentView")
        
        for tab in tabs {
            // Skip if tab already has a favicon
            if tab.favicon != nil {
                Logger.log("Tab \(tab.url?.absoluteString ?? "no url") already has favicon", type: "ContentView")
                continue
            }
            
            guard let url = tab.url else {
                // Generate domain initial for tabs without URLs
                if let domainInitial = DomainInitialsGenerator.shared.generateInitialImage(for: "newtab") {
                    tab.favicon = domainInitial
                }
                continue
            }
            
            Logger.log("Preloading favicon for tab: \(url.absoluteString)", type: "ContentView")
            
            // First check cache
            if let cachedFavicon = FaviconCache.shared.getFavicon(for: url) {
                Logger.log("Found cached favicon for \(url.absoluteString), setting on tab", type: "ContentView")
                tab.favicon = cachedFavicon
                continue
            }
            
            // Try to download favicon directly from common location
            preloadFaviconForTab(tab: tab, url: url)
        }
    }
    
    private func preloadFaviconForTab(tab: Tab, url: URL) {
        guard let faviconURL = URL(string: "\(url.scheme ?? "https")://\(url.host ?? "")/favicon.ico") else { return }

        URLSession.shared.dataTask(with: faviconURL) { data, response, error in
            if let data = data,
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200,
               data.count > 0,
               NSImage(data: data) != nil {
                // Cache the favicon and update the tab on the main thread
                FaviconCache.shared.setFavicon(data, for: url)
                DispatchQueue.main.async {
                    tab.favicon = data
                }
                return
            }

            // No favicon.ico: fall back to a generated domain-initial icon
            DispatchQueue.main.async {
                if tab.favicon == nil, let host = url.host,
                   let domainInitial = DomainInitialsGenerator.shared.generateInitialImage(for: host) {
                    tab.favicon = domainInitial
                }
            }
        }.resume()
    }

    private func updateTabTitle(_ tab: BrowserTab) {
        tabManager.updateTabTitle(tab)
    }

    private var activeTab: BrowserTab? {
        let active = tabManager.getActiveTab(from: allTabs)
        if active == nil && tabManager.selectedTabId != nil {
            Logger.log("ContentView activeTab: selectedTabId is \(tabManager.selectedTabId?.uuidString ?? "nil") but no matching tab found in \(tabs.count) tabs", type: "ContentView")
            for tab in tabs {
                Logger.log("  Tab: \(tab.id) - \(tab.title)", type: "ContentView")
            }
        }
        return active
    }




    // WKWebView's back-forward list is the single source of truth;
    // the tab's URL/title update via the navigation delegate.
    private func goBack() {
        webViewManager?.goBack()
    }

    private func goForward() {
        webViewManager?.goForward()
    }

    private func reload() {
        if isLoading {
            webViewManager?.stopLoading()
        } else {
            webViewManager?.reload()
        }
    }

    private func hardReload() {
        // For hard reload, we need to access the active web view directly
        if let webView = webViewManager?.activeWebView {
            webView.reloadFromOrigin()
        }
    }

    private func reloadAllTabs() {
        webViewManager?.reloadAllTabs()
    }

    private func toggleBookmark() {
        guard let activeTab = activeTab,
              let url = activeTab.url,
              let bookmarkManager = bookmarkManager else { return }

        if isCurrentPageBookmarked {
            // Remove bookmark
            if let bookmark = bookmarks.first(where: { $0.url.absoluteString == url.absoluteString }) {
                bookmarkManager.removeBookmark(bookmark)
            }
        } else {
            // Add bookmark
            _ = bookmarkManager.addBookmark(from: activeTab)
        }
    }

    private func showBookmarks() {
        // For now, just show the omnibar - in a full implementation this would show a dedicated bookmarks panel
        showOmnibar = true
    }

    private func presentImportBookmarksDialog() {
        availableBrowsers = BookmarkImporter.detectAvailableBrowsers()
        if !availableBrowsers.isEmpty {
            isImportBookmarksDialogPresented = true
        } else {
            // Show alert that no browsers were found
            let alert = NSAlert()
            alert.messageText = String(localized: "No Browsers Found")
            alert.informativeText = String(localized: "No compatible browsers with bookmarks were found on your system.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
        }
    }

    private func importBookmarks(from browser: BrowserType) {
        isImportBookmarksDialogPresented = false

        let importedBookmarks = BookmarkImporter.importBookmarks(from: browser)
        guard !importedBookmarks.isEmpty else {
            let alert = NSAlert()
            alert.messageText = String(localized: "No Bookmarks Found")
            alert.informativeText = String(localized: "No bookmarks were found in \(browser.displayName).")
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
            return
        }

        // Import the bookmarks (deduped, single save)
        let addedCount = bookmarkManager?.importBookmarks(
            importedBookmarks.map { (title: $0.title, url: $0.url) }
        ) ?? 0

        // Show success message
        let alert = NSAlert()
        alert.messageText = String(localized: "Import Complete")
        // ponytail: simple %lld interpolation, not per-language plural rules — one-time import dialog; add plural variants if it matters
        alert.informativeText = String(localized: "Imported \(addedCount) new bookmarks from \(browser.displayName) (\(importedBookmarks.count - addedCount) already existed).")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    private func switchToNextTab() {
        tabManager.switchToNextTab(tabs: allTabs)
        // TabManager is now observed directly, no manual sync needed
    }

    private func switchToPreviousTab() {
        tabManager.switchToPreviousTab(tabs: allTabs)
        // TabManager is now observed directly, no manual sync needed
    }

    private func switchToTab(at index: Int) {
        Logger.log("ContentView switchToTab: switching to index \(index), tabs.count = \(tabs.count)", type: "ContentView")
        for (i, tab) in tabs.enumerated() {
            Logger.log("  Tab \(i): id=\(tab.id), url=\(tab.url?.absoluteString ?? "nil")", type: "ContentView")
        }
        tabManager.switchToTab(at: index, tabs: allTabs)
        // Also update our local state
        if index >= 0 && index < tabs.count {
            let targetTabId = tabs[index].id
        Logger.log("Setting selectedTabId to: \(targetTabId)", type: "ContentView")
        // TabManager is updated by switchToTab(at:) method, no manual sync needed
        }
    }

    private func closeCurrentTab() {
        if let activeTab = activeTab {
            tabManager.closeTab(activeTab, tabs: allTabs)
        }
    }

}

#Preview {
    ContentView()
        .modelContainer(for: Tab.self, inMemory: true)
}
