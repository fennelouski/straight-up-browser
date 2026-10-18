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

extension Notification.Name {
    static let browserAppRequestedTabNavigation = Notification.Name("browserAppRequestedTabNavigation")
}

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
            if let windowID {
                BrowserProfile.defaults.set(selectedTabId?.uuidString, forKey: "selectedTabId." + windowID.uuidString)
            }
            // Selecting any tab takes focus back from a document pane (ADR 0008).
            if oldValue != selectedTabId { focusedDocumentId = nil }
            noteSelectionForRecentOrder()
            if !splitTabIds.isEmpty, let id = selectedTabId, !splitTabIds.contains(id) {
                splitTabIds = []
            }
            if !applyingPaneLayout, !restoringPaneLayout, let tree = paneLayout {
                persistPaneLayoutRecovery(tree, focus: focusedDocumentId ?? selectedTabId)
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
        didSet {
            // Private membership must never become a disk-backed recovery record.
            let privateIDs = Set(incognitoTabs.map(\.id))
            let publicIDs = splitTabIds.filter { !privateIDs.contains($0) }
            BrowserProfile.defaults.set(publicIDs.map(\.uuidString), forKey: persistenceKey(Self.splitKey))
            if !applyingPaneLayout {
                let changedGate = refreshPaneLayoutRollout()
                if paneLayoutsEnabled {
                    if !changedGate { reconcilePaneLayout() }
                } else {
                    // Legacy membership still works, but the v2 tree remains
                    // untouched until an explicit rollout enable.
                    disabledPreviewLayout = nil
                    paneLayoutRevision &+= 1
                }
            }
        }
    }
    @Published private(set) var paneLayout: PaneLayoutTree?
    @Published private(set) var paneLayoutRevision: UInt64 = 0
    @Published private(set) var canUndoPaneLayout = false
    @Published private(set) var canRedoPaneLayout = false
    @Published private(set) var paneLayoutsEnabled: Bool
    let coldLayoutStarters = ColdLayoutStarterScheduler()
    @Published private(set) var coldLayoutStarterStateRevision: UInt64 = 0
    private var explicitColdStarterOverrides = Set<UUID>()
    var onColdStarterPumpRequested: (() -> Void)?
    var canRetryColdStarter: ((UUID, URL) -> Bool)?
    private let paneLayoutDefaults: UserDefaults
    private var paneRolloutObserverTokens: [NSObjectProtocol] = []
    private var paneRecoveryWriteBlocked = false
    private var retainedPaneWorkspaceID: UUID?
    private var disabledPreviewLayout: PaneLayoutTree?
    private var disabledPreviewMembers: [PaneContentReference] = []
    /// The stable AppKit host supplies viewport validation; nil in pure model tests.
    var paneLayoutFits: ((PaneLayoutTree) -> Bool)?
    private var applyingPaneLayout = false
    private var restoringPaneLayout = false
    private var paneLayoutUndo: [(tree: PaneLayoutTree, focus: UUID?)] = []
    private var paneLayoutRedo: [(tree: PaneLayoutTree, focus: UUID?)] = []
    private var paneIDsByContent: [UUID: UUID] = [:]
    private var liveRecipeBindings: [UUID: [UUID: UUID]] = [:]
    private final class WeakLayoutOwner { weak var manager: TabManager?; init(_ manager: TabManager) { self.manager = manager } }
    private static var liveLayoutOwners: [UUID: WeakLayoutOwner] = [:]
    @Published private(set) var activeLayoutRecipeID: UUID?
    @Published private(set) var maximizedPaneContentID: UUID?
    private var paneFocusBeforeMaximize: UUID?
    private var savedLiveLayoutTree: PaneLayoutTree?
    var hasUnsavedPaneLayoutChanges: Bool {
        let retainedMatches = paneLayout?.panes.map(\.content) == currentPaneMembers && retainedPaneWorkspaceID == activeWorkspaceId
        return activeLayoutRecipeID != nil && (retainedMatches ? paneLayout : currentPaneLayout()) != savedLiveLayoutTree
    }
    // A Split is an arrangement of 2–4 PANES: tabs or workspace documents
    // (ADR 0008). splitTabIds keeps its name and persistence key but holds pane
    // ids; each resolves against the tab list first, then the active workspace's
    // documents, and unresolved ids are dropped by the existing restore rule.
    //
    // Non-nil = a document owns focus (omnibar shows its name, ⌘W closes its
    // pane and never writes a disposition). selectedTabId stays tabs-only so its
    // many call sites keep meaning what they meant; selecting any tab clears this.
    @Published var focusedDocumentId: UUID? {
        didSet {
            if !applyingPaneLayout, !restoringPaneLayout, let tree = paneLayout {
                persistPaneLayoutRecovery(tree, focus: focusedDocumentId ?? selectedTabId)
            }
        }
    }

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

    // Set once on an eligible app launch by the engagement observer.
    @Published var offerDefaultBrowser = false

    // Presentational only: link provenance below owns behavior; this value just
    // lets both sidebar rows perform the same short birth animation.
    @Published private(set) var automaticLinkBirthCue: AutomaticLinkBirthCue?

    private static let closedTabsKey = "closedTabsStack"
    private static let maxClosedTabs = 25
    private static let splitKey = "splitTabIds"
    static let activeWorkspaceKey = "activeWorkspaceId"

    static func restoredActiveWorkspaceId() -> UUID? {
        BrowserProfile.defaults.string(forKey: activeWorkspaceKey).flatMap(UUID.init(uuidString:))
    }
    static var maxSplitTabs: Int {
        PaneLayoutRolloutPolicy.newMembershipLimit(enabled: BrowserProfile.defaults.bool(forKey: PaneLayoutRolloutPolicy.defaultsKey))
    }
    private var paneMembershipLimit: Int {
        PaneLayoutRolloutPolicy.newMembershipLimit(enabled: paneLayoutDefaults.bool(forKey: PaneLayoutRolloutPolicy.defaultsKey))
    }

    let windowID: UUID?
    let homeWorkspaceID: UUID?
    private func persistenceKey(_ key: String) -> String {
        windowID.map { key + "." + $0.uuidString } ?? key
    }

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
                BrowserProfile.defaults.set(id.uuidString, forKey: persistenceKey(Self.activeWorkspaceKey))
            } else {
                BrowserProfile.defaults.removeObject(forKey: persistenceKey(Self.activeWorkspaceKey))
            }
            #if os(macOS)
            if let windowID { BrowserWindows.shared.setWorkspace(activeWorkspaceId, for: windowID) }
            #endif
            // Document panes and their edit sessions belong to the workspace
            // being left; the owner (ContentView / BrowserView_iOS) closes and
            // discards them here so they don't accumulate across switches.
            if oldValue != activeWorkspaceId {
                cancelColdLayoutStarters(reason: .workspaceChanged)
                workspaceSwitched?()
            }
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
        windowID: UUID? = nil,
        homeWorkspaceID: UUID? = nil,
        webViewManager: WebViewManager? = nil,
        paneLayoutDefaults: UserDefaults = BrowserProfile.defaults,
        terminateApplication: @escaping () -> Void = defaultTerminateApplication
    ) {
        self.windowID = windowID
        self.homeWorkspaceID = homeWorkspaceID
        self.modelContext = modelContext
        self.webViewManager = webViewManager
        self.paneLayoutDefaults = paneLayoutDefaults
        self.paneLayoutsEnabled = paneLayoutDefaults.bool(forKey: PaneLayoutRolloutPolicy.defaultsKey)
        self.terminateApplication = terminateApplication
        super.init()
        connectColdStarterHooks()
        #if os(macOS)
        // Preserve the original window's split and undo stack on upgrade.
        if let windowID, BrowserWindows.shared.records.first?.id == windowID {
            for key in [Self.closedTabsKey, Self.splitKey] {
                let scoped = persistenceKey(key)
                if BrowserProfile.defaults.object(forKey: scoped) == nil,
                   let legacy = BrowserProfile.defaults.object(forKey: key) {
                    BrowserProfile.defaults.set(legacy, forKey: scoped)
                    BrowserProfile.defaults.removeObject(forKey: key)
                }
            }
        }
        #endif
        if let data = BrowserProfile.defaults.data(forKey: persistenceKey(Self.closedTabsKey)),
           let saved = try? JSONDecoder().decode([ClosedTabSnapshot].self, from: data) {
            closedTabs = saved
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(historyDidClear),
            name: .browserHistoryDidClear,
            object: nil
        )
        paneRolloutObserverTokens.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: paneLayoutDefaults, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPaneLayoutRollout() }
        })
        paneRolloutObserverTokens.append(NotificationCenter.default.addObserver(forName: .browserAppRequestedTabNavigation, object: nil, queue: .main) { [weak self] note in
            let id = note.object as? UUID
            Task { @MainActor [weak self] in if let id { self?.noteExplicitColdStarterNavigation(id) } }
        })
    }

    // Keep only the most recent entries on disk; the in-session stack is small
    // by nature (you'd have to close thousands of tabs to grow it).
    private func persistClosedTabs() {
        let capped = Array(closedTabs.suffix(Self.maxClosedTabs))
        guard !capped.isEmpty else {
            BrowserProfile.defaults.removeObject(forKey: persistenceKey(Self.closedTabsKey))
            return
        }
        if let data = try? JSONEncoder().encode(capped) {
            BrowserProfile.defaults.set(data, forKey: persistenceKey(Self.closedTabsKey))
        }
    }

    static func clearPersistedClosedTabs() {
        for key in BrowserProfile.defaults.dictionaryRepresentation().keys
            where key == closedTabsKey || key.hasPrefix(closedTabsKey + ".") {
            BrowserProfile.defaults.removeObject(forKey: key)
        }
    }

    func purgeClosedTabs(forSession sessionId: UUID) {
        closedTabs.removeAll { $0.sessionId == sessionId }
    }

    @objc private func historyDidClear() {
        closedTabs.removeAll()
    }

    isolated deinit {
        paneRolloutObserverTokens.forEach { NotificationCenter.default.removeObserver($0) }
        NotificationCenter.default.removeObserver(self)
    }

    func setModelContext(_ modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func setWebViewManager(_ webViewManager: WebViewManager) {
        self.webViewManager = webViewManager
        connectColdStarterHooks()
    }

    private func connectColdStarterHooks() {
        webViewManager?.shouldDeferColdLayoutStarter = { [weak self] id in self?.shouldDeferColdLayoutStarter(id) ?? false }
        webViewManager?.onWebViewDisposed = { [weak self] id, closed in
            guard let self else { return }
            if let permit = self.coldLayoutStarters.activePermit(for: id) {
                // removeWebView has actually stopped and disposed this engine;
                // no navigation delegate terminal is guaranteed after disposal.
                self.coldLayoutStarters.terminal(permit.token, outcome: .terminated)
            }
            if closed { self.coldLayoutStarters.forgetDeferredTab(id); self.explicitColdStarterOverrides.remove(id) }
            self.noteColdStarterStateChanged()
        }
    }

    func shouldDeferColdLayoutStarter(_ id: UUID) -> Bool {
        !explicitColdStarterOverrides.contains(id) && coldLayoutStarters.ownsStarter(id)
    }

    func prepareColdStarterAdmission() -> Bool {
        refreshPaneLayoutRollout()
        return paneLayoutsEnabled
    }

    func noteColdStarterStateChanged() {
        coldLayoutStarterStateRevision &+= 1
        onColdStarterPumpRequested?()
    }

    func cancelColdLayoutStarters(reason: ColdLayoutStarterScheduler.CancellationReason) {
        coldLayoutStarters.cancelPending(reason: reason)
        noteColdStarterStateChanged()
    }

    /// Called only by explicit browser navigation or the labeled Load action,
    /// never from generic selection (Undo/workspace focus is not user intent).
    func noteExplicitColdStarterNavigation(_ id: UUID) {
        guard coldLayoutStarters.ownsStarter(id) else { return }
        coldLayoutStarters.cancelForManualNavigation(tabID: id)
        explicitColdStarterOverrides.insert(id)
        noteColdStarterStateChanged()
    }

    func loadDeferredLayoutStarter(_ id: UUID, tabs: [Tab]) throws {
        try requirePaneLayoutRollout()
        guard coldLayoutStarters.isDeferred(id), let tab = tabs.first(where: { $0.id == id }),
              tab.workspaceId == activeWorkspaceId,
              splitTabIds.isEmpty ? selectedTabId == id : splitTabIds.contains(id) else { throw PaneLayoutError.unavailableContent }
        if coldLayoutStarters.pendingTabIDs.contains(id) {
            // Promote a still-queued page; the explicit button must not bypass
            // the automatic two-load budget while this restore remains live.
            selectedTabId = id
            noteColdStarterStateChanged()
            return
        }
        guard let original = coldLayoutStarters.registeredStarter(for: id), let startingURL = original.startingURL,
              tab.sessionId == original.profileID, tab.sessionKind != .incognito,
              tab.url == startingURL || canRetryColdStarter?(id, startingURL) == true,
              coldLayoutStarters.retryDeferredStarter(starter: original,
                                                     workspaceID: activeWorkspaceId, layoutRevision: paneLayoutRevision, gateEnabled: paneLayoutsEnabled) else { throw PaneLayoutError.unavailableContent }
        tab.url = startingURL
        noteColdStarterStateChanged()
        // A saved-page retry remains subject to the same budget, including
        // retired generations. Only a new browser navigation bypasses it.
        selectedTabId = id
    }

    @discardableResult
    func createNewTab(
        url: URL? = nil,
        select: Bool = true,
        preferredEngine: BrowserEngine = .webKit,
        after source: Tab? = nil
    ) -> Tab {
        let newTab = Tab(title: String(localized: "New Tab"), url: url, isActive: false)
        newTab.preferredEngine = preferredEngine
        newTab.openerId = source?.id ?? selectedTabId
        // Link tabs stay with their source; other new tabs join the active workspace.
        newTab.workspaceId = source == nil ? activeWorkspaceId : source?.workspaceId
        newTab.groupId = source?.groupId
        newTab.isPinned = source?.isPinned ?? false
        newTab.memoryPolicy = MemoryPolicy(rawValue:
            BrowserProfile.defaults.string(forKey: "memorySaverDefaultPolicy") ?? "") ?? .whenNeeded
        if url != nil {
            newTab.updateTitleFromURL()
        }
        if let modelContext = modelContext {
            // Order before insert: without this every tab keeps orderIndex 0 and the
            // sidebar sorts the whole pile arbitrarily. Popups were the visible
            // symptom — one would appear at the top of the list, nowhere near the
            // tab that opened it. Matches what createIncognitoTab already does.
            let existing = (try? modelContext.fetch(FetchDescriptor<Tab>())) ?? []
            if let current = source ?? existing.first(where: { $0.id == selectedTabId }) {
                // Explicit links land immediately after their source. Other
                // new-tab commands retain the existing child-queue ordering.
                let anchor = source?.orderIndex ?? existing
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
        preferredEngine: BrowserEngine = .webKit,
        after source: Tab? = nil
    ) -> Tab {
        let tab = Tab(title: String(localized: "New Tab"), url: nil, isActive: false)
        tab.preferredEngine = preferredEngine
        tab.sessionKind = .incognito
        tab.sessionId = sessionId ?? UUID()
        tab.openerId = source?.id ?? selectedTabId
        tab.workspaceId = source?.workspaceId
        tab.groupId = source?.groupId
        tab.isPinned = source?.isPinned ?? false
        // In-memory only: never unload (there's no SwiftData row to restore from).
        tab.memoryPolicy = .never
        if let source {
            for existing in incognitoTabs where existing.orderIndex > source.orderIndex { existing.orderIndex += 1 }
            tab.orderIndex = source.orderIndex + 1
        } else {
            tab.orderIndex = (incognitoTabs.map(\.orderIndex).max() ?? 1_000_000) + 1
        }
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
        select: Bool = true,
        after source: Tab? = nil
    ) -> Tab {
        switch context.sessionKind {
        case .normal:
            return createNewTab(
                url: url,
                select: select,
                preferredEngine: context.preferredEngine,
                after: source
            )
        case .incognito:
            let tab = createIncognitoTab(
                sessionId: context.sessionId,
                select: select,
                preferredEngine: context.preferredEngine,
                after: source
            )
            if let url { tab.navigateTo(url); tab.updateTitleFromURL() }
            return tab
        case .container:
            let tab = createNewTab(
                url: url,
                select: select,
                preferredEngine: context.preferredEngine,
                after: source
            )
            tab.sessionKind = .container
            tab.sessionId = context.sessionId
            webViewManager?.registerSession(for: tab.id, kind: .container, sessionId: context.sessionId)
            return tab
        }
    }

    /// Explicit link opens always select their destination, independent of chrome visibility.
    @discardableResult
    func openLinkInNewTab(_ url: URL, from source: Tab?) -> Tab {
        createTab(inheriting: source?.browsingContext ?? .normalWebKit,
                  url: url, select: true, after: source)
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
        if splitTabIds.count < paneMembershipLimit {
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
        } else if splitTabIds.count < paneMembershipLimit {
            splitTabIds.append(tab.id)
            gatherSplitTabs(tabs: tabs)
            selectedTabId = tab.id
        }
        // At the cap (4): adding is a no-op.
    }

    /// Explicit creation preserves other blank tabs and the current split at its cap.
    @discardableResult
    func createCommandTab(inSplit: Bool, tabs: [Tab], inheriting context: BrowsingContext) -> Tab? {
        guard !inSplit || splitTabIds.count < Self.maxSplitTabs else { return nil }
        let tab = createTab(inheriting: context, select: !inSplit)
        if inSplit { toggleSplitMembership(tab, tabs: tabs + [tab]) }
        return tab
    }

    /// Reorder the focused web or document pane without changing focus or tab order.
    @discardableResult
    func moveFocusedPane(by offset: Int) -> Bool {
        guard offset == -1 || offset == 1,
              let focused = focusedDocumentId ?? selectedTabId,
              let index = splitTabIds.firstIndex(of: focused),
              splitTabIds.indices.contains(index + offset) else { return false }
        var reordered = splitTabIds
        reordered.swapAt(index, index + offset)
        splitTabIds = reordered
        return true
    }

    // MARK: Document panes (ADR 0008)

    // MARK: Local pane arrangements

    private var currentPaneMembers: [PaneContentReference] {
        splitTabIds.map { isDocumentPaneId?($0) == true ? .document($0) : .tab($0) }
    }

    func setPaneLayoutsEnabled(_ enabled: Bool) {
        paneLayoutDefaults.set(enabled, forKey: PaneLayoutRolloutPolicy.defaultsKey)
        refreshPaneLayoutRollout()
    }

    @discardableResult private func refreshPaneLayoutRollout() -> Bool {
        let enabled = paneLayoutDefaults.bool(forKey: PaneLayoutRolloutPolicy.defaultsKey)
        guard paneLayoutsEnabled != enabled else { return false }
        let currentMembers = currentPaneMembers
        if !enabled {
            cancelColdLayoutStarters(reason: .rolloutDisabled)
            retainedPaneWorkspaceID = activeWorkspaceId
            maximizedPaneContentID = nil
            paneFocusBeforeMaximize = nil
            canUndoPaneLayout = false
            canRedoPaneLayout = false
            // No membership writes or session work on revocation. The native
            // host falls back to nonrecursive geometry for every current ID.
            paneLayoutsEnabled = false
        } else {
            paneLayoutsEnabled = true
            // Recheck current bytes even when the retained live tree wins.
            // An unknown record written while off must never be downgraded by
            // a later focus/reconcile write after re-enabling that same tree.
            let recovery = validatedPaneRecovery(matching: currentMembers)
            let canRetain = paneLayout.map {
                PaneLayoutRolloutPolicy.canRestoreRetainedTree(enabled: enabled, retainedMembers: $0.panes.map(\.content), currentMembers: currentMembers,
                                                              retainedWorkspaceID: retainedPaneWorkspaceID, currentWorkspaceID: activeWorkspaceId)
            } ?? false
            if !canRetain {
                paneLayout = nil
                paneLayoutUndo = []; paneLayoutRedo = []
                // Read recovery only after opt-in. A stale/corrupt record is
                // not authority to change legacy membership or focus.
                if let recovery {
                    paneLayout = recovery.tree
                    for pane in recovery.tree.panes { paneIDsByContent[pane.content.id] = pane.id }
                } else { reconcilePaneLayout() }
            }
            canUndoPaneLayout = !paneLayoutUndo.isEmpty
            canRedoPaneLayout = !paneLayoutRedo.isEmpty
        }
        disabledPreviewLayout = nil
        paneLayoutRevision &+= 1
        return true
    }

    private func requirePaneLayoutRollout() throws {
        refreshPaneLayoutRollout()
        guard paneLayoutsEnabled else { throw PaneLayoutError.rolloutDisabled }
    }

    /// Called by legacy split membership changes too. This makes the old
    /// sidebar reorder use the same tree, rather than maintaining two layouts.
    private func reconcilePaneLayout() {
        guard paneLayoutsEnabled, paneLayoutDefaults.bool(forKey: PaneLayoutRolloutPolicy.defaultsKey) else { return }
        cancelColdLayoutStarters(reason: .layoutChanged)
        if let current = paneLayout {
            for pane in current.panes { paneIDsByContent[pane.content.id] = pane.id }
        }
        guard splitTabIds.count >= 2 else {
            paneLayout = nil
            maximizedPaneContentID = nil
            paneLayoutRevision &+= 1
            return
        }
        let refs = splitTabIds.map { id -> PaneContentReference in
            isDocumentPaneId?(id) == true ? .document(id) : .tab(id)
        }
        if let current = paneLayout,
           let reconciled = try? current.reconciling(refs, anchorContentID: focusedDocumentId ?? selectedTabId) {
            paneLayout = reconciled
            if splitTabIds != reconciled.contentIDs {
                applyingPaneLayout = true
                splitTabIds = reconciled.contentIDs
                applyingPaneLayout = false
            }
        } else {
            paneLayout = PaneLayoutTree.legacy(refs.map { reference in
                let id = paneIDsByContent[reference.id] ?? UUID()
                paneIDsByContent[reference.id] = id
                return LayoutPane(id: id, content: reference)
            })
        }
        if let tree = paneLayout {
            for pane in tree.panes { paneIDsByContent[pane.content.id] = pane.id }
            if !restoringPaneLayout { persistPaneLayoutRecovery(tree, focus: focusedDocumentId ?? selectedTabId) }
        }
        paneLayoutRevision &+= 1
    }

    func currentPaneLayout() -> PaneLayoutTree? {
        if paneLayoutsEnabled, paneLayoutDefaults.bool(forKey: PaneLayoutRolloutPolicy.defaultsKey), let paneLayout { return paneLayout }
        if splitTabIds.count >= 2 {
            let members = currentPaneMembers
            if disabledPreviewMembers != members || disabledPreviewLayout == nil {
                disabledPreviewMembers = members
                disabledPreviewLayout = PaneLayoutTree.legacy(members.map { reference in
                    let id = paneIDsByContent[reference.id] ?? UUID()
                    paneIDsByContent[reference.id] = id
                    return LayoutPane(id: id, content: reference)
                })
            }
            return disabledPreviewLayout
        }
        guard let contentID = focusedDocumentId ?? selectedTabId else { return nil }
        let id = paneIDsByContent[contentID] ?? UUID()
        paneIDsByContent[contentID] = id
        return .pane(LayoutPane(id: id, content: isDocumentPaneId?(contentID) == true ? .document(contentID) : .tab(contentID)))
    }

    func togglePaneMaximize(_ contentID: UUID, tabs: [Tab]) throws {
        try requirePaneLayoutRollout()
        if maximizedPaneContentID != nil {
            maximizedPaneContentID = nil
            if let prior = paneFocusBeforeMaximize, currentPaneLayout()?.contentIDs.contains(prior) == true {
                if isDocumentPaneId?(prior) == true { focusedDocumentId = prior }
                else { selectedTabId = prior }
            }
            paneFocusBeforeMaximize = nil
            paneLayoutRevision &+= 1
            return
        }
        guard let tree = currentPaneLayout(), tree.contentIDs.contains(contentID) else { throw PaneLayoutError.unavailableContent }
        guard !tree.contentIDs.contains(where: { $0 != contentID && paneIsProtected($0, tabs: tabs) }) else { throw PaneLayoutError.protectedPane }
        paneFocusBeforeMaximize = focusedDocumentId ?? selectedTabId
        maximizedPaneContentID = contentID
        if isDocumentPaneId?(contentID) == true { focusedDocumentId = contentID }
        else { selectedTabId = contentID }
        paneLayoutRevision &+= 1
    }

    func paneIsProtected(_ id: UUID, tabs: [Tab]) -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }) else { return false }
        if (tab.memoryPolicy == .never && tab.url != nil) || MemoryPinnedSites.isPinned(tab.url) || LayoutStarterURLPolicy.isMeeting(tab.url) { return true }
        guard let view = webViewManager?.existingWebView(for: id) else { return false }
        return view.microphoneCaptureState != .none || view.cameraCaptureState != .none
    }

    private func validatePaneContent(_ tree: PaneLayoutTree, tabs: [Tab], plannedIDs: Set<UUID> = []) throws {
        // Read-only previews remain available even before rollout. Mutation
        // entry points separately enforce the default-off rollout gate.
        _ = try tree.validated(maximumPanes: PaneLayoutRolloutPolicy.newMembershipLimit(enabled: true))
        for pane in tree.panes {
            switch pane.content {
            case .tab(let id):
                guard plannedIDs.contains(id) || tabs.contains(where: { $0.id == id }) else { throw PaneLayoutError.unavailableContent }
            case .document(let id):
                guard isDocumentPaneId?(id) == true else { throw PaneLayoutError.unavailableContent }
            }
        }
        let visible = currentPaneLayout()?.contentIDs ?? []
        guard !visible.contains(where: { !tree.contentIDs.contains($0) && paneIsProtected($0, tabs: tabs) }) else { throw PaneLayoutError.protectedPane }
        guard paneLayoutFits?(tree) != false else { throw PaneLayoutError.invalidTree }
    }

    func previewPanePlacement(source: PaneContentReference, targetPaneID: UUID, edge: PanePlacement, tabs: [Tab]) throws -> PaneLayoutPreview {
        guard let current = currentPaneLayout(), let target = current.panes.first(where: { $0.id == targetPaneID }) else { throw PaneLayoutError.unavailableContent }
        let visibleSource = current.panes.contains { $0.content == source }
        if edge == .center, !visibleSource, paneIsProtected(target.content.id, tabs: tabs) { throw PaneLayoutError.protectedPane }
        if let a = tabs.first(where: { $0.id == source.id }), let b = tabs.first(where: { $0.id == target.content.id }),
           (a.sessionKind != b.sessionKind || a.sessionId != b.sessionId) { throw PaneLayoutError.profileBoundary }
        let next = try current.placing(source, at: targetPaneID, edge: edge)
        try validatePaneContent(next, tabs: tabs)
        let summary = edge == .center ? (visibleSource ? "Swap visible occupants; keep divider sizes." : "Place existing content; keep the previous occupant open in the sidebar.") : "Move existing content \(edge.label.lowercased()); keep its live session."
        return PaneLayoutPreview(expectedRevision: paneLayoutRevision, tree: next, focusedContentID: source.id, summary: summary,
                                 action: edge == .center && visibleSource ? .swap : .arrangement)
    }

    func previewPaneTree(_ tree: PaneLayoutTree, summary: String, tabs: [Tab], focus: UUID? = nil, action: PaneLayoutAction = .arrangement) throws -> PaneLayoutPreview {
        try validatePaneContent(tree, tabs: tabs)
        return PaneLayoutPreview(expectedRevision: paneLayoutRevision, tree: tree,
                                 focusedContentID: focus ?? focusedDocumentId ?? selectedTabId, summary: summary, action: action)
    }

    func previewNewBlankPane(targetPaneID: UUID, edge: PanePlacement, tabs: [Tab]) throws -> PaneLayoutPreview {
        guard edge != .center, let tree = currentPaneLayout(),
              let target = tree.panes.first(where: { $0.id == targetPaneID }) else { throw PaneLayoutError.invalidTree }
        let anchor = tabs.first(where: { $0.id == target.content.id })
        let plan = LayoutPlannedTab(startingURL: nil, profileID: anchor?.sessionId,
                                   label: "New blank pane", isPrivate: anchor?.sessionKind == .incognito)
        let next = try tree.placing(.tab(plan.id), at: targetPaneID, edge: edge)
        try validatePaneContent(next, tabs: tabs, plannedIDs: [plan.id])
        return PaneLayoutPreview(expectedRevision: paneLayoutRevision, tree: next, focusedContentID: plan.id,
                                 summary: "Create one blank pane \(edge.label.lowercased()). Existing tabs and documents keep their sessions.", newTabs: [plan], action: .newSplit)
    }

    func previewLayoutRecipe(_ recipe: LocalLayoutRecipe, tabs: [Tab], keepProtectedVisible: Bool = false) throws -> PaneLayoutPreview {
        _ = try recipe.validated()
        if let owner = Self.liveLayoutOwners[recipe.id]?.manager, owner !== self { throw PaneLayoutError.liveElsewhere }
        guard recipe.linkedResearchWorkspaceID == activeWorkspaceId else { throw PaneLayoutError.wrongWorkspace }
        guard recipe.slots.count == recipe.tree.panes.count, Set(recipe.slots.map(\.id)) == Set(recipe.tree.contentIDs) else { throw PaneLayoutError.invalidTree }
        var tree = recipe.tree, created: [LayoutPlannedTab] = [], bindings: [UUID: UUID] = [:]
        let liveBindings = liveRecipeBindings[recipe.id] ?? [:]
        for slot in recipe.slots {
            guard let pane = recipe.tree.panes.first(where: { $0.content.id == slot.id }) else { throw PaneLayoutError.invalidTree }
            var reference: PaneContentReference?
            if case .document(let documentID) = slot.restore, isDocumentPaneId?(documentID) == true {
                reference = .document(documentID)
            } else if let liveID = liveBindings[slot.id], let tab = tabs.first(where: { $0.id == liveID }),
                      tab.sessionKind != .incognito, tab.sessionId == slot.profileID {
                reference = .tab(liveID)
            }
            if reference == nil {
                // A deleted profile never silently falls back to the normal store.
                if let profileID = slot.profileID {
                    let profiles = (try? modelContext?.fetch(FetchDescriptor<BrowserSession>())) ?? []
                    guard profiles.contains(where: { $0.id == profileID }) else { throw PaneLayoutError.profileBoundary }
                }
                let url: URL?
                let label: String
                switch slot.restore {
                case .safeStarter(let starter):
                    guard LayoutStarterURLPolicy.safeStarter(starter) == starter, !MemoryPinnedSites.isPinned(starter) else { throw PaneLayoutError.invalidTree }
                    url = starter; label = starter.host ?? "Starting page"
                case .chooseCurrentMeeting: url = nil; label = "Choose a current meeting"
                case .document: url = nil; label = "Document unavailable — choose content"
                case .empty: url = nil; label = "Empty layout slot — choose content"
                }
                let planned = LayoutPlannedTab(startingURL: url, profileID: slot.profileID, label: label)
                created.append(planned)
                reference = .tab(planned.id)
            }
            bindings[slot.id] = reference!.id
            tree = tree.replacing(pane.id, with: .pane(LayoutPane(id: pane.id, content: reference!)))
        }
        let protected = (currentPaneLayout()?.panes ?? []).filter { paneIsProtected($0.content.id, tabs: tabs) && !tree.contentIDs.contains($0.content.id) }
        if !protected.isEmpty, keepProtectedVisible {
            tree = .split(id: UUID(), axis: .x, ratio: 0.65, first: tree, second: PaneLayoutTree.columns(protected)!)
        }
        try validatePaneContent(tree, tabs: tabs, plannedIDs: Set(created.map(\.id)))
        return PaneLayoutPreview(expectedRevision: paneLayoutRevision, tree: tree,
                                 focusedContentID: recipe.focusedContentID.flatMap { bindings[$0] },
                                 summary: "Reuse \(bindings.count - created.count) live bindings; create \(created.filter { $0.startingURL != nil }.count) safe starting pages and \(created.filter { $0.startingURL == nil }.count) manual empty slots. Extra tabs stay open. Calls are never automatically joined.",
                                 newTabs: created, recipeID: recipe.id, recipeBindings: bindings, action: .restoreRecipe)
    }

    @discardableResult func applyPaneLayout(_ preview: PaneLayoutPreview, tabs: [Tab]) throws -> Bool {
        try requirePaneLayoutRollout()
        guard preview.expectedRevision == paneLayoutRevision else { throw PaneLayoutError.stalePreview }
        let plannedIDs = Set(preview.newTabs.map(\.id))
        try validatePaneContent(preview.tree, tabs: tabs, plannedIDs: plannedIDs)
        guard plannedIDs.count == preview.newTabs.count, plannedIDs.isDisjoint(with: Set(tabs.map(\.id))) else { throw PaneLayoutError.stalePreview }
        guard preview.newTabs.allSatisfy(\.isPrivate) || modelContext != nil else { throw PaneLayoutError.unavailableContent }
        guard preview.tree != currentPaneLayout() else { return false }
        #if os(macOS)
        let privateIDs = Set(tabs.filter { $0.sessionKind == .incognito }.map(\.id))
        let actionWasPrivate = preview.newTabs.contains(where: \.isPrivate)
            || !(privateIDs.intersection(preview.tree.contentIDs).isEmpty)
            || !(privateIDs.intersection(currentPaneLayout()?.contentIDs ?? []).isEmpty)
        #endif
        if let current = currentPaneLayout() {
            paneLayoutUndo.append((current, focusedDocumentId ?? selectedTabId))
            paneLayoutUndo = Array(paneLayoutUndo.suffix(30))
        }
        paneLayoutRedo = []
        // All validation precedes insertion. Preview/Cancel creates no tabs;
        // the final commit retains existing sessions and only inserts the
        // explicitly reviewed cold-restore slots. Undo leaves these in the tray.
        let created = preview.newTabs.enumerated().map { index, plan in
            let tab = Tab(title: plan.label, url: plan.startingURL, isActive: false)
            tab.id = plan.id
            tab.workspaceId = activeWorkspaceId
            tab.orderIndex = (tabs.map(\.orderIndex).max() ?? -1) + 1 + index
            if plan.isPrivate {
                tab.sessionKind = .incognito; tab.sessionId = plan.profileID ?? UUID(); tab.memoryPolicy = .never
                incognitoTabs.append(tab)
                webViewManager?.registerSession(for: tab.id, kind: .incognito, sessionId: tab.sessionId)
            } else {
                if let profileID = plan.profileID { tab.sessionKind = .container; tab.sessionId = profileID }
                modelContext?.insert(tab)
                if let profileID = plan.profileID { webViewManager?.registerSession(for: tab.id, kind: .container, sessionId: profileID) }
            }
            return tab
        }
        if let recipeID = preview.recipeID {
            liveRecipeBindings[recipeID] = preview.recipeBindings
            Self.liveLayoutOwners[recipeID] = WeakLayoutOwner(self)
            activeLayoutRecipeID = recipeID
            savedLiveLayoutTree = preview.tree
        }
        commitPaneLayout(preview.tree, focus: preview.focusedContentID, tabs: tabs + created)
        if preview.action == .restoreRecipe {
            coldLayoutStarters.register(starters: preview.newTabs.map {
                .init(tabID: $0.id, startingURL: $0.startingURL, profileID: $0.profileID, isPrivate: $0.isPrivate)
            }, workspaceID: activeWorkspaceId, layoutRevision: paneLayoutRevision, gateEnabled: paneLayoutsEnabled)
            noteColdStarterStateChanged()
        }
        #if os(macOS)
        if preview.action != .resize {
            PowerUpLearning.shared.recordSuccess(feature: preview.action == .restoreRecipe ? .savedWorkspace : preview.action == .swap ? .swapPanes : .splitLayout,
                                                 method: .button, isPrivate: actionWasPrivate)
        }
        #endif
        return true
    }

    private func commitPaneLayout(_ tree: PaneLayoutTree, focus: UUID?, tabs: [Tab]) {
        cancelColdLayoutStarters(reason: .layoutChanged)
        applyingPaneLayout = true
        for pane in tree.panes { paneIDsByContent[pane.content.id] = pane.id }
        maximizedPaneContentID = nil
        paneFocusBeforeMaximize = nil
        paneLayout = tree.panes.count > 1 ? tree : nil
        splitTabIds = tree.panes.count > 1 ? tree.contentIDs : []
        let target = focus.flatMap { tree.contentIDs.contains($0) ? $0 : nil } ?? tree.contentIDs.first
        if let target, isDocumentPaneId?(target) == true { focusedDocumentId = target }
        else { selectedTabId = target; focusedDocumentId = nil }
        applyingPaneLayout = false
        paneLayoutRevision &+= 1
        canUndoPaneLayout = !paneLayoutUndo.isEmpty
        canRedoPaneLayout = !paneLayoutRedo.isEmpty
        // Private working state remains in memory. Existing legacy membership
        // is kept until the new recovery record has been written successfully.
        persistPaneLayoutRecovery(tree, focus: target)
    }

    private func persistPaneLayoutRecovery(_ tree: PaneLayoutTree, focus: UUID?) {
        guard paneLayoutsEnabled, paneLayoutDefaults.bool(forKey: PaneLayoutRolloutPolicy.defaultsKey), !paneRecoveryWriteBlocked else { return }
        let privateIDs = Set(incognitoTabs.map(\.id))
        if privateIDs.isDisjoint(with: tree.contentIDs),
           let data = try? JSONEncoder().encode(PaneLayoutRecovery(linkedResearchWorkspaceID: activeWorkspaceId, tree: tree, focusedContentID: focus)) {
            BrowserProfile.defaults.set(data, forKey: persistenceKey("paneLayoutRecovery.v1"))
        } else {
            BrowserProfile.defaults.removeObject(forKey: persistenceKey("paneLayoutRecovery.v1"))
        }
    }

    private func validatedPaneRecovery(matching members: [PaneContentReference]) -> PaneLayoutRecovery? {
        guard paneLayoutsEnabled, paneLayoutDefaults.bool(forKey: PaneLayoutRolloutPolicy.defaultsKey) else { return nil }
        guard let data = BrowserProfile.defaults.data(forKey: persistenceKey("paneLayoutRecovery.v1")) else {
            paneRecoveryWriteBlocked = false
            return nil
        }
        guard data.count <= 1_048_576,
              let recovery = try? JSONDecoder().decode(PaneLayoutRecovery.self, from: data),
              recovery.schemaVersion == 1, recovery.linkedResearchWorkspaceID == activeWorkspaceId,
              (try? recovery.tree.validated(maximumPanes: PaneLayoutRolloutPolicy.newMembershipLimit(enabled: true))) != nil,
              recovery.tree.panes.map(\.content) == members,
              Set(incognitoTabs.map(\.id)).isDisjoint(with: recovery.tree.contentIDs) else {
            // Never downgrade future/corrupt/stale data during opt-in or a
            // later focus change. Saved recipes remain independently writable.
            paneRecoveryWriteBlocked = true
            return nil
        }
        paneRecoveryWriteBlocked = false
        return recovery
    }

    func undoPaneLayout(tabs: [Tab], redo: Bool = false) throws {
        try requirePaneLayoutRollout()
        cancelColdLayoutStarters(reason: .undo)
        guard let prior = redo ? paneLayoutRedo.last : paneLayoutUndo.last else { return }
        try validatePaneContent(prior.tree, tabs: tabs)
        if let current = currentPaneLayout() {
            if redo { paneLayoutUndo.append((current, focusedDocumentId ?? selectedTabId)) }
            else { paneLayoutRedo.append((current, focusedDocumentId ?? selectedTabId)) }
        }
        if redo { paneLayoutRedo.removeLast() } else { paneLayoutUndo.removeLast() }
        commitPaneLayout(prior.tree, focus: prior.focus, tabs: tabs)
    }

    func makeLayoutRecipe(named name: String, tabs: [Tab], updating oldRecipe: LocalLayoutRecipe? = nil) throws -> LocalLayoutRecipe {
        guard let tree = currentPaneLayout() else { throw PaneLayoutError.unavailableContent }
        try validatePaneContent(tree, tabs: tabs)
        guard !tree.contentIDs.contains(where: { id in tabs.contains { $0.id == id && $0.sessionKind == .incognito } }) else { throw PaneLayoutError.privateLayout }
        var configurationTree = tree, slots: [LayoutRecipeSlot] = [], bindings: [UUID: UUID] = [:]
        let focusedID = focusedDocumentId ?? selectedTabId
        var focusedSlot: UUID?
        for pane in tree.panes {
            // Stable slot identity is kept when updating a still-bound recipe.
            let existingSlot = oldRecipe.flatMap { recipe in liveRecipeBindings[recipe.id]?.first(where: { $0.value == pane.content.id })?.key }
            let slotID = existingSlot ?? UUID()
            let restore: LayoutRestoreSpecification
            var profileID: UUID?
            switch pane.content {
            case .document(let id): restore = .document(id)
            case .tab(let id):
                guard let tab = tabs.first(where: { $0.id == id }) else { throw PaneLayoutError.unavailableContent }
                profileID = tab.sessionKind == .container ? tab.sessionId : nil
                if paneIsProtected(id, tabs: tabs) || LayoutStarterURLPolicy.isMeeting(tab.url) { restore = .chooseCurrentMeeting }
                else if let url = LayoutStarterURLPolicy.safeStarter(tab.url) { restore = .safeStarter(url) }
                else { restore = .empty }
            }
            slots.append(LayoutRecipeSlot(id: slotID, restore: restore, profileID: profileID))
            bindings[slotID] = pane.content.id
            if pane.content.id == focusedID { focusedSlot = slotID }
            let ref: PaneContentReference
            if case .document = pane.content { ref = .document(slotID) } else { ref = .tab(slotID) }
            configurationTree = configurationTree.replacing(pane.id, with: .pane(LayoutPane(id: pane.id, content: ref)))
        }
        var recipe = LocalLayoutRecipe(name: name, linkedResearchWorkspaceID: activeWorkspaceId,
                                       tree: configurationTree, slots: slots, focusedContentID: focusedSlot)
        if let oldRecipe { recipe.id = oldRecipe.id; recipe.revision = oldRecipe.revision }
        liveRecipeBindings[recipe.id] = bindings
        return recipe
    }

    func markLayoutRecipeSaved(_ recipeID: UUID) {
        Self.liveLayoutOwners[recipeID] = WeakLayoutOwner(self)
        activeLayoutRecipeID = recipeID
        savedLiveLayoutTree = currentPaneLayout()
    }

    #if os(macOS)
    @discardableResult func revealLiveLayoutRecipe(_ recipeID: UUID) -> Bool {
        guard let owner = Self.liveLayoutOwners[recipeID]?.manager, owner !== self,
              let id = owner.windowID, let window = BrowserWindows.shared.window(id) else { return false }
        window.makeKeyAndOrderFront(nil)
        return true
    }
    #endif

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
        } else if splitTabIds.count < paneMembershipLimit {
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
        refreshPaneLayoutRollout()
        guard let strings = BrowserProfile.defaults.stringArray(forKey: persistenceKey(Self.splitKey)) else { return }
        restoringPaneLayout = true
        defer { restoringPaneLayout = false }
        // Pane ids resolve against the tab list first, then the active
        // workspace's documents (ADR 0008); unresolved ids drop as before.
        let isDocument = isDocumentPaneId ?? { _ in false }
        let ids = strings.compactMap(UUID.init(uuidString:)).filter { id in
            tabs.contains { $0.id == id } || isDocument(id)
        }
        guard ids.count >= 2 else {
            if !strings.isEmpty { BrowserProfile.defaults.removeObject(forKey: persistenceKey(Self.splitKey)) }
            return
        }
        splitTabIds = ids
        // A versioned recovery snapshot extends the old local membership
        // record. It is separate from explicit saved recipe revisions.
        let recoveryKey = persistenceKey("paneLayoutRecovery.v1")
        if paneLayoutsEnabled, BrowserProfile.defaults.data(forKey: recoveryKey) != nil {
            if let recovery = validatedPaneRecovery(matching: currentPaneMembers) {
                commitPaneLayout(recovery.tree, focus: recovery.focusedContentID, tabs: tabs)
            }
            // A malformed or stale record is retained for recovery inspection;
            // the validated legacy membership still gives a usable fallback.
        } else if paneLayoutsEnabled, let tree = paneLayout {
            commitPaneLayout(tree, focus: focusedDocumentId ?? selectedTabId, tabs: tabs)
        }
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
            if activeWorkspaceId != homeWorkspaceID {
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
        noteNewspaperPageFinished(tab: tab, webView: webView)
        settleCapture?.pageDidSettleEventually(
            tab: tab,
            webView: webView,
            openedFromSourceId: openerSourceId(for: tab, tabs: tabs)
        )
    }

    func noteNewspaperPageFinished(tab: Tab, webView: WKWebView?) {
        guard let webView, let modelContext else { return }
        NewspaperDiscoveryCoordinator.shared.start(modelContext: modelContext)
        NewspaperDiscoveryCoordinator.shared.consider(webView, session: tab.sessionKind)
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
        guard activeWorkspaceId != homeWorkspaceID else { return }
        splitTabIds = []
        focusedDocumentId = nil
        activeWorkspaceId = homeWorkspaceID
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


    func duplicateTab(_ tab: Tab, select: Bool = true) -> Tab {
        let newTab = createTab(
            inheriting: tab.browsingContext,
            url: tab.url,
            select: select
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

        // Split pane order is splitTabIds' own order, not orderIndex, so a drag
        // between two split members needs to move them there too. A non-member
        // dragged into the block naturally does nothing here (it isn't found).
        if let splitSourceIndex = splitTabIds.firstIndex(of: sourceTabId),
           let splitTargetIndex = splitTabIds.firstIndex(of: targetTabId),
           splitSourceIndex != splitTargetIndex {
            var reorderedSplit = splitTabIds
            let movedId = reorderedSplit.remove(at: splitSourceIndex)
            reorderedSplit.insert(movedId, at: splitTargetIndex)
            splitTabIds = reorderedSplit
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
