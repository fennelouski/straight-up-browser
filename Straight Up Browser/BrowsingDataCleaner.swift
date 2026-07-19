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

    // Clear all normal browsing data: the default store, the shared URL cache, and
    // cookies. Container sessions keep their own jars on purpose (they're persistent
    // by design) — clear those from within each via "Clear This Session's Data".
    static func clearDefaultEverything(then: @escaping () -> Void = {}) {
        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        clearStore(.default(), then: then)
    }
}
