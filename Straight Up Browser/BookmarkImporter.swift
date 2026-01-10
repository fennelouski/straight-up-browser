//
//  BookmarkImporter.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import Foundation
import AppKit

enum BrowserType: String, CaseIterable {
    case safari = "Safari"
    case chrome = "Google Chrome"
    case firefox = "Firefox"
    case edge = "Microsoft Edge"

    var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        case .firefox: return "Mozilla Firefox"
        case .edge: return "Microsoft Edge"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        case .firefox: return "org.mozilla.firefox"
        case .edge: return "com.microsoft.edgemac"
        }
    }

    var bookmarkFilePath: String? {
        let fileManager = FileManager.default
        let homeDirectory = NSHomeDirectory()

        switch self {
        case .safari:
            // Safari bookmarks require special access. We'll use AppleScript instead
            // Return a dummy path that indicates Safari is available
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil ? "safari-script" : nil

        case .chrome:
            let path = "\(homeDirectory)/Library/Application Support/Google/Chrome/Default/Bookmarks"
            return fileManager.fileExists(atPath: path) ? path : nil

        case .firefox:
            // Firefox has profiles, we need to find the default profile
            let profilesPath = "\(homeDirectory)/Library/Application Support/Firefox/Profiles"
            if fileManager.fileExists(atPath: profilesPath) {
                do {
                    let profileDirs = try fileManager.contentsOfDirectory(atPath: profilesPath)
                    for profileDir in profileDirs {
                        if profileDir.hasSuffix(".default") || profileDir.hasSuffix(".default-release") {
                            let bookmarkPath = "\(profilesPath)/\(profileDir)/places.sqlite"
                            if fileManager.fileExists(atPath: bookmarkPath) {
                                return bookmarkPath
                            }
                        }
                    }
                } catch {
                    print("Error reading Firefox profiles: \(error)")
                }
            }
            return nil

        case .edge:
            let path = "\(homeDirectory)/Library/Application Support/Microsoft Edge/Default/Bookmarks"
            return fileManager.fileExists(atPath: path) ? path : nil
        }
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
        case .safari:
            return importSafariBookmarks(from: filePath)
        case .chrome, .edge:
            return importChromeBookmarks(from: filePath)
        case .firefox:
            return importFirefoxBookmarks(from: filePath)
        }
    }

    private static func importSafariBookmarks(from filePath: String) -> [ImportedBookmark] {
        var bookmarks: [ImportedBookmark] = []

        // Direct access to Safari's bookmark file is restricted by macOS privacy policies
        // We cannot access ~/Library/Safari/Bookmarks.plist without special entitlements
        // or user permission. Safari also doesn't expose bookmarks via AppleScript.

        // For now, return empty array with a note that Safari import requires manual export
        print("Safari bookmark import requires manual export: File > Export Bookmarks... then import the HTML file")

        // TODO: Add support for importing Safari's exported HTML bookmark files
        // Safari can export bookmarks as HTML, which we could parse

        return bookmarks
    }

    private static func parseSafariBookmarks(_ items: [[String: Any]], bookmarks: inout [ImportedBookmark]) {
        for item in items {
            if let type = item["WebBookmarkType"] as? String {
                if type == "WebBookmarkTypeLeaf" {
                    var title: String?
                    if let uriDict = item["URIDictionary"] as? [String: Any],
                       let uriTitle = uriDict["title"] as? String {
                        title = uriTitle
                    } else if let directTitle = item["title"] as? String {
                        title = directTitle
                    }

                    if let title = title,
                       let urlString = item["URLString"] as? String,
                       let url = URL(string: urlString) {
                        let dateAdded = (item["WebBookmarkCreationDateKey"] as? Date) ?? Date()
                        bookmarks.append(ImportedBookmark(title: title, url: url, dateAdded: dateAdded))
                    }
                } else if type == "WebBookmarkTypeList" {
                    if let children = item["Children"] as? [[String: Any]] {
                        parseSafariBookmarks(children, bookmarks: &bookmarks)
                    }
                }
            }
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
            print("Error importing Chrome bookmarks: \(error)")
        }

        return bookmarks
    }

    private static func parseChromeBookmarks(_ item: [String: Any], bookmarks: inout [ImportedBookmark]) {
        if let type = item["type"] as? String, type == "url" {
            if let title = item["name"] as? String,
               let urlString = item["url"] as? String,
               let url = URL(string: urlString) {
                let dateAdded = item["date_added"] as? String
                let parsedDate = dateAdded != nil ? Date(timeIntervalSince1970: TimeInterval(dateAdded!)! / 1000000) : Date()
                bookmarks.append(ImportedBookmark(title: title, url: url, dateAdded: parsedDate))
            }
        } else if let children = item["children"] as? [[String: Any]] {
            for child in children {
                parseChromeBookmarks(child, bookmarks: &bookmarks)
            }
        }
    }

    private static func importFirefoxBookmarks(from filePath: String) -> [ImportedBookmark] {
        // Firefox uses SQLite database, which is more complex to parse
        // For now, we'll return an empty array and note that Firefox import requires additional setup
        print("Firefox bookmark import requires SQLite parsing which is not implemented yet")
        return []
    }
}