import Foundation
import Testing
@testable import Browser

struct CoworkArtifactTransactionTests {
    @Test func createIsStagedUntilAnAtomicCommit() async throws {
        try await withTemporaryCoworkRoot { root in
            let runID = UUID()
            let identity = try CoworkRootIdentity.capture(root)
            let workspace = try CoworkArtifactTransactionWorkspace(
                rootURL: root,
                expectedRootIdentity: identity,
                runID: runID
            )
            let sourceStepID = UUID()
            let preview = try await workspace.stage(
                .create(
                    relativePath: "notes/answer.txt",
                    content: Data("new answer\n".utf8),
                    contentType: "text/plain"
                ),
                sourceStepIDs: [sourceStepID],
                invocation: .init(toolName: "write_file", invocationDigest: "create-digest")
            )

            #expect(preview.commitState == .staged)
            #expect(preview.finalRelativePath == "notes/answer.txt")
            #expect(!FileManager.default.fileExists(
                atPath: root.appendingPathComponent("notes/answer.txt").path
            ))

            let result = try await workspace.commit(transactionID: preview.transactionID)

            #expect(result.commitState == .committed)
            #expect(result.runID == runID)
            #expect(result.sourceStepIDs == [sourceStepID])
            #expect(result.finalRelativePath == "notes/answer.txt")
            #expect(result.byteCount == 11)
            #expect(result.sha256.count == 64)
            #expect(try Data(contentsOf: root.appendingPathComponent("notes/answer.txt")) == Data("new answer\n".utf8))
        }
    }

    @Test func committedArtifactSnapshotIsVerifiedAndRunWorkspaceCanBeDeleted() async throws {
        try await withTemporaryCoworkRoot { root in
            let runID = UUID()
            let identity = try CoworkRootIdentity.capture(root)
            let workspace = try CoworkArtifactTransactionWorkspace(
                rootURL: root,
                expectedRootIdentity: identity,
                runID: runID
            )
            let preview = try await workspace.stage(
                .create(
                    relativePath: "reports/result.txt",
                    content: Data("verified result\n".utf8),
                    contentType: "text/plain"
                ),
                sourceStepIDs: [UUID()],
                invocation: .init(
                    toolName: "write_file",
                    invocationDigest: "durable-snapshot"
                )
            )
            let result = try await workspace.commit(
                transactionID: preview.transactionID
            )

            let snapshot = try await workspace.durableArtifactSnapshot(
                transactionID: preview.transactionID
            )
            #expect(snapshot.result == result)
            #expect(snapshot.data == Data("verified result\n".utf8))
            #expect(FileManager.default.fileExists(atPath: workspace.workspaceURL.path))

            #expect(try CoworkArtifactWorkspaceRetention.remove(
                runID: runID,
                rootURL: root,
                expectedRootIdentity: identity
            ))
            #expect(!FileManager.default.fileExists(atPath: workspace.workspaceURL.path))
            #expect(try read("reports/result.txt", beneath: root) == "verified result\n")
            let removedAgain = try CoworkArtifactWorkspaceRetention.remove(
                runID: runID,
                rootURL: root,
                expectedRootIdentity: identity
            )
            #expect(!removedAgain)
        }
    }

    @Test func disconnectCleanupRemovesLiveAndRecoveredPrivateBytesButPreservesDestinations() async throws {
        try await withTemporaryCoworkRoot { root in
            let identity = try CoworkRootIdentity.capture(root)
            let committedRunID = UUID()
            try write("prior destination\n", to: "reports/result.txt", beneath: root)
            let committedWorkspace = try CoworkArtifactTransactionWorkspace(
                rootURL: root,
                expectedRootIdentity: identity,
                runID: committedRunID
            )
            let committedPreview = try await committedWorkspace.stage(
                .replace(
                    relativePath: "reports/result.txt",
                    content: Data("committed destination\n".utf8),
                    contentType: "text/plain"
                ),
                sourceStepIDs: [UUID()],
                invocation: .init(
                    toolName: "write_file",
                    invocationDigest: "disconnect-committed"
                )
            )
            _ = try await committedWorkspace.commit(
                transactionID: committedPreview.transactionID,
                authorization: CoworkArtifactCommitAuthorization(
                    preview: committedPreview
                )
            )

            let recoveredRunID = UUID()
            let recoveredWorkspace = try CoworkArtifactTransactionWorkspace(
                rootURL: root,
                expectedRootIdentity: identity,
                runID: recoveredRunID
            )
            _ = try await recoveredWorkspace.stage(
                .create(
                    relativePath: "never-committed.txt",
                    content: Data("private staged body".utf8),
                    contentType: "text/plain"
                ),
                sourceStepIDs: [UUID()],
                invocation: .init(
                    toolName: "write_file",
                    invocationDigest: "disconnect-recovered"
                )
            )
            // Drop the actor and rely on root enumeration, matching a
            // workspace recovered from a previous process lifetime.
            _ = recoveredWorkspace

            #expect(try CoworkArtifactWorkspaceRetention.removeAll(
                rootURL: root,
                expectedRootIdentity: identity
            ) == 2)
            #expect(!FileManager.default.fileExists(
                atPath: committedWorkspace.workspaceURL.path
            ))
            #expect(!FileManager.default.fileExists(
                atPath: recoveredWorkspace.workspaceURL.path
            ))
            #expect(try read("reports/result.txt", beneath: root) == "committed destination\n")
            #expect(!FileManager.default.fileExists(
                atPath: root.appendingPathComponent("never-committed.txt").path
            ))

            let reopened = try CoworkArtifactTransactionWorkspace(
                rootURL: root,
                expectedRootIdentity: identity,
                runID: committedRunID
            )
            await #expect(throws: CoworkArtifactTransactionError.rollbackUnavailable(
                committedPreview.transactionID
            )) {
                _ = try await reopened.rollback(
                    transactionID: committedPreview.transactionID
                )
            }
        }
    }

    @Test func cancelledStageHasNoDurableArtifactSnapshot() async throws {
        try await withTemporaryCoworkRoot { root in
            let workspace = try makeWorkspace(root: root)
            let preview = try await workspace.stage(
                .create(
                    relativePath: "cancelled.txt",
                    content: Data("never committed".utf8),
                    contentType: "text/plain"
                ),
                sourceStepIDs: [UUID()],
                invocation: .init(toolName: "write_file", invocationDigest: "cancel")
            )
            try await workspace.cancel(transactionID: preview.transactionID)

            await #expect(throws: CoworkArtifactTransactionError.unknownTransaction(
                preview.transactionID
            )) {
                _ = try await workspace.durableArtifactSnapshot(
                    transactionID: preview.transactionID
                )
            }
            #expect(!FileManager.default.fileExists(
                atPath: root.appendingPathComponent("cancelled.txt").path
            ))
        }
    }

    @Test func overwritePreviewRequiresDigestBoundUnexpiredApproval() async throws {
        try await withTemporaryCoworkRoot { root in
            try write("old line\n", to: "draft.txt", beneath: root)
            let at = Date(timeIntervalSince1970: 1_000)
            let workspace = try makeWorkspace(root: root)
            let preview = try await workspace.stage(
                .replace(
                    relativePath: "draft.txt",
                    content: Data("new line\n".utf8),
                    contentType: "text/plain"
                ),
                sourceStepIDs: [UUID()],
                invocation: .init(toolName: "write_file", invocationDigest: "replace-v1"),
                at: at
            )

            #expect(preview.requiresApproval)
            #expect(preview.risk == .overwrite)
            #expect(preview.textDiff?.unifiedText.contains("-old line") == true)
            #expect(preview.textDiff?.unifiedText.contains("+new line") == true)
            #expect(preview.metadata.priorByteCount == 9)
            #expect(preview.metadata.proposedByteCount == 9)
            #expect(try read("draft.txt", beneath: root) == "old line\n")

            await #expect(throws: CoworkArtifactTransactionError.approvalRequired(
                preview.transactionID
            )) {
                _ = try await workspace.commit(
                    transactionID: preview.transactionID,
                    at: at
                )
            }
            let expired = CoworkArtifactCommitAuthorization(
                preview: preview,
                approvedAt: at,
                validFor: 1
            )
            await #expect(throws: CoworkArtifactTransactionError.expiredApproval) {
                _ = try await workspace.commit(
                    transactionID: preview.transactionID,
                    authorization: expired,
                    at: at.addingTimeInterval(2)
                )
            }

            let unrelated = try await workspace.stage(
                .create(
                    relativePath: "other.txt",
                    content: Data("other".utf8),
                    contentType: "text/plain"
                ),
                sourceStepIDs: [UUID()],
                invocation: .init(toolName: "write_file", invocationDigest: "other"),
                at: at
            )
            await #expect(throws: CoworkArtifactTransactionError.invalidApproval) {
                _ = try await workspace.commit(
                    transactionID: preview.transactionID,
                    authorization: CoworkArtifactCommitAuthorization(
                        preview: unrelated,
                        approvedAt: at
                    ),
                    at: at
                )
            }

            let result = try await workspace.commit(
                transactionID: preview.transactionID,
                authorization: CoworkArtifactCommitAuthorization(
                    preview: preview,
                    approvedAt: at
                ),
                at: at
            )
            #expect(result.commitState == .committed)
            #expect(result.previewDigest == preview.previewDigest)
            #expect(try read("draft.txt", beneath: root) == "new line\n")
        }
    }

    @Test func targetSubstitutionAfterPreviewFailsClosed() async throws {
        try await withTemporaryCoworkRoot { root in
            try write("reviewed\n", to: "target.txt", beneath: root)
            let workspace = try makeWorkspace(root: root)
            let preview = try await workspace.stage(
                .replace(
                    relativePath: "target.txt",
                    content: Data("approved replacement\n".utf8),
                    contentType: "text/plain"
                ),
                sourceStepIDs: [UUID()],
                invocation: .init(toolName: "write_file", invocationDigest: "bound-target")
            )
            try write("substituted after preview\n", to: "target.txt", beneath: root)

            await #expect(throws: CoworkArtifactTransactionError.self) {
                _ = try await workspace.commit(
                    transactionID: preview.transactionID,
                    authorization: CoworkArtifactCommitAuthorization(preview: preview)
                )
            }
            #expect(try read("target.txt", beneath: root) == "substituted after preview\n")
        }
    }

    @Test func appendMoveAndRecoverableDeleteCanEachRollback() async throws {
        try await withTemporaryCoworkRoot { root in
            try write("one\n", to: "log.txt", beneath: root)
            let workspace = try makeWorkspace(root: root)

            let append = try await workspace.stage(
                .append(
                    relativePath: "log.txt",
                    content: Data("two\n".utf8),
                    contentType: "text/plain"
                ),
                sourceStepIDs: [UUID()],
                invocation: .init(toolName: "write_file", invocationDigest: "append")
            )
            let appended = try await workspace.commit(
                transactionID: append.transactionID,
                authorization: CoworkArtifactCommitAuthorization(preview: append)
            )
            #expect(try read("log.txt", beneath: root) == "one\ntwo\n")
            let appendRollback = try await workspace.rollback(
                transactionID: appended.transactionID
            )
            #expect(appendRollback.commitState == .rolledBack)
            #expect(try read("log.txt", beneath: root) == "one\n")

            let move = try await workspace.stage(
                .move(
                    sourceRelativePath: "log.txt",
                    destinationRelativePath: "archive/log.txt"
                ),
                sourceStepIDs: [UUID()],
                invocation: .init(toolName: "move_file", invocationDigest: "move")
            )
            _ = try await workspace.commit(
                transactionID: move.transactionID,
                authorization: CoworkArtifactCommitAuthorization(preview: move)
            )
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("log.txt").path))
            #expect(try read("archive/log.txt", beneath: root) == "one\n")
            _ = try await workspace.rollback(transactionID: move.transactionID)
            #expect(try read("log.txt", beneath: root) == "one\n")
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("archive/log.txt").path))

            let deletion = try await workspace.stage(
                .delete(relativePath: "log.txt"),
                sourceStepIDs: [UUID()],
                invocation: .init(toolName: "delete_file", invocationDigest: "delete")
            )
            #expect(deletion.textDiff?.unifiedText.contains("-one") == true)
            let deleted = try await workspace.commit(
                transactionID: deletion.transactionID,
                authorization: CoworkArtifactCommitAuthorization(preview: deletion)
            )
            #expect(!deleted.existsAfterCommit)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("log.txt").path))
            let restored = try await workspace.rollback(transactionID: deletion.transactionID)
            #expect(restored.existsAfterCommit)
            #expect(try read("log.txt", beneath: root) == "one\n")
        }
    }

    @Test func cancellationBeforeCommitLeavesDestinationAndTransactionStaged() async throws {
        try await withTemporaryCoworkRoot { root in
            let workspace = try makeWorkspace(root: root)
            let preview = try await workspace.stage(
                .create(
                    relativePath: "cancelled.txt",
                    content: Data("must stay staged".utf8),
                    contentType: "text/plain"
                ),
                sourceStepIDs: [UUID()],
                invocation: .init(toolName: "write_file", invocationDigest: "cancel")
            )
            let task = Task {
                try await workspace.commit(transactionID: preview.transactionID)
            }
            task.cancel()
            await #expect(throws: CancellationError.self) {
                _ = try await task.value
            }
            #expect(!FileManager.default.fileExists(
                atPath: root.appendingPathComponent("cancelled.txt").path
            ))
            #expect(await workspace.pendingPreviews().map(\.transactionID) == [preview.transactionID])
            try await workspace.cancel(transactionID: preview.transactionID)
            #expect(await workspace.pendingPreviews().isEmpty)
        }
    }

    @Test func interruptionRecoveryObservesEitherPriorOrCompleteNewFile() async throws {
        try await withTemporaryCoworkRoot { root in
            try write("prior\n", to: "before.txt", beneath: root)
            let identity = try CoworkRootIdentity.capture(root)
            let runBefore = UUID()
            let beforeWorkspace = try CoworkArtifactTransactionWorkspace(
                rootURL: root,
                expectedRootIdentity: identity,
                runID: runBefore,
                hooks: CoworkArtifactTransactionHooks { checkpoint in
                    if checkpoint == .beforeAtomicMutation {
                        throw InjectedCoworkFailure.interruption
                    }
                }
            )
            let before = try await beforeWorkspace.stage(
                .replace(
                    relativePath: "before.txt",
                    content: Data("new\n".utf8),
                    contentType: "text/plain"
                ),
                sourceStepIDs: [UUID()],
                invocation: .init(toolName: "write_file", invocationDigest: "before")
            )
            await #expect(throws: InjectedCoworkFailure.interruption) {
                _ = try await beforeWorkspace.commit(
                    transactionID: before.transactionID,
                    authorization: CoworkArtifactCommitAuthorization(preview: before)
                )
            }
            #expect(try read("before.txt", beneath: root) == "prior\n")
            let reopenedBefore = try CoworkArtifactTransactionWorkspace(
                rootURL: root,
                expectedRootIdentity: identity,
                runID: runBefore
            )
            let beforeRecovery = try await reopenedBefore.recoverInterruptedTransactions()
            #expect(beforeRecovery == [CoworkArtifactRecoveryResult(
                transactionID: before.transactionID,
                disposition: .readyToRetry,
                result: nil
            )])

            let runAfter = UUID()
            let afterWorkspace = try CoworkArtifactTransactionWorkspace(
                rootURL: root,
                expectedRootIdentity: identity,
                runID: runAfter,
                hooks: CoworkArtifactTransactionHooks { checkpoint in
                    if checkpoint == .afterAtomicMutation {
                        throw InjectedCoworkFailure.interruption
                    }
                }
            )
            let after = try await afterWorkspace.stage(
                .create(
                    relativePath: "after.txt",
                    content: Data("complete new bytes\n".utf8),
                    contentType: "text/plain"
                ),
                sourceStepIDs: [UUID()],
                invocation: .init(toolName: "write_file", invocationDigest: "after")
            )
            await #expect(throws: InjectedCoworkFailure.interruption) {
                _ = try await afterWorkspace.commit(transactionID: after.transactionID)
            }
            #expect(try read("after.txt", beneath: root) == "complete new bytes\n")
            let reopenedAfter = try CoworkArtifactTransactionWorkspace(
                rootURL: root,
                expectedRootIdentity: identity,
                runID: runAfter
            )
            let afterRecovery = try await reopenedAfter.recoverInterruptedTransactions()
            #expect(afterRecovery.count == 1)
            #expect(afterRecovery[0].disposition == .finalizedCommitted)
            #expect(afterRecovery[0].result?.sha256.count == 64)
            #expect((await reopenedAfter.manifest()).artifacts.count == 1)
        }
    }

    @Test func traversalAbsoluteSymlinkAliasAndHardLinkTargetsFailSafely() async throws {
        try await withTemporaryCoworkRoot { root in
            let workspace = try makeWorkspace(root: root)
            let sourceStep = [UUID()]
            let invocation = CoworkArtifactInvocation(
                toolName: "write_file",
                invocationDigest: "containment"
            )
            await #expect(throws: CoworkArtifactTransactionError.invalidRelativePath) {
                _ = try await workspace.stage(
                    .create(
                        relativePath: "../escape.txt",
                        content: Data("escape".utf8),
                        contentType: "text/plain"
                    ),
                    sourceStepIDs: sourceStep,
                    invocation: invocation
                )
            }
            await #expect(throws: CoworkArtifactTransactionError.invalidRelativePath) {
                _ = try await workspace.stage(
                    .create(
                        relativePath: "/tmp/absolute.txt",
                        content: Data("escape".utf8),
                        contentType: "text/plain"
                    ),
                    sourceStepIDs: sourceStep,
                    invocation: invocation
                )
            }
            await #expect(throws: CoworkArtifactTransactionError.reservedPath) {
                _ = try await workspace.stage(
                    .create(
                        relativePath: ".straight-up-browser/tamper.json",
                        content: Data("tamper".utf8),
                        contentType: "application/json"
                    ),
                    sourceStepIDs: sourceStep,
                    invocation: invocation
                )
            }

            let outside = root.deletingLastPathComponent()
                .appendingPathComponent("cowork-outside-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("linked"),
                withDestinationURL: outside
            )
            await #expect(throws: CoworkArtifactTransactionError.symbolicLinkRejected("linked/file.txt")) {
                _ = try await workspace.stage(
                    .create(
                        relativePath: "linked/file.txt",
                        content: Data("escape".utf8),
                        contentType: "text/plain"
                    ),
                    sourceStepIDs: sourceStep,
                    invocation: invocation
                )
            }
            #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("file.txt").path))

            try write("hard-linked", to: "original.txt", beneath: root)
            try FileManager.default.linkItem(
                at: root.appendingPathComponent("original.txt"),
                to: root.appendingPathComponent("hard-link.txt")
            )
            await #expect(throws: CoworkArtifactTransactionError.hardLinkRejected("hard-link.txt")) {
                _ = try await workspace.stage(
                    .replace(
                        relativePath: "hard-link.txt",
                        content: Data("new".utf8),
                        contentType: "text/plain"
                    ),
                    sourceStepIDs: sourceStep,
                    invocation: invocation
                )
            }

            #if os(macOS)
            let bookmark = try root.appendingPathComponent("original.txt").bookmarkData(
                options: .suitableForBookmarkFile,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let alias = root.appendingPathComponent("original alias")
            try URL.writeBookmarkData(bookmark, to: alias)
            await #expect(throws: CoworkArtifactTransactionError.aliasRejected("original alias")) {
                _ = try await workspace.stage(
                    .delete(relativePath: "original alias"),
                    sourceStepIDs: sourceStep,
                    invocation: invocation
                )
            }
            #endif
        }
    }

    @Test func sizeRecursionBinaryDirectoryAndFilenameCollisionsAreBounded() async throws {
        try await withTemporaryCoworkRoot { root in
            let limits = CoworkArtifactTransactionLimits(
                maximumArtifactBytes: 8,
                maximumPathDepth: 2
            )
            let workspace = try makeWorkspace(root: root, limits: limits)
            let invocation = CoworkArtifactInvocation(
                toolName: "write_file",
                invocationDigest: "bounds"
            )
            await #expect(throws: CoworkArtifactTransactionError.artifactTooLarge(
                maximumBytes: 8
            )) {
                _ = try await workspace.stage(
                    .create(
                        relativePath: "large.txt",
                        content: Data(repeating: 1, count: 9),
                        contentType: "application/octet-stream"
                    ),
                    sourceStepIDs: [UUID()],
                    invocation: invocation
                )
            }
            await #expect(throws: CoworkArtifactTransactionError.pathTooDeep(maximumDepth: 2)) {
                _ = try await workspace.stage(
                    .create(
                        relativePath: "a/b/c.txt",
                        content: Data("small".utf8),
                        contentType: "text/plain"
                    ),
                    sourceStepIDs: [UUID()],
                    invocation: invocation
                )
            }

            try write("existing", to: "Report.txt", beneath: root)
            await #expect(throws: CoworkArtifactTransactionError.filenameCollision("Report.txt")) {
                _ = try await workspace.stage(
                    .create(
                        relativePath: "report.txt",
                        content: Data("small".utf8),
                        contentType: "text/plain"
                    ),
                    sourceStepIDs: [UUID()],
                    invocation: invocation
                )
            }

            let folder = root.appendingPathComponent("folder", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            await #expect(throws: CoworkArtifactTransactionError.directoryOperationRejected("folder")) {
                _ = try await workspace.stage(
                    .delete(relativePath: "folder"),
                    sourceStepIDs: [UUID()],
                    invocation: invocation
                )
            }

            try Data([0xFF, 0x00]).write(to: root.appendingPathComponent("binary.bin"))
            await #expect(throws: CoworkArtifactTransactionError.binaryRewriteRequiresDedicatedHandler) {
                _ = try await workspace.stage(
                    .replace(
                        relativePath: "binary.bin",
                        content: Data([0x00, 0x01]),
                        contentType: "application/octet-stream"
                    ),
                    sourceStepIDs: [UUID()],
                    invocation: invocation
                )
            }
        }
    }

    @Test func diskFullBeforeAtomicMutationKeepsPriorBytesAndCanRecoverForRetry() async throws {
        try await withTemporaryCoworkRoot { root in
            try write("prior bytes\n", to: "disk.txt", beneath: root)
            let identity = try CoworkRootIdentity.capture(root)
            let runID = UUID()
            let workspace = try CoworkArtifactTransactionWorkspace(
                rootURL: root,
                expectedRootIdentity: identity,
                runID: runID,
                hooks: CoworkArtifactTransactionHooks { checkpoint in
                    if checkpoint == .beforeAtomicMutation {
                        throw CoworkArtifactTransactionError.insufficientDiskSpace
                    }
                }
            )
            let preview = try await workspace.stage(
                .replace(
                    relativePath: "disk.txt",
                    content: Data("new bytes\n".utf8),
                    contentType: "text/plain"
                ),
                sourceStepIDs: [UUID()],
                invocation: .init(toolName: "write_file", invocationDigest: "disk-full")
            )
            await #expect(throws: CoworkArtifactTransactionError.insufficientDiskSpace) {
                _ = try await workspace.commit(
                    transactionID: preview.transactionID,
                    authorization: CoworkArtifactCommitAuthorization(preview: preview)
                )
            }
            #expect(try read("disk.txt", beneath: root) == "prior bytes\n")

            let reopened = try CoworkArtifactTransactionWorkspace(
                rootURL: root,
                expectedRootIdentity: identity,
                runID: runID
            )
            let recovery = try await reopened.recoverInterruptedTransactions()
            #expect(recovery.map(\.disposition) == [.readyToRetry])
            #expect(await reopened.pendingPreviews().map(\.transactionID) == [preview.transactionID])
        }
    }

    @Test func workspacesArePerRunAndPendingRecordsSurviveRelaunch() async throws {
        try await withTemporaryCoworkRoot { root in
            let identity = try CoworkRootIdentity.capture(root)
            let firstRun = UUID()
            let secondRun = UUID()
            let first = try CoworkArtifactTransactionWorkspace(
                rootURL: root,
                expectedRootIdentity: identity,
                runID: firstRun
            )
            let preview = try await first.stage(
                .create(
                    relativePath: "durable.txt",
                    content: Data("durable staged bytes".utf8),
                    contentType: "text/plain"
                ),
                sourceStepIDs: [UUID()],
                invocation: .init(toolName: "write_file", invocationDigest: "durable")
            )
            let second = try CoworkArtifactTransactionWorkspace(
                rootURL: root,
                expectedRootIdentity: identity,
                runID: secondRun
            )
            await #expect(throws: CoworkArtifactTransactionError.unknownTransaction(
                preview.transactionID
            )) {
                _ = try await second.commit(transactionID: preview.transactionID)
            }
            #expect(first.workspaceURL != second.workspaceURL)

            let reopened = try CoworkArtifactTransactionWorkspace(
                rootURL: root,
                expectedRootIdentity: identity,
                runID: firstRun
            )
            #expect(await reopened.pendingPreviews().map(\.transactionID) == [preview.transactionID])
            let committed = try await reopened.commit(transactionID: preview.transactionID)
            #expect(committed.runID == firstRun)
            #expect(try read("durable.txt", beneath: root) == "durable staged bytes")
        }
    }

    @Test func manifestAndModelResultAreTypedBoundedAndNeverContainArtifactBody() async throws {
        try await withTemporaryCoworkRoot { root in
            let runID = UUID()
            let sourceSteps = [UUID(), UUID()]
            let marker = String(repeating: "secret-artifact-body-", count: 20)
            let workspace = try CoworkArtifactTransactionWorkspace(
                rootURL: root,
                expectedRootIdentity: CoworkRootIdentity.capture(root),
                runID: runID
            )
            let preview = try await workspace.stage(
                .create(
                    relativePath: "reports/summary.txt",
                    content: Data(marker.utf8),
                    contentType: "text/plain"
                ),
                sourceStepIDs: sourceSteps,
                invocation: .init(toolName: "write_file", invocationDigest: "manifest")
            )
            let result = try await workspace.commit(transactionID: preview.transactionID)
            let manifest = await workspace.manifest()
            #expect(manifest.runID == runID)
            #expect(manifest.artifacts == [result])
            #expect(result.sourceStepIDs == sourceSteps)
            #expect(result.finalRelativePath == "reports/summary.txt")
            #expect(result.contentType == "text/plain")
            #expect(result.byteCount == marker.utf8.count)
            #expect(result.sha256.count == 64)
            #expect(result.commitState == .committed)

            let modelData = try result.boundedModelResult(maximumBytes: 1_024)
            #expect(modelData.count <= 1_024)
            let modelText = String(decoding: modelData, as: UTF8.self)
            #expect(!modelText.contains(marker))
            #expect(modelText.contains(result.sha256))

            let manifestData = try Data(
                contentsOf: workspace.workspaceURL.appendingPathComponent("manifest.json")
            )
            #expect(!String(decoding: manifestData, as: UTF8.self).contains(marker))
            #expect(try #require(
                FileManager.default.attributesOfItem(
                    atPath: workspace.workspaceURL.appendingPathComponent("manifest.json").path
                )[.posixPermissions] as? NSNumber
            ).intValue == 0o600)
        }
    }

    @Test func priorVersionsAreBoundedAndNewestRollbackRestoresExactly() async throws {
        try await withTemporaryCoworkRoot { root in
            try write("v0\n", to: "versioned.txt", beneath: root)
            let base = Date(timeIntervalSince1970: 5_000)
            let workspace = try makeWorkspace(
                root: root,
                limits: CoworkArtifactTransactionLimits(
                    maximumPriorVersionsPerPath: 1,
                    priorVersionRetention: 100
                )
            )
            let first = try await workspace.stage(
                .replace(
                    relativePath: "versioned.txt",
                    content: Data("v1\n".utf8),
                    contentType: "text/plain"
                ),
                sourceStepIDs: [UUID()],
                invocation: .init(toolName: "write_file", invocationDigest: "v1"),
                at: base
            )
            _ = try await workspace.commit(
                transactionID: first.transactionID,
                authorization: CoworkArtifactCommitAuthorization(
                    preview: first,
                    approvedAt: base
                ),
                at: base
            )
            let second = try await workspace.stage(
                .replace(
                    relativePath: "versioned.txt",
                    content: Data("v2\n".utf8),
                    contentType: "text/plain"
                ),
                sourceStepIDs: [UUID()],
                invocation: .init(toolName: "write_file", invocationDigest: "v2"),
                at: base.addingTimeInterval(1)
            )
            _ = try await workspace.commit(
                transactionID: second.transactionID,
                authorization: CoworkArtifactCommitAuthorization(
                    preview: second,
                    approvedAt: base.addingTimeInterval(1)
                ),
                at: base.addingTimeInterval(1)
            )
            #expect(try read("versioned.txt", beneath: root) == "v2\n")

            let manifest = await workspace.manifest()
            let firstResult = try #require(manifest.artifacts.first {
                $0.transactionID == first.transactionID
            })
            let secondResult = try #require(manifest.artifacts.first {
                $0.transactionID == second.transactionID
            })
            #expect(firstResult.rollbackAvailableUntil == nil)
            #expect(secondResult.rollbackAvailableUntil != nil)
            await #expect(throws: CoworkArtifactTransactionError.rollbackUnavailable(
                first.transactionID
            )) {
                _ = try await workspace.rollback(
                    transactionID: first.transactionID,
                    at: base.addingTimeInterval(2)
                )
            }
            _ = try await workspace.rollback(
                transactionID: second.transactionID,
                at: base.addingTimeInterval(2)
            )
            #expect(try read("versioned.txt", beneath: root) == "v1\n")
        }
    }

    @Test func retentionExpiryRemovesPriorBytesAndDisablesRollback() async throws {
        try await withTemporaryCoworkRoot { root in
            try write("prior retention body\n", to: "retained.txt", beneath: root)
            let base = Date(timeIntervalSince1970: 7_000)
            let workspace = try makeWorkspace(
                root: root,
                limits: CoworkArtifactTransactionLimits(priorVersionRetention: 10)
            )
            let preview = try await workspace.stage(
                .replace(
                    relativePath: "retained.txt",
                    content: Data("current\n".utf8),
                    contentType: "text/plain"
                ),
                sourceStepIDs: [UUID()],
                invocation: .init(toolName: "write_file", invocationDigest: "retention"),
                at: base
            )
            _ = try await workspace.commit(
                transactionID: preview.transactionID,
                authorization: CoworkArtifactCommitAuthorization(
                    preview: preview,
                    approvedAt: base
                ),
                at: base
            )
            #expect(try await workspace.expirePriorVersions(
                at: base.addingTimeInterval(11)
            ) == 1)
            await #expect(throws: CoworkArtifactTransactionError.rollbackUnavailable(
                preview.transactionID
            )) {
                _ = try await workspace.rollback(
                    transactionID: preview.transactionID,
                    at: base.addingTimeInterval(11)
                )
            }
            let priorFiles = try FileManager.default.contentsOfDirectory(
                at: workspace.workspaceURL.appendingPathComponent("prior"),
                includingPropertiesForKeys: nil
            )
            #expect(priorFiles.isEmpty)
        }
    }

    @Test func rootIdentityReplacementInvalidatesEveryPendingCommit() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("cowork-root-identity-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("root", isDirectory: true)
        let displaced = parent.appendingPathComponent("displaced", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let identity = try CoworkRootIdentity.capture(root)
        let workspace = try CoworkArtifactTransactionWorkspace(
            rootURL: root,
            expectedRootIdentity: identity,
            runID: UUID()
        )
        let preview = try await workspace.stage(
            .create(
                relativePath: "pending.txt",
                content: Data("pending".utf8),
                contentType: "text/plain"
            ),
            sourceStepIDs: [UUID()],
            invocation: .init(toolName: "write_file", invocationDigest: "root-swap")
        )
        try FileManager.default.moveItem(at: root, to: displaced)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        await #expect(throws: CoworkArtifactTransactionError.rootIdentityChanged) {
            _ = try await workspace.commit(transactionID: preview.transactionID)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("pending.txt").path))
        #expect(!FileManager.default.fileExists(atPath: displaced.appendingPathComponent("pending.txt").path))
    }
}

private func withTemporaryCoworkRoot(
    _ body: (URL) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cowork-artifact-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
}

private func makeWorkspace(
    root: URL,
    runID: UUID = UUID(),
    limits: CoworkArtifactTransactionLimits = CoworkArtifactTransactionLimits()
) throws -> CoworkArtifactTransactionWorkspace {
    try CoworkArtifactTransactionWorkspace(
        rootURL: root,
        expectedRootIdentity: CoworkRootIdentity.capture(root),
        runID: runID,
        limits: limits
    )
}

private func write(_ value: String, to relativePath: String, beneath root: URL) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(value.utf8).write(to: url, options: .atomic)
}

private func read(_ relativePath: String, beneath root: URL) throws -> String {
    let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
    return try #require(String(data: data, encoding: .utf8))
}

private enum InjectedCoworkFailure: Error {
    case interruption
}
