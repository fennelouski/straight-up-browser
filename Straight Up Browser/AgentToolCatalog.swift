import Foundation

// This file is compiled by both app targets and the dependency-free
// browser-cli helper. Keep it Foundation-only: descriptors are metadata and
// never execute a tool.

nonisolated enum JSONValue: Codable, Equatable, Sendable {
    case null
    case boolean(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .boolean(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    init(foundationValue value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .boolean(value)
        case let value as NSNumber:
            self = .number(value.doubleValue)
        case let value as String:
            self = .string(value)
        case let values as [Any]:
            self = .array(try values.map(JSONValue.init(foundationValue:)))
        case let values as [String: Any]:
            self = .object(try values.mapValues(JSONValue.init(foundationValue:)))
        default:
            throw ConversionError.unsupported(String(describing: type(of: value)))
        }
    }

    var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case .boolean(let value): value
        case .number(let value):
            value.rounded() == value && value >= Double(Int.min) && value <= Double(Int.max)
                ? Int(value) : value
        case .string(let value): value
        case .array(let values): values.map(\.foundationValue)
        case .object(let values): values.mapValues(\.foundationValue)
        }
    }

    enum ConversionError: Error, Equatable {
        case unsupported(String)
    }
}

nonisolated indirect enum AgentJSONSchema: Codable, Equatable, Sendable {
    case string(description: String? = nil, allowedValues: [String]? = nil)
    case boolean(description: String? = nil)
    case integer(description: String? = nil, minimum: Int? = nil, maximum: Int? = nil)
    case number(description: String? = nil, minimum: Double? = nil, maximum: Double? = nil)
    case array(description: String? = nil, items: AgentJSONSchema)
    case object(
        description: String? = nil,
        properties: [String: AgentJSONSchema],
        required: Set<String>,
        additionalProperties: Bool
    )
    case unsupported(keyword: String)

    static func object(
        _ properties: [String: AgentJSONSchema] = [:],
        required: [String] = [],
        additionalProperties: Bool = false
    ) -> AgentJSONSchema {
        .object(
            description: nil,
            properties: properties,
            required: Set(required),
            additionalProperties: additionalProperties
        )
    }

    var jsonValue: JSONValue {
        var value: [String: JSONValue]
        switch self {
        case .string(let description, let allowedValues):
            value = ["type": .string("string")]
            if let allowedValues { value["enum"] = .array(allowedValues.map(JSONValue.string)) }
            if let description { value["description"] = .string(description) }
        case .boolean(let description):
            value = ["type": .string("boolean")]
            if let description { value["description"] = .string(description) }
        case .integer(let description, let minimum, let maximum):
            value = ["type": .string("integer")]
            if let minimum { value["minimum"] = .number(Double(minimum)) }
            if let maximum { value["maximum"] = .number(Double(maximum)) }
            if let description { value["description"] = .string(description) }
        case .number(let description, let minimum, let maximum):
            value = ["type": .string("number")]
            if let minimum { value["minimum"] = .number(minimum) }
            if let maximum { value["maximum"] = .number(maximum) }
            if let description { value["description"] = .string(description) }
        case .array(let description, let items):
            value = ["type": .string("array"), "items": items.jsonValue]
            if let description { value["description"] = .string(description) }
        case .object(let description, let properties, let required, let additionalProperties):
            value = [
                "type": .string("object"),
                "properties": .object(properties.mapValues(\.jsonValue)),
                "additionalProperties": .boolean(additionalProperties),
            ]
            if !required.isEmpty { value["required"] = .array(required.sorted().map(JSONValue.string)) }
            if let description { value["description"] = .string(description) }
        case .unsupported(let keyword):
            value = [keyword: .boolean(true)]
        }
        return .object(value)
    }

    var unsupportedKeyword: String? {
        switch self {
        case .unsupported(let keyword): keyword
        case .array(_, let items): items.unsupportedKeyword
        case .object(_, let properties, _, _):
            properties.values.compactMap(\.unsupportedKeyword).first
        default: nil
        }
    }

    func validationErrors(for value: JSONValue, path: String = "$") -> [String] {
        switch (self, value) {
        case (.string(_, let allowed), .string(let value)):
            guard let allowed, !allowed.contains(value) else { return [] }
            return ["\(path) must be one of \(allowed.joined(separator: ", "))"]
        case (.boolean, .boolean):
            return []
        case (.integer(_, let minimum, let maximum), .number(let value)):
            var errors: [String] = []
            if value.rounded() != value { errors.append("\(path) must be an integer") }
            if let minimum, value < Double(minimum) { errors.append("\(path) is below \(minimum)") }
            if let maximum, value > Double(maximum) { errors.append("\(path) is above \(maximum)") }
            return errors
        case (.number(_, let minimum, let maximum), .number(let value)):
            var errors: [String] = []
            if let minimum, value < minimum { errors.append("\(path) is below \(minimum)") }
            if let maximum, value > maximum { errors.append("\(path) is above \(maximum)") }
            return errors
        case (.array(_, let items), .array(let values)):
            return values.enumerated().flatMap { index, value in
                items.validationErrors(for: value, path: "\(path)[\(index)]")
            }
        case (.object(_, let properties, let required, let additional), .object(let values)):
            var errors = required.subtracting(values.keys).sorted().map { "\(path).\($0) is required" }
            for (key, value) in values {
                if let schema = properties[key] {
                    errors += schema.validationErrors(for: value, path: "\(path).\(key)")
                } else if !additional {
                    errors.append("\(path).\(key) is not allowed")
                }
            }
            return errors
        case (.unsupported(let keyword), _):
            return ["\(path) uses unsupported schema keyword \(keyword)"]
        default:
            return ["\(path) has the wrong JSON type"]
        }
    }
}

