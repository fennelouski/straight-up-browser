import Foundation

// A dependency-free Model Context Protocol stdio server.  Keeping it in the
// shipped helper means every MCP client talks to the same capability-gated
// browser bridge as the CLI; there is no debug port or second daemon to run.

private let mcpProtocolVersion = "2025-06-18"

var browserMCPTools: [[String: Any]] {
    (try? AgentToolCatalog.canonical.mcpTools(profile: .browserOSMCP)) ?? []
}
private func mcpNormaliseArguments(_ arguments: [String: Any]) -> [String: Any] {
    let aliases = [
        "page_id": "pageId", "window_id": "windowId", "element_id": "elementId",
        "target_element_id": "targetElementId", "target_selector": "targetSelector",
        "full_page": "fullPage", "prompt_text": "promptText", "group_id": "groupId",
        "page_ids": "pageIds",
    ]
    var result = arguments
    for (old, new) in aliases where result[new] == nil { result[new] = result[old] }
    return result
}

private func mcpAppRequest(
    _ tool: String,
    arguments: [String: Any],
    timeout: TimeInterval = 30
) -> [String: Any] {
    let request: [String: Any] = ["tool": tool, "arguments": mcpNormaliseArguments(arguments)]
    guard let data = try? JSONSerialization.data(withJSONObject: request) else {
        return ["error": "could not encode browser request"]
    }
    do {
        let response = try requestResponseThrowing("agent \(data.base64EncodedString())", timeout: timeout)
        return ((try? JSONSerialization.jsonObject(with: response)) as? [String: Any])
            ?? ["error": "browser returned a malformed response"]
    } catch {
        return ["error": error.localizedDescription]
    }
}

private func mcpJSONString(_ value: Any) -> String {
    if let string = value as? String { return string }
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    else { return String(describing: value) }
    return String(data: data, encoding: .utf8) ?? String(describing: value)
}

private func mcpWriteBase64Result(_ response: [String: Any], path: String) -> [String: Any] {
    guard response["error"] == nil,
          let encoded = response["data"] as? String,
          let data = Data(base64Encoded: encoded) else { return response }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    do {
        try data.write(to: url, options: .atomic)
        return ["ok": true, "path": url.path, "bytes": data.count, "mimeType": response["mimeType"] ?? "application/octet-stream"]
    } catch {
        return ["error": "could not write \(url.path): \(error.localizedDescription)"]
    }
}

private func mcpCallBrowserTool(_ name: String, rawArguments: [String: Any]) -> [String: Any] {
    let arguments = mcpNormaliseArguments(rawArguments)
    switch name {
    case "save_pdf":
        guard let path = arguments["path"] as? String else { return ["error": "save_pdf requires path"] }
        return mcpWriteBase64Result(mcpAppRequest(name, arguments: arguments, timeout: 60), path: path)
    case "save_screenshot":
        guard let path = arguments["path"] as? String else { return ["error": "save_screenshot requires path"] }
        return mcpWriteBase64Result(mcpAppRequest(name, arguments: arguments, timeout: 60), path: path)
    default:
        return mcpAppRequest(name, arguments: arguments)
    }
}

private func mcpResponseContent(_ result: [String: Any]) -> [String: Any] {
    if let encoded = result["data"] as? String,
       let mimeType = result["mimeType"] as? String,
       mimeType.hasPrefix("image/") {
        var metadata = result
        metadata.removeValue(forKey: "data")
        return [
            "content": [
                ["type": "image", "data": encoded, "mimeType": mimeType],
                ["type": "text", "text": mcpJSONString(metadata)],
            ],
        ]
    }
    let isError = result["error"] != nil
    return [
        "content": [["type": "text", "text": mcpJSONString(result)]],
        "isError": isError,
    ]
}

private func mcpSend(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([UInt8(ascii: "\n")]))
}

private func mcpError(id: Any, code: Int, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
}

/// The helper is shipped inside Browser.app rather than as its own bundle, so
/// advertise the enclosing app's marketing version. This keeps MCP client
/// diagnostics aligned with the browser release without a second version
/// literal that can drift.
private func mcpServerVersion() -> String {
    let executable = (Bundle.main.executableURL
        ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .resolvingSymlinksInPath()
    let appURL = executable
        .deletingLastPathComponent() // Helpers
        .deletingLastPathComponent() // Contents
        .deletingLastPathComponent() // Browser.app
    return Bundle(url: appURL)?
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "development"
}

func runMCPServer() -> Never {
    // BrowserCLI owns the canonical, metadata-only AgentRunStore record for
    // every invocation. Do not create a second JSONL history here: old JSONL
    // files are imported by the legacy migrator, and continuing to emit them
    // would duplicate runs while retaining raw arguments, DOM/file/MCP bodies,
    // and automatic screenshots (including incognito content).
    while let line = readLine(strippingNewline: true) {
        guard let data = line.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = message["method"] as? String else { continue }
        let id = message["id"]
        if id == nil { continue } // notifications never receive a response

        switch method {
        case "initialize":
            mcpSend([
                "jsonrpc": "2.0",
                "id": id!,
                "result": [
                    "protocolVersion": mcpProtocolVersion,
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "straight-up-browser", "version": mcpServerVersion()],
                    "instructions": "Controls the user's real WebKit browser. Start with list_pages or take_snapshot. Background pages have stable IDs; do not act on a personal page unless the user asked you to.",
                ],
            ])
        case "ping":
            mcpSend(["jsonrpc": "2.0", "id": id!, "result": [:]])
        case "tools/list":
            mcpSend(["jsonrpc": "2.0", "id": id!, "result": ["tools": browserMCPTools]])
        case "tools/call":
            guard let params = message["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                mcpSend(mcpError(id: id!, code: -32602, message: "tools/call requires a tool name"))
                continue
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let result = mcpCallBrowserTool(name, rawArguments: arguments)
            mcpSend(["jsonrpc": "2.0", "id": id!, "result": mcpResponseContent(result)])
        default:
            mcpSend(mcpError(id: id!, code: -32601, message: "Method not found: \(method)"))
        }
    }
    exit(0)
}
