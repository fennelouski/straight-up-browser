import CryptoKit
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

    @Test func retainedArtifactIsDurableInventoriedAndReadableByExactBacklink() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("Cowork output\n".utf8)
        let artifactID = UUID()

        let store = try AgentRunStore(baseDirectory: root)
        let run = try await store.createRun(
            conversationID: nil,
            entryPoint: .attended
        )
        let source = try await store.appendStep(
            runID: run.id,
            kind: .artifact,
            summary: "Committed Cowork output",
            artifactID: artifactID,
            redactionState: .retained
        )

        let artifact = try await store.persistArtifact(
            id: artifactID,
            runID: run.id,
            sourceStepID: source.id,
            contentType: "text/plain",
            data: bytes
        )

        let retrySource = try await store.appendStep(
            runID: run.id,
            kind: .artifact,
            summary: "Idempotent committed Cowork output",
            artifactID: artifactID,
            redactionState: .metadataOnly
        )
        let retried = try await store.persistArtifact(
            id: artifactID,
            runID: run.id,
            sourceStepID: retrySource.id,
            contentType: "text/plain",
            data: bytes,
            at: Date().addingTimeInterval(60)
        )

        #expect(artifact.id == artifactID)
        #expect(retried == artifact)
        #expect(retried.sourceStepID == source.id)
        #expect(artifact.sourceStepID == source.id)
        #expect(artifact.relativePath == "artifacts/\(artifactID.uuidString).data")
        #expect(artifact.byteCount == bytes.count)
        #expect(try permissions(of: runDirectory(root: root, runID: run.id)
            .appendingPathComponent(artifact.relativePath)) == 0o600)

        let inputs = try await AgentArtifactInventoryReader(
            runsDirectory: root.appendingPathComponent("agent/runs", isDirectory: true)
        ).inventory(runIDs: [run.id])
        let input = try #require(inputs.first)
        #expect(input.artifact == artifact)
        #expect(input.storageObservation == .present)
        let timeline = try await AgentTimelineService(store: store).load(artifacts: inputs)
        let summary = try #require(timeline.artifacts.first)
        let locator = try #require(summary.locator)
        #expect(try await AgentArtifactReader(
            runsDirectory: root.appendingPathComponent("agent/runs", isDirectory: true)
        ).data(for: locator, maximumBytes: 1_024) == bytes)

        let reopened = try AgentRunStore(baseDirectory: root)
        #expect(await reopened.run(id: run.id) != nil)
        #expect(try await reopened.steps(runID: run.id).contains { $0.id == source.id })
    }

    @Test func artifactPersistenceFailsClosedForIncognitoOrWrongSourceStep() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentRunStore(baseDirectory: root)
        let artifactID = UUID()
        let run = try await store.createRun(
            conversationID: nil,
            entryPoint: .attended
        )
        let unrelated = try await store.appendStep(
            runID: run.id,
            kind: .system,
            summary: "Not an artifact"
        )

        await #expect(throws: AgentRunStoreError.self) {
            _ = try await store.persistArtifact(
                id: artifactID,
                runID: run.id,
                sourceStepID: unrelated.id,
                contentType: "text/plain",
                data: Data("blocked".utf8)
            )
        }

        let incognito = try await store.createRun(
            conversationID: nil,
            entryPoint: .attended,
            incognito: true
        )
        let incognitoArtifactID = UUID()
        let incognitoStep = try await store.appendStep(
            runID: incognito.id,
            kind: .artifact,
            summary: "Incognito metadata only",
            artifactID: incognitoArtifactID,
            redactionState: .metadataOnly
        )
        await #expect(throws: AgentRunStoreError.self) {
            _ = try await store.persistArtifact(
                id: incognitoArtifactID,
                runID: incognito.id,
                sourceStepID: incognitoStep.id,
                contentType: "text/plain",
                data: Data("must not persist".utf8)
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: runDirectory(root: root, runID: incognito.id)
                .appendingPathComponent("artifacts/index.json").path
        ))
    }

    @Test func replayFrameTransactionRollsBackInjectedFailureAndRetryIsValid() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let frameID = UUID()
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let metadata = AgentReplayFrameMetadata(
            artifactID: frameID,
            pageHandle: page,
            urlOrigin: "https://example.test",
            viewport: AgentReplayViewport(width: 800, height: 600, scale: 2),
            capturePosition: .beforeMutation
        )
        let store = try AgentRunStore(
            baseDirectory: root,
            failureInjector: { point in
                if case .beforeReplayFrameManifestWrite = point {
                    throw ReplayPersistenceTestError.injected
                }
            }
        )
        let run = try await store.createRun(
            conversationID: nil,
            entryPoint: .attended
        )
        let policy = try await store.appendStep(
            runID: run.id,
            kind: .policyDecision,
            summary: "Allowed click"
        )
        let invocation = try await store.appendStep(
            runID: run.id,
            kind: .toolInvocation,
            summary: "click",
            payload: .object(["tool": .string("click")]),
            policyDecisionStepID: policy.id
        )

        await #expect(throws: ReplayPersistenceTestError.self) {
            _ = try await store.persistReplayFrame(
                id: frameID,
                runID: run.id,
                sourceStepID: invocation.id,
                contentType: "image/png",
                data: bytes,
                metadata: metadata
            )
        }
        let runDirectory = runDirectory(root: root, runID: run.id)
        let rolledBackArtifacts = try JSONDecoder().decode(
            [AgentArtifact].self,
            from: Data(contentsOf: runDirectory.appendingPathComponent("artifacts/index.json"))
        )
        let rolledBackFrames = try JSONDecoder().decode(
            [AgentReplayFrameMetadata].self,
            from: Data(contentsOf: runDirectory.appendingPathComponent("frames/index.json"))
        )
        #expect(rolledBackArtifacts.isEmpty)
        #expect(rolledBackFrames.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: runDirectory.appendingPathComponent(
                "artifacts/\(frameID.uuidString).data"
            ).path
        ))

        let retryingStore = try AgentRunStore(baseDirectory: root)
        let artifact = try await retryingStore.persistReplayFrame(
            id: frameID,
            runID: run.id,
            sourceStepID: invocation.id,
            contentType: "image/png",
            data: bytes,
            metadata: metadata
        )
        let retried = try await retryingStore.persistReplayFrame(
            id: frameID,
            runID: run.id,
            sourceStepID: invocation.id,
            contentType: "image/png",
            data: bytes,
            metadata: metadata,
            at: Date().addingTimeInterval(60)
        )
        #expect(retried == artifact)
        #expect(artifact.sourceStepID == invocation.id)

        let inventory = try await AgentArtifactInventoryReader(
            runsDirectory: root.appendingPathComponent("agent/runs", isDirectory: true)
        ).inventory(runIDs: [run.id])
        #expect(inventory.count == 1)
        #expect(inventory.first?.frame == metadata)
        let projection = try await AgentTimelineService(store: retryingStore).load(
            artifacts: inventory
        )
        #expect(projection.validationIssues.isEmpty)
        let locator = try #require(projection.artifacts.first?.locator)
        #expect(try await AgentArtifactReader(
            runsDirectory: root.appendingPathComponent("agent/runs", isDirectory: true)
        ).data(for: locator, maximumBytes: 1_024) == bytes)
    }

    @Test func replayJournalCompletesArtifactFirstCrashOnStoreReopen() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("encoded-frame".utf8)
        let frameID = UUID()
        let store = try AgentRunStore(baseDirectory: root)
        let run = try await store.createRun(conversationID: nil, entryPoint: .localMCP)
        let policy = try await store.appendStep(
            runID: run.id,
            kind: .policyDecision,
            summary: "Allowed fill"
        )
        let invocation = try await store.appendStep(
            runID: run.id,
            kind: .toolInvocation,
            summary: "fill",
            payload: .object(["tool": .string("fill")]),
            policyDecisionStepID: policy.id
        )
        let artifact = AgentArtifact(
            id: frameID,
            runID: run.id,
            sourceStepID: invocation.id,
            contentType: "image/png",
            byteCount: bytes.count,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            relativePath: "artifacts/\(frameID.uuidString).data",
            redactionState: .retained,
            createdAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let frame = AgentReplayFrameMetadata(
            artifactID: frameID,
            pageHandle: PageHandle(windowID: UUID(), tabID: UUID()),
            urlOrigin: "https://example.test",
            viewport: .init(width: 640, height: 480, scale: 1),
            capturePosition: .afterMutation
        )
        let runDirectory = runDirectory(root: root, runID: run.id)
        let artifactsDirectory = runDirectory.appendingPathComponent("artifacts")
        let pendingDirectory = runDirectory.appendingPathComponent("frames/pending")
        try FileManager.default.createDirectory(
            at: artifactsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: pendingDirectory,
            withIntermediateDirectories: true
        )
        try bytes.write(to: runDirectory.appendingPathComponent(artifact.relativePath))
        try JSONEncoder().encode([artifact]).write(
            to: artifactsDirectory.appendingPathComponent("index.json")
        )
        let journal = ReplayPersistenceTestJournal(
            schemaVersion: 1,
            artifact: artifact,
            frame: frame
        )
        let journalURL = pendingDirectory.appendingPathComponent(
            "\(frameID.uuidString).json"
        )
        try JSONEncoder().encode(journal).write(to: journalURL)

        _ = try AgentRunStore(baseDirectory: root)

        let frames = try JSONDecoder().decode(
            [AgentReplayFrameMetadata].self,
            from: Data(contentsOf: runDirectory.appendingPathComponent("frames/index.json"))
        )
        #expect(frames == [frame])
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test func replayFrameCountAcceptsExactMaximumThenRejectsNext() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentRunStore(baseDirectory: root)
        let run = try await store.createRun(conversationID: nil, entryPoint: .attended)
        let policy = try await store.appendStep(
            runID: run.id,
            kind: .policyDecision,
            summary: "Allowed mutation"
        )
        let invocation = try await store.appendStep(
            runID: run.id,
            kind: .toolInvocation,
            summary: "click",
            payload: .object(["tool": .string("click")]),
            policyDecisionStepID: policy.id
        )
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        for index in 0..<256 {
            let id = UUID()
            _ = try await store.persistReplayFrame(
                id: id,
                runID: run.id,
                sourceStepID: invocation.id,
                contentType: "image/png",
                data: Data([UInt8(index % 255)]),
                metadata: AgentReplayFrameMetadata(
                    artifactID: id,
                    pageHandle: page,
                    urlOrigin: "https://example.test",
                    viewport: .init(width: 1, height: 1, scale: 1),
                    capturePosition: .afterMutation
                )
            )
        }
        let rejectedID = UUID()
        await #expect(throws: AgentRunStoreError.artifactManifestFull(
            maximumEntries: 256
        )) {
            _ = try await store.persistReplayFrame(
                id: rejectedID,
                runID: run.id,
                sourceStepID: invocation.id,
                contentType: "image/png",
                data: Data([0]),
                metadata: AgentReplayFrameMetadata(
                    artifactID: rejectedID,
                    pageHandle: page,
                    urlOrigin: "https://example.test",
                    viewport: .init(width: 1, height: 1, scale: 1),
                    capturePosition: .afterMutation
                )
            )
        }
    }

    @Test func replayByteAccountingOverflowFailsClosedWithoutWriting() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentRunStore(baseDirectory: root)
        let run = try await store.createRun(
            conversationID: nil,
            entryPoint: .attended
        )
        let decision = try await store.appendStep(
            runID: run.id,
            kind: .policyDecision,
            summary: "Allowed click"
        )
        let invocation = try await store.appendStep(
            runID: run.id,
            kind: .toolInvocation,
            summary: "click",
            payload: .object(["tool": .string("click")]),
            policyDecisionStepID: decision.id
        )
        let retainedIDs = [UUID(), UUID()]
        let artifacts = retainedIDs.map { id in
            AgentArtifact(
                id: id,
                runID: run.id,
                sourceStepID: invocation.id,
                contentType: "image/png",
                byteCount: Int.max,
                sha256: String(repeating: "a", count: 64),
                relativePath: "artifacts/\(id.uuidString).data",
                redactionState: .retained,
                createdAt: Date()
            )
        }
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let frames = retainedIDs.map { id in
            AgentReplayFrameMetadata(
                artifactID: id,
                pageHandle: page,
                urlOrigin: "https://example.test",
                viewport: .init(width: 1, height: 1, scale: 1),
                capturePosition: .afterMutation
            )
        }
        let runDirectory = runDirectory(root: root, runID: run.id)
        let artifactsDirectory = runDirectory.appendingPathComponent(
            "artifacts",
            isDirectory: true
        )
        let framesDirectory = runDirectory.appendingPathComponent(
            "frames",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: artifactsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: framesDirectory,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(artifacts).write(
            to: artifactsDirectory.appendingPathComponent("index.json"),
            options: .atomic
        )
        try JSONEncoder().encode(frames).write(
            to: framesDirectory.appendingPathComponent("index.json"),
            options: .atomic
        )
        let rejectedID = UUID()

        await #expect(throws: AgentRunStoreError.corruptStore(
            path: "artifacts/index.json",
            reason: "replay frame byte accounting overflowed"
        )) {
            _ = try await store.persistReplayFrame(
                id: rejectedID,
                runID: run.id,
                sourceStepID: invocation.id,
                contentType: "image/png",
                data: Data([0]),
                metadata: AgentReplayFrameMetadata(
                    artifactID: rejectedID,
                    pageHandle: page,
                    urlOrigin: "https://example.test",
                    viewport: .init(width: 1, height: 1, scale: 1),
                    capturePosition: .afterMutation
                )
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: artifactsDirectory.appendingPathComponent(
                "\(rejectedID.uuidString).data"
            ).path
        ))
    }

    @MainActor
    @Test func replayRejectsReloadedApprovalDocumentWithoutEffectOrArtifacts() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "AgentReplayAuthorityTests.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: defaultsName)?
                .removePersistentDomain(forName: defaultsName)
        }
        let store = try AgentRunStore(baseDirectory: root)
        let run = try await store.createRun(
            conversationID: nil,
            entryPoint: .attended
        )
        let descriptor = try #require(
            AgentToolCatalog.canonical.descriptor(named: "click")
        )
        let decision = try await store.appendStep(
            runID: run.id,
            kind: .policyDecision,
            summary: "Allowed click"
        )
        let invocation = try await store.appendStep(
            runID: run.id,
            kind: .toolInvocation,
            summary: descriptor.name,
            payload: .object(["tool": .string(descriptor.name)]),
            policyDecisionStepID: decision.id
        )
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let approved = BrowserAutomationPageDispatchBinding(
            target: AgentPageTarget(
                pageID: page.description,
                origin: "https://approval.test",
                session: .normal
            ),
            version: AgentPageLeaseVersion(
                navigation: PageNavigationGeneration(rawValue: 0),
                document: PageDocumentGeneration(rawValue: UUID())
            )
        )
        // Same Page and URL, but a replacement isolated-world document after
        // approval. Neither pixels nor the effect may cross this boundary.
        let reloaded = BrowserAutomationPageDispatchBinding(
            target: approved.target,
            version: AgentPageLeaseVersion(
                navigation: approved.version.navigation,
                document: PageDocumentGeneration(rawValue: UUID())
            )
        )
        let observability = AgentObservabilityRuntime(
            baseDirectory: root,
            defaultsSuiteName: defaultsName
        )
        let meter = AgentRunMeter(
            runID: run.id,
            taskDefinitionID: nil,
            incognito: false,
            limits: try AgentExecutionLimits(
                maximumArtifacts: 4,
                maximumArtifactBytes: 1_024
            ),
            observability: observability
        )
        let permit = AgentExecutionPermit(
            runID: run.id,
            toolName: descriptor.name,
            invocationDigest: "fixture",
            decisionStepID: decision.id,
            invocationStepID: invocation.id
        )
        var effectRan = false
        var captureCount = 0

        let succeeded = await AgentReplayCaptureCoordinator.around(
            descriptor: descriptor,
            authorizedBinding: approved,
            permit: permit,
            capture: { expected in
                captureCount += 1
                guard expected == reloaded else { return nil }
                return AgentReplayCapturedFrame(
                    data: Data("replacement pixels".utf8),
                    target: reloaded.target,
                    viewport: .init(width: 10, height: 10, scale: 1)
                )
            },
            operationSucceeded: { $0 },
            resolvePostOperationBinding: { reloaded },
            store: store,
            meter: meter,
            operation: {
                guard approved == reloaded else { return false }
                effectRan = true
                return true
            }
        )

        #expect(!succeeded)
        #expect(!effectRan)
        #expect(captureCount == 1)
        let inventory = try await AgentArtifactInventoryReader(
            runsDirectory: root.appendingPathComponent(
                "agent/runs",
                isDirectory: true
            )
        ).inventory(runIDs: [run.id])
        #expect(inventory.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: runDirectory(root: root, runID: run.id)
                .appendingPathComponent("frames/index.json").path
        ))
    }

    @MainActor
    @Test func replayCapturesFreshPostNavigationDocumentAfterSuccessfulDispatch() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "AgentReplayNavigationTests.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: defaultsName)?
                .removePersistentDomain(forName: defaultsName)
        }
        let store = try AgentRunStore(baseDirectory: root)
        let run = try await store.createRun(
            conversationID: nil,
            entryPoint: .localMCP
        )
        let descriptor = try #require(
            AgentToolCatalog.canonical.descriptor(named: "navigate_page")
        )
        let decision = try await store.appendStep(
            runID: run.id,
            kind: .policyDecision,
            summary: "Allowed navigation"
        )
        let invocation = try await store.appendStep(
            runID: run.id,
            kind: .toolInvocation,
            summary: descriptor.name,
            payload: .object(["tool": .string(descriptor.name)]),
            policyDecisionStepID: decision.id
        )
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let approved = BrowserAutomationPageDispatchBinding(
            target: AgentPageTarget(
                pageID: page.description,
                origin: "https://before.test",
                session: .normal
            ),
            version: AgentPageLeaseVersion(
                navigation: PageNavigationGeneration(rawValue: 0),
                document: PageDocumentGeneration(rawValue: UUID())
            )
        )
        let navigated = BrowserAutomationPageDispatchBinding(
            target: AgentPageTarget(
                pageID: page.description,
                origin: "https://after.test",
                session: .normal
            ),
            version: AgentPageLeaseVersion(
                navigation: approved.version.navigation.advanced(),
                document: PageDocumentGeneration(rawValue: UUID())
            )
        )
        let observability = AgentObservabilityRuntime(
            baseDirectory: root,
            defaultsSuiteName: defaultsName
        )
        let meter = AgentRunMeter(
            runID: run.id,
            taskDefinitionID: nil,
            incognito: false,
            limits: try AgentExecutionLimits(
                maximumArtifacts: 4,
                maximumArtifactBytes: 1_024
            ),
            observability: observability
        )
        let permit = AgentExecutionPermit(
            runID: run.id,
            toolName: descriptor.name,
            invocationDigest: "fixture",
            decisionStepID: decision.id,
            invocationStepID: invocation.id
        )
        var live = approved
        var captureBindings: [BrowserAutomationPageDispatchBinding] = []

        let succeeded = await AgentReplayCaptureCoordinator.around(
            descriptor: descriptor,
            authorizedBinding: approved,
            permit: permit,
            capture: { expected in
                captureBindings.append(expected)
                guard expected == live else { return nil }
                return AgentReplayCapturedFrame(
                    data: Data("fresh pixels".utf8),
                    target: live.target,
                    viewport: .init(width: 10, height: 10, scale: 1)
                )
            },
            operationSucceeded: { $0 },
            resolvePostOperationBinding: { live },
            store: store,
            meter: meter,
            operation: {
                live = navigated
                return true
            }
        )

        #expect(succeeded)
        #expect(captureBindings == [navigated])
        let inventory = try await AgentArtifactInventoryReader(
            runsDirectory: root.appendingPathComponent(
                "agent/runs",
                isDirectory: true
            )
        ).inventory(runIDs: [run.id])
        let retained = try #require(inventory.first)
        #expect(inventory.count == 1)
        #expect(retained.artifact.sourceStepID == invocation.id)
        #expect(retained.frame?.urlOrigin == "https://after.test")
        #expect(retained.frame?.capturePosition == .afterMutation)
    }

    @MainActor
    @Test func productionRetentionDeletesWholeExpiredRunAndStaleResponses() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "AgentHistoryRetentionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(AgentRetentionPolicy.hours24.rawValue, forKey: AgentHistoryRetentionSettings.Key.policy)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = try AgentRunStore(baseDirectory: root)
        let expiredConversation = try await store.createConversation(
            title: "Expired prompt title",
            at: now.addingTimeInterval(-90_001)
        )
        let expired = try await store.createRun(
            conversationID: expiredConversation.id,
            entryPoint: .attended,
            at: now.addingTimeInterval(-90_000)
        )
        _ = try await store.transitionRun(
            expired.id,
            to: .running,
            reason: "Started",
            at: now.addingTimeInterval(-89_999)
        )
        let policy = try await store.appendStep(
            runID: expired.id,
            kind: .policyDecision,
            summary: "Allowed click",
            at: now.addingTimeInterval(-89_998.8)
        )
        let invocation = try await store.appendStep(
            runID: expired.id,
            kind: .toolInvocation,
            summary: "click",
            payload: .object(["tool": .string("click")]),
            policyDecisionStepID: policy.id,
            at: now.addingTimeInterval(-89_998.6)
        )
        let frameID = UUID()
        _ = try await store.persistReplayFrame(
            id: frameID,
            runID: expired.id,
            sourceStepID: invocation.id,
            contentType: "image/png",
            data: Data("frame".utf8),
            metadata: AgentReplayFrameMetadata(
                artifactID: frameID,
                pageHandle: PageHandle(windowID: UUID(), tabID: UUID()),
                urlOrigin: "https://example.test",
                viewport: .init(width: 100, height: 100, scale: 1),
                capturePosition: .afterMutation
            ),
            at: now.addingTimeInterval(-89_998.4)
        )
        _ = try await store.transitionRun(
            expired.id,
            to: .succeeded,
            reason: "Done",
            at: now.addingTimeInterval(-89_998)
        )
        let active = try await store.createRun(
            conversationID: nil,
            entryPoint: .localMCP,
            at: now.addingTimeInterval(-200_000)
        )
        _ = try await store.transitionRun(
            active.id,
            to: .running,
            reason: "Still active",
            at: now.addingTimeInterval(-199_999)
        )
        let expiredDirectory = runDirectory(root: root, runID: expired.id)
        let orphan = expiredDirectory.appendingPathComponent("frames/pending/.orphan-temp")
        try FileManager.default.createDirectory(
            at: orphan.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("temporary".utf8).write(to: orphan)
        let responseDirectory = root.appendingPathComponent("responses", isDirectory: true)
        try FileManager.default.createDirectory(at: responseDirectory, withIntermediateDirectories: true)
        let response = responseDirectory.appendingPathComponent("stale.json")
        try Data("{}".utf8).write(to: response)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7_200)],
            ofItemAtPath: response.path
        )

        let report = try await AgentHistoryRetentionController.enforce(
            store: store,
            baseDirectory: root,
            defaults: defaults,
            now: now
        )

        #expect(report.deletedRunIDs == [expired.id])
        #expect(report.deletedConversationIDs == [expiredConversation.id])
        #expect(report.deletedTemporaryRelativePaths == ["responses/stale.json"])
        #expect(await store.run(id: expired.id) == nil)
        #expect(await store.run(id: active.id) != nil)
        #expect(try await store.listConversations().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: expiredDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: response.path))
        let conversationIndex = root.appendingPathComponent(
            "agent/conversations/index.json"
        )
        #expect(
            try !String(contentsOf: conversationIndex, encoding: .utf8)
                .contains("Expired prompt title")
        )
        let reopened = try AgentRunStore(baseDirectory: root)
        #expect(await reopened.run(id: active.id) != nil)
        #expect(await reopened.run(id: expired.id) == nil)
        #expect(try await reopened.listConversations().isEmpty)
    }

    @MainActor
    @Test func manualRetentionPreservesOldRunAndConversationTitle() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "AgentHistoryRetentionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(
            AgentRetentionPolicy.manual.rawValue,
            forKey: AgentHistoryRetentionSettings.Key.policy
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = try AgentRunStore(baseDirectory: root)
        let conversation = try await store.createConversation(
            title: "Retain this title",
            at: now.addingTimeInterval(-200_001)
        )
        let run = try await store.createRun(
            conversationID: conversation.id,
            entryPoint: .attended,
            at: now.addingTimeInterval(-200_000)
        )
        _ = try await store.transitionRun(
            run.id,
            to: .running,
            reason: "Started",
            at: now.addingTimeInterval(-199_999)
        )
        _ = try await store.transitionRun(
            run.id,
            to: .succeeded,
            reason: "Done",
            at: now.addingTimeInterval(-199_998)
        )

        let report = try await AgentHistoryRetentionController.enforce(
            store: store,
            baseDirectory: root,
            defaults: defaults,
            now: now
        )

        #expect(report.deletedRunIDs.isEmpty)
        #expect(report.deletedConversationIDs.isEmpty)
        #expect(await store.run(id: run.id) != nil)
        let retained = try #require(try await store.listConversations().first)
        #expect(retained.id == conversation.id)
        #expect(retained.title == "Retain this title")
        #expect(retained.runIDs == [run.id])
    }

    @MainActor
    @Test func retentionPreservesConversationWhenAnotherRunRemains() async throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "AgentHistoryRetentionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(
            AgentRetentionPolicy.hours24.rawValue,
            forKey: AgentHistoryRetentionSettings.Key.policy
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = try AgentRunStore(baseDirectory: root)
        let conversation = try await store.createConversation(
            title: "Two related runs",
            at: now.addingTimeInterval(-100_001)
        )
        let expired = try await store.createRun(
            conversationID: conversation.id,
            entryPoint: .attended,
            at: now.addingTimeInterval(-100_000)
        )
        _ = try await store.transitionRun(
            expired.id,
            to: .running,
            reason: "Started",
            at: now.addingTimeInterval(-99_999)
        )
        _ = try await store.transitionRun(
            expired.id,
            to: .succeeded,
            reason: "Done",
            at: now.addingTimeInterval(-99_998)
        )
        let retained = try await store.createRun(
            conversationID: conversation.id,
            entryPoint: .attended,
            at: now.addingTimeInterval(-3_600)
        )
        _ = try await store.transitionRun(
            retained.id,
            to: .running,
            reason: "Started",
            at: now.addingTimeInterval(-3_599)
        )
        _ = try await store.transitionRun(
            retained.id,
            to: .succeeded,
            reason: "Done",
            at: now.addingTimeInterval(-3_598)
        )

        let report = try await AgentHistoryRetentionController.enforce(
            store: store,
            baseDirectory: root,
            defaults: defaults,
            now: now
        )

        #expect(report.deletedRunIDs == [expired.id])
        #expect(report.deletedConversationIDs.isEmpty)
        #expect(await store.run(id: expired.id) == nil)
        #expect(await store.run(id: retained.id) != nil)
        let persistedConversation = try #require(
            try await store.listConversations().first
        )
        #expect(persistedConversation.id == conversation.id)
        #expect(persistedConversation.title == "Two related runs")
        #expect(persistedConversation.runIDs == [retained.id])
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

private enum ReplayPersistenceTestError: Error {
    case injected
}

private struct ReplayPersistenceTestJournal: Codable {
    let schemaVersion: Int
    let artifact: AgentArtifact
    let frame: AgentReplayFrameMetadata
}
