import Foundation
import Combine
import Security
import SwiftUI
import AppKit

enum BrowserAgentProvider: String, CaseIterable, Identifiable, Sendable {
    case openAI = "OpenAI"
    case openRouter = "OpenRouter"
    case ollama = "Ollama"
    case lmStudio = "LM Studio"
    case compatible = "OpenAI-compatible"

    var id: String { rawValue }

    var defaultEndpoint: String {
        switch self {
        case .openAI: "https://api.openai.com/v1/chat/completions"
        case .openRouter: "https://openrouter.ai/api/v1/chat/completions"
        case .ollama: "http://127.0.0.1:11434/v1/chat/completions"
        case .lmStudio: "http://127.0.0.1:1234/v1/chat/completions"
        case .compatible: ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: "gpt-5-mini"
        case .openRouter: "openai/gpt-5-mini"
        case .ollama: "qwen3:8b"
        case .lmStudio: "local-model"
        case .compatible: ""
        }
    }

    var needsAPIKey: Bool {
        self != .ollama && self != .lmStudio
    }
}

struct BrowserAgentConfiguration: Sendable {
    let provider: BrowserAgentProvider
    let endpoint: String
    let model: String
    let apiKey: String
}

struct BrowserAgentMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant, tool, error }

    let id: UUID
    let role: Role
    let text: String
    let toolName: String?
    let createdAt: Date

    init(role: Role, text: String, toolName: String? = nil) {
        id = UUID()
        self.role = role
        self.text = text
        self.toolName = toolName
        createdAt = Date()
    }
}

enum BrowserAgentKeychain {
    private static let service = "com.nathanfennel.Straight-Up-Browser.agent"

    static func read(provider: BrowserAgentProvider) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func write(_ value: String, provider: BrowserAgentProvider) {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        if value.isEmpty {
            SecItemDelete(identity as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(
            identity as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

// MARK: - External MCP app integrations

struct BrowserAgentMCPConnection: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var endpoint: String
    var enabled: Bool

    init(name: String, endpoint: String) {
        id = UUID()
        self.name = name
        self.endpoint = endpoint
        enabled = true
    }
}

private enum BrowserAgentMCPKeychain {
    private static let service = "com.nathanfennel.Straight-Up-Browser.agent-mcp"

    static func read(_ id: UUID) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func write(_ value: String, id: UUID) {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        if value.isEmpty {
            SecItemDelete(identity as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        if SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

private struct BrowserAgentMCPRoute {
    let connection: BrowserAgentMCPConnection
    let toolName: String
}

private struct BrowserAgentExternalTools {
    var definitions: [[String: Any]] = []
    var routes: [String: BrowserAgentMCPRoute] = [:]
}

@MainActor
final class BrowserAgentMCPStore: ObservableObject {
    static let shared = BrowserAgentMCPStore()

    @Published private(set) var connections: [BrowserAgentMCPConnection] = []
    @Published private(set) var status: [UUID: String] = [:]

    private var sessionIds: [UUID: String] = [:]
    private var requestId = 0
    private let storeURL: URL

    private init() {
        storeURL = BrowserCLI.supportDirectory.appendingPathComponent("agent-mcp-connections.json")
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode([BrowserAgentMCPConnection].self, from: data) {
            connections = decoded
        }
    }

    func add(name: String, endpoint: String, bearerToken: String) throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty,
              let url = URL(string: cleanEndpoint),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw MCPError.message("Enter a name and an HTTP(S) MCP endpoint.")
        }
        let connection = BrowserAgentMCPConnection(name: cleanName, endpoint: cleanEndpoint)
        connections.append(connection)
        BrowserAgentMCPKeychain.write(bearerToken, id: connection.id)
        save()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].enabled = enabled
        if !enabled { sessionIds.removeValue(forKey: id) }
        save()
    }

    func remove(_ id: UUID) {
        connections.removeAll { $0.id == id }
        BrowserAgentMCPKeychain.write("", id: id)
        sessionIds.removeValue(forKey: id)
        status.removeValue(forKey: id)
        save()
    }

    func test(_ connection: BrowserAgentMCPConnection) async {
        status[connection.id] = "Connecting…"
        do {
            let tools = try await listTools(connection)
            status[connection.id] = "Connected · \(tools.count) tools"
        } catch {
            sessionIds.removeValue(forKey: connection.id)
            status[connection.id] = "Failed · \(error.localizedDescription)"
        }
    }

    fileprivate func prepareTools() async -> BrowserAgentExternalTools {
        var bundle = BrowserAgentExternalTools()
        for connection in connections where connection.enabled {
            do {
                let tools = try await listTools(connection)
                status[connection.id] = "Connected · \(tools.count) tools"
                for tool in tools {
                    guard let originalName = tool["name"] as? String else { continue }
                    let exposedName = modelToolName(connection: connection, tool: originalName)
                    let description = tool["description"] as? String ?? "External app action."
                    let schema = tool["inputSchema"] as? [String: Any]
                        ?? ["type": "object", "properties": [:], "additionalProperties": true]
                    bundle.definitions.append([
                        "type": "function",
                        "function": [
                            "name": exposedName,
                            "description": "\(connection.name): \(description)",
                            "parameters": schema,
                        ],
                    ])
                    bundle.routes[exposedName] = BrowserAgentMCPRoute(
                        connection: connection,
                        toolName: originalName
                    )
                }
            } catch {
                status[connection.id] = "Unavailable · \(error.localizedDescription)"
                sessionIds.removeValue(forKey: connection.id)
            }
        }
        return bundle
    }

    fileprivate func call(_ route: BrowserAgentMCPRoute, arguments: [String: Any]) async -> String {
        do {
            try await initialize(route.connection)
            let response = try await rpc(
                route.connection,
                method: "tools/call",
                params: ["name": route.toolName, "arguments": arguments]
            )
            if let error = response["error"] {
                return "{\"error\":\(jsonString(error))}"
            }
            return jsonString(response["result"] ?? [:])
        } catch {
            sessionIds.removeValue(forKey: route.connection.id)
            return jsonString(["error": error.localizedDescription])
        }
    }

    private func listTools(_ connection: BrowserAgentMCPConnection) async throws -> [[String: Any]] {
        try await initialize(connection)
        let response = try await rpc(connection, method: "tools/list", params: [:])
        if let error = response["error"] { throw MCPError.message(jsonString(error)) }
        let result = response["result"] as? [String: Any]
        return result?["tools"] as? [[String: Any]] ?? []
    }

    private func initialize(_ connection: BrowserAgentMCPConnection) async throws {
        guard sessionIds[connection.id] == nil else { return }
        let response = try await rpc(
            connection,
            method: "initialize",
            params: [
                "protocolVersion": "2025-06-18",
                "capabilities": [:],
                "clientInfo": ["name": "Straight Up Browser", "version": "1.0.0"],
            ],
            initializing: true
        )
        if let error = response["error"] { throw MCPError.message(jsonString(error)) }
        _ = try? await rpc(connection, method: "notifications/initialized", params: [:], notification: true)
    }

    private func rpc(
        _ connection: BrowserAgentMCPConnection,
        method: String,
        params: [String: Any],
        initializing: Bool = false,
        notification: Bool = false
    ) async throws -> [String: Any] {
        guard let endpoint = URL(string: connection.endpoint) else { throw MCPError.message("Invalid endpoint URL.") }
        requestId += 1
        var payload: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if !notification { payload["id"] = requestId }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let session = sessionIds[connection.id] {
            request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
        }
        let token = BrowserAgentMCPKeychain.read(connection.id)
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.message("No HTTP response.") }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.message("HTTP \(http.statusCode): \(String(data: data, encoding: .utf8)?.prefix(600) ?? "")")
        }
        if initializing, let session = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !session.isEmpty {
            sessionIds[connection.id] = session
        }
        if notification || data.isEmpty { return [:] }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.split(separator: "\n").reversed() {
            guard line.hasPrefix("data:") else { continue }
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if let bytes = json.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                return object
            }
        }
        throw MCPError.message("The MCP server returned an unsupported response.")
    }

    private func modelToolName(connection: BrowserAgentMCPConnection, tool: String) -> String {
        let prefix = "app_\(connection.id.uuidString.prefix(6).lowercased())_"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let clean = tool.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        return String((prefix + clean).prefix(64))
    }

    private func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return String(describing: value)
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: BrowserCLI.supportDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try JSONEncoder().encode(connections).write(to: storeURL, options: [.atomic, .completeFileProtection])
        } catch {
            Logger.log("Could not save MCP app connections: \(error)", type: "BrowserAgent")
        }
    }

