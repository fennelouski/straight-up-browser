//
//  TabManager.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import SwiftData
import Combine

class TabManager: ObservableObject {
    @Published var selectedTabId: UUID?
    @Published var closedTabs: [Tab] = []

    private var modelContext: ModelContext?
    private weak var webViewManager: WebViewManager?

    init(modelContext: ModelContext? = nil, webViewManager: WebViewManager? = nil) {
        self.modelContext = modelContext
        self.webViewManager = webViewManager
    }

    func setModelContext(_ modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func setWebViewManager(_ webViewManager: WebViewManager) {
        self.webViewManager = webViewManager
    }

    func createNewTab() -> Tab {
        let newTab = Tab()
        if let modelContext = modelContext {
            modelContext.insert(newTab)
        }
        selectedTabId = newTab.id
        return newTab
    }

    func closeTab(_ tab: Tab, tabs: [Tab]) {
        if tabs.count > 1 {
            // Clean up the web view for this tab
            webViewManager?.removeWebView(for: tab.id)

            // Store the tab in closed tabs list for potential reopening
            closedTabs.append(tab)
            modelContext?.delete(tab)
            if selectedTabId == tab.id {
                selectedTabId = tabs.filter { $0.id != tab.id }.first?.id
            }
        } else {
            Logger.log("TabManager closeTab: Closing last tab, converting to history tab", type: "TabManager")
            // Handle closing the last tab - convert the existing tab to a history tab instead of creating a new one
            // This ensures there's always at least one tab open, showing browsing history

            // Clean up the web view for this tab
            webViewManager?.removeWebView(for: tab.id)

            // Store the tab in closed tabs list (but don't delete it from the model)
            closedTabs.append(tab)

            // Convert the existing tab to a history tab by changing its properties
            Logger.log("TabManager closeTab: Converting tab \(tab.id) to history tab", type: "TabManager")
            tab.title = "History"
            tab.url = URL(string: "about:history")
            tab.historyStrings = [] // Clear the history since we're showing all history
            tab.currentHistoryIndex = -1
            tab.lastAccessed = Date() // Update last accessed time

            // Keep the same selectedTabId since we're modifying the existing tab
            Logger.log("TabManager closeTab: Converted tab \(tab.id) to history tab with URL \(tab.url?.absoluteString ?? "nil")", type: "TabManager")
            Logger.log("TabManager closeTab: selectedTabId remains \(selectedTabId?.uuidString ?? "nil")", type: "TabManager")
        }
    }


    func duplicateTab(_ tab: Tab) -> Tab {
        let newTab = Tab(title: tab.title + " Copy", url: tab.url, isActive: false)
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
        guard let lastClosedTab = closedTabs.popLast() else { return nil }

        // Create a new tab with the same properties as the closed one
        let newTab = Tab(title: lastClosedTab.title, url: lastClosedTab.url, isActive: true)
        newTab.historyStrings = lastClosedTab.historyStrings
        newTab.currentHistoryIndex = lastClosedTab.currentHistoryIndex

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

    func moveTabLeft(tabs: [Tab]) {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == selectedTabId }), currentIndex > 0 else { return }
        // Note: SwiftData doesn't support reordering directly. This would require
        // recreating the tabs in the new order. For now, we'll just log that this
        // functionality needs proper implementation with a reorderable data source.
        Logger.log("Tab moving not yet implemented - requires reordering data source", type: "TabManager")
    }

    func moveTabRight(tabs: [Tab]) {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == selectedTabId }), currentIndex < tabs.count - 1 else { return }
        // Note: SwiftData doesn't support reordering directly. This would require
        // recreating the tabs in the new order. For now, we'll just log that this
        // functionality needs proper implementation with a reorderable data source.
        Logger.log("Tab moving not yet implemented - requires reordering data source", type: "TabManager")
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

    func collectBrowsingHistory(from tabs: [Tab]) -> [URL] {
        var allHistory: [(url: URL, timestamp: Date)] = []

        for tab in tabs {
            // Add current URL if it exists
            if let currentUrl = tab.url {
                allHistory.append((url: currentUrl, timestamp: tab.lastAccessed))
            }

            // Add all URLs from history
            for url in tab.history {
                allHistory.append((url: url, timestamp: tab.lastAccessed))
            }
        }

        // Also add closed tabs history
        for closedTab in closedTabs {
            if let currentUrl = closedTab.url {
                allHistory.append((url: currentUrl, timestamp: closedTab.lastAccessed))
            }

            for url in closedTab.history {
                allHistory.append((url: url, timestamp: closedTab.lastAccessed))
            }
        }

        // Remove duplicates, keeping the most recent timestamp
        var uniqueHistory: [URL: Date] = [:]
        for (url, timestamp) in allHistory {
            if let existingTimestamp = uniqueHistory[url] {
                uniqueHistory[url] = max(existingTimestamp, timestamp)
            } else {
                uniqueHistory[url] = timestamp
            }
        }

        // Sort by timestamp (most recent first) and return URLs
        return uniqueHistory.sorted { $0.value > $1.value }.map { $0.key }
    }

    func createHistoryTab(tabs: [Tab]) -> Tab {
        let historyTab = Tab(title: "History", url: URL(string: "straightup://history"), isActive: true)
        return historyTab
    }
}
