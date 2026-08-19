//
//  Phase2Tests.swift
//  Straight Up BrowserTests
//
//  Thought Flow Phase 2 (docs/phase2-design.md §9): the anchor round trip
//  through the real editor core, file-coordination conflict handling,
//  transcript timestamp search, multi-document workspace behavior, and the
//  widened Split's pane rules (ADR 0008).
//

import Foundation
import SwiftData
import Testing
@testable import Browser

// MARK: - Shared fixture

@MainActor
private func makePhase2Stores() throws -> (ModelContainer, ModelContext, LedgerStore, DocumentStore, URL) {
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
        .appendingPathComponent("Phase2Tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let documents = DocumentStore(modelContext: context, ledgerStore: ledger, containerOverride: root)
    return (container, context, ledger, documents, root)
}

@MainActor
private func makeWorkspace(_ context: ModelContext, name: String = "Fermentation") -> Workspace {
    let workspace = Workspace(name: name)
    context.insert(workspace)
    return workspace
}

@MainActor
private func captureSource(
    _ ledger: LedgerStore, workspaceId: UUID,
    url: String = "https://example.com/study", title: String = "Gut Study"
) -> NewspaperArticle {
    ledger.recordManualCapture(url: URL(string: url)!, title: title, workspaceId: workspaceId)
}

// MARK: - Anchor round trip through the real editor core

@MainActor
struct AnchorRoundTripTests {

    /// Insert → save: the file holds the plain-Markdown link, the edge is
    /// reconciled, and resolution runs on the id-prefix fast path.
    @Test func insertAndSaveWritesFileAndEdge() async throws {
        let (_, context, ledger, documents, _) = try makePhase2Stores()
        let workspace = makeWorkspace(context)
        let article = captureSource(ledger, workspaceId: workspace.id)
        let anchor = ledger.createAnchor(
            source: article, modality: .webPage,
            locator: .textFragment("text=gut%20bacteria"), quote: "gut bacteria finding")
        let row = try #require(documents.createDocument(in: workspace, name: "Draft"))
        let session = documents.session(for: row, workspaceId: workspace.id)
        await session.open()

        let href = AnchorLocator.textFragment("text=gut%20bacteria")
            .url(base: URL(string: article.sourceKey)!, modality: .webPage)
        let link = AnchorLink.markdown(text: "the gut bacteria finding", url: href, anchorId: anchor.id)
        session.editorDidChangeText("# Notes\n\nA claim. \(link)\n")
        await session.saveNow()

        let fileURL = try #require(documents.url(for: row))
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(onDisk.contains(link), "the file holds plain Markdown, unmangled")

        let edges = ledger.edges(documentId: row.id)
        #expect(edges.count == 1)
        #expect(edges.first?.anchorId == anchor.id)
        #expect(edges.first?.rangeQuote == "the gut bacteria finding")
        let start = try #require(edges.first?.rangeStart)
        let length = try #require(edges.first?.rangeLength)
        #expect((onDisk as NSString).substring(with: NSRange(location: start, length: length)) == link,
                "offsets are the fast path and they point at the live link")

        let resolved = session.resolvedLinks
        #expect(resolved.count == 1)
        #expect(resolved.first?.state == .enrichedById)
        await session.close()
    }

    /// External modification (offsets shifted, "^id" title stripped) → reopen:
    /// fallback #2 resolves by URL + locator, the next save repairs the title,
    /// and rangeQuote recovers the edge offsets.
    @Test func externalEditFallsBackAndRepairs() async throws {
        let (_, context, ledger, documents, _) = try makePhase2Stores()
        let workspace = makeWorkspace(context)
        let article = captureSource(ledger, workspaceId: workspace.id)
        let anchor = ledger.createAnchor(
            source: article, modality: .webPage,
            locator: .textFragment("text=gut%20bacteria"), quote: "gut bacteria finding")
        let row = try #require(documents.createDocument(in: workspace, name: "Draft"))
        let href = AnchorLocator.textFragment("text=gut%20bacteria")
            .url(base: URL(string: article.sourceKey)!, modality: .webPage)
        let link = AnchorLink.markdown(text: "the finding", url: href, anchorId: anchor.id)

        do {
            let session = documents.session(for: row, workspaceId: workspace.id)
            await session.open()
            session.editorDidChangeText("Original paragraph. \(link)\n")
            await session.saveNow()
            await session.close()
            documents.closeSession(for: row.id)
        }

        // An external editor inserts a paragraph above AND strips the marker.
        let fileURL = try #require(documents.url(for: row))
        let mangled = "A whole new intro paragraph.\n\n"
            + "Original paragraph. [the finding](\(href.absoluteString))\n"
        try Data(mangled.utf8).write(to: fileURL, options: .atomic)

        let session = documents.session(for: row, workspaceId: workspace.id)
        await session.open()
        #expect(session.resolvedLinks.first?.state == .enrichedByLocator,
                "the stripped marker falls back to URL + locator")
        #expect(session.resolvedLinks.first?.anchorId == anchor.id)

        await session.saveNow()
        let repaired = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(repaired.contains(AnchorLink.idToken(for: anchor.id)), "save repairs the title")
        #expect(session.resolvedLinks.first?.state == .enrichedById, "repair restores the fast path")

        let edges = ledger.edges(documentId: row.id)
        #expect(edges.count == 1)
        let start = try #require(edges.first?.rangeStart)
        #expect(start > 0)
        let length = try #require(edges.first?.rangeLength)
        let inRepaired = (repaired as NSString).substring(with: NSRange(location: start, length: length))
        #expect(inRepaired.hasPrefix("[the finding]"), "offsets recomputed against the repaired text")
        await session.close()
    }

    /// Fallback #3: a link the ledger knows nothing about renders plain,
    /// produces no edge, and the save pass leaves the bytes untouched.
    @Test func unknownLinksStayPlainAndUntouched() async throws {
        let (_, context, _, documents, _) = try makePhase2Stores()
        let workspace = makeWorkspace(context)
        let row = try #require(documents.createDocument(in: workspace, name: "Draft"))
        let session = documents.session(for: row, workspaceId: workspace.id)
        await session.open()
        let text = "See [an ordinary link](https://unrelated.example/page \"a title\") here.\n"
        session.editorDidChangeText(text)
        await session.saveNow()
        #expect(session.resolvedLinks.first?.state == .plain)
        #expect(session.text == text, "the save pass never rewrites what it did not resolve")
        let fileURL = try #require(documents.url(for: row))
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == text)
        await session.close()
    }

    /// Deleting the ledger's anchors degrades the document to plain links —
    /// never an error, never a broken-looking document.
    @Test func deletedLedgerDegradesToPlain() async throws {
        let (_, context, ledger, documents, _) = try makePhase2Stores()
        let workspace = makeWorkspace(context)
        let article = captureSource(ledger, workspaceId: workspace.id)
        let anchor = ledger.createAnchor(
            source: article, modality: .webPage, locator: .wholeSource, quote: "q")
        let row = try #require(documents.createDocument(in: workspace, name: "Draft"))
        let link = AnchorLink.markdown(
            text: "kept text", url: URL(string: article.sourceKey)!, anchorId: anchor.id)

        let session = documents.session(for: row, workspaceId: workspace.id)
        await session.open()
        session.editorDidChangeText(link + "\n")
        await session.saveNow()
        await session.close()
        documents.closeSession(for: row.id)

        context.delete(anchor)
        try context.save()

        let reopened = documents.session(for: row, workspaceId: workspace.id)
        await reopened.open()
        #expect(reopened.resolvedLinks.count == 1)
        #expect(reopened.resolvedLinks.first?.state == .plain)
        await reopened.close()
    }
}

