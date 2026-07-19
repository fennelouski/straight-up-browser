//
//  BrowserView_iOS.swift
//  Browser (iPadOS)
//
//  The iPad browser: a NavigationSplitView tab sidebar plus a full-bleed web view
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

struct BrowserView_iOS: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tab.orderIndex) private var tabs: [Tab]
    @Query(sort: \TabGroup.orderIndex) private var tabGroups: [TabGroup]
    @Query(sort: \BrowserSession.createdAt) private var browserSessions: [BrowserSession]

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
    @State private var showGestureGuide = false
    @State private var showSettings = false

    // Group / workspace dialogs
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var showNewContainer = false
    @State private var newContainerName = ""
    @State private var showSaveWorkspace = false
    @State private var workspaceName = ""
    @State private var savedWorkspaces: [SavedWorkspace] = []

    @AppStorage("progressBarTop") private var progressBarTop = true
    @AppStorage("progressBarBottom") private var progressBarBottom = false
    @AppStorage("progressBarLeft") private var progressBarLeft = false
    @AppStorage("progressBarRight") private var progressBarRight = false
    @AppStorage("theme") private var theme = "System"

    // MARK: Derived

    // Working set: persisted (normal/container) tabs plus in-memory incognito tabs.
    // Everything that selects, switches, closes, or renders a tab uses this so
    // incognito tabs (never in @Query) are first-class. Mirrors ContentView.allTabs.
    private var allTabs: [Tab] { tabs + tabManager.incognitoTabs }

    private var activeTab: Tab? { allTabs.first { $0.id == tabManager.selectedTabId } }

    // Tabs shown on this device: drops open-only local closes (their records stay
    // in the cloud so they remain open on your other devices). Incognito isn't
    // synced, so it bypasses the visibility filter and always shows.
    private var visibleTabs: [Tab] { TabSync.visible(tabs) + tabManager.incognitoTabs }

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
                           tabs: allTabs,
                           activeTabId: tabManager.selectedTabId,
                           onURLChange: { _ in })
                    .ignoresSafeArea()
            }

            EdgeProgressBar(progress: progressValue, show: showProgressBar,
                            top: progressBarTop, bottom: progressBarBottom,
                            left: progressBarLeft, right: progressBarRight)

            // Touch's stand-in for the keyboard (iPhone has no ⌘L / ⌘T). Hidden
            // whenever the omnibar or sidebar is already up.
            if managersInitialized && !showOmnibar && !showSidebar {
                bottomGestureBar
            }

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
            tabManager.updateActiveTab(in: allTabs)
            webViewManager?.setActiveTab(newValue)
            syncOmnibarToActiveTab()
            withAnimation { showSidebar = false }  // picking a tab dismisses the panel
        }
        .onChange(of: activeTab?.url) { _, _ in if !showOmnibar { syncOmnibarToActiveTab() } }
        .onChange(of: isLoading) { _, loading in withAnimation { showProgressBar = loading } }
        .onChange(of: tabs) { _, newTabs in
            // Keep restored container tabs' sessions registered, and keep a valid
            // selection across the merged working set (incognito included).
            webViewManager?.syncSessions(from: newTabs)
            tabManager.ensureSelectedTab(from: TabSync.visible(newTabs) + tabManager.incognitoTabs)
        }
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
        .sheet(isPresented: $showShortcutSheet) { ShortcutCheatSheet_iOS() }
        .sheet(isPresented: $showGestureGuide) {
            GestureGuide_iOS().presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSettings) { Settings_iOS() }
        // Keyboard commands (posted by BrowserApp_iOS.commands), handled through
        // one merged publisher — a chain of ~16 .onReceive modifiers overwhelms
        // the SwiftUI type-checker.
        .onReceive(commandPublisher) { handleCommand($0) }
    }

    private var commandPublisher: AnyPublisher<Notification, Never> {
        let names: [Notification.Name] = [
            .browserNewTab, .browserNewIncognitoTab, .browserCloseTab, .reopenLastClosedTab, .showOmnibar,
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
        case .browserNewIncognitoTab: _ = tabManager.createIncognitoTab(); focusOmnibar()
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
                sessionColor: sessionColor,
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
                onGestures: { withAnimation { showSidebar = false }; showGestureGuide = true },
                workspaceMenu: AnyView(workspaceMenu),
                containersMenu: AnyView(containersMenu)
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
                .padding(.vertical, 18)      // fat invisible hit area for the thumb
                .padding(.horizontal, 40)
                .contentShape(Rectangle())
                .onTapGesture { focusOmnibar() }
                .onLongPressGesture(minimumDuration: 0.4) { createNewTab() }
                .highPriorityGesture(DragGesture(minimumDistance: 20).onEnded(handleBarSwipe))
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
            tabManager.switchToNextTab(tabs: visibleTabs)      // left → next tab
        } else if dx > 30, abs(dx) > abs(dy) {
            tabManager.switchToPreviousTab(tabs: visibleTabs)  // right → previous tab
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
        let wvm = WebViewManager()
        webViewManager = wvm
        navigationManager = NavigationManager()
        bookmarkManager = BookmarkManager(modelContext: modelContext)
        tabManager.setModelContext(modelContext)
        tabManager.setWebViewManager(wvm)
        // Register restored container tabs' sessions before their web views build,
        // so each resumes in its own data store (not the default one).
        wvm.syncSessions(from: tabs)
        managersInitialized = true
        savedWorkspaces = SavedWorkspace.loadAll()

        // First run with no keyboard pops the touch guide; when it does, skip the
        // omnibar auto-focus so the user reads "tap the bar" and then does it.
        let showingGuide = maybeShowGestureGuide()

        if visibleTabs.isEmpty {
            let t = tabManager.createNewTab()
            #if DEBUG
            if let url = debugLaunchURL() { t.navigateTo(url) }
            else if !showingGuide { DispatchQueue.main.async { focusOmnibar() } }
            #else
            if !showingGuide { DispatchQueue.main.async { focusOmnibar() } }
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

    // The active tab's session, so a new tab (⌘T / +) stays in the same container.
    private func activeSession() -> (kind: SessionKind, sessionId: UUID?) {
        guard let active = activeTab else { return (.normal, nil) }
        return (active.sessionKind, active.sessionId)
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
        modelContext.delete(session)
        WKWebsiteDataStore.remove(forIdentifier: id) { _ in }
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
                    Text("The web fills the whole screen. A few gestures on the handle at the bottom edge do everything a toolbar would.")
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
