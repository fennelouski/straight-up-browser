import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Browser

@MainActor
struct BrowserAgentTests {
    @Test func providerTemplatesCoverCloudLocalAndCustomEndpoints() {
        #expect(BrowserAgentProvider.allCases == [
            .openAI, .openRouter, .ollama, .lmStudio, .compatible,
        ])
        #expect(BrowserAgentProvider.openAI.defaultEndpoint.hasPrefix("https://"))
        #expect(BrowserAgentProvider.openRouter.defaultEndpoint.hasPrefix("https://"))
        #expect(BrowserAgentProvider.ollama.defaultEndpoint.contains("11434"))
        #expect(BrowserAgentProvider.lmStudio.defaultEndpoint.contains("1234"))
        #expect(BrowserAgentProvider.compatible.defaultEndpoint.isEmpty)
        #expect(!BrowserAgentProvider.openAI.defaultModel.isEmpty)
        #expect(!BrowserAgentProvider.openRouter.defaultModel.isEmpty)
        #expect(!BrowserAgentProvider.ollama.defaultModel.isEmpty)
        #expect(!BrowserAgentProvider.lmStudio.defaultModel.isEmpty)
        #expect(BrowserAgentProvider.compatible.defaultModel.isEmpty)
        #expect(BrowserAgentProvider.openAI.needsAPIKey)
        #expect(!BrowserAgentProvider.ollama.needsAPIKey)
        #expect(!BrowserAgentProvider.lmStudio.needsAPIKey)
    }

    @Test func builtInAgentToolCatalogueIsUniqueAndComplete() {
        let names = BrowserAgent.builtInToolNames
        #expect(names.count == 34)
        #expect(Set(names).count == names.count)
        #expect(names.contains("take_snapshot"))
        #expect(names.contains("wait_for"))
        #expect(names.contains("create_bookmark"))
        #expect(names.contains("write_file"))
        #expect(names.contains("delete_file"))
    }

    @Test func schedulesCalculateAllSupportedCadences() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let minutes = BrowserAgentTaskDefinition(
            name: "Minutes",
            prompt: "Run",
            scheduleKind: .minutes,
            interval: 5,
            dailyHour: 8,
            dailyMinute: 0,
            now: now
        )
        let hours = BrowserAgentTaskDefinition(
            name: "Hours",
            prompt: "Run",
            scheduleKind: .hours,
            interval: 3,
            dailyHour: 8,
            dailyMinute: 0,
            now: now
        )
        let daily = BrowserAgentTaskDefinition(
            name: "Daily",
            prompt: "Run",
            scheduleKind: .daily,
            interval: 1,
            dailyHour: 9,
            dailyMinute: 30,
            now: now
        )

        #expect(minutes.nextRunAt.timeIntervalSince(now) == 300)
        #expect(hours.nextRunAt.timeIntervalSince(now) == 10_800)
        #expect(daily.nextRunAt > now)
        #expect(daily.nextRunAt.timeIntervalSince(now) <= 86_400)
        #expect(minutes.scheduleDescription == "Every 5 minutes")
        #expect(hours.scheduleDescription == "Every 3 hours")
        #expect(daily.scheduleDescription == "Daily at 09:30")

        let run = BrowserAgentTaskRun(startedAt: Date().addingTimeInterval(-1), status: .succeeded, output: "Done")
        #expect(run.status == .succeeded)
        #expect(run.finishedAt >= run.startedAt)
        let roundTrip = try JSONDecoder().decode(
            BrowserAgentTaskDefinition.self,
            from: JSONEncoder().encode(minutes)
        )
        #expect(roundTrip.id == minutes.id)
        #expect(roundTrip.scheduleKind == .minutes)
    }

    @Test func invalidModelConfigurationBecomesAVisibleAgentError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-agent-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentRunStore(baseDirectory: directory)
        let agent = BrowserAgent(storageDirectory: directory, runStore: store)

        agent.submit(
            "Inspect this page",
            pageTitle: "Test",
            pageURL: "https://example.com",
            configuration: BrowserAgentConfiguration(
                provider: .compatible,
                endpoint: "",
                model: "",
                apiKey: ""
            ),
            execute: { _, _, _ in "{\"ok\":true}" }
        )
        for _ in 0..<100 where agent.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!agent.isRunning)
        #expect(agent.messages.map(\.role) == [.user, .error])
        #expect(agent.messages.last?.text.contains("valid endpoint") == true)
        let runs = await store.listRuns()
        let run = try #require(runs.first)
        #expect(run.status == .failed)
        #expect(run.entryPoint == .attended)
        #expect(run.configuration.provider?.endpointIdentity == "invalid")
        let persistedSteps = try await store.steps(runID: run.id)
        #expect(persistedSteps.map(\.kind).contains(.userMessage))
        #expect(persistedSteps.map(\.kind).contains(.error))
        let transitionCount = persistedSteps.reduce(into: 0) { count, step in
            if step.kind == .stateTransition { count += 1 }
        }
        #expect(transitionCount == 2)

        let conversationID = try #require(run.conversationID)
        let reopened = BrowserAgent(storageDirectory: directory, runStore: store)
        await reopened.openConversation(conversationID)
        #expect(reopened.messages.map(\.role) == [.user, .error])
        #expect(reopened.messages.first?.id == agent.messages.first?.id)
        agent.clear()
        #expect(agent.messages.isEmpty)
    }

    @Test func appConnectionDefinitionRoundTripsWithoutPersistingSecrets() throws {
        let connection = BrowserAgentMCPConnection(
            name: "Calendar",
            endpoint: "http://127.0.0.1:8000/mcp"
        )
        let decoded = try JSONDecoder().decode(
            BrowserAgentMCPConnection.self,
            from: JSONEncoder().encode(connection)
        )
        #expect(decoded == connection)
        #expect(decoded.enabled)
    }

    @Test func normalizedProviderStreamUpdatesThePanelAndPersistsUsageAndFinish() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-agent-stream-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentRunStore(baseDirectory: directory)
        let adapter = ScriptedAgentProviderAdapter(script: [
            .event(.responseStarted(id: "response-1")),
            .event(.textDelta("Hel")),
            .event(.textDelta("lo")),
            .event(.usage(.reported(
                inputTokens: 4,
                outputTokens: 2,
                totalTokens: 6,
                cachedInputTokens: nil
            ))),
            .event(.finished(.stop)),
        ])
        let agent = BrowserAgent(
            storageDirectory: directory,
            runStore: store,
            providerAdapterFactory: { _ in adapter }
        )

        agent.submit(
            "Say hello",
            pageTitle: "Test",
            pageURL: "https://example.com",
            configuration: fixtureConfiguration(apiKey: "never-persist-this-secret"),
            execute: { _, _, _ in "{}" }
        )
        for _ in 0..<200 where agent.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(agent.messages.last?.role == .assistant)
        #expect(agent.messages.last?.text == "Hello")
        let persistedRuns = await store.listRuns()
        let run = try #require(persistedRuns.first)
        #expect(run.status == .succeeded)
        #expect(run.configuration.provider?.supportsStreaming == true)
        let steps = try await store.steps(runID: run.id)
        #expect(steps.filter { $0.kind == .modelText }.count == 2)
        #expect(steps.contains { $0.kind == .usage && $0.summary.contains("6 tokens") })
        #expect(steps.contains {
            $0.kind == .system && $0.summary == "Provider stream finished"
        })
        let persisted = try persistedText(in: directory)
        #expect(!persisted.contains("never-persist-this-secret"))
    }

    @Test func cancellationOfAProviderStreamCannotExecuteALaterTool() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-agent-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentRunStore(baseDirectory: directory)
        let counter = ToolExecutionCounter()
        let call = AgentToolCall(id: "late-call", index: 0, name: "take_snapshot")
        let adapter = ScriptedAgentProviderAdapter(script: [
            .event(.textDelta("Working")),
            .delay(nanoseconds: 5_000_000_000),
            .event(.toolCallStarted(call)),
            .event(.toolCallCompleted(call: call, arguments: .valid(.object([:])))),
            .event(.usage(.unknown)),
            .event(.finished(.toolCalls)),
        ])
        let agent = BrowserAgent(
            storageDirectory: directory,
            runStore: store,
            providerAdapterFactory: { _ in adapter }
        )

        agent.submit(
            "Inspect",
            pageTitle: "Test",
            pageURL: "https://example.com",
            configuration: fixtureConfiguration(),
            execute: { _, _, _ in
                await counter.increment()
                return "{}"
            }
        )
        for _ in 0..<200 {
            if agent.messages.last?.text == "Working" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        agent.cancel()
        for _ in 0..<200 where agent.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }

        let executionCount = await counter.count
        let finalStatus = await store.listRuns().first?.status
        #expect(executionCount == 0)
        #expect(finalStatus == .cancelled)
    }

    @Test func newAgentSurfacesConstruct() {
        let agent = BrowserAgent(storageDirectory: FileManager.default.temporaryDirectory)
        let panel = BrowserAgentPanel(
            agent: agent,
            pageTitle: "Example",
            pageURL: "https://example.com",
            pageTarget: nil,
            onClose: {},
            execute: { _, _, _ in "{}" }
        )
        _ = panel.body
        _ = BrowserAgentMCPConnectionsView().body
        _ = BrowserAgentTasksView().body
        _ = BrowserAgentAuditView().body
    }

    private func fixtureConfiguration(apiKey: String = "fixture-key") -> BrowserAgentConfiguration {
        BrowserAgentConfiguration(
            provider: .compatible,
            endpoint: "https://provider.invalid/v1/chat/completions",
            model: "fixture-model",
            apiKey: apiKey
        )
    }

    private func persistedText(in directory: URL) throws -> String {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var text = ""
        while let url = enumerator?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  let data = try? Data(contentsOf: url),
                  let value = String(data: data, encoding: .utf8) else { continue }
            text += value
        }
        return text
    }
}

private actor ToolExecutionCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
