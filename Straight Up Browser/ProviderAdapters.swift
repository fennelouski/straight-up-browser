import Foundation

// Provider-specific dictionaries stop at this file. The run engine consumes
// only these Codable, Sendable values.

nonisolated enum AgentModelRole: String, Codable, Equatable, Sendable {
    case system
    case user
    case assistant
    case tool
}

nonisolated struct AgentModelImage: Codable, Equatable, Sendable {
    let url: URL
    let mediaType: String?

    init(url: URL, mediaType: String? = nil) {
        self.url = url
        self.mediaType = mediaType
    }
}

nonisolated struct AgentModelToolResult: Codable, Equatable, Sendable {
    let callID: String
    let toolName: String
    let content: JSONValue
    let isError: Bool

    init(callID: String, toolName: String, content: JSONValue, isError: Bool = false) {
        self.callID = callID
        self.toolName = toolName
        self.content = content
        self.isError = isError
    }
}

nonisolated struct AgentModelToolInvocation: Codable, Equatable, Sendable {
    let call: AgentToolCall
    let arguments: JSONValue

    init(call: AgentToolCall, arguments: JSONValue) {
        self.call = call
        self.arguments = arguments
    }
}

nonisolated enum AgentModelContentPart: Codable, Equatable, Sendable {
    case text(String)
    case image(AgentModelImage)
    case toolCall(AgentModelToolInvocation)
    case toolResult(AgentModelToolResult)
}

nonisolated struct AgentModelMessage: Codable, Equatable, Sendable {
    let role: AgentModelRole
    let content: [AgentModelContentPart]

    init(role: AgentModelRole, content: [AgentModelContentPart]) {
        self.role = role
        self.content = content
    }
}

nonisolated enum AgentModelResponseFormat: Codable, Equatable, Sendable {
    case jsonObject
    case jsonSchema(name: String, schema: JSONValue)
}

nonisolated enum AgentProviderCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case streaming
    case toolCalling
    case parallelToolCalls
    case imageInput
    case structuredOutput
    case usageReporting
    case reasoningControls
}

nonisolated struct AgentProviderCapabilities: Codable, Equatable, Sendable {
    let supported: Set<AgentProviderCapability>

    init(_ supported: Set<AgentProviderCapability>) {
        self.supported = supported
    }

    func supports(_ capability: AgentProviderCapability) -> Bool {
        supported.contains(capability)
    }
}

nonisolated struct AgentModelRequest: Codable, Equatable, Sendable {
    let id: UUID
    let model: String
    let messages: [AgentModelMessage]
    let tools: [AgentToolDescriptor]
    let temperature: Double?
    let maxOutputTokens: Int?
    let reasoningEffort: String?
    let responseFormat: AgentModelResponseFormat?
    let allowParallelToolCalls: Bool
    let additionalRequiredCapabilities: Set<AgentProviderCapability>

    init(
        id: UUID = UUID(),
        model: String,
        messages: [AgentModelMessage],
        tools: [AgentToolDescriptor] = [],
        temperature: Double? = nil,
        maxOutputTokens: Int? = nil,
        reasoningEffort: String? = nil,
        responseFormat: AgentModelResponseFormat? = nil,
        allowParallelToolCalls: Bool = false,
        additionalRequiredCapabilities: Set<AgentProviderCapability> = []
    ) {
        self.id = id
        self.model = model
        self.messages = messages
        self.tools = tools
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.reasoningEffort = reasoningEffort
        self.responseFormat = responseFormat
        self.allowParallelToolCalls = allowParallelToolCalls
        self.additionalRequiredCapabilities = additionalRequiredCapabilities
    }

    var requiredCapabilities: Set<AgentProviderCapability> {
        var required = additionalRequiredCapabilities
        required.insert(.streaming)
        if !tools.isEmpty { required.insert(.toolCalling) }
        if messages.contains(where: { message in
            message.content.contains { part in
                if case .toolCall = part { return true }
                return false
            }
        }) {
            required.insert(.toolCalling)
        }
        if allowParallelToolCalls { required.insert(.parallelToolCalls) }
        if messages.contains(where: { message in
            message.content.contains { part in
                if case .image = part { return true }
                return false
            }
        }) {
            required.insert(.imageInput)
        }
        if responseFormat != nil { required.insert(.structuredOutput) }
        if reasoningEffort != nil { required.insert(.reasoningControls) }
        return required
    }
}

nonisolated enum AgentModelFinishReason: Codable, Equatable, Sendable {
    case stop
    case toolCalls
    case length
    case contentFilter
    case cancelled
    case error
    case other(String)
}

nonisolated enum AgentModelUsage: Codable, Equatable, Sendable {
    case reported(
        inputTokens: Int?,
        outputTokens: Int?,
        totalTokens: Int?,
        cachedInputTokens: Int?
    )
    case unknown
}

nonisolated enum AgentToolArguments: Codable, Equatable, Sendable {
    case valid(JSONValue)
    case malformed(raw: String, reason: String)
}

nonisolated struct AgentToolCall: Codable, Equatable, Sendable {
    let id: String
    let index: Int
    let name: String

    init(id: String, index: Int, name: String) {
        self.id = id
        self.index = index
        self.name = name
    }
}

nonisolated struct AgentProviderWarning: Codable, Equatable, Sendable {
    let code: String
    let message: String
}

nonisolated enum AgentModelEvent: Codable, Equatable, Sendable {
    case responseStarted(id: String?)
    case textDelta(String)
    case toolCallStarted(AgentToolCall)
    case toolCallArgumentsDelta(id: String, delta: String)
    case toolCallCompleted(call: AgentToolCall, arguments: AgentToolArguments)
    case usage(AgentModelUsage)
    case warning(AgentProviderWarning)
    case finished(AgentModelFinishReason)
}

nonisolated enum AgentProviderRetryClassification: Codable, Equatable, Sendable {
    case transient
    case rateLimited(retryAfter: TimeInterval?)
    case permanent
}

nonisolated enum AgentProviderRetryDecision: Codable, Equatable, Sendable {
    case retry(after: TimeInterval?)
    case doNotRetry
}

