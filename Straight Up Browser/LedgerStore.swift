//
//  LedgerStore.swift
//  Straight Up Browser
//
//  Every write to the research ledger goes through here, so the two rules stay
//  in one place: capture happens at settle, and closing a tab only ever writes a
//  disposition (docs/phase1-design.md §3, ADR 0007).
//

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

    private func save(_ operation: String) {
        do {
            try modelContext.save()
        } catch {
            PersistenceDiagnostics.shared.report(operation: operation, error: error)
        }
    }
}