nonisolated enum AgentToolOrigin: String, Codable, Equatable, Sendable {
    case browser
    case cowork
    case mcp
    case internalTool
}

nonisolated enum AgentToolRisk: String, Codable, Equatable, Sendable {
    case observe
    case navigate
    case mutateLocal
    case externalEffect
    case destructive
}

nonisolated enum AgentCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case browserControl
    case pageRead
    case pageScript
    case screenshot
    case download
    case windowManagement
    case tabGroups
    case bookmarkRead
    case bookmarkWrite
    case historyRead
    case historyWrite
    case coworkRead
    case coworkWrite
    case externalMCP
}

nonisolated enum AgentToolVisibility: String, Codable, CaseIterable, Hashable, Sendable {
    case browserOSMCP
    case builtInAgent
    case scheduler
}

nonisolated enum AgentToolRoute: String, Codable, Equatable, Sendable {
    case browserNative
    case browserScript
    case observableWait
    case cowork
    case dynamicMCP
}

nonisolated struct AgentToolDeprecation: Codable, Equatable, Sendable {
    let sinceVersion: Int
    let replacement: String?
    let message: String
}

nonisolated struct AgentToolAlias: Codable, Equatable, Sendable {
    let name: String
    let targetName: String
    var deprecation: AgentToolDeprecation?

    init(name: String, targetName: String, deprecation: AgentToolDeprecation? = nil) {
        self.name = name
        self.targetName = targetName
        self.deprecation = deprecation
    }
}

nonisolated struct AgentToolDescriptor: Codable, Equatable, Sendable {
    var name: String
    var version: Int
    var description: String
    var inputSchema: AgentJSONSchema
    var outputSchema: AgentJSONSchema
    var requiredCapabilities: Set<AgentCapability>
    var risk: AgentToolRisk
    var origin: AgentToolOrigin
    var route: AgentToolRoute
    var visibility: Set<AgentToolVisibility>
    var deprecation: AgentToolDeprecation?
}