nonisolated struct AgentProviderRetryPolicy: Codable, Equatable, Sendable {
    let maximumAttempts: Int

    init(maximumAttempts: Int = 2) {
        self.maximumAttempts = max(1, maximumAttempts)
    }

    func decision(
        for classification: AgentProviderRetryClassification,
        attempt: Int,
        hasCommittedSideEffect: Bool
    ) -> AgentProviderRetryDecision {
        guard !hasCommittedSideEffect, attempt < maximumAttempts else { return .doNotRetry }
        switch classification {
        case .transient:
            return .retry(after: nil)
        case .rateLimited(let retryAfter):
            return .retry(after: retryAfter)
        case .permanent:
            return .doNotRetry
        }
    }
}

nonisolated struct AgentProviderAdapterError: Error, Equatable, Sendable {
    enum Code: String, Codable, Equatable, Sendable {
        case invalidRequest
        case unsupportedCapabilities
        case malformedStream
        case authentication
        case rateLimited
        case serviceUnavailable
        case transport
        case scriptedFailure
    }

    let providerID: String
    let code: Code
    let safeMessage: String
    let retryClassification: AgentProviderRetryClassification

    static func unsupportedCapabilities(
        providerID: String,
        capabilities: Set<AgentProviderCapability>
    ) -> AgentProviderAdapterError {
        let names = capabilities.map(\.rawValue).sorted().joined(separator: ", ")
        return AgentProviderAdapterError(
            providerID: providerID,
            code: .unsupportedCapabilities,
            safeMessage: "\(providerID) does not support: \(names).",
            retryClassification: .permanent
        )
    }

    static func malformedStream(providerID: String) -> AgentProviderAdapterError {
        AgentProviderAdapterError(
            providerID: providerID,
            code: .malformedStream,
            safeMessage: "\(providerID) returned malformed streaming data.",
            retryClassification: .permanent
        )
    }

    static func invalidRequest(providerID: String, message: String) -> AgentProviderAdapterError {
        AgentProviderAdapterError(
            providerID: providerID,
            code: .invalidRequest,
            safeMessage: message,
            retryClassification: .permanent
        )
    }

    static func httpStatus(
        providerID: String,
        statusCode: Int,
        retryAfter: TimeInterval? = nil,
        untrustedResponseBody: String? = nil,
        sentRequestFields: [String] = []
    ) -> AgentProviderAdapterError {
        let code: Code
        let retry: AgentProviderRetryClassification
        switch statusCode {
        case 401, 403:
            code = .authentication
            retry = .permanent
        case 429:
            code = .rateLimited
            retry = .rateLimited(retryAfter: retryAfter)
        case 500...599:
            code = .serviceUnavailable
            retry = .transient
        default:
            code = .transport
            retry = .permanent
        }
        let providerDetail = providerErrorDetail(from: untrustedResponseBody)
        let detail = [
            providerDetail.code.map { "Provider code: \($0)." },
            providerDetail.parameter.map { "Parameter: \($0)." },
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        let requestAudit = sentRequestFields.isEmpty
            ? ""
            : " Request fields: \(sentRequestFields.joined(separator: ", "))."
        return AgentProviderAdapterError(
            providerID: providerID,
            code: code,
            safeMessage: "\(providerID) request failed with HTTP \(statusCode)."
                + (detail.isEmpty ? "" : " \(detail)")
                + requestAudit,
            retryClassification: retry
        )
    }

    /// Server messages can echo prompt or account data. Surface only short,
    /// machine-readable code and parameter fields so the UI helps diagnose a
    /// request without retaining untrusted response text.
    private static func providerErrorDetail(from body: String?) -> (code: String?, parameter: String?) {
        guard let body,
              let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return (nil, nil) }
        let code = safeMachineValue(
            (error["code"] as? String) ?? (error["type"] as? String),
            allowed: "_-."
        )
        let parameter = safeMachineValue(
            error["param"] as? String,
            allowed: "_-.[]"
        )
        return (code, parameter)
    }

    private static func safeMachineValue(_ raw: String?, allowed: String) -> String? {
        guard let raw, raw.count <= 120 else { return nil }
        let permitted = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: allowed))
        guard raw.unicodeScalars.allSatisfy({ permitted.contains($0) }) else {
            return nil
        }
        return raw
    }
}

extension AgentProviderAdapterError: LocalizedError {
    nonisolated var errorDescription: String? { safeMessage }
}

nonisolated protocol AgentProviderAdapter: Sendable {
    var providerID: String { get }
    var capabilities: AgentProviderCapabilities { get }
    func events(
        for request: AgentModelRequest
    ) throws -> AsyncThrowingStream<AgentModelEvent, Error>
}

nonisolated extension AgentProviderAdapter {
    func validateCapabilities(for request: AgentModelRequest) throws {
        let missing = request.requiredCapabilities.subtracting(capabilities.supported)
        guard missing.isEmpty else {
            throw AgentProviderAdapterError.unsupportedCapabilities(
                providerID: providerID,
                capabilities: missing
            )
        }
    }
}

nonisolated enum ScriptedAgentProviderItem: Sendable {
    case event(AgentModelEvent)
    case delay(nanoseconds: UInt64)
    case failure(AgentProviderAdapterError)
}

