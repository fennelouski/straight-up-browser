//
//  Phase7Tests.swift
//  Straight Up BrowserTests
//
//  Deep-research import (docs/phase7-design.md): the parser tables, and the
//  end-to-end pipeline against real stores — proving one ordinary Phase 2 save
//  turns an imported report into repaired links + pre-populated edges, and
//  that lineage makes the bundle one Shared Upstream fan.
//

import Foundation
import SwiftData
import Testing
@testable import Browser

struct ReportParserTests {

    @Test func titleComesFromHeadingThenFirstLineThenOverride() {
        #expect(ResearchReportParser.parse("# Gut Health Report\n\nBody.").title == "Gut Health Report")
        #expect(ResearchReportParser.parse("Plain first line\n\nBody.").title == "Plain first line")
        #expect(ResearchReportParser.parse("# Ignored\n", titleOverride: "Chosen").title == "Chosen")
        let longLine = String(repeating: "x", count: 200)
        #expect(ResearchReportParser.parse(longLine).title.count == ResearchReportParser.maximumTitleLength)
    }

    @Test func markdownLinksAndBareURLsBothBecomeCitations() {
        let report = ResearchReportParser.parse("""
        # R
        A claim [the study](https://a.example/paper?utm_source=chat) here.
        Sources:
        [1] https://b.example/post.
        ftp://ignored.example/file
        """)
        #expect(report.citations.count == 2)
        let markdown = report.citations[0]
        #expect(markdown.isMarkdownLink && markdown.text == "the study")
        let bare = report.citations[1]
        #expect(!bare.isMarkdownLink && bare.text.isEmpty)
        #expect(bare.url.absoluteString == "https://b.example/post", "trailing prose punctuation trimmed")
    }

    @Test func citationsDeduplicateOnCanonicalKeyAndLinksBeatBareTwins() {
        let report = ResearchReportParser.parse("""
        [named](https://a.example/paper?utm_source=x) and later its footnote:
        https://a.example/paper
        """)
        #expect(report.citations.count == 1)
        #expect(report.citations[0].isMarkdownLink, "the Markdown link wins over its bare twin")
    }

    @Test func locatorInferenceMatchesWhatTheResolverExpects() {
        let video = URL(string: "https://youtube.com/watch?v=abc&t=417")!
        #expect(ResearchReportParser.inferredLocator(for: video, modality: .video)
                == .timestamp(start: 417, end: nil))
        let fragment = URL(string: "https://a.example/p#:~:text=gut%20bacteria")!
        #expect(ResearchReportParser.inferredLocator(for: fragment, modality: .webPage)
                == .textFragment("text=gut%20bacteria"))
        #expect(ResearchReportParser.inferredLocator(for: URL(string: "https://a.example/p")!, modality: .webPage)
                == .wholeSource)
    }
}

/// Shared by the import tests and the handoff tests below — the same real
/// stores over an in-memory container and a throwaway documents folder.
@MainActor
private func makeStores() throws -> (ModelContainer, ModelContext, LedgerStore, DocumentStore, URL) {
    let schema = Schema([
        NewspaperArticle.self, Workspace.self, WorkspaceSourceRef.self,
        WorkspaceDocument.self, LedgerAnchor.self, LedgerClaim.self,
        LedgerEdge.self, LedgerArchive.self, SourceTranscript.self, Tab.self
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let context = ModelContext(container)
    let ledger = LedgerStore(modelContext: context)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("Phase7Tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (container, context, ledger, DocumentStore(modelContext: context, ledgerStore: ledger, containerOverride: root), root)
}

@MainActor
struct ReportImportTests {


    private let reportText = """
    # Fermentation Deep Dive

    The strongest evidence is [the gut study](https://a.example/paper?utm_source=chat).

    Also see the overview video [at the key moment](https://youtube.com/watch?v=abc&t=417).

    Sources:
    https://c.example/uncited-footnote
    """

    @Test func importBuildsTheWholeBundle() async throws {
        let (_, context, ledger, documents, _) = try makeStores()
        let workspace = Workspace(name: "Fermentation"); context.insert(workspace)

        let summary = try #require(await ResearchReportImporter.importReport(
            text: reportText, titleOverride: nil,
            workspace: workspace, ledgerStore: ledger, documentStore: documents))

        #expect(summary.documentName == "Fermentation Deep Dive")
        #expect(summary.citedSources == 3)
        #expect(summary.linkedEdges == 2, "only Markdown links carry edges")

        // The report is a source: hash-keyed, .importBundle.
        let reportRef = ledger.references(workspaceId: workspace.id)
            .first { $0.sourceKey.hasPrefix("hash:") }
        let report = try #require(reportRef)
        #expect(report.method == .importBundle)

        // Every citation: source + .importBundle ref + lineage to the report.
        let paperRef = try #require(ledger.reference(workspaceId: workspace.id, sourceKey: "https://a.example/paper"))
        #expect(paperRef.method == .importBundle)
        #expect(paperRef.openedFromSourceId == report.sourceId, "the fan's spine")
        let bareRef = try #require(ledger.reference(workspaceId: workspace.id, sourceKey: "https://c.example/uncited-footnote"))
        #expect(bareRef.openedFromSourceId == report.sourceId)

        // One ordinary Phase 2 save repaired the file: ^id markers on disk.
        let row = try #require(documents.document(id: summary.documentId))
        let onDisk = try String(contentsOf: #require(documents.url(for: row)), encoding: .utf8)
        let edges = ledger.edges(documentId: summary.documentId)
        #expect(edges.count == 2)
        for edge in edges {
            let anchor = try #require(ledger.anchor(id: edge.anchorId))
            #expect(onDisk.contains(AnchorLink.idToken(for: anchor.id)), "title repair stamped the marker")
        }
        #expect(edges.contains { $0.rangeQuote == "the gut study" })
        #expect(edges.contains { $0.rangeQuote == "at the key moment" })

        // The video citation kept its timestamp as a locator, not a second source.
        let videoAnchor = ledger.anchors(sourceKey: "https://youtube.com/watch?v=abc").first
        #expect(videoAnchor?.locator == "t=417")

        // Provenance: the audit view's fan falls straight out of the lineage.
        let inputs = ledger.references(workspaceId: workspace.id).map {
            AuditModel.SourceInput(sourceId: $0.sourceId, sourceKey: $0.sourceKey, title: "",
                                   url: nil, disposition: $0.disposition,
                                   openedFromSourceId: $0.openedFromSourceId)
        }
        let groups = AuditModel.upstreamGroups(for: inputs)
        let citedIds = [paperRef.sourceId, bareRef.sourceId]
        #expect(citedIds.allSatisfy { groups[$0] != nil && groups[$0] == groups[citedIds[0]] },
                "every citation joins one fan rooted at the report")
    }

    @Test func reimportingTheSameReportIsTheSameSource() async throws {
        let (_, context, ledger, documents, _) = try makeStores()
        let workspace = Workspace(name: "W"); context.insert(workspace)
        let first = try #require(await ResearchReportImporter.importReport(
            text: reportText, titleOverride: nil,
            workspace: workspace, ledgerStore: ledger, documentStore: documents))
        let second = try #require(await ResearchReportImporter.importReport(
            text: reportText, titleOverride: nil,
            workspace: workspace, ledgerStore: ledger, documentStore: documents))

        let hashRefs = ledger.references(workspaceId: workspace.id).filter { $0.sourceKey.hasPrefix("hash:") }
        #expect(hashRefs.count == 1, "same bytes, same report source")
        #expect(ledger.reference(workspaceId: workspace.id, sourceKey: "https://a.example/paper") != nil)
        #expect(second.documentName == "Fermentation Deep Dive 2", "the document collides politely")
        #expect(first.documentId != second.documentId)
    }

    @Test func emptyPasteImportsNothing() async throws {
        let (_, context, ledger, documents, _) = try makeStores()
        let workspace = Workspace(name: "W"); context.insert(workspace)
        let summary = await ResearchReportImporter.importReport(
            text: "   \n  ", titleOverride: nil,
            workspace: workspace, ledgerStore: ledger, documentStore: documents)
        #expect(summary == nil)
        #expect(ledger.references(workspaceId: workspace.id).isEmpty)
    }
}

