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
        Logger.log("BrowserCLI initialized", type: "BrowserCLI")
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
            Logger.log("Browser CLI pipe created at: \(pipePath)", type: "BrowserCLI")
            isPipeSetup = true

            // Start listening for commands in background
            DispatchQueue.global(qos: .background).async {
                self.listenForCommands(at: pipePath)
            }
        } else {
            Logger.log("Failed to create command pipe", type: "BrowserCLI")
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
                Logger.log("Error reading from pipe: \(error)", type: "BrowserCLI")
                // Wait a bit before retrying
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
    }

    private func handleCommand(_ command: String) {
        Logger.log("BrowserCLI handleCommand called with: \(command)", type: "BrowserCLI")
        // Ensure pipe is set up before handling commands
        setupCommandInterface()

        // Parse command and extract response file if present
        var commandParts = command.split(separator: " ")
        var responseFilePath: String? = nil

        // Check for --response-file flag
        if let responseFlagIndex = commandParts.firstIndex(of: "--response-file"),
           responseFlagIndex + 1 < commandParts.count {
            responseFilePath = String(commandParts[responseFlagIndex + 1])
            Logger.log("Found response file path: \(responseFilePath!)", type: "BrowserCLI")
            // Remove the response file arguments from the command
            commandParts.remove(at: responseFlagIndex + 1)
            commandParts.remove(at: responseFlagIndex)
        }

        let action = commandParts.first?.lowercased()
        let parameter = commandParts.count > 1 ? commandParts[1..<commandParts.count].joined(separator: " ") : nil
        Logger.log("Parsed action: \(action ?? "nil"), parameter: \(parameter ?? "nil")", type: "BrowserCLI")

        switch action {
        case "open":
            if let urlString = parameter {
                openURL(urlString)
            }
        case "get":
            if let urlString = parameter {
                let actualURL = (urlString == "current") ? nil : urlString
                getPageData(actualURL, responseFilePath: responseFilePath)
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
            Logger.log("Unknown command: \(command)", type: "BrowserCLI")
        }

    }

    private func openURL(_ urlString: String) {
        // Send notification to the main app to open URL
        NotificationCenter.default.post(name: .browserOpenURL, object: nil, userInfo: ["url": urlString])
    }

    private func getPageData(_ urlString: String?, responseFilePath: String? = nil) {
        Logger.log("BrowserCLI getPageData called with urlString: \(urlString ?? "nil"), responseFilePath: \(responseFilePath ?? "nil")", type: "BrowserCLI")

        // For testing, write a simple response immediately
        if let responseFilePath = responseFilePath {
            let testResponse = "{\"status\": \"command_received\", \"url\": \"\(urlString ?? "current")\", \"timestamp\": \"\(Date())\"}"
            do {
                try testResponse.write(toFile: responseFilePath, atomically: true, encoding: .utf8)
                Logger.log("Test response written to: \(responseFilePath)", type: "BrowserCLI")
            } catch {
                Logger.log("Error writing test response: \(error)", type: "BrowserCLI")
            }
        }

        // Send notification to extract page data from the active web view
        var userInfo: [String: Any] = [:]
        if let urlString = urlString {
            userInfo["url"] = urlString
        } else {
            userInfo["currentPage"] = true
        }
        if let responseFilePath = responseFilePath {
            userInfo["responseFilePath"] = responseFilePath
        }
        Logger.log("Posting browserGetPageData notification", type: "BrowserCLI")
        NotificationCenter.default.post(name: .browserGetPageData, object: nil, userInfo: userInfo)
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

    // View menu
    static let browserToggleTabBar = Notification.Name("browserToggleTabBar")
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

    // Window menu
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
