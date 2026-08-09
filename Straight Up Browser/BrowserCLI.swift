//
//  BrowserCLI.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import Foundation

// MARK: - Structured agent automation

/// Routes structured agent requests to the browser window that owns the target
/// page.  The original CLI predates multi-window automation and broadcasts
/// NotificationCenter messages, which means two open browser windows can both
/// react to one command.  MCP uses this registry instead: page IDs include the
/// owning window ID, so parallel clients never have to steal the user's focus
/// just to address a background page.
final class BrowserAutomationRegistry {
    static let shared = BrowserAutomationRegistry()

    private final class WeakManager {
        weak var value: NotificationManager?
        init(_ value: NotificationManager) { self.value = value }
    }

    private var managers: [UUID: WeakManager] = [:]

    private init() {}

    func register(_ manager: NotificationManager) {
        managers[manager.automationWindowId] = WeakManager(manager)
    }

    func unregister(_ manager: NotificationManager) {
        managers.removeValue(forKey: manager.automationWindowId)
    }

    private func liveManagers() -> [NotificationManager] {
        managers = managers.filter { $0.value.value != nil }
        return managers.values.compactMap(\.value)
    }

    var hasLiveManagers: Bool { !liveManagers().isEmpty }

    private func manager(windowId: String?, pageId: String?) -> NotificationManager? {
        let live = liveManagers()
        if let windowId, let id = UUID(uuidString: windowId), let manager = managers[id]?.value {
            return manager
        }
        if let pageId,
           let prefix = pageId.split(separator: ":", maxSplits: 1).first,
           let id = UUID(uuidString: String(prefix)),
           let manager = managers[id]?.value {
            return manager
        }
        return live.first(where: \.isAutomationKeyWindow) ?? live.first
    }

    func execute(_ request: [String: Any], responseFilePath: String?) {
        guard let tool = request["tool"] as? String else {
            BrowserCLI.writeResponse(["error": "agent request is missing tool"], to: responseFilePath)
            return
        }
        let arguments = request["arguments"] as? [String: Any] ?? [:]
        let live = liveManagers()

        switch tool {
        case "list_pages":
            let pages = live.flatMap { $0.automationPageSummaries() }
            BrowserCLI.writeResponse(["ok": true, "pages": pages], to: responseFilePath)
        case "list_windows":
            let windows = live.map { $0.automationWindowSummary() }
            BrowserCLI.writeResponse(["ok": true, "windows": windows], to: responseFilePath)
        case "get_active_page":
            guard let manager = manager(
                windowId: arguments["windowId"] as? String,
                pageId: arguments["pageId"] as? String
            ), let page = manager.automationActivePageSummary() else {
                BrowserCLI.writeResponse(["error": "no active browser page"], to: responseFilePath)
                return
            }
            BrowserCLI.writeResponse(["ok": true, "page": page], to: responseFilePath)
        case "create_window", "create_hidden_window":
            guard let source = manager(windowId: nil, pageId: nil) else {
                BrowserCLI.writeResponse(["error": "no browser window is ready"], to: responseFilePath)
                return
            }
            let existing = Set(live.map(\.automationWindowId))
            source.requestAutomationWindow()
            waitForNewWindow(
                excluding: existing,
                hidden: tool == "create_hidden_window",
                url: arguments["url"] as? String,
                responseFilePath: responseFilePath
            )
        default:
            guard let manager = manager(
                windowId: arguments["windowId"] as? String,
                pageId: arguments["pageId"] as? String
            ) else {
                BrowserCLI.writeResponse(["error": "no browser window is ready"], to: responseFilePath)
                return
            }
            manager.performAutomationTool(tool, arguments: arguments, responseFilePath: responseFilePath)
        }
    }

