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

// Floating favicon overlay for compact mode
struct FloatingFaviconOverlay: View {
    let tabs: [Tab]
    let selectedTabId: UUID?
    let onTabSelect: (UUID) -> Void
    let onReorder: ((UUID, UUID) -> Void)?
    let tabManager: TabManager?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(tabs.indices, id: \.self) { index in
                let tab = tabs[index]
                let isSelected = selectedTabId == tab.id

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
                .onDrag {
                    // Provide the tab ID as the drag item
                    NSItemProvider(object: tab.id.uuidString as NSString)
                }
                .onDrop(of: [UTType.text], delegate: TabDropDelegate(tabId: tab.id, onReorder: onReorder))
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

    init(name: String, groups: [TabGroup], tabs: [Tab]) {
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
    @Query(sort: \Tab.orderIndex) private var tabs: [Tab]
    @Query(sort: \TabGroup.orderIndex) private var tabGroups: [TabGroup]
    @Query(sort: \Bookmark.createdAt, order: .reverse) private var allBookmarks: [Bookmark]

    // Managers
    @State private var tabManager: TabManager?
    @State private var navigationManager: NavigationManager?
    @State private var windowManager: WindowManager?
    @State private var notificationManager: NotificationManager?
    @State private var keyboardShortcutsManager: KeyboardShortcutsManager?
    @State private var crashRecoveryManager: CrashRecoveryManager?
    @State private var bookmarkManager: BookmarkManager?
    @State private var webViewManager: WebViewManager?

    // UI State
    @State private var showOmnibar = false
    @State private var currentURL: URL?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var currentTitle = ""
    @State private var isLoading = false
    @State private var showCrashRecoveryPrompt = false
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



    init() {
        // CLI is now initialized lazily when first used
    }
    
    // WindowAccessor to configure NSWindow when it becomes available
    private struct WindowAccessor: NSViewRepresentable {
        var callback: (NSWindow?) -> Void
        
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            DispatchQueue.main.async {
                self.callback(view.window)
            }
            return view
        }
        
        func updateNSView(_ nsView: NSView, context: Context) {
            DispatchQueue.main.async {
                self.callback(nsView.window)
            }
        }
    }

    @State private var selectedTabId: UUID?


    private var bookmarks: [Bookmark] {
        return bookmarkManager?.fetchAllBookmarks() ?? []
    }

    private var bookmarkSuggestions: [(title: String, url: URL)] {
        return bookmarks.map { (title: $0.title, url: $0.url) }
    }

    private var groupedTabs: [(group: TabGroup?, tabs: [Tab])] {
        var result: [(group: TabGroup?, tabs: [Tab])] = []

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
                            selectedTabId: selectedTabId,
                            availableWidth: geometry.size.width,
                            showOnlyIcons: tabBarWidth <= 30,
                            tabBarWidth: tabBarWidth,
                            onSelect: {
                                print("Tab clicked: \(tab.id), current selectedTabId: \(selectedTabId?.uuidString ?? "nil")")
                                print("Setting selectedTabId to: \(tab.id)")
                                selectedTabId = tab.id
                                tabManager?.selectedTabId = tab.id
                                print("After setting, selectedTabId is now: \(selectedTabId?.uuidString ?? "nil")")
                            },
                            onReorder: { sourceTabId, targetTabId in
                                tabManager?.reorderTabs(sourceTabId: sourceTabId, targetTabId: targetTabId, tabs: tabs)
                            }
                        )
                        .contextMenu {
                            Button("Close Tab", action: { tabManager?.closeTab(tab, tabs: tabs) })
                            Button("Duplicate Tab", action: { _ = tabManager?.duplicateTab(tab) })
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
                        selectedTabId: selectedTabId,
                        onTabSelect: { tabId in
                            selectedTabId = tabId
                            tabManager?.selectedTabId = tabId
                        },
                        onReorder: { sourceTabId, targetTabId in
                            tabManager?.reorderTabs(sourceTabId: sourceTabId, targetTabId: targetTabId, tabs: tabs)
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

    private var mainContent: some View {
        ZStack {
            // Always render WebView to prevent recreation when switching tabs
            WebView(url: Binding(
                get: {
                    let url = self.activeTab?.url
                    print("WebView binding getter: returning URL \(url?.absoluteString ?? "nil")")
                    return url
                },
                set: { newURL in
                    // Only update the tab URL directly, don't call navigateTo to avoid recursion
                    if let url = newURL, let activeTab = self.activeTab {
                        print("WebView binding setter: setting tab URL to \(url.absoluteString)")
                        activeTab.url = url
                    }
                    if let activeTab = self.activeTab {
                        self.tabManager?.updateTabTitle(activeTab)
                    }
                }
            ), canGoBack: Binding(
                get: { self.webViewManager?.canGoBack ?? false },
                set: { _ in }
            ), canGoForward: Binding(
                get: { self.webViewManager?.canGoForward ?? false },
                set: { _ in }
            ), title: Binding(
                get: { self.currentTitle },
                set: { newTitle in
                    self.currentTitle = newTitle
                    // Also update the active tab's title
                    if let activeTab = self.activeTab {
                        activeTab.title = newTitle
                    }
                }
            ), isLoading: $isLoading, progressValue: $progressValue, hasRenderedContent: $hasRenderedContent, webViewManager: webViewManager, onPopupRequest: handlePopupRequest, tabManager: tabManager, tabs: tabs, activeTabId: selectedTabId)
            .clipped() // Ensure WebView doesn't extend beyond bounds
            .overlay(
                // Progress bar at the top
                VStack(spacing: 0) {
                    progressBar
                    Spacer()
                }
                .edgesIgnoringSafeArea(.top)
            )
            .overlay(
                // Show new tab page when no active tab
                Group {
                    if activeTab == nil {
                        VStack {
                            Image(systemName: "globe")
                                .font(.system(size: 64))
                                .foregroundColor(.gray)
                            Text("New Tab")
                                .font(.title)
                                .foregroundColor(.gray)
                            Text("Press ⌥Space to navigate")
                                .font(.subheadline)
                                .foregroundColor(.gray.opacity(0.8))
                                .padding(.top, 8)
                        }
                    }
                }
            )

            // Omnibar overlay
            if showOmnibar {
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
                                tabManager?.updateTabTitle(activeTab!)
                            }
                        },
                        errorMessage: navigationManager!.omnibarError,
                        tabs: tabs,
                        bookmarkSuggestions: bookmarkSuggestions
                    )
                    Spacer()
                }
            }

            // Create Tab Group Dialog
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

            // Save Workspace Dialog
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

            // Crash recovery prompt
            if showCrashRecoveryPrompt {
                Color.black.opacity(0.5)
                    .edgesIgnoringSafeArea(.all)

                VStack {
                    Spacer()
                    VStack(spacing: 20) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)

                        Text("Browser Crash Detected")
                            .font(.title)
                            .fontWeight(.bold)

                        Text("It looks like the browser crashed during your last session. Would you like to restore your previous tabs?")
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        HStack(spacing: 16) {
                            Button("Restore Session") {
                                if let savedSession = crashRecoveryManager?.getSavedSession() {
                                    crashRecoveryManager?.restoreSession(savedSession, in: modelContext)
                                    // Refresh the tabs query by triggering a state update
                                    DispatchQueue.main.async {
                                        if let restoredTabs = try? modelContext.fetch(FetchDescriptor<Tab>()),
                                           let firstTab = restoredTabs.first {
                                            tabManager?.selectedTabId = firstTab.id
                                        }
                                    }
                                }
                                showCrashRecoveryPrompt = false
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Start Fresh") {
                                showCrashRecoveryPrompt = false
                                if tabs.isEmpty {
                                    _ = tabManager?.createNewTab()
                                } else {
                                    tabManager?.selectedTabId = tabs.first?.id
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(32)
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(12)
                    .shadow(radius: 20)
                    Spacer()
                }
            }

            // Import Bookmarks Dialog
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
        .background(WindowAccessor { window in
            guard let window = window else { return }
            // Aggressively configure window to completely remove title bar
            // Following recommendations to eliminate black bar rendering issues
            DispatchQueue.main.async {
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                
                if !window.styleMask.contains(.fullSizeContentView) {
                    window.styleMask.insert(.fullSizeContentView)
                }
                
                // Remove .titled style mask - critical for eliminating black bar
                window.styleMask.remove(.titled)
                
                // Hide all control buttons
                window.standardWindowButton(.closeButton)?.isHidden = true
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                window.standardWindowButton(.zoomButton)?.isHidden = true
                
                // Use very low alpha white instead of clear to avoid rendering artifacts
                window.backgroundColor = NSColor.white.withAlphaComponent(0.00001)
                window.isOpaque = false
                
                // Disable shadow
                window.hasShadow = false
                
                window.isMovableByWindowBackground = true
                
                // Force content view to extend to top
                if let contentView = window.contentView {
                    contentView.wantsLayer = true
                    contentView.frame = window.frame
                }
                
                window.invalidateShadow()
                window.contentView?.needsDisplay = true
                window.display()
            }
        })
        .onAppear {
            initializeManagers()
            loadWorkspacesFromDisk()

            // Load favicons for all tabs BEFORE web views are loaded
            preloadFaviconsForAllTabs()

            // Initialize selectedTabId from tabManager
            if let tabManagerSelectedId = tabManager?.selectedTabId {
                selectedTabId = tabManagerSelectedId
            }

            // Also configure window when view appears (backup method)
            // Aggressively remove title bar completely - remove .titled style mask
            #if os(macOS)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first {
                    window.titleVisibility = .hidden
                    window.titlebarAppearsTransparent = true
                    if !window.styleMask.contains(.fullSizeContentView) {
                        window.styleMask.insert(.fullSizeContentView)
                    }
                    // Remove .titled to eliminate black bar
                    window.styleMask.remove(.titled)
                    
                    window.standardWindowButton(.closeButton)?.isHidden = true
                    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                    window.standardWindowButton(.zoomButton)?.isHidden = true
                    
                    // Use very low alpha white instead of clear
                    window.backgroundColor = NSColor.white.withAlphaComponent(0.00001)
                    window.isOpaque = false
                    window.hasShadow = false
                    
                    window.isMovableByWindowBackground = true
                    
                    // Force content to extend to top
                    if let contentView = window.contentView {
                        contentView.frame = window.frame
                    }
                    
                    window.invalidateShadow()
                    window.contentView?.needsDisplay = true
                    window.display()
                }
            }
            #endif
            notificationManager!.setupNotificationObservers()
            keyboardShortcutsManager!.setupKeyboardShortcuts()
            windowManager!.configureWindow(showTitleBar: false)

            // Setup observer for tab title display mode changes
            NotificationCenter.default.addObserver(
                forName: .browserTabTitleDisplayModeChanged,
                object: nil,
                queue: .main
            ) { [self] _ in
                tabTitleDisplayRefreshTrigger = UUID()
            }

            // First, try to restore normal session from previous app restart
            if let restoredSession = restoreSessionForRestart() {
                print("ContentView onAppear: Restored normal session")
                tabManager?.selectedTabId = restoredSession.selectedTabId
                // Reload favicons after session restoration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    preloadFaviconsForAllTabs()
                }
                // Note: Removed reloadAllTabs() call - tabs should load their content naturally when selected
            }
            // Then check for crash recovery if no normal session was restored
            else if crashRecoveryManager?.shouldOfferRecovery() == true,
               let savedSession = crashRecoveryManager?.getSavedSession(),
               !savedSession.tabs.isEmpty {
                print("ContentView onAppear: Crash detected, showing recovery prompt. Saved session has \(savedSession.tabs.count) tabs")
                showCrashRecoveryPrompt = true
                // Note: Removed reloadAllTabs() call - tabs should load their content naturally when selected
            } else {
                print("ContentView onAppear: No crash detected, normal startup. shouldOfferRecovery=\(crashRecoveryManager?.shouldOfferRecovery() ?? false), hasSavedSession=\(crashRecoveryManager?.getSavedSession() != nil)")
                if tabs.isEmpty {
                    _ = tabManager?.createNewTab()
                } else {
                    tabManager?.selectedTabId = tabs.first?.id
                }
                // Note: Removed reloadAllTabs() call - tabs should load their content naturally when selected
            }

            // Reload all tabs exactly once on app launch
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.reloadAllTabs()
            }
        }
        .onChange(of: selectedTabId) { oldValue, newValue in
            print("ContentView onChange selectedTabId: \(oldValue?.uuidString ?? "nil") -> \(newValue?.uuidString ?? "nil")")

            // Update tabManager to match the new selection (single source of truth is selectedTabId)
            tabManager?.selectedTabId = newValue

            // Update the WebViewManager with the new active tab
            webViewManager?.setActiveTab(newValue)
            print("ContentView onChange: WebViewManager activeWebView set to tab \(newValue?.uuidString ?? "nil")")

            if let activeTab = activeTab {
                currentURL = activeTab.url
                print("ContentView onChange: currentURL set to \(activeTab.url?.absoluteString ?? "nil")")
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
        .onDisappear {
            notificationManager!.cleanup()
            crashRecoveryManager?.cleanup()

            // Save session for normal app restart
            saveSessionForRestart()
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: goBack) {
                    Image(systemName: "arrow.left")
                }
                .disabled(!(activeTab?.canGoBack() ?? false))
                .help("Go Back")

                Button(action: goForward) {
                    Image(systemName: "arrow.right")
                }
                .disabled(!(activeTab?.canGoForward() ?? false))
                .help("Go Forward")

                Button(action: reload) {
                    Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                }
                .help(isLoading ? "Stop Loading" : "Reload")

                Button(action: toggleBookmark) {
                    Image(systemName: isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                }
                .help(isCurrentPageBookmarked ? "Remove Bookmark" : "Add Bookmark")
            }
        }
    }

    private func initializeManagers() {
        webViewManager = WebViewManager()
        tabManager = TabManager(modelContext: modelContext, webViewManager: webViewManager)
        navigationManager = NavigationManager()
        windowManager = WindowManager()
        crashRecoveryManager = CrashRecoveryManager()
        bookmarkManager = BookmarkManager(modelContext: modelContext)

        notificationManager = NotificationManager(
            tabManager: tabManager!,
            navigationManager: navigationManager!,
            showOmnibar: $showOmnibar,
            tabs: { self.tabs },
            closeTabAction: { tab, tabs in
                self.tabManager?.closeTab(tab, tabs: tabs)
            },
            createNewTabAction: {
                // Close empty tabs before creating a new one
                let emptyTabs = self.tabs.filter { $0.url == nil }
                for emptyTab in emptyTabs {
                    if emptyTab.id != self.tabManager?.selectedTabId {
                        self.tabManager?.closeTab(emptyTab, tabs: self.tabs)
                    }
                }

                let newTab = self.tabManager?.createNewTab()
                // Show omnibar when creating a new tab
                if newTab != nil {
                    self.showOmnibar = true
                }
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
            tabManager: tabManager!,
            navigationManager: navigationManager!,
            webViewManager: webViewManager,
            showOmnibar: $showOmnibar,
            activeTab: { self.activeTab },
            reloadAction: { self.reload() },
            goBackAction: { self.goBack() },
            goForwardAction: { self.goForward() },
            hardReloadAction: { self.hardReload() },
            switchToNextTabAction: { self.switchToNextTab() },
            switchToPreviousTabAction: { self.switchToPreviousTab() },
            switchToTabAction: { index in self.switchToTab(at: index) },
            closeTabAction: { self.closeCurrentTab() },
            reloadAllTabsAction: { self.reloadAllTabs() },
            setTabBarWidth: { width in
                self.tabBarWidth = width
                UserDefaults.standard.set(width, forKey: "tabBarWidth")
            },
            getWindowWidth: {
                #if os(macOS)
                return Double(NSApplication.shared.keyWindow?.frame.width ?? 800)
                #else
                return 800.0
                #endif
            }
        )

        // Setup crash recovery after all managers are initialized
        crashRecoveryManager?.setup(with: modelContext)
    }

    private func createNewTab() {
        // Close empty tabs before creating a new one
        let emptyTabs = tabs.filter { $0.url == nil }
        for emptyTab in emptyTabs {
            if emptyTab.id != tabManager?.selectedTabId {
                tabManager?.closeTab(emptyTab, tabs: tabs)
            }
        }

        let newTab = tabManager?.createNewTab()
        // Show omnibar when creating a new tab
        if newTab != nil {
            showOmnibar = true
        }
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
            let tab = Tab(title: savedTab.title, url: nil, isActive: false)
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
                tabManager?.selectedTabId = firstTab.id
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
        print("Preloading favicons for all tabs before web views are loaded...")
        
        for tab in tabs {
            // Skip if tab already has a favicon
            if tab.favicon != nil {
                print("Tab \(tab.url?.absoluteString ?? "no url") already has favicon")
                continue
            }
            
            guard let url = tab.url else {
                // Generate domain initial for tabs without URLs
                if let domainInitial = DomainInitialsGenerator.shared.generateInitialImage(for: "newtab") {
                    tab.favicon = domainInitial
                }
                continue
            }
            
            print("Preloading favicon for tab: \(url.absoluteString)")
            
            // First check cache
            if let cachedFavicon = FaviconCache.shared.getFavicon(for: url) {
                print("Found cached favicon for \(url.absoluteString), setting on tab")
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
                    
                    print("Preloaded favicon for \(url.absoluteString) from \(faviconURL.absoluteString)")
                    
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
                                print("Generated domain initial for \(host)")
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
        print("Loading favicons for all tabs...")
        for tab in tabs {
            if let url = tab.url, tab.favicon == nil {
                print("Checking favicon cache for tab: \(url.absoluteString)")

                // First check if we have a favicon cached for this URL
                if let cachedFavicon = FaviconCache.shared.getFavicon(for: url) {
                    print("Found cached favicon for \(url.absoluteString), setting on tab")
                    tab.favicon = cachedFavicon
                } else {
                    print("No cached favicon for \(url.absoluteString), will load when tab becomes active")
                    // For now, we'll load favicons when tabs become active
                    // In the future, we could implement background favicon loading
                }
            } else if tab.favicon != nil {
                print("Tab \(tab.url?.absoluteString ?? "no url") already has favicon")
            }
        }
    }

    private func updateTabTitle(_ tab: Tab) {
        tabManager?.updateTabTitle(tab)
    }

    private var activeTab: Tab? {
        tabManager?.getActiveTab(from: tabs)
    }




    private func goBack() {
        if let activeTab = activeTab, activeTab.canGoBack() {
            if let newURL = activeTab.goBack() {
                currentURL = newURL
                webViewManager?.goBack()
            }
        }
    }

    private func goForward() {
        if let activeTab = activeTab, activeTab.canGoForward() {
            if let newURL = activeTab.goForward() {
                currentURL = newURL
                webViewManager?.goForward()
            }
        }
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
        tabManager?.switchToNextTab(tabs: tabs)
        // Update local selectedTabId to match TabManager
        if let tabManagerSelectedId = tabManager?.selectedTabId {
            selectedTabId = tabManagerSelectedId
        }
    }

    private func switchToPreviousTab() {
        tabManager?.switchToPreviousTab(tabs: tabs)
        // Update local selectedTabId to match TabManager
        if let tabManagerSelectedId = tabManager?.selectedTabId {
            selectedTabId = tabManagerSelectedId
        }
    }

    private func switchToTab(at index: Int) {
        print("ContentView switchToTab: switching to index \(index), tabs.count = \(tabs.count)")
        for (i, tab) in tabs.enumerated() {
            print("  Tab \(i): id=\(tab.id), url=\(tab.url?.absoluteString ?? "nil")")
        }
        tabManager?.switchToTab(at: index, tabs: tabs)
        // Also update our local state
        if index >= 0 && index < tabs.count {
            let targetTabId = tabs[index].id
            print("Setting selectedTabId to: \(targetTabId)")
            selectedTabId = targetTabId
        }
    }

    private func closeCurrentTab() {
        if let activeTab = activeTab {
            tabManager?.closeTab(activeTab, tabs: tabs)
        }
    }

    private func handlePopupRequest(url: URL, windowFeatures: Any?) {
        // Create a new tab for the popup
        let newTab = Tab(title: "Popup", url: url, isActive: false)
        modelContext.insert(newTab)
        tabManager?.selectedTabId = newTab.id
    }

    private func saveSessionForRestart() {
        // Create session data for normal app restart
        let sessionData = SessionData(
            tabs: tabs.enumerated().map { (index, tab) in
                SavedTab(
                    id: tab.id,
                    title: tab.title,
                    url: tab.url,
                    isActive: tab.isActive,
                    historyStrings: tab.historyStrings,
                    currentHistoryIndex: tab.currentHistoryIndex,
                    isPinned: tab.isPinned,
                    isMuted: tab.isMuted,
                    zoomLevel: tab.zoomLevel,
                    orderIndex: index
                )
            },
            selectedTabId: tabManager?.selectedTabId
        )

        // Save to UserDefaults with a different key than crash recovery
        let normalSessionKey = "normal_session_data"
        if let encoded = try? JSONEncoder().encode(sessionData) {
            UserDefaults.standard.set(encoded, forKey: normalSessionKey)
            // Clear the crash recovery saved session since we're saving a normal session
            UserDefaults.standard.removeObject(forKey: "saved_session_data")
            UserDefaults.standard.synchronize()
        }
    }

    private func restoreSessionForRestart() -> SessionData? {
        let normalSessionKey = "normal_session_data"

        // Check if we have a saved normal session
        guard let data = UserDefaults.standard.data(forKey: normalSessionKey),
              let sessionData = try? JSONDecoder().decode(SessionData.self, from: data) else {
            return nil
        }

        // Clear existing tabs first
        for tab in tabs {
            modelContext.delete(tab)
        }

        // Restore tabs, handling invalid URLs gracefully
        var restoredTabs: [Tab] = []
        for savedTab in sessionData.tabs {
            let tab = Tab(title: savedTab.title, url: nil, isActive: savedTab.isActive)
            tab.id = savedTab.id

            // Handle invalid URLs - only restore valid URLs
            var validHistory: [URL] = []
            for urlString in savedTab.historyStrings {
                if let url = URL(string: urlString), url.scheme != nil && url.host != nil {
                    validHistory.append(url)
                }
            }

            // Set current URL if it's valid, otherwise set to nil
            if let currentURL = savedTab.url,
               currentURL.scheme != nil && currentURL.host != nil {
                tab.url = currentURL
                // Make sure current URL is in history
                if !validHistory.contains(currentURL) {
                    validHistory.append(currentURL)
                }
            } else {
                // If current URL is invalid, try to use the last valid history entry
                tab.url = validHistory.last
            }

            tab.historyStrings = validHistory.map { $0.absoluteString }
            tab.currentHistoryIndex = min(savedTab.currentHistoryIndex, validHistory.count - 1)
            tab.isPinned = savedTab.isPinned
            tab.isMuted = savedTab.isMuted
            tab.zoomLevel = savedTab.zoomLevel
            tab.orderIndex = savedTab.orderIndex

            // Update title to use domain name
            tab.updateTitleFromURL()

            modelContext.insert(tab)
            restoredTabs.append(tab)
        }

        // Clear the saved session after successful restore
        UserDefaults.standard.removeObject(forKey: normalSessionKey)
        UserDefaults.standard.synchronize()

        return sessionData
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Tab.self, inMemory: true)
}
