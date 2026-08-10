import Foundation
import Testing
@testable import Browser

@Suite("Agent memory runtime")
@MainActor
struct AgentMemoryRuntimeTests {
    @Test("Model memory search stays in the exact Run scope and records consumption")
    func modelSearchIsScopedAndAuditable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: AgentMemorySettings.Key.enabled)
        fixture.defaults.set(8, forKey: AgentMemorySettings.Key.maximumRetrievedEntries)
        let controller = AgentMemoryController(
            baseDirectory: fixture.baseURL,
            defaults: fixture.defaults
        )

        let matchingID = try await propose(
            "scope sentinel for the active origin",
            scope: "origin",
            pageURL: "https://allowed.example/first",
            browserSession: .normal,
            using: controller
        )
        let otherOriginID = try await propose(
            "scope sentinel for another origin",
            scope: "origin",
            pageURL: "https://private.example/",
            browserSession: .normal,
            using: controller
        )
        let otherSessionID = try await propose(
            "scope sentinel for another browser Session",
            scope: "origin",
            pageURL: "https://allowed.example/in-container",
            browserSession: .container(UUID()),
            using: controller
        )

        let searchRunID = UUID()
        let sourceStepID = UUID()
        let searched = await controller.call(
            "search_agent_memory",
            arguments: ["query": "scope sentinel", "limit": 8],
            permit: permit(runID: searchRunID, tool: "search_agent_memory"),
            conversationID: nil,
            taskID: nil,
            pageURL: "https://allowed.example/current",
            browserSession: .normal,
            sourceStepID: sourceStepID
        )
        let searchedJSON = try object(searched)
        let values = try #require(searchedJSON["entries"] as? [[String: Any]])
        #expect(values.compactMap { $0["memoryId"] as? String } == [matchingID])

        // The user-facing manager remains an intentionally unscoped review of
        // the separate memory store, while model-facing search is bounded.
        await controller.refresh()
        #expect(Set(controller.entries.map { $0.id.uuidString }) == Set([
            matchingID, otherOriginID, otherSessionID,
        ]))
        let matching = try #require(controller.entries.first {
            $0.id.uuidString == matchingID
        })
        #expect(matching.consumptions.contains {
            $0.runID == searchRunID && $0.stepID == sourceStepID
        })
        let inaccessibleEntries = controller.entries.filter {
            $0.id.uuidString == otherOriginID || $0.id.uuidString == otherSessionID
        }
        #expect(inaccessibleEntries.allSatisfy { $0.consumptions.isEmpty })

        let rejectedForget = await controller.call(
            "forget_agent_memory",
            arguments: ["memoryId": otherOriginID],
            permit: permit(runID: searchRunID, tool: "forget_agent_memory"),
            conversationID: nil,
            taskID: nil,
            pageURL: "https://allowed.example/current",
            browserSession: .normal,
            sourceStepID: UUID()
        )
        let rejectedForgetJSON = try object(rejectedForget)
        #expect((rejectedForgetJSON["deleted"] as? [String])?.isEmpty == true)
        await controller.refresh()
        #expect(controller.entries.contains { $0.id.uuidString == otherOriginID })
    }

    @Test("Explicit proposals are scoped, retrieved as untrusted data, and independently forgotten")
    func proposalRetrievalAndForget() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: AgentMemorySettings.Key.enabled)
        let controller = AgentMemoryController(
            baseDirectory: fixture.baseURL,
            defaults: fixture.defaults
        )
        let runID = UUID()
        let sourceStepID = UUID()

        let proposed = await controller.call(
            "propose_agent_memory",
            arguments: [
                "text": "The user prefers compact tab titles.",
                "scope": "origin",
                "sensitivity": "preference",
            ],
            permit: permit(runID: runID, tool: "propose_agent_memory"),
            conversationID: nil,
            taskID: nil,
            pageURL: "https://example.com/path?private=1",
            browserSession: .normal,
            sourceStepID: sourceStepID
        )
        let proposedJSON = try object(proposed)
        #expect(proposedJSON["stored"] as? Bool == true)
        let memoryID = try #require(proposedJSON["memoryId"] as? String)

        let retrieved = try #require(await controller.retrieve(
            runID: UUID(),
            stepID: UUID(),
            conversationID: nil,
            taskID: nil,
            pageURL: "https://example.com/another-path",
            browserSession: .normal,
            query: "compact tab"
        ))
        #expect(retrieved.entries.count == 1)
        #expect(retrieved.entries[0].canGrantAuthority == false)
        #expect(retrieved.entries[0].role == .untrustedMemoryObservation)
        #expect(retrieved.entries[0].text == "The user prefers compact tab titles.")

        let forgotten = await controller.call(
            "forget_agent_memory",
            arguments: ["memoryId": memoryID],
            permit: permit(runID: runID, tool: "forget_agent_memory"),
            conversationID: nil,
            taskID: nil,
            pageURL: "https://example.com/",
            browserSession: .normal,
            sourceStepID: UUID()
        )
        let forgottenJSON = try object(forgotten)
        #expect((forgottenJSON["deleted"] as? [String]) == [memoryID])
        #expect(forgottenJSON["historyUnaffected"] as? Bool == true)
        #expect(forgottenJSON["conversationsUnaffected"] as? Bool == true)
    }

    @Test("Disabled and Incognito runs fail closed")
    func privacyDefaults() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let controller = AgentMemoryController(
            baseDirectory: fixture.baseURL,
            defaults: fixture.defaults
        )
        let runID = UUID()
        let disabled = await controller.call(
            "propose_agent_memory",
            arguments: [
                "text": "Do not retain this.",
                "scope": "global",
                "sensitivity": "preference",
            ],
            permit: permit(runID: runID, tool: "propose_agent_memory"),
            conversationID: nil,
            taskID: nil,
            pageURL: "https://example.com/",
            browserSession: .normal,
            sourceStepID: UUID()
        )
        #expect((try object(disabled))["error"] as? String == "Agent memory is disabled in Settings.")

        fixture.defaults.set(true, forKey: AgentMemorySettings.Key.enabled)
        let normalMemoryID = try await propose(
            "Private browsing must not reveal this durable memory.",
            scope: "global",
            pageURL: "https://example.com/",
            browserSession: .normal,
            using: controller
        )
        let incognito = await controller.call(
            "propose_agent_memory",
            arguments: [
                "text": "Still do not retain this.",
                "scope": "global",
                "sensitivity": "preference",
            ],
            permit: permit(runID: runID, tool: "propose_agent_memory"),
            conversationID: nil,
            taskID: nil,
            pageURL: "https://example.com/",
            browserSession: .incognito,
            sourceStepID: UUID()
        )
        #expect((try object(incognito))["stored"] as? Bool == false)
        #expect(await controller.retrieve(
            runID: runID,
            stepID: nil,
            conversationID: nil,
            taskID: nil,
            pageURL: "https://example.com/",
            browserSession: .incognito,
            query: "retain"
        )?.entries.isEmpty == true)

        let incognitoSearch = await controller.call(
            "search_agent_memory",
            arguments: ["query": "durable memory", "limit": 8],
            permit: permit(runID: runID, tool: "search_agent_memory"),
            conversationID: nil,
            taskID: nil,
            pageURL: "https://example.com/",
            browserSession: .incognito,
            sourceStepID: UUID()
        )
        let incognitoSearchJSON = try object(incognitoSearch)
        #expect((incognitoSearchJSON["entries"] as? [[String: Any]])?.isEmpty == true)
        #expect((incognitoSearchJSON["suppressionReason"] as? String)?.contains("Incognito") == true)
        await controller.refresh()
        #expect(controller.entries.contains { $0.id.uuidString == normalMemoryID })
    }

    private func permit(runID: UUID, tool: String) -> AgentExecutionPermit {
        AgentExecutionPermit(
            runID: runID,
            toolName: tool,
            invocationDigest: "fixture-\(tool)",
            decisionStepID: UUID()
        )
    }

    private func propose(
        _ text: String,
        scope: String,
        pageURL: String,
        browserSession: AgentBrowserSession,
        using controller: AgentMemoryController
    ) async throws -> String {
        let proposed = await controller.call(
            "propose_agent_memory",
            arguments: [
                "text": text,
                "scope": scope,
                "sensitivity": "preference",
            ],
            permit: permit(runID: UUID(), tool: "propose_agent_memory"),
            conversationID: nil,
            taskID: nil,
            pageURL: pageURL,
            browserSession: browserSession,
            sourceStepID: UUID()
        )
        return try #require(try object(proposed)["memoryId"] as? String)
    }

    private func object(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private struct Fixture {
        let baseURL: URL
        let defaults: UserDefaults
        let suiteName: String

        init() throws {
            baseURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("agent-memory-runtime-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
            suiteName = "AgentMemoryRuntimeTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: baseURL)
        }
    }
}
