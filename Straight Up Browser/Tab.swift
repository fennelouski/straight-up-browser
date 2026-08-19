//
//  Tab.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import Foundation
import SwiftData
#if os(macOS)
import AppKit
#endif

enum SecurityLevel: String, Codable {
    case none
    case secure
    case insecure
    case mixed
}

// How aggressively this tab may be released from RAM under memory pressure.
enum MemoryPolicy: String, Codable, CaseIterable {
    case always      // first to be dropped (mild pressure)
    case whenNeeded  // dropped under mild pressure
    case lastResort  // dropped only under critical pressure
    case never       // never dropped (long-running tasks, media)

    var label: String {
        switch self {
        case .always: return String(localized: "Always")
        case .whenNeeded: return String(localized: "Only when needed")
        case .lastResort: return String(localized: "As a last resort")
        case .never: return String(localized: "Never")
        }
    }
}

// Sites that stay live no matter what: streaming, calls, anything you leave
// running in a background tab. Matched by host suffix, so "spotify.com" also
// pins open.spotify.com, and one entry covers every tab on that site — a tab's
// own MemoryPolicy doesn't have to be re-set each time you open one.
enum MemoryPinnedSites {
    static let defaultsKey = "memoryPinnedSites"

    static let starterHosts = [
        "meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "discord.com", "app.slack.com",
        "open.spotify.com", "music.apple.com", "music.youtube.com",
        "soundcloud.com", "pandora.com", "tidal.com",
        "netflix.com", "twitch.tv", "hulu.com", "max.com", "disneyplus.com",
    ]

    static var hosts: [String] {
        get { UserDefaults.standard.array(forKey: defaultsKey) as? [String] ?? starterHosts }
        set {
            let cleaned = Array(Set(newValue.map(normalized).filter { !$0.isEmpty })).sorted()
            UserDefaults.standard.set(cleaned, forKey: defaultsKey)
        }
    }

    /// Accepts a bare host or a pasted URL; returns the bare, lowercased host.
    static func normalized(_ entry: String) -> String {
        var value = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let host = URL(string: value)?.host { value = host }
        if value.hasPrefix("www.") { value = String(value.dropFirst(4)) }
        return value
    }

    static func matches(_ url: URL?, hosts: [String]) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return hosts.contains { pinned in
            !pinned.isEmpty && (host == pinned || host.hasSuffix("." + pinned))
        }
    }

    static func isPinned(_ url: URL?) -> Bool { matches(url, hosts: hosts) }

    static func setPinned(_ pinned: Bool, for url: URL?) {
        guard let host = url?.host.map(normalized), !host.isEmpty else { return }
        if pinned {
            hosts = hosts + [host]
        } else {
            // Drop every entry this URL matches, not just an exact one — otherwise
            // un-pinning a page covered by a parent-domain rule silently does nothing.
            hosts = hosts.filter { !matches(url, hosts: [$0]) }
        }
    }
}

enum BrowserResourcePolicy {
    static func shouldUnload(_ policy: MemoryPolicy, url: URL? = nil, critical: Bool) -> Bool {
        // Site pin beats the per-tab policy: the whole point is not having to set
        // the policy on every Spotify tab you ever open.
        if MemoryPinnedSites.isPinned(url) { return false }
        switch policy {
        case .never: return false
        case .lastResort: return critical
        case .always, .whenNeeded: return true
        }
    }

    static func showFaviconProgress(
        enabled: Bool,
        isActive: Bool,
        isLoading: Bool
    ) -> Bool {
        enabled && isActive && isLoading
    }
}

// Which data store (cookie/cache/storage jar) a tab browses in.
// normal    = the shared default persistent store (every tab, today).
// container = a named persistent isolated store keyed by sessionId (a BrowserSession),
//             so you can stay logged into one site under different accounts side by side.
// incognito = an ephemeral in-memory store that dies with its tabs; incognito tabs are
//             held in memory only (never persisted/synced), see TabManager.incognitoTabs.
enum SessionKind: String, Codable {
    case normal
    case container
    case incognito
}