// MARK: - Conflict handling

@MainActor
struct DocumentConflictTests {

    /// Dirty buffer + external change: the disk version becomes a sibling file,
    /// the buffer wins the path, and nothing is lost.
    @Test func dirtyBufferPreservesDiskVersionAsSibling() async throws {
        let (_, context, _, documents, root) = try makePhase2Stores()
        let workspace = makeWorkspace(context)
        let row = try #require(documents.createDocument(in: workspace, name: "Draft"))
        let fileURL = try #require(documents.url(for: row))
        try Data("From the iPad.\n".utf8).write(to: fileURL, options: .atomic)

        #expect(documents.preserveDiskVersionAsSibling(for: row))
        let folder = fileURL.deletingLastPathComponent()
        let siblings = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("conflict") }
        #expect(siblings.count == 1, "the losing version is an ordinary visible file")
        #expect(try String(contentsOf: siblings[0], encoding: .utf8) == "From the iPad.\n")
        _ = root
    }

    /// An empty disk file yields no sibling — there is nothing to preserve.
    @Test func emptyDiskVersionMakesNoSibling() async throws {
        let (_, context, _, documents, _) = try makePhase2Stores()
        let workspace = makeWorkspace(context)
        let row = try #require(documents.createDocument(in: workspace, name: "Draft"))
        #expect(!documents.preserveDiskVersionAsSibling(for: row))
    }

    /// The full dirty-buffer flow through the session: buffer B, disk C →
    /// path holds B, sibling holds C.
    @Test func externalChangeWhileDirtyKeepsBoth() async throws {
        let (_, context, _, documents, _) = try makePhase2Stores()
        let workspace = makeWorkspace(context)
        let row = try #require(documents.createDocument(in: workspace, name: "Draft"))
        let session = documents.session(for: row, workspaceId: workspace.id)
        await session.open()
        session.editorDidChangeText("Typed here, unsaved.\n")

        let fileURL = try #require(documents.url(for: row))
        try Data("Landed from another device.\n".utf8).write(to: fileURL, options: .atomic)

        session.handleExternalChange()
        // The handler hops through a Task; give it a beat, then force the save.
        try await Task.sleep(for: .milliseconds(200))
        await session.saveNow()

        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "Typed here, unsaved.\n",
                "the buffer wins the path")
        let folder = fileURL.deletingLastPathComponent()
        let siblings = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("conflict") }
        #expect(siblings.contains { (try? String(contentsOf: $0, encoding: .utf8)) == "Landed from another device.\n" },
                "the other device's words survive as a sibling")
        await session.close()
    }

    /// Clean buffer + external change: silent reload, no sibling.
    @Test func externalChangeWhileCleanReloads() async throws {
        let (_, context, _, documents, _) = try makePhase2Stores()
        let workspace = makeWorkspace(context)
        let row = try #require(documents.createDocument(in: workspace, name: "Draft"))
        let session = documents.session(for: row, workspaceId: workspace.id)
        await session.open()
        session.editorDidChangeText("First version.\n")
        await session.saveNow()

        let fileURL = try #require(documents.url(for: row))
        try Data("Second version, from elsewhere.\n".utf8).write(to: fileURL, options: .atomic)
        session.handleExternalChange()
        try await Task.sleep(for: .milliseconds(300))

        #expect(session.text == "Second version, from elsewhere.\n", "clean buffers reload silently")
        let folder = fileURL.deletingLastPathComponent()
        let siblings = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("conflict") }
        #expect(siblings.isEmpty)
        await session.close()
    }
}

