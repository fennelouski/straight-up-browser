//
//  TabManager.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import SwiftData
import WebKit
import Combine
#if os(macOS)
import AppKit
#endif

#if os(macOS)
private let defaultTerminateApplication: () -> Void = {
    NSApp.terminate(nil)
}
#else
// iOS applications must not terminate themselves programmatically.
private let defaultTerminateApplication: () -> Void = {}
#endif

// Value snapshot of a closed tab. Holding the deleted SwiftData model itself
// is undefined behavior once modelContext.delete runs.
struct ClosedTabSnapshot: Codable {
    let title: String
    let url: URL?
    let historyStrings: [String]
    // Optional for backward compatibility with snapshots written before session
    // inheritance was preserved.
    let sessionKind: SessionKind?
    let sessionId: UUID?
    // Optional so snapshots written by WebKit-only releases still decode.
    let preferredEngine: BrowserEngine?
    // Workspace membership at close, so reopen restores it. Optional for
    // pre-workspace snapshots.
    let workspaceId: UUID?
    // True when this close wrote a `dismissed` disposition, so reopen can
    // un-write it (SPEC: undo must un-write the rejection, not just the tab).
    let wroteDismissed: Bool?
    // The ref's disposition before the close; nil = the close created the ref.
    let priorDispositionRaw: String?
    // Set on every member of a multi-pane close (⌘W on a split), so one ⇧⌘T
    // undoes the whole set as one unit.
    let undoGroup: UUID?

    init(
        title: String,
        url: URL?,
        historyStrings: [String],
        sessionKind: SessionKind?,
        sessionId: UUID?,
        preferredEngine: BrowserEngine? = nil,
        workspaceId: UUID? = nil,
        wroteDismissed: Bool? = nil,
        priorDispositionRaw: String? = nil,
        undoGroup: UUID? = nil
    ) {
        self.title = title
        self.url = url
        self.historyStrings = historyStrings
        self.sessionKind = sessionKind
        self.sessionId = sessionId
        self.preferredEngine = preferredEngine
        self.workspaceId = workspaceId
        self.wroteDismissed = wroteDismissed
        self.priorDispositionRaw = priorDispositionRaw
        self.undoGroup = undoGroup
    }
}

/// One short-lived visual event shared by the source and child rows when a
/// clicked link creates a foreground tab. The token lets SwiftUI replay the
/// effect when the same pair opens more than once.
struct AutomaticLinkBirthCue: Equatable {
    let token = UUID()
    let sourceTabId: UUID
    let childTabId: UUID
}

class TabManager: NSObject, ObservableObject {
    // The focused tab: owns the omnibar, title, and all key commands. In a split
    // it is always one of splitTabIds; selecting any non-member dissolves the split
    // (see docs/adr/0001-split-is-view-state.md).
    @Published var selectedTabId: UUID? {
        didSet {
            // Selecting any tab takes focus back from a document pane (ADR 0008).
            if oldValue != selectedTabId { focusedDocumentId = nil }
            noteSelectionForRecentOrder()
            if !splitTabIds.isEmpty, let id = selectedTabId, !splitTabIds.contains(id) {
                splitTabIds = []
            }
            // Focusing a fast-forwarded pane means the guess was useful.
            let focusedTabId = selectedTabId
            let fastForward = fastForward
            Task { @MainActor [weak fastForward] in
                fastForward?.noteFocus(focusedTabId)
            }
        }
    }
    // Split view: ordered member tab ids (2–4; empty = normal single view).
    // Window view state, not a SwiftData entity — persisted to UserDefaults only.
    @Published var splitTabIds: [UUID] = [] {
        didSet { UserDefaults.standard.set(splitTabIds.map(\.uuidString), forKey: Self.splitKey) }
    }
    // A Split is an arrangement of 2–4 PANES: tabs or workspace documents
    // (ADR 0008). splitTabIds keeps its name and persistence key but holds pane
    // ids; each resolves against the tab list first, then the active workspace's
    // documents, and unresolved ids are dropped by the existing restore rule.
    //
    // Non-nil = a document owns focus (omnibar shows its name, ⌘W closes its
    // pane and never writes a disposition). selectedTabId stays tabs-only so its
    // many call sites keep meaning what they meant; selecting any tab clears this.
    @Published var focusedDocumentId: UUID?

    /// Set by the content view once the DocumentStore exists: whether a pane id
    /// is a workspace document. Nil (tests, startup) means "no id is".
    var isDocumentPaneId: ((UUID) -> Bool)?

    // Incognito tabs live only in memory — never inserted into SwiftData — so a private
    // URL never persists to disk or syncs to iCloud. They vanish when the app quits.
    @Published var incognitoTabs: [Tab] = []
    // Survives quit (persisted to UserDefaults) so Cmd+Shift+T can reopen tabs
    // from the previous session, not just the current one.
    @Published var closedTabs: [ClosedTabSnapshot] = [] {
        didSet { persistClosedTabs() }
    }
    // Non-nil while closeTabSet is closing a multi-pane selection: every
    // snapshot it stacks carries this id, so reopen restores the set as one unit.
    private var pendingUndoGroup: UUID?

    // Set when a normal tab is created and we're not the default browser, so
    // ContentView can show the bottom-corner nudge. Every new-tab path (⌘T, +,
    // menus, CLI) funnels through createNewTab.
    @Published var offerDefaultBrowser = false

    // Presentational only: link provenance below owns behavior; this value just
    // lets both sidebar rows perform the same short birth animation.
    @Published private(set) var automaticLinkBirthCue: AutomaticLinkBirthCue?

