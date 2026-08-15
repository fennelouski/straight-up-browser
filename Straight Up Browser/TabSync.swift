//
//  TabSync.swift
//  Straight Up Browser
//
//  Cross-device tab sync (SwiftData + iCloud/CloudKit). Shared by both the macOS
//  and iOS/iPadOS targets. The master toggle picks the CloudKit private database at
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

enum SyncedDataCategory: String, CaseIterable {
    case tabs
    case tabGroups
    case bookmarks
    case browserSessions
    case autofillProfiles
    case newspaper
    case scratchPad

    var label: String {
        switch self {
        case .tabs:
            return String(localized: "Open tabs: URLs, titles, visit history, and tab settings")
        case .tabGroups:
            return String(localized: "Tab groups: names, colors, and ordering")
        case .bookmarks:
            return String(localized: "Bookmarks: titles, URLs, categories, and favicons")
        case .browserSessions:
            return String(localized: "Browsing containers: names and colors (not cookies or logins)")
        case .autofillProfiles:
            return String(localized: "Autofill profiles: names, contact details, and addresses (no cards or passwords)")
        case .newspaper:
            return String(localized: "Newspaper: saved article text, reading state, sections, and ratings")
        case .scratchPad:
            return String(localized: "Scratch Pad: notes, clipped text, links, images, and source attribution")
        }
    }

    var systemImage: String {
        switch self {
        case .tabs: return "rectangle.on.rectangle"
        case .tabGroups: return "square.stack.3d.up"
        case .bookmarks: return "bookmark"
        case .browserSessions: return "person.crop.square"
        case .autofillProfiles: return "text.append"
        case .newspaper: return "newspaper"
        case .scratchPad: return "note.text"
        }
    }
}

private struct CloudBackedModelDescriptor {
    let modelType: any PersistentModel.Type
    let category: SyncedDataCategory
}

enum TabSync {
    static let containerID = "iCloud.com.nathanfennel.Straight-Up-Browser"

    // This list drives both ModelContainer schemas and the settings disclosure.
    // Adding a CloudKit-backed model therefore requires naming its user-visible
    // data category in the same change.
    private static let cloudBackedModels: [CloudBackedModelDescriptor] = [
        CloudBackedModelDescriptor(modelType: Tab.self, category: .tabs),
        CloudBackedModelDescriptor(modelType: TabGroup.self, category: .tabGroups),
        CloudBackedModelDescriptor(modelType: Bookmark.self, category: .bookmarks),
        CloudBackedModelDescriptor(modelType: BrowserSession.self, category: .browserSessions),
        CloudBackedModelDescriptor(modelType: AutofillProfile.self, category: .autofillProfiles),
        CloudBackedModelDescriptor(modelType: NewspaperArticle.self, category: .newspaper),
        CloudBackedModelDescriptor(modelType: ScratchPadItem.self, category: .scratchPad)
    ]

    static var cloudBackedModelTypes: [any PersistentModel.Type] {
        cloudBackedModels.map(\.modelType)
    }

    static var cloudBackedModelTypeNames: [String] {
        cloudBackedModels.map { String(describing: $0.modelType) }
    }

    static var syncedDataCategories: [SyncedDataCategory] {
        cloudBackedModels.map(\.category)
    }

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
    static func iCloudAvailable(
        effectiveContainerIdentifiers: Set<String>? = nil,
        accountStatus: @Sendable () async throws -> CKAccountStatus = {
            try await CKContainer(identifier: containerID).accountStatus()
        }
    ) async -> Bool {
        guard CloudKitEntitlements.permits(
            containerID,
            effectiveIdentifiers: effectiveContainerIdentifiers
        ) else {
            return false
        }
        do {
            return try await accountStatus() == .available
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

    /// Page-state sync is separately opt-in. Removing that permission must also
    /// remove snapshots already stored on tab records so CloudKit propagates the
    /// deletion instead of retaining old form/session data.
    @discardableResult
    static func clearPageState(in tabs: [Tab]) -> Int {
        var changed = 0
        for tab in tabs where tab.interactionStateData != nil || tab.sessionStorageData != nil {
            tab.interactionStateData = nil
            tab.sessionStorageData = nil
            changed += 1
        }
        return changed
    }

    /// Builds before 2.0.0 (23) could persist `sessionStorage`, which can contain
    /// website authentication state. Scrub every legacy snapshot so SwiftData
    /// propagates deletion to the user's private CloudKit database.
    @discardableResult
    static func clearLegacySessionStorage(in tabs: [Tab]) -> Int {
        var changed = 0
        for tab in tabs where tab.sessionStorageData != nil {
            tab.sessionStorageData = nil
            changed += 1
        }
        return changed
    }

    /// Snapshot the web view's page state (scroll + back/forward + form state via
    /// interactionState) onto the tab so it syncs. Website storage is excluded.
    static func captureCacheState(from webView: WKWebView, into tab: Tab) {
        guard cacheStateEnabled else { return }
        tab.sessionStorageData = nil
        if let state = webView.interactionState {
            tab.interactionStateData = try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false)
        }
    }

    /// Restore a synced tab's interactionState into a fresh web view (scroll +
    /// history + form). Returns true if it restored (so the caller skips loading
    /// the URL — interactionState already brings back the page and history).
    @discardableResult
    static func restoreInteractionState(_ tab: Tab, into webView: WKWebView) -> Bool {
        guard cacheStateEnabled, let data = tab.interactionStateData,
              let state = NSKeyedUnarchiver.unarchiveTopLevelObject(from: data) else { return false }
        webView.interactionState = state
        return true
    }

}