    private enum MCPError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let message) = self { message } else { nil } }
    }
}

@MainActor
final class BrowserAgentWorkspace: ObservableObject {
    static let shared = BrowserAgentWorkspace()

    @Published private(set) var rootURL: URL?
    private let bookmarkKey = "browserAgentWorkspaceBookmark"

    private init() { restore() }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Agent Cowork Folder"
        panel.message = "The agent can only read and change files inside the folder you choose."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setRoot(url)
    }

    func clear() {
        rootURL?.stopAccessingSecurityScopedResource()
        rootURL = nil
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    fileprivate func call(_ tool: String, arguments: [String: Any]) -> String {
        do {
            switch tool {
            case "workspace_info":
                return json(["ok": true, "available": rootURL != nil, "folder": rootURL?.path ?? ""])
            case "list_files":
                let path = arguments["path"] as? String ?? ""
                let recursive = arguments["recursive"] as? Bool ?? false
                let directory = try resolve(path, mustExist: true)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw WorkspaceError.message("Not a directory: \(path)")
                }
                let urls: [URL]
                if recursive {
                    let enumerator = FileManager.default.enumerator(
                        at: directory,
                        includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                    )
                    urls = (enumerator?.allObjects as? [URL] ?? []).prefix(500).map { $0 }
                } else {
                    urls = try FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                        options: [.skipsHiddenFiles]
                    )
                }
                let root = try root()
                let files = urls.map { url -> [String: Any] in
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                    let modified: Any = values?.contentModificationDate
                        .map { ISO8601DateFormatter().string(from: $0) } ?? ""
                    return [
                        "path": String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                        "directory": values?.isDirectory ?? false,
                        "bytes": values?.fileSize ?? 0,
                        "modified": modified,
                    ]
                }
                return json(["ok": true, "files": files, "truncated": files.count >= 500])
            case "read_file":
                let url = try resolve(requiredPath(arguments), mustExist: true)
                let data = try Data(contentsOf: url)
                guard data.count <= 2_000_000 else { throw WorkspaceError.message("File exceeds the 2 MB agent read limit.") }
                guard let text = String(data: data, encoding: .utf8) else { throw WorkspaceError.message("Only UTF-8 text files can be read.") }
                return json(["ok": true, "path": relative(url), "content": text])
            case "write_file":
                let url = try resolve(requiredPath(arguments), mustExist: false)
                let content = arguments["content"] as? String ?? ""
                let append = arguments["append"] as? Bool ?? false
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if append, FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(content.utf8))
                    try handle.close()
                } else {
                    try Data(content.utf8).write(to: url, options: .atomic)
                }
                return json(["ok": true, "path": relative(url), "bytes": content.utf8.count])
            case "move_file":
                let source = try resolve(requiredPath(arguments), mustExist: true)
                guard let destinationPath = arguments["destination"] as? String, !destinationPath.isEmpty else {
                    throw WorkspaceError.message("move_file requires destination.")
                }
                let destination = try resolve(destinationPath, mustExist: false)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: source, to: destination)
                return json(["ok": true, "from": relative(source), "to": relative(destination)])
            case "delete_file":
                let url = try resolve(requiredPath(arguments), mustExist: true)
                var trashed: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                return json(["ok": true, "path": relative(url), "recoverable": true])
            default:
                throw WorkspaceError.message("Unknown cowork file tool: \(tool)")
            }
        } catch {
            return json(["error": error.localizedDescription])
        }
    }

    private func setRoot(_ url: URL) {
        rootURL?.stopAccessingSecurityScopedResource()
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            rootURL = url
            _ = rootURL?.startAccessingSecurityScopedResource()
        } catch {
            Logger.log("Could not save cowork folder access: \(error)", type: "BrowserAgent")
        }
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return }
        rootURL = url
        _ = url.startAccessingSecurityScopedResource()
        if stale { setRoot(url) }
    }

    private func root() throws -> URL {
        guard let rootURL else { throw WorkspaceError.message("Choose a cowork folder in the Agent model settings first.") }
        return rootURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func resolve(_ path: String, mustExist: Bool) throws -> URL {
        let root = try root()
        guard !path.hasPrefix("/") else { throw WorkspaceError.message("Use a path relative to the cowork folder.") }
        let candidate = root.appendingPathComponent(path).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            throw WorkspaceError.message("Path escapes the cowork folder.")
        }
        let containmentTarget = mustExist ? candidate : candidate.deletingLastPathComponent()
        let resolved = containmentTarget.resolvingSymlinksInPath()
        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
            throw WorkspaceError.message("Symbolic link escapes the cowork folder.")
        }
        if mustExist, !FileManager.default.fileExists(atPath: candidate.path) {
            throw WorkspaceError.message("File does not exist: \(path)")
        }
        return candidate
    }

    private func requiredPath(_ arguments: [String: Any]) throws -> String {
        guard let path = arguments["path"] as? String, !path.isEmpty else {
            throw WorkspaceError.message("A relative path is required.")
        }
        return path
    }

    private func relative(_ url: URL) -> String {
        guard let rootURL else { return url.lastPathComponent }
        return String(url.path.dropFirst(rootURL.standardizedFileURL.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private enum WorkspaceError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let message) = self { message } else { nil } }
    }
}