    private static let closedTabsKey = "closedTabsStack"
    private static let maxClosedTabs = 25
    private static let splitKey = "splitTabIds"
    static let activeWorkspaceKey = "activeWorkspaceId"

    static func restoredActiveWorkspaceId() -> UUID? {
        UserDefaults.standard.string(forKey: activeWorkspaceKey).flatMap(UUID.init(uuidString:))
    }
    static let maxSplitTabs = 4

    private var modelContext: ModelContext?
    private weak var webViewManager: WebViewManager?
    weak var fastForward: FastForward?
    private let terminateApplication: () -> Void

    /// The workspace this window is showing, or nil for the default workspace.
    /// Per-window view state persisted to UserDefaults, exactly like splitTabIds
    /// (ADR 0001) — two windows can sit in two different workspaces.
    @Published var activeWorkspaceId: UUID? {
        didSet {
            if let id = activeWorkspaceId {
                UserDefaults.standard.set(id.uuidString, forKey: Self.activeWorkspaceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.activeWorkspaceKey)
            }
            // Document panes and their edit sessions belong to the workspace
            // being left; the owner (ContentView / BrowserView_iOS) closes and
            // discards them here so they don't accumulate across switches.
            if oldValue != activeWorkspaceId { workspaceSwitched?() }
        }
    }

    /// Called after the active workspace changes. Set by the content view to
    /// close and discard document panes/sessions from the previous workspace.
    var workspaceSwitched: (() -> Void)?

    /// Set once the model container exists. Nil in tests that don't need a ledger.
    var ledgerStore: LedgerStore?
    var settleCapture: WorkspaceSettleCapture?

    // The blank tab the last new-tab command (⌘T/+) created, if the user hasn't
    // navigated it anywhere yet. Tracked so a second new-tab press undoes the
    // first instead of piling up another blank tab, and so switching away from
    // it closes it automatically (see newTabOrUndo / handleSelectionChanged).
    private var pendingNewTabId: UUID?
    private var tabIdBeforePendingNewTab: UUID?

    // Only tabs created because a clicked page link requested another tab live
    // here. `Tab.openerId` is broader (Cmd+T, duplicates, Command-click queues),
    // so it cannot by itself decide whether Back should close a child tab.
    private var automaticLinkOpeners: [UUID: UUID] = [:]

