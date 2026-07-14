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
enum BrowserType: String, CaseIterable {
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

    var bookmarkFilePath: String? {
        let homeDirectory = NSHomeDirectory()
        let path: String
        switch self {
        case .chrome:
            path = "\(homeDirectory)/Library/Application Support/Google/Chrome/Default/Bookmarks"
        case .edge:
            path = "\(homeDirectory)/Library/Application Support/Microsoft Edge/Default/Bookmarks"
        }
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}

struct ImportedBookmark {
    let title: String
    let url: URL
    let dateAdded: Date?
}

class BookmarkImporter {
    static func detectAvailableBrowsers() -> [BrowserType] {
        var availableBrowsers: [BrowserType] = []

        for browser in BrowserType.allCases {
            // Check if the app is installed
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) != nil {
                // Check if bookmark file exists
                if browser.bookmarkFilePath != nil {
                    availableBrowsers.append(browser)
                }
            }
        }

        return availableBrowsers
    }

    static func importBookmarks(from browser: BrowserType) -> [ImportedBookmark] {
        guard let filePath = browser.bookmarkFilePath else {
            return []
        }

        switch browser {
        case .chrome, .edge:
            return importChromeBookmarks(from: filePath)
        }
    }

    private static func importChromeBookmarks(from filePath: String) -> [ImportedBookmark] {
        var bookmarks: [ImportedBookmark] = []

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
            if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                if let roots = json["roots"] as? [String: Any] {
                    for (_, rootValue) in roots {
                        if let rootDict = rootValue as? [String: Any] {
                            parseChromeBookmarks(rootDict, bookmarks: &bookmarks)
                        }
                    }
                }
            }
        } catch {
            Logger.log("Error importing Chrome bookmarks: \(error)", type: "BookmarkImporter")
        }

        return bookmarks
    }

    private static func parseChromeBookmarks(_ item: [String: Any], bookmarks: inout [ImportedBookmark]) {
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