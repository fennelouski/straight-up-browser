import Foundation
import Testing
@testable import Browser

struct ProviderTransportTests {
    @Test func HTTPAdapterStreamsNormalizedEventsAndKeepsSecretOutOfErrors() async throws {
        let recorder = ProviderRequestRecorder()
        let transport = FixtureProviderTransport(
            recorder: recorder,
            response: AgentProviderHTTPResponse(
                statusCode: 200,
                headers: [:],
                body: AsyncThrowingStream { continuation in
                    continuation.yield(Data(
                        "data: {\"id\":\"r1\",\"choices\":[{\"delta\":{\"content\":\"Hi\"},\"finish_reason\":\"stop\"}]}\n\n".utf8
                    ))
                    continuation.yield(Data("data: [DONE]\n\n".utf8))
                    continuation.finish()
                }
            )
        )
        let adapter = AgentProviderHTTPAdapter(
            dialect: .openAICompatibleChat,
            endpoint: URL(string: "https://provider.invalid/v1/chat/completions")!,
            apiKey: "fixture-secret",
            transport: transport
        )
        let request = AgentModelRequest(
            model: "fixture",
            messages: [AgentModelMessage(role: .user, content: [.text("Hello")])]
        )

        var events: [AgentModelEvent] = []
        for try await event in try adapter.events(for: request) { events.append(event) }

        #expect(events == [
            .responseStarted(id: "r1"),
            .textDelta("Hi"),
            .usage(.unknown),
            .finished(.stop),
        ])
        let sent = await recorder.request
        #expect(sent?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret")
        #expect(sent?.httpBody?.isEmpty == false)
        #expect(!String(describing: adapter).contains("fixture-secret"))
    }

    @Test func HTTPAdapterRejectsOversizedAndFailedResponsesWithoutLeakingBodies() async throws {
        let secret = "response-body-secret"
        let response = AgentProviderHTTPResponse(
            statusCode: 429,
            headers: ["retry-after": "2"],
            body: AsyncThrowingStream { continuation in
                continuation.yield(Data(secret.utf8))
                continuation.finish()
            }
        )
        let adapter = AgentProviderHTTPAdapter(
            dialect: .openAIResponses,
            endpoint: URL(string: "https://provider.invalid/v1/responses")!,
            apiKey: "request-secret",
            transport: FixtureProviderTransport(recorder: ProviderRequestRecorder(), response: response)
        )
        let request = AgentModelRequest(
            model: "fixture",
            messages: [AgentModelMessage(role: .user, content: [.text("Hello")])]
        )

        do {
            for try await _ in try adapter.events(for: request) {}
            Issue.record("Expected HTTP failure")
        } catch let error as AgentProviderAdapterError {
            #expect(error.code == .rateLimited)
            #expect(error.retryClassification == .rateLimited(retryAfter: 2))
            #expect(!String(describing: error).contains(secret))
            #expect(!String(describing: error).contains("request-secret"))
        }
    }

    @Test func HTTPStatusSurfacesOnlyMachineReadableProviderCode() {
        let error = AgentProviderAdapterError.httpStatus(
            providerID: "openAICompatibleChat",
            statusCode: 400,
            untrustedResponseBody: #"{"error":{"code":"model_not_found","message":"secret prompt text"}}"#
        )

        #expect(error.safeMessage.contains("model_not_found"))
        #expect(!error.safeMessage.contains("secret prompt text"))
    }

    @Test func chatTransportDoesNotSerializeReasoningFields() async throws {
        let recorder = ProviderRequestRecorder()
        let adapter = AgentProviderHTTPAdapter(
            dialect: .openAICompatibleChat,
            endpoint: URL(string: "https://provider.invalid/v1/chat/completions")!,
            apiKey: "fixture-secret",
            transport: FixtureProviderTransport(
                recorder: recorder,
                response: AgentProviderHTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: AsyncThrowingStream { continuation in
                        continuation.yield(Data(
                            (#"data: {"id":"response-1","choices":[{"delta":{"content":"Hi"},"finish_reason":"stop"}]}"# + "\n\n").utf8
                        ))
                        continuation.yield(Data("data: [DONE]\n\n".utf8))
                        continuation.finish()
                    }
                )
            )
        )
        let request = AgentModelRequest(
            model: "fixture",
            messages: [AgentModelMessage(role: .user, content: [.text("Hello")])]
        )

        _ = try await collect(adapter.events(for: request))

        let sent = try #require(await recorder.request)
        let body = try #require(sent.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["reasoning_effort"] == nil)
        #expect(json["reasoning"] == nil)
    }

    @Test func selectableNativeProvidersRouteChunkedStreamsWithCorrectAuthentication() async throws {
        let expectedEvents: [AgentModelEvent] = [
            .responseStarted(id: "shared"),
            .textDelta("Hi"),
            .usage(.reported(
                inputTokens: 2,
                outputTokens: 1,
                totalTokens: 3,
                cachedInputTokens: nil
            )),
            .finished(.stop),
        ]
        let fixtures = [
            NativeTransportFixture(
                dialect: .openAIResponses,
                endpoint: "https://api.openai.com/v1/responses",
                model: "gpt-5-mini",
                chunks: [
                    "event: response.created\ndata: {\"type\":\"response.cre",
                    "ated\",\"response\":{\"id\":\"shared\"}}\n\n"
                        + "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hi\"}\n\n",
                    "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":2,\"output_tokens\":1,\"total_tokens\":3}}}\n\n",
                ],
                expectedURL: "https://api.openai.com/v1/responses"
            ),
            NativeTransportFixture(
                dialect: .anthropicMessages,
                endpoint: "https://api.anthropic.com/v1/messages",
                model: "claude-sonnet-5",
                chunks: [
                    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"shared\",\"usage\":{\"input_tokens\":2}}}\n\n"
                        + "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"H",
                    "i\"}}\n\n"
                        + "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n",
                ],
                expectedURL: "https://api.anthropic.com/v1/messages"
            ),
            NativeTransportFixture(
                dialect: .geminiGenerateContent,
                endpoint: "https://generativelanguage.googleapis.com/v1beta/models/stale-model:streamGenerateContent",
                model: "gemini-3.6-flash",
                chunks: [
                    "data: {\"responseId\":\"shared\",\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"H",
                    "i\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":2,\"candidatesTokenCount\":1,\"totalTokenCount\":3}}\n\n",
                ],
                expectedURL: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:streamGenerateContent?alt=sse"
            ),
        ]

        for fixture in fixtures {
            let recorder = ProviderRequestRecorder()
            let adapter = AgentProviderHTTPAdapter(
                dialect: fixture.dialect,
                endpoint: try #require(URL(string: fixture.endpoint)),
                apiKey: "fixture-key",
                transport: FixtureProviderTransport(
                    recorder: recorder,
                    response: fixture.response
                )
            )

            let events = try await collect(try adapter.events(for: AgentModelRequest(
                model: fixture.model,
                messages: [AgentModelMessage(role: .user, content: [.text("Hello")])]
            )))

            #expect(events == expectedEvents)
            let sent = try #require(await recorder.request)
            #expect(sent.url?.absoluteString == fixture.expectedURL)
            let body = try #require(sent.httpBody)
            let object = try #require(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            switch fixture.dialect {
            case .openAIResponses:
                #expect(sent.value(forHTTPHeaderField: "Authorization") ==
                    "Bearer fixture-key")
                #expect(object["model"] as? String == fixture.model)
            case .anthropicMessages:
                #expect(sent.value(forHTTPHeaderField: "x-api-key") == "fixture-key")
                #expect(sent.value(forHTTPHeaderField: "anthropic-version") ==
                    "2023-06-01")
                #expect(object["model"] as? String == fixture.model)
            case .geminiGenerateContent:
                #expect(sent.value(forHTTPHeaderField: "x-goog-api-key") ==
                    "fixture-key")
                #expect(object["contents"] != nil)
            case .openAICompatibleChat:
                Issue.record("Unexpected legacy Chat Completions fixture")
            }
        }
    }

    @Test func nativeProvidersPreserveMalformedToolArgumentsAsValidationEvents() async throws {
        let fixtures = [
            NativeTransportFixture(
                dialect: .openAIResponses,
                endpoint: "https://api.openai.com/v1/responses",
                model: "gpt-5-mini",
                chunks: [
                    "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"item-1\",\"type\":\"function_call\",\"call_id\":\"bad-call\",\"name\":\"lookup\",\"arguments\":\"\"}}\n\n"
                        + "data: {\"type\":\"response.function_call_arguments.done\",\"item_id\":\"item-1\",\"output_index\":0,\"arguments\":\"{\"}\n\n"
                        + "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n",
                ],
                expectedURL: "https://api.openai.com/v1/responses"
            ),
            NativeTransportFixture(
                dialect: .anthropicMessages,
                endpoint: "https://api.anthropic.com/v1/messages",
                model: "claude-sonnet-5",
                chunks: [
                    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"bad-call\",\"name\":\"lookup\",\"input\":{}}}\n\n"
                        + "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\"}}\n\n"
                        + "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
                        + "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n\n",
                ],
                expectedURL: "https://api.anthropic.com/v1/messages"
            ),
            NativeTransportFixture(
                dialect: .geminiGenerateContent,
                endpoint: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:streamGenerateContent",
                model: "gemini-3.6-flash",
                chunks: [
                    "data: {\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"id\":\"bad-call\",\"name\":\"lookup\",\"args\":\"{\"}}]},\"finishReason\":\"STOP\"}]}\n\n",
                ],
                expectedURL: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:streamGenerateContent?alt=sse"
            ),
        ]

        for fixture in fixtures {
            let adapter = AgentProviderHTTPAdapter(
                dialect: fixture.dialect,
                endpoint: try #require(URL(string: fixture.endpoint)),
                apiKey: "fixture-key",
                transport: FixtureProviderTransport(
                    recorder: ProviderRequestRecorder(),
                    response: fixture.response
                )
            )
            let events = try await collect(try adapter.events(for: AgentModelRequest(
                model: fixture.model,
                messages: [AgentModelMessage(role: .user, content: [.text("Use lookup")])]
            )))
            let retainedMalformedCall = events.contains { event in
                guard case .toolCallCompleted(let call, let arguments) = event,
                      case .malformed(let raw, _) = arguments else {
                    return false
                }
                return call.id == "bad-call" && raw == "{"
            }
            #expect(retainedMalformedCall)
            #expect(events.contains(.finished(.toolCalls)))
        }
    }

    @Test func geminiModelIsEncodedAsOnePathSegment() async throws {
        let recorder = ProviderRequestRecorder()
        let adapter = AgentProviderHTTPAdapter(
            dialect: .geminiGenerateContent,
            endpoint: try #require(URL(string:
                "https://generativelanguage.googleapis.com/v1beta/models/stale:streamGenerateContent")),
            apiKey: "fixture-key",
            transport: FixtureProviderTransport(
                recorder: recorder,
                response: AgentProviderHTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: AsyncThrowingStream { continuation in
                        continuation.yield(Data(
                            "data: {\"candidates\":[{\"finishReason\":\"STOP\"}]}\n\n".utf8
                        ))
                        continuation.finish()
                    }
                )
            )
        )

        _ = try await collect(try adapter.events(for: AgentModelRequest(
            model: "models/custom?candidate#1",
            messages: [AgentModelMessage(role: .user, content: [.text("Hello")])]
        )))

        let sent = await recorder.request
        #expect(sent?.url?.absoluteString ==
            "https://generativelanguage.googleapis.com/v1beta/models/models%2Fcustom%3Fcandidate%231:streamGenerateContent?alt=sse")
    }

    @Test func nativeProvidersKeepMissingUsageExplicitlyUnknown() async throws {
        let fixtures = [
            NativeTransportFixture(
                dialect: .openAIResponses,
                endpoint: "https://api.openai.com/v1/responses",
                model: "gpt-5-mini",
                chunks: [
                    "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n",
                ],
                expectedURL: "https://api.openai.com/v1/responses"
            ),
            NativeTransportFixture(
                dialect: .anthropicMessages,
                endpoint: "https://api.anthropic.com/v1/messages",
                model: "claude-sonnet-5",
                chunks: [
                    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n",
                ],
                expectedURL: "https://api.anthropic.com/v1/messages"
            ),
            NativeTransportFixture(
                dialect: .geminiGenerateContent,
                endpoint: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:streamGenerateContent",
                model: "gemini-3.6-flash",
                chunks: [
                    "data: {\"candidates\":[{\"finishReason\":\"STOP\"}]}\n\n",
                ],
                expectedURL: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:streamGenerateContent?alt=sse"
            ),
        ]

        for fixture in fixtures {
            let adapter = AgentProviderHTTPAdapter(
                dialect: fixture.dialect,
                endpoint: try #require(URL(string: fixture.endpoint)),
                apiKey: "fixture-key",
                transport: FixtureProviderTransport(
                    recorder: ProviderRequestRecorder(),
                    response: fixture.response
                )
            )
            let events = try await collect(try adapter.events(for: AgentModelRequest(
                model: fixture.model,
                messages: [AgentModelMessage(role: .user, content: [.text("Hello")])]
            )))
            #expect(events.contains(.usage(.unknown)))
        }
    }

    @Test func cancellingHTTPProviderStreamCancelsItsBodyAndDropsLateEvents() async throws {
        let probe = ProviderCancellationProbe()
        let eventRecorder = ProviderEventRecorder()
        let response = AgentProviderHTTPResponse(
            statusCode: 200,
            headers: [:],
            body: AsyncThrowingStream { continuation in
                continuation.yield(Data(
                    "data: {\"type\":\"response.output_text.delta\",\"delta\":\"before\"}\n\n".utf8
                ))
                let producer = Task {
                    do {
                        try await Task.sleep(for: .seconds(30))
                        continuation.yield(Data(
                            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"late\"}\n\n".utf8
                        ))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { @Sendable _ in
                    producer.cancel()
                    Task { await probe.markCancelled() }
                }
            }
        )
        let adapter = AgentProviderHTTPAdapter(
            dialect: .openAIResponses,
            endpoint: try #require(URL(string: "https://api.openai.com/v1/responses")),
            apiKey: "fixture-key",
            transport: FixtureProviderTransport(
                recorder: ProviderRequestRecorder(),
                response: response
            )
        )
        let consumer = Task {
            do {
                for try await event in try adapter.events(for: AgentModelRequest(
                    model: "gpt-5-mini",
                    messages: [AgentModelMessage(role: .user, content: [.text("Hello")])]
                )) {
                    await eventRecorder.append(event)
                }
            } catch is CancellationError {
                // Cancellation is the expected terminal transport behavior.
            } catch {
                Issue.record("Unexpected provider stream failure: \(error.localizedDescription)")
            }
        }
        for _ in 0..<100 {
            if await eventRecorder.events.contains(.textDelta("before")) { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        consumer.cancel()
        await consumer.value
        for _ in 0..<100 {
            if await probe.cancelled { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        let events = await eventRecorder.events
        let bodyWasCancelled = await probe.cancelled
        #expect(events.contains(.textDelta("before")))
        #expect(!events.contains(.textDelta("late")))
        #expect(bodyWasCancelled)
    }

    private func collect(
        _ stream: AsyncThrowingStream<AgentModelEvent, Error>
    ) async throws -> [AgentModelEvent] {
        var events: [AgentModelEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}

private struct NativeTransportFixture {
    let dialect: AgentProviderDialect
    let endpoint: String
    let model: String
    let chunks: [String]
    let expectedURL: String

    var response: AgentProviderHTTPResponse {
        AgentProviderHTTPResponse(
            statusCode: 200,
            headers: [:],
            body: AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(Data(chunk.utf8)) }
                continuation.finish()
            }
        )
    }
}

private actor ProviderRequestRecorder {
    private(set) var request: URLRequest?
    func record(_ request: URLRequest) { self.request = request }
}

private actor ProviderEventRecorder {
    private(set) var events: [AgentModelEvent] = []
    func append(_ event: AgentModelEvent) { events.append(event) }
}

private actor ProviderCancellationProbe {
    private(set) var cancelled = false
    func markCancelled() { cancelled = true }
}

private struct FixtureProviderTransport: AgentProviderHTTPTransport {
    let recorder: ProviderRequestRecorder
    let response: AgentProviderHTTPResponse

    func response(for request: URLRequest) async throws -> AgentProviderHTTPResponse {
        await recorder.record(request)
        return response
    }
}