    private func waitForNewWindow(
        excluding existing: Set<UUID>,
        hidden: Bool,
        url: String?,
        responseFilePath: String?,
        attemptsRemaining: Int = 40
    ) {
        if let created = liveManagers().first(where: { !existing.contains($0.automationWindowId) }) {
            if hidden { created.setAutomationWindowHidden(true) }
            if let url {
                created.performAutomationTool(
                    hidden ? "new_hidden_page" : "new_page",
                    arguments: ["url": url],
                    responseFilePath: responseFilePath
                )
            } else {
                BrowserCLI.writeResponse(
                    ["ok": true, "window": created.automationWindowSummary()],
                    to: responseFilePath
                )
            }
            return
        }
        guard attemptsRemaining > 0 else {
            BrowserCLI.writeResponse(["error": "timed out creating browser window"], to: responseFilePath)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForNewWindow(
                excluding: existing,
                hidden: hidden,
                url: url,
                responseFilePath: responseFilePath,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }
}

// File-based CLI IPC. The browser owns a named pipe (FIFO) in its own
// Application Support directory with owner-only permissions. Those permissions
// limit callers to the signed-in user; explicit in-app settings authorize what
// their processes may ask the browser to do. The CLI tool writes one command
// per line; data commands pass --response-file <path>, which must live inside
// our response directory, and the app writes the JSON result there.
enum CLICapability: Equatable {
    case control
    case pageRead
    case pageScript
    case screenshot
}

struct CLIAuthorization {
    enum Key {
        static let enabled = "cliAutomationEnabled"
        static let pageRead = "cliPageReadEnabled"
        static let pageScript = "cliPageScriptEnabled"
        static let screenshot = "cliScreenshotEnabled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func capability(for action: String) -> CLICapability {
        switch action {
        case "tabs", "get":
            return .pageRead
        case "js", "realclick":
            return .pageScript
        case "screenshot":
            return .screenshot
        default:
            return .control
        }
    }

    static func capability(forAgentTool tool: String) -> CLICapability {
        switch tool {
        case "take_screenshot", "save_pdf":
            return .screenshot
        case "evaluate_script", "handle_dialog", "click", "click_at", "hover", "focus",
             "fill", "clear", "check", "uncheck", "select_option", "press_key", "drag",
             "scroll", "upload_file", "download_file":
            return .pageScript
        case "get_active_page", "list_pages", "list_windows", "get_bookmarks",
             "search_bookmarks", "search_history", "get_recent_history", "list_tab_groups",
             "take_snapshot", "take_enhanced_snapshot", "get_page_content", "get_page_links",
             "get_dom", "search_dom", "wait_for_page":
            return .pageRead
        default:
            return .control
        }
    }

    func allows(action: String) -> Bool {
        guard defaults.bool(forKey: Key.enabled) else { return false }

        switch Self.capability(for: action) {
        case .control:
            return true
        case .pageRead:
            return defaults.bool(forKey: Key.pageRead)
        case .pageScript:
            return defaults.bool(forKey: Key.pageScript)
        case .screenshot:
            return defaults.bool(forKey: Key.screenshot)
        }
    }

    func allows(capability: CLICapability) -> Bool {
        guard defaults.bool(forKey: Key.enabled) else { return false }
        switch capability {
        case .control: return true
        case .pageRead: return defaults.bool(forKey: Key.pageRead)
        case .pageScript: return defaults.bool(forKey: Key.pageScript)
        case .screenshot: return defaults.bool(forKey: Key.screenshot)
        }
    }

    func denialMessage(for action: String) -> String {
        guard defaults.bool(forKey: Key.enabled) else {
            return "CLI automation is disabled. Enable it in Settings > Security > CLI Automation."
        }

        switch Self.capability(for: action) {
        case .control:
            return "CLI automation is disabled."
        case .pageRead:
            return "CLI page reading is disabled. Enable it in Settings > Security > CLI Automation."
        case .pageScript:
            return "CLI JavaScript and synthetic interaction are disabled. Enable them in Settings > Security > CLI Automation."
        case .screenshot:
            return "CLI screenshots are disabled. Enable them in Settings > Security > CLI Automation."
        }
    }

    func denialMessage(for capability: CLICapability) -> String {
        guard defaults.bool(forKey: Key.enabled) else {
            return "Agent automation is disabled. Enable it in Settings > Security > Agent Automation."
        }
        switch capability {
        case .control: return "Agent browser control is disabled."
        case .pageRead: return "Agent page reading is disabled in Settings > Security > Agent Automation."
        case .pageScript: return "Agent JavaScript and synthetic interaction are disabled in Settings > Security > Agent Automation."
        case .screenshot: return "Agent screenshots are disabled in Settings > Security > Agent Automation."
        }
    }
}

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

        DispatchQueue.global(qos: .background).async {
            BrowserCLI.listenForCommands(at: pipePath) { command in
                Task { @MainActor in
                    BrowserCLI.shared.handleCommand(command)
                }
            }
        }
    }

