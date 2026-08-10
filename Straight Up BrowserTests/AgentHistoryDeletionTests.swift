import Foundation
import Testing
@testable import Browser

@MainActor
struct AgentHistoryDeletionTests {
    @Test func fullDeletionRemovesEveryHistoryOwnerAndPreservesSeparateSettings() async throws {
        let root = temporaryDirectory("agent-history-delete")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let store = try AgentRunStore(baseDirectory: root)
        let conversation = try await store.createConversation(title: "Private prompt")
        let run = try await store.createRun(
            conversationID: conversation.id,
            entryPoint: .attended
        )
        _ = try await store.transitionRun(
            run.id,
            to: .running,
            reason: "Started"
        )
        _ = try await store.appendStep(
            runID: run.id,
            kind: .modelText,
            summary: "Private page body"
        )
        _ = try await store.transitionRun(
            run.id,
            to: .succeeded,
            reason: "Finished"
        )

        let legacyConversationDirectory = root.appendingPathComponent(
            "agent-conversations",
            isDirectory: true
        )
        let legacyAuditDirectory = root.appendingPathComponent(
            "agent-audit/session",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: legacyConversationDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: legacyAuditDirectory,
            withIntermediateDirectories: true
        )
        try Data("legacy prompt".utf8).write(
            to: legacyConversationDirectory.appendingPathComponent("history.json")
        )
        try Data("legacy audit body".utf8).write(
            to: legacyAuditDirectory.appendingPathComponent("frame.png")
        )
        try Data("legacy scheduler output".utf8).write(
            to: root.appendingPathComponent("agent-tasks.json")
        )

        let schedules = root.appendingPathComponent("agent/schedules.json")
        let mcpConnections = root.appendingPathComponent(
            "agent-mcp-connections.json"
        )
        let scopedMemory = root.appendingPathComponent("agent-memory.json")
        let localMetrics = root.appendingPathComponent("agent-metrics.json")
        for (url, marker) in [
            (schedules, "schedule definitions"),
            (mcpConnections, "mcp settings"),
            (scopedMemory, "scoped memory"),
            (localMetrics, "local metrics"),
        ] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(marker.utf8).write(to: url)
        }
        let excludedFiles = [schedules, mcpConnections, scopedMemory, localMetrics]
        let excludedBytes = try Dictionary(uniqueKeysWithValues: excludedFiles.map {
            ($0, try Data(contentsOf: $0))
        })
        var schedulerClearCount = 0
        var coworkCleanupCount = 0

        let report = try await AgentCompleteHistoryDeletionCoordinator.deleteAll(
            store: store,
            baseDirectory: root,
            clearScheduledHistory: {
                schedulerClearCount += 1
                return 3
            },
            clearCoworkPrivateWorkspaces: {
                coworkCleanupCount += 1
                return 2
            }
        )

