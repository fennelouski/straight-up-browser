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
}

private actor ProviderRequestRecorder {
    private(set) var request: URLRequest?
    func record(_ request: URLRequest) { self.request = request }
}

private struct FixtureProviderTransport: AgentProviderHTTPTransport {
    let recorder: ProviderRequestRecorder
    let response: AgentProviderHTTPResponse

    func response(for request: URLRequest) async throws -> AgentProviderHTTPResponse {
        await recorder.record(request)
        return response
    }
}