    nonisolated private static func listenForCommands(
        at pipePath: String,
        onCommand: @escaping @Sendable (String) -> Void
    ) {
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
                    onCommand(command)
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

        var newTab = false
        if let newFlagIndex = commandParts.firstIndex(of: "--new") {
            commandParts.remove(at: newFlagIndex)
            newTab = true
        }

        // screenshot-only flags, reusing the same generic strip-before-dispatch
        // approach as --new above.
        var fullPage = false
        if let index = commandParts.firstIndex(of: "--full-page") {
            commandParts.remove(at: index)
            fullPage = true
        }
        var toClipboard = false
        if let index = commandParts.firstIndex(of: "--clipboard") {
            commandParts.remove(at: index)
            toClipboard = true
        }
        var toShared = false
        if let index = commandParts.firstIndex(of: "--shared") {
            commandParts.remove(at: index)
            toShared = true
        }

        guard let action = commandParts.first?.lowercased() else {
            Self.writeResponse(["error": "missing command"], to: responseFilePath)
            return
        }
        let parameter = commandParts.count > 1 ? commandParts[1..<commandParts.count].joined(separator: " ") : nil

        let agentRequest: [String: Any]? = {
            guard action == "agent", let parameter,
                  let data = Data(base64Encoded: parameter),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let request = object as? [String: Any] else { return nil }
            return request
        }()

        let authorization = CLIAuthorization()
        let allowed: Bool
        if action == "agent", let tool = agentRequest?["tool"] as? String {
            allowed = authorization.allows(capability: CLIAuthorization.capability(forAgentTool: tool))
        } else {
            allowed = authorization.allows(action: action)
        }
        guard allowed else {
            let agentCapability = (agentRequest?["tool"] as? String)
                .map(CLIAuthorization.capability(forAgentTool:)) ?? .control
            let message = action == "agent"
                ? authorization.denialMessage(for: agentCapability)
                : authorization.denialMessage(for: action)
            Self.writeResponse(["error": message], to: responseFilePath)
            return
        }

        // Same cold-launch race App Intents guard against: observers attach in
        // ContentView.onAppear. We're on the dedicated pipe thread and commands
        // are serial, so a bounded blocking wait is fine. Authorization is
        // checked first so denied commands never wait for or touch browser state.
        if !NotificationManager.observersReady {
            for _ in 0..<100 where !NotificationManager.observersReady {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if !NotificationManager.observersReady {
                Self.writeResponse(["error": "Browser window not ready (first-run EULA screen?)"], to: responseFilePath)
                return
            }
        }

        // Acks mean "accepted for execution on the main queue" - agents follow
        // navigation with `wait`. Commands that can fail respond from their
        // observer instead.
        switch action {
        case "agent":
            guard let agentRequest else {
                Self.writeResponse(["error": "agent requires a base64-encoded JSON request"], to: responseFilePath)
                return
            }
            BrowserAutomationRegistry.shared.execute(agentRequest, responseFilePath: responseFilePath)
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
            NotificationCenter.default.post(name: .browserNavigate, object: nil, userInfo: ["action": action])
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
            if fullPage { userInfo["fullPage"] = true }
            if toClipboard { userInfo["clipboard"] = true }
            if toShared { userInfo["shared"] = true }
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
            Self.writeResponse(["error": "unknown command: \(action)"], to: responseFilePath)
        }
    }
}
