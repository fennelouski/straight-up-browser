//
//  BookmarkImporter.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import Foundation
import AppKit

// Safari (needs manual HTML export) and Firefox (places.sqlite) are not
// supported - only browsers we can actually import from are offered.
nonisolated enum BrowserType: String, CaseIterable, Sendable {
    case chrome = "Google Chrome"
    case edge = "Microsoft Edge"

    var displayName: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .edge: return "Microsoft Edge"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .chrome: return "com.google.Chrome"
        case .edge: return "com.microsoft.edgemac"
        }
    }

    var suggestedBookmarkFileURL: URL {
        let homeDirectory = NSHomeDirectory()
        let path: String
        switch self {
        case .chrome:
            path = "\(homeDirectory)/Library/Application Support/Google/Chrome/Default/Bookmarks"
        case .edge:
            path = "\(homeDirectory)/Library/Application Support/Microsoft Edge/Default/Bookmarks"
        }
        return URL(fileURLWithPath: path)
    }
}

nonisolated struct ImportedBookmark: Sendable {
    let title: String
    let url: URL
    let dateAdded: Date?
}

class BookmarkImporter {
    static func detectAvailableBrowsers() -> [BrowserType] {
        var availableBrowsers: [BrowserType] = []

        for browser in BrowserType.allCases {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) != nil {
                availableBrowsers.append(browser)
            }
        }

        return availableBrowsers
    }

    static func importBookmarks(from browser: BrowserType) async throws -> [ImportedBookmark]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "Choose \(browser.displayName) Bookmarks")
        panel.message = String(
            localized: "Select the Bookmarks file exported or stored by \(browser.displayName)."
        )
        panel.prompt = String(localized: "Import")
        panel.directoryURL = browser.suggestedBookmarkFileURL
            .deletingLastPathComponent()
        guard await panel.begin() == .OK, let fileURL = panel.url else { return nil }
        return try await importChromeBookmarks(from: fileURL)
    }

    @concurrent static func importChromeBookmarks(from fileURL: URL) async throws -> [ImportedBookmark] {
        assert(!Thread.isMainThread)
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        var bookmarks: [ImportedBookmark] = []

        let data = try Data(contentsOf: fileURL)
        try Task.checkCancellation()
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let roots = json["roots"] as? [String: Any] {
            for key in roots.keys.sorted() {
                if let root = roots[key] as? [String: Any] {
                    parseChromeBookmarks(root, bookmarks: &bookmarks)
                }
            }
        }
        try Task.checkCancellation()

        return bookmarks
    }

    nonisolated private static func parseChromeBookmarks(_ item: [String: Any], bookmarks: inout [ImportedBookmark]) {
        guard !Task.isCancelled else { return }
        if let type = item["type"] as? String, type == "url" {
            if let title = item["name"] as? String,
               let urlString = item["url"] as? String,
               let url = URL(string: urlString) {
                // Chrome's date_added is microseconds since 1601-01-01, as a string.
                // Never force-unwrap external file content.
                let parsedDate = (item["date_added"] as? String)
                    .flatMap { TimeInterval($0) }
                    .map { Date(timeIntervalSince1970: $0 / 1_000_000 - 11_644_473_600) }
                    ?? Date()
                bookmarks.append(ImportedBookmark(title: title, url: url, dateAdded: parsedDate))
            }
        } else if let children = item["children"] as? [[String: Any]] {
            for child in children {
                parseChromeBookmarks(child, bookmarks: &bookmarks)
            }
        }
    }
}