@Model
final class Tab {
    // Defaults on every stored attribute: SwiftData+CloudKit requires each
    // non-relationship attribute to be optional or have a default value.
    var id: UUID = UUID()
    var title: String = ""
    var url: URL?
    var isActive: Bool = false
    var createdAt: Date = Date()
    var lastAccessed: Date = Date()
    var historyStrings: [String] = []
    var currentHistoryIndex: Int = -1 // ponytail: unused since back/forward moved to WKWebView, kept for store compatibility

    // Computed property to get history as URLs
    var history: [URL] {
        get {
            historyStrings.compactMap { URL(string: $0) }
        }
        set {
            historyStrings = newValue.map { $0.absoluteString }
        }
    }

    // Typed accessor over memoryPolicyRaw (see the note on the stored property). A missing
    // or unknown raw value falls back to .whenNeeded, so a read can never crash.
    var memoryPolicy: MemoryPolicy {
        get { memoryPolicyRaw.flatMap(MemoryPolicy.init(rawValue:)) ?? .whenNeeded }
        set { memoryPolicyRaw = newValue.rawValue }
    }

    // Typed accessor over sessionKindRaw. Stores nil for .normal so existing rows
    // (and every normal tab) stay clean and don't need migration.
    var sessionKind: SessionKind {
        get { sessionKindRaw.flatMap(SessionKind.init(rawValue:)) ?? .normal }
        set { sessionKindRaw = newValue == .normal ? nil : newValue.rawValue }
    }

    // The engine this tab should use where available. Existing rows, unknown
    // future values, and all newly-created tabs default to WebKit. Keep the raw
    // preference even on a WebKit-only device so CloudKit round-trips do not
    // erase a Mac tab's Chromium choice.
    var preferredEngine: BrowserEngine {
        get { browserEngineRaw.flatMap(BrowserEngine.init(rawValue:)) ?? .webKit }
        set { browserEngineRaw = newValue == .webKit ? nil : newValue.rawValue }
    }

    var effectiveEngine: BrowserEngine {
        BrowserEngineAvailability.effectiveEngine(for: preferredEngine)
    }

    var browsingContext: BrowsingContext {
        BrowsingContext(
            sessionKind: sessionKind,
            sessionId: sessionId,
            preferredEngine: preferredEngine
        )
    }

    /// The research workspace this tab belongs to; nil is the default workspace
    /// (no workspace), which is an absence rather than a row. A workspace's tabs
    /// stay with it permanently and are never carried into the default workspace.
    var workspaceId: UUID?

    // Additional tab properties
    var isPinned: Bool = false
    var isMuted: Bool = false
    var lastThumbnail: Data?
    var favicon: Data?
    // Cache-state sync (opt-in): archived WKWebView.interactionState (scroll +
    // back/forward history + form state), so a synced tab resumes where you left
    // off on another device. sessionStorageData is retained only to migrate and
    // delete snapshots written by builds before 2.0.0 (23); it is never restored.
    var interactionStateData: Data? = nil
    var sessionStorageData: Data? = nil
    var loadingProgress: Double = 0.0
    var securityLevel: SecurityLevel = SecurityLevel.none
    // Persisted as the raw string, not the enum. Adding a non-optional enum column to a
    // store that already has rows leaves those rows unmigrated, and SwiftData crashes
    // (swift_dynamicCastFailure) reading them. An optional String migrates cleanly; the
    // typed `memoryPolicy` accessor is below, mirroring history/historyStrings.
    var memoryPolicyRaw: String?
    var zoomLevel: Double = 1.0
    var orderIndex: Int = 0
    var groupId: UUID? = nil
    // The tab this one was opened from (⌘-click, popup, ⌘T). Makes tabs opened
    // from a page a reading queue: closing the opener focuses its first child,
    // closing that child focuses the next one (see TabManager.neighbor).
    var openerId: UUID? = nil
    // Session isolation. nil sessionKindRaw => normal (shared default store). For a
    // container tab, sessionId is its BrowserSession.id. For an incognito tab, sessionId
    // identifies which ephemeral store its tabs share (the tab itself lives in memory only).
    var sessionId: UUID? = nil
    var sessionKindRaw: String? = nil   // optional String for clean SwiftData migration (see memoryPolicyRaw)
    // nil means WebKit. Optional raw storage lets existing SwiftData/CloudKit
    // rows migrate cleanly and lets mobile preserve an unavailable Mac engine.
    var browserEngineRaw: String? = nil