nonisolated struct ScriptedAgentProviderAdapter: AgentProviderAdapter {
    let providerID: String
    let capabilities: AgentProviderCapabilities
    let script: [ScriptedAgentProviderItem]

    init(
        providerID: String = "scripted",
        capabilities: AgentProviderCapabilities = AgentProviderCapabilities(
            Set(AgentProviderCapability.allCases)
        ),
        script: [ScriptedAgentProviderItem]
    ) {
        self.providerID = providerID
        self.capabilities = capabilities
        self.script = script
    }

    func events(
        for request: AgentModelRequest
    ) throws -> AsyncThrowingStream<AgentModelEvent, Error> {
        try validateCapabilities(for: request)
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    for item in script {
                        try Task.checkCancellation()
                        switch item {
                        case .event(let event):
                            continuation.yield(event)
                        case .delay(let nanoseconds):
                            try await Task.sleep(nanoseconds: nanoseconds)
                        case .failure(let error):
                            throw error
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }
}

// MARK: - Provider wire frames

nonisolated struct AgentProviderStreamFrame: Equatable, Sendable {
    let event: String?
    let data: String

    init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }
}

nonisolated struct AgentSSEDecoder: Sendable {
    private var buffer = Data()

    init() {}

    mutating func append(_ data: Data) throws -> [AgentProviderStreamFrame] {
        buffer.append(data)
        var frames: [AgentProviderStreamFrame] = []
        while let boundary = nextBoundary() {
            let eventData = buffer.subdata(in: buffer.startIndex..<boundary.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<boundary.upperBound)
            if let frame = try parseEvent(eventData) { frames.append(frame) }
        }
        return frames
    }

    mutating func finish() throws -> [AgentProviderStreamFrame] {
        guard !buffer.isEmpty else { return [] }
        let remaining = buffer
        buffer.removeAll(keepingCapacity: false)
        return try parseEvent(remaining).map { [$0] } ?? []
    }

    private func nextBoundary() -> Range<Data.Index>? {
        let lf = buffer.range(of: Data([0x0A, 0x0A]))
        let crlf = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A]))
        return switch (lf, crlf) {
        case (.none, .none): nil
        case (.some(let range), .none), (.none, .some(let range)): range
        case (.some(let left), .some(let right)):
            left.lowerBound < right.lowerBound ? left : right
        }
    }

    private func parseEvent(_ data: Data) throws -> AgentProviderStreamFrame? {
        guard let string = String(data: data, encoding: .utf8) else {
            throw AgentProviderAdapterError.malformedStream(providerID: "sse")
        }
        let normalized = string.replacingOccurrences(of: "\r\n", with: "\n")
        var event: String?
        var dataLines: [String] = []
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard !line.isEmpty, !line.hasPrefix(":") else { continue }
            let field: String
            var value: String
            if let colon = line.firstIndex(of: ":") {
                field = String(line[..<colon])
                value = String(line[line.index(after: colon)...])
                if value.first == " " { value.removeFirst() }
            } else {
                field = line
                value = ""
            }
            switch field {
            case "event": event = value
            case "data": dataLines.append(value)
            default: continue
            }
        }
        guard !dataLines.isEmpty else { return nil }
        return AgentProviderStreamFrame(event: event, data: dataLines.joined(separator: "\n"))
    }
}

private nonisolated struct PendingAgentToolCall: Sendable {
    var id: String
    var index: Int
    var name: String
    var arguments = ""
    var didEmitStart = false

    var call: AgentToolCall { AgentToolCall(id: id, index: index, name: name) }
}

private nonisolated func decodedJSONObject(
    _ text: String,
    providerID: String
) throws -> [String: Any] {
    guard let data = text.data(using: .utf8) else {
        throw AgentProviderAdapterError.malformedStream(providerID: providerID)
    }
    do {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentProviderAdapterError.malformedStream(providerID: providerID)
        }
        return object
    } catch let error as AgentProviderAdapterError {
        throw error
    } catch {
        throw AgentProviderAdapterError.malformedStream(providerID: providerID)
    }
}

private nonisolated func normalizedToolArguments(_ raw: String) -> AgentToolArguments {
    let source = raw.isEmpty ? "{}" : raw
    guard let data = source.data(using: .utf8) else {
        return .malformed(raw: raw, reason: "Tool arguments were not valid UTF-8 JSON.")
    }
    do {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return .valid(try JSONValue(foundationValue: object))
    } catch {
        return .malformed(raw: raw, reason: "Tool arguments were not valid JSON.")
    }
}

private nonisolated func integer(_ value: Any?) -> Int? {
    (value as? NSNumber)?.intValue
}

private nonisolated func finishReason(_ raw: String?) -> AgentModelFinishReason? {
    guard let raw else { return nil }
    return switch raw.lowercased() {
    case "stop", "end_turn", "completed": .stop
    case "tool_calls", "tool_use": .toolCalls
    case "length", "max_tokens", "max_tokens_exceeded": .length
    case "content_filter", "safety", "blocked": .contentFilter
    case "cancelled", "canceled": .cancelled
    case "error", "failed": .error
    default: .other(raw)
    }
}

// Stateful because OpenAI-compatible APIs split one function call's JSON
// arguments over an arbitrary number of SSE frames.
nonisolated struct OpenAICompatibleChatStreamParser: Sendable {
    private var didEmitResponseStart = false
    private var didFinish = false
    private var pendingFinishReason: AgentModelFinishReason?
    private var pendingUsage: AgentModelUsage?
    private var toolCalls: [Int: PendingAgentToolCall] = [:]

    init() {}

    mutating func consume(_ frame: AgentProviderStreamFrame) throws -> [AgentModelEvent] {
        guard !didFinish else { return [] }
        if frame.data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            return finishStream()
        }

        let object = try decodedJSONObject(frame.data, providerID: "openai-compatible-chat")
        var events: [AgentModelEvent] = []
        if !didEmitResponseStart, let responseID = object["id"] as? String {
            didEmitResponseStart = true
            events.append(.responseStarted(id: responseID))
        }

        if let usage = object["usage"] as? [String: Any] {
            pendingUsage = .reported(
                inputTokens: integer(usage["prompt_tokens"]),
                outputTokens: integer(usage["completion_tokens"]),
                totalTokens: integer(usage["total_tokens"]),
                cachedInputTokens: integer(
                    (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"]
                )
            )
        }

        for choice in object["choices"] as? [[String: Any]] ?? [] {
            if let delta = choice["delta"] as? [String: Any] {
                if let text = delta["content"] as? String, !text.isEmpty {
                    events.append(.textDelta(text))
                }
                for toolDelta in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let index = integer(toolDelta["index"]) ?? 0
                    let function = toolDelta["function"] as? [String: Any]
                    var pending = toolCalls[index] ?? PendingAgentToolCall(
                        id: toolDelta["id"] as? String ?? "chat-tool-\(index)",
                        index: index,
                        name: function?["name"] as? String ?? "unknown_tool"
                    )
                    if let id = toolDelta["id"] as? String { pending.id = id }
                    if let name = function?["name"] as? String { pending.name = name }
                    if !pending.didEmitStart {
                        events.append(.toolCallStarted(pending.call))
                        pending.didEmitStart = true
                    }
                    if let argumentsDelta = function?["arguments"] as? String,
                       !argumentsDelta.isEmpty {
                        pending.arguments += argumentsDelta
                        events.append(.toolCallArgumentsDelta(
                            id: pending.id,
                            delta: argumentsDelta
                        ))
                    }
                    toolCalls[index] = pending
                }
            }
            if let reason = finishReason(choice["finish_reason"] as? String) {
                pendingFinishReason = reason
            }
        }
        return events
    }

    mutating func finish() -> [AgentModelEvent] {
        guard !didFinish else { return [] }
        return finishStream()
    }

    private mutating func finishStream() -> [AgentModelEvent] {
        didFinish = true
        var events = toolCalls.values
            .sorted { $0.index < $1.index }
            .map { pending in
                AgentModelEvent.toolCallCompleted(
                    call: pending.call,
                    arguments: normalizedToolArguments(pending.arguments)
                )
            }
        events.append(.usage(pendingUsage ?? .unknown))
        events.append(.finished(pendingFinishReason ?? (toolCalls.isEmpty ? .stop : .toolCalls)))
        return events
    }
}

