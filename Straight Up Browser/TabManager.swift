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
    @Published var selectedTabId: UUID?
    // Survives quit (persisted to UserDefaults) so Cmd+Shift+T can reopen tabs
    // from the previous session, not just the current one.
    @Published var closedTabs: [ClosedTabSnapshot] = [] {
        didSet { persistClosedTabs() }
    }

    private static let closedTabsKey = "closedTabsStack"
    private static let maxClosedTabs = 25

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
            modelContext.insert(newTab)
        }
        if select {
            selectedTabId = newTab.id
        }
        return newTab
    }

    func closeTab(_ tab: Tab, tabs: [Tab]) {
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