    init(title: String = String(localized: "New Tab"), url: URL? = nil, isActive: Bool = false) {
        self.id = UUID()
        self.title = title
        self.url = url
        self.isActive = isActive
        self.createdAt = Date()
        self.lastAccessed = Date()
        if let url = url {
            self.historyStrings = [url.absoluteString]
            self.currentHistoryIndex = 0
        }
    }

    convenience init() {
        self.init(title: String(localized: "New Tab"), url: nil, isActive: false)
    }

    // Back/forward navigation lives in WKWebView's back-forward list.
    // historyStrings is only a visit log for omnibar suggestions.
    @MainActor
    func navigateTo(_ url: URL) {
        Logger.log("Tab.navigateTo: setting URL to \(url.absoluteString)", type: "Tab")
        self.url = url

        historyStrings.append(url.absoluteString)

        // Limit history size (remove oldest entries)
        let maxHistorySize = SettingsManager.shared.maxHistorySize
        if historyStrings.count > maxHistorySize {
            historyStrings.removeFirst(historyStrings.count - maxHistorySize)
        }
    }

    // Helper function to extract domain name from URL
    static func extractDomain(from url: URL?) -> String {
        guard let url = url, let host = url.host else {
            return String(localized: "New Tab")
        }

        // Remove www. prefix if present
        var domain = host
        if domain.hasPrefix("www.") {
            domain = String(domain.dropFirst(4))
        }

        return domain
    }

    // Normalize URL for comparison by removing trailing slashes
    static func normalizeURLForComparison(_ url: URL?) -> URL? {
        guard let url = url else { return nil }
        var urlString = url.absoluteString

        // Remove trailing slash from path, but keep it for root URLs
        if urlString.hasSuffix("/") && url.path != "/" {
            urlString = String(urlString.dropLast())
        }

        return URL(string: urlString)
    }

    // Short, page-specific text for the hidden-sidebar tab peek. Prefer a real
    // page title, but fall back to path/query details when sibling tabs on the
    // same site have the same title (or only a domain title).
    func peekLabel(among tabs: [Tab], maxLength: Int = 39) -> String {
        func normalizedHost(_ url: URL?) -> String {
            guard var host = url?.host?.lowercased() else { return "" }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return host
        }
        let host = normalizedHost(url)
        let peers = tabs.filter { normalizedHost($0.url) == host }

        func titleCandidate(_ tab: Tab) -> String? {
            let value = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  value.caseInsensitiveCompare(host) != .orderedSame,
                  value != String(localized: "New Tab") else { return nil }
            return value
        }

        let ownTitle = titleCandidate(self)
        let sameTitleCount = ownTitle.map { title in
            peers.filter { titleCandidate($0)?.caseInsensitiveCompare(title) == .orderedSame }.count
        } ?? 0

        var label: String
        if let ownTitle, sameTitleCount <= 1 {
            label = ownTitle
        } else if let url {
            let path = url.pathComponents
                .filter { $0 != "/" }
                .suffix(2)
                .map { $0.removingPercentEncoding ?? $0 }
                .joined(separator: " / ")
            if !path.isEmpty {
                label = path
            } else if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { !($0.value ?? "").isEmpty }) {
                label = query.value ?? query.name
            } else {
                label = ownTitle ?? host
            }
        } else {
            label = ownTitle ?? String(localized: "New Tab")
        }

        if peers.filter({ peer in
            guard peer.id != id else { return false }
            return peer.url == url || titleCandidate(peer)?.caseInsensitiveCompare(label) == .orderedSame
        }).isEmpty == false,
           let position = peers.firstIndex(where: { $0.id == id }) {
            label += " · \(position + 1)"
        }

        return String(label.prefix(maxLength))
    }

    // Update title based on current URL
    func updateTitleFromURL() {
        title = Tab.extractDomain(from: url)
    }
}