nonisolated struct OpenAICompatibleChatRequestBuilder: Sendable {
    let capabilities = AgentProviderCapabilities([
        .streaming, .toolCalling, .parallelToolCalls, .imageInput,
        .structuredOutput, .usageReporting,
    ])

    init() {}

    func makeBody(for request: AgentModelRequest) throws -> JSONValue {
        let providerID = "openai-compatible-chat"
        let missing = request.requiredCapabilities.subtracting(capabilities.supported)
        guard missing.isEmpty else {
            throw AgentProviderAdapterError.unsupportedCapabilities(
                providerID: providerID,
                capabilities: missing
            )
        }
        guard !request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentProviderAdapterError.invalidRequest(
                providerID: providerID,
                message: "A model is required for OpenAI-compatible Chat Completions."
            )
        }

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "stream": .boolean(true),
            "stream_options": .object(["include_usage": .boolean(true)]),
            "messages": .array(try request.messages.flatMap(chatMessages)),
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { descriptor in
                .object([
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(descriptor.name),
                        "description": .string(descriptor.description),
                        "parameters": descriptor.inputSchema.jsonValue,
                    ]),
                ])
            })
            body["tool_choice"] = .string("auto")
            body["parallel_tool_calls"] = .boolean(request.allowParallelToolCalls)
        }
        if let temperature = request.temperature { body["temperature"] = .number(temperature) }
        if let maxOutputTokens = request.maxOutputTokens {
            body["max_tokens"] = .number(Double(maxOutputTokens))
        }
        if let responseFormat = request.responseFormat {
            body["response_format"] = chatResponseFormat(responseFormat)
        }
        return .object(body)
    }

    private func chatMessages(_ message: AgentModelMessage) throws -> [JSONValue] {
        let role = message.role.rawValue
        if message.role == .tool {
            return try message.content.map { part in
                guard case .toolResult(let result) = part else {
                    throw AgentProviderAdapterError.invalidRequest(
                        providerID: "openai-compatible-chat",
                        message: "Tool messages may contain only tool results."
                    )
                }
                return .object([
                    "role": .string("tool"),
                    "tool_call_id": .string(result.callID),
                    "content": .string(try compactJSONString(result.content)),
                ])
            }
        }

        let invocations = message.content.compactMap { part -> AgentModelToolInvocation? in
            if case .toolCall(let invocation) = part { return invocation }
            return nil
        }
        if !invocations.isEmpty {
            guard message.role == .assistant else {
                throw AgentProviderAdapterError.invalidRequest(
                    providerID: "openai-compatible-chat",
                    message: "Only assistant messages may contain tool calls."
                )
            }
            let text = message.content.compactMap { part -> String? in
                if case .text(let value) = part { return value }
                return nil
            }.joined()
            let hasUnsupportedPart = message.content.contains { part in
                switch part {
                case .text, .toolCall: false
                case .image, .toolResult: true
                }
            }
            guard !hasUnsupportedPart else {
                throw AgentProviderAdapterError.invalidRequest(
                    providerID: "openai-compatible-chat",
                    message: "An assistant tool-call message contains unsupported content."
                )
            }
            return [.object([
                "role": .string("assistant"),
                "content": text.isEmpty ? .null : .string(text),
                "tool_calls": .array(try invocations.map { invocation in
                    .object([
                        "id": .string(invocation.call.id),
                        "type": .string("function"),
                        "function": .object([
                            "name": .string(invocation.call.name),
                            "arguments": .string(try compactJSONString(invocation.arguments)),
                        ]),
                    ])
                }),
            ])]
        }

        let hasImage = message.content.contains { part in
            if case .image = part { return true }
            return false
        }
        if !hasImage {
            let texts = try message.content.map { part -> String in
                guard case .text(let text) = part else {
                    throw AgentProviderAdapterError.invalidRequest(
                        providerID: "openai-compatible-chat",
                        message: "A non-tool message contains an unsupported content part."
                    )
                }
                return text
            }
            return [.object([
                "role": .string(role),
                "content": .string(texts.joined()),
            ])]
        }

        let parts = try message.content.map { part -> JSONValue in
            switch part {
            case .text(let text):
                return .object(["type": .string("text"), "text": .string(text)])
            case .image(let image):
                return .object([
                    "type": .string("image_url"),
                    "image_url": .object(["url": .string(image.url.absoluteString)]),
                ])
            case .toolResult:
                throw AgentProviderAdapterError.invalidRequest(
                    providerID: "openai-compatible-chat",
                    message: "Tool results require a tool-role message."
                )
            case .toolCall:
                throw AgentProviderAdapterError.invalidRequest(
                    providerID: "openai-compatible-chat",
                    message: "Tool calls require an assistant tool-call message."
                )
            }
        }
        return [.object(["role": .string(role), "content": .array(parts)])]
    }

    private func chatResponseFormat(_ format: AgentModelResponseFormat) -> JSONValue {
        switch format {
        case .jsonObject:
            .object(["type": .string("json_object")])
        case .jsonSchema(let name, let schema):
            .object([
                "type": .string("json_schema"),
                "json_schema": .object([
                    "name": .string(name),
                    "schema": schema,
                ]),
            ])
        }
    }
}