nonisolated struct AgentToolCatalog: Sendable {
    /// Version of the catalog snapshot persisted with an agent run. Increment
    /// this only when the canonical descriptor contract changes incompatibly.
    static let currentVersion = 1

    private(set) var allDescriptors: [AgentToolDescriptor]
    private(set) var aliases: [AgentToolAlias]

    init(descriptors: [AgentToolDescriptor], aliases: [AgentToolAlias] = []) {
        allDescriptors = descriptors
        self.aliases = aliases
    }

    static let canonical = AgentToolCatalog(
        descriptors: makeCanonicalDescriptors(),
        aliases: [
            AgentToolAlias(
                name: "wait_for_page",
                targetName: "wait_for",
                deprecation: AgentToolDeprecation(
                    sinceVersion: 1,
                    replacement: "wait_for",
                    message: "Use wait_for with condition=load."
                )
            ),
        ]
    )

    func descriptors(visibleIn profile: AgentToolVisibility) -> [AgentToolDescriptor] {
        allDescriptors.filter { $0.visibility.contains(profile) }
    }

    func descriptor(named name: String) -> AgentToolDescriptor? {
        if let descriptor = allDescriptors.first(where: { $0.name == name }) { return descriptor }
        guard let alias = aliases.first(where: { $0.name == name }) else { return nil }
        return allDescriptors.first { $0.name == alias.targetName }
    }

    func validate() throws {
        var names = Set<String>()
        for descriptor in allDescriptors {
            guard names.insert(descriptor.name).inserted else {
                throw ValidationError.duplicateName(descriptor.name)
            }
            guard Self.validName(descriptor.name) else {
                throw ValidationError.invalidName(descriptor.name)
            }
            guard descriptor.version > 0 else {
                throw ValidationError.invalidVersion(descriptor.name)
            }
            guard !descriptor.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError.missingDescription(descriptor.name)
            }
            guard !descriptor.requiredCapabilities.isEmpty else {
                throw ValidationError.missingCapabilities(descriptor.name)
            }
            guard !descriptor.visibility.isEmpty else {
                throw ValidationError.missingVisibility(descriptor.name)
            }
            if let keyword = descriptor.inputSchema.unsupportedKeyword
                ?? descriptor.outputSchema.unsupportedKeyword {
                throw ValidationError.unsupportedSchema(tool: descriptor.name, keyword: keyword)
            }
        }

        var aliasNames = Set<String>()
        for alias in aliases {
            guard names.contains(alias.targetName) else {
                throw ValidationError.unresolvedAlias(alias.name)
            }
            guard !names.contains(alias.name), aliasNames.insert(alias.name).inserted else {
                throw ValidationError.duplicateAlias(alias.name)
            }
        }
    }

    func openAIFunctionTools(profile: AgentToolVisibility) throws -> [[String: Any]] {
        try validate()
        return descriptors(visibleIn: profile).map { descriptor in
            [
                "type": "function",
                "function": [
                    "name": descriptor.name,
                    "description": descriptor.description,
                    "parameters": descriptor.inputSchema.jsonValue.foundationValue,
                ],
            ]
        }
    }

    func mcpTools(profile: AgentToolVisibility) throws -> [[String: Any]] {
        try validate()
        return descriptors(visibleIn: profile).map { descriptor in
            [
                "name": descriptor.name,
                "description": descriptor.description,
                "inputSchema": descriptor.inputSchema.jsonValue.foundationValue,
                "outputSchema": descriptor.outputSchema.jsonValue.foundationValue,
            ]
        }
    }

    func mcpSnapshotData() throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: mcpTools(profile: .browserOSMCP),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(UInt8(ascii: "\n"))
        return data
    }

    enum ValidationError: Error, Equatable {
        case duplicateName(String)
        case invalidName(String)
        case invalidVersion(String)
        case missingDescription(String)
        case missingCapabilities(String)
        case missingVisibility(String)
        case unresolvedAlias(String)
        case duplicateAlias(String)
        case unsupportedSchema(tool: String, keyword: String)
    }

    nonisolated private static func validName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return name.unicodeScalars.allSatisfy(allowed.contains)
    }
}

