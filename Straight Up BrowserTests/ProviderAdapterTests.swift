import Foundation
import Testing
@testable import Browser

struct ProviderAdapterTests {
    @Test func scriptedAdapterEmitsNormalizedEventsInOrder() async throws {
        let request = AgentModelRequest(
            model: "scripted",
            messages: [AgentModelMessage(role: .user, content: [.text("Hello")])]
        )
        let adapter = ScriptedAgentProviderAdapter(script: [
            .event(.textDelta("Hel")),
            .event(.textDelta("lo")),
            .event(.usage(.unknown)),
            .event(.finished(.stop)),
        ])

        let events = try await collect(adapter.events(for: request))

        #expect(events == [
            .textDelta("Hel"),
            .textDelta("lo"),
            .usage(.unknown),
            .finished(.stop),
        ])
    }

    @Test func openAICompatibleChatChunksBecomeNormalizedTextToolUsageAndFinishEvents() throws {
        var parser = OpenAICompatibleChatStreamParser()
        let frames = [
            AgentProviderStreamFrame(data: #"{"id":"response-1","choices":[{"delta":{"content":"Hel"},"finish_reason":null}]}"#),
            AgentProviderStreamFrame(data: #"{"choices":[{"delta":{"content":"lo","tool_calls":[{"index":0,"id":"call-1","function":{"name":"lookup","arguments":"{\"q\":"}}]},"finish_reason":null}]}"#),
            AgentProviderStreamFrame(data: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"swift\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":8,"completion_tokens":4,"total_tokens":12}}"#),
            AgentProviderStreamFrame(data: "[DONE]"),
        ]

        let events = try frames.flatMap { try parser.consume($0) }

        #expect(events == [
            .responseStarted(id: "response-1"),
            .textDelta("Hel"),
            .textDelta("lo"),
            .toolCallStarted(AgentToolCall(id: "call-1", index: 0, name: "lookup")),
            .toolCallArgumentsDelta(id: "call-1", delta: #"{"q":"#),
            .toolCallArgumentsDelta(id: "call-1", delta: #""swift"}"#),
            .toolCallCompleted(
                call: AgentToolCall(id: "call-1", index: 0, name: "lookup"),
                arguments: .valid(.object(["q": .string("swift")]))
            ),
            .usage(.reported(inputTokens: 8, outputTokens: 4, totalTokens: 12, cachedInputTokens: nil)),
            .finished(.toolCalls),
        ])
    }

    @Test func openAICompatibleChatRequestBuilderUsesCanonicalMessagesAndTools() throws {
        let request = AgentModelRequest(
            model: "fixture-model",
            messages: [AgentModelMessage(role: .user, content: [.text("Find Swift")])],
            tools: [fixtureTool()],
            temperature: 0.25,
            maxOutputTokens: 321
        )

        let body = try OpenAICompatibleChatRequestBuilder().makeBody(for: request)
        guard case .object(let object) = body else {
            Issue.record("Expected an object request body")
            return
        }

        #expect(object["model"] == .string("fixture-model"))
        #expect(object["stream"] == .boolean(true))
        #expect(object["stream_options"] == .object(["include_usage": .boolean(true)]))
        #expect(object["temperature"] == .number(0.25))
        #expect(object["max_tokens"] == .number(321))
        guard case .array(let tools) = object["tools"] else {
            Issue.record("Expected rendered tools")
            return
        }
        #expect(tools.count == 1)
    }

    @Test func openAIResponsesEventsNormalizeIncrementalFunctionArguments() throws {
        var parser = OpenAIResponsesStreamParser()
        let frames = [
            AgentProviderStreamFrame(event: "response.created", data: #"{"type":"response.created","response":{"id":"resp-1"}}"#),
            AgentProviderStreamFrame(event: "response.output_text.delta", data: #"{"type":"response.output_text.delta","delta":"Working"}"#),
            AgentProviderStreamFrame(event: "response.output_item.added", data: #"{"type":"response.output_item.added","output_index":0,"item":{"id":"item-1","type":"function_call","call_id":"call-1","name":"lookup","arguments":""}}"#),
            AgentProviderStreamFrame(event: "response.function_call_arguments.delta", data: #"{"type":"response.function_call_arguments.delta","item_id":"item-1","output_index":0,"delta":"{\"q\":"}"#),
            AgentProviderStreamFrame(event: "response.function_call_arguments.delta", data: #"{"type":"response.function_call_arguments.delta","item_id":"item-1","output_index":0,"delta":"\"swift\"}"}"#),
            AgentProviderStreamFrame(event: "response.function_call_arguments.done", data: #"{"type":"response.function_call_arguments.done","item_id":"item-1","output_index":0,"arguments":"{\"q\":\"swift\"}"}"#),
            AgentProviderStreamFrame(event: "response.completed", data: #"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":6,"output_tokens":3,"total_tokens":9}}}"#),
        ]

        let events = try frames.flatMap { try parser.consume($0) }

        #expect(events == [
            .responseStarted(id: "resp-1"),
            .textDelta("Working"),
            .toolCallStarted(AgentToolCall(id: "call-1", index: 0, name: "lookup")),
            .toolCallArgumentsDelta(id: "call-1", delta: #"{"q":"#),
            .toolCallArgumentsDelta(id: "call-1", delta: #""swift"}"#),
            .toolCallCompleted(
                call: AgentToolCall(id: "call-1", index: 0, name: "lookup"),
                arguments: .valid(.object(["q": .string("swift")]))
            ),
            .usage(.reported(inputTokens: 6, outputTokens: 3, totalTokens: 9, cachedInputTokens: nil)),
            .finished(.toolCalls),
        ])
    }

    @Test func openAIResponsesRequestBuilderSeparatesInstructionsFromInput() throws {
        let request = AgentModelRequest(
            model: "gpt-fixture",
            messages: [
                AgentModelMessage(role: .system, content: [.text("Be exact.")]),
                AgentModelMessage(role: .user, content: [.text("Research Swift")]),
            ],
            tools: [fixtureTool()],
            maxOutputTokens: 900,
            reasoningEffort: "low"
        )

        let body = try OpenAIResponsesRequestBuilder().makeBody(for: request)
        guard case .object(let object) = body else {
            Issue.record("Expected an object request body")
            return
        }

        #expect(object["model"] == .string("gpt-fixture"))
        #expect(object["instructions"] == .string("Be exact."))
        #expect(object["stream"] == .boolean(true))
        #expect(object["max_output_tokens"] == .number(900))
        #expect(object["reasoning"] == .object(["effort": .string("low")]))
        guard case .array(let input) = object["input"] else {
            Issue.record("Expected Responses input")
            return
        }
        #expect(input.count == 1)
    }

    @Test func anthropicMessageEventsNormalizeTextToolUsageAndFinish() throws {
        var parser = AnthropicMessagesStreamParser()
        let frames = [
            AgentProviderStreamFrame(event: "message_start", data: #"{"type":"message_start","message":{"id":"msg-1","usage":{"input_tokens":7}}}"#),
            AgentProviderStreamFrame(event: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Checking"}}"#),
            AgentProviderStreamFrame(event: "content_block_start", data: #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tool-1","name":"lookup","input":{}}}"#),
            AgentProviderStreamFrame(event: "content_block_delta", data: #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"q\":"}}"#),
            AgentProviderStreamFrame(event: "content_block_delta", data: #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"swift\"}"}}"#),
            AgentProviderStreamFrame(event: "content_block_stop", data: #"{"type":"content_block_stop","index":1}"#),
            AgentProviderStreamFrame(event: "message_delta", data: #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}"#),
            AgentProviderStreamFrame(event: "message_stop", data: #"{"type":"message_stop"}"#),
        ]

        let events = try frames.flatMap { try parser.consume($0) }

        #expect(events == [
            .responseStarted(id: "msg-1"),
            .textDelta("Checking"),
            .toolCallStarted(AgentToolCall(id: "tool-1", index: 1, name: "lookup")),
            .toolCallArgumentsDelta(id: "tool-1", delta: #"{"q":"#),
            .toolCallArgumentsDelta(id: "tool-1", delta: #""swift"}"#),
            .toolCallCompleted(
                call: AgentToolCall(id: "tool-1", index: 1, name: "lookup"),
                arguments: .valid(.object(["q": .string("swift")]))
            ),
            .usage(.reported(inputTokens: 7, outputTokens: 5, totalTokens: 12, cachedInputTokens: nil)),
            .finished(.toolCalls),
        ])
    }

    @Test func anthropicRequestBuilderUsesSystemMessagesAndInputSchemas() throws {
        let request = AgentModelRequest(
            model: "claude-fixture",
            messages: [
                AgentModelMessage(role: .system, content: [.text("Be careful.")]),
                AgentModelMessage(role: .user, content: [.text("Look this up")]),
            ],
            tools: [fixtureTool()],
            temperature: 0.4,
            maxOutputTokens: 700
        )

        let body = try AnthropicMessagesRequestBuilder().makeBody(for: request)
        guard case .object(let object) = body else {
            Issue.record("Expected an object request body")
            return
        }

        #expect(object["model"] == .string("claude-fixture"))
        #expect(object["system"] == .string("Be careful."))
        #expect(object["stream"] == .boolean(true))
        #expect(object["max_tokens"] == .number(700))
        guard case .array(let tools) = object["tools"] else {
            Issue.record("Expected Anthropic tools")
            return
        }
        #expect(tools.count == 1)
    }

    @Test func geminiChunksNormalizeTextFunctionCallUsageAndFinish() throws {
        var parser = GeminiGenerateContentStreamParser()
        let frames = [
            AgentProviderStreamFrame(data: #"{"candidates":[{"content":{"parts":[{"text":"Hel"}]}}]}"#),
            AgentProviderStreamFrame(data: #"{"candidates":[{"content":{"parts":[{"text":"lo"},{"functionCall":{"id":"call-1","name":"lookup","args":{"q":"swift"}}}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":4,"candidatesTokenCount":3,"totalTokenCount":7}}"#),
        ]

        let events = try frames.flatMap { try parser.consume($0) }

        #expect(events == [
            .responseStarted(id: nil),
            .textDelta("Hel"),
            .textDelta("lo"),
            .toolCallStarted(AgentToolCall(id: "call-1", index: 1, name: "lookup")),
            .toolCallArgumentsDelta(id: "call-1", delta: #"{"q":"swift"}"#),
            .toolCallCompleted(
                call: AgentToolCall(id: "call-1", index: 1, name: "lookup"),
                arguments: .valid(.object(["q": .string("swift")]))
            ),
            .usage(.reported(inputTokens: 4, outputTokens: 3, totalTokens: 7, cachedInputTokens: nil)),
            .finished(.toolCalls),
        ])
    }

    @Test func geminiRequestBuilderUsesSystemInstructionAndFunctionDeclarations() throws {
        let request = AgentModelRequest(
            model: "gemini-fixture",
            messages: [
                AgentModelMessage(role: .system, content: [.text("Stay grounded.")]),
                AgentModelMessage(role: .user, content: [.text("Find docs")]),
            ],
            tools: [fixtureTool()],
            responseFormat: .jsonObject
        )

        let body = try GeminiGenerateContentRequestBuilder().makeBody(for: request)
        guard case .object(let object) = body else {
            Issue.record("Expected an object request body")
            return
        }

        #expect(object["systemInstruction"] == .object([
            "parts": .array([.object(["text": .string("Stay grounded.")])]),
        ]))
        guard case .array(let tools) = object["tools"] else {
            Issue.record("Expected Gemini tools")
            return
        }
        #expect(tools.count == 1)
        guard case .object(let generationConfig) = object["generationConfig"] else {
            Issue.record("Expected generation configuration")
            return
        }
        #expect(generationConfig["responseMimeType"] == .string("application/json"))
    }

    @Test func sseDecoderHandlesChunkBoundariesCRLFAndMultilineData() throws {
        var decoder = AgentSSEDecoder()

        let first = try decoder.append(Data("event: delta\r\ndata: {\"text\":\"Hel".utf8))
        let second = try decoder.append(Data("lo\"}\r\n\r\ndata: first\ndata: second\n\n".utf8))

        #expect(first.isEmpty)
        #expect(second == [
            AgentProviderStreamFrame(event: "delta", data: #"{"text":"Hello"}"#),
            AgentProviderStreamFrame(data: "first\nsecond"),
        ])
    }

    @Test func malformedToolArgumentsBecomeAValidationEventInsteadOfAParserFailure() throws {
        var parser = OpenAICompatibleChatStreamParser()
        let frames = [
            AgentProviderStreamFrame(data: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"bad-call","function":{"name":"lookup","arguments":"{"}}]},"finish_reason":"tool_calls"}]}"#),
            AgentProviderStreamFrame(data: "[DONE]"),
        ]

        let events = try frames.flatMap { try parser.consume($0) }

        #expect(events.contains(.toolCallCompleted(
            call: AgentToolCall(id: "bad-call", index: 0, name: "lookup"),
            arguments: .malformed(raw: "{", reason: "Tool arguments were not valid JSON.")
        )))
        #expect(events.last == .finished(.toolCalls))
    }

    @Test func cancellingAStreamPreventsLateScriptedEvents() async throws {
        let adapter = ScriptedAgentProviderAdapter(script: [
            .event(.textDelta("before")),
            .delay(nanoseconds: 5_000_000_000),
            .event(.textDelta("late")),
            .event(.finished(.stop)),
        ])
        let request = AgentModelRequest(
            model: "scripted",
            messages: [AgentModelMessage(role: .user, content: [.text("Go")])]
        )
        let recorder = ProviderEventRecorder()
        let consumer = Task {
            do {
                for try await event in try adapter.events(for: request) {
                    await recorder.append(event)
                }
            } catch is CancellationError {
                // Expected cancellation is part of the public stream behavior.
            } catch {
                Issue.record("Unexpected stream failure: \(error.localizedDescription)")
            }
        }
        for _ in 0..<100 {
            if await recorder.count == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        consumer.cancel()
        await consumer.value
        try await Task.sleep(for: .milliseconds(20))

        let recorded = await recorder.events
        #expect(recorded == [.textDelta("before")])
    }

    @Test func unsupportedCapabilitiesFailBeforeAStreamStarts() throws {
        let adapter = ScriptedAgentProviderAdapter(
            capabilities: AgentProviderCapabilities([.streaming]),
            script: [.event(.finished(.stop))]
        )
        let request = AgentModelRequest(
            model: "scripted",
            messages: [AgentModelMessage(role: .user, content: [.text("Use a tool")])],
            tools: [fixtureTool()]
        )

        do {
            _ = try adapter.events(for: request)
            Issue.record("Expected capability preflight to fail")
        } catch let error as AgentProviderAdapterError {
            #expect(error.code == .unsupportedCapabilities)
            #expect(error.safeMessage.contains("toolCalling"))
        }
    }

    @Test func transientProviderFailuresRetryOnlyBeforeSideEffects() {
        let policy = AgentProviderRetryPolicy(maximumAttempts: 3)

        #expect(policy.decision(
            for: .transient,
            attempt: 1,
            hasCommittedSideEffect: false
        ) == .retry(after: nil))
        #expect(policy.decision(
            for: .rateLimited(retryAfter: 1.5),
            attempt: 2,
            hasCommittedSideEffect: false
        ) == .retry(after: 1.5))
        #expect(policy.decision(
            for: .transient,
            attempt: 1,
            hasCommittedSideEffect: true
        ) == .doNotRetry)
        #expect(policy.decision(
            for: .transient,
            attempt: 3,
            hasCommittedSideEffect: false
        ) == .doNotRetry)
        #expect(policy.decision(
            for: .permanent,
            attempt: 1,
            hasCommittedSideEffect: false
        ) == .doNotRetry)
    }

    @Test func providerErrorsDiscardUntrustedBodiesAndSecrets() {
        let secret = "Bearer sk-do-not-store"
        let error = AgentProviderAdapterError.httpStatus(
            providerID: "fixture",
            statusCode: 429,
            retryAfter: 2,
            untrustedResponseBody: #"{"error":"Bearer sk-do-not-store"}"#
        )
        let rendered = error.localizedDescription + String(describing: error)

        #expect(error.code == .rateLimited)
        #expect(error.retryClassification == .rateLimited(retryAfter: 2))
        #expect(!rendered.contains(secret))
        #expect(!rendered.contains("do-not-store"))
    }

    @Test func everyProviderFixtureProducesTheSameNormalizedStory() throws {
        var chat = OpenAICompatibleChatStreamParser()
        let chatEvents = try [
            AgentProviderStreamFrame(data: #"{"id":"shared","choices":[{"delta":{"content":"Hi"},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}"#),
            AgentProviderStreamFrame(data: "[DONE]"),
        ].flatMap { try chat.consume($0) }

        var responses = OpenAIResponsesStreamParser()
        let responseEvents = try [
            AgentProviderStreamFrame(data: #"{"type":"response.created","response":{"id":"shared"}}"#),
            AgentProviderStreamFrame(data: #"{"type":"response.output_text.delta","delta":"Hi"}"#),
            AgentProviderStreamFrame(data: #"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":2,"output_tokens":1,"total_tokens":3}}}"#),
        ].flatMap { try responses.consume($0) }

        var anthropic = AnthropicMessagesStreamParser()
        let anthropicEvents = try [
            AgentProviderStreamFrame(data: #"{"type":"message_start","message":{"id":"shared","usage":{"input_tokens":2}}}"#),
            AgentProviderStreamFrame(data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#),
            AgentProviderStreamFrame(data: #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#),
        ].flatMap { try anthropic.consume($0) }

        var gemini = GeminiGenerateContentStreamParser()
        let geminiEvents = try [
            AgentProviderStreamFrame(data: #"{"responseId":"shared","candidates":[{"content":{"parts":[{"text":"Hi"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":2,"candidatesTokenCount":1,"totalTokenCount":3}}"#),
        ].flatMap { try gemini.consume($0) }

        let expected: [AgentModelEvent] = [
            .responseStarted(id: "shared"),
            .textDelta("Hi"),
            .usage(.reported(inputTokens: 2, outputTokens: 1, totalTokens: 3, cachedInputTokens: nil)),
            .finished(.stop),
        ]
        #expect(chatEvents == expected)
        #expect(responseEvents == expected)
        #expect(anthropicEvents == expected)
        #expect(geminiEvents == expected)
    }

    @Test func absentProviderUsageIsExplicitlyUnknown() throws {
        var parser = OpenAICompatibleChatStreamParser()
        let events = try [
            AgentProviderStreamFrame(data: #"{"choices":[{"delta":{"content":"Done"},"finish_reason":"stop"}]}"#),
            AgentProviderStreamFrame(data: "[DONE]"),
        ].flatMap { try parser.consume($0) }

        #expect(events.suffix(2) == [
            .usage(.unknown),
            .finished(.stop),
        ])
    }

    @Test func normalizedRequestsAndEventsRoundTripAsDurableValues() throws {
        let request = AgentModelRequest(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            model: "fixture",
            messages: [AgentModelMessage(role: .user, content: [.text("Hello")])],
            tools: [fixtureTool()],
            temperature: 0.2,
            maxOutputTokens: 100,
            responseFormat: .jsonObject
        )
        let event = AgentModelEvent.toolCallCompleted(
            call: AgentToolCall(id: "call", index: 0, name: "lookup"),
            arguments: .malformed(raw: "{", reason: "Tool arguments were not valid JSON.")
        )

        let decodedRequest = try JSONDecoder().decode(
            AgentModelRequest.self,
            from: JSONEncoder().encode(request)
        )
        let decodedEvent = try JSONDecoder().decode(
            AgentModelEvent.self,
            from: JSONEncoder().encode(event)
        )

        #expect(decodedRequest == request)
        #expect(decodedEvent == event)
    }

    @Test func completedToolCallsRoundTripIntoEveryProviderContinuationRequest() throws {
        let invocation = AgentModelToolInvocation(
            call: AgentToolCall(id: "call-1", index: 0, name: "lookup"),
            arguments: .object(["q": .string("swift")])
        )
        let messages = [
            AgentModelMessage(role: .user, content: [.text("Find Swift")]),
            AgentModelMessage(role: .assistant, content: [.text("Checking"), .toolCall(invocation)]),
            AgentModelMessage(role: .tool, content: [.toolResult(AgentModelToolResult(
                callID: "call-1",
                toolName: "lookup",
                content: .object(["ok": .boolean(true)])
            ))]),
        ]
        let request = AgentModelRequest(model: "fixture", messages: messages, tools: [fixtureTool()])

        let chat = try OpenAICompatibleChatRequestBuilder().makeBody(for: request)
        let responses = try OpenAIResponsesRequestBuilder().makeBody(for: request)
        let anthropic = try AnthropicMessagesRequestBuilder().makeBody(for: request)
        let gemini = try GeminiGenerateContentRequestBuilder().makeBody(for: request)

        #expect(String(describing: chat).contains("tool_calls"))
        #expect(String(describing: responses).contains("function_call"))
        #expect(String(describing: anthropic).contains("tool_use"))
        #expect(String(describing: gemini).contains("functionCall"))
        #expect(try JSONDecoder().decode(
            AgentModelMessage.self,
            from: JSONEncoder().encode(messages[1])
        ) == messages[1])
    }

    private func collect(
        _ stream: AsyncThrowingStream<AgentModelEvent, Error>
    ) async throws -> [AgentModelEvent] {
        var events: [AgentModelEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    private func fixtureTool() -> AgentToolDescriptor {
        AgentToolDescriptor(
            name: "lookup",
            version: 1,
            description: "Look something up.",
            inputSchema: .object(
                ["q": .string(description: "Query")],
                required: ["q"]
            ),
            outputSchema: .object(),
            requiredCapabilities: [.pageRead],
            risk: .observe,
            origin: .browser,
            route: .browserNative,
            visibility: [.builtInAgent]
        )
    }
}

private actor ProviderEventRecorder {
    private(set) var events: [AgentModelEvent] = []
    var count: Int { events.count }

    func append(_ event: AgentModelEvent) {
        events.append(event)
    }
}