private nonisolated func compactJSONString(_ value: JSONValue) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value.foundationValue, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Native OpenAI Responses

nonisolated struct OpenAIResponsesStreamParser: Sendable {
    private var toolCallsByItemID: [String: PendingAgentToolCall] = [:]
    private var completedItemIDs: Set<String> = []
    private var sawToolCall = false
    private var didFinish = false

    init() {}

    mutating func consume(_ frame: AgentProviderStreamFrame) throws -> [AgentModelEvent] {
        guard !didFinish else { return [] }
        let object = try decodedJSONObject(frame.data, providerID: "openai-responses")
        let type = object["type"] as? String ?? frame.event ?? ""
        switch type {
        case "response.created":
            let response = object["response"] as? [String: Any]
            return [.responseStarted(id: response?["id"] as? String)]

        case "response.output_text.delta":
            guard let delta = object["delta"] as? String, !delta.isEmpty else { return [] }
            return [.textDelta(delta)]

        case "response.output_item.added":
            guard let item = object["item"] as? [String: Any],
                  item["type"] as? String == "function_call" else { return [] }
            let itemID = item["id"] as? String ?? "response-item-\(integer(object["output_index"]) ?? 0)"
            let index = integer(object["output_index"]) ?? 0
            var pending = PendingAgentToolCall(
                id: item["call_id"] as? String ?? itemID,
                index: index,
                name: item["name"] as? String ?? "unknown_tool",
                arguments: item["arguments"] as? String ?? ""
            )
            pending.didEmitStart = true
            toolCallsByItemID[itemID] = pending
            sawToolCall = true
            var events: [AgentModelEvent] = [.toolCallStarted(pending.call)]
            if !pending.arguments.isEmpty {
                events.append(.toolCallArgumentsDelta(id: pending.id, delta: pending.arguments))
            }
            return events

        case "response.function_call_arguments.delta":
            let itemID = object["item_id"] as? String
                ?? "response-item-\(integer(object["output_index"]) ?? 0)"
            let index = integer(object["output_index"]) ?? 0
            let delta = object["delta"] as? String ?? ""
            var pending = toolCallsByItemID[itemID] ?? PendingAgentToolCall(
                id: object["call_id"] as? String ?? itemID,
                index: index,
                name: object["name"] as? String ?? "unknown_tool"
            )
            var events: [AgentModelEvent] = []
            if !pending.didEmitStart {
                pending.didEmitStart = true
                events.append(.toolCallStarted(pending.call))
            }
            if !delta.isEmpty {
                pending.arguments += delta
                events.append(.toolCallArgumentsDelta(id: pending.id, delta: delta))
            }
            toolCallsByItemID[itemID] = pending
            sawToolCall = true
            return events

        case "response.function_call_arguments.done":
            let itemID = object["item_id"] as? String
                ?? "response-item-\(integer(object["output_index"]) ?? 0)"
            guard !completedItemIDs.contains(itemID) else { return [] }
            let index = integer(object["output_index"]) ?? 0
            var pending = toolCallsByItemID[itemID] ?? PendingAgentToolCall(
                id: object["call_id"] as? String ?? itemID,
                index: index,
                name: object["name"] as? String ?? "unknown_tool"
            )
            if let completeArguments = object["arguments"] as? String {
                pending.arguments = completeArguments
            }
            completedItemIDs.insert(itemID)
            toolCallsByItemID[itemID] = pending
            sawToolCall = true
            return [.toolCallCompleted(
                call: pending.call,
                arguments: normalizedToolArguments(pending.arguments)
            )]

        case "response.completed", "response.incomplete", "response.cancelled":
            didFinish = true
            let response = object["response"] as? [String: Any] ?? object
            let usageObject = response["usage"] as? [String: Any]
            let usage: AgentModelUsage = usageObject.map { usage in
                .reported(
                    inputTokens: integer(usage["input_tokens"]),
                    outputTokens: integer(usage["output_tokens"]),
                    totalTokens: integer(usage["total_tokens"]),
                    cachedInputTokens: integer(
                        (usage["input_tokens_details"] as? [String: Any])?["cached_tokens"]
                    )
                )
            } ?? .unknown
            let reason: AgentModelFinishReason
            if type == "response.cancelled" {
                reason = .cancelled
            } else if type == "response.incomplete" || response["status"] as? String == "incomplete" {
                reason = .length
            } else {
                reason = sawToolCall ? .toolCalls : .stop
            }
            var events = flushUnfinishedTools()
            events.append(.usage(usage))
            events.append(.finished(reason))
            return events

        case "response.failed", "error":
            didFinish = true
            throw AgentProviderAdapterError(
                providerID: "openai-responses",
                code: .transport,
                safeMessage: "OpenAI Responses streaming failed.",
                retryClassification: .permanent
            )

        default:
            return []
        }
    }

    mutating func finish() -> [AgentModelEvent] {
        guard !didFinish else { return [] }
        didFinish = true
        var events = flushUnfinishedTools()
        events.append(.usage(.unknown))
        events.append(.finished(sawToolCall ? .toolCalls : .stop))
        return events
    }

    private mutating func flushUnfinishedTools() -> [AgentModelEvent] {
        let pending = toolCallsByItemID
            .filter { !completedItemIDs.contains($0.key) }
            .sorted { $0.value.index < $1.value.index }
        for (itemID, _) in pending { completedItemIDs.insert(itemID) }
        return pending.map { _, call in
            .toolCallCompleted(
                call: call.call,
                arguments: normalizedToolArguments(call.arguments)
            )
        }
    }
}

