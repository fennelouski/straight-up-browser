//
//  TabSync.swift
//  Straight Up Browser
//
//  Cross-device tab sync (SwiftData + iCloud/CloudKit). Shared by both the macOS
//  and iPadOS targets. The master toggle picks the CloudKit private database at
//  launch; the mode decides whether closing a tab propagates (openClose) or stays
//  local (openOnly, the default). Cache-state syncs each tab's page state.
//
//  Reads live in UserDefaults so the settings UI (@AppStorage) and the launch-time
//  container config agree. Toggling the master switch takes effect on relaunch,
//  since SwiftData fixes the container at startup.
//

import Foundation
import SwiftData
import WebKit
import CloudKit

enum TabSyncMode: String, CaseIterable {
    case openOnly    // just opening syncs; closes are local to each device (default)
    case openClose   // opening AND closing sync (one shared tab set)

    var label: String {
        switch self {
        case .openOnly:  return String(localized: "Just opening tabs")
        case .openClose: return String(localized: "Opening and closing tabs")
        }
    }
}

enum TabSync {
    static let containerID = "iCloud.com.nathanfennel.Straight-Up-Browser"

    // UserDefaults keys (mirrored by @AppStorage in the settings UI).
    enum Key {
        static let enabled = "tabSyncEnabled"
        static let mode = "tabSyncMode"
        static let cacheState = "tabSyncCacheState"
        static let locallyClosed = "tabSyncLocallyClosedIds"
    }

    static var enabled: Bool { UserDefaults.standard.bool(forKey: Key.enabled) }
    static var mode: TabSyncMode {
        TabSyncMode(rawValue: UserDefaults.standard.string(forKey: Key.mode) ?? "") ?? .openOnly
    }
    static var cacheStateEnabled: Bool { UserDefaults.standard.bool(forKey: Key.cacheState) }

    /// The database the SwiftData store binds to at launch: the private CloudKit
    /// DB when sync is on, or none (local only) when off.
    static var cloudKitDatabase: ModelConfiguration.CloudKitDatabase {
        enabled ? .private(containerID) : .none
    }

    /// Whether the user's iCloud account can actually back CloudKit sync (signed
    /// in and usable). The settings UI hides the sync controls when this is false,
    /// so we never offer a setting that can't work. Also covers the case where the
    /// CloudKit container isn't provisioned yet (the check errors → false).
    static func iCloudAvailable() async -> Bool {
        do {
            return try await CKContainer(identifier: containerID).accountStatus() == .available
        } catch {
            return false
        }
    }

    // MARK: Open-only local closes

    /// Tab ids hidden on THIS device only (open-only mode). Closing a tab records
    /// its id here and keeps the CloudKit record, so it stays open on other devices.
    static var locallyClosedIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Key.locallyClosed) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Key.locallyClosed) }
    }

    static func markLocallyClosed(_ id: UUID) {
        locallyClosedIds.insert(id.uuidString)
    }

    static func isLocallyClosed(_ id: UUID) -> Bool {
        locallyClosedIds.contains(id.uuidString)
    }

    static func clearLocallyClosed() {
        UserDefaults.standard.removeObject(forKey: Key.locallyClosed)
    }

    /// True while sync is on in open-only mode and this tab was closed on this
    /// device — it should be hidden from this device's UI but its record kept.
    static func shouldHideLocally(_ tab: Tab) -> Bool {
        enabled && mode == .openOnly && isLocallyClosed(tab.id)
    }

    /// Tabs visible on this device (drops open-only local closes).
    static func visible(_ tabs: [Tab]) -> [Tab] {
        guard enabled && mode == .openOnly else { return tabs }
        let hidden = locallyClosedIds
        return tabs.filter { !hidden.contains($0.id.uuidString) }
    }

    // MARK: Cache state (opt-in)

    private static let maxSessionStorageBytes = 300_000

    /// Snapshot the web view's page state (scroll + back/forward + form state via
    /// interactionState, plus best-effort sessionStorage) onto the tab so it syncs.
    static func captureCacheState(from webView: WKWebView, into tab: Tab) {
        guard cacheStateEnabled else { return }
        if let state = webView.interactionState {
            tab.interactionStateData = try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false)
        }
        webView.evaluateJavaScript("JSON.stringify(sessionStorage)") { result, _ in
            guard let json = result as? String, json != "{}",
                  let data = json.data(using: .utf8), data.count < maxSessionStorageBytes else { return }
            tab.sessionStorageData = data
        }
    }

    /// Restore a synced tab's interactionState into a fresh web view (scroll +
    /// history + form). Returns true if it restored (so the caller skips loading
    /// the URL — interactionState already brings back the page and history).
    @discardableResult
    static func restoreInteractionState(_ tab: Tab, into webView: WKWebView) -> Bool {
        guard cacheStateEnabled, let data = tab.interactionStateData,
              let state = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) else { return false }
        webView.interactionState = state
        return true
    }

    /// Best-effort repopulate sessionStorage on the loading page (call on commit).
    static func restoreSessionStorage(_ tab: Tab, into webView: WKWebView) {
        guard cacheStateEnabled, let data = tab.sessionStorageData,
              let json = String(data: data, encoding: .utf8) else { return }
        // `json` is JSON.stringify output — a valid JS object literal.
        webView.evaluateJavaScript("try{var s=\(json);for(var k in s){sessionStorage.setItem(k,s[k]);}}catch(e){}")
    }
}
