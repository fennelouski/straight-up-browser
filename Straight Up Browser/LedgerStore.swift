//
//  LedgerStore.swift
//  Straight Up Browser
//
//  Every write to the research ledger goes through here, so the two rules stay
//  in one place: capture happens at settle, and closing a tab only ever writes a
//  disposition (docs/phase1-design.md §3, ADR 0007).
//

import CryptoKit
import Foundation
import SwiftData

@MainActor
final class LedgerStore {
    private let modelContext: ModelContext
    private let newspaper: NewspaperStore

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        newspaper = NewspaperStore(modelContext: modelContext)
    }

    // MARK: Lookups

    func workspace(id: UUID) -> Workspace? {
        var descriptor = FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    func reference(workspaceId: UUID, sourceKey: String) -> WorkspaceSourceRef? {
        var descriptor = FetchDescriptor<WorkspaceSourceRef>(
            predicate: #Predicate { $0.workspaceId == workspaceId && $0.sourceKey == sourceKey }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    func references(sourceKey: String) -> [WorkspaceSourceRef] {
        (try? modelContext.fetch(FetchDescriptor<WorkspaceSourceRef>(
            predicate: #Predicate { $0.sourceKey == sourceKey }
        ))) ?? []
    }

    func references(workspaceId: UUID) -> [WorkspaceSourceRef] {
        (try? modelContext.fetch(FetchDescriptor<WorkspaceSourceRef>(
            predicate: #Predicate { $0.workspaceId == workspaceId }
        ))) ?? []
    }

    /// Everything the seen-before surfaces need, in one fetch keyed on the
    /// canonical URL. Runs on every navigation, so it stays cheap.
    nonisolated struct PriorEncounter: Equatable, Sendable {
        let workspaceName: String
        let disposition: SourceDisposition
        let addedAt: Date
        let rating: Int
    }

    func priorEncounters(for url: URL) -> [PriorEncounter] {
        let key = SourceCanonicalizer.canonicalKey(for: url)
        let refs = references(sourceKey: key)
        guard !refs.isEmpty else { return [] }
        let rating = source(sourceKey: key)?.rating ?? 0
        return refs.compactMap { ref in
            guard let name = workspace(id: ref.workspaceId)?.name else { return nil }
            return PriorEncounter(
                workspaceName: name,
                disposition: ref.disposition,
                addedAt: ref.addedAt,
                rating: rating
            )
        }
        .sorted { $0.addedAt > $1.addedAt }
    }

    func source(sourceKey: String) -> NewspaperArticle? {
        var descriptor = FetchDescriptor<NewspaperArticle>(
            predicate: #Predicate { $0.sourceKey == sourceKey }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: Capture

    /// True when settle-capture should do nothing at all: a reference already
    /// exists and the source is fully captured. This is the common case on any
    /// revisit, and it costs one indexed fetch.
    func isFullyCaptured(workspaceId: UUID, url: URL) -> Bool {
        let key = SourceCanonicalizer.canonicalKey(for: url)
        guard let ref = reference(workspaceId: workspaceId, sourceKey: key),
              ref.disposition == .open,
              let source = source(sourceKey: key)
        else { return false }
        return source.captureState == .ready
    }

    /// The page settled: it loaded and the user stayed with it. Writes the
    /// reference and a source row at minimum; the caller performs the
    /// opportunistic extraction and archive on top.
    ///
    /// Returns the article so the caller can hand it to the capture coordinator,
    /// or nil when nothing needs doing.
    @discardableResult
    func recordSettle(
        url: URL,
        title: String,
        workspaceId: UUID,
        openedFromSourceId: UUID? = nil
    ) -> NewspaperArticle? {
        guard !isFullyCaptured(workspaceId: workspaceId, url: url) else { return nil }
        let article = enqueueSource(url: url, title: title, workspaceId: workspaceId)
        upsertReference(
            workspaceId: workspaceId,
            article: article,
            method: .settle,
            disposition: .open,
            openedFromSourceId: openedFromSourceId
        )
        save("Record settled source")
        return article
    }

    /// Deliberate one-keystroke capture, and the per-tab write that workspace
    /// promotion performs.
    @discardableResult
    func recordManualCapture(
        url: URL,
        title: String,
        workspaceId: UUID,
        openedFromSourceId: UUID? = nil
    ) -> NewspaperArticle {
        let article = enqueueSource(url: url, title: title, workspaceId: workspaceId)
        upsertReference(
            workspaceId: workspaceId,
            article: article,
            method: .manual,
            disposition: .open,
            openedFromSourceId: openedFromSourceId
        )
        save("Record manual capture")
        return article
    }

    // MARK: Share-sheet capture (Phase 3)

    /// A URL shared in from another app (docs/phase3-design.md §4). Same writes
    /// as any capture — enqueue + reference — with the method that says a share
    /// sheet chose it. No text extraction here (no web view at drain); the
    /// article stays `deferred` and fills in when the source is next opened.
    @discardableResult
    func recordShareCapture(url: URL, title: String, workspaceId: UUID) -> NewspaperArticle {
        let article = enqueueSource(url: url, title: title, workspaceId: workspaceId)
        upsertReference(
            workspaceId: workspaceId,
            article: article,
            method: .shareSheet,
            disposition: .open
        )
        save("Record shared source")
        return article
    }

    /// A file/image shared in: bytes become a permanent import, identity is the
    /// content hash (`NewspaperArticle.contentHash`, the Phase 1 column built
    /// for exactly this), so the same bytes shared twice are one source.
    @discardableResult
    func recordFileImport(
        data: Data,
        suggestedName: String,
        workspaceId: UUID,
        importsDirectory: URL,
        method: SourceCaptureMethod = .shareSheet
    ) -> NewspaperArticle? {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let sourceKey = "hash:" + hash
        let cleanedName = suggestedName.isEmpty ? "Import" : suggestedName
        if let existing = source(sourceKey: sourceKey) {
            upsertReference(workspaceId: workspaceId, article: existing, method: method, disposition: .open)
            save("Record shared file")
            return existing
        }
        let ext = (cleanedName as NSString).pathExtension
        let fileURL = importsDirectory.appendingPathComponent(hash + (ext.isEmpty ? "" : "." + ext))
        do {
            try FileManager.default.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return nil
        }
        let article = enqueueSource(url: fileURL, title: cleanedName, workspaceId: workspaceId)
        // Content identity, not path identity: re-key onto the hash so the same
        // bytes from any path collapse to one source.
        article.sourceKey = sourceKey
        article.contentHash = hash
        switch ext.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "avif": article.modality = .image
        case "pdf": article.modality = .pdf
        default: article.modality = .importedFile
        }
        upsertReference(workspaceId: workspaceId, article: article, method: method, disposition: .open)
        save("Record shared file")
        return article
    }

    /// Phase 7: a citation inside an imported deep-research report. Same
    /// writes as any capture, with the .importBundle method Phase 1 reserved
    /// and lineage back to the report — which is what makes the audit view's
    /// Shared Upstream mode render the bundle as one fan.
    @discardableResult
    func recordBundleSource(
        url: URL,
        title: String,
        workspaceId: UUID,
        openedFromSourceId: UUID?
    ) -> NewspaperArticle {
        let article = enqueueSource(url: url, title: title, workspaceId: workspaceId)
        upsertReference(
            workspaceId: workspaceId,
            article: article,
            method: .importBundle,
            disposition: .open,
            openedFromSourceId: openedFromSourceId
        )
        save("Record bundle source")
        return article
    }

    /// "Items movable afterward": re-point the join row. Disposition and method
    /// travel with it; the Newspaper section does NOT re-file (the freeze rule)
    /// and `firstWorkspaceId` is history, not location. Moving onto a workspace
    /// that already references the source merges into the existing row.
    func moveReference(_ ref: WorkspaceSourceRef, to workspaceId: UUID) {
        guard ref.workspaceId != workspaceId else { return }
        if reference(workspaceId: workspaceId, sourceKey: ref.sourceKey) != nil {
            modelContext.delete(ref)
        } else {
            ref.workspaceId = workspaceId
            ref.updatedAt = Date()
        }
        save("Move workspace reference")
    }

    // MARK: Rejection

    /// The user closed a tab in a workspace. This writes a disposition and
    /// NOTHING else — no extraction, no archive, no web view retained.
    ///
    /// With a 20-second dwell most rejections happen before the page ever
    /// settled, so this creates the source row itself when there isn't one. That
    /// is still only a disposition write: one insert, no capture work. It is
    /// what lets seen-before say "you rejected this in March".
    func recordRejection(url: URL?, title: String, workspaceId: UUID) {
        // A blank tab has no source. This is what exempts the housekeeping
        // callers that close url == nil tabs.
        guard let url, !url.absoluteString.isEmpty else { return }
        let article = enqueueSource(url: url, title: title, workspaceId: workspaceId)
        upsertReference(
            workspaceId: workspaceId,
            article: article,
            method: .rejectedOnClose,
            disposition: .dismissed
        )
        save("Record rejected source")
    }

    /// The ref's disposition before a close, captured into the closed-tab
    /// snapshot so undo can restore it. Nil = no ref exists yet (the close will
    /// create one).
    func priorDisposition(url: URL, workspaceId: UUID) -> SourceDisposition? {
        reference(workspaceId: workspaceId, sourceKey: SourceCanonicalizer.canonicalKey(for: url))?.disposition
    }

    /// Undo of an accidental tab close: un-write the `dismissed` the close
    /// wrote. A ref the close created is deleted outright; a ref that predated
    /// it returns to its prior disposition. Only a ref still `dismissed` is
    /// touched — if anything (a re-settle, another device) already moved it on,
    /// the newer verdict wins.
    func undoRejection(url: URL?, workspaceId: UUID, priorDispositionRaw: String?) {
        guard let url, !url.absoluteString.isEmpty else { return }
        let key = SourceCanonicalizer.canonicalKey(for: url)
        guard let ref = reference(workspaceId: workspaceId, sourceKey: key),
              ref.disposition == .dismissed else { return }
        if let raw = priorDispositionRaw, let prior = SourceDisposition(rawValue: raw) {
            ref.disposition = prior
            ref.updatedAt = Date()
        } else {
            modelContext.delete(ref)
        }
        save("Undo rejected source")
    }

    // MARK: Completion

    /// Archiving a workspace sweeps every remaining `open` reference to `kept`.
    /// `dismissed` rows are never touched — a rejection survives archiving,
    /// which is the point of keeping the distinction.
    ///
    /// Idempotent: a second run finds no `open` rows and writes nothing, which
    /// matters because it can run again on another device after sync.
    @discardableResult
    func archiveWorkspace(_ workspace: Workspace) -> Int {
        var swept = 0
        for ref in references(workspaceId: workspace.id) where ref.disposition == .open {
            ref.disposition = .kept
            ref.updatedAt = Date()
            swept += 1
        }
        if !workspace.isArchived {
            workspace.isArchived = true
        }
        save("Archive workspace")
        return swept
    }

    func unarchiveWorkspace(_ workspace: Workspace) {
        workspace.isArchived = false
        workspace.lastActiveAt = Date()
        save("Reopen workspace")
    }

    // MARK: Shared writes

    private func enqueueSource(url: URL, title: String, workspaceId: UUID) -> NewspaperArticle {
        let result = newspaper.enqueue(
            url: url,
            title: title,
            section: workspace(id: workspaceId)?.sectionName
        )
        let article = result.article
        if article.firstWorkspaceId == nil {
            // First workspace wins the Section; later ones only add a reference.
            article.firstWorkspaceId = workspaceId
        }
        if article.modalityRaw.isEmpty {
            article.modalityRaw = SourceModality.inferred(from: url).rawValue
        }
        // A source with no payload yet is deferred, not mid-capture: the capture
        // reconciler must leave it alone rather than flipping it to failed.
        if article.originalPayloadData == nil, article.captureState == .capturing {
            article.captureState = .deferred
        }
        return article
    }

    private func upsertReference(
        workspaceId: UUID,
        article: NewspaperArticle,
        method: SourceCaptureMethod,
        disposition: SourceDisposition,
        openedFromSourceId: UUID? = nil
    ) {
        if let existing = reference(workspaceId: workspaceId, sourceKey: article.sourceKey) {
            // Settling a dismissed or kept source returns it to the working set:
            // deliberately opening it again reverses the earlier verdict.
            existing.disposition = disposition
            existing.updatedAt = Date()
            if existing.openedFromSourceId == nil { existing.openedFromSourceId = openedFromSourceId }
            return
        }
        modelContext.insert(WorkspaceSourceRef(
            workspaceId: workspaceId,
            sourceId: article.id,
            sourceKey: article.sourceKey,
            method: method,
            disposition: disposition,
            openedFromSourceId: openedFromSourceId
        ))
    }

    // MARK: Archives

    func storeArchive(sourceId: UUID, sourceKey: String, data: Data) {
        guard data.count <= WorkspaceCapturePolicy.maximumArchiveBytes else { return }
        modelContext.insert(LedgerArchive(sourceId: sourceId, sourceKey: sourceKey, webArchiveData: data))
        save("Store page archive")
    }

    func totalArchiveBytes() -> Int {
        let archives = (try? modelContext.fetch(FetchDescriptor<LedgerArchive>())) ?? []
        return archives.reduce(0) { $0 + $1.byteCount }
    }

    @discardableResult
    func clearArchives() -> Int {
        let archives = (try? modelContext.fetch(FetchDescriptor<LedgerArchive>())) ?? []
        for archive in archives { modelContext.delete(archive) }
        save("Clear page archives")
        return archives.count
    }

    // MARK: Feed

    /// Sources whose every reference is `dismissed` are excluded from the
    /// Newspaper, so pages rejected inside the settle dwell — most rejections,
    /// at a 20-second dwell — do not litter the reading list.
    func isHiddenFromFeed(_ article: NewspaperArticle) -> Bool {
        let refs = references(sourceKey: article.sourceKey)
        guard !refs.isEmpty else { return false }
        return refs.allSatisfy { $0.disposition == .dismissed }
    }

    func hiddenFromFeedKeys() -> Set<String> {
        let refs = (try? modelContext.fetch(FetchDescriptor<WorkspaceSourceRef>())) ?? []
        var byKey: [String: [SourceDisposition]] = [:]
        for ref in refs { byKey[ref.sourceKey, default: []].append(ref.disposition) }
        return Set(byKey.filter { $0.value.allSatisfy { $0 == .dismissed } }.keys)
    }

    // MARK: Anchors (Phase 2)

    func anchor(id: UUID) -> LedgerAnchor? {
        var descriptor = FetchDescriptor<LedgerAnchor>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Resolution step 1: the "^a1b2c3d4" marker from a document's link title.
    /// ponytail: linear scan over the anchor table; add an indexed prefix column
    /// if anchor counts ever make this visible.
    func anchor(idPrefix: String) -> LedgerAnchor? {
        let anchors = (try? modelContext.fetch(FetchDescriptor<LedgerAnchor>())) ?? []
        return anchors.first { AnchorLink.matches(anchorId: $0.id, idPrefix: idPrefix) }
    }

    func anchors(sourceKey: String) -> [LedgerAnchor] {
        (try? modelContext.fetch(FetchDescriptor<LedgerAnchor>(
            predicate: #Predicate { $0.sourceKey == sourceKey }
        ))) ?? []
    }

    /// Anchor creation reuses an identical existing anchor rather than piling up
    /// duplicates: anchoring the same selection twice is the same anchor.
    @discardableResult
    func createAnchor(
        source: NewspaperArticle,
        modality: SourceModality,
        locator: AnchorLocator,
        quote: String,
        label: String = ""
    ) -> LedgerAnchor {
        let stored = locator.stored
        if let existing = anchors(sourceKey: source.sourceKey)
            .first(where: { $0.locator == stored && $0.quote == quote }) {
            return existing
        }
        let anchor = LedgerAnchor(
            sourceId: source.id,
            sourceKey: source.sourceKey,
            modality: modality,
            locator: stored,
            quote: quote,
            label: label
        )
        modelContext.insert(anchor)
        save("Create anchor")
        return anchor
    }

    // MARK: Edges (Phase 2)

    /// One anchor-link occurrence found in a document's Markdown at save time.
    nonisolated struct EdgeOccurrence: Equatable, Sendable {
        let anchorId: UUID
        let quote: String
        let start: Int
        let length: Int
    }

    func edges(documentId: UUID) -> [LedgerEdge] {
        (try? modelContext.fetch(FetchDescriptor<LedgerEdge>(
            predicate: #Predicate { $0.documentId == documentId }
        ))) ?? []
    }

    /// Declarative: the document's anchor links ARE its edge set. Called on every
    /// save with the links actually present — upserts offsets (`rangeQuote` stays
    /// the truth, offsets are the recomputed fast path) and deletes edges whose
    /// anchor no longer appears. One edge per (document, anchor); a second
    /// occurrence of the same anchor keeps the first occurrence's range.
    func reconcileEdges(documentId: UUID, occurrences: [EdgeOccurrence]) {
        var firstByAnchor: [UUID: EdgeOccurrence] = [:]
        for occurrence in occurrences where firstByAnchor[occurrence.anchorId] == nil {
            firstByAnchor[occurrence.anchorId] = occurrence
        }
        let existing = edges(documentId: documentId)
        for edge in existing {
            if let occurrence = firstByAnchor.removeValue(forKey: edge.anchorId) {
                edge.rangeQuote = occurrence.quote
                edge.rangeStart = occurrence.start
                edge.rangeLength = occurrence.length
            } else {
                modelContext.delete(edge)
            }
        }
        for occurrence in firstByAnchor.values {
            modelContext.insert(LedgerEdge(
                documentId: documentId,
                anchorId: occurrence.anchorId,
                rangeQuote: occurrence.quote,
                rangeStart: occurrence.start,
                rangeLength: occurrence.length
            ))
        }
        save("Reconcile document edges")
    }

    /// One targeted edge write, for the append-to-a-closed-document path where
    /// no save pass will run until the document is next opened. Offsets start at
    /// zero — rangeQuote is the truth, and the next save recomputes them.
    func recordEdge(documentId: UUID, anchorId: UUID, quote: String) {
        if let existing = edges(documentId: documentId).first(where: { $0.anchorId == anchorId }) {
            existing.rangeQuote = quote
        } else {
            modelContext.insert(LedgerEdge(
                documentId: documentId,
                anchorId: anchorId,
                rangeQuote: quote
            ))
        }
        save("Record document edge")
    }

    /// Deleting a document deletes its edges. Anchors are never deleted here —
    /// they belong to sources, and other documents may reference them.
    func deleteEdges(documentId: UUID) {
        for edge in edges(documentId: documentId) { modelContext.delete(edge) }
        save("Delete document edges")
    }

    // MARK: Claims (Phase 6)

    /// Promotion: the only write claim extraction ever performs, and
    /// LedgerClaim's first writer since Phase 1 reserved it. Fetch-then-insert
    /// on normalizedText — the dedup-across-projects key.
    @discardableResult
    func promoteClaim(text: String) -> LedgerClaim {
        let normalized = LedgerClaim.normalize(text)
        var descriptor = FetchDescriptor<LedgerClaim>(
            predicate: #Predicate { $0.normalizedText == normalized }
        )
        descriptor.fetchLimit = 1
        if let existing = try? modelContext.fetch(descriptor).first { return existing }
        let claim = LedgerClaim(text: text)
        modelContext.insert(claim)
        save("Promote claim")
        return claim
    }

    func claimExists(normalizedFrom text: String) -> Bool {
        let normalized = LedgerClaim.normalize(text)
        var descriptor = FetchDescriptor<LedgerClaim>(
            predicate: #Predicate { $0.normalizedText == normalized }
        )
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetch(descriptor).first) ?? nil) != nil
    }

    /// Stamp the claim onto this document's edges whose range starts inside the
    /// claim's paragraph — LedgerEdge.claimId's first writer. An edge already
    /// claimed keeps its earlier claim; stamping is not a merge tool.
    func stampClaim(_ claimId: UUID, documentId: UUID, within range: NSRange) {
        for edge in edges(documentId: documentId)
        where edge.claimId == nil && NSLocationInRange(edge.rangeStart, range) {
            edge.claimId = claimId
        }
        save("Stamp claim onto edges")
    }

    // MARK: Transcripts (Phase 2)

    func transcript(sourceKey: String) -> SourceTranscript? {
        var descriptor = FetchDescriptor<SourceTranscript>(
            predicate: #Predicate { $0.sourceKey == sourceKey }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    @discardableResult
    func storeTranscript(
        sourceId: UUID,
        sourceKey: String,
        languageCode: String,
        isAutoGenerated: Bool,
        segments: [TranscriptSegment]
    ) -> SourceTranscript {
        let data = try? JSONEncoder().encode(segments)
        if let existing = transcript(sourceKey: sourceKey) {
            existing.languageCode = languageCode
            existing.isAutoGenerated = isAutoGenerated
            existing.segmentsData = data
            existing.fetchedAt = Date()
            save("Update transcript")
            return existing
        }
        let transcript = SourceTranscript(
            sourceId: sourceId,
            sourceKey: sourceKey,
            languageCode: languageCode,
            isAutoGenerated: isAutoGenerated,
            segmentsData: data
        )
        modelContext.insert(transcript)
        save("Store transcript")
        return transcript
    }

    func allTranscripts() -> [SourceTranscript] {
        (try? modelContext.fetch(FetchDescriptor<SourceTranscript>())) ?? []
    }

    private func save(_ operation: String) {
        do {
            try modelContext.save()
        } catch {
            PersistenceDiagnostics.shared.report(operation: operation, error: error)
        }
    }
}
