//
//  BrowserCLI.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import Foundation

class BrowserCLI {
    static let shared = BrowserCLI()

    private var commandPipe: Pipe?
    private var commandHandle: FileHandle?
    private var isPipeSetup = false

    private init() {
        // Defer pipe setup until first use to avoid sandboxing issues during app initialization
    }

    private func setupCommandInterface() {
        guard !isPipeSetup else { return }

        // Create a named pipe for receiving commands
        let pipePath = "/tmp/straight_up_browser_commands"

        // Remove existing pipe if it exists
        try? FileManager.default.removeItem(atPath: pipePath)

        // Create new pipe
        let result = mkfifo(pipePath, 0o666)
        if result == 0 {
            print("Browser CLI pipe created at: \(pipePath)")
            isPipeSetup = true

            // Start listening for commands in background
            DispatchQueue.global(qos: .background).async {
                self.listenForCommands(at: pipePath)
            }
        } else {
            print("Failed to create command pipe")
        }
    }

    private func listenForCommands(at pipePath: String) {
        while true {
            do {
                let fileHandle = FileHandle(forReadingAtPath: pipePath)
                defer { try? fileHandle?.close() }

                if let data = try fileHandle?.readToEnd() {
                    if let command = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                        handleCommand(command)
                    }
                }
            } catch {
                print("Error reading from pipe: \(error)")
                // Wait a bit before retrying
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
    }

    private func handleCommand(_ command: String) {
        // Ensure pipe is set up before handling commands
        setupCommandInterface()

        let parts = command.split(separator: " ", maxSplits: 1)
        let action = parts.first?.lowercased()
        let parameter = parts.count > 1 ? String(parts[1]) : nil

        switch action {
        case "open":
            if let urlString = parameter {
                openURL(urlString)
            }
        case "get":
            if let urlString = parameter {
                getPageData(urlString)
            }
        case "search":
            if let query = parameter {
                search(query)
            }
        case "close":
            closeActiveTab()
        case "new":
            createNewTab()
        case "tabs":
            listTabs()
        case "screenshot":
            if let urlString = parameter {
                screenshot(urlString)
            }
        case "pdf":
            if let urlString = parameter {
                exportPDF(urlString)
            }
        case "inject":
            if let script = parameter {
                injectScript(script)
            }
        case "cookies":
            showCookies()
        case "history":
            showHistory()
        case "bookmarks":
            showBookmarks()
        case "download":
            if let urlString = parameter {
                downloadFile(urlString)
            }
        case "focus":
            if let tabId = parameter {
                focusTab(tabId)
            }
        default:
            print("Unknown command: \(command)")
        }

    }

    private func openURL(_ urlString: String) {
        // Send notification to the main app to open URL
        NotificationCenter.default.post(name: .browserOpenURL, object: nil, userInfo: ["url": urlString])
    }

    private func getPageData(_ urlString: String) {
        // Send notification to extract page data from the active web view
        NotificationCenter.default.post(name: .browserGetPageData, object: nil, userInfo: ["url": urlString])
    }

    private func search(_ query: String) {
        let searchURL = "https://www.google.com/search?q=" + query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        openURL(searchURL)
    }

    private func closeActiveTab() {
        NotificationCenter.default.post(name: .browserCloseTab, object: nil)
    }

    private func createNewTab() {
        NotificationCenter.default.post(name: .browserNewTab, object: nil)
    }

    private func listTabs() {
        NotificationCenter.default.post(name: .browserListTabs, object: nil)
    }

    private func screenshot(_ urlString: String) {
        NotificationCenter.default.post(name: .browserScreenshot, object: nil, userInfo: ["url": urlString])
    }

    private func exportPDF(_ urlString: String) {
        NotificationCenter.default.post(name: .browserExportPDF, object: nil, userInfo: ["url": urlString])
    }

    private func injectScript(_ script: String) {
        NotificationCenter.default.post(name: .browserInjectScript, object: nil, userInfo: ["script": script])
    }

    private func showCookies() {
        NotificationCenter.default.post(name: .browserShowCookies, object: nil)
    }

    private func showHistory() {
        NotificationCenter.default.post(name: .browserShowHistory, object: nil)
    }

    private func showBookmarks() {
        NotificationCenter.default.post(name: .browserShowBookmarks, object: nil)
    }

    private func downloadFile(_ urlString: String) {
        NotificationCenter.default.post(name: .browserDownloadFile, object: nil, userInfo: ["url": urlString])
    }

    private func focusTab(_ tabId: String) {
        NotificationCenter.default.post(name: .browserFocusTab, object: nil, userInfo: ["tabId": tabId])
    }
}

// Notification names
extension Notification.Name {
    static let browserOpenURL = Notification.Name("browserOpenURL")
    static let browserCloseTab = Notification.Name("browserCloseTab")
    static let browserNewTab = Notification.Name("browserNewTab")
    static let reopenLastClosedTab = Notification.Name("reopenLastClosedTab")
    static let showOmnibar = Notification.Name("showOmnibar")
    static let browserListTabs = Notification.Name("browserListTabs")