// MARK: - Transcripts

@MainActor
struct TranscriptTests {

    private let json3 = Data("""
    {"events":[
      {"tStartMs":0,"dDurationMs":2000,"segs":[{"utf8":"Welcome to the show."}]},
      {"tStartMs":417000,"dDurationMs":3000,"segs":[{"utf8":"The gut bacteria "},{"utf8":"finding is robust."}]},
      {"tStartMs":420000,"dDurationMs":1000},
      {"tStartMs":421000,"dDurationMs":500,"segs":[{"utf8":"\\n"}]}
    ]}
    """.utf8)

    @Test func parsesJSON3DroppingEmptyEvents() {
        let segments = TranscriptFetcher.parseJSON3(json3)
        #expect(segments.count == 2)
        #expect(segments[1].t == "The gut bacteria finding is robust.")
        #expect(segments[1].startSeconds == 417)
        #expect(segments[1].endSeconds == 420)
    }

    @Test func timestampSearchFindsTheMomentWithItsTime() throws {
        let (_, context, ledger, _, _) = try makePhase2Stores()
        let workspace = makeWorkspace(context)
        let article = captureSource(
            ledger, workspaceId: workspace.id,
            url: "https://www.youtube.com/watch?v=abc123", title: "Food Science")
        ledger.storeTranscript(
            sourceId: article.id, sourceKey: article.sourceKey,
            languageCode: "en", isAutoGenerated: false,
            segments: TranscriptFetcher.parseJSON3(json3))

        let fetcher = TranscriptFetcher(ledgerStore: ledger)
        let hits = fetcher.search("gut bacteria")
        #expect(hits.count == 1)
        #expect(hits.first?.segment.startSeconds == 417)
        #expect(hits.first?.sourceKey == article.sourceKey)
        #expect(fetcher.search("gu").isEmpty, "two characters is noise, not a query")
        #expect(fetcher.search("absent phrase").isEmpty)
    }

