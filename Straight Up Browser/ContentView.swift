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
                            // Background circle - sized to provide 4 points buffer around 18x18 favicon (26x26 circle)
                            Circle()
                                .fill(isSelected ? Color.blue.opacity(0.8) : Color.black.opacity(0.6))
                                .frame(width: 26, height: 26)

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
                                    .foregroundColor(.white)
                            } else {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
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

    // Managers
    @StateObject private var tabManager: TabManager
    @State private var navigationManager: NavigationManager?
    @State private var windowManager: WindowManager?
    @State private var notificationManager: NotificationManager?
    @State private var keyboardShortcutsManager: KeyboardShortcutsManager?
    @State private var bookmarkManager: BookmarkManager?
    @State private var webViewManager: WebViewManager?
    @State private var managersInitialized = false

    // UI State
    @State private var showOmnibar = false
    @State private var currentURL: URL?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var currentTitle = ""
    @State private var isLoading = false
    @State private var isImportBookmarksDialogPresented = false
    @State private var availableBrowsers: [BrowserType] = []
    @State private var showCreateGroupDialog = false
    @State private var newGroupName = ""
    @State private var newGroupColor = Color.blue
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
    @State private var progressTimer: Timer?
    @State private var hasRenderedContent = false

    // Stable URL for WebView binding to prevent constant reloading
    @State private var stableWebViewURL: URL?



    init() {
        // CLI is now initialized lazily when first used
        _tabManager = StateObject(wrappedValue: TabManager())
    }



    private var bookmarks: [Bookmark] {
        return bookmarkManager?.fetchAllBookmarks() ?? []
    }

    private var bookmarkSuggestions: [(title: String, url: URL)] {
        return bookmarks.map { (title: $0.title, url: $0.url) }
    }

    private var groupedTabs: [(group: TabGroup?, tabs: [BrowserTab])] {
        var result: [(group: TabGroup?, tabs: [BrowserTab])] = []

        // Group tabs by groupId
        let groupedById = Dictionary(grouping: tabs) { $0.groupId }

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
                                Logger.log("Tab clicked: \(tab.id), current selectedTabId: \(tabManager.selectedTabId?.uuidString ?? "nil")", type: "ContentView")
                                Logger.log("Setting selectedTabId to: \(tab.id)", type: "ContentView")
                                tabManager.selectedTabId = tab.id
                                Logger.log("After setting, selectedTabId is now: \(tabManager.selectedTabId?.uuidString ?? "nil")", type: "ContentView")
                            },
                            onReorder: { sourceTabId, targetTabId in
                                tabManager.reorderTabs(sourceTabId: sourceTabId, targetTabId: targetTabId, tabs: tabs)
                            }
                        )
                        .contextMenu {
                            Button("Close Tab", action: { tabManager.closeTab(tab, tabs: tabs) })
                            Button("Duplicate Tab", action: { _ = tabManager.duplicateTab(tab) })
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
                        tabs: tabs,
                        selectedTabId: tabManager.selectedTabId,
                        onTabSelect: { tabId in
                            tabManager.selectedTabId = tabId
                        },
                            onReorder: { sourceTabId, targetTabId in
                                tabManager.reorderTabs(sourceTabId: sourceTabId, targetTabId: targetTabId, tabs: tabs)
                            },
                        tabManager: tabManager
                    )
                } else {
                    // Regular tab list view
                    tabListView(geometry: geometry)
                }
            }
            .frame(minWidth: 80)
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
                        onPopupRequest: handlePopupRequest,
                        tabManager: tabManager,
                        tabs: tabs,
                        activeTabId: tabManager.selectedTabId,
                        onURLChange: { newURL in
                            Logger.log("ContentView onURLChange: updating stableWebViewURL to \(newURL?.absoluteString ?? "nil")", type: "ContentView")
                            stableWebViewURL = newURL
                        })
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

    private var webViewURLBinding: Binding<URL?> {
        Binding(
            get: {
                // Use stable URL to prevent constant reloading, but allow WebView interactions
                Logger.log("WebView binding getter: returning stable URL \(stableWebViewURL?.absoluteString ?? "nil")", type: "ContentView")
                return stableWebViewURL
            },
            set: { newURL in
                Logger.log("WebView binding setter: setting stable URL to \(newURL?.absoluteString ?? "nil")", type: "ContentView")
                stableWebViewURL = newURL
                // Only update the tab URL directly, don't call navigateTo to avoid recursion
                if let url = newURL, let activeTab = self.activeTab {
                    Logger.log("WebView binding setter: setting tab URL to \(url.absoluteString) for tab \(activeTab.title)", type: "ContentView")
                    activeTab.url = url
                } else {
                    Logger.log("WebView binding setter: newURL=\(newURL?.absoluteString ?? "nil"), activeTab=\(self.activeTab?.title ?? "nil")", type: "ContentView")
                }
                if let activeTab = self.activeTab {
                    tabManager.updateTabTitle(activeTab)
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
        VStack(spacing: 0) {
            progressBar
            Spacer()
        }
        .edgesIgnoringSafeArea(.top)
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

                    VStack {
                        Spacer()
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
                        Spacer()
                    }
                }
            }
        }
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

    private var mainContent: some View {
        ZStack {
            webViewContent
                .zIndex(0)
        }
        .overlay(progressBarOverlay.zIndex(1))
        .overlay(newTabPageOverlay.zIndex(2))
        .overlay(omnibarOverlay.zIndex(3))
        .overlay(createGroupDialogOverlay.zIndex(4))
        .overlay(saveWorkspaceDialogOverlay.zIndex(5))
        .overlay(importBookmarksDialogOverlay.zIndex(6))
    }

    private var colorScheme: ColorScheme? {
        SettingsManager.shared.colorScheme
    }

    private var progressBar: some View {
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

                // SwiftData is the session store: tabs are already loaded via @Query.
                // Select the tab that was active last time, tabs load lazily on selection.
                if tabs.isEmpty {
                    _ = tabManager.createNewTab()
                } else {
                    tabManager.selectedTabId = tabs.first(where: { $0.isActive })?.id ?? tabs.first?.id
                }
            }

            // Safe to re-run: observer setup is balanced by cleanup/teardown in onDisappear
            notificationManager?.setupNotificationObservers()
            keyboardShortcutsManager?.setupKeyboardShortcuts()
            windowManager?.configureWindow()
        }
        .onChange(of: tabManager.selectedTabId) { oldValue, newValue in
            Logger.log("ContentView onChange selectedTabId: \(oldValue?.uuidString ?? "nil") -> \(newValue?.uuidString ?? "nil")", type: "ContentView")

            // Persist which tab is active so relaunch restores the selection
            tabManager.updateActiveTab(in: tabs)

            // Update the WebViewManager with the new active tab
            webViewManager?.setActiveTab(newValue)
            Logger.log("ContentView onChange: WebViewManager activeWebView set to tab \(newValue?.uuidString ?? "nil")", type: "ContentView")

            // Update stable URL to the URL of the newly selected tab
            if let newTabId = newValue, let activeTab = tabs.first(where: { $0.id == newTabId }) {
                stableWebViewURL = activeTab.url
                Logger.log("ContentView onChange: Updated stableWebViewURL to \(activeTab.url?.absoluteString ?? "nil") for tab \(newTabId)", type: "ContentView")
            } else {
                stableWebViewURL = nil
                Logger.log("ContentView onChange: Cleared stableWebViewURL (no active tab)", type: "ContentView")
            }

            Logger.log("ContentView onChange: completed tab switch to \(newValue?.uuidString ?? "nil")", type: "ContentView")

            if let activeTab = activeTab {
                currentURL = activeTab.url
                Logger.log("ContentView onChange: currentURL set to \(activeTab.url?.absoluteString ?? "nil")", type: "ContentView")
            }
        }
        .onChange(of: isLoading) { oldValue, newValue in
            if newValue {
                // Page started loading
                showProgressBar = false
                hasRenderedContent = false
                progressTimer?.invalidate()

                // Start timer to show progress bar after 500ms
                progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                    if self.isLoading && !self.hasRenderedContent {
                        withAnimation(.easeIn(duration: max(0.02, 0.2))) {
                            self.showProgressBar = true
                        }
                    }
                }
            } else {
                // Page finished loading
                progressTimer?.invalidate()
                progressTimer = nil
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
            // Ensure there's always a selected tab when tabs change
            tabManager.ensureSelectedTab(from: newTabs)
        }
        .onDisappear {
            notificationManager?.cleanup()
            keyboardShortcutsManager?.teardown()
        }
    }

    private func initializeManagers() {
        let webViewManager = WebViewManager()
        let navigationManager = NavigationManager()
        self.webViewManager = webViewManager
        self.navigationManager = navigationManager
        tabManager.setModelContext(modelContext)
        tabManager.setWebViewManager(webViewManager)
        windowManager = WindowManager()
        bookmarkManager = BookmarkManager(modelContext: modelContext)
        managersInitialized = true

        notificationManager = NotificationManager(
            tabManager: tabManager,
            navigationManager: navigationManager,
            webViewManager: webViewManager,
            showOmnibar: $showOmnibar,
            tabs: { self.tabs },
            closeTabAction: { tab, tabs in
                tabManager.closeTab(tab, tabs: tabs)
            },
            createNewTabAction: {
                // Close empty tabs before creating a new one
                let emptyTabs = self.tabs.filter { $0.url == nil }
                for emptyTab in emptyTabs {
                    if emptyTab.id != tabManager.selectedTabId {
                        tabManager.closeTab(emptyTab, tabs: tabs)
                    }
                }

                _ = self.tabManager.createNewTab()
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
                tabManager.closeTab(emptyTab, tabs: tabs)
            }
        }

        _ = tabManager.createNewTab()
        // Show omnibar when creating a new tab
        showOmnibar = true
    }

    private func createTabGroup(name: String, color: Color) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let newGroup = TabGroup(name: trimmedName, color: color, orderIndex: tabGroups.count)
        modelContext.insert(newGroup)
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
        // Try common favicon locations
        let faviconURLs = [
            URL(string: "\(url.scheme ?? "https")://\(url.host ?? "")/favicon.ico"),
            URL(string: "\(url.scheme ?? "https")://\(url.host ?? "")/apple-touch-icon.png")
        ].compactMap { $0 }
        
        // Try each URL
        for faviconURL in faviconURLs {
            URLSession.shared.dataTask(with: faviconURL) { data, response, error in
                
                if let data = data,
                   let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 200,
                   data.count > 0,
                   let _ = NSImage(data: data) {
                    
                    Logger.log("Preloaded favicon for \(url.absoluteString) from \(faviconURL.absoluteString)", type: "ContentView")
                    
                    // Cache the favicon
                    FaviconCache.shared.setFavicon(data, for: url)
                    
                    // Update tab on main thread
                    DispatchQueue.main.async {
                        tab.favicon = data
                    }
                    return
                }
                
                // If this was the last URL and we still don't have a favicon, generate domain initial
                if faviconURL == faviconURLs.last {
                    DispatchQueue.main.async {
                        if tab.favicon == nil, let host = url.host {
                            if let domainInitial = DomainInitialsGenerator.shared.generateInitialImage(for: host) {
                                Logger.log("Generated domain initial for \(host)", type: "ContentView")
                                tab.favicon = domainInitial
                            }
                        }
                    }
                }
            }.resume()
            
            // Only try the first URL for now to avoid multiple requests
            break
        }
    }

    private func loadFaviconsForAllTabs() {
        Logger.log("Loading favicons for all tabs...", type: "ContentView")
        for tab in tabs {
            if let url = tab.url, tab.favicon == nil {
                Logger.log("Checking favicon cache for tab: \(url.absoluteString)", type: "ContentView")

                // First check if we have a favicon cached for this URL
                if let cachedFavicon = FaviconCache.shared.getFavicon(for: url) {
                    Logger.log("Found cached favicon for \(url.absoluteString), setting on tab", type: "ContentView")
                    tab.favicon = cachedFavicon
                } else {
                    Logger.log("No cached favicon for \(url.absoluteString), will load when tab becomes active", type: "ContentView")
                    // For now, we'll load favicons when tabs become active
                    // In the future, we could implement background favicon loading
                }
            } else if tab.favicon != nil {
                Logger.log("Tab \(tab.url?.absoluteString ?? "no url") already has favicon", type: "ContentView")
            }
        }
    }

    private func updateTabTitle(_ tab: BrowserTab) {
        tabManager.updateTabTitle(tab)
    }

    private var activeTab: BrowserTab? {
        let active = tabManager.getActiveTab(from: tabs)
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
            alert.messageText = "No Browsers Found"
            alert.informativeText = "No compatible browsers with bookmarks were found on your system."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func importBookmarks(from browser: BrowserType) {
        isImportBookmarksDialogPresented = false

        let importedBookmarks = BookmarkImporter.importBookmarks(from: browser)
        guard !importedBookmarks.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Bookmarks Found"
            if browser == .safari {
                alert.informativeText = "Safari bookmarks cannot be imported automatically due to macOS privacy restrictions. To import Safari bookmarks:\n\n1. Open Safari\n2. Go to File > Export Bookmarks...\n3. Save the bookmarks as an HTML file\n4. Use a bookmark import tool that supports HTML files"
            } else {
                alert.informativeText = "No bookmarks were found in \(browser.displayName)."
            }
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Import the bookmarks
        for importedBookmark in importedBookmarks {
            _ = bookmarkManager?.addBookmark(
                title: importedBookmark.title,
                url: importedBookmark.url
            )
        }

        // Show success message
        let alert = NSAlert()
        alert.messageText = "Import Complete"
        alert.informativeText = "Successfully imported \(importedBookmarks.count) bookmarks from \(browser.displayName)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func switchToNextTab() {
        tabManager.switchToNextTab(tabs: tabs)
        // TabManager is now observed directly, no manual sync needed
    }

    private func switchToPreviousTab() {
        tabManager.switchToPreviousTab(tabs: tabs)
        // TabManager is now observed directly, no manual sync needed
    }

    private func switchToTab(at index: Int) {
        Logger.log("ContentView switchToTab: switching to index \(index), tabs.count = \(tabs.count)", type: "ContentView")
        for (i, tab) in tabs.enumerated() {
            Logger.log("  Tab \(i): id=\(tab.id), url=\(tab.url?.absoluteString ?? "nil")", type: "ContentView")
        }
        tabManager.switchToTab(at: index, tabs: tabs)
        // Also update our local state
        if index >= 0 && index < tabs.count {
            let targetTabId = tabs[index].id
        Logger.log("Setting selectedTabId to: \(targetTabId)", type: "ContentView")
        // TabManager is updated by switchToTab(at:) method, no manual sync needed
        }
    }

    private func closeCurrentTab() {
        if let activeTab = activeTab {
            tabManager.closeTab(activeTab, tabs: tabs)
        }
    }

    private func handlePopupRequest(url: URL, windowFeatures: Any?) {
        // Create a new tab for the popup
        let newTab = BrowserTab(title: "Popup", url: url, isActive: false)
        modelContext.insert(newTab)
        tabManager.selectedTabId = newTab.id
    }

}

#Preview {
    ContentView()
        .modelContainer(for: Tab.self, inMemory: true)
}