nonisolated struct OpenAIResponsesRequestBuilder: Sendable {
    let capabilities = AgentProviderCapabilities(Set(AgentProviderCapability.allCases))

    init() {}

    func makeBody(for request: AgentModelRequest) throws -> JSONValue {
        let providerID = "openai-responses"
        let missing = request.requiredCapabilities.subtracting(capabilities.supported)
        guard missing.isEmpty else {
            throw AgentProviderAdapterError.unsupportedCapabilities(
                providerID: providerID,
                capabilities: missing
            )
        }
        guard !request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentProviderAdapterError.invalidRequest(
                providerID: providerID,
                message: "A model is required for OpenAI Responses."
            )
        }

        let instructions = request.messages
            .filter { $0.role == .system }
            .flatMap(\.content)
            .compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }
            .joined(separator: "\n\n")

        var input: [JSONValue] = []
        for message in request.messages where message.role != .system {
            if message.role == .tool {
                for part in message.content {
                    guard case .toolResult(let result) = part else {
                        throw AgentProviderAdapterError.invalidRequest(
                            providerID: providerID,
                            message: "Tool messages may contain only tool results."
                        )
                    }
                    input.append(.object([
                        "type": .string("function_call_output"),
                        "call_id": .string(result.callID),
                        "output": .string(try compactJSONString(result.content)),
                    ]))
                }
                continue
            }
            for part in message.content {
                guard case .toolCall(let invocation) = part else { continue }
                guard message.role == .assistant else {
                    throw AgentProviderAdapterError.invalidRequest(
                        providerID: providerID,
                        message: "Only assistant messages may contain tool calls."
                    )
                }
                input.append(.object([
                    "type": .string("function_call"),
                    "call_id": .string(invocation.call.id),
                    "name": .string(invocation.call.name),
                    "arguments": .string(try compactJSONString(invocation.arguments)),
                ]))
            }
            let content = try message.content.compactMap { part -> JSONValue? in
                switch part {
                case .text(let text):
                    return .object([
                        "type": .string(message.role == .assistant ? "output_text" : "input_text"),
                        "text": .string(text),
                    ])
                case .image(let image):
                    return .object([
                        "type": .string("input_image"),
                        "image_url": .string(image.url.absoluteString),
                    ])
                case .toolResult:
                    throw AgentProviderAdapterError.invalidRequest(
                        providerID: providerID,
                        message: "Tool results require a tool-role message."
                    )
                case .toolCall:
                    return nil
                }
            }
            if !content.isEmpty {
                input.append(.object([
                    "role": .string(message.role.rawValue),
                    "content": .array(content),
                ]))
            }
        }

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "stream": .boolean(true),
            "input": .array(input),
        ]
        if !instructions.isEmpty { body["instructions"] = .string(instructions) }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { descriptor in
                .object([
                    "type": .string("function"),
                    "name": .string(descriptor.name),
                    "description": .string(descriptor.description),
                    "parameters": descriptor.inputSchema.jsonValue,
                    "strict": .boolean(false),
                ])
            })
            body["parallel_tool_calls"] = .boolean(request.allowParallelToolCalls)
        }
        if let temperature = request.temperature { body["temperature"] = .number(temperature) }
        if let maxOutputTokens = request.maxOutputTokens {
            body["max_output_tokens"] = .number(Double(maxOutputTokens))
        }
        if let reasoningEffort = request.reasoningEffort {
            body["reasoning"] = .object(["effort": .string(reasoningEffort)])
        }
        if let responseFormat = request.responseFormat {
            body["text"] = .object(["format": responsesFormat(responseFormat)])
        }
        return .object(body)
    }

    private func responsesFormat(_ format: AgentModelResponseFormat) -> JSONValue {
        switch format {
        case .jsonObject:
            .object(["type": .string("json_object")])
        case .jsonSchema(let name, let schema):
            .object([
                "type": .string("json_schema"),
                "name": .string(name),
                "schema": schema,
                "strict": .boolean(false),
            ])
        }
    }
}

// MARK: - Anthropic Messages