@MainActor
final class BrowserAgent: ObservableObject {
    @Published private(set) var messages: [BrowserAgentMessage] = []
    @Published private(set) var isRunning = false
    @Published private(set) var currentTool: String?

    private var runTask: Task<Void, Never>?
    private let conversationId = UUID()
    private let storageDirectory: URL

    init(storageDirectory: URL = BrowserCLI.supportDirectory) {
        self.storageDirectory = storageDirectory
    }

    deinit { runTask?.cancel() }

    func clear() {
        guard !isRunning else { return }
        messages = []
        persist()
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        currentTool = nil
        isRunning = false
    }

    func submit(
        _ prompt: String,
        pageTitle: String,
        pageURL: String,
        configuration: BrowserAgentConfiguration,
        execute: @escaping (_ tool: String, _ arguments: [String: Any]) async -> String
    ) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        messages.append(BrowserAgentMessage(role: .user, text: trimmed))
        persist()
        isRunning = true

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runLoop(
                    prompt: trimmed,
                    pageTitle: pageTitle,
                    pageURL: pageURL,
                    configuration: configuration,
                    execute: execute
                )
            } catch is CancellationError {
                self.messages.append(BrowserAgentMessage(role: .error, text: "Stopped."))
            } catch {
                self.messages.append(BrowserAgentMessage(role: .error, text: error.localizedDescription))
            }
            self.isRunning = false
            self.currentTool = nil
            self.runTask = nil
            self.persist()
        }
    }

    private func runLoop(
        prompt: String,
        pageTitle: String,
        pageURL: String,
        configuration: BrowserAgentConfiguration,
        execute: @escaping (_ tool: String, _ arguments: [String: Any]) async -> String
    ) async throws {
        guard let endpoint = URL(string: configuration.endpoint), !configuration.model.isEmpty else {
            throw AgentError.configuration("Choose a model and valid endpoint in the agent panel.")
        }
        if configuration.provider.needsAPIKey && configuration.apiKey.isEmpty {
            throw AgentError.configuration("Add an API key for \(configuration.provider.rawValue).")
        }

        var transcript: [[String: Any]] = [
            [
                "role": "system",
                "content": """
                You are the agent built into Straight Up Browser, a real WebKit browser. Use tools to observe before acting. Start with take_snapshot for page work. Stable page IDs let you use background pages without taking over the user's focused page. Cowork file tools are confined to a folder the user explicitly chose. Never send, publish, purchase, delete, or submit consequential data unless the user's request clearly authorizes it. Ask for human help on captcha, login, 2FA, or ambiguous consequential choices. The currently focused page is titled \(pageTitle) at \(pageURL).
                """,
            ],
            ["role": "user", "content": prompt],
        ]
        let externalTools = await BrowserAgentMCPStore.shared.prepareTools()
        let availableTools = Self.toolDefinitions + Self.workspaceToolDefinitions + externalTools.definitions

        for _ in 0..<30 {
            try Task.checkCancellation()
            let response = try await completion(
                endpoint: endpoint,
                configuration: configuration,
                transcript: transcript,
                tools: availableTools
            )
            guard let choices = response["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else {
                let detail = response["error"].map { String(describing: $0) } ?? "No assistant message"
                throw AgentError.service(detail)
            }
            transcript.append(message)

            let content = message["content"] as? String ?? ""
            let calls = message["tool_calls"] as? [[String: Any]] ?? []
            if calls.isEmpty {
                messages.append(BrowserAgentMessage(
                    role: .assistant,
                    text: content.isEmpty ? "Done." : content
                ))
                return
            }
            if !content.isEmpty {
                messages.append(BrowserAgentMessage(role: .assistant, text: content))
            }

            for call in calls {
                try Task.checkCancellation()
                guard let callId = call["id"] as? String,
                      let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                let raw = function["arguments"] as? String ?? "{}"
                let arguments = raw.data(using: .utf8)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                currentTool = name
                messages.append(BrowserAgentMessage(role: .tool, text: compactArguments(arguments), toolName: name))
                let result: String
                if let route = externalTools.routes[name] {
                    result = await BrowserAgentMCPStore.shared.call(route, arguments: arguments)
                } else if Self.workspaceToolNames.contains(name) {
                    result = BrowserAgentWorkspace.shared.call(name, arguments: arguments)
                } else {
                    result = await execute(name, arguments)
                }
                transcript.append([
                    "role": "tool",
                    "tool_call_id": callId,
                    "content": String(result.prefix(120_000)),
                ])
            }
        }
        throw AgentError.service("The agent reached its 30-step safety limit.")
    }

    private func completion(
        endpoint: URL,
        configuration: BrowserAgentConfiguration,
        transcript: [[String: Any]],
        tools: [[String: Any]]
    ) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        if configuration.provider == .openRouter {
            request.setValue("Straight Up Browser", forHTTPHeaderField: "X-Title")
            request.setValue("https://github.com/", forHTTPHeaderField: "HTTP-Referer")
        }
        let body: [String: Any] = [
            "model": configuration.model,
            "messages": transcript,
            "tools": tools,
            "tool_choice": "auto",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentError.service("The model endpoint returned no HTTP response.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError.service("The model endpoint returned invalid JSON (HTTP \(http.statusCode)).")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw AgentError.service("Model request failed (HTTP \(http.statusCode)): \(String(detail.prefix(1000)))")
        }
        return object
    }

    private static var toolDefinitions: [[String: Any]] {
        func schema(_ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            var value: [String: Any] = ["type": "object", "properties": properties]
            if !required.isEmpty { value["required"] = required }
            return value
        }
        func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
        func boolean(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }
        func integer(_ description: String) -> [String: Any] { ["type": "integer", "description": description] }
        func strings(_ description: String) -> [String: Any] { ["type": "array", "items": ["type": "string"], "description": description] }
        func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], _ required: [String] = []) -> [String: Any] {
            ["type": "function", "function": ["name": name, "description": description, "parameters": schema(properties, required: required)]]
        }
        let page = string("Stable page ID from list_pages; omit for the focused page.")
        let element = string("Snapshot element ID, such as sub-4.")
        let selector = string("CSS selector; use elementId when possible.")
        return [
            tool("get_active_page", "Get the focused page."),
            tool("list_pages", "List open pages and stable IDs."),
            tool("navigate_page", "Navigate by URL or back/forward/reload.", ["pageId": page, "url": string("Absolute URL."), "action": string("back, forward, reload, or stop.")]),
            tool("new_page", "Open a page, optionally in the background.", ["url": string("Absolute URL."), "background": boolean("Keep focus unchanged."), "incognito": boolean("Use an ephemeral private session.")]),
            tool("new_hidden_page", "Open a background automation page.", ["url": string("Absolute URL.")]),
            tool("show_page", "Reveal and focus a page.", ["pageId": page], ["pageId"]),
            tool("close_page", "Close a page.", ["pageId": page], ["pageId"]),
            tool("wait_for_page", "Wait for a page to finish loading.", ["pageId": page, "timeout": integer("Timeout in seconds, up to 60.")]),
            tool("take_snapshot", "Get page text and interactive element IDs.", ["pageId": page]),
            tool("take_enhanced_snapshot", "Get a detailed semantic page snapshot.", ["pageId": page]),
            tool("get_page_content", "Extract readable page content.", ["pageId": page]),
            tool("get_page_links", "Extract page links.", ["pageId": page]),
            tool("get_dom", "Get raw page HTML.", ["pageId": page, "selector": selector]),
            tool("search_dom", "Search DOM text, CSS, or XPath.", ["pageId": page, "query": string("Query."), "mode": string("text, css, or xpath."), "limit": integer("Maximum results.")], ["query"]),
            tool("evaluate_script", "Run JavaScript against the page DOM.", ["pageId": page, "script": string("JavaScript source.")], ["script"]),
            tool("click", "Click by snapshot element ID or CSS selector.", ["pageId": page, "elementId": element, "selector": selector]),
            tool("fill", "Fill a text control.", ["pageId": page, "elementId": element, "selector": selector, "value": string("Text to enter.")], ["value"]),
            tool("press_key", "Press a key or modifier combination.", ["pageId": page, "key": string("Key, such as Enter or Meta+A.")], ["key"]),
            tool("scroll", "Scroll a page or element.", ["pageId": page, "elementId": element, "selector": selector, "direction": string("up, down, left, or right."), "amount": integer("Pixels.")]),
            tool("handle_dialog", "Accept or dismiss a JavaScript dialog.", ["pageId": page, "accept": boolean("Accept if true."), "promptText": string("Prompt response.")]),
            tool("list_tab_groups", "List tab groups."),
            tool("group_tabs", "Group pages.", ["pageIds": strings("Stable page IDs."), "title": string("Group title."), "color": string("Hex color.")], ["pageIds"]),
            tool("ungroup_tabs", "Remove pages from groups.", ["pageIds": strings("Stable page IDs.")], ["pageIds"]),
            tool("get_bookmarks", "List bookmarks and folders."),
            tool("search_bookmarks", "Search bookmarks.", ["query": string("Search query.")], ["query"]),
            tool("create_bookmark", "Create a bookmark or folder.", ["title": string("Title."), "url": string("Optional URL."), "folder": string("Folder.")], ["title"]),
            tool("search_history", "Search local browsing history.", ["query": string("Search query."), "limit": integer("Maximum results.")], ["query"]),
            tool("get_recent_history", "Get recent browsing history.", ["limit": integer("Maximum results.")]),
        ]
    }

    private static let workspaceToolNames = Set([
        "workspace_info", "list_files", "read_file", "write_file", "move_file", "delete_file",
    ])

    private static var workspaceToolDefinitions: [[String: Any]] {
        func definition(_ name: String, _ description: String, properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
            if !required.isEmpty { schema["required"] = required }
            return ["type": "function", "function": ["name": name, "description": description, "parameters": schema]]
        }
        let path: [String: Any] = ["type": "string", "description": "Path relative to the user-approved cowork folder."]
        return [
            definition("workspace_info", "Show whether a cowork folder is available."),
            definition("list_files", "List files inside the cowork folder.", properties: [
                "path": path,
                "recursive": ["type": "boolean", "description": "Include descendants, capped at 500 entries."],
            ]),
            definition("read_file", "Read a UTF-8 text file from the cowork folder.", properties: ["path": path], required: ["path"]),
            definition("write_file", "Create or update a UTF-8 text file in the cowork folder.", properties: [
                "path": path,
                "content": ["type": "string", "description": "Text to write."],
                "append": ["type": "boolean", "description": "Append instead of replacing."],
            ], required: ["path", "content"]),
            definition("move_file", "Move or rename a file within the cowork folder.", properties: [
                "path": path,
                "destination": path,
            ], required: ["path", "destination"]),
            definition("delete_file", "Move a file to the macOS Trash so it remains recoverable.", properties: ["path": path], required: ["path"]),
        ]
    }

    static var builtInToolNames: [String] {
        (toolDefinitions + workspaceToolDefinitions).compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }
    }

    private func compactArguments(_ arguments: [String: Any]) -> String {
        guard !arguments.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return String(text.prefix(500))
    }

    private func persist() {
        let directory = storageDirectory.appendingPathComponent("agent-conversations", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(messages)
            try data.write(to: directory.appendingPathComponent("\(conversationId).json"), options: .atomic)
        } catch {
            Logger.log("Could not save agent conversation: \(error)", type: "BrowserAgent")
        }
    }

    private enum AgentError: LocalizedError {
        case configuration(String)
        case service(String)
        var errorDescription: String? {
            switch self {
            case .configuration(let message), .service(let message): message
            }
        }
    }
}

