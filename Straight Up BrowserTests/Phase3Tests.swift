//
//  Phase3Tests.swift
//  Straight Up BrowserTests
//
//  Share-sheet capture (docs/phase3-design.md): the queue round trip, the
//  drain into the ledger, file-import identity, the workspace mirror, and
//  "items movable afterward".
//

import Foundation
import SwiftData
import Testing
@testable import Browser

@MainActor
private func makePhase3Stores() throws -> (ModelContainer, ModelContext, LedgerStore, URL) {
    let schema = Schema([
        NewspaperArticle.self, Workspace.self, WorkspaceSourceRef.self,
        WorkspaceDocument.self, LedgerAnchor.self, LedgerClaim.self,
        LedgerEdge.self, LedgerArchive.self, SourceTranscript.self, Tab.self
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let context = ModelContext(container)
    let group = FileManager.default.temporaryDirectory
        .appendingPathComponent("Phase3Tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
    return (container, context, LedgerStore(modelContext: context), group)
}

@MainActor
struct ShareQueueTests {

    @Test func queueRoundTripsItemsOldestFirst() throws {
        let (_, _, _, group) = try makePhase3Stores()
        let workspaceId = UUID()
        let older = ShareQueue.SharedItem(
            workspaceId: workspaceId, url: URL(string: "https://a.example")!,
            title: "A", fileName: nil, sharedAt: Date(timeIntervalSinceNow: -60))
        let newer = ShareQueue.SharedItem(
            workspaceId: workspaceId, url: URL(string: "https://b.example")!,
            title: "B", fileName: nil, sharedAt: Date())
        #expect(ShareQueue.enqueue(newer, container: group))
        #expect(ShareQueue.enqueue(older, container: group))
        let pending = ShareQueue.pending(container: group)
        #expect(pending.map(\.item.title) == ["A", "B"], "oldest first")
        ShareQueue.clear(older, container: group)
        #expect(ShareQueue.pending(container: group).map(\.item.title) == ["B"])
    }

    @Test func filePayloadRidesBesideTheItem() throws {
        let (_, _, _, group) = try makePhase3Stores()
        let item = ShareQueue.SharedItem(
            workspaceId: UUID(), url: nil, title: "photo", fileName: "photo.png")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        #expect(ShareQueue.enqueue(item, fileData: bytes, container: group))
        let pending = ShareQueue.pending(container: group)
        #expect(pending.first?.fileData == bytes)
        ShareQueue.clear(item, container: group)
        let inbox = ShareQueue.inboxURL(container: group)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []).isEmpty,
                "clear removes payload and JSON alike")
    }

    @Test func mirrorSortsMostRecentFirstAndStampsTheActiveWorkspace() {
        let suite = "Phase3MirrorTests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let older = ShareQueue.MirroredWorkspace(id: UUID(), name: "Old", lastActiveAt: Date(timeIntervalSinceNow: -3600))
        let newer = ShareQueue.MirroredWorkspace(id: UUID(), name: "New", lastActiveAt: Date(timeIntervalSinceNow: -60))
        // The ACTIVE workspace wins even with the oldest stored timestamp.
        ShareQueue.updateMirror([older, newer], activeWorkspaceId: older.id, groupID: suite)
        let mirrored = ShareQueue.mirroredWorkspaces(groupID: suite)
        #expect(mirrored.map(\.name) == ["Old", "New"])
    }
}

@MainActor
struct ShareIngestTests {

    @Test func drainRecordsSharesAsOpenShareSheetReferences() throws {
        let (_, context, ledger, group) = try makePhase3Stores()
        let workspace = Workspace(name: "Fermentation")
        context.insert(workspace)
        ShareQueue.enqueue(ShareQueue.SharedItem(
            workspaceId: workspace.id,
            url: URL(string: "https://example.com/paper?utm_source=x")!,
            title: "A Paper", fileName: nil), container: group)

        let result = ShareIngest.drain(ledgerStore: ledger, container: group,
                                       importsDirectory: group.appendingPathComponent("Imports"))
        #expect(result.ingested == 1)
        #expect(result.workspaceName == "Fermentation")
        #expect(ShareQueue.pending(container: group).isEmpty, "ingested items leave the queue")

        let ref = ledger.reference(workspaceId: workspace.id, sourceKey: "https://example.com/paper")
        let reference = try #require(ref, "canonicalization ran — tracking params stripped")
        #expect(reference.method == .shareSheet)
        #expect(reference.disposition == .open)
        let article = try #require(ledger.source(sourceKey: "https://example.com/paper"))
        #expect(article.captureState == .deferred, "no text at drain; fills in on first open")
    }

    @Test func fileImportsCollapseOnContentHash() throws {
        let (_, context, ledger, group) = try makePhase3Stores()
        let workspaceA = Workspace(name: "A"); context.insert(workspaceA)
        let workspaceB = Workspace(name: "B"); context.insert(workspaceB)
        let bytes = Data("same pdf bytes".utf8)
        let imports = group.appendingPathComponent("Imports")

        let first = try #require(ledger.recordFileImport(
            data: bytes, suggestedName: "study.pdf", workspaceId: workspaceA.id, importsDirectory: imports))
        let second = try #require(ledger.recordFileImport(
            data: bytes, suggestedName: "renamed.pdf", workspaceId: workspaceB.id, importsDirectory: imports))
        #expect(first.id == second.id, "same bytes are one source")
        #expect(first.sourceKey.hasPrefix("hash:"))
        #expect(first.modality == .pdf)
        #expect(ledger.references(sourceKey: first.sourceKey).count == 2, "one source, two workspace references")
        #expect(FileManager.default.fileExists(atPath: first.url.path), "bytes persisted to Imports")
    }

    @Test func vanishedWorkspacesDropTheirItems() throws {
        let (_, _, ledger, group) = try makePhase3Stores()
        ShareQueue.enqueue(ShareQueue.SharedItem(
            workspaceId: UUID(), url: URL(string: "https://x.example")!,
            title: "Orphan", fileName: nil), container: group)
        let result = ShareIngest.drain(ledgerStore: ledger, container: group,
                                       importsDirectory: group.appendingPathComponent("Imports"))
        #expect(result.ingested == 0)
        #expect(ShareQueue.pending(container: group).isEmpty, "no poison-pill queue")
    }
}