    // File menu
    static let browserOpenLocation = Notification.Name("browserOpenLocation")
    static let browserSavePageAs = Notification.Name("browserSavePageAs")
    static let browserPrint = Notification.Name("browserPrint")

    // Edit menu
    static let browserFind = Notification.Name("browserFind")
    static let browserFindNext = Notification.Name("browserFindNext")
    static let browserFindPrevious = Notification.Name("browserFindPrevious")

    // View menu
    static let browserZoomIn = Notification.Name("browserZoomIn")
    static let browserZoomOut = Notification.Name("browserZoomOut")
    static let browserActualSize = Notification.Name("browserActualSize")
    static let browserReaderMode = Notification.Name("browserReaderMode")
    static let browserHideTabBar = Notification.Name("browserHideTabBar")
    static let browserMinimalTabBar = Notification.Name("browserMinimalTabBar")
    static let browserCompactTabBar = Notification.Name("browserCompactTabBar")
    static let browserWideTabBar = Notification.Name("browserWideTabBar")

    // History menu
    static let browserShowHistory = Notification.Name("browserShowHistory")

    // Bookmarks menu
    static let browserShowBookmarks = Notification.Name("browserShowBookmarks")
    static let browserAddBookmark = Notification.Name("browserAddBookmark")
    static let browserImportBookmarks = Notification.Name("browserImportBookmarks")

    // Developer menu
    static let browserInspectElement = Notification.Name("browserInspectElement")
    static let browserShowConsole = Notification.Name("browserShowConsole")
    static let browserShowNetwork = Notification.Name("browserShowNetwork")

    // Window menu
    static let browserNewWindow = Notification.Name("browserNewWindow")
    static let browserShowDownloads = Notification.Name("browserShowDownloads")
    static let browserShowExtensions = Notification.Name("browserShowExtensions")
    static let browserNextTab = Notification.Name("browserNextTab")
    static let browserPreviousTab = Notification.Name("browserPreviousTab")
    static let browserSwitchToTab1 = Notification.Name("browserSwitchToTab1")
    static let browserSwitchToTab2 = Notification.Name("browserSwitchToTab2")
    static let browserSwitchToTab3 = Notification.Name("browserSwitchToTab3")
    static let browserSwitchToTab4 = Notification.Name("browserSwitchToTab4")
    static let browserSwitchToTab5 = Notification.Name("browserSwitchToTab5")
    static let browserSwitchToTab6 = Notification.Name("browserSwitchToTab6")
    static let browserSwitchToTab7 = Notification.Name("browserSwitchToTab7")
    static let browserSwitchToTab8 = Notification.Name("browserSwitchToTab8")
    static let browserSwitchToTab9 = Notification.Name("browserSwitchToTab9")

    // Settings
    static let browserShowSettings = Notification.Name("browserShowSettings")

    // CLI Commands
    static let browserScreenshot = Notification.Name("browserScreenshot")
    static let browserExportPDF = Notification.Name("browserExportPDF")
    static let browserInjectScript = Notification.Name("browserInjectScript")
    static let browserShowCookies = Notification.Name("browserShowCookies")
    static let browserDownloadFile = Notification.Name("browserDownloadFile")
    static let browserFocusTab = Notification.Name("browserFocusTab")
    static let browserGetPageData = Notification.Name("browserGetPageData")
    static let browserTabTitleDisplayModeChanged = Notification.Name("browserTabTitleDisplayModeChanged")
}