struct BrowserAgentPanel: View {
    @ObservedObject var agent: BrowserAgent
    let pageTitle: String
    let pageURL: String
    let onClose: () -> Void
    let execute: (_ tool: String, _ arguments: [String: Any]) async -> String

    @AppStorage("browserAgentProvider") private var providerRaw = BrowserAgentProvider.openRouter.rawValue
    @AppStorage("browserAgentEndpoint") private var customEndpoint = ""
    @AppStorage("browserAgentModel") private var savedModel = ""
    @State private var apiKey = ""
    @State private var prompt = ""
    @State private var showingConfiguration = false
    @ObservedObject private var workspace = BrowserAgentWorkspace.shared
    @Environment(\.openWindow) private var openWindow

    private var provider: BrowserAgentProvider {
        BrowserAgentProvider(rawValue: providerRaw) ?? .openRouter
    }

    private var endpoint: String {
        provider == .compatible ? customEndpoint : provider.defaultEndpoint
    }

    private var model: String {
        savedModel.isEmpty ? provider.defaultModel : savedModel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("Agent").font(.headline)
                if let tool = agent.currentTool {
                    Text(tool).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { showingConfiguration.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.plain)
                    .help("Model settings")
                Button { openWindow(id: "agent-tasks") } label: { Image(systemName: "clock.arrow.circlepath") }
                    .buttonStyle(.plain)
                    .help("Scheduled Agent Tasks")
                Button { openWindow(id: "agent-audit") } label: { Image(systemName: "play.rectangle.on.rectangle") }
                    .buttonStyle(.plain)
                    .help("Agent Audit & Replay")
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("Close Agent")
            }
            .padding(12)

            if showingConfiguration { configurationView }
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if agent.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Ask about this page, extract structured information, or have the agent work through a browser flow.")
                                Text(pageURL.isEmpty ? "No page is open." : pageURL)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 8)
                        }
                        ForEach(agent.messages) { message in
                            messageRow(message).id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: agent.messages.count) { _, _ in
                    if let last = agent.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask the agent…", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .onSubmit { submit() }
                if agent.isRunning {
                    Button(action: agent.cancel) { Image(systemName: "stop.fill") }
                        .buttonStyle(.borderless)
                        .help("Stop")
                } else {
                    Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.borderless)
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Send")
                }
            }
            .padding(12)
        }
        .frame(width: 380)
        .frame(maxHeight: .infinity)
        .background(.ultraThickMaterial)
        .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1) }
        .shadow(color: .black.opacity(0.2), radius: 16, x: -4)
        .onAppear { apiKey = BrowserAgentKeychain.read(provider: provider) }
        .onChange(of: providerRaw) { oldValue, _ in
            if let old = BrowserAgentProvider(rawValue: oldValue) {
                BrowserAgentKeychain.write(apiKey, provider: old)
            }
            apiKey = BrowserAgentKeychain.read(provider: provider)
            savedModel = provider.defaultModel
        }
        .onChange(of: apiKey) { _, value in BrowserAgentKeychain.write(value, provider: provider) }
    }

    private var configurationView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Provider", selection: $providerRaw) {
                ForEach(BrowserAgentProvider.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            TextField("Model", text: Binding(get: { model }, set: { savedModel = $0 }))
                .textFieldStyle(.roundedBorder)
            if provider == .compatible {
                TextField("Chat Completions URL", text: $customEndpoint)
                    .textFieldStyle(.roundedBorder)
            }
            if provider.needsAPIKey {
                SecureField("API key (stored in Keychain)", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            } else {
                Text("Local endpoint: \(endpoint)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack {
                Text("Cowork folder")
                Spacer()
                Text(workspace.rootURL?.lastPathComponent ?? "Not selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Choose…", action: workspace.chooseFolder)
                if workspace.rootURL != nil { Button("Clear", action: workspace.clear) }
            }
            HStack {
                Text("Automation uses the permissions in Settings → Security.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("App Integrations…") { openWindow(id: "agent-integrations") }
                Button("Clear Chat", action: agent.clear).disabled(agent.isRunning)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func messageRow(_ message: BrowserAgentMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role == .tool ? (message.toolName ?? "Tool") : message.role.rawValue.capitalized)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(message.role == .error ? .red : .secondary)
            if !message.text.isEmpty {
                Text(message.text)
                    .font(message.role == .tool ? .caption.monospaced() : .body)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .user ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func submit() {
        let value = prompt
        prompt = ""
        agent.submit(
            value,
            pageTitle: pageTitle,
            pageURL: pageURL,
            configuration: BrowserAgentConfiguration(
                provider: provider,
                endpoint: endpoint,
                model: model,
                apiKey: apiKey
            ),
            execute: execute
        )
    }
}

struct BrowserAgentMCPConnectionsView: View {
    @ObservedObject private var store = BrowserAgentMCPStore.shared
    @State private var name = ""
    @State private var endpoint = ""
    @State private var bearerToken = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("App Integrations").font(.title2.weight(.semibold))
                    Text("Connect any Streamable HTTP MCP server. Its tools become available to the built-in agent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            Divider()

            HSplitView {
                Form {
                    Section("Add MCP Server") {
                        TextField("Name", text: $name)
                        TextField("https://…/mcp", text: $endpoint)
                            .textContentType(.URL)
                        SecureField("Bearer token (optional, stored in Keychain)", text: $bearerToken)
                        if let errorMessage {
                            Text(errorMessage).font(.caption).foregroundStyle(.red)
                        }
                        Button("Add Integration") { addConnection() }
                            .buttonStyle(.borderedProminent)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Section("OAuth Servers") {
                        Text("For OAuth-only services, run their local MCP remote bridge and add its HTTP endpoint here. Straight Up Browser never stores OAuth cookies or app credentials outside Keychain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .frame(minWidth: 340, idealWidth: 380)

                List {
                    if store.connections.isEmpty {
                        ContentUnavailableView(
                            "No App Integrations",
                            systemImage: "point.3.connected.trianglepath.dotted",
                            description: Text("Add an MCP endpoint to give the agent direct access to that app's tools.")
                        )
                    }
                    ForEach(store.connections) { connection in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Toggle("", isOn: Binding(
                                    get: { connection.enabled },
                                    set: { store.setEnabled(connection.id, $0) }
                                ))
                                .labelsHidden()
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(connection.name).fontWeight(.medium)
                                    Text(connection.endpoint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Spacer()
                                Button("Test") { Task { await store.test(connection) } }
                                Button(role: .destructive) { store.remove(connection.id) } label: {
                                    Image(systemName: "trash")
                                }
                            }
                            if let status = store.status[connection.id] {
                                Text(status)
                                    .font(.caption)
                                    .foregroundStyle(status.hasPrefix("Connected") ? .green : .secondary)
                            }
                        }
                        .padding(.vertical, 5)
                    }
                }
                .frame(minWidth: 440)
            }
        }
        .frame(minWidth: 860, minHeight: 520)
    }

    private func addConnection() {
        do {
            try store.add(name: name, endpoint: endpoint, bearerToken: bearerToken)
            name = ""
            endpoint = ""
            bearerToken = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Scheduled agent tasks

enum BrowserAgentScheduleKind: String, Codable, CaseIterable, Identifiable {
    case daily = "Daily"
    case hours = "Every N hours"
    case minutes = "Every N minutes"
    var id: String { rawValue }
}

struct BrowserAgentTaskRun: Codable, Identifiable {
    enum Status: String, Codable { case succeeded, failed, cancelled }
    let id: UUID
    let startedAt: Date
    let finishedAt: Date
    let status: Status
    let output: String

    init(startedAt: Date, status: Status, output: String) {
        id = UUID()
        self.startedAt = startedAt
        finishedAt = Date()
        self.status = status
        self.output = output
    }
}

struct BrowserAgentTaskDefinition: Codable, Identifiable {
    let id: UUID
    var name: String
    var prompt: String
    var enabled: Bool
    var scheduleKind: BrowserAgentScheduleKind
    var interval: Int
    var dailyHour: Int
    var dailyMinute: Int
    var nextRunAt: Date
    var runs: [BrowserAgentTaskRun]

    init(
        name: String,
        prompt: String,
        enabled: Bool = true,
        scheduleKind: BrowserAgentScheduleKind,
        interval: Int,
        dailyHour: Int,
        dailyMinute: Int,
        now: Date = Date()
    ) {
        id = UUID()
        self.name = name
        self.prompt = prompt
        self.enabled = enabled
        self.scheduleKind = scheduleKind
        self.interval = interval
        self.dailyHour = dailyHour
        self.dailyMinute = dailyMinute
        nextRunAt = now
        runs = []
        nextRunAt = nextDate(after: now)
    }

    func nextDate(after date: Date) -> Date {
        switch scheduleKind {
        case .minutes:
            return date.addingTimeInterval(Double(max(1, min(interval, 60))) * 60)
        case .hours:
            return date.addingTimeInterval(Double(max(1, min(interval, 24))) * 3_600)
        case .daily:
            let calendar = Calendar.autoupdatingCurrent
            var components = calendar.dateComponents([.year, .month, .day], from: date)
            components.hour = max(0, min(dailyHour, 23))
            components.minute = max(0, min(dailyMinute, 59))
            components.second = 0
            let today = calendar.date(from: components) ?? date
            return today > date ? today : (calendar.date(byAdding: .day, value: 1, to: today) ?? date.addingTimeInterval(86_400))
        }
    }

    var scheduleDescription: String {
        switch scheduleKind {
        case .minutes: "Every \(max(1, min(interval, 60))) minutes"
        case .hours: "Every \(max(1, min(interval, 24))) hours"
        case .daily: String(format: "Daily at %02d:%02d", dailyHour, dailyMinute)
        }
    }
}

@MainActor
final class BrowserAgentScheduler: ObservableObject {
    static let shared = BrowserAgentScheduler()

    @Published private(set) var tasks: [BrowserAgentTaskDefinition] = []
    @Published private(set) var runningTaskIds: Set<UUID> = []

    private weak var automationManager: NotificationManager?
    private var runningAgents: [UUID: BrowserAgent] = [:]
    private var cancelledTaskIds: Set<UUID> = []
    private var timer: Timer?
    private let storeURL: URL

    private init() {
        let directory = BrowserCLI.supportDirectory
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        storeURL = directory.appendingPathComponent("agent-tasks.json")
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in BrowserAgentScheduler.shared.runDueTasks() }
        }
    }

    func register(_ manager: NotificationManager) {
        automationManager = manager
        runDueTasks()
    }

    func unregister(_ manager: NotificationManager) {
        if automationManager === manager { automationManager = nil }
    }

    func add(
        name: String,
        prompt: String,
        scheduleKind: BrowserAgentScheduleKind,
        interval: Int,
        dailyHour: Int,
        dailyMinute: Int
    ) {
        tasks.append(BrowserAgentTaskDefinition(
            name: name,
            prompt: prompt,
            scheduleKind: scheduleKind,
            interval: interval,
            dailyHour: dailyHour,
            dailyMinute: dailyMinute
        ))
        save()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].enabled = enabled
        if enabled { tasks[index].nextRunAt = tasks[index].nextDate(after: Date()) }
        save()
    }

    func remove(_ id: UUID) {
        guard !runningTaskIds.contains(id) else { return }
        tasks.removeAll { $0.id == id }
        save()
    }

    func runNow(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              !runningTaskIds.contains(id) else { return }
        tasks[index].nextRunAt = tasks[index].nextDate(after: Date())
        save()
        startRun(id)
    }

    func cancel(_ id: UUID) {
        guard let agent = runningAgents[id] else { return }
        cancelledTaskIds.insert(id)
        agent.cancel()
    }

    private func runDueTasks(now: Date = Date()) {
        let due = tasks.filter { $0.enabled && $0.nextRunAt <= now && !runningTaskIds.contains($0.id) }
        for task in due {
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index].nextRunAt = tasks[index].nextDate(after: now)
            }
            startRun(task.id)
        }
        if !due.isEmpty { save() }
    }

    private func startRun(_ id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }), let manager = automationManager else {
            record(id, startedAt: Date(), status: .failed, output: "No browser window is available. The task will retry at its next scheduled time.")
            return
        }
        runningTaskIds.insert(id)
        let started = Date()
        let agent = BrowserAgent()
        runningAgents[id] = agent
        let provider = BrowserAgentProvider(
            rawValue: UserDefaults.standard.string(forKey: "browserAgentProvider") ?? ""
        ) ?? .openRouter
        let savedModel = UserDefaults.standard.string(forKey: "browserAgentModel") ?? ""
        let customEndpoint = UserDefaults.standard.string(forKey: "browserAgentEndpoint") ?? ""
        let configuration = BrowserAgentConfiguration(
            provider: provider,
            endpoint: provider == .compatible ? customEndpoint : provider.defaultEndpoint,
            model: savedModel.isEmpty ? provider.defaultModel : savedModel,
            apiKey: BrowserAgentKeychain.read(provider: provider)
        )
        let scheduledPrompt = """
        This is a scheduled background task. Work in a new_hidden_page so the user's focused page is not interrupted. When finished, close pages you created unless keeping one open is useful to the result.

        \(task.prompt)
        """
        agent.submit(
            scheduledPrompt,
            pageTitle: "Scheduled task",
            pageURL: "",
            configuration: configuration,
            execute: { tool, arguments in
                await manager.automationJSONResult(tool: tool, arguments: arguments)
            }
        )
        Task { [weak self] in
            while agent.isRunning {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let self else { return }
            let errors = agent.messages.filter { $0.role == .error }
            let output = agent.messages.last(where: { $0.role == .assistant || $0.role == .error })?.text
                ?? "Task ended without a response."
            let status: BrowserAgentTaskRun.Status = if self.cancelledTaskIds.contains(id) {
                .cancelled
            } else {
                errors.isEmpty ? .succeeded : .failed
            }
            self.record(id, startedAt: started, status: status, output: output)
        }
    }

    private func record(_ id: UUID, startedAt: Date, status: BrowserAgentTaskRun.Status, output: String) {
        runningTaskIds.remove(id)
        runningAgents.removeValue(forKey: id)
        cancelledTaskIds.remove(id)
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].runs.insert(BrowserAgentTaskRun(startedAt: startedAt, status: status, output: output), at: 0)
        tasks[index].runs = Array(tasks[index].runs.prefix(15))
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([BrowserAgentTaskDefinition].self, from: data) else { return }
        tasks = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        try? data.write(to: storeURL, options: [.atomic, .completeFileProtection])
    }
}

struct BrowserAgentTasksView: View {
    @ObservedObject private var scheduler = BrowserAgentScheduler.shared
    @State private var name = ""
    @State private var prompt = ""
    @State private var scheduleKind = BrowserAgentScheduleKind.daily
    @State private var interval = 1
    @State private var dailyTime = Calendar.current.date(from: DateComponents(hour: 8)) ?? Date()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Scheduled Agent Tasks", systemImage: "clock.arrow.circlepath")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding()
            Divider()
            HSplitView {
                Form {
                    Section("New Task") {
                        TextField("Name", text: $name)
                        TextField("What should the agent do?", text: $prompt, axis: .vertical)
                            .lineLimit(4...10)
                        Picker("Schedule", selection: $scheduleKind) {
                            ForEach(BrowserAgentScheduleKind.allCases) { Text($0.rawValue).tag($0) }
                        }
                        if scheduleKind == .daily {
                            DatePicker("Time", selection: $dailyTime, displayedComponents: .hourAndMinute)
                        } else {
                            Stepper("Interval: \(interval)", value: $interval, in: 1...(scheduleKind == .hours ? 24 : 60))
                        }
                        Button("Create Task") { createTask() }
                            .buttonStyle(.borderedProminent)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .formStyle(.grouped)
                .frame(minWidth: 300, idealWidth: 340)

                List {
                    ForEach(scheduler.tasks) { task in taskRow(task) }
                }
                .frame(minWidth: 420)
            }
        }
        .frame(minWidth: 780, minHeight: 520)
    }

    @ViewBuilder
    private func taskRow(_ task: BrowserAgentTaskDefinition) -> some View {
        DisclosureGroup {
            Text(task.prompt).font(.callout).textSelection(.enabled)
            if task.runs.isEmpty {
                Text("No runs yet").foregroundStyle(.secondary)
            } else {
                ForEach(task.runs) { run in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: run.status == .succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(run.status == .succeeded ? .green : .orange)
                            Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                            Spacer()
                            Text(run.status.rawValue.capitalized).foregroundStyle(.secondary)
                        }
                        Text(run.output).font(.caption).textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }
        } label: {
            HStack {
                Toggle("", isOn: Binding(
                    get: { task.enabled },
                    set: { scheduler.setEnabled(task.id, $0) }
                ))
                .labelsHidden()
                VStack(alignment: .leading) {
                    Text(task.name).fontWeight(.medium)
                    Text("\(task.scheduleDescription) · next \(task.nextRunAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if scheduler.runningTaskIds.contains(task.id) {
                    ProgressView().controlSize(.small)
                    Button("Stop") { scheduler.cancel(task.id) }
                } else {
                    Button("Run") { scheduler.runNow(task.id) }
                    Button(role: .destructive) { scheduler.remove(task.id) } label: { Image(systemName: "trash") }
                }
            }
        }
    }

    private func createTask() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: dailyTime)
        scheduler.add(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            scheduleKind: scheduleKind,
            interval: interval,
            dailyHour: components.hour ?? 8,
            dailyMinute: components.minute ?? 0
        )
        name = ""
        prompt = ""
    }
}

// MARK: - Local agent audit and replay

private struct BrowserAgentAuditEvent: Identifiable {
    let id = UUID()
    let timestamp: Date?
    let kind: String
    let tool: String
    let detail: String
    let framePath: String?
}

private struct BrowserAgentAuditSession: Identifiable {
    let id: String
    let modifiedAt: Date
    let client: String
    let events: [BrowserAgentAuditEvent]

    var frames: [BrowserAgentAuditEvent] { events.filter { $0.framePath != nil } }
    var toolCount: Int { events.filter { $0.kind == "tool_finished" }.count }
}

@MainActor
private final class BrowserAgentAuditStore: ObservableObject {
    @Published private(set) var sessions: [BrowserAgentAuditSession] = []

    func reload() {
        let directory = BrowserCLI.supportDirectory.appendingPathComponent("agent-audit", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        sessions = files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap(loadSession)
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func loadSession(_ url: URL) -> BrowserAgentAuditSession? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let formatter = ISO8601DateFormatter()
        var client = "MCP client"
        var events: [BrowserAgentAuditEvent] = []
        for line in text.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let kind = object["event"] as? String ?? "event"
            let tool = object["tool"] as? String ?? ""
            if kind == "client_initialized", let info = object["client"] as? [String: Any] {
                client = info["name"] as? String ?? client
            }
            var printable = object
            printable.removeValue(forKey: "event")
            printable.removeValue(forKey: "timestamp")
            printable.removeValue(forKey: "tool")
            printable.removeValue(forKey: "frame")
            let detail: String
            if printable.isEmpty {
                detail = ""
            } else if let encoded = try? JSONSerialization.data(withJSONObject: printable, options: [.prettyPrinted, .sortedKeys]) {
                detail = String(data: encoded, encoding: .utf8) ?? ""
            } else {
                detail = String(describing: printable)
            }
            events.append(BrowserAgentAuditEvent(
                timestamp: (object["timestamp"] as? String).flatMap(formatter.date),
                kind: kind,
                tool: tool,
                detail: detail,
                framePath: object["frame"] as? String
            ))
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
        return BrowserAgentAuditSession(
            id: url.deletingPathExtension().lastPathComponent,
            modifiedAt: modified,
            client: client,
            events: events
        )
    }
}

struct BrowserAgentAuditView: View {
    @StateObject private var store = BrowserAgentAuditStore()
    @State private var selectedSessionId: String?
    @State private var selectedFrame = 0
    @State private var playbackTask: Task<Void, Never>?

    private var selectedSession: BrowserAgentAuditSession? {
        store.sessions.first { $0.id == selectedSessionId } ?? store.sessions.first
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Agent Sessions").font(.headline)
                    Spacer()
                    Button(action: reload) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                }
                .padding(12)
                Divider()
                List {
                    ForEach(store.sessions) { session in
                        Button {
                            selectedSessionId = session.id
                            selectedFrame = 0
                            stopPlayback()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.client).fontWeight(.medium)
                                Text(session.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(session.toolCount) tools · \(session.frames.count) replay frames")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(session.id == selectedSession?.id ? Color.accentColor.opacity(0.16) : Color.clear)
                    }
                }
            }
            .frame(minWidth: 230, idealWidth: 270)

            if let session = selectedSession {
                sessionDetail(session)
            } else {
                ContentUnavailableView(
                    "No Agent Sessions",
                    systemImage: "play.rectangle.on.rectangle",
                    description: Text("MCP sessions are recorded locally when an agent controls the browser.")
                )
            }
        }
        .frame(minWidth: 880, minHeight: 600)
        .onAppear(perform: reload)
        .onDisappear(perform: stopPlayback)
    }

    @ViewBuilder
    private func sessionDetail(_ session: BrowserAgentAuditSession) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(session.client).font(.title2.weight(.semibold))
                    Text("Session \(session.id)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("Show Files") {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        BrowserCLI.supportDirectory.appendingPathComponent("agent-audit/\(session.id)", isDirectory: true)
                    ])
                }
                if !session.frames.isEmpty {
                    Button(playbackTask == nil ? "Replay" : "Stop") { togglePlayback(session) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            Divider()

            if !session.frames.isEmpty {
                let index = min(selectedFrame, session.frames.count - 1)
                let event = session.frames[index]
                VStack(spacing: 8) {
                    if let path = event.framePath, let image = NSImage(contentsOfFile: path) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 330)
                            .background(Color.black.opacity(0.75))
                    } else {
                        ContentUnavailableView("Frame Missing", systemImage: "photo.badge.exclamationmark")
                            .frame(height: 260)
                    }
                    HStack {
                        Button { selectedFrame = max(0, index - 1) } label: { Image(systemName: "backward.frame.fill") }
                            .disabled(index == 0)
                        Slider(
                            value: Binding(get: { Double(index) }, set: { selectedFrame = Int($0.rounded()) }),
                            in: 0...Double(max(1, session.frames.count - 1)),
                            step: 1
                        )
                        Button { selectedFrame = min(session.frames.count - 1, index + 1) } label: { Image(systemName: "forward.frame.fill") }
                            .disabled(index >= session.frames.count - 1)
                        Text("\(index + 1) / \(session.frames.count)").font(.caption.monospacedDigit())
                    }
                    Text(event.tool.isEmpty ? "Browser action" : event.tool)
                        .font(.caption.weight(.medium))
                }
                .padding()
                Divider()
            }

            List(session.events) { event in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: event.kind))
                        .foregroundStyle(event.kind == "frame_captured" ? .blue : .secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.tool.isEmpty ? event.kind.replacingOccurrences(of: "_", with: " ").capitalized : event.tool)
                            .fontWeight(.medium)
                        if !event.detail.isEmpty {
                            Text(event.detail).font(.caption.monospaced()).lineLimit(4).textSelection(.enabled)
                        }
                    }
                    Spacer()
                    if let date = event.timestamp {
                        Text(date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func reload() {
        store.reload()
        if selectedSessionId == nil { selectedSessionId = store.sessions.first?.id }
    }

    private func togglePlayback(_ session: BrowserAgentAuditSession) {
        if playbackTask != nil {
            stopPlayback()
            return
        }
        playbackTask = Task { @MainActor in
            if selectedFrame >= session.frames.count - 1 { selectedFrame = 0 }
            while !Task.isCancelled && selectedFrame < session.frames.count - 1 {
                try? await Task.sleep(for: .milliseconds(850))
                guard !Task.isCancelled else { break }
                selectedFrame += 1
            }
            playbackTask = nil
        }
    }

    private func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
    }

    private func icon(for event: String) -> String {
        switch event {
        case "tool_started": "play.circle"
        case "tool_finished": "checkmark.circle"
        case "frame_captured": "photo"
        case "session_started": "record.circle"
        case "session_ended": "stop.circle"
        default: "circle"
        }
    }
}
