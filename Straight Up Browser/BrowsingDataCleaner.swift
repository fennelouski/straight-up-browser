//
//  BrowsingDataCleaner.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 7/17/26.
//

import Foundation
import WebKit

// Scoped browsing-data clearing for the Privacy menu. WebKit can't un-delete data,
// so the caller confirms with a warning first; there is no undo. Hard-reload (a page
// scope with no deletion) lives in ContentView.hardReload() / ⇧⌘R.
enum BrowsingDataCleaner {

    // Browsing history is app-owned rather than WebKit-owned. Clear every local
    // and synced recovery surface together so neither search nor session restore
    // can reconstruct destinations after the user erases history.
    static func clearHistory(
        in tabs: [Tab],
        siteHistory: SiteHistory = .shared,
        browsingHistory: BrowsingHistoryStore = .shared
    ) {
        for tab in tabs {
            tab.historyStrings.removeAll()
            tab.currentHistoryIndex = -1
        }
        siteHistory.clear()
        browsingHistory.clear()
        TabSync.clearPageState(in: tabs)
        TabManager.clearPersistedClosedTabs()
        WebViewManager.clearPersistedInteractionStateFile()
        NotificationCenter.default.post(name: .browserHistoryDidClear, object: nil)
    }

    // Translate the settings checkboxes into non-overlapping WebKit data types.
    // In particular, selecting cookies must not silently erase caches or storage.
    static func websiteDataTypes(
        cookies: Bool,
        cache: Bool,
        localStorage: Bool
    ) -> Set<String> {
        var types: Set<String> = []
        if cookies { types.insert(WKWebsiteDataTypeCookies) }
        if cache {
            types.insert(WKWebsiteDataTypeDiskCache)
            types.insert(WKWebsiteDataTypeMemoryCache)
        }
        if localStorage { types.insert(WKWebsiteDataTypeLocalStorage) }
        return types
    }

    static func clearSelectedWebsiteData(
        cookies: Bool,
        cache: Bool,
        localStorage: Bool,
        in store: WKWebsiteDataStore = .default(),
        then: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        if cache { URLCache.shared.removeAllCachedResponses() }
        let types = websiteDataTypes(
            cookies: cookies,
            cache: cache,
            localStorage: localStorage
        )
        guard !types.isEmpty else {
            then()
            return
        }
        store.removeData(ofTypes: types, modifiedSince: .distantPast, completionHandler: then)
    }

    // Remove one site's data (cookies + cache + storage) from a specific store, then
    // run `then` (e.g. reload the page). Scoped to the tab's own store, so clearing a
    // site in one container/incognito session never touches another.
    static func clearSite(host: String, in store: WKWebsiteDataStore, then: @escaping () -> Void = {}) {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            // displayName is typically the registrable domain (e.g. "google.com"), so
            // match the exact host and any subdomain of it ("mail.google.com").
            let match = records.filter { host == $0.displayName || host.hasSuffix("." + $0.displayName) }
            store.removeData(ofTypes: types, for: match) { then() }
        }
    }

    // Wipe an entire store — the whole session/container/incognito jar.
    static func clearStore(_ store: WKWebsiteDataStore, then: @escaping () -> Void = {}) {
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { then() }
    }

    // Clear all normal browsing data: the default WebKit store and shared URL cache.
    // Container sessions keep their own jars on purpose (they're persistent
    // by design) — clear those from within each via "Clear This Session's Data".
    static func clearDefaultEverything(then: @escaping () -> Void = {}) {
        URLCache.shared.removeAllCachedResponses()
        clearStore(.default(), then: then)
    }
}