/// The outbound half (ResearchHandoff.swift): an external agent reads the
/// workspace, then hands the finished report back through the same importer.
@MainActor
struct ResearchHandoffTests {

    private func wire(_ ledger: LedgerStore, _ documents: DocumentStore) {
        ResearchRecall.shared.ledgerStore = ledger
        ResearchRecall.shared.documentStore = documents
    }

    @Test func briefCarriesNotesKeptSourcesAndRejections() async throws {
        let (_, context, ledger, documents, _) = try makeStores()
        wire(ledger, documents)
        let workspace = Workspace(name: "Fermentation"); context.insert(workspace)

        ledger.recordManualCapture(
            url: URL(string: "https://a.example/paper")!, title: "The Gut Study",
            workspaceId: workspace.id)
        ledger.recordRejection(
            url: URL(string: "https://spam.example/listicle")!, title: "17 Gut Hacks",
            workspaceId: workspace.id)
        let note = try #require(documents.createDocument(in: workspace, name: "Question"))
        documents.append(line: "Does fermentation change gut diversity?", to: note)

        let result = await ResearchHandoff.call(
            "get_workspace_brief",
            arguments: ["workspaceId": workspace.id.uuidString],
            modelContext: context)
        let brief = try #require(result["brief"] as? String)

        #expect(brief.contains("Does fermentation change gut diversity?"), "the note is the question")
        #expect(brief.contains("[The Gut Study](https://a.example/paper)"), "kept sources are citable")
        #expect(brief.contains("do not revisit"))
        #expect(brief.contains("17 Gut Hacks"))
        #expect(!brief.contains("[17 Gut Hacks]"), "a rejection is never offered as a citation")
    }

    @Test func unknownWorkspaceFailsWithSomethingActionable() async throws {
        let (_, context, ledger, documents, _) = try makeStores()
        wire(ledger, documents)
        let result = await ResearchHandoff.call(
            "get_workspace_brief",
            arguments: ["workspaceId": UUID().uuidString],
            modelContext: context)
        #expect((result["error"] as? String)?.contains("list_workspaces") == true)
        #expect(result["brief"] == nil)
    }

    @Test func reportComesBackThroughTheImporter() async throws {
        let (_, context, ledger, documents, _) = try makeStores()
        wire(ledger, documents)
        let workspace = Workspace(name: "Fermentation"); context.insert(workspace)

        let result = await ResearchHandoff.call(
            "import_report",
            arguments: [
                "workspaceId": workspace.id.uuidString,
                "markdown": "# Findings\n\nDiversity rises, per [the gut study](https://a.example/paper).",
            ],
            modelContext: context)

        #expect(result["ok"] as? Bool == true)
        #expect(result["citedSources"] as? Int == 1)
        #expect(result["documentName"] as? String == "Findings")
        // The whole point of the round trip: the citation is a real source in
        // this workspace, not prose.
        let refs = ledger.references(workspaceId: workspace.id)
        #expect(refs.contains { ledger.source(sourceKey: $0.sourceKey)?.url.host == "a.example" })
    }
}