nonisolated struct AnthropicMessagesStreamParser: Sendable {
    private var toolCalls: [Int: PendingAgentToolCall] = [:]
    private var completedToolIndexes: Set<Int> = []
    private var inputTokens: Int?
    private var outputTokens: Int?
    private var cachedInputTokens: Int?
    private var pendingFinishReason: AgentModelFinishReason?
    private var didFinish = false

    init() {}

    mutating func consume(_ frame: AgentProviderStreamFrame) throws -> [AgentModelEvent] {
        guard !didFinish else { return [] }
        let object = try decodedJSONObject(frame.data, providerID: "anthropic-messages")
        let type = object["type"] as? String ?? frame.event ?? ""
        switch type {
        case "message_start":
            let message = object["message"] as? [String: Any]
            if let usage = message?["usage"] as? [String: Any] {
                inputTokens = integer(usage["input_tokens"])
                cachedInputTokens = integer(usage["cache_read_input_tokens"])
            }
            return [.responseStarted(id: message?["id"] as? String)]

        case "content_block_start":
            guard let block = object["content_block"] as? [String: Any],
                  block["type"] as? String == "tool_use" else { return [] }
            let index = integer(object["index"]) ?? 0
            var pending = PendingAgentToolCall(
                id: block["id"] as? String ?? "anthropic-tool-\(index)",
                index: index,
                name: block["name"] as? String ?? "unknown_tool"
            )
            pending.didEmitStart = true
            if let input = block["input"] as? [String: Any], !input.isEmpty,
               let value = try? JSONValue(foundationValue: input),
               let encoded = try? compactJSONString(value) {
                pending.arguments = encoded
            }
            toolCalls[index] = pending
            var events: [AgentModelEvent] = [.toolCallStarted(pending.call)]
            if !pending.arguments.isEmpty {
                events.append(.toolCallArgumentsDelta(id: pending.id, delta: pending.arguments))
            }
            return events

        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "text_delta":
                guard let text = delta["text"] as? String, !text.isEmpty else { return [] }
                return [.textDelta(text)]
            case "input_json_delta":
                let index = integer(object["index"]) ?? 0
                let fragment = delta["partial_json"] as? String ?? ""
                var pending = toolCalls[index] ?? PendingAgentToolCall(
                    id: "anthropic-tool-\(index)",
                    index: index,
                    name: "unknown_tool"
                )
                var events: [AgentModelEvent] = []
                if !pending.didEmitStart {
                    pending.didEmitStart = true
                    events.append(.toolCallStarted(pending.call))
                }
                if !fragment.isEmpty {
                    pending.arguments += fragment
                    events.append(.toolCallArgumentsDelta(id: pending.id, delta: fragment))
                }
                toolCalls[index] = pending
                return events
            default:
                return []
            }

        case "content_block_stop":
            let index = integer(object["index"]) ?? 0
            guard let pending = toolCalls[index], !completedToolIndexes.contains(index) else { return [] }
            completedToolIndexes.insert(index)
            return [.toolCallCompleted(
                call: pending.call,
                arguments: normalizedToolArguments(pending.arguments)
            )]

        case "message_delta":
            if let usage = object["usage"] as? [String: Any] {
                outputTokens = integer(usage["output_tokens"])
                if inputTokens == nil { inputTokens = integer(usage["input_tokens"]) }
            }
            if let delta = object["delta"] as? [String: Any] {
                pendingFinishReason = finishReason(delta["stop_reason"] as? String)
            }
            didFinish = true
            var events = flushUnfinishedTools()
            events.append(.usage(currentUsage()))
            events.append(.finished(pendingFinishReason ?? (toolCalls.isEmpty ? .stop : .toolCalls)))
            return events

        case "message_stop":
            didFinish = true
            var events = flushUnfinishedTools()
            events.append(.usage(currentUsage()))
            events.append(.finished(pendingFinishReason ?? (toolCalls.isEmpty ? .stop : .toolCalls)))
            return events

        case "error":
            didFinish = true
            throw AgentProviderAdapterError(
                providerID: "anthropic-messages",
                code: .transport,
                safeMessage: "Anthropic Messages streaming failed.",
                retryClassification: .permanent
            )

        default:
            return []
        }
    }

    mutating func finish() -> [AgentModelEvent] {
        guard !didFinish else { return [] }
        didFinish = true
        var events = flushUnfinishedTools()
        events.append(.usage(currentUsage()))
        events.append(.finished(pendingFinishReason ?? (toolCalls.isEmpty ? .stop : .toolCalls)))
        return events
    }

    private func currentUsage() -> AgentModelUsage {
        guard inputTokens != nil || outputTokens != nil else { return .unknown }
        let total = inputTokens.flatMap { input in outputTokens.map { input + $0 } }
        return .reported(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalTokens: total,
            cachedInputTokens: cachedInputTokens
        )
    }

    private mutating func flushUnfinishedTools() -> [AgentModelEvent] {
        let pending = toolCalls
            .filter { !completedToolIndexes.contains($0.key) }
            .sorted { $0.key < $1.key }
        for (index, _) in pending { completedToolIndexes.insert(index) }
        return pending.map { _, call in
            .toolCallCompleted(
                call: call.call,
                arguments: normalizedToolArguments(call.arguments)
            )
        }
    }
}

nonisolated struct AnthropicMessagesRequestBuilder: Sendable {
    let capabilities = AgentProviderCapabilities([
        .streaming, .toolCalling, .parallelToolCalls, .imageInput, .usageReporting,
    ])

    init() {}

    func makeBody(for request: AgentModelRequest) throws -> JSONValue {
        let providerID = "anthropic-messages"
        let missing = request.requiredCapabilities.subtracting(capabilities.supported)
        guard missing.isEmpty else {
            throw AgentProviderAdapterError.unsupportedCapabilities(
                providerID: providerID,
                capabilities: missing
            )
        }
        guard !request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentProviderAdapterError.invalidRequest(
                providerID: providerID,
                message: "A model is required for Anthropic Messages."
            )
        }

        let system = request.messages
            .filter { $0.role == .system }
            .flatMap(\.content)
            .compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }
            .joined(separator: "\n\n")
        var messages: [JSONValue] = []
        for message in request.messages where message.role != .system {
            let role = message.role == .assistant ? "assistant" : "user"
            let parts = try message.content.map { part -> JSONValue in
                switch part {
                case .text(let text):
                    return .object(["type": .string("text"), "text": .string(text)])
                case .image(let image):
                    return .object([
                        "type": .string("image"),
                        "source": .object([
                            "type": .string("url"),
                            "url": .string(image.url.absoluteString),
                        ]),
                    ])
                case .toolResult(let result):
                    return .object([
                        "type": .string("tool_result"),
                        "tool_use_id": .string(result.callID),
                        "content": .string(try compactJSONString(result.content)),
                        "is_error": .boolean(result.isError),
                    ])
                case .toolCall(let invocation):
                    guard message.role == .assistant else {
                        throw AgentProviderAdapterError.invalidRequest(
                            providerID: providerID,
                            message: "Only assistant messages may contain tool calls."
                        )
                    }
                    return .object([
                        "type": .string("tool_use"),
                        "id": .string(invocation.call.id),
                        "name": .string(invocation.call.name),
                        "input": invocation.arguments,
                    ])
                }
            }
            messages.append(.object([
                "role": .string(role),
                "content": .array(parts),
            ]))
        }

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "stream": .boolean(true),
            "max_tokens": .number(Double(request.maxOutputTokens ?? 4_096)),
            "messages": .array(messages),
        ]
        if !system.isEmpty { body["system"] = .string(system) }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { descriptor in
                .object([
                    "name": .string(descriptor.name),
                    "description": .string(descriptor.description),
                    "input_schema": descriptor.inputSchema.jsonValue,
                ])
            })
        }
        if let temperature = request.temperature { body["temperature"] = .number(temperature) }
        return .object(body)
    }
}

// MARK: - Gemini generateContent