        #expect(report.deletedRuns == 1)
        #expect(report.deletedConversations == 1)
        #expect(report.deletedScheduledOccurrenceRecords == 3)
        #expect(report.deletedCoworkWorkspaces == 2)
        #expect(report.retiredLegacySources >= 3)
        #expect(schedulerClearCount == 1)
        #expect(coworkCleanupCount == 1)
        #expect(await store.listRuns().isEmpty)
        #expect(try await store.listConversations().isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: legacyConversationDirectory.path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("agent-audit").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("agent-tasks.json").path
        ))
        for file in excludedFiles {
            #expect(try Data(contentsOf: file) == excludedBytes[file])
        }
    }

    @Test func activeRunFailsBeforeAnyOtherHistoryOwnerIsMutated() async throws {
        let root = temporaryDirectory("agent-history-active")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentRunStore(baseDirectory: root)
        _ = try await store.createRun(
            conversationID: nil,
            entryPoint: .attended
        )
        let legacy = root.appendingPathComponent("agent-tasks.json")
        try Data("must remain".utf8).write(to: legacy)
        var schedulerWasCleared = false
        var coworkWasCleared = false

        await #expect(throws: AgentCompleteHistoryDeletionError.activeRuns(1)) {
            try await AgentCompleteHistoryDeletionCoordinator.deleteAll(
                store: store,
                baseDirectory: root,
                clearScheduledHistory: {
                    schedulerWasCleared = true
                    return 0
                },
                clearCoworkPrivateWorkspaces: {
                    coworkWasCleared = true
                    return 0
                }
            )
        }

        #expect(!schedulerWasCleared)
        #expect(!coworkWasCleared)
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        #expect(await store.listRuns().count == 1)
    }

    @Test func coworkCleanupFailureLeavesRunEvidenceAndLegacySourcesForRetry() async throws {
        enum InjectedFailure: Error { case coworkCleanup }

        let root = temporaryDirectory("agent-history-cowork-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentRunStore(baseDirectory: root)
        let conversation = try await store.createConversation(title: "Retry evidence")
        let run = try await store.createRun(
            conversationID: conversation.id,
            entryPoint: .attended
        )
        _ = try await store.transitionRun(run.id, to: .running, reason: "Start")
        let retainedStep = try await store.appendStep(
            runID: run.id,
            kind: .modelText,
            summary: "Evidence must remain"
        )
        _ = try await store.transitionRun(run.id, to: .succeeded, reason: "Done")
        let legacyTask = root.appendingPathComponent("agent-tasks.json")
        try Data("legacy scheduler output".utf8).write(to: legacyTask)
        let legacyConversations = root.appendingPathComponent(
            "agent-conversations",
            isDirectory: true
        )
        let legacyAudit = root.appendingPathComponent(
            "agent-audit",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: legacyConversations,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: legacyAudit,
            withIntermediateDirectories: true
        )
        let legacyConversationSource = legacyConversations
            .appendingPathComponent("conversation.json")
        let legacyAuditSource = legacyAudit.appendingPathComponent("audit.jsonl")
        try Data("legacy conversation".utf8).write(to: legacyConversationSource)
        try Data("legacy audit".utf8).write(to: legacyAuditSource)
        var schedulerWasCleared = false

        await #expect(throws: InjectedFailure.coworkCleanup) {
            try await AgentCompleteHistoryDeletionCoordinator.deleteAll(
                store: store,
                baseDirectory: root,
                clearScheduledHistory: {
                    schedulerWasCleared = true
                    let data = try JSONEncoder().encode(
                        AgentTaskSchedulerSnapshot()
                    )
                    try BrowserAgentScheduleSnapshotPersistence.persist(
                        data,
                        to: root.appendingPathComponent("agent/schedules.json"),
                        retiring: legacyTask
                    )
                    return 1
                },
                clearCoworkPrivateWorkspaces: {
                    throw InjectedFailure.coworkCleanup
                }
            )
        }

        #expect(schedulerWasCleared)
        #expect(await store.run(id: run.id)?.status == .succeeded)
        #expect(try await store.steps(runID: run.id).contains(retainedStep))
        #expect(try await store.listConversations().map(\.id).contains(
            conversation.id
        ))
        #expect(!FileManager.default.fileExists(atPath: legacyTask.path))
        #expect(FileManager.default.fileExists(
            atPath: legacyConversationSource.path
        ))
        #expect(FileManager.default.fileExists(atPath: legacyAuditSource.path))
        #expect(AgentHistoryDeletionController.failureOutcome(
            for: InjectedFailure.coworkCleanup
        ).message.contains("partially completed"))
        let reopened = try AgentRunStore(baseDirectory: root)
        #expect(await reopened.run(id: run.id)?.status == .succeeded)
        #expect(try await reopened.steps(runID: run.id).contains(retainedStep))
    }

    @Test func legacyRetirementRejectsSymlinksBeforeDeletingSafeSources() throws {
        let root = temporaryDirectory("agent-history-legacy-symlink")
        let outside = temporaryDirectory("agent-history-outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let conversations = root.appendingPathComponent(
            "agent-conversations",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: conversations,
            withIntermediateDirectories: true
        )
        let safeSource = conversations.appendingPathComponent("safe.json")
        try Data("history".utf8).write(to: safeSource)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("agent-audit"),
            withDestinationURL: outside
        )

        #expect(throws: AgentLegacySourceRetirementError.self) {
            try AgentLegacyMigrationCoordinator.retireSources(
                baseDirectory: root
            )
        }
        #expect(FileManager.default.fileExists(atPath: safeSource.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    private func temporaryDirectory(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