@MainActor
struct MoveReferenceTests {

    @Test func movingRepointsTheJoinRowAndNothingElse() throws {
        let (_, context, ledger, _) = try makePhase3Stores()
        let workspaceA = Workspace(name: "A"); context.insert(workspaceA)
        let workspaceB = Workspace(name: "B"); context.insert(workspaceB)
        let article = ledger.recordShareCapture(
            url: URL(string: "https://example.com/page")!, title: "P", workspaceId: workspaceA.id)
        let section = article.section
        let firstWorkspace = article.firstWorkspaceId
        let ref = try #require(ledger.reference(workspaceId: workspaceA.id, sourceKey: article.sourceKey))
        let addedAt = ref.addedAt

        ledger.moveReference(ref, to: workspaceB.id)
        #expect(ledger.reference(workspaceId: workspaceA.id, sourceKey: article.sourceKey) == nil)
        let moved = try #require(ledger.reference(workspaceId: workspaceB.id, sourceKey: article.sourceKey))
        #expect(moved.method == .shareSheet, "method travels")
        #expect(moved.addedAt == addedAt, "history is history")
        #expect(article.section == section, "the Section never re-files")
        #expect(article.firstWorkspaceId == firstWorkspace, "firstWorkspaceId is history, not location")
    }

    @Test func movingOntoAnExistingReferenceMerges() throws {
        let (_, context, ledger, _) = try makePhase3Stores()
        let workspaceA = Workspace(name: "A"); context.insert(workspaceA)
        let workspaceB = Workspace(name: "B"); context.insert(workspaceB)
        let url = URL(string: "https://example.com/page")!
        ledger.recordShareCapture(url: url, title: "P", workspaceId: workspaceA.id)
        ledger.recordManualCapture(url: url, title: "P", workspaceId: workspaceB.id)
        let key = SourceCanonicalizer.canonicalKey(for: url)
        let refA = try #require(ledger.reference(workspaceId: workspaceA.id, sourceKey: key))
        let refB = try #require(ledger.reference(workspaceId: workspaceB.id, sourceKey: key))

        ledger.moveReference(refA, to: workspaceB.id)
        let remaining = ledger.references(sourceKey: key)
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == refB.id, "the destination's row survives; the mover dissolves")
    }
}
