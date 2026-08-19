//
//  LedgerMigrator.swift
//  Straight Up Browser
//
//  Data migrations for the research ledger, run as idempotent version-gated
//  passes at container creation — the same hook and the same shape as
//  NewspaperStore.reconcileInterruptedWork().
//
//  Deliberately NOT a SwiftData SchemaMigrationPlan: CloudKit-backed stores do
//  not run custom migration stages reliably, and the CloudKit attribute rules
//  already force every model change to be lightweight-compatible. Model SHAPE
//  changes are handled by those rules (add columns, never rename or retype,
//  every attribute optional or defaulted, enums as raw strings with a fallback).
//  This type only handles DATA shape.
//
//  Every step must be idempotent: the version is per-device, so a multi-device
//  user runs each pass once per device, and a device that has not launched in a
//  while can sync down already-migrated rows before running its own pass.
//

import Foundation
import SwiftData

@MainActor
struct LedgerMigrator {
    static let currentVersion = 2
    static let versionKey = "ledgerSchemaVersion"

    private let modelContext: ModelContext
    private let defaults: UserDefaults

    init(modelContext: ModelContext, defaults: UserDefaults = .standard) {
        self.modelContext = modelContext
        self.defaults = defaults
    }

    nonisolated struct Report: Equatable, Sendable {
        var importedWorkspaces = 0
        var rekeyedSources = 0
        var mergedDuplicates = 0

        var total: Int { importedWorkspaces + rekeyedSources + mergedDuplicates }
    }

    @discardableResult
    func migrateIfNeeded() -> Report {
        var report = Report()
        let from = defaults.integer(forKey: Self.versionKey)
        guard from < Self.currentVersion else { return report }

        if from < 1 { report.importedWorkspaces = importSavedWorkspaces() }
        if from < 2 {
            let rekey = rekeySources()
            report.rekeyedSources = rekey.rekeyed
            report.mergedDuplicates = rekey.merged
        }

        defaults.set(Self.currentVersion, forKey: Self.versionKey)
        if report.total > 0 {
            Logger.log(
                "Ledger migration: \(report.importedWorkspaces) workspaces, \(report.rekeyedSources) re-keyed, \(report.mergedDuplicates) merged",
                type: "LedgerMigrator"
            )
        }
        return report
    }

    // MARK: Step 1 — the old UserDefaults workspace snapshots

    /// The previous mechanism stored named tab snapshots as JSON in UserDefaults
    /// and replaced every open tab on load. Convert each into a real Workspace.
    /// The saved tabs become that workspace's tabs; nothing is destroyed.
    private func importSavedWorkspaces() -> Int {
        guard let data = defaults.data(forKey: "saved_workspaces"),
              let saved = try? JSONDecoder().decode([LegacySavedWorkspace].self, from: data),
              !saved.isEmpty
        else { return 0 }

        let existing = (try? modelContext.fetch(FetchDescriptor<Workspace>())) ?? []
        var imported = 0
        for (index, legacy) in saved.enumerated() {
            // Idempotent: an id already present means this ran before.
            let legacyId = legacy.id
            if existing.contains(where: { $0.id == legacyId }) { continue }
            let workspace = Workspace(name: legacy.name, orderIndex: index)
            workspace.id = legacy.id
            workspace.createdAt = legacy.createdAt
            modelContext.insert(workspace)

            for savedTab in legacy.tabs {
                guard let urlString = savedTab.urlString, let url = URL(string: urlString) else { continue }
                let tab = Tab(title: savedTab.title, url: url, isActive: false)
                tab.id = savedTab.id
                tab.isPinned = savedTab.isPinned
                tab.orderIndex = savedTab.orderIndex
                tab.workspaceId = workspace.id
                modelContext.insert(tab)
            }
            imported += 1
        }
        if imported > 0 {
            try? modelContext.save()
            // Keep the old blob: it is small, and it is the only copy if this
            // import turns out to have been wrong.
            defaults.set(data, forKey: "saved_workspaces_migrated_backup")
            defaults.removeObject(forKey: "saved_workspaces")
        }
        return imported
    }

    private struct LegacySavedWorkspace: Decodable {
        let id: UUID
        let name: String
        let createdAt: Date
        let tabs: [LegacySavedTab]
    }

