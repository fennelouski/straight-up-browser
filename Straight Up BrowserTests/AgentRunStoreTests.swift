import Foundation
import Testing
@testable import Browser

struct AgentRunStoreTests {
    @Test func legacyBundleInstallIsDurableOwnerOnlyAndIdempotent() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let bytes = Data("""
        [{"createdAt":725760000,"id":"ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB","role":"user","text":"Research this"},{"createdAt":725760002,"id":"33333333-3333-4333-8333-333333333333","role":"assistant","text":"Done."}]
        """.utf8)
        let bundle = try LegacyAgentImporter().parseConversation(
            bytes,
            sourceName: "\(conversationID.uuidString).json"
        )
        let store = try AgentRunStore(baseDirectory: root)

        #expect(try await store.importLegacyBundle(bundle) == .inserted)
        #expect(try await store.importLegacyBundle(bundle) == .alreadyImported)
        let runID = try #require(bundle.runs.first?.run.id)
        #expect(await store.run(id: runID)?.importedFromLegacy == true)
        #expect(try await store.steps(runID: runID) == bundle.runs[0].steps)

        let reopened = try AgentRunStore(baseDirectory: root)
        #expect(await reopened.run(id: runID) == bundle.runs[0].run)
        #expect(try await reopened.listConversations().first?.id == conversationID)
        let migrationDirectory = root.appendingPathComponent("agent/migrations", isDirectory: true)
        #expect(try permissions(of: migrationDirectory) == 0o700)
        let receipt = try #require(
            FileManager.default.contentsOfDirectory(at: migrationDirectory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" }
        )
        #expect(try permissions(of: receipt) == 0o600)
    }

    @Test func launchMigrationDiscoversKnownSourcesAndLeavesLegacyFilesUntouched() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyDirectory = root.appendingPathComponent("agent-conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let source = legacyDirectory.appendingPathComponent(
            "22222222-2222-4222-8222-222222222222.json"
        )
        try Data("""
        [{"createdAt":725760000,"id":"ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB","role":"user","text":"Keep me"},{"createdAt":725760001,"id":"33333333-3333-4333-8333-333333333333","role":"assistant","text":"Kept."}]
        """.utf8).write(to: source)
        let store = try AgentRunStore(baseDirectory: root)

        let first = await AgentLegacyMigrationCoordinator.migrate(baseDirectory: root, into: store)
        let second = await AgentLegacyMigrationCoordinator.migrate(baseDirectory: root, into: store)

        #expect(first.inserted == 1)
        #expect(first.failed == 0)
        #expect(second.alreadyImported == 1)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try await store.listConversations().count == 1)
    }

    @Test func storeUsesOwnerOnlyPermissions() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try AgentRunStore(baseDirectory: root)
        let conversation = try await store.createConversation(title: "Private")
        let run = try await store.createRun(
            conversationID: conversation.id,
            entryPoint: .attended
        )
        _ = try await store.appendStep(
            runID: run.id,
            kind: .userMessage,
            summary: "Sensitive content"
        )

        let agent = root.appendingPathComponent("agent", isDirectory: true)
        let conversations = agent.appendingPathComponent("conversations", isDirectory: true)
        let runs = agent.appendingPathComponent("runs", isDirectory: true)
        let runDirectory = runs.appendingPathComponent(run.id.uuidString, isDirectory: true)
        for directory in [agent, conversations, runs, runDirectory] {
            #expect(try permissions(of: directory) == 0o700)
        }
        for file in [
            conversations.appendingPathComponent("index.json"),
            runs.appendingPathComponent("index.json"),
            runDirectory.appendingPathComponent("metadata.json"),
            runDirectory.appendingPathComponent("steps.jsonl"),
        ] {
            #expect(try permissions(of: file) == 0o600)
        }
    }

    @Test func truncatedFinalStepDoesNotCorruptEarlierSteps() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try AgentRunStore(baseDirectory: root)
        let run = try await store.createRun(conversationID: nil, entryPoint: .scheduled)
        let retained = try await store.appendStep(
            runID: run.id,
            kind: .system,
            summary: "Persisted before crash"
        )
        let stepsURL = stepsURL(root: root, runID: run.id)
        let handle = try FileHandle(forWritingTo: stepsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"schemaVersion\":1".utf8))
        try handle.close()

        let steps = try await store.steps(runID: run.id)
        #expect(steps == [retained])
    }

    @Test func appendAfterTruncatedFinalStepReplacesIncompleteTail() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try AgentRunStore(baseDirectory: root)
        let run = try await store.createRun(conversationID: nil, entryPoint: .scheduled)
        let first = try await store.appendStep(runID: run.id, kind: .system, summary: "First")
        let handle = try FileHandle(forWritingTo: stepsURL(root: root, runID: run.id))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"incomplete\":".utf8))
        try handle.close()

        let second = try await store.appendStep(runID: run.id, kind: .system, summary: "Second")

        #expect(second.sequence == 1)
        #expect(try await store.steps(runID: run.id) == [first, second])
    }

    @Test func malformedCompleteStepIsRejected() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try AgentRunStore(baseDirectory: root)
        let run = try await store.createRun(conversationID: nil, entryPoint: .scheduled)
        _ = try await store.appendStep(runID: run.id, kind: .system, summary: "Valid")
        let handle = try FileHandle(forWritingTo: stepsURL(root: root, runID: run.id))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))
        try handle.close()

        await #expect(throws: AgentRunStoreError.self) {
            try await store.steps(runID: run.id)
        }
    }

    @Test func blankCompleteStepIsRejected() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try AgentRunStore(baseDirectory: root)
        let run = try await store.createRun(conversationID: nil, entryPoint: .scheduled)
        let handle = try FileHandle(forWritingTo: stepsURL(root: root, runID: run.id))
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()

        await #expect(throws: AgentRunStoreError.self) {
            try await store.steps(runID: run.id)
        }
    }

    @Test func recoveryInterruptsPersistedActiveRunsExactlyOnce() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let recoveryDate = start.addingTimeInterval(10)

        let store = try AgentRunStore(baseDirectory: root)
        let queued = try await store.createRun(conversationID: nil, entryPoint: .scheduled, at: start)
        let running = try await store.createRun(conversationID: nil, entryPoint: .attended, at: start)
        _ = try await store.transitionRun(running.id, to: .running, reason: "Start", at: start)
        let waiting = try await store.createRun(conversationID: nil, entryPoint: .localMCP, at: start)
        _ = try await store.transitionRun(waiting.id, to: .running, reason: "Start", at: start)
        _ = try await store.transitionRun(
            waiting.id,
            to: .waitingForApproval,
            reason: "Approval",
            at: start
        )
        let waitingForHuman = try await store.createRun(
            conversationID: nil,
            entryPoint: .scheduled,
            at: start
        )
        _ = try await store.transitionRun(waitingForHuman.id, to: .running, reason: "Start", at: start)
        _ = try await store.transitionRun(
            waitingForHuman.id,
            to: .waitingForHuman,
            reason: "Human handoff",
            at: start
        )
        let completed = try await store.createRun(conversationID: nil, entryPoint: .commandLine, at: start)
        _ = try await store.transitionRun(completed.id, to: .running, reason: "Start", at: start)
        _ = try await store.transitionRun(completed.id, to: .succeeded, reason: "Done", at: start)

        let recoveringStore = try AgentRunStore(baseDirectory: root)
        let recovered = try await recoveringStore.recoverInterruptedRuns(at: recoveryDate)
        let recoveredAgain = try await recoveringStore.recoverInterruptedRuns(
            at: recoveryDate.addingTimeInterval(1)
        )

        #expect(Set(recovered.map(\.runID)) == [queued.id, running.id, waiting.id, waitingForHuman.id])
        #expect(recovered.allSatisfy { $0.kind == .stateTransition && $0.timestamp == recoveryDate })
        #expect(recoveredAgain.isEmpty)
        #expect(await recoveringStore.run(id: queued.id)?.status == .interrupted)
        #expect(await recoveringStore.run(id: running.id)?.status == .interrupted)
        #expect(await recoveringStore.run(id: waiting.id)?.status == .interrupted)
        #expect(await recoveringStore.run(id: waitingForHuman.id)?.status == .interrupted)
        #expect(await recoveringStore.run(id: completed.id)?.status == .succeeded)

        let reopened = try AgentRunStore(baseDirectory: root)
        #expect(await reopened.run(id: queued.id)?.status == .interrupted)
        #expect(try await reopened.steps(runID: queued.id).map(\.sequence) == [0])
        #expect(try await reopened.steps(runID: running.id).map(\.sequence) == [0, 1])
        #expect(try await reopened.steps(runID: waiting.id).map(\.sequence) == [0, 1, 2])
    }

    @Test func interruptedRunRequiresExplicitResumeToQueued() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try AgentRunStore(baseDirectory: root)
        let run = try await store.createRun(conversationID: nil, entryPoint: .attended)
        _ = try await store.recoverInterruptedRuns()
        let resumed = try await store.transitionRun(
            run.id,
            to: .queued,
            reason: "User chose to resume"
        )

        #expect(resumed.sequence == 1)
        #expect(await store.run(id: run.id)?.status == .queued)
        let reopened = try AgentRunStore(baseDirectory: root)
        #expect(await reopened.run(id: run.id)?.status == .queued)
        #expect(try await reopened.steps(runID: run.id).map(\.sequence) == [0, 1])
    }

    @Test func createRunPreservesExplicitIdentityAndOriginMetadata() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = UUID()
        let taskDefinitionID = UUID()
        let parentRunID = UUID()
        let runGroupID = UUID()

        let store = try AgentRunStore(baseDirectory: root)
        let run = try await store.createRun(
            id: runID,
            conversationID: nil,
            taskDefinitionID: taskDefinitionID,
            parentRunID: parentRunID,
            runGroupID: runGroupID,
            entryPoint: .childRun,
            incognito: true,
            importedFromLegacy: true
        )

        #expect(run.id == runID)
        #expect(run.taskDefinitionID == taskDefinitionID)
        #expect(run.parentRunID == parentRunID)
        #expect(run.runGroupID == runGroupID)
        #expect(run.entryPoint == .childRun)
        #expect(run.incognito)
        #expect(run.importedFromLegacy)
        let reopened = try AgentRunStore(baseDirectory: root)
        #expect(await reopened.run(id: runID) == run)
    }

    @Test func runQueriesUseMetadataFiltersWithoutReadingSteps() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let instant = Date(timeIntervalSince1970: 2_000_000_000)
        let taskID = UUID()
        let parentID = UUID()
        let providerA = AgentConfigurationSnapshot(provider: AgentProviderSnapshot(
            providerID: "provider-a",
            model: "one",
            endpointIdentity: "local"
        ))
        let providerB = AgentConfigurationSnapshot(provider: AgentProviderSnapshot(
            providerID: "provider-b",
            model: "two",
            endpointIdentity: "local"
        ))

        let store = try AgentRunStore(baseDirectory: root)
        let firstConversation = try await store.createConversation(title: "First", at: instant)
        let secondConversation = try await store.createConversation(title: "Second", at: instant)
        let first = try await store.createRun(
            conversationID: firstConversation.id,
            taskDefinitionID: taskID,
            parentRunID: parentID,
            entryPoint: .scheduled,
            configuration: providerA,
            at: instant.addingTimeInterval(10)
        )
        _ = try await store.transitionRun(first.id, to: .running, reason: "Start")
        let second = try await store.createRun(
            conversationID: firstConversation.id,
            entryPoint: .attended,
            configuration: providerB,
            at: instant.addingTimeInterval(20)
        )
        let third = try await store.createRun(
            conversationID: secondConversation.id,
            entryPoint: .localMCP,
            configuration: providerA,
            at: instant.addingTimeInterval(30)
        )
        _ = try await store.transitionRun(third.id, to: .running, reason: "Start")

        let corruptHandle = try FileHandle(forWritingTo: stepsURL(root: root, runID: first.id))
        try corruptHandle.seekToEnd()
        try corruptHandle.write(contentsOf: Data("malformed-complete-record\n".utf8))
        try corruptHandle.close()

        #expect(await store.listRuns(matching: AgentRunQuery(
            conversationID: firstConversation.id
        )).map(\.id) == [second.id, first.id])
        #expect(await store.listRuns(matching: AgentRunQuery(
            taskDefinitionID: taskID
        )).map(\.id) == [first.id])
        #expect(Set(await store.listRuns(matching: AgentRunQuery(
            status: .running
        )).map(\.id)) == [first.id, third.id])
        #expect(Set(await store.listRuns(matching: AgentRunQuery(
            providerID: "provider-a"
        )).map(\.id)) == [first.id, third.id])
        #expect(await store.listRuns(matching: AgentRunQuery(
            createdAtInterval: DateInterval(
                start: instant.addingTimeInterval(5),
                end: instant.addingTimeInterval(15)
            )
        )).map(\.id) == [first.id])
        #expect(await store.listRuns(matching: AgentRunQuery(
            parentRunID: parentID
        )).map(\.id) == [first.id])
    }

    @Test func deletingOneRunPreservesConversationSiblingsAndUnrelatedRuns() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try AgentRunStore(baseDirectory: root)
        let conversation = try await store.createConversation(title: "Keep thread")
        let deleted = try await store.createRun(
            conversationID: conversation.id,
            entryPoint: .attended
        )
        let sibling = try await store.createRun(
            conversationID: conversation.id,
            entryPoint: .attended
        )
        let unrelated = try await store.createRun(conversationID: nil, entryPoint: .scheduled)
        let deletedDirectory = runDirectory(root: root, runID: deleted.id)
        let artifactDirectory = deletedDirectory.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)

        try await store.deleteRun(id: deleted.id)

        #expect(await store.run(id: deleted.id) == nil)
        #expect(await store.run(id: sibling.id) != nil)
        #expect(await store.run(id: unrelated.id) != nil)
        #expect(!FileManager.default.fileExists(atPath: deletedDirectory.path))
        #expect(FileManager.default.fileExists(atPath: runDirectory(root: root, runID: sibling.id).path))
        let updatedConversation = try #require(try await store.listConversations().first {
            $0.id == conversation.id
        })
        #expect(updatedConversation.runIDs == [sibling.id])

        let reopened = try AgentRunStore(baseDirectory: root)
        #expect(await reopened.run(id: deleted.id) == nil)
        #expect(await reopened.run(id: sibling.id) != nil)
        #expect(await reopened.run(id: unrelated.id) != nil)
        let reopenedConversation = try #require(try await reopened.listConversations().first {
            $0.id == conversation.id
        })
        #expect(reopenedConversation.runIDs == [sibling.id])
    }

    @Test func deletingConversationCascadesItsRunDirectoriesOnly() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try AgentRunStore(baseDirectory: root)
        let deletedConversation = try await store.createConversation(title: "Delete")
        let preservedConversation = try await store.createConversation(title: "Preserve")
        let parent = try await store.createRun(
            conversationID: deletedConversation.id,
            entryPoint: .attended
        )
        let child = try await store.createRun(
            conversationID: deletedConversation.id,
            parentRunID: parent.id,
            entryPoint: .childRun
        )
        let preserved = try await store.createRun(
            conversationID: preservedConversation.id,
            entryPoint: .scheduled
        )
        let artifacts = runDirectory(root: root, runID: child.id)
            .appendingPathComponent("artifacts/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)

        try await store.deleteConversation(id: deletedConversation.id)

        #expect(await store.run(id: parent.id) == nil)
        #expect(await store.run(id: child.id) == nil)
        #expect(await store.run(id: preserved.id) != nil)
        #expect(!FileManager.default.fileExists(atPath: runDirectory(root: root, runID: parent.id).path))
        #expect(!FileManager.default.fileExists(atPath: runDirectory(root: root, runID: child.id).path))
        #expect(FileManager.default.fileExists(atPath: runDirectory(root: root, runID: preserved.id).path))
        #expect(try await store.listConversations().map(\.id) == [preservedConversation.id])

        let reopened = try AgentRunStore(baseDirectory: root)
        #expect(await reopened.run(id: preserved.id) != nil)
        #expect(try await reopened.listConversations().map(\.id) == [preservedConversation.id])
    }

    @Test func runLifecycleHasExplicitTerminalAndRecoverableOutcomes() throws {
        #expect(AgentRunStatus.succeeded.isTerminal)
        #expect(AgentRunStatus.failed.isTerminal)
        #expect(AgentRunStatus.cancelled.isTerminal)
        #expect(!AgentRunStatus.interrupted.isTerminal)
        #expect(AgentRunStatus.interrupted.isRecoverable)
        #expect(AgentRunStatus.waitingForHuman.isWaiting)

        try AgentRunStateMachine.validateTransition(from: .queued, to: .running)
        try AgentRunStateMachine.validateTransition(from: .queued, to: .interrupted)
        try AgentRunStateMachine.validateTransition(from: .running, to: .waitingForApproval)
        try AgentRunStateMachine.validateTransition(from: .waitingForApproval, to: .running)
        try AgentRunStateMachine.validateTransition(from: .running, to: .interrupted)
        try AgentRunStateMachine.validateTransition(from: .interrupted, to: .queued)

        #expect(throws: AgentRunStateMachine.TransitionError.self) {
            try AgentRunStateMachine.validateTransition(from: .succeeded, to: .running)
        }
        #expect(throws: AgentRunStateMachine.TransitionError.self) {
            try AgentRunStateMachine.validateTransition(from: .queued, to: .succeeded)
        }

        let encoded = try JSONEncoder().encode(AgentRunStatus.waitingForHuman)
        #expect(try JSONDecoder().decode(AgentRunStatus.self, from: encoded) == .waitingForHuman)
    }

    @Test func storePersistsOrderedLifecycleAcrossRecreation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-run-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let instant = Date(timeIntervalSince1970: 2_000_000_000)

        let store = try AgentRunStore(baseDirectory: root)
        let conversation = try await store.createConversation(title: "Research", at: instant)
        let run = try await store.createRun(
            conversationID: conversation.id,
            entryPoint: .attended,
            configuration: AgentConfigurationSnapshot(provider: AgentProviderSnapshot(
                providerID: "fixture",
                model: "scripted",
                endpointIdentity: "loopback",
                reportsUsage: true,
                supportsStreaming: true
            )),
            at: instant
        )
        let running = try await store.transitionRun(
            run.id,
            to: .running,
            reason: "User submitted prompt",
            at: instant.addingTimeInterval(1)
        )
        let prompt = try await store.appendStep(
            runID: run.id,
            kind: .userMessage,
            summary: "Inspect the page",
            payload: .object(["text": .string("Inspect the page")]),
            redactionState: .retained,
            at: instant.addingTimeInterval(2)
        )
        let succeeded = try await store.transitionRun(
            run.id,
            to: .succeeded,
            reason: "Completed",
            at: instant.addingTimeInterval(3)
        )

        #expect(running.sequence == 0)
        #expect(prompt.sequence == 1)
        #expect(succeeded.sequence == 2)

        let reopened = try AgentRunStore(baseDirectory: root)
        let loadedRun = try #require(await reopened.run(id: run.id))
        let steps = try await reopened.steps(runID: run.id)
        let conversations = try await reopened.listConversations()
        #expect(loadedRun.status == .succeeded)
        #expect(loadedRun.configuration.provider?.model == "scripted")
        #expect(steps.map(\.sequence) == [0, 1, 2])
        #expect(steps.map(\.kind) == [.stateTransition, .userMessage, .stateTransition])
        #expect(conversations.first?.runIDs == [run.id])
    }

    private func temporaryStoreDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-run-store-\(UUID().uuidString)", isDirectory: true)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    private func stepsURL(root: URL, runID: UUID) -> URL {
        runDirectory(root: root, runID: runID).appendingPathComponent("steps.jsonl")
    }

    private func runDirectory(root: URL, runID: UUID) -> URL {
        root.appendingPathComponent("agent/runs/\(runID.uuidString)", isDirectory: true)
    }
}
