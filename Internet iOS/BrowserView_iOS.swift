//
//  BrowserView_iOS.swift
//  Internet (iPadOS)
//
//  The iPad browser: a NavigationSplitView tab sidebar plus a full-bleed web view
//  with no persistent chrome — the omnibar is summoned on demand (⌘L / new tab) as
//  a floating overlay and progress shows on the window edges, matching the Mac
//  app's "the web is the app" spirit. Reuses the shared TabManager / WebViewManager
//  / NavigationManager / BookmarkManager exactly as the Mac ContentView does.
//
//  Keyboard commands are posted as notifications by the app's .commands block
//  (InternetApp_iOS) and handled here — the same decoupling the Mac app uses.
//

import SwiftUI
import SwiftData
import WebKit
import Combine

struct BrowserView_iOS: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tab.orderIndex) private var tabs: [Tab]
    @Query(sort: \TabGroup.orderIndex) private var tabGroups: [TabGroup]

    @StateObject private var tabManager = TabManager()
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
    @State private var showSettings = false

    // Group / workspace dialogs
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var showSaveWorkspace = false
    @State private var workspaceName = ""
    @State private var savedWorkspaces: [SavedWorkspace] = []

    @AppStorage("progressBarTop") private var progressBarTop = true
    @AppStorage("progressBarBottom") private var progressBarBottom = false
    @AppStorage("progressBarLeft") private var progressBarLeft = false
    @AppStorage("progressBarRight") private var progressBarRight = false
    @AppStorage("theme") private var theme = "System"

    // MARK: Derived

    private var activeTab: Tab? { tabs.first { $0.id == tabManager.selectedTabId } }

    // Tabs shown on this device: drops open-only local closes (their records stay
    // in the cloud so they remain open on your other devices).
    private var visibleTabs: [Tab] { TabSync.visible(tabs) }

    private var bookmarkPairs: [(title: String, url: URL)] {
        (bookmarkManager?.fetchAllBookmarks() ?? []).map { (title: $0.title, url: $0.url) }
    }

    private var suggestions: [Suggestion] {
        guard showOmnibar else { return [] }
        return omnibarSuggestions(input: omnibarText, tabs: tabs, bookmarks: bookmarkPairs)
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
                           tabs: tabs,
                           activeTabId: tabManager.selectedTabId,
                           onURLChange: { _ in })
                    .ignoresSafeArea()
            }

            EdgeProgressBar(progress: progressValue, show: showProgressBar,
                            top: progressBarTop, bottom: progressBarBottom,
                            left: progressBarLeft, right: progressBarRight)

            // Slide-in tab sidebar (⇧⌘L), dim backdrop, tap-out to close.
            if showSidebar {
                Color.black.opacity(0.25).ignoresSafeArea()
                    .onTapGesture { withAnimation { showSidebar = false } }
                sidebarPanel.transition(.move(edge: .leading))
            }

            if showOmnibar {
                omnibarOverlay.transition(.opacity)
            }
        }
        .preferredColorScheme(colorScheme)
        // Maximize screen real estate: hide the status bar and auto-hide the home
        // indicator so the web fills every pixel.
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear(perform: firstAppear)
        .onChange(of: tabManager.selectedTabId) { _, newValue in
            tabManager.updateActiveTab(in: tabs)
            webViewManager?.setActiveTab(newValue)
            syncOmnibarToActiveTab()
            withAnimation { showSidebar = false }  // picking a tab dismisses the panel
        }
        .onChange(of: activeTab?.url) { _, _ in if !showOmnibar { syncOmnibarToActiveTab() } }
        .onChange(of: isLoading) { _, loading in withAnimation { showProgressBar = loading } }
        .onChange(of: tabs) { _, newTabs in tabManager.ensureSelectedTab(from: TabSync.visible(newTabs)) }
        .alert("New Group", isPresented: $showNewGroup) {
            TextField("Group name", text: $newGroupName)
            Button("Create") { createGroup(newGroupName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Save Workspace", isPresented: $showSaveWorkspace) {
            TextField("Workspace name", text: $workspaceName)
            Button("Save") { saveWorkspace(workspaceName) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showShortcutSheet) { ShortcutCheatSheet_iOS() }
        .sheet(isPresented: $showSettings) { Settings_iOS() }
        // Keyboard commands (posted by InternetApp_iOS.commands), handled through
        // one merged publisher — a chain of ~16 .onReceive modifiers overwhelms
        // the SwiftUI type-checker.
        .onReceive(commandPublisher) { handleCommand($0) }
    }

    private var commandPublisher: AnyPublisher<Notification, Never> {
        let names: [Notification.Name] = [
            .browserNewTab, .browserCloseTab, .reopenLastClosedTab, .showOmnibar,
            .browserGoBack, .browserGoForward, .browserReload,
            .browserNextTab, .browserPreviousTab, .browserSwitchTab, .browserAddBookmark,
            .browserZoomIn, .browserZoomOut, .browserZoomReset,
            .browserToggleTabBar, .browserToggleShortcutOverlay, .browserShowSettings,
            .browserFindInPage,
        ]
        let center = NotificationCenter.default
        return Publishers.MergeMany(names.map { center.publisher(for: $0) }).eraseToAnyPublisher()
    }

    private func handleCommand(_ note: Notification) {
        switch note.name {
        case .browserNewTab: createNewTab()
        case .browserCloseTab: closeActiveTab()
        case .reopenLastClosedTab: _ = tabManager.reopenLastClosedTab()
        case .showOmnibar: focusOmnibar()
        case .browserGoBack: webViewManager?.goBack()
        case .browserGoForward: webViewManager?.goForward()
        case .browserReload: reloadOrStop()
        case .browserNextTab: tabManager.switchToNextTab(tabs: visibleTabs)
        case .browserPreviousTab: tabManager.switchToPreviousTab(tabs: visibleTabs)
        case .browserSwitchTab:
            if let idx = note.userInfo?["index"] as? Int { tabManager.switchToTab(at: idx - 1, tabs: visibleTabs) }
        case .browserAddBookmark: toggleBookmark()
        case .browserZoomIn: zoom(by: 1.1)
        case .browserZoomOut: zoom(by: 1 / 1.1)
        case .browserZoomReset: setZoom(1)
        case .browserToggleTabBar: toggleSidebar()
        case .browserToggleShortcutOverlay: showShortcutSheet.toggle()
        case .browserShowSettings: showSettings = true
        case .browserFindInPage:
            if let wv = webViewManager?.activeWebView {
                wv.isFindInteractionEnabled = true
                wv.becomeFirstResponder()
                wv.findInteraction?.presentFindNavigator(showingReplace: false)
            }
        default: break
        }
    }

    // MARK: Sidebar panel (summoned overlay)

    private var sidebarPanel: some View {
        NavigationStack {
            TabSidebar_iOS(
                tabManager: tabManager,
                tabs: visibleTabs,
                tabGroups: tabGroups,
                progressValue: progressValue,
                isLoading: isLoading,
                onNewTab: createNewTab,
                onCloseTab: { tabManager.closeTab($0, tabs: visibleTabs) },
                onNewGroup: { newGroupName = ""; showNewGroup = true },
                onDeleteGroup: deleteGroup,
                onMoveTab: { $0.groupId = $1 },
                onSaveWorkspace: { workspaceName = ""; showSaveWorkspace = true },
                onSettings: { showSettings = true },
                onShortcuts: { showShortcutSheet = true },
                workspaceMenu: AnyView(workspaceMenu)
            )
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .ignoresSafeArea(edges: .bottom)
    }

    // Floating omnibar summoned over the page (the Mac app's model) so the chrome
    // vanishes whenever you're not typing an address.
    private var omnibarOverlay: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture { dismissOmnibar() }
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
    }

    private var omnibarCard: some View {
        HStack(spacing: 10) {
            Button { dismissOmnibar(); withAnimation { showSidebar = true } } label: {
                Image(systemName: "square.stack").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Image(systemName: isLoading ? "arrow.triangle.2.circlepath" : "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search or enter address", text: $omnibarText)
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
            }
        }
        .font(.system(size: 17))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .onChange(of: omnibarText) { _, _ in selectedSuggestion = -1 }
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

    // MARK: Actions

    private func firstAppear() {
        guard !managersInitialized else { return }
        let wvm = WebViewManager()
        webViewManager = wvm
        navigationManager = NavigationManager()
        bookmarkManager = BookmarkManager(modelContext: modelContext)
        tabManager.setModelContext(modelContext)
        tabManager.setWebViewManager(wvm)
        managersInitialized = true
        savedWorkspaces = SavedWorkspace.loadAll()

        if visibleTabs.isEmpty {
            let t = tabManager.createNewTab()
            #if DEBUG
            if let url = debugLaunchURL() { t.navigateTo(url) } else { DispatchQueue.main.async { focusOmnibar() } }
            #else
            DispatchQueue.main.async { focusOmnibar() }
            #endif
        } else {
            tabManager.selectedTabId = visibleTabs.first(where: { $0.isActive })?.id ?? visibleTabs.first?.id
            #if DEBUG
            if let url = debugLaunchURL(), let t = visibleTabs.first(where: { $0.id == tabManager.selectedTabId }) { t.navigateTo(url) }
            #endif
            syncOmnibarToActiveTab()
        }
    }

    #if DEBUG
    // Test hook: `simctl launch … -openURL https://example.com` loads that page
    // into the initial tab so web rendering can be verified without UI typing.
    private func debugLaunchURL() -> URL? {
        guard let i = CommandLine.arguments.firstIndex(of: "-openURL"), i + 1 < CommandLine.arguments.count else { return nil }
        return URL(string: CommandLine.arguments[i + 1])
    }
    #endif

    private func createNewTab() {
        for empty in tabs where empty.url == nil && empty.id != tabManager.selectedTabId {
            tabManager.closeTab(empty, tabs: tabs)
        }
        _ = tabManager.createNewTab()
        focusOmnibar()
    }

    private func closeActiveTab() { if let t = activeTab { tabManager.closeTab(t, tabs: visibleTabs) } }

    private func reloadOrStop() {
        if isLoading { webViewManager?.stopLoading() } else { webViewManager?.reload() }
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
        return bookmarkManager?.isBookmarked(url) ?? false
    }

    private func toggleBookmark() {
        guard let tab = activeTab, let url = tab.url, let bm = bookmarkManager else { return }
        if bm.isBookmarked(url) {
            if let existing = bm.fetchAllBookmarks().first(where: { $0.url.absoluteString == url.absoluteString }) {
                bm.removeBookmark(existing)
            }
        } else {
            _ = bm.addBookmark(from: tab)
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

    private func toggleSidebar() {
        withAnimation(.easeOut(duration: 0.2)) { showSidebar.toggle() }
    }

    private func createGroup(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        modelContext.insert(TabGroup(name: trimmed, color: .blue, orderIndex: tabGroups.count))
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
        for tab in tabs { modelContext.delete(tab) }
        for group in tabGroups { modelContext.delete(group) }
        for sg in workspace.groups {
            let g = TabGroup(name: sg.name, color: Color(hex: sg.colorHex) ?? .blue, orderIndex: sg.orderIndex)
            g.id = sg.id
            modelContext.insert(g)
        }
        for st in workspace.tabs {
            let t = Tab(title: st.title, url: st.urlString.flatMap(URL.init(string:)), isActive: false)
            t.id = st.id
            t.groupId = st.groupId
            t.orderIndex = st.orderIndex
            modelContext.insert(t)
        }
        DispatchQueue.main.async {
            tabManager.selectedTabId = (try? modelContext.fetch(FetchDescriptor<Tab>()))?.first?.id
        }
    }
}

// A compact, keyboard-first shortcut reference (⇧⌘H).
struct ShortcutCheatSheet_iOS: View {
    @Environment(\.dismiss) private var dismiss
    private let rows: [(String, String)] = [
        ("⌘L", "Focus the address bar"),
        ("⌘T", "New tab"),
        ("⌘W", "Close tab"),
        ("⇧⌘T", "Reopen closed tab"),
        ("⌘R", "Reload / Stop"),
        ("⌘[  ⌘]", "Back / Forward"),
        ("⌘1–9", "Switch to tab"),
        ("⌃Tab", "Next / Previous tab"),
        ("⌘D", "Bookmark this page"),
        ("⌘+  ⌘−  ⌘0", "Zoom in / out / reset"),
        ("⇧⌘L", "Toggle the sidebar"),
        ("⇧⌘H", "This cheat sheet"),
    ]
    var body: some View {
        NavigationStack {
            List(rows, id: \.0) { row in
                HStack {
                    Text(row.0).font(.system(.body, design: .monospaced)).frame(width: 120, alignment: .leading)
                    Text(row.1).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Keyboard Shortcuts")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
