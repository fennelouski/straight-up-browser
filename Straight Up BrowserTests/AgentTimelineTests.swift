import CryptoKit
import Foundation
import Testing
@testable import Browser

struct AgentTimelineTests {
    @Test func serviceLoadsUnifiedHistoryDirectlyFromRunStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-timeline-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentRunStore(baseDirectory: root)
        for entryPoint in AgentRunEntryPoint.allCases {
            let run = try await store.createRun(conversationID: nil, entryPoint: entryPoint)
            _ = try await store.appendStep(
                runID: run.id,
                kind: .system,
                summary: entryPoint.rawValue
            )
        }

        let timeline = try await AgentTimelineService(store: store).load()

        #expect(Set(timeline.runs.map(\.entryPoint)) == Set(AgentRunEntryPoint.allCases))
        #expect(timeline.items.count == AgentRunEntryPoint.allCases.count)
    }

    @Test func historyProjectsEveryAgentRunEntryPointThroughOneContract() throws {
        let base = Date(timeIntervalSince1970: 2_000_000_000)
        let runs = AgentRunEntryPoint.allCases.enumerated().map { offset, entryPoint in
            AgentRun(
                id: UUID(),
                entryPoint: entryPoint,
                status: .succeeded,
                createdAt: base.addingTimeInterval(Double(offset))
            )
        }
        let steps = Dictionary(uniqueKeysWithValues: runs.map { run in
            (run.id, [AgentStep(
                runID: run.id,
                sequence: 0,
                timestamp: run.createdAt,
                kind: .stateTransition,
                summary: "Run completed"
            )])
        })

        let timeline = AgentTimelineProjector().project(
            runs: runs,
            stepsByRun: steps,
            artifacts: []
        )

        #expect(Set(timeline.runs.map(\.entryPoint)) == Set(AgentRunEntryPoint.allCases))
        #expect(timeline.items.count == AgentRunEntryPoint.allCases.count)
        #expect(timeline.items.allSatisfy { !$0.accessibilityDescription.isEmpty })
    }

    @Test func runSequenceWinsOverWallClockSkew() {
        let run = AgentRun(entryPoint: .attended)
        let laterClock = Date(timeIntervalSince1970: 20)
        let earlierClock = Date(timeIntervalSince1970: 10)
        let first = AgentStep(
            runID: run.id,
            sequence: 0,
            timestamp: laterClock,
            kind: .system,
            summary: "First"
        )
        let second = AgentStep(
            runID: run.id,
            sequence: 1,
            timestamp: earlierClock,
            kind: .system,
            summary: "Second"
        )

        let timeline = AgentTimelineProjector().project(
            runs: [run],
            stepsByRun: [run.id: [first, second]],
            artifacts: []
        )

        #expect(timeline.items.map(\.id) == [first.id, second.id])
    }

    @Test func frameSummaryIsLazyAndLinksToOneArtifactStep() throws {
        let runID = UUID()
        let policy = AgentStep(
            runID: runID,
            sequence: 0,
            kind: .policyDecision,
            summary: "Allowed click"
        )
        let mutation = AgentStep(
            runID: runID,
            sequence: 1,
            kind: .toolInvocation,
            summary: "click",
            payload: .object(["tool": .string("click")]),
            policyDecisionStepID: policy.id
        )
        let artifactID = UUID()
        let artifactStep = AgentStep(
            runID: runID,
            sequence: 2,
            kind: .artifact,
            summary: "Frame after click",
            artifactID: artifactID,
            policyDecisionStepID: policy.id,
            redactionState: .retained
        )
        let artifact = AgentArtifact(
            id: artifactID,
            runID: runID,
            sourceStepID: artifactStep.id,
            contentType: "image/png",
            byteCount: 256,
            sha256: String(repeating: "a", count: 64),
            relativePath: "frames/2.png",
            redactionState: .retained
        )
        let frame = AgentReplayFrameMetadata(
            artifactID: artifactID,
            pageHandle: PageHandle(windowID: UUID(), tabID: UUID()),
            urlOrigin: "https://example.test",
            viewport: AgentReplayViewport(width: 1280, height: 720, scale: 2),
            capturePosition: .afterMutation
        )
        let run = AgentRun(id: runID, entryPoint: .attended)

        let timeline = AgentTimelineProjector().project(
            runs: [run],
            stepsByRun: [runID: [policy, mutation, artifactStep]],
            artifacts: [.init(
                artifact: artifact,
                storageObservation: .present,
                frame: frame
            )]
        )

        let summary = try #require(timeline.artifacts.first)
        #expect(summary.sourceStepID == artifactStep.id)
        #expect(summary.availability == .available)
        #expect(summary.frame == frame)
        #expect(summary.locator?.relativePath == "frames/2.png")
        #expect(timeline.items.first { $0.id == artifactStep.id }?.artifactID == artifactID)
        #expect(timeline.sourceStep(for: artifactID)?.id == artifactStep.id)
        #expect(timeline.policyDecision(for: mutation.id)?.id == policy.id)
        #expect(timeline.validationIssues.isEmpty)
    }

    @Test func replayCapturePolicyUsesResolvedPageAndDisablesIncognitoByDefault() throws {
        let descriptor = try #require(AgentToolCatalog.canonical.descriptor(named: "click"))
        let run = AgentRun(entryPoint: .attended)
        let page = AgentPageTarget(
            pageID: "window:tab",
            origin: "https://example.test",
            session: .normal
        )
        let context = AgentInvocationContext(
            runID: run.id,
            entryPoint: .attended,
            humanPresent: true,
            toolName: descriptor.name,
            arguments: .object(["pageId": .string(page.pageID), "selector": .string("#buy")]),
            target: .page(page),
            runScope: AgentRunScope(
                capabilities: descriptor.requiredCapabilities,
                pageIDs: [page.pageID],
                origins: [page.origin]
            )
        )
        let policy = AgentReplayCapturePolicy()

        #expect(policy.positions(for: run, descriptor: descriptor, context: context) == [
            .beforeMutation, .afterMutation,
        ])

        let incognito = AgentRun(id: run.id, entryPoint: .attended, incognito: true)
        #expect(policy.positions(
            for: incognito,
            descriptor: descriptor,
            context: context
        ).isEmpty)
    }

    @Test func completedIncognitoRunNeverRetainsCaptureByDefault() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let runID = UUID()
        let run = AgentRun(
            id: runID,
            entryPoint: .attended,
            status: .succeeded,
            createdAt: now.addingTimeInterval(-10),
            incognito: true
        )
        let artifactID = UUID()
        let step = AgentStep(
            runID: runID,
            sequence: 0,
            kind: .artifact,
            summary: "Incognito frame",
            artifactID: artifactID,
            redactionState: .retained
        )
        let artifact = AgentArtifact(
            id: artifactID,
            runID: runID,
            sourceStepID: step.id,
            contentType: "image/png",
            byteCount: 10,
            sha256: String(repeating: "b", count: 64),
            relativePath: "frames/incognito.png",
            redactionState: .retained,
            createdAt: now.addingTimeInterval(-9)
        )
        let input = AgentTimelineArtifactInput(
            artifact: artifact,
            storageObservation: .present,
            frame: AgentReplayFrameMetadata(
                artifactID: artifactID,
                pageHandle: PageHandle(windowID: UUID(), tabID: UUID()),
                urlOrigin: "https://private-incognito.test",
                viewport: AgentReplayViewport(width: 100, height: 100, scale: 1),
                capturePosition: .afterMutation
            )
        )

        let timeline = AgentTimelineProjector().project(
            runs: [run],
            stepsByRun: [runID: [step]],
            artifacts: [input]
        )
        let plan = AgentRetentionPlanner().plan(
            runs: [run],
            artifacts: [artifact],
            temporaryItems: [],
            request: AgentRetentionRequest(defaultPolicy: .manual),
            now: now
        )
        let optedInPlan = AgentRetentionPlanner().plan(
            runs: [run],
            artifacts: [artifact],
            temporaryItems: [],
            request: AgentRetentionRequest(
                defaultPolicy: .manual,
                incognitoArtifactOptInRunIDs: [runID]
            ),
            now: now
        )

        #expect(timeline.artifacts.first?.availability == .notRetained)
        #expect(timeline.artifacts.first?.locator == nil)
        #expect(timeline.artifacts.first?.frame == nil)
        #expect(plan.artifactIDs.contains(artifactID))
        #expect(plan.artifactRelativePaths.contains("frames/incognito.png"))
        #expect(optedInPlan.artifactIDs.isEmpty)
    }

    @Test func unavailableArtifactsLeaveTheRunReadable() throws {
        let run = AgentRun(entryPoint: .scheduled)
        let states: [(AgentRedactionState, AgentArtifactStorageObservation, AgentTimelineArtifactAvailability)] = [
            (.retained, .missing, .missing),
            (.expired, .present, .expired),
            (.redacted, .present, .redacted),
            (.metadataOnly, .present, .notRetained),
        ]
        var steps: [AgentStep] = []
        var inputs: [AgentTimelineArtifactInput] = []
        for (sequence, state) in states.enumerated() {
            let artifactID = UUID()
            let step = AgentStep(
                runID: run.id,
                sequence: sequence,
                kind: .artifact,
                summary: "Artifact \(sequence)",
                artifactID: artifactID,
                redactionState: state.0
            )
            steps.append(step)
            inputs.append(.init(
                artifact: AgentArtifact(
                    id: artifactID,
                    runID: run.id,
                    sourceStepID: step.id,
                    contentType: "application/octet-stream",
                    byteCount: sequence,
                    sha256: String(repeating: "c", count: 64),
                    relativePath: "artifacts/\(sequence).bin",
                    redactionState: state.0
                ),
                storageObservation: state.1
            ))
        }

        let timeline = AgentTimelineProjector().project(
            runs: [run],
            stepsByRun: [run.id: steps],
            artifacts: inputs
        )

        #expect(timeline.items.count == states.count)
        #expect(timeline.artifacts.map(\.availability) == states.map(\.2))
        #expect(timeline.artifacts.allSatisfy { $0.locator == nil })
        #expect(timeline.artifacts.allSatisfy { !$0.accessibilityDescription.isEmpty })
        #expect(timeline.validationIssues.isEmpty)
    }

    @Test func mutationMustLinkToAnEarlierPolicyDecisionInTheSameRun() {
        let run = AgentRun(entryPoint: .localMCP)
        let unrelated = AgentStep(
            runID: run.id,
            sequence: 0,
            kind: .system,
            summary: "Not a decision"
        )
        let mutation = AgentStep(
            runID: run.id,
            sequence: 1,
            kind: .toolInvocation,
            summary: "click",
            payload: .object(["tool": .string("click")]),
            policyDecisionStepID: unrelated.id
        )

        let timeline = AgentTimelineProjector().project(
            runs: [run],
            stepsByRun: [run.id: [unrelated, mutation]],
            artifacts: []
        )

        #expect(timeline.validationIssues.map(\.code) == [.invalidPolicyDecisionLink])
        #expect(timeline.validationIssues.first?.stepID == mutation.id)
        #expect(timeline.items.count == 2)
    }

    @Test func artifactAndFrameMetadataFailValidationWithoutAnExactStepBacklink() {
        let run = AgentRun(entryPoint: .attended)
        let step = AgentStep(
            runID: run.id,
            sequence: 0,
            kind: .artifact,
            summary: "Broken frame"
        )
        let artifact = AgentArtifact(
            runID: run.id,
            sourceStepID: step.id,
            contentType: "image/png",
            byteCount: 1,
            sha256: String(repeating: "1", count: 64),
            relativePath: "frames/broken.png",
            redactionState: .retained
        )
        let frame = AgentReplayFrameMetadata(
            artifactID: artifact.id,
            pageHandle: PageHandle(windowID: UUID(), tabID: UUID()),
            urlOrigin: "https://example.test/path?q=must-not-be-here",
            viewport: AgentReplayViewport(width: 0, height: 720, scale: 2),
            capturePosition: .beforeMutation
        )

        let issues = AgentTimelineProjector().project(
            runs: [run],
            stepsByRun: [run.id: [step]],
            artifacts: [.init(artifact: artifact, storageObservation: .present, frame: frame)]
        ).validationIssues

        #expect(Set(issues.map(\.code)) == [
            .artifactBacklinkMismatch,
            .invalidFrameOrigin,
            .invalidFrameViewport,
        ])
    }

    @Test func artifactBytesLoadOnlyThroughBoundedVerifiedLocator() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-timeline-reader-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = UUID()
        let directory = root
            .appendingPathComponent(runID.uuidString, isDirectory: true)
            .appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = Data("frame bytes".utf8)
        let file = directory.appendingPathComponent("1.png")
        try bytes.write(to: file)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let locator = AgentArtifactLocator(
            runID: runID,
            artifactID: UUID(),
            relativePath: "frames/1.png",
            expectedByteCount: bytes.count,
            sha256: digest
        )

        let reader = AgentArtifactReader(runsDirectory: root)
        #expect(try await reader.data(for: locator, maximumBytes: 1_024) == bytes)

        let oversized = AgentArtifactLocator(
            runID: locator.runID,
            artifactID: locator.artifactID,
            relativePath: locator.relativePath,
            expectedByteCount: locator.expectedByteCount,
            sha256: locator.sha256
        )
        await #expect(throws: AgentArtifactReadError.limitExceeded) {
            try await reader.data(for: oversized, maximumBytes: 1)
        }
    }

    @Test func artifactInventoryReadsMetadataWithoutLoadingBodies() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-timeline-inventory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = UUID()
        let artifactsDirectory = root
            .appendingPathComponent(runID.uuidString, isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactsDirectory, withIntermediateDirectories: true)
        let available = AgentArtifact(
            runID: runID,
            sourceStepID: UUID(),
            contentType: "text/plain",
            byteCount: 1_000_000,
            sha256: String(repeating: "f", count: 64),
            relativePath: "artifacts/available.txt",
            redactionState: .retained
        )
        let missing = AgentArtifact(
            runID: runID,
            sourceStepID: UUID(),
            contentType: "text/plain",
            byteCount: 1,
            sha256: String(repeating: "0", count: 64),
            relativePath: "artifacts/missing.txt",
            redactionState: .retained
        )
        try JSONEncoder().encode([available, missing]).write(
            to: artifactsDirectory.appendingPathComponent("index.json")
        )
        try Data("not one million bytes".utf8).write(
            to: artifactsDirectory.appendingPathComponent("available.txt")
        )

        let inventory = try await AgentArtifactInventoryReader(runsDirectory: root)
            .inventory(runIDs: [runID])

        #expect(inventory.map(\.artifact.id) == [available.id, missing.id])
        #expect(inventory.map(\.storageObservation) == [.present, .missing])
    }

    @Test func artifactInventoryRejectsOversizedManifestBeforeDecode() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-timeline-manifest-limit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = UUID()
        let directory = root
            .appendingPathComponent(runID.uuidString, isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("oversized".utf8).write(to: directory.appendingPathComponent("index.json"))

        let reader = AgentArtifactInventoryReader(runsDirectory: root, maximumManifestBytes: 4)
        await #expect(throws: AgentArtifactInventoryError.self) {
            try await reader.inventory(runIDs: [runID])
        }
    }

    @Test func retentionPlansExpiredEvidenceAndOrphanTemporaryCleanup() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let expired = AgentRun(
            entryPoint: .commandLine,
            status: .succeeded,
            createdAt: now.addingTimeInterval(-(25 * 60 * 60))
        )
        let active = AgentRun(
            entryPoint: .attended,
            status: .running,
            createdAt: now.addingTimeInterval(-(48 * 60 * 60))
        )
        let artifact = AgentArtifact(
            runID: expired.id,
            sourceStepID: UUID(),
            contentType: "image/png",
            byteCount: 1,
            sha256: String(repeating: "d", count: 64),
            relativePath: "frames/expired.png",
            redactionState: .retained
        )
        let old = now.addingTimeInterval(-(2 * 60 * 60))
        let plan = AgentRetentionPlanner().plan(
            runs: [expired, active],
            artifacts: [artifact],
            temporaryItems: [
                .init(relativePath: "tmp/orphan", createdAt: old),
                .init(relativePath: "tmp/active", createdAt: old, owningRunID: active.id),
                .init(relativePath: "../escape", createdAt: old),
            ],
            request: AgentRetentionRequest(defaultPolicy: .hours24),
            now: now
        )

        #expect(plan.runIDs == [expired.id])
        #expect(plan.artifactIDs == [artifact.id])
        #expect(plan.orphanTemporaryRelativePaths == ["tmp/orphan"])
        #expect(plan.rejectedUnsafeRelativePaths == ["../escape"])
        #expect(plan.requiresRunIndexUpdate)
    }

    @Test func defaultDiagnosticExportOmitsQueriesBodiesScreenshotsAndSecrets() throws {
        let provider = AgentProviderSnapshot(
            providerID: "fixture",
            model: "test-model",
            endpointIdentity: "https://api.example.test/v1/responses?access_token=endpoint-secret#fragment"
        )
        let run = AgentRun(
            entryPoint: .scheduled,
            configuration: AgentConfigurationSnapshot(
                provider: provider,
                settings: ["apiKey": .string("top-secret")]
            )
        )
        let steps = [
            AgentStep(
                runID: run.id,
                sequence: 0,
                kind: .userMessage,
                summary: "private page body top-secret",
                payload: .object(["content": .string("private page body")]),
                redactionState: .retained
            ),
            AgentStep(
                runID: run.id,
                sequence: 1,
                kind: .error,
                summary: "GET https://example.test/private?q=query-secret token=top-secret"
            ),
        ]
        let artifact = AgentArtifact(
            runID: run.id,
            sourceStepID: steps[0].id,
            contentType: "image/png",
            byteCount: 9_999,
            sha256: String(repeating: "e", count: 64),
            relativePath: "screenshots/private-page.png",
            redactionState: .retained
        )

        let data = try AgentDiagnosticExporter().export(
            runs: [run],
            stepsByRun: [run.id: steps],
            artifacts: [artifact],
            options: AgentDiagnosticExportOptions(configuredSecrets: [
                "top-secret", "endpoint-secret", "query-secret",
            ]),
            generatedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let text = String(decoding: data, as: UTF8.self)

        #expect(text.contains("https://api.example.test"))
        #expect(text.contains("https://example.test"))
        #expect(text.contains("Content omitted"))
        #expect(!text.contains("?"))
        #expect(!text.contains("#fragment"))
        #expect(!text.contains("private page body"))
        #expect(!text.contains("private-page.png"))
        #expect(!text.contains("top-secret"))
        #expect(!text.contains("endpoint-secret"))
        #expect(!text.contains("query-secret"))
        #expect(!text.contains("apiKey"))
    }

    @Test func keyboardAutoplayAndFiltersShareAccessiblePlaybackState() throws {
        let run = AgentRun(entryPoint: .childRun)
        let steps = [
            AgentStep(runID: run.id, sequence: 0, kind: .modelText, summary: "Plan"),
            AgentStep(runID: run.id, sequence: 1, kind: .toolResult, summary: "Observed"),
            AgentStep(runID: run.id, sequence: 2, kind: .error, summary: "Stopped"),
        ]
        let items = AgentTimelineProjector().project(
            runs: [run],
            stepsByRun: [run.id: steps],
            artifacts: []
        ).items
        var playback = AgentTimelinePlaybackState(items: items)

        #expect(playback.selectedItemID == items[0].id)
        playback.handle(.next, items: items)
        #expect(playback.selectedItemID == items[1].id)
        playback.setFilter([.tool, .error], items: items)
        #expect(playback.visibleItems(in: items).map(\.id) == [items[1].id, items[2].id])

        playback.handle(.toggleAutoplay, items: items)
        #expect(playback.isAutoplayEnabled)
        playback.autoplayTick(items: items)
        #expect(playback.selectedItemID == items[2].id)
        playback.autoplayTick(items: items)
        #expect(!playback.isAutoplayEnabled)

        playback.handle(.previous, items: items)
        #expect(playback.selectedItemID == items[1].id)
        #expect(playback.accessibilityValue(items: items).contains("1 of 2"))
        #expect(playback.accessibilityValue(items: items).contains("tool result"))
    }
}
