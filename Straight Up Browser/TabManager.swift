//
//  TabManager.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import SwiftData
import Combine

// Value snapshot of a closed tab. Holding the deleted SwiftData model itself
// is undefined behavior once modelContext.delete runs.
struct ClosedTabSnapshot: Codable {
    let title: String
    let url: URL?
    let historyStrings: [String]
}

class TabManager: ObservableObject {
    // The focused tab: owns the omnibar, title, and all key commands. In a split
    // it is always one of splitTabIds; selecting any non-member dissolves the split
    // (see docs/adr/0001-split-is-view-state.md).
    @Published var selectedTabId: UUID? {
        didSet {
            if !splitTabIds.isEmpty, let id = selectedTabId, !splitTabIds.contains(id) {
                splitTabIds = []
            }
        }
    }
    // Split view: ordered member tab ids (2–4; empty = normal single view).
    // Window view state, not a SwiftData entity — persisted to UserDefaults only.
    @Published var splitTabIds: [UUID] = [] {
        didSet { UserDefaults.standard.set(splitTabIds.map(\.uuidString), forKey: Self.splitKey) }
    }
    // Incognito tabs live only in memory — never inserted into SwiftData — so a private
    // URL never persists to disk or syncs to iCloud. They vanish when the app quits.
    @Published var incognitoTabs: [Tab] = []
    // Survives quit (persisted to UserDefaults) so Cmd+Shift+T can reopen tabs
    // from the previous session, not just the current one.
    @Published var closedTabs: [ClosedTabSnapshot] = [] {
        didSet { persistClosedTabs() }
    }

    private static let closedTabsKey = "closedTabsStack"
    private static let maxClosedTabs = 25
    private static let splitKey = "splitTabIds"
    static let maxSplitTabs = 4

    private var modelContext: ModelContext?
    private weak var webViewManager: WebViewManager?

    init(modelContext: ModelContext? = nil, webViewManager: WebViewManager? = nil) {
        self.modelContext = modelContext
        self.webViewManager = webViewManager
        if let data = UserDefaults.standard.data(forKey: Self.closedTabsKey),
           let saved = try? JSONDecoder().decode([ClosedTabSnapshot].self, from: data) {
            closedTabs = saved
        }
    }

    // Keep only the most recent entries on disk; the in-session stack is small
    // by nature (you'd have to close thousands of tabs to grow it).
    private func persistClosedTabs() {
        let capped = Array(closedTabs.suffix(Self.maxClosedTabs))
        if let data = try? JSONEncoder().encode(capped) {
            UserDefaults.standard.set(data, forKey: Self.closedTabsKey)
        }
    }