    @Test func refetchReplacesInsteadOfDuplicating() throws {
        let (_, context, ledger, _, _) = try makePhase2Stores()
        let workspace = makeWorkspace(context)
        let article = captureSource(
            ledger, workspaceId: workspace.id, url: "https://youtube.com/watch?v=abc")
        ledger.storeTranscript(sourceId: article.id, sourceKey: article.sourceKey,
                               languageCode: "en", isAutoGenerated: true,
                               segments: [TranscriptSegment(s: 1, d: 1, t: "old")])
        ledger.storeTranscript(sourceId: article.id, sourceKey: article.sourceKey,
                               languageCode: "en", isAutoGenerated: false,
                               segments: [TranscriptSegment(s: 2, d: 1, t: "new")])
        #expect(ledger.allTranscripts().count == 1)
        #expect(ledger.transcript(sourceKey: article.sourceKey)?.segments.first?.t == "new")
        #expect(ledger.transcript(sourceKey: article.sourceKey)?.isAutoGenerated == false)
    }

    @Test func trackChoicePrefersManualThenLanguage() {
        let asrEn = TranscriptFetcher.CaptionTrack(baseUrl: "u1", languageCode: "en", kind: "asr")
        let manualDe = TranscriptFetcher.CaptionTrack(baseUrl: "u2", languageCode: "de", kind: nil)
        let manualEn = TranscriptFetcher.CaptionTrack(baseUrl: "u3", languageCode: "en-US", kind: nil)
        let chosen = TranscriptFetcher.chooseTrack([asrEn, manualDe, manualEn], preferredLanguages: ["en-US"])
        #expect(chosen == manualEn, "manual beats ASR; the user's language beats the video's")
        let asrOnly = TranscriptFetcher.chooseTrack([asrEn], preferredLanguages: ["de"])
        #expect(asrOnly == asrEn, "ASR is better than nothing")
    }

    @Test func json3URLReplacesFormat() throws {
        let track = TranscriptFetcher.CaptionTrack(
            baseUrl: "https://www.youtube.com/api/timedtext?v=abc&fmt=srv3", languageCode: "en", kind: nil)
        let url = try #require(TranscriptFetcher.json3URL(for: track))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.filter { $0.name == "fmt" } == [URLQueryItem(name: "fmt", value: "json3")])
    }
}

// MARK: - Multi-document workspace behavior

@MainActor
struct MultiDocumentTests {

    @Test func namingCollisionsGetSuffixes() throws {
        let (_, context, _, documents, _) = try makePhase2Stores()
        let workspace = makeWorkspace(context)
        let first = try #require(documents.createDocument(in: workspace))
        let second = try #require(documents.createDocument(in: workspace))
        #expect(first.displayName == "Untitled")
        #expect(second.displayName == "Untitled 2")
        #expect(first.relativePath != second.relativePath)
    }

    @Test func currentDocumentIsTheMostRecentlyOpened() throws {
        let (_, context, _, documents, _) = try makePhase2Stores()
        let workspace = makeWorkspace(context)
        let notes = try #require(documents.createDocument(in: workspace, name: "Notes"))
        let draft = try #require(documents.createDocument(in: workspace, name: "Draft"))
        notes.lastOpenedAt = Date(timeIntervalSinceNow: -100)
        draft.lastOpenedAt = Date()
        #expect(documents.currentDocument(workspaceId: workspace.id)?.id == draft.id)
        draft.lastOpenedAt = Date(timeIntervalSinceNow: -200)
        #expect(documents.currentDocument(workspaceId: workspace.id)?.id == notes.id)
    }

    /// The anchor path with no open editor: coordinated append to the raw file.
    @Test func appendReachesClosedDocuments() throws {
        let (_, context, _, documents, _) = try makePhase2Stores()
        let workspace = makeWorkspace(context)
        let row = try #require(documents.createDocument(in: workspace, name: "Notes"))
        let fileURL = try #require(documents.url(for: row))
        try Data("Existing text without trailing newline".utf8).write(to: fileURL, options: .atomic)
        documents.append(line: "- [a link](https://x.example)", to: row)
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(contents == "Existing text without trailing newline\n- [a link](https://x.example)\n")
    }

