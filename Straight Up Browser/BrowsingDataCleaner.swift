//
//  BrowsingDataCleaner.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 7/17/26.
//

import Foundation
import WebKit

enum ContainerStoreRemoval {
    static func result(for error: Error?) -> Result<Void, Error> {
        if let error { return .failure(error) }
        return .success(())
    }

    static func remove(
        identifier: UUID,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) {
        WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
            completion(result(for: error))
        }
    }
}

enum WebsiteDataStoreScope: Equatable {
    case defaultStore
    case container(UUID)
}

// Scoped browsing-data clearing for the Privacy menu. WebKit can't un-delete data,
// so the caller confirms with a warning first; there is no undo. Hard-reload (a page
// scope with no deletion) lives in ContentView.hardReload() / ⇧⌘R.
enum BrowsingDataCleaner {
    static func allStoreScopes(containerIdentifiers: [UUID]) -> [WebsiteDataStoreScope] {
        var seen: Set<UUID> = []
        let containers = containerIdentifiers.compactMap { identifier in
            seen.insert(identifier).inserted
                ? WebsiteDataStoreScope.container(identifier)
                : nil
        }
        return [.defaultStore] + containers
    }

    static func store(for scope: WebsiteDataStoreScope) -> WKWebsiteDataStore {
        switch scope {
        case .defaultStore:
            return .default()
        case .container(let identifier):
            return WKWebsiteDataStore(forIdentifier: identifier)
        }
    }

    private static func stores(for scopes: [WebsiteDataStoreScope]) -> [WKWebsiteDataStore] {
        scopes.map(store(for:))
    }

    // Which sites you're signed into, per store scope, in `allStoreScopes` order.
    static func signedInHosts(
        containerIdentifiers: [UUID],
        then: @escaping @MainActor @Sendable ([[String]]) -> Void
    ) {
        let jars = stores(for: allStoreScopes(containerIdentifiers: containerIdentifiers))
        var results = [[String]](repeating: [], count: jars.count)
        var remaining = jars.count
        for (index, jar) in jars.enumerated() {
            jar.httpCookieStore.getAllCookies { cookies in
                results[index] = SignedInSites.hosts(in: cookies)
                remaining -= 1
                if remaining == 0 { then(results) }
            }
        }
    }

    private static func clear(
        dataTypes: Set<String>,
        from stores: [WKWebsiteDataStore],
        then: @escaping @MainActor @Sendable () -> Void
    ) {
        guard !stores.isEmpty, !dataTypes.isEmpty else {
            then()
            return
        }
        var remaining = stores.count
        for store in stores {
            store.removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {
                remaining -= 1
                if remaining == 0 { then() }
            }
        }
    }

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
        containerIdentifiers: [UUID] = [],
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
        clear(
            dataTypes: types,
            from: stores(for: allStoreScopes(containerIdentifiers: containerIdentifiers)),
            then: then
        )
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

    // Clear every persistent browsing jar: the default store plus each named
    // container. Incognito stores are memory-only and disappear with their tabs.
    static func clearEverything(
        containerIdentifiers: [UUID],
        then: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        URLCache.shared.removeAllCachedResponses()
        clear(
            dataTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            from: stores(for: allStoreScopes(containerIdentifiers: containerIdentifiers)),
            then: then
        )
    }
}

// WebKit has no "am I logged in" API, so infer it from cookies: a server-set
// (httpOnly) cookie whose name reads like a session or auth token. Misses sites
// that keep their session in local storage, and can over-report the odd
// server-set tracking cookie.
// ponytail: name matching. Only worth more if it visibly misfires.
enum SignedInSites {
    static let authNames = [
        "session", "sess", "auth", "token", "login", "logged",
        "sid", "remember", "account", "credential", "identity"
    ]

    static func looksLikeLogin(_ cookie: HTTPCookie) -> Bool {
        guard cookie.isHTTPOnly else { return false }
        let name = cookie.name.lowercased()
        return authNames.contains { name.contains($0) }
    }

    static func hosts(in cookies: [HTTPCookie]) -> [String] {
        let matched = cookies.filter(looksLikeLogin).map { cookie in
            cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        }
        return Set(matched).sorted()
    }
}
