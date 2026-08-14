import Foundation

nonisolated enum AgentProviderDialect: String, Codable, CaseIterable, Sendable {
    case openAICompatibleChat
    case openAIResponses
    case anthropicMessages
    case geminiGenerateContent
}

nonisolated struct AgentProviderHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: AsyncThrowingStream<Data, Error>

    init(
        statusCode: Int,
        headers: [String: String],
        body: AsyncThrowingStream<Data, Error>
    ) {
        self.statusCode = statusCode
        self.headers = headers.reduce(into: [:]) { result, pair in
            result[pair.key.lowercased()] = pair.value
        }
        self.body = body
    }
}

nonisolated protocol AgentProviderHTTPTransport: Sendable {
    func response(for request: URLRequest) async throws -> AgentProviderHTTPResponse
}

nonisolated struct URLSessionAgentProviderTransport: AgentProviderHTTPTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func response(for request: URLRequest) async throws -> AgentProviderHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentProviderAdapterError(
                providerID: "http",
                code: .transport,
                safeMessage: "The provider returned no HTTP response.",
                retryClassification: .transient
            )
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            guard let key = pair.key as? String else { return }
            result[key] = String(describing: pair.value)
        }
        let body = AsyncThrowingStream<Data, Error> { continuation in
            let producer = Task {
                do {
                    var chunk = Data()
                    chunk.reserveCapacity(4_096)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        chunk.append(byte)
                        if chunk.count >= 4_096 {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
        return AgentProviderHTTPResponse(
            statusCode: http.statusCode,
            headers: headers,
            body: body
        )
    }
}

nonisolated struct AgentProviderHTTPAdapter: AgentProviderAdapter, CustomStringConvertible {
    static let maximumRequestBytes = 4 * 1_024 * 1_024
    static let maximumResponseBytes = 16 * 1_024 * 1_024
    static let maximumFrameBytes = 1 * 1_024 * 1_024

    let dialect: AgentProviderDialect
    let endpoint: URL
    private let apiKey: String
    private let transport: any AgentProviderHTTPTransport

    init(
        dialect: AgentProviderDialect,
        endpoint: URL,
        apiKey: String,
        transport: any AgentProviderHTTPTransport = URLSessionAgentProviderTransport()
    ) {
        self.dialect = dialect
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.transport = transport
    }

    var providerID: String { dialect.rawValue }

    var capabilities: AgentProviderCapabilities {
        switch dialect {
        case .openAICompatibleChat:
            OpenAICompatibleChatRequestBuilder().capabilities
        case .openAIResponses:
            OpenAIResponsesRequestBuilder().capabilities
        case .anthropicMessages:
            AnthropicMessagesRequestBuilder().capabilities
        case .geminiGenerateContent:
            GeminiGenerateContentRequestBuilder().capabilities
        }
    }

    var description: String {
        "AgentProviderHTTPAdapter(provider: \(providerID), endpoint: \(endpointIdentity))"
    }

    func events(
        for request: AgentModelRequest
    ) throws -> AsyncThrowingStream<AgentModelEvent, Error> {
        try validateCapabilities(for: request)
        let body = try requestBody(for: request)
        // Chat Completions providers reject reasoning controls for some models.
        // Keep this at the transport boundary so an upstream adapter change cannot
        // accidentally reintroduce the unsupported parameter.
        let outboundBody = sanitizedOutboundBody(body)
        let outboundFieldNames = Self.topLevelFieldNames(in: outboundBody)
        let bodyData = try JSONSerialization.data(
            withJSONObject: outboundBody.foundationValue,
            options: [.sortedKeys]
        )
        guard bodyData.count <= Self.maximumRequestBytes else {
            throw AgentProviderAdapterError.invalidRequest(
                providerID: providerID,
                message: "The normalized provider request exceeds the 4 MiB limit."
            )
        }
        let urlRequest = makeURLRequest(body: bodyData, model: request.model)
        let transport = self.transport
        let providerID = self.providerID
        let dialect = self.dialect

        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let response = try await transport.response(for: urlRequest)
                    guard (200..<300).contains(response.statusCode) else {
                        let retryAfter = response.headers["retry-after"].flatMap(TimeInterval.init)
                        let errorBody = try await Self.boundedErrorBody(response.body)
                        throw AgentProviderAdapterError.httpStatus(
                            providerID: providerID,
                            statusCode: response.statusCode,
                            retryAfter: retryAfter,
                            untrustedResponseBody: errorBody,
                            sentRequestFields: outboundFieldNames
                        )
                    }

                    var decoder = AgentSSEDecoder()
                    var parser = AgentHTTPStreamParser(dialect: dialect)
                    var responseBytes = 0
                    for try await chunk in response.body {
                        try Task.checkCancellation()
                        responseBytes += chunk.count
                        guard responseBytes <= Self.maximumResponseBytes else {
                            throw AgentProviderAdapterError(
                                providerID: providerID,
                                code: .malformedStream,
                                safeMessage: "The provider stream exceeded the 16 MiB limit.",
                                retryClassification: .permanent
                            )
                        }
                        for frame in try decoder.append(chunk) {
                            try Self.validateFrame(frame, providerID: providerID)
                            for event in try parser.consume(frame) {
                                try Task.checkCancellation()
                                continuation.yield(event)
                            }
                        }
                    }
                    for frame in try decoder.finish() {
                        try Self.validateFrame(frame, providerID: providerID)
                        for event in try parser.consume(frame) {
                            try Task.checkCancellation()
                            continuation.yield(event)
                        }
                    }
                    for event in parser.finish() {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.redacted(error, providerID: providerID))
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    private var endpointIdentity: String {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return "invalid"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "invalid"
    }

    private func requestBody(for request: AgentModelRequest) throws -> JSONValue {
        switch dialect {
        case .openAICompatibleChat:
            try OpenAICompatibleChatRequestBuilder().makeBody(for: request)
        case .openAIResponses:
            try OpenAIResponsesRequestBuilder().makeBody(for: request)
        case .anthropicMessages:
            try AnthropicMessagesRequestBuilder().makeBody(for: request)
        case .geminiGenerateContent:
            try GeminiGenerateContentRequestBuilder().makeBody(for: request)
        }
    }

    private func sanitizedOutboundBody(_ body: JSONValue) -> JSONValue {
        guard dialect == .openAICompatibleChat,
              case .object(var fields) = body else {
            return body
        }
        fields.removeValue(forKey: "reasoning_effort")
        fields.removeValue(forKey: "reasoning")
        return .object(fields)
    }

    /// Names only: suitable for diagnostics without retaining prompt, tool, or
    /// credential values in an error report.
    private static func topLevelFieldNames(in body: JSONValue) -> [String] {
        guard case .object(let fields) = body else { return [] }
        return fields.keys.sorted()
    }

    private func makeURLRequest(body: Data, model: String) -> URLRequest {
        var request = URLRequest(url: requestURL(model: model))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        guard !apiKey.isEmpty else { return request }
        switch dialect {
        case .openAICompatibleChat, .openAIResponses:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropicMessages:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .geminiGenerateContent:
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        return request
    }

    private func requestURL(model: String) -> URL {
        guard dialect == .geminiGenerateContent,
              var components = URLComponents(
                  url: endpoint,
                  resolvingAgainstBaseURL: false
              ) else {
            return endpoint
        }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._~")
        )
        guard !trimmedModel.isEmpty,
              let encodedModel = trimmedModel.addingPercentEncoding(
                  withAllowedCharacters: allowed
              ) else {
            return endpoint
        }

        var basePath = components.percentEncodedPath
        if let models = basePath.range(of: "/models/") {
            basePath = String(basePath[..<models.lowerBound])
        }
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath =
            "\(basePath)/models/\(encodedModel):streamGenerateContent"
        components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        components.fragment = nil
        return components.url ?? endpoint
    }

    private static func validateFrame(
        _ frame: AgentProviderStreamFrame,
        providerID: String
    ) throws {
        guard frame.data.utf8.count <= maximumFrameBytes else {
            throw AgentProviderAdapterError(
                providerID: providerID,
                code: .malformedStream,
                safeMessage: "A provider stream frame exceeded the 1 MiB limit.",
                retryClassification: .permanent
            )
        }
    }

    private static func redacted(
        _ error: Error,
        providerID: String
    ) -> Error {
        if error is CancellationError { return CancellationError() }
        if let safe = error as? AgentProviderAdapterError { return safe }
        return AgentProviderAdapterError(
            providerID: providerID,
            code: .transport,
            safeMessage: "The provider transport failed.",
            retryClassification: .transient
        )
    }

    private static func boundedErrorBody(_ body: AsyncThrowingStream<Data, Error>) async throws -> String {
        var data = Data()
        for try await chunk in body {
            let remaining = 4_096 - data.count
            guard remaining > 0 else { break }
            data.append(chunk.prefix(remaining))
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private nonisolated enum AgentHTTPStreamParser: Sendable {
    case openAICompatibleChat(OpenAICompatibleChatStreamParser)
    case openAIResponses(OpenAIResponsesStreamParser)
    case anthropicMessages(AnthropicMessagesStreamParser)
    case geminiGenerateContent(GeminiGenerateContentStreamParser)

    init(dialect: AgentProviderDialect) {
        self = switch dialect {
        case .openAICompatibleChat: .openAICompatibleChat(OpenAICompatibleChatStreamParser())
        case .openAIResponses: .openAIResponses(OpenAIResponsesStreamParser())
        case .anthropicMessages: .anthropicMessages(AnthropicMessagesStreamParser())
        case .geminiGenerateContent: .geminiGenerateContent(GeminiGenerateContentStreamParser())
        }
    }

    mutating func consume(_ frame: AgentProviderStreamFrame) throws -> [AgentModelEvent] {
        switch self {
        case .openAICompatibleChat(var parser):
            let events = try parser.consume(frame)
            self = .openAICompatibleChat(parser)
            return events
        case .openAIResponses(var parser):
            let events = try parser.consume(frame)
            self = .openAIResponses(parser)
            return events
        case .anthropicMessages(var parser):
            let events = try parser.consume(frame)
            self = .anthropicMessages(parser)
            return events
        case .geminiGenerateContent(var parser):
            let events = try parser.consume(frame)
            self = .geminiGenerateContent(parser)
            return events
        }
    }

    mutating func finish() -> [AgentModelEvent] {
        switch self {
        case .openAICompatibleChat(var parser):
            let events = parser.finish()
            self = .openAICompatibleChat(parser)
            return events
        case .openAIResponses(var parser):
            let events = parser.finish()
            self = .openAIResponses(parser)
            return events
        case .anthropicMessages(var parser):
            let events = parser.finish()
            self = .anthropicMessages(parser)
            return events
        case .geminiGenerateContent(var parser):
            let events = parser.finish()
            self = .geminiGenerateContent(parser)
            return events
        }
    }
}