    func setModelContext(_ modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func setWebViewManager(_ webViewManager: WebViewManager) {
        self.webViewManager = webViewManager
    }

    @discardableResult
    func createNewTab(url: URL? = nil, select: Bool = true) -> Tab {
        let newTab = Tab(title: String(localized: "New Tab"), url: url, isActive: false)
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
            newTab.orderIndex = (existing.map(\.orderIndex).max() ?? -1) + 1
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
    func createIncognitoTab(sessionId: UUID? = nil, select: Bool = true) -> Tab {
        let tab = Tab(title: String(localized: "New Tab"), url: nil, isActive: false)
        tab.sessionKind = .incognito
        tab.sessionId = sessionId ?? UUID()
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
    func createTab(inheriting session: (kind: SessionKind, sessionId: UUID?), url: URL? = nil, select: Bool = true) -> Tab {
        switch session.kind {
        case .normal:
            return createNewTab(url: url, select: select)
        case .incognito:
            let tab = createIncognitoTab(sessionId: session.sessionId, select: select)
            if let url { tab.navigateTo(url); tab.updateTitleFromURL() }
            return tab
        case .container:
            let tab = createNewTab(url: url, select: select)
            tab.sessionKind = .container
            tab.sessionId = session.sessionId
            webViewManager?.registerSession(for: tab.id, kind: .container, sessionId: session.sessionId)
            return tab
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
            let newTab = self.createIncognitoTab(sessionId: sessionId)
            if let url {
                newTab.navigateTo(url)
                newTab.updateTitleFromURL()
            }
            self.webViewManager?.removeWebView(for: tab.id)
            self.modelContext?.delete(tab)
        }
    }

    // MARK: - Split view

    // Shift-click / context-menu toggle: add the tab as a pane (focusing it) or
    // remove its pane. Live — there is no separate selection/confirm step.
    func toggleSplitMembership(_ tab: Tab, tabs: [Tab]) {
        if splitTabIds.contains(tab.id) {
            removeFromSplit(tab.id)
        } else if splitTabIds.isEmpty {
            guard let current = selectedTabId, current != tab.id else {
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

    private func removeFromSplit(_ tabId: UUID) {
        let remaining = splitTabIds.filter { $0 != tabId }
        splitTabIds = remaining.count >= 2 ? remaining : []
        if selectedTabId == tabId {
            selectedTabId = remaining.first ?? selectedTabId
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
        let ids = strings.compactMap(UUID.init(uuidString:)).filter { id in tabs.contains { $0.id == id } }
        guard ids.count >= 2 else {
            if !strings.isEmpty { UserDefaults.standard.removeObject(forKey: Self.splitKey) }
            return
        }
        splitTabIds = ids
        if let selected = selectedTabId, !ids.contains(selected) {
            selectedTabId = ids.first
        }
    }

    func closeTab(_ tab: Tab, tabs: [Tab]) {
        // Closing a split member collapses just its pane; focus moves to another
        // member so the dissolve-on-outside-selection rule doesn't tear down the rest.
        if splitTabIds.contains(tab.id) {
            removeFromSplit(tab.id)
        }

        // Incognito tabs are in-memory and ephemeral: no closed-tab snapshot (privacy),
        // just drop the tab and wipe its jar once the session has no tabs left.
        if tab.sessionKind == .incognito {
            webViewManager?.removeWebView(for: tab.id)
            incognitoTabs.removeAll { $0.id == tab.id }
            if let sid = tab.sessionId, !incognitoTabs.contains(where: { $0.sessionId == sid }) {
                webViewManager?.discardIncognitoStore(sid)
            }
            let remaining = tabs.filter { $0.id != tab.id }
            if selectedTabId == tab.id { selectedTabId = remaining.first?.id }
            if remaining.isEmpty { _ = createNewTab() } else { ensureSelectedTab(from: remaining) }
            return
        }

        // Snapshot before any mutation/deletion so reopen works safely
        closedTabs.append(ClosedTabSnapshot(title: tab.title, url: tab.url, historyStrings: tab.historyStrings))

        // Clean up the web view for this tab
        webViewManager?.removeWebView(for: tab.id)

        let remaining = tabs.filter { $0.id != tab.id }

        // Open-only tab sync: don't delete the record (deleting would propagate the
        // close to your other devices). Hide it on this device via the local
        // closed-set instead, and keep the always-one-tab invariant.
        if TabSync.enabled && TabSync.mode == .openOnly {
            TabSync.markLocallyClosed(tab.id)
            if selectedTabId == tab.id { selectedTabId = remaining.first?.id }
            if remaining.isEmpty { _ = createNewTab() } else { ensureSelectedTab(from: remaining) }
            return
        }

        if tabs.count > 1 {
            modelContext?.delete(tab)
            if selectedTabId == tab.id {
                selectedTabId = remaining.first?.id
            }
            // Ensure there's always a selected tab after closing
            ensureSelectedTab(from: remaining)
        } else {
            // Closing the last tab: reset it to a fresh New Tab instead of
            // deleting it, so there is always one tab open
            tab.title = String(localized: "New Tab")
            tab.url = nil
            tab.historyStrings = []
            tab.currentHistoryIndex = -1
            tab.lastAccessed = Date()
        }
    }


    func duplicateTab(_ tab: Tab) -> Tab {
        let newTab = Tab(title: tab.title + " Copy", url: tab.url, isActive: false)
        newTab.memoryPolicy = tab.memoryPolicy
        // Update the title to use the domain name
        newTab.updateTitleFromURL()
        modelContext?.insert(newTab)
        selectedTabId = newTab.id
        return newTab
    }

    func deleteTabs(at offsets: IndexSet, tabs: [Tab]) {
        for index in offsets {
            let tab = tabs[index]
            closeTab(tab, tabs: tabs)
        }
    }

    func reopenLastClosedTab() -> Tab? {
        guard let snapshot = closedTabs.popLast() else { return nil }

        // Create a new tab with the same properties as the closed one
        let newTab = Tab(title: snapshot.title, url: snapshot.url, isActive: true)
        newTab.historyStrings = snapshot.historyStrings
        newTab.currentHistoryIndex = snapshot.historyStrings.isEmpty ? -1 : snapshot.historyStrings.count - 1

        // Update the title to use the domain name
        newTab.updateTitleFromURL()

        modelContext?.insert(newTab)
        selectedTabId = newTab.id
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
        guard let currentIndex = tabs.firstIndex(where: { $0.id == selectedTabId }) else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
        selectedTabId = tabs[nextIndex].id
    }

    func switchToPreviousTab(tabs: [Tab]) {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == selectedTabId }) else { return }
        let previousIndex = currentIndex == 0 ? tabs.count - 1 : currentIndex - 1
        selectedTabId = tabs[previousIndex].id
    }

    func switchToTab(at index: Int, tabs: [Tab]) {
        guard index >= 0 && index < tabs.count else {
            Logger.log("TabManager switchToTab: invalid index \(index), tabs.count = \(tabs.count)", type: "TabManager")
            return
        }
        let tab = tabs[index]
        Logger.log("TabManager switchToTab: switching to tab at index \(index), id=\(tab.id), url=\(tab.url?.absoluteString ?? "nil")", type: "TabManager")
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

        // Remove the source tab and insert it at the target position
        let sourceTab = reorderedTabs.remove(at: sourceIndex)
        let adjustedTargetIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        reorderedTabs.insert(sourceTab, at: adjustedTargetIndex)

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