    init(
        modelContext: ModelContext? = nil,
        webViewManager: WebViewManager? = nil,
        terminateApplication: @escaping () -> Void = defaultTerminateApplication
    ) {
        self.modelContext = modelContext
        self.webViewManager = webViewManager
        self.terminateApplication = terminateApplication
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.closedTabsKey),
           let saved = try? JSONDecoder().decode([ClosedTabSnapshot].self, from: data) {
            closedTabs = saved
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(historyDidClear),
            name: .browserHistoryDidClear,
            object: nil
        )
    }

    // Keep only the most recent entries on disk; the in-session stack is small
    // by nature (you'd have to close thousands of tabs to grow it).
    private func persistClosedTabs() {
        let capped = Array(closedTabs.suffix(Self.maxClosedTabs))
        guard !capped.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.closedTabsKey)
            return
        }
        if let data = try? JSONEncoder().encode(capped) {
            UserDefaults.standard.set(data, forKey: Self.closedTabsKey)
        }
    }

    static func clearPersistedClosedTabs() {
        UserDefaults.standard.removeObject(forKey: closedTabsKey)
    }

    func purgeClosedTabs(forSession sessionId: UUID) {
        closedTabs.removeAll { $0.sessionId == sessionId }
    }

    @objc private func historyDidClear() {
        closedTabs.removeAll()
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setModelContext(_ modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func setWebViewManager(_ webViewManager: WebViewManager) {
        self.webViewManager = webViewManager
    }

    @discardableResult
    func createNewTab(
        url: URL? = nil,
        select: Bool = true,
        preferredEngine: BrowserEngine = .webKit
    ) -> Tab {
        #if os(macOS)
        if DefaultBrowser.shouldOffer { offerDefaultBrowser = true }
        #endif
        let newTab = Tab(title: String(localized: "New Tab"), url: url, isActive: false)
        newTab.preferredEngine = preferredEngine
        newTab.openerId = selectedTabId
        // New tabs join whatever workspace this window is showing.
        newTab.workspaceId = activeWorkspaceId
        newTab.memoryPolicy = MemoryPolicy(rawValue:
            UserDefaults.standard.string(forKey: "memorySaverDefaultPolicy") ?? "") ?? .whenNeeded
        if url != nil {
            newTab.updateTitleFromURL()
        }
        if let modelContext = modelContext {
            // Order before insert: without this every tab keeps orderIndex 0 and the
            // sidebar sorts the whole pile arbitrarily. Popups were the visible
            // symptom — one would appear at the top of the list, nowhere near the
            // tab that opened it. Matches what createIncognitoTab already does.
            let existing = (try? modelContext.fetch(FetchDescriptor<Tab>())) ?? []
            if let current = existing.first(where: { $0.id == selectedTabId }) {
                // Land right after the tab you're on — and after any tabs already
                // opened from it, so ⌘-clicking several links queues them in click
                // order instead of reversing them.
                let anchor = existing
                    .filter { $0.openerId == current.id && $0.orderIndex > current.orderIndex }
                    .map(\.orderIndex)
                    .max() ?? current.orderIndex
                for tab in existing where tab.orderIndex > anchor {
                    tab.orderIndex += 1
                }
                newTab.orderIndex = anchor + 1
            } else {
                newTab.orderIndex = (existing.map(\.orderIndex).max() ?? -1) + 1
            }
            modelContext.insert(newTab)
        }
        if select {
            selectedTabId = newTab.id
        }
        return newTab
    }

    // Open an incognito tab. Pass an existing sessionId to join that private session
    // (shares its ephemeral cookie jar); omit it for a fresh, isolated one.
    @discardableResult
    func createIncognitoTab(
        sessionId: UUID? = nil,
        select: Bool = true,
        preferredEngine: BrowserEngine = .webKit
    ) -> Tab {
        let tab = Tab(title: String(localized: "New Tab"), url: nil, isActive: false)
        tab.preferredEngine = preferredEngine
        tab.sessionKind = .incognito
        tab.sessionId = sessionId ?? UUID()
        tab.openerId = selectedTabId
        // In-memory only: never unload (there's no SwiftData row to restore from).
        tab.memoryPolicy = .never
        tab.orderIndex = (incognitoTabs.map(\.orderIndex).max() ?? 1_000_000) + 1
        incognitoTabs.append(tab)
        webViewManager?.registerSession(for: tab.id, kind: .incognito, sessionId: tab.sessionId)
        if select { selectedTabId = tab.id }
        return tab
    }

    // Create a tab in the given session, so a new tab (Cmd+T) or a window.open popup
    // stays in the current container/incognito. Normal falls through to createNewTab.
    @discardableResult
    func createTab(
        inheriting context: BrowsingContext,
        url: URL? = nil,
        select: Bool = true
    ) -> Tab {
        switch context.sessionKind {
        case .normal:
            return createNewTab(
                url: url,
                select: select,
                preferredEngine: context.preferredEngine
            )
        case .incognito:
            let tab = createIncognitoTab(
                sessionId: context.sessionId,
                select: select,
                preferredEngine: context.preferredEngine
            )
            if let url { tab.navigateTo(url); tab.updateTitleFromURL() }
            return tab
        case .container:
            let tab = createNewTab(
                url: url,
                select: select,
                preferredEngine: context.preferredEngine
            )
            tab.sessionKind = .container
            tab.sessionId = context.sessionId
            webViewManager?.registerSession(for: tab.id, kind: .container, sessionId: context.sessionId)
            return tab
        }
    }

    // Compatibility convenience for call sites that intentionally create a
    // fresh WebKit tab in a particular cookie/session jar.
    func createTab(
        inheriting session: (kind: SessionKind, sessionId: UUID?),
        url: URL? = nil,
        select: Bool = true
    ) -> Tab {
        createTab(
            inheriting: BrowsingContext(
                sessionKind: session.kind,
                sessionId: session.sessionId,
                preferredEngine: .webKit
            ),
            url: url,
            select: select
        )
    }

    // The ⌘T/+ entry point: if we're still looking at the blank tab the last
    // press created, undo it (close it, go back to what was showing before).
    // Otherwise create a fresh one and remember where we came from. Returns
    // nil on undo (nothing new to show) so callers can skip e.g. opening the
    // omnibar.
    @discardableResult
    func newTabOrUndo(tabs: [Tab], inheriting context: BrowsingContext) -> Tab? {
        if closePendingNewTab(tabs: tabs) { return nil }

        // Stray blank tabs (e.g. the one launch starts with) shouldn't pile up
        // alongside a freshly created one either.
        for tab in tabs where tab.url == nil && tab.id != selectedTabId {
            closeTab(tab, tabs: tabs, reason: .housekeeping)
        }

        tabIdBeforePendingNewTab = selectedTabId
        let newTab = createTab(inheriting: context)
        pendingNewTabId = newTab.id
        return newTab
    }

    /// The fixed ⌘N path. Unlike ⌘T it never interprets a second press as
    /// undo, and it never resolves an omnibar query to an existing tab.
    @discardableResult
    func forceNewTab(tabs: [Tab], inheriting context: BrowsingContext) -> Tab {
        _ = closePendingNewTab(tabs: tabs)
        for tab in tabs where tab.url == nil && tab.id != selectedTabId {
            closeTab(tab, tabs: tabs, reason: .housekeeping)
        }
        tabIdBeforePendingNewTab = selectedTabId
        let newTab = createTab(inheriting: context)
        pendingNewTabId = newTab.id
        return newTab
    }

    // Undo the last new-tab command if we're still sitting on the blank tab it
    // created: close it and go back to what was showing before. Returns whether
    // it did anything.
    @discardableResult
    func closePendingNewTab(tabs: [Tab]) -> Bool {
        guard let pendingId = pendingNewTabId,
              selectedTabId == pendingId,
              let pendingTab = tabs.first(where: { $0.id == pendingId }),
              pendingTab.url == nil else { return false }
        selectedTabId = tabIdBeforePendingNewTab
        pendingNewTabId = nil
        tabIdBeforePendingNewTab = nil
        closeTab(pendingTab, tabs: tabs, reason: .housekeeping)
        return true
    }

    // Called whenever the selection changes away from the pending blank tab
    // (click, key command, anything). If it's still blank, close it — that's
    // the whole point of tracking it. If it navigated, it's a real tab now;
    // just stop tracking it.
    func handleSelectionChanged(from oldValue: UUID?, tabs: [Tab]) {
        guard let oldValue, oldValue == pendingNewTabId else { return }
        pendingNewTabId = nil
        tabIdBeforePendingNewTab = nil
        if let tab = tabs.first(where: { $0.id == oldValue }), tab.url == nil {
            closeTab(tab, tabs: tabs, reason: .housekeeping)
        }
    }

    // Switch a live normal/container tab into incognito: same page and login (its
    // cookies are copied into a fresh ephemeral jar first), but everything from
    // that point on — new cookies, cache, page state — lives only in memory and
    // dies with the tab. The old SwiftData row is deleted outright (the tab went
    // private, so it should vanish from other devices too) with no closed-tab
    // snapshot, since the tab lives on as the incognito replacement.
    func convertToIncognito(_ tab: Tab) {
        guard tab.sessionKind != .incognito, let webViewManager else { return }
        let url = tab.url
        let sessionId = UUID()
        webViewManager.prepareIncognitoStore(sessionId: sessionId, copyingCookiesFromTab: tab.id) { [weak self] in
            guard let self else { return }
            let newTab = self.createIncognitoTab(
                sessionId: sessionId,
                preferredEngine: tab.preferredEngine
            )
            if let url {
                newTab.navigateTo(url)
                newTab.updateTitleFromURL()
            }
            self.webViewManager?.removeWebView(for: tab.id)
            self.modelContext?.delete(tab)
        }
    }

    // Switch a live incognito tab back to normal: a fresh persisted tab on the
    // same page. Nothing is carried over (history, cookies) — going private →
    // public shouldn't silently persist what the incognito session held.
    func convertToNormal(_ tab: Tab) {
        guard tab.sessionKind == .incognito else { return }
        let newTab = createNewTab(url: tab.url, preferredEngine: tab.preferredEngine)
        webViewManager?.removeWebView(for: tab.id)
        incognitoTabs.removeAll { $0.id == tab.id }
        if let sessionId = tab.sessionId, !incognitoTabs.contains(where: { $0.sessionId == sessionId }) {
            webViewManager?.discardIncognitoStore(sessionId)
        }
        selectedTabId = newTab.id
    }

    // MARK: - Split view

    /// Finish opening a tab that a normal click caused the website to create.
    /// This is deliberately separate from Command-click and JavaScript utility
    /// popups, which have their own selection/split rules.
    func presentAutomaticallyOpenedLink(_ tab: Tab, from sourceTabId: UUID?, tabs: [Tab]) {
        guard let sourceTabId else {
            selectedTabId = tab.id
            return
        }

        tab.openerId = sourceTabId
        automaticLinkOpeners[tab.id] = sourceTabId

        if SettingsManager.shared.automaticLinkMitosisEnabled {
            let cue = AutomaticLinkBirthCue(sourceTabId: sourceTabId, childTabId: tab.id)
            automaticLinkBirthCue = cue
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard self?.automaticLinkBirthCue?.token == cue.token else { return }
                self?.automaticLinkBirthCue = nil
            }
        }

        guard SettingsManager.shared.automaticLinkSplitEnabled else {
            selectedTabId = tab.id
            return
        }

        // Focus the actual source first. In a split, the clicked link may have
        // come from a displayed but unfocused pane, and toggleSplitMembership
        // uses the focused tab as its anchor for a new split.
        selectedTabId = sourceTabId
        if splitTabIds.count < Self.maxSplitTabs {
            toggleSplitMembership(tab, tabs: tabs)
        } else {
            selectedTabId = tab.id
        }
    }

    /// Safari-style Back at the beginning of a link-created child: close it and
    /// return explicitly to the source. The caller first checks WKWebView's
    /// history so ordinary in-tab Back always wins when available.
    @discardableResult
    func closeAutomaticallyOpenedLinkOnBack(tabs: [Tab]) -> Bool {
        guard let childId = selectedTabId,
              let sourceId = automaticLinkOpeners[childId],
              let child = tabs.first(where: { $0.id == childId }),
              tabs.contains(where: { $0.id == sourceId }) else { return false }

        // Undoing an automatic link open, not rejecting the source.
        selectedTabId = sourceId
        closeTab(child, tabs: tabs, reason: .housekeeping)
        return true
    }

    // Shift-click / context-menu toggle: add the tab as a pane (focusing it) or
    // remove its pane. Live — there is no separate selection/confirm step.
    func toggleSplitMembership(_ tab: Tab, tabs: [Tab]) {
        if splitTabIds.contains(tab.id) {
            removeFromSplit(tab.id)
        } else if splitTabIds.isEmpty {
            guard let current = focusedDocumentId ?? selectedTabId, current != tab.id else {
                selectedTabId = tab.id
                return
            }
            splitTabIds = [current, tab.id]
            gatherSplitTabs(tabs: tabs)
            selectedTabId = tab.id
        } else if splitTabIds.count < Self.maxSplitTabs {
            splitTabIds.append(tab.id)
            gatherSplitTabs(tabs: tabs)
            selectedTabId = tab.id
        }
        // At the cap (4): adding is a no-op.
    }

    // MARK: Document panes (ADR 0008)

    /// Selecting a document row: solo display, dissolving a split it isn't in —
    /// the same rule as selecting a non-member tab.
    func selectDocument(_ documentId: UUID) {
        if !splitTabIds.contains(documentId) { splitTabIds = [] }
        focusedDocumentId = documentId
    }

    /// Shift-click / context-menu toggle for a document row, exactly like
    /// toggleSplitMembership for tabs. Documents are never gathered in the
    /// sidebar — they live in their own block within the workspace section.
    func toggleDocumentSplitMembership(_ documentId: UUID) {
        if splitTabIds.contains(documentId) {
            removeFromSplit(documentId)
            if focusedDocumentId == documentId { focusedDocumentId = nil }
        } else if splitTabIds.isEmpty {
            guard let current = focusedDocumentId ?? selectedTabId, current != documentId else {
                focusedDocumentId = documentId
                return
            }
            splitTabIds = [current, documentId]
            focusedDocumentId = documentId
        } else if splitTabIds.count < Self.maxSplitTabs {
            splitTabIds.append(documentId)
            focusedDocumentId = documentId
        }
        // At the cap (4): adding is a no-op.
    }

    /// ⌘W on a focused document: close its pane. Never writes a disposition —
    /// documents have none — and the sidebar row remains (closing ≠ deleting).
    func closeDocumentPane(_ documentId: UUID) {
        if splitTabIds.contains(documentId) {
            removeFromSplit(documentId)
        }
        if focusedDocumentId == documentId { focusedDocumentId = nil }
    }

    private func removeFromSplit(_ tabId: UUID) {
        let remaining = splitTabIds.filter { $0 != tabId }
        splitTabIds = remaining.count >= 2 ? remaining : []
        if selectedTabId == tabId {
            // selectedTabId stays tabs-only: a document successor takes focus
            // through focusedDocumentId instead (ADR 0008).
            let isDocument = isDocumentPaneId ?? { _ in false }
            if let successor = remaining.first(where: { !isDocument($0) }) {
                selectedTabId = successor
            } else if let documentSuccessor = remaining.first {
                focusedDocumentId = documentSuccessor
            }
        }
    }

    // Gather members adjacent in the sidebar: a real reorder (orderIndex moves
    // members after the first-added anchor, in pane order); on dissolve they stay
    // where they gathered. ponytail: members in different TabGroups stay in their
    // own sections — gathering only orders within a section.
    private func gatherSplitTabs(tabs: [Tab]) {
        guard let anchorId = splitTabIds.first else { return }
        let ordered = tabs.sorted { $0.orderIndex < $1.orderIndex }
        let members = splitTabIds.compactMap { id in ordered.first { $0.id == id } }
        var rest = ordered.filter { $0.id == anchorId || !splitTabIds.contains($0.id) }
        guard let anchorPos = rest.firstIndex(where: { $0.id == anchorId }) else { return }
        rest.replaceSubrange(anchorPos...anchorPos, with: members)
        for (index, tab) in rest.enumerated() where tab.orderIndex != index {
            tab.orderIndex = index
        }
    }

    // Restore the persisted split at launch. Unresolved ids (closed on another
    // device, incognito tabs that died with the app) are silently dropped; fewer
    // than 2 survivors means a plain single view.
    func restoreSplit(from tabs: [Tab]) {
        guard let strings = UserDefaults.standard.stringArray(forKey: Self.splitKey) else { return }
        // Pane ids resolve against the tab list first, then the active
        // workspace's documents (ADR 0008); unresolved ids drop as before.
        let isDocument = isDocumentPaneId ?? { _ in false }
        let ids = strings.compactMap(UUID.init(uuidString:)).filter { id in
            tabs.contains { $0.id == id } || isDocument(id)
        }
        guard ids.count >= 2 else {
            if !strings.isEmpty { UserDefaults.standard.removeObject(forKey: Self.splitKey) }
            return
        }
        splitTabIds = ids
        if let selected = selectedTabId, !ids.contains(selected) {
            // selectedTabId stays tabs-only; an all-document split focuses its
            // first pane through focusedDocumentId instead.
            if let firstTab = ids.first(where: { id in tabs.contains { $0.id == id } }) {
                selectedTabId = firstTab
            } else {
                focusedDocumentId = ids.first
            }
        }
    }

    /// Which tab takes focus when `tab` is closed. Tabs opened from this one are a
    /// reading queue: focus its first child, then its next sibling as each is closed,
    /// so ⌘-clicking a pile of links and closing them walks the pile in click order.
    /// Otherwise: the tab before it, or the one after when closing the first tab.
    private func neighbor(of tab: Tab, in tabs: [Tab]) -> UUID? {
        if let child = tabs.first(where: { $0.openerId == tab.id && $0.id != tab.id }) {
            return child.id
        }
        if let opener = tab.openerId,
           let index = tabs.firstIndex(where: { $0.id == tab.id }),
           let sibling = tabs[tabs.index(after: index)...].first(where: { $0.openerId == opener }) {
            return sibling.id
        }
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return tabs.first?.id }
        if index > 0 { return tabs[index - 1].id }
        return tabs.count > 1 ? tabs[index + 1].id : nil
    }

    /// `reason` is required, not defaulted: this function has roughly fifteen
    /// callers and most of them are housekeeping (blank-tab cleanup, JS
    /// window.close(), container deletion, undoing an automatic link open). A
    /// default would silently misfile whichever call site is added next, and
    /// closing a tab in a workspace is how the user REJECTS a source.
    func closeTab(_ tab: Tab, tabs: [Tab], reason: TabCloseReason) {
        // Closing is rejection, and that is the whole of what it writes: a
        // disposition. No capture, no archive, no web view retained past the
        // close. See docs/phase1-design.md §3 and ADR 0007.
        // The ref's pre-close state rides the snapshot so ⇧⌘T un-writes the
        // rejection, not just the tab (SPEC's undo-close debt).
        var wroteDismissed = false
        var priorDispositionRaw: String?
        if reason == .userRejected, tab.sessionKind != .incognito, let workspaceId = tab.workspaceId {
            if let url = tab.url, !url.absoluteString.isEmpty {
                wroteDismissed = true
                priorDispositionRaw = ledgerStore?.priorDisposition(url: url, workspaceId: workspaceId)?.rawValue
            }
            ledgerStore?.recordRejection(url: tab.url, title: tab.title, workspaceId: workspaceId)
        }

        automaticLinkOpeners.removeValue(forKey: tab.id)
        automaticLinkOpeners = automaticLinkOpeners.filter { $0.value != tab.id }

        // Resolve the focus target while the list still contains the tab.
        let successor = neighbor(of: tab, in: tabs)
        let remaining = tabs.filter { $0.id != tab.id }

        // Closing a fast-forwarded pane is the "no thanks" — record the verdict
        // before the tab goes away.
        let fastForward = fastForward
        Task { @MainActor [weak fastForward] in
            fastForward?.paneClosed(tab.id)
        }

        // Closing a split member collapses just its pane; focus moves to another
        // member so the dissolve-on-outside-selection rule doesn't tear down the rest.
        if splitTabIds.contains(tab.id) {
            removeFromSplit(tab.id)
        }
        // If a document pane holds (or just inherited) focus, the selection
        // reassignments below must not steal it — selectedTabId's didSet clears
        // document focus, so it is restored after the selection settles.
        let documentSuccessor = focusedDocumentId

        // Incognito tabs are in-memory and ephemeral: no closed-tab snapshot (privacy),
        // just drop the tab and wipe its jar once the session has no tabs left.
        if tab.sessionKind == .incognito {
            webViewManager?.removeWebView(for: tab.id)
            incognitoTabs.removeAll { $0.id == tab.id }
            if let sid = tab.sessionId, !incognitoTabs.contains(where: { $0.sessionId == sid }) {
                webViewManager?.discardIncognitoStore(sid)
            }
            if selectedTabId == tab.id { selectedTabId = successor }
            if remaining.isEmpty {
                terminateApplication()
            } else {
                ensureSelectedTab(from: remaining)
                if let documentSuccessor { focusedDocumentId = documentSuccessor }
            }
            return
        }

        // Snapshot before any mutation/deletion so reopen works safely
        closedTabs.append(ClosedTabSnapshot(
            title: tab.title,
            url: tab.url,
            historyStrings: tab.historyStrings,
            sessionKind: tab.sessionKind,
            sessionId: tab.sessionId,
            preferredEngine: tab.preferredEngine,
            workspaceId: tab.workspaceId,
            wroteDismissed: wroteDismissed,
            priorDispositionRaw: priorDispositionRaw,
            undoGroup: pendingUndoGroup
        ))

        // Clean up the web view for this tab
        webViewManager?.removeWebView(for: tab.id)

        // Open-only tab sync: don't delete the record (deleting would propagate the
        // close to your other devices). Hide it on this device via the local closed-set.
        if TabSync.enabled && TabSync.mode == .openOnly {
            TabSync.markLocallyClosed(tab.id)
            if selectedTabId == tab.id { selectedTabId = successor }
            if remaining.isEmpty {
                terminateApplication()
            } else {
                ensureSelectedTab(from: remaining)
                if let documentSuccessor { focusedDocumentId = documentSuccessor }
            }
            return
        }

        modelContext?.delete(tab)
        if selectedTabId == tab.id {
            selectedTabId = successor
        }
        if remaining.isEmpty {
            // Inside a workspace an empty tab set means "I'm done here", not
            // "quit": suspend back to the default workspace instead. Otherwise
            // closing the last tab would both reject every source and terminate.
            if activeWorkspaceId != nil {
                if let modelContext { try? modelContext.save() }
                suspendWorkspace()
                return
            }
            // Persist the deletion before termination so relaunch starts from an
            // actually empty session rather than restoring the tab just closed.
            if let modelContext { try? modelContext.save() }
            terminateApplication()
        } else {
            ensureSelectedTab(from: remaining)
            if let documentSuccessor { focusedDocumentId = documentSuccessor }
        }
    }

    // MARK: Workspaces

    /// A page finished loading. Starts the settle clock: if the tab is still on
    /// this page 20 seconds from now, it enters the ledger. Any further
    /// navigation restarts it, so only the page actually dwelt on is recorded.
    func notePageFinished(tab: Tab, webView: WKWebView?, tabs: [Tab]) {
        // Seen-before surfacing runs on arrival, whatever brought you here.
        if tab.id == selectedTabId, tab.sessionKind != .incognito {
            NotificationCenter.default.post(name: .browserPageArrived, object: tab.url)
        }
        settleCapture?.pageDidSettleEventually(
            tab: tab,
            webView: webView,
            openedFromSourceId: openerSourceId(for: tab, tabs: tabs)
        )
    }

    /// Deliberate capture of one tab into the active workspace.
    @discardableResult
    func captureSourceNow(tab: Tab) -> Bool {
        // existingWebView, not getWebView: capturing must never bring a web view
        // into being as a side effect.
        settleCapture?.captureNow(tab: tab, webView: webViewManager?.existingWebView(for: tab.id)) ?? false
    }

    /// The source a tab was opened FROM, when it was spawned by another tab in
    /// the same workspace. Phase 1 records this as provenance lineage; Phase 4's
    /// graph renders the fan-to-common-ancestor pattern from it.
    func openerSourceId(for tab: Tab, tabs: [Tab]) -> UUID? {
        guard let openerId = tab.openerId,
              let opener = tabs.first(where: { $0.id == openerId }),
              opener.workspaceId == tab.workspaceId,
              let url = opener.url
        else { return nil }
        return ledgerStore?.source(sourceKey: SourceCanonicalizer.canonicalKey(for: url))?.id
    }


    /// Leaving a workspace. Tabs keep their workspaceId and simply stop being
    /// shown; their web views go through the same release path the memory saver
    /// uses. Nothing is written to the ledger.
    func suspendWorkspace() {
        guard activeWorkspaceId != nil else { return }
        splitTabIds = []
        focusedDocumentId = nil
        activeWorkspaceId = nil
        selectedTabId = nil
    }

    /// Entering a workspace. Restore is just the filter changing — nothing is
    /// recreated, because nothing was ever discarded.
    func enterWorkspace(_ id: UUID, tabs: [Tab]) {
        guard activeWorkspaceId != id else { return }
        splitTabIds = []
        focusedDocumentId = nil
        activeWorkspaceId = id
        selectedTabId = nil
        ensureSelectedTab(from: tabs.filter { $0.workspaceId == id })
    }

    /// Turn the default workspace into a real one: every tab in this window with
    /// no workspace joins it. Those tabs have no ledger references — capture only
    /// fires inside a workspace — so the caller captures them immediately rather
    /// than waiting for a re-navigation that may never come.
    @discardableResult
    func promoteDefaultWorkspace(named name: String, tabs: [Tab], orderIndex: Int) -> Workspace? {
        guard activeWorkspaceId == nil, let modelContext else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let workspace = Workspace(name: trimmed, orderIndex: orderIndex)
        modelContext.insert(workspace)

        // Incognito tabs are never workspace members, and tabs already owned by
        // another workspace are not in this window's default set to begin with.
        let promoted = tabs.filter { $0.workspaceId == nil && $0.sessionKind != .incognito }
        for tab in promoted { tab.workspaceId = workspace.id }
        try? modelContext.save()

        if let ledgerStore {
            for tab in promoted {
                guard let url = tab.url else { continue }
                ledgerStore.recordManualCapture(
                    url: url,
                    title: tab.title,
                    workspaceId: workspace.id
                )
            }
        }
        activeWorkspaceId = workspace.id
        return workspace
    }


    func duplicateTab(_ tab: Tab) -> Tab {
        let newTab = createTab(
            inheriting: tab.browsingContext,
            url: tab.url
        )
        newTab.memoryPolicy = tab.memoryPolicy
        // Update the title to use the domain name
        newTab.updateTitleFromURL()
        return newTab
    }

    func deleteTabs(at offsets: IndexSet, tabs: [Tab]) {
        for index in offsets {
            let tab = tabs[index]
            closeTab(tab, tabs: tabs, reason: .userRejected)
        }
    }

    func closeTabSet(tabs: [Tab]) {
        let hasSplitTabs = splitTabIds.count >= 2
        let targetIds = (hasSplitTabs ? splitTabIds : [selectedTabId].compactMap { $0 })
            .filter { id in tabs.contains { $0.id == id } }

        guard !targetIds.isEmpty else { return }

        // The whole set is one gesture, so one ⇧⌘T undoes it as one unit.
        pendingUndoGroup = targetIds.count > 1 ? UUID() : nil
        defer { pendingUndoGroup = nil }

        var remaining = tabs
        for id in targetIds {
            guard let tab = remaining.first(where: { $0.id == id }) else { continue }
            closeTab(tab, tabs: remaining, reason: .userRejected)
            remaining.removeAll { $0.id == id }
        }
    }

    func reopenLastClosedTab() -> Tab? {
        guard let last = closedTabs.last else { return nil }

        // A multi-pane close (⌘W on a split) stacked its members contiguously
        // under one group id; reopen them all as the single unit they were.
        var snapshots: [ClosedTabSnapshot] = []
        if let group = last.undoGroup {
            while let next = closedTabs.last, next.undoGroup == group {
                snapshots.append(closedTabs.removeLast())
            }
        } else {
            snapshots.append(closedTabs.removeLast())
        }

        // Reopen in close order so sidebar order comes back out roughly right;
        // the last snapshot popped (closed first) is restored first.
        var lastReopened: Tab?
        for snapshot in snapshots.reversed() {
            lastReopened = reopen(snapshot)
        }
        return lastReopened
    }

    private func reopen(_ snapshot: ClosedTabSnapshot) -> Tab {
        // Old snapshots had no session fields and decode as normal. Incognito tabs
        // are never snapshotted; if one is encountered, createTab still keeps it
        // memory-only rather than persisting its URL.
        let newTab = createTab(
            inheriting: BrowsingContext(
                sessionKind: snapshot.sessionKind ?? .normal,
                sessionId: snapshot.sessionId,
                preferredEngine: snapshot.preferredEngine ?? .webKit
            ),
            url: snapshot.url
        )
        newTab.historyStrings = snapshot.historyStrings
        newTab.currentHistoryIndex = snapshot.historyStrings.isEmpty ? -1 : snapshot.historyStrings.count - 1

        // Membership is permanent (ADR 0007): the tab returns to its workspace,
        // not to whichever one happens to be active now.
        if let workspaceId = snapshot.workspaceId {
            newTab.workspaceId = workspaceId
        }
        // The close wrote `dismissed`; undoing the close un-writes it.
        if snapshot.wroteDismissed == true, let workspaceId = snapshot.workspaceId {
            ledgerStore?.undoRejection(
                url: snapshot.url,
                workspaceId: workspaceId,
                priorDispositionRaw: snapshot.priorDispositionRaw
            )
        }

        // Update the title to use the domain name
        newTab.updateTitleFromURL()

        return newTab
    }

    func getActiveTab(from tabs: [Tab]) -> Tab? {
        tabs.first { $0.id == selectedTabId }
    }

    func updateActiveTab(in tabs: [Tab]) {
        tabs.forEach { $0.isActive = false }
        if let activeTab = getActiveTab(from: tabs) {
            activeTab.isActive = true
            activeTab.lastAccessed = Date()
        }
    }

    func updateTabTitle(_ tab: Tab) {
        tab.updateTitleFromURL()
    }

    func switchToNextTab(tabs: [Tab]) {
        guard !SettingsManager.shared.recentTabCycling else { return cycleRecentTab(forward: true, tabs: tabs) }
        guard let currentIndex = tabs.firstIndex(where: { $0.id == selectedTabId }) else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
        selectedTabId = tabs[nextIndex].id
    }

    func switchToPreviousTab(tabs: [Tab]) {
        guard !SettingsManager.shared.recentTabCycling else { return cycleRecentTab(forward: false, tabs: tabs) }
        guard let currentIndex = tabs.firstIndex(where: { $0.id == selectedTabId }) else { return }
        let previousIndex = currentIndex == 0 ? tabs.count - 1 : currentIndex - 1
        selectedTabId = tabs[previousIndex].id
    }

    // MARK: - Most-recently-used cycling

    // ⌘Tab semantics: the tab you're on is slot 0, the one you came from slot 1,
    // and so on. The order is frozen for the length of one hold — otherwise the
    // second press would bounce straight back to where the first press started —
    // and only commits when the hold ends (endRecentTabCycle, driven by the
    // Control key going up).
    private(set) var recentTabIds: [UUID] = []
    private var cycleSnapshot: [UUID]?
    private var cycleIndex = 0

    func cycleRecentTab(forward: Bool, tabs: [Tab]) {
        guard !tabs.isEmpty else { return }
        let order = cycleSnapshot ?? recentOrder(of: tabs)
        guard !order.isEmpty else { return }
        cycleSnapshot = order
        let step = forward ? 1 : -1
        cycleIndex = ((cycleIndex + step) % order.count + order.count) % order.count
        selectedTabId = order[cycleIndex]
    }

    /// The hold ended: whatever you landed on becomes the new slot 0.
    func endRecentTabCycle() {
        guard cycleSnapshot != nil else { return }
        cycleSnapshot = nil
        cycleIndex = 0
        if let id = selectedTabId { promoteRecentTab(id) }
    }

    private func noteSelectionForRecentOrder() {
        guard let id = selectedTabId else { return }
        guard let snapshot = cycleSnapshot else { return promoteRecentTab(id) }
        // Still walking the frozen list — nothing to record yet.
        if cycleIndex < snapshot.count, snapshot[cycleIndex] == id { return }
        // A selection that didn't come from the cycle (a click, a close, a ⌘1)
        // ends it, so the frozen order can never get stuck. The tab the cycle
        // had reached still counts as visited, just less recently than this one.
        let landed = cycleIndex < snapshot.count ? snapshot[cycleIndex] : nil
        cycleSnapshot = nil
        cycleIndex = 0
        if let landed { promoteRecentTab(landed) }
        promoteRecentTab(id)
    }

    private func promoteRecentTab(_ id: UUID) {
        recentTabIds.removeAll { $0 == id }
        recentTabIds.insert(id, at: 0)
    }

    // ponytail: linear scans over an open-tab list; nobody has thousands of tabs.
    private func recentOrder(of tabs: [Tab]) -> [UUID] {
        let live = Set(tabs.map(\.id))
        var order = recentTabIds.filter { live.contains($0) }
        let seen = Set(order)
        // Tabs restored at launch have no recorded history yet, so fall back to
        // the timestamp SwiftData already keeps.
        order += tabs.filter { !seen.contains($0.id) }
            .sorted { $0.lastAccessed > $1.lastAccessed }
            .map(\.id)
        if let current = selectedTabId, let index = order.firstIndex(of: current), index != 0 {
            order.remove(at: index)
            order.insert(current, at: 0)
        }
        return order
    }

    func switchToTab(at index: Int, tabs: [Tab]) {
        guard index >= 0 && index < tabs.count else {
            Logger.log("TabManager switchToTab: invalid index \(index), tabs.count = \(tabs.count)", type: "TabManager")
            return
        }
        let tab = tabs[index]
        Logger.log("TabManager switchToTab: switching to index \(index)", type: "TabManager")
        selectedTabId = tab.id
    }

    func reorderTabs(sourceTabId: UUID, targetTabId: UUID, tabs: [Tab]) {
        Logger.log("TabManager reorderTabs called: sourceTabId=\(sourceTabId), targetTabId=\(targetTabId)", type: "TabManager")
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == sourceTabId }),
              let targetIndex = tabs.firstIndex(where: { $0.id == targetTabId }),
              sourceIndex != targetIndex else {
            Logger.log("TabManager reorderTabs: invalid indices or same tab", type: "TabManager")
            return
        }

        Logger.log("TabManager reorderTabs: sourceIndex=\(sourceIndex), targetIndex=\(targetIndex)", type: "TabManager")

        // Create a mutable copy of the tabs array to work with
        var reorderedTabs = tabs

        // Remove the source tab and insert it at the row it crossed. Using
        // targetIndex - 1 for a forward move leaves adjacent rows unchanged,
        // which made a drop feel ignored and makes live hover reordering jitter.
        let sourceTab = reorderedTabs.remove(at: sourceIndex)
        reorderedTabs.insert(sourceTab, at: targetIndex)

        // Update orderIndex for all tabs
        for (index, tab) in reorderedTabs.enumerated() {
            tab.orderIndex = index
        }

        Logger.log("Reordered tabs: new order: \(reorderedTabs.map { $0.id })", type: "TabManager")
    }

    /// Ensures there is always a selected tab when tabs are available
    func ensureSelectedTab(from tabs: [Tab]) {
        // If there are no tabs, there's nothing to select
        guard !tabs.isEmpty else {
            selectedTabId = nil
            return
        }

        // If we already have a valid selected tab, keep it
        if let selectedId = selectedTabId, tabs.contains(where: { $0.id == selectedId }) {
            return
        }

        // Otherwise, select the first available tab
        selectedTabId = tabs.first?.id
        Logger.log("TabManager ensureSelectedTab: No valid selected tab found, selecting first tab: \(selectedTabId?.uuidString ?? "nil")", type: "TabManager")
    }
}