    /// The anchor path with an open editor: the append lands in the buffer, so
    /// screen and disk agree.
    @Test func appendReachesOpenBuffers() async throws {
        let (_, context, _, documents, _) = try makePhase2Stores()
        let workspace = makeWorkspace(context)
        let row = try #require(documents.createDocument(in: workspace, name: "Notes"))
        let session = documents.session(for: row, workspaceId: workspace.id)
        await session.open()
        session.editorDidChangeText("Typing along")
        documents.append(line: "- appended", to: row)
        #expect(session.text == "Typing along\n- appended\n")
        await session.saveNow()
        let fileURL = try #require(documents.url(for: row))
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "Typing along\n- appended\n")
        await session.close()
    }

    @Test func deleteRemovesEdgesButNeverAnchors() async throws {
        let (_, context, ledger, documents, _) = try makePhase2Stores()
        let workspace = makeWorkspace(context)
        let article = captureSource(ledger, workspaceId: workspace.id)
        let anchor = ledger.createAnchor(source: article, modality: .webPage, locator: .wholeSource, quote: "q")
        let row = try #require(documents.createDocument(in: workspace, name: "Draft"))
        ledger.recordEdge(documentId: row.id, anchorId: anchor.id, quote: "q")
        let fileURL = try #require(documents.url(for: row))

        documents.deleteDocument(row)
        #expect(ledger.edges(documentId: row.id).isEmpty, "edges go with the document")
        #expect(ledger.anchor(id: anchor.id) != nil, "anchors belong to sources and stay")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func renameMovesTheFileAndUpdatesThePath() throws {
        let (_, context, _, documents, _) = try makePhase2Stores()
        let workspace = makeWorkspace(context)
        let row = try #require(documents.createDocument(in: workspace, name: "Notes"))
        let oldURL = try #require(documents.url(for: row))
        try Data("content".utf8).write(to: oldURL, options: .atomic)
        #expect(documents.renameDocument(row, to: "Script Draft"))
        #expect(row.displayName == "Script Draft")
        let newURL = try #require(documents.url(for: row))
        #expect(newURL.lastPathComponent == "Script Draft.md")
        #expect(try String(contentsOf: newURL, encoding: .utf8) == "content")
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
    }

    /// Folder names freeze at first creation, like Workspace.sectionName.
    @Test func workspaceRenameDoesNotMoveTheFolder() throws {
        let (_, context, _, documents, root) = try makePhase2Stores()
        let workspace = makeWorkspace(context, name: "Fermentation")
        let row = try #require(documents.createDocument(in: workspace, name: "Notes"))
        workspace.name = "Fermentation Renamed"
        let second = try #require(documents.createDocument(in: workspace, name: "Draft"))
        #expect(row.relativePath.hasPrefix("Fermentation/"))
        #expect(second.relativePath.hasPrefix("Fermentation/"), "the folder froze at first creation")
        _ = root
    }
}

// MARK: - Pane rules (ADR 0008)

@MainActor
struct DocumentPaneRuleTests {

    private func makeManager() -> (TabManager, UUID) {
        let manager = TabManager()
        let documentId = UUID()
        manager.isDocumentPaneId = { $0 == documentId }
        return (manager, documentId)
    }

    @Test func selectingADocumentDissolvesForeignSplits() {
        let (manager, documentId) = makeManager()
        manager.splitTabIds = [UUID(), UUID()]
        manager.selectDocument(documentId)
        #expect(manager.splitTabIds.isEmpty)
        #expect(manager.focusedDocumentId == documentId)
    }

    @Test func selectingATabTakesFocusBack() {
        let (manager, documentId) = makeManager()
        manager.selectDocument(documentId)
        manager.selectedTabId = UUID()
        #expect(manager.focusedDocumentId == nil, "selectedTabId stays tabs-only; tabs win focus back")
    }

    @Test func documentSplitMembershipTogglesLikeTabs() {
        let (manager, documentId) = makeManager()
        let tabId = UUID()
        manager.selectedTabId = tabId
        manager.toggleDocumentSplitMembership(documentId)
        #expect(manager.splitTabIds == [tabId, documentId])
        #expect(manager.focusedDocumentId == documentId)
        manager.toggleDocumentSplitMembership(documentId)
        #expect(manager.splitTabIds.isEmpty)
        #expect(manager.focusedDocumentId == nil)
        #expect(manager.selectedTabId == tabId)
    }

