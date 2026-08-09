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
        #expect(names.contains("wait_for_page"))
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
        let agent = BrowserAgent(storageDirectory: directory)

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
            execute: { _, _ in "{\"ok\":true}" }
        )
        for _ in 0..<100 where agent.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!agent.isRunning)
        #expect(agent.messages.map(\.role) == [.user, .error])
        #expect(agent.messages.last?.text.contains("valid endpoint") == true)
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

    @Test func newAgentSurfacesConstruct() {
        let agent = BrowserAgent(storageDirectory: FileManager.default.temporaryDirectory)
        let panel = BrowserAgentPanel(
            agent: agent,
            pageTitle: "Example",
            pageURL: "https://example.com",
            onClose: {},
            execute: { _, _ in "{}" }
        )
        _ = panel.body
        _ = BrowserAgentMCPConnectionsView().body
        _ = BrowserAgentTasksView().body
        _ = BrowserAgentAuditView().body
    }
}
