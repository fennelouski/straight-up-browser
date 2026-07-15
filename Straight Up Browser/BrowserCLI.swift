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

    // Every response the app writes lives inside its own responses/ dir.
    // Errors and acks share one JSON shape: {"ok":true,...} or {"error":"..."}.
    static func writeResponse(_ dict: [String: Any], to path: String?) {
        guard let path = path else { return }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
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

        // Same cold-launch race App Intents guard against: observers attach in
        // ContentView.onAppear. We're on the dedicated pipe thread and commands
        // are serial, so a bounded blocking wait is fine.
        if !NotificationManager.observersReady {
            for _ in 0..<100 where !NotificationManager.observersReady {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if !NotificationManager.observersReady {
                Self.writeResponse(["error": "Browser window not ready (first-run EULA screen?)"], to: responseFilePath)
                return
            }
        }

        var newTab = false
        if let newFlagIndex = commandParts.firstIndex(of: "--new") {
            commandParts.remove(at: newFlagIndex)
            newTab = true
        }

        let action = commandParts.first?.lowercased()
        let parameter = commandParts.count > 1 ? commandParts[1..<commandParts.count].joined(separator: " ") : nil

        // Acks mean "accepted for execution on the main queue" - agents follow
        // navigation with `wait`. Commands that can fail respond from their
        // observer instead.
        switch action {
        case "open":
            if let urlString = parameter {
                var userInfo: [String: Any] = ["url": urlString]
                if newTab { userInfo["newTab"] = true }
                NotificationCenter.default.post(name: .browserOpenURL, object: nil, userInfo: userInfo)
                Self.writeResponse(["ok": true], to: responseFilePath)
            } else {
                Self.writeResponse(["error": "open requires a URL"], to: responseFilePath)
            }
        case "search":
            if let query = parameter {
                let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                NotificationCenter.default.post(name: .browserOpenURL, object: nil,
                                                userInfo: ["url": "https://www.google.com/search?q=" + encoded])
                Self.writeResponse(["ok": true], to: responseFilePath)
            } else {
                Self.writeResponse(["error": "search requires a query"], to: responseFilePath)
            }
        case "new":
            NotificationCenter.default.post(name: .browserNewTab, object: nil)
            Self.writeResponse(["ok": true], to: responseFilePath)
        case "close":
            NotificationCenter.default.post(name: .browserCloseTab, object: nil)
            Self.writeResponse(["ok": true], to: responseFilePath)
        case "back", "forward", "reload":
            NotificationCenter.default.post(name: .browserNavigate, object: nil, userInfo: ["action": action!])
            Self.writeResponse(["ok": true], to: responseFilePath)
        case "switch":
            if let parameter = parameter, let index = Int(parameter) {
                var userInfo: [String: Any] = ["index": index]
                if let responseFilePath = responseFilePath { userInfo["responseFilePath"] = responseFilePath }
                NotificationCenter.default.post(name: .browserSwitchTab, object: nil, userInfo: userInfo)
            } else {
                Self.writeResponse(["error": "switch requires a tab index (1-based, see `tabs`)"], to: responseFilePath)
            }
        case "wait":
            let timeout = parameter.flatMap(Double.init) ?? 15
            var userInfo: [String: Any] = ["timeout": timeout]
            if let responseFilePath = responseFilePath { userInfo["responseFilePath"] = responseFilePath }
            NotificationCenter.default.post(name: .browserWaitForLoad, object: nil, userInfo: userInfo)
        case "js":
            // Code is base64'd by the CLI so newlines/spaces survive the
            // one-line pipe protocol
            if let encoded = parameter, let data = Data(base64Encoded: encoded),
               let script = String(data: data, encoding: .utf8) {
                var userInfo: [String: Any] = ["script": script]
                if let responseFilePath = responseFilePath { userInfo["responseFilePath"] = responseFilePath }
                NotificationCenter.default.post(name: .browserRunJS, object: nil, userInfo: userInfo)
            } else {
                Self.writeResponse(["error": "js requires base64-encoded code"], to: responseFilePath)
            }
        case "realclick":
            if let encoded = parameter, let data = Data(base64Encoded: encoded),
               let selector = String(data: data, encoding: .utf8) {
                var userInfo: [String: Any] = ["selector": selector]
                if let responseFilePath = responseFilePath { userInfo["responseFilePath"] = responseFilePath }
                NotificationCenter.default.post(name: .browserRealClick, object: nil, userInfo: userInfo)
            } else {
                Self.writeResponse(["error": "realclick requires a base64-encoded selector"], to: responseFilePath)
            }
        case "screenshot":
            var userInfo: [String: Any] = [:]
            if let responseFilePath = responseFilePath { userInfo["responseFilePath"] = responseFilePath }
            NotificationCenter.default.post(name: .browserScreenshot, object: nil, userInfo: userInfo)
        case "notify":
            NotificationCenter.default.post(name: .browserNotifyUser, object: nil,
                                            userInfo: ["message": parameter ?? "The browser needs your attention."])
            Self.writeResponse(["ok": true], to: responseFilePath)
        case "focus":
            NotificationCenter.default.post(name: .browserFocusWindow, object: nil)
            Self.writeResponse(["ok": true], to: responseFilePath)
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
            Self.writeResponse(["error": "unknown command: \(action ?? "")"], to: responseFilePath)
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

    // Ad blocker toggled in Settings
    static let adBlockChanged = Notification.Name("adBlockChanged")
    // System memory pressure (userInfo["critical"]: Bool)
    static let memoryPressure = Notification.Name("memoryPressure")
    // Cmd+Shift+H shortcut cheat-sheet overlay
    static let browserToggleShortcutOverlay = Notification.Name("browserToggleShortcutOverlay")
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

    // CLI agent commands (userInfo carries responseFilePath where the
    // observer writes the JSON result)
    static let browserNavigate = Notification.Name("browserNavigate") // userInfo["action"]: back|forward|reload
    static let browserSwitchTab = Notification.Name("browserSwitchTab") // userInfo["index"]: 1-based
    static let browserRunJS = Notification.Name("browserRunJS") // userInfo["script"]
    static let browserWaitForLoad = Notification.Name("browserWaitForLoad") // userInfo["timeout"]
    static let browserScreenshot = Notification.Name("browserScreenshot")
    static let browserRealClick = Notification.Name("browserRealClick") // userInfo["selector"]
    static let browserNotifyUser = Notification.Name("browserNotifyUser") // userInfo["message"]
    static let browserFocusWindow = Notification.Name("browserFocusWindow")
}