    @Test func closingTheDocumentPaneNeverTouchesTabs() {
        let (manager, documentId) = makeManager()
        let tabId = UUID()
        manager.selectedTabId = tabId
        manager.toggleDocumentSplitMembership(documentId)
        manager.closeDocumentPane(documentId)
        #expect(manager.focusedDocumentId == nil)
        #expect(manager.splitTabIds.isEmpty)
        #expect(manager.selectedTabId == tabId)
    }

    @Test func documentSuccessorNeverLandsInSelectedTabId() {
        let (manager, documentId) = makeManager()
        let tabId = UUID()
        manager.selectedTabId = tabId
        manager.splitTabIds = [tabId, documentId]
        // Simulate the focused tab pane going away.
        manager.selectedTabId = nil
        manager.splitTabIds = [documentId]
        #expect(manager.selectedTabId != documentId, "a document id must never become selectedTabId")
    }

    @Test func workspaceSwitchDropsDocumentFocus() {
        let (manager, documentId) = makeManager()
        manager.activeWorkspaceId = UUID()
        manager.selectDocument(documentId)
        manager.suspendWorkspace()
        #expect(manager.focusedDocumentId == nil)
    }
}

// MARK: - Pure helpers

struct AnchorComposerHelperTests {

    @Test func shortSelectionsBecomeWholeFragments() {
        let directive = AnchorComposer.textFragmentDirective(for: "gut  bacteria\nfinding")
        #expect(directive == "text=" + "gut bacteria finding"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)
    }

    @Test func longSelectionsBecomeStartEndPairs() {
        let words = (1...60).map { "word\($0)" }.joined(separator: " ")
        let directive = AnchorComposer.textFragmentDirective(for: words)
        #expect(directive.contains(","), "long selections anchor by start,end")
        #expect(directive.hasPrefix("text="))
    }

    @Test func linkTextTrimsAtWordBoundaries() {
        let long = Array(repeating: "sesquipedalian", count: 20).joined(separator: " ")
        let text = AnchorComposer.linkText(selection: long, title: "T", locator: .wholeSource)
        #expect(text.count <= 121)
        #expect(text.hasSuffix("…"))
        #expect(!text.dropLast().hasSuffix("sesquipedalia"), "cut lands on a word boundary")
    }

    @Test func titlesCarryTimestamps() {
        let text = AnchorComposer.linkText(
            selection: nil, title: "Food Video", locator: .timestamp(start: 3725, end: nil))
        #expect(text.contains("1:02:05"))
        #expect(AnchorComposer.formatTimestamp(417) == "6:57")
    }
}

struct MarkdownStylingTests {

    @Test func headingsEmphasisAndFencesGetSpans() {
        let text = "# Title\n\nSome **bold** and `code`.\n```\nlet x = 1\n```\n"
        let spans = MarkdownStyling.spans(for: text)
        #expect(spans.contains { $0.kind == .heading(1) })
        #expect(spans.contains { $0.kind == .bold })
        #expect(spans.contains { $0.kind == .inlineCode })
        #expect(spans.contains { $0.kind == .codeBlock })
        // The fence interior is one codeBlock line, not styled as Markdown.
        let codeSpan = spans.first { $0.kind == .codeBlock }!
        #expect((text as NSString).substring(with: codeSpan.range) == "let x = 1")
    }

    @Test func linksSplitIntoTextAndMarks() {
        let text = "See [the finding](https://x.example \"^abcd1234\") now."
        let spans = MarkdownStyling.spans(for: text)
        let linkText = spans.first { $0.kind == .linkText }
        #expect(linkText != nil)
        #expect((text as NSString).substring(with: linkText!.range) == "the finding")
    }

    @Test func parseAllMatchesReportsAccurateRanges() {
        let text = "pad [t](https://a.example \"^ff00ff00\") tail"
        let match = AnchorLink.parseAllMatches(in: text).first
        #expect(match != nil)
        #expect((text as NSString).substring(with: match!.range) == "[t](https://a.example \"^ff00ff00\")")
        #expect((text as NSString).substring(with: match!.textRange) == "t")
        #expect(match!.parsed.idPrefix == "ff00ff00")
    }
}
