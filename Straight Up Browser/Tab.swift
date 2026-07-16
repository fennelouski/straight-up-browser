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

    // Additional tab properties
    var isPinned: Bool = false
    var isMuted: Bool = false
    var lastThumbnail: Data?
    var favicon: Data?
    // Cache-state sync (opt-in): archived WKWebView.interactionState (scroll +
    // back/forward history + much form state) and a best-effort sessionStorage
    // snapshot, so a synced tab resumes where you left off on another device.
    var interactionStateData: Data? = nil
    var sessionStorageData: Data? = nil
    var loadingProgress: Double = 0.0
    var securityLevel: SecurityLevel = SecurityLevel.secure
    // Persisted as the raw string, not the enum. Adding a non-optional enum column to a
    // store that already has rows leaves those rows unmigrated, and SwiftData crashes
    // (swift_dynamicCastFailure) reading them. An optional String migrates cleanly; the
    // typed `memoryPolicy` accessor is below, mirroring history/historyStrings.
    var memoryPolicyRaw: String?
    var zoomLevel: Double = 1.0
    var orderIndex: Int = 0
    var groupId: UUID? = nil

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

    // Update title based on current URL
    func updateTitleFromURL() {
        title = Tab.extractDomain(from: url)
    }
}