nonisolated struct GeminiGenerateContentStreamParser: Sendable {
    private var didEmitResponseStart = false
    private var didFinish = false
    private var sawToolCall = false
    private var latestUsage: AgentModelUsage?

    init() {}

    mutating func consume(_ frame: AgentProviderStreamFrame) throws -> [AgentModelEvent] {
        guard !didFinish else { return [] }
        let object = try decodedJSONObject(frame.data, providerID: "gemini-generate-content")
        if object["error"] != nil {
            didFinish = true
            throw AgentProviderAdapterError(
                providerID: "gemini-generate-content",
                code: .transport,
                safeMessage: "Gemini generateContent streaming failed.",
                retryClassification: .permanent
            )
        }

        var events: [AgentModelEvent] = []
        if !didEmitResponseStart {
            didEmitResponseStart = true
            events.append(.responseStarted(id: object["responseId"] as? String))
        }
        if let usage = object["usageMetadata"] as? [String: Any] {
            latestUsage = .reported(
                inputTokens: integer(usage["promptTokenCount"]),
                outputTokens: integer(usage["candidatesTokenCount"]),
                totalTokens: integer(usage["totalTokenCount"]),
                cachedInputTokens: integer(usage["cachedContentTokenCount"])
            )
        }

        var terminalReason: AgentModelFinishReason?
        for (candidateIndex, candidate) in (object["candidates"] as? [[String: Any]] ?? []).enumerated() {
            if let content = candidate["content"] as? [String: Any] {
                for (partIndex, part) in (content["parts"] as? [[String: Any]] ?? []).enumerated() {
                    if let text = part["text"] as? String, !text.isEmpty {
                        events.append(.textDelta(text))
                    }
                    if let function = part["functionCall"] as? [String: Any] {
                        sawToolCall = true
                        let index = candidateIndex * 1_000 + partIndex
                        let call = AgentToolCall(
                            id: function["id"] as? String ?? "gemini-tool-\(index)",
                            index: index,
                            name: function["name"] as? String ?? "unknown_tool"
                        )
                        let arguments: AgentToolArguments
                        let raw: String
                        if let rawArguments = function["args"] as? String {
                            raw = rawArguments
                            arguments = normalizedToolArguments(rawArguments)
                        } else if let foundationArguments = function["args"] {
                            do {
                                let value = try JSONValue(foundationValue: foundationArguments)
                                raw = try compactJSONString(value)
                                arguments = .valid(value)
                            } catch {
                                raw = ""
                                arguments = .malformed(
                                    raw: "",
                                    reason: "Tool arguments were not valid JSON."
                                )
                            }
                        } else {
                            raw = "{}"
                            arguments = .valid(.object([:]))
                        }
                        events.append(.toolCallStarted(call))
                        events.append(.toolCallArgumentsDelta(id: call.id, delta: raw))
                        events.append(.toolCallCompleted(call: call, arguments: arguments))
                    }
                }
            }
            if let rawReason = candidate["finishReason"] as? String {
                terminalReason = finishReason(rawReason)
            }
        }

        if let terminalReason {
            didFinish = true
            events.append(.usage(latestUsage ?? .unknown))
            let normalizedReason: AgentModelFinishReason = if sawToolCall && terminalReason == .stop {
                .toolCalls
            } else {
                terminalReason
            }
            events.append(.finished(normalizedReason))
        }
        return events
    }

    mutating func finish() -> [AgentModelEvent] {
        guard !didFinish else { return [] }
        didFinish = true
        return [
            .usage(latestUsage ?? .unknown),
            .finished(sawToolCall ? .toolCalls : .stop),
        ]
    }
}

nonisolated struct GeminiGenerateContentRequestBuilder: Sendable {
    let capabilities = AgentProviderCapabilities([
        .streaming, .toolCalling, .parallelToolCalls, .imageInput,
        .structuredOutput, .usageReporting,
    ])

    init() {}

    func makeBody(for request: AgentModelRequest) throws -> JSONValue {
        let providerID = "gemini-generate-content"
        let missing = request.requiredCapabilities.subtracting(capabilities.supported)
        guard missing.isEmpty else {
            throw AgentProviderAdapterError.unsupportedCapabilities(
                providerID: providerID,
                capabilities: missing
            )
        }
        guard !request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentProviderAdapterError.invalidRequest(
                providerID: providerID,
                message: "A model is required for Gemini generateContent."
            )
        }

        let systemTexts = request.messages
            .filter { $0.role == .system }
            .flatMap(\.content)
            .compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }
        var contents: [JSONValue] = []
        for message in request.messages where message.role != .system {
            let role = message.role == .assistant ? "model" : "user"
            let parts = message.content.map { part -> JSONValue in
                switch part {
                case .text(let text):
                    return .object(["text": .string(text)])
                case .image(let image):
                    return .object([
                        "fileData": .object([
                            "mimeType": .string(image.mediaType ?? "application/octet-stream"),
                            "fileUri": .string(image.url.absoluteString),
                        ]),
                    ])
                case .toolResult(let result):
                    return .object([
                        "functionResponse": .object([
                            "id": .string(result.callID),
                            "name": .string(result.toolName),
                            "response": result.content,
                        ]),
                    ])
                case .toolCall(let invocation):
                    return .object([
                        "functionCall": .object([
                            "id": .string(invocation.call.id),
                            "name": .string(invocation.call.name),
                            "args": invocation.arguments,
                        ]),
                    ])
                }
            }
            contents.append(.object([
                "role": .string(role),
                "parts": .array(parts),
            ]))
        }

        var body: [String: JSONValue] = ["contents": .array(contents)]
        if !systemTexts.isEmpty {
            body["systemInstruction"] = .object([
                "parts": .array(systemTexts.map { .object(["text": .string($0)]) }),
            ])
        }
        if !request.tools.isEmpty {
            body["tools"] = .array([.object([
                "functionDeclarations": .array(request.tools.map { descriptor in
                    .object([
                        "name": .string(descriptor.name),
                        "description": .string(descriptor.description),
                        "parameters": descriptor.inputSchema.jsonValue,
                    ])
                }),
            ])])
        }
        var generationConfig: [String: JSONValue] = [:]
        if let temperature = request.temperature {
            generationConfig["temperature"] = .number(temperature)
        }
        if let maxOutputTokens = request.maxOutputTokens {
            generationConfig["maxOutputTokens"] = .number(Double(maxOutputTokens))
        }
        if let responseFormat = request.responseFormat {
            generationConfig["responseMimeType"] = .string("application/json")
            if case .jsonSchema(_, let schema) = responseFormat {
                generationConfig["responseSchema"] = schema
            }
        }
        if !generationConfig.isEmpty { body["generationConfig"] = .object(generationConfig) }
        return .object(body)
    }
}
