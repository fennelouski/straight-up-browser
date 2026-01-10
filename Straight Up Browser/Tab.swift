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

@Model
final class Tab {
    var id: UUID
    var title: String
    var url: URL?
    var isActive: Bool
    var createdAt: Date
    var lastAccessed: Date
    var historyStrings: [String] = []
    var currentHistoryIndex: Int = -1

    // Computed property to get history as URLs
    var history: [URL] {
        get {
            historyStrings.compactMap { URL(string: $0) }
        }
        set {
            historyStrings = newValue.map { $0.absoluteString }
        }
    }

    // Additional tab properties
    var isPinned: Bool = false
    var isMuted: Bool = false
    var lastThumbnail: Data?
    var favicon: Data?
    var loadingProgress: Double = 0.0
    var securityLevel: SecurityLevel = SecurityLevel.secure
    var zoomLevel: Double = 1.0
    var orderIndex: Int = 0
    var groupId: UUID? = nil

    init(title: String = "New Tab", url: URL? = nil, isActive: Bool = false) {
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
        self.init(title: "New Tab", url: nil, isActive: false)
    }

    func navigateTo(_ url: URL) {
        Logger.log("Tab.navigateTo: setting URL to \(url.absoluteString)", type: "Tab")
        self.url = url

        // Add to history
        if currentHistoryIndex >= 0 && currentHistoryIndex < history.count {
            // Remove forward history if we're not at the end
            history = Array(history.prefix(through: currentHistoryIndex))
        }
        history.append(url)
        currentHistoryIndex = history.count - 1

        // Limit history size (remove oldest entries)
        let maxHistorySize = SettingsManager.shared.maxHistorySize
        if history.count > maxHistorySize {
            let excess = history.count - maxHistorySize
            history.removeFirst(excess)
            currentHistoryIndex = max(history.count - 1, 0)
        }
    }

    func canGoBack() -> Bool {
        return currentHistoryIndex > 0
    }

    func canGoForward() -> Bool {
        return currentHistoryIndex < history.count - 1
    }

    func goBack() -> URL? {
        guard canGoBack() else { return nil }
        currentHistoryIndex -= 1
        url = history[currentHistoryIndex]
        return url
    }

    func goForward() -> URL? {
        guard canGoForward() else { return nil }
        currentHistoryIndex += 1
        url = history[currentHistoryIndex]
        return url
    }

    // Helper function to extract domain name from URL
    static func extractDomain(from url: URL?) -> String {
        guard let url = url, let host = url.host else {
            return "New Tab"
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
