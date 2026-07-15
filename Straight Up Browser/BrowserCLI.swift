//
//  BrowserCLI.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import Foundation

// File-based CLI IPC. The browser owns a named pipe (FIFO) in its own
// Application Support directory with owner-only permissions - filesystem
// permissions are the authentication. The CLI tool writes one command per
// line; data commands pass --response-file <path>, which must live inside
// our response directory, and the app writes the JSON result there.
class BrowserCLI {
    static let shared = BrowserCLI()

    static let supportDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Straight Up Browser", isDirectory: true)
    static let pipeURL = supportDirectory.appendingPathComponent("cli.pipe")
    static let responseDirectory = supportDirectory.appendingPathComponent("responses", isDirectory: true)

    private var isPipeSetup = false

    private init() {
        setupCommandInterface()
    }

    private func setupCommandInterface() {
        guard !isPipeSetup else { return }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.responseDirectory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            Logger.log("Failed to create CLI directories: \(error)", type: "BrowserCLI")
            return
        }

        let pipePath = Self.pipeURL.path
        try? fm.removeItem(atPath: pipePath)

        guard mkfifo(pipePath, 0o600) == 0 else {
            Logger.log("Failed to create command pipe at \(pipePath)", type: "BrowserCLI")
            return
        }

        Logger.log("Browser CLI pipe created at: \(pipePath)", type: "BrowserCLI")
        isPipeSetup = true

        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.listenForCommands(at: pipePath)
        }
    }

    private func listenForCommands(at pipePath: String) {
        // O_RDWR on our own FIFO: never blocks on open, keeps a reader alive so
        // clients' O_NONBLOCK writes succeed (Darwin returns ENXIO to a
        // nonblocking writer unless the read end is fully open), and read()
        // blocks instead of returning EOF between clients. No polling, no spin.
        let fd = open(pipePath, O_RDWR)
        guard fd >= 0 else {
            Logger.log("Failed to open command pipe for reading", type: "BrowserCLI")
            return
        }
        let fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)

        var buffer = Data()
        while true {
            let chunk = fileHandle.availableData // blocks until data arrives
            if chunk.isEmpty { continue }
            buffer.append(chunk)

            // One command per line; writes under PIPE_BUF are atomic
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[buffer.index(after: newlineIndex)...])
                if let command = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !command.isEmpty {
                    handleCommand(command)
                }
            }
        }
    }

    private func handleCommand(_ command: String) {
        Logger.log("BrowserCLI handleCommand: \(command)", type: "BrowserCLI")

        var commandParts = command.split(separator: " ")
        var responseFilePath: String? = nil

        if let responseFlagIndex = commandParts.firstIndex(of: "--response-file"),
           responseFlagIndex + 1 < commandParts.count {
            // Bare filename only (the response dir path contains spaces, and we
            // never take an arbitrary write path from input anyway) - the app
            // resolves it inside its own response directory
            let name = String(commandParts[responseFlagIndex + 1])
            commandParts.remove(at: responseFlagIndex + 1)
            commandParts.remove(at: responseFlagIndex)

            if !name.contains("/") && !name.contains("..") {
                responseFilePath = Self.responseDirectory.appendingPathComponent(name).path
            } else {
                Logger.log("Rejected response file name: \(name)", type: "BrowserCLI")
            }
        }

        let action = commandParts.first?.lowercased()
        let parameter = commandParts.count > 1 ? commandParts[1..<commandParts.count].joined(separator: " ") : nil

        switch action {
        case "open":
            if let urlString = parameter {
                NotificationCenter.default.post(name: .browserOpenURL, object: nil, userInfo: ["url": urlString])
            }
        case "search":
            if let query = parameter {
                let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                NotificationCenter.default.post(name: .browserOpenURL, object: nil,
                                                userInfo: ["url": "https://www.google.com/search?q=" + encoded])
            }
        case "new":
            NotificationCenter.default.post(name: .browserNewTab, object: nil)
        case "close":
            NotificationCenter.default.post(name: .browserCloseTab, object: nil)
        case "tabs":
            var userInfo: [String: Any] = [:]
            if let responseFilePath = responseFilePath {
                userInfo["responseFilePath"] = responseFilePath
            }
            NotificationCenter.default.post(name: .browserListTabs, object: nil, userInfo: userInfo)
        case "get":
            var userInfo: [String: Any] = [:]
            if let urlString = parameter, urlString != "current" {
                userInfo["url"] = urlString
            } else {
                userInfo["currentPage"] = true
            }
            if let responseFilePath = responseFilePath {
                userInfo["responseFilePath"] = responseFilePath
            }
            NotificationCenter.default.post(name: .browserGetPageData, object: nil, userInfo: userInfo)
        default:
            Logger.log("Unknown CLI command: \(command)", type: "BrowserCLI")
        }
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

    // Edit menu
    static let browserFindInPage = Notification.Name("browserFindInPage")
    static let browserFindNext = Notification.Name("browserFindNext")
    static let browserFindPrevious = Notification.Name("browserFindPrevious")

    // View menu
    static let browserZoomIn = Notification.Name("browserZoomIn")
    static let browserZoomOut = Notification.Name("browserZoomOut")
    static let browserZoomReset = Notification.Name("browserZoomReset")
    static let browserPrint = Notification.Name("browserPrint")
    static let browserExportPDF = Notification.Name("browserExportPDF")

    // Link preview (long-press) signals from the injected page script
    static let browserLinkPreviewDown = Notification.Name("browserLinkPreviewDown")
    static let browserLinkPreviewLongPress = Notification.Name("browserLinkPreviewLongPress")
    static let browserLinkPreviewUp = Notification.Name("browserLinkPreviewUp")

    // Hold-Cmd+Q-to-quit progress (userInfo["progress"]: Double, 0 = cancelled)
    static let browserQuitHoldProgress = Notification.Name("browserQuitHoldProgress")
    static let browserToggleTabBar = Notification.Name("browserToggleTabBar")
    static let browserHideTabBar = Notification.Name("browserHideTabBar")
    static let browserMinimalTabBar = Notification.Name("browserMinimalTabBar")
    static let browserCompactTabBar = Notification.Name("browserCompactTabBar")
    static let browserWideTabBar = Notification.Name("browserWideTabBar")

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
    static let browserTabTitleDisplayModeChanged = Notification.Name("browserTabTitleDisplayModeChanged")

    // CLI data command
    static let browserGetPageData = Notification.Name("browserGetPageData")
}