private extension AgentToolCatalog {
    nonisolated static func makeCanonicalDescriptors() -> [AgentToolDescriptor] {
        let page = AgentJSONSchema.string(description: "Stable page ID from list_pages. Omit to use the focused page.")
        let window = AgentJSONSchema.string(description: "Stable window ID from list_windows. Omit to use the focused window.")
        let selector = AgentJSONSchema.string(description: "CSS selector, or omit when elementId from a snapshot is supplied.")
        let element = AgentJSONSchema.string(description: "Element ID (for example sub-12) returned by take_snapshot.")
        let path = AgentJSONSchema.string(description: "Path relative to the user-approved cowork folder.")
        let strings: (String) -> AgentJSONSchema = { .array(description: $0, items: .string()) }
        let result = AgentJSONSchema.object([
            "ok": .boolean(description: "Whether the operation succeeded."),
            "error": .string(description: "A structured failure message when the operation did not succeed."),
        ], additionalProperties: true)

        func descriptor(
            _ name: String,
            _ description: String,
            properties: [String: AgentJSONSchema] = [:],
            required: [String] = [],
            capabilities: Set<AgentCapability>,
            risk: AgentToolRisk,
            route: AgentToolRoute,
            builtIn: Bool = false,
            origin: AgentToolOrigin = .browser,
            mcp: Bool = true
        ) -> AgentToolDescriptor {
            var visibility = Set<AgentToolVisibility>()
            if mcp { visibility.insert(.browserOSMCP) }
            if builtIn { visibility.formUnion([.builtInAgent, .scheduler]) }
            return AgentToolDescriptor(
                name: name,
                version: 1,
                description: description,
                inputSchema: .object(properties, required: required),
                outputSchema: result,
                requiredCapabilities: capabilities,
                risk: risk,
                origin: origin,
                route: route,
                visibility: visibility,
                deprecation: nil
            )
        }

        let read: Set<AgentCapability> = [.pageRead]
        let control: Set<AgentCapability> = [.browserControl]
        let script: Set<AgentCapability> = [.pageRead, .pageScript]

        return [
            // BrowserOS-compatible navigation/pages (8)
            descriptor("get_active_page", "Get the focused browser page.", properties: ["windowId": window], capabilities: read, risk: .observe, route: .browserNative, builtIn: true),
            descriptor("list_pages", "List every open page with stable page, tab, and window IDs.", capabilities: read, risk: .observe, route: .browserNative, builtIn: true),
            descriptor("navigate_page", "Navigate a page to a URL or perform back, forward, reload, or stop.", properties: [
                "pageId": page,
                "url": .string(description: "Absolute URL to load."),
                "action": .string(description: "History action.", allowedValues: ["back", "forward", "reload", "stop"]),
            ], capabilities: control, risk: .navigate, route: .browserNative, builtIn: true),
            descriptor("new_page", "Open a page. It may remain in the background without changing the focused tab.", properties: [
                "windowId": window,
                "url": .string(description: "Optional absolute URL."),
                "background": .boolean(description: "Keep the user's focused page unchanged."),
                "incognito": .boolean(description: "Use a fresh in-memory private session."),
            ], capabilities: control, risk: .navigate, route: .browserNative, builtIn: true),
            descriptor("new_hidden_page", "Open a background automation page without changing focus.", properties: [
                "windowId": window,
                "url": .string(description: "Optional absolute URL."),
                "incognito": .boolean(description: "Use a fresh in-memory private session."),
            ], capabilities: control, risk: .navigate, route: .browserNative, builtIn: true),
            descriptor("show_page", "Focus and reveal a background page.", properties: ["pageId": page], required: ["pageId"], capabilities: control, risk: .navigate, route: .browserNative, builtIn: true),
            descriptor("move_page", "Move a page to a zero-based sidebar position.", properties: [
                "pageId": page,
                "index": .integer(description: "Zero-based destination index.", minimum: 0),
            ], required: ["pageId", "index"], capabilities: control, risk: .navigate, route: .browserNative),
            descriptor("close_page", "Close a page by stable ID.", properties: ["pageId": page], required: ["pageId"], capabilities: control, risk: .navigate, route: .browserNative, builtIn: true),

            // Observation (8)
            descriptor("take_snapshot", "Return a compact accessibility-style outline with stable interactive element IDs.", properties: ["pageId": page], capabilities: read, risk: .observe, route: .browserScript, builtIn: true),
            descriptor("take_enhanced_snapshot", "Return a detailed semantic outline including element state and geometry.", properties: ["pageId": page], capabilities: read, risk: .observe, route: .browserScript, builtIn: true),
            descriptor("get_page_content", "Extract the main page as readable Markdown-like text.", properties: ["pageId": page], capabilities: read, risk: .observe, route: .browserScript, builtIn: true),
            descriptor("get_page_links", "Extract and deduplicate links from a page.", properties: ["pageId": page], capabilities: read, risk: .observe, route: .browserScript, builtIn: true),
            descriptor("get_dom", "Return raw HTML, optionally scoped to a CSS selector.", properties: [
                "pageId": page,
                "selector": .string(description: "Optional CSS selector to scope the returned DOM."),
            ], capabilities: read, risk: .observe, route: .browserScript, builtIn: true),
            descriptor("search_dom", "Search the DOM by text, CSS selector, or XPath.", properties: [
                "pageId": page,
                "query": .string(description: "Text, selector, or XPath query."),
                "mode": .string(description: "Search mode.", allowedValues: ["text", "css", "xpath"]),
                "limit": .integer(description: "Maximum matching nodes to return.", minimum: 1, maximum: 500),
            ], required: ["query"], capabilities: read, risk: .observe, route: .browserScript, builtIn: true),
            descriptor("take_screenshot", "Capture a page and return image content.", properties: [
                "pageId": page,
                "fullPage": .boolean(description: "Capture the whole scrollable document."),
                "format": .string(description: "Image encoding.", allowedValues: ["png", "jpeg"]),
            ], capabilities: [.pageRead, .screenshot], risk: .observe, route: .browserNative),
            descriptor("evaluate_script", "Evaluate JavaScript in an isolated content world that shares the page DOM.", properties: [
                "pageId": page,
                "script": .string(description: "JavaScript source; the last expression is returned."),
            ], required: ["script"], capabilities: script, risk: .externalEffect, route: .browserNative, builtIn: true),

            // Interaction/input (14)
            descriptor("click", "Click an element by snapshot ID or CSS selector.", properties: ["pageId": page, "elementId": element, "selector": selector], capabilities: script, risk: .externalEffect, route: .browserScript, builtIn: true),
            descriptor("click_at", "Click the topmost page element at viewport coordinates.", properties: ["pageId": page, "x": .number(description: "Viewport X coordinate."), "y": .number(description: "Viewport Y coordinate.")], required: ["x", "y"], capabilities: script, risk: .externalEffect, route: .browserScript),
            descriptor("hover", "Dispatch pointer hover events over an element.", properties: ["pageId": page, "elementId": element, "selector": selector], capabilities: script, risk: .mutateLocal, route: .browserScript),
            descriptor("focus", "Scroll an element into view and focus it.", properties: ["pageId": page, "elementId": element, "selector": selector], capabilities: script, risk: .mutateLocal, route: .browserScript),
            descriptor("fill", "Set an input, textarea, or editable element value and fire input/change events.", properties: ["pageId": page, "elementId": element, "selector": selector, "value": .string(description: "Text to enter."), "clear": .boolean(description: "Clear the current value first.")], required: ["value"], capabilities: script, risk: .mutateLocal, route: .browserScript, builtIn: true),
            descriptor("clear", "Clear an input or editable element.", properties: ["pageId": page, "elementId": element, "selector": selector], capabilities: script, risk: .mutateLocal, route: .browserScript),
            descriptor("check", "Check a checkbox or radio control.", properties: ["pageId": page, "elementId": element, "selector": selector], capabilities: script, risk: .mutateLocal, route: .browserScript),
            descriptor("uncheck", "Uncheck a checkbox.", properties: ["pageId": page, "elementId": element, "selector": selector], capabilities: script, risk: .mutateLocal, route: .browserScript),
            descriptor("select_option", "Select one or more options by value or visible text.", properties: ["pageId": page, "elementId": element, "selector": selector, "values": strings("Option values or visible labels.")], required: ["values"], capabilities: script, risk: .mutateLocal, route: .browserScript),
            descriptor("press_key", "Dispatch a key or modifier combination such as Enter or Meta+A.", properties: ["pageId": page, "key": .string(description: "Key or plus-separated modifier combination.")], required: ["key"], capabilities: script, risk: .externalEffect, route: .browserScript, builtIn: true),
            descriptor("drag", "Drag from one element or point to another.", properties: ["pageId": page, "elementId": element, "selector": selector, "targetElementId": .string(description: "Destination snapshot element ID."), "targetSelector": .string(description: "Destination CSS selector."), "x": .number(description: "Destination viewport X."), "y": .number(description: "Destination viewport Y.")], capabilities: script, risk: .externalEffect, route: .browserScript),
            descriptor("scroll", "Scroll the page or an element by pixels.", properties: ["pageId": page, "elementId": element, "selector": selector, "direction": .string(description: "Direction.", allowedValues: ["up", "down", "left", "right"]), "amount": .number(description: "Distance in CSS pixels.")], capabilities: script, risk: .mutateLocal, route: .browserScript, builtIn: true),
            descriptor("upload_file", "Attach local files to a file input and fire its change event.", properties: ["pageId": page, "elementId": element, "selector": selector, "paths": strings("Absolute local file paths.")], required: ["paths"], capabilities: script, risk: .externalEffect, route: .browserScript),
            descriptor("handle_dialog", "Accept or dismiss an open JavaScript dialog, optionally filling its prompt.", properties: ["pageId": page, "accept": .boolean(description: "Accept when true; dismiss when false."), "promptText": .string(description: "Text for a prompt dialog.")], capabilities: script, risk: .externalEffect, route: .browserNative, builtIn: true),

            // Export/files (3)
            descriptor("save_pdf", "Render the page to a PDF file.", properties: ["pageId": page, "path": .string(description: "Destination file path.")], required: ["path"], capabilities: [.pageRead, .screenshot], risk: .mutateLocal, route: .browserNative),
            descriptor("save_screenshot", "Capture and save a screenshot to disk.", properties: ["pageId": page, "path": .string(description: "Destination file path."), "fullPage": .boolean(description: "Capture the whole document."), "format": .string(description: "Image encoding.", allowedValues: ["png", "jpeg"])], required: ["path"], capabilities: [.pageRead, .screenshot], risk: .mutateLocal, route: .browserScript),
            descriptor("download_file", "Click a page element to begin its normal WebKit download.", properties: ["pageId": page, "elementId": element, "selector": selector], capabilities: [.pageRead, .pageScript, .download], risk: .externalEffect, route: .browserScript),

            // Windows (5)
            descriptor("list_windows", "List browser windows and their stable IDs.", capabilities: read, risk: .observe, route: .browserNative),
            descriptor("create_window", "Create and activate a browser window.", properties: ["url": .string(description: "Optional URL for its focused page.")], capabilities: [.windowManagement], risk: .navigate, route: .browserNative),
            descriptor("create_hidden_window", "Create a browser window for background automation.", properties: ["url": .string(description: "Optional URL for its focused page.")], capabilities: [.windowManagement], risk: .navigate, route: .browserNative),
            descriptor("close_window", "Close a browser window.", properties: ["windowId": window], required: ["windowId"], capabilities: [.windowManagement], risk: .navigate, route: .browserNative),
            descriptor("activate_window", "Bring a browser window to the front.", properties: ["windowId": window], required: ["windowId"], capabilities: [.windowManagement], risk: .navigate, route: .browserNative),

            // Tab groups (5)
            descriptor("list_tab_groups", "List tab groups and their member pages.", properties: ["windowId": window], capabilities: [.tabGroups], risk: .observe, route: .browserNative, builtIn: true),
            descriptor("group_tabs", "Create or reuse a group and place pages in it.", properties: ["windowId": window, "groupId": .string(description: "Existing group ID, if any."), "pageIds": strings("Pages to group."), "title": .string(description: "Group title."), "color": .string(description: "Hex color such as #007AFF.")], required: ["pageIds"], capabilities: [.tabGroups], risk: .mutateLocal, route: .browserNative, builtIn: true),
            descriptor("update_tab_group", "Update a tab group's title or color.", properties: ["windowId": window, "groupId": .string(description: "Group ID."), "title": .string(description: "New title."), "color": .string(description: "New hex color.")], required: ["groupId"], capabilities: [.tabGroups], risk: .mutateLocal, route: .browserNative),
            descriptor("ungroup_tabs", "Remove pages from their groups.", properties: ["windowId": window, "pageIds": strings("Pages to ungroup.")], required: ["pageIds"], capabilities: [.tabGroups], risk: .mutateLocal, route: .browserNative, builtIn: true),
            descriptor("close_tab_group", "Close every page in a group and remove the group.", properties: ["windowId": window, "groupId": .string(description: "Group ID.")], required: ["groupId"], capabilities: [.tabGroups], risk: .destructive, route: .browserNative),

            // Bookmarks (6)
            descriptor("get_bookmarks", "List bookmarks and bookmark folders.", capabilities: [.bookmarkRead], risk: .observe, route: .browserNative, builtIn: true),
            descriptor("create_bookmark", "Create a bookmark, or omit URL to create a folder.", properties: ["title": .string(description: "Bookmark or folder title."), "url": .string(description: "Bookmark URL."), "folder": .string(description: "Folder/category title.")], required: ["title"], capabilities: [.bookmarkWrite], risk: .mutateLocal, route: .browserNative, builtIn: true),
            descriptor("remove_bookmark", "Remove a bookmark or folder.", properties: ["id": .string(description: "Bookmark or folder ID.")], required: ["id"], capabilities: [.bookmarkWrite], risk: .destructive, route: .browserNative),
            descriptor("update_bookmark", "Update a bookmark title, URL, or folder.", properties: ["id": .string(description: "Bookmark ID."), "title": .string(description: "New title."), "url": .string(description: "New URL."), "folder": .string(description: "New folder/category.")], required: ["id"], capabilities: [.bookmarkWrite], risk: .mutateLocal, route: .browserNative),
            descriptor("move_bookmark", "Move a bookmark to a folder/category.", properties: ["id": .string(description: "Bookmark ID."), "folder": .string(description: "Destination folder/category.")], required: ["id"], capabilities: [.bookmarkWrite], risk: .mutateLocal, route: .browserNative),
            descriptor("search_bookmarks", "Search bookmarks by title, URL, host, or folder.", properties: ["query": .string(description: "Search query.")], required: ["query"], capabilities: [.bookmarkRead], risk: .observe, route: .browserNative, builtIn: true),

            // History (4)
            descriptor("search_history", "Fuzzy-search local browsing history.", properties: ["query": .string(description: "Search query."), "limit": .integer(description: "Maximum results.", minimum: 1)], required: ["query"], capabilities: [.historyRead], risk: .observe, route: .browserNative, builtIn: true),
            descriptor("get_recent_history", "Get recent unique history entries.", properties: ["limit": .integer(description: "Maximum results.", minimum: 1)], capabilities: [.historyRead], risk: .observe, route: .browserNative, builtIn: true),
            descriptor("delete_history_url", "Delete all history visits for a URL.", properties: ["url": .string(description: "URL to remove.")], required: ["url"], capabilities: [.historyWrite], risk: .destructive, route: .browserNative),
            descriptor("delete_history_range", "Delete history within an inclusive ISO-8601 date range.", properties: ["start": .string(description: "Optional ISO-8601 start."), "end": .string(description: "Optional ISO-8601 end.")], capabilities: [.historyWrite], risk: .destructive, route: .browserNative),

            // Built-in-only observable wait and Cowork tools.
            descriptor("wait_for", "Wait for an observable WebKit page condition without changing focus.", properties: [
                "pageId": page,
                "condition": .string(description: "Observable condition.", allowedValues: ["load", "url", "selector", "text", "elementState", "dialog", "downloadStarted", "downloadCompleted", "pageClosed"]),
                "value": .string(description: "Expected URL, selector, text, dialog kind, or semantic element reference."),
                "state": .string(description: "Element state for elementState waits.", allowedValues: ["visible", "enabled", "disabled", "checked", "selected", "expanded", "editable", "focused"]),
                "isPresent": .boolean(description: "Whether the requested element state must be present."),
                "downloadId": .string(description: "Optional download identifier."),
                "timeout": .number(description: "Required maximum timeout in seconds.", minimum: 0.1, maximum: 60),
            ], required: ["condition", "timeout"], capabilities: read, risk: .observe, route: .observableWait, builtIn: true, mcp: false),
            descriptor("workspace_info", "Show whether a cowork folder is available without exposing its absolute path.", capabilities: [.coworkRead], risk: .observe, route: .cowork, builtIn: true, origin: .cowork, mcp: false),
            descriptor("list_files", "List files inside the cowork folder.", properties: ["path": path, "recursive": .boolean(description: "Include descendants, capped by file-count and depth limits.")], capabilities: [.coworkRead], risk: .observe, route: .cowork, builtIn: true, origin: .cowork, mcp: false),
            descriptor("read_file", "Read a bounded UTF-8 text file from the cowork folder.", properties: ["path": path], required: ["path"], capabilities: [.coworkRead], risk: .observe, route: .cowork, builtIn: true, origin: .cowork, mcp: false),
            descriptor("write_file", "Create or update a UTF-8 text file in the cowork folder.", properties: ["path": path, "content": .string(description: "Text to write."), "append": .boolean(description: "Append instead of replacing.")], required: ["path", "content"], capabilities: [.coworkWrite], risk: .mutateLocal, route: .cowork, builtIn: true, origin: .cowork, mcp: false),
            descriptor("move_file", "Move or rename a file within the cowork folder.", properties: ["path": path, "destination": path], required: ["path", "destination"], capabilities: [.coworkWrite], risk: .mutateLocal, route: .cowork, builtIn: true, origin: .cowork, mcp: false),
            descriptor("delete_file", "Move a file to the macOS Trash so it remains recoverable.", properties: ["path": path], required: ["path"], capabilities: [.coworkWrite], risk: .destructive, route: .cowork, builtIn: true, origin: .cowork, mcp: false),
        ]
    }
}