    private struct LegacySavedTab: Decodable {
        let id: UUID
        let title: String
        let urlString: String?
        let isPinned: Bool
        let orderIndex: Int
    }

    // MARK: Step 2 — re-key sources onto the canonical identity

    /// Canonicalization changed (tracking params, YouTube timestamps, arXiv,
    /// DOI), so every existing Saved Article needs its sourceKey recomputed.
    /// Where two rows collapse onto one key, the richer one wins and absorbs the
    /// other. Irreversible, which is why the merge rule is explicit.
    private func rekeySources() -> (rekeyed: Int, merged: Int) {
        guard let articles = try? modelContext.fetch(FetchDescriptor<NewspaperArticle>()),
              !articles.isEmpty
        else { return (0, 0) }

        var rekeyed = 0
        var byKey: [String: [NewspaperArticle]] = [:]
        for article in articles {
            let key = SourceCanonicalizer.canonicalKey(for: article.url)
            if article.sourceKey != key {
                article.sourceKey = key
                rekeyed += 1
            }
            byKey[key, default: []].append(article)
        }

        var merged = 0
        for (key, group) in byKey where group.count > 1 {
            let ordered = group.sorted(by: Self.winsMerge)
            let winner = ordered[0]
            for loser in ordered.dropFirst() {
                absorb(loser, into: winner)
                repointReferences(from: loser.id, to: winner.id, sourceKey: key)
                modelContext.delete(loser)
                merged += 1
            }
        }
        if rekeyed > 0 || merged > 0 { try? modelContext.save() }
        return (rekeyed, merged)
    }

    /// Has extracted text, then higher rating, then EARLIEST addedAt — so the
    /// original filing and Section survive the merge.
    static func winsMerge(_ a: NewspaperArticle, _ b: NewspaperArticle) -> Bool {
        let aHasText = a.originalPayloadData != nil
        let bHasText = b.originalPayloadData != nil
        if aHasText != bHasText { return aHasText }
        if a.rating != b.rating { return a.rating > b.rating }
        return a.addedAt < b.addedAt
    }

    private func absorb(_ loser: NewspaperArticle, into winner: NewspaperArticle) {
        if winner.originalPayloadData == nil, let data = loser.originalPayloadData {
            winner.originalPayloadData = data
            winner.sourceDigest = loser.sourceDigest
            winner.sourceWordCount = loser.sourceWordCount
            winner.sourceCharacterCount = loser.sourceCharacterCount
            winner.captureState = loser.captureState
        }
        if winner.byline == nil { winner.byline = loser.byline }
        if winner.publication == nil { winner.publication = loser.publication }
        if winner.leadImageURL == nil { winner.leadImageURL = loser.leadImageURL }
        if winner.firstWorkspaceId == nil { winner.firstWorkspaceId = loser.firstWorkspaceId }
        winner.rating = max(winner.rating, loser.rating)
        winner.readingProgress = max(winner.readingProgress, loser.readingProgress)
        winner.isRead = winner.isRead || loser.isRead
        winner.finishedAt = Self.latest(winner.finishedAt, loser.finishedAt)
        winner.lastReadAt = Self.latest(winner.lastReadAt, loser.lastReadAt)
        winner.updatedAt = Date()
    }

    static func latest(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): return max(a, b)
        default: return a ?? b
        }
    }

    /// Nothing references sources on the first run; this matters on any later
    /// re-key pass, once the ledger has content.
    private func repointReferences(from loserId: UUID, to winnerId: UUID, sourceKey: String) {
        let refs = (try? modelContext.fetch(FetchDescriptor<WorkspaceSourceRef>(
            predicate: #Predicate { $0.sourceId == loserId }
        ))) ?? []
        for ref in refs {
            ref.sourceId = winnerId
            ref.sourceKey = sourceKey
        }
        let anchors = (try? modelContext.fetch(FetchDescriptor<LedgerAnchor>(
            predicate: #Predicate { $0.sourceId == loserId }
        ))) ?? []
        for anchor in anchors {
            anchor.sourceId = winnerId
            anchor.sourceKey = sourceKey
        }
    }
}
