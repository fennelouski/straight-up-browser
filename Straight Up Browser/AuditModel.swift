//
//  AuditModel.swift
//  Straight Up Browser
//
//  The audit view's model (Phase 4, docs/phase4-design.md): a literal rendering
//  of the edge table for one document. Pure value inputs and pure computation —
//  the store-backed assembly lives in AuditView's loader, so every rule here is
//  testable without SwiftData.
//

import Foundation

nonisolated struct AuditModel: Equatable {

    // MARK: Inputs (plain values, mirroring the ledger rows)

    struct EdgeInput: Equatable {
        let id: UUID
        let anchorId: UUID
        let quote: String
        let start: Int
        let length: Int
    }

    struct AnchorInput: Equatable {
        let id: UUID
        let sourceId: UUID
        let sourceKey: String
    }

    struct SourceInput: Equatable {
        let sourceId: UUID
        let sourceKey: String
        let title: String
        let url: URL?
        let disposition: SourceDisposition?
        /// WorkspaceSourceRef.openedFromSourceId — recorded lineage, Phase 1.
        let openedFromSourceId: UUID?
    }

    // MARK: Output

    struct Block: Identifiable, Equatable {
        let id: Int
        let range: NSRange          // UTF-16, into the document text
        let text: String
        let isHeading: Bool
        var edgeIds: [UUID] = []

        var isProse: Bool { !isHeading && !text.isEmpty }
    }

    struct SourceCard: Identifiable, Equatable {
        var id: UUID { sourceId }
        let sourceId: UUID
        let sourceKey: String
        let title: String
        let url: URL?
        let disposition: SourceDisposition?
        /// True when NO edge in ANY of the workspace's documents cites it —
        /// "captured but never cited" is only meaningful workspace-wide.
        let isUnusedInWorkspace: Bool
        /// Non-nil when this source shares a recorded upstream ancestor with at
        /// least one other source; equal numbers = one fan.
        let upstreamGroup: Int?
        var edgeIds: [UUID] = []
    }

    struct Connection: Equatable {
        let edgeId: UUID
        let blockId: Int
        let sourceId: UUID
    }

    let blocks: [Block]
    let sources: [SourceCard]
    let connections: [Connection]

    /// Prose blocks with no edge — the unsupported-claims mode, and Phase 6's
    /// "research plan" read straight off the page.
    var unsupportedBlockIds: Set<Int> {
        Set(blocks.filter { $0.isProse && $0.edgeIds.isEmpty }.map(\.id))
    }

    // MARK: Build

    static func build(
        markdown: String,
        edges: [EdgeInput],
        anchors: [AnchorInput],
        sources: [SourceInput],
        citedSourceIdsInWorkspace: Set<UUID>
    ) -> AuditModel {
        var blocks = parseBlocks(markdown)
        let anchorsById = Dictionary(uniqueKeysWithValues: anchors.map { ($0.id, $0) })
        let upstreamGroups = upstreamGroups(for: sources)

        var cards: [UUID: SourceCard] = [:]
        for source in sources {
            cards[source.sourceId] = SourceCard(
                sourceId: source.sourceId,
                sourceKey: source.sourceKey,
                title: source.title,
                url: source.url,
                disposition: source.disposition,
                isUnusedInWorkspace: !citedSourceIdsInWorkspace.contains(source.sourceId),
                upstreamGroup: upstreamGroups[source.sourceId]
            )
        }

        var connections: [Connection] = []
        for edge in edges {
            guard let anchor = anchorsById[edge.anchorId], cards[anchor.sourceId] != nil else { continue }
            cards[anchor.sourceId]?.edgeIds.append(edge.id)
            guard let blockIndex = blockIndex(for: edge, in: markdown, blocks: blocks) else { continue }
            blocks[blockIndex].edgeIds.append(edge.id)
            connections.append(Connection(edgeId: edge.id, blockId: blocks[blockIndex].id, sourceId: anchor.sourceId))
        }

        // Cited sources first, then unused, alphabetical within each — a calm
        // rail, not a layout algorithm.
        let orderedCards = cards.values.sorted {
            if $0.isUnusedInWorkspace != $1.isUnusedInWorkspace { return !$0.isUnusedInWorkspace }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        return AuditModel(blocks: blocks, sources: orderedCards, connections: connections)
    }

    // MARK: Blocks

    /// Blank-line-separated blocks with UTF-16 ranges into the original text.
    static func parseBlocks(_ markdown: String) -> [Block] {
        let nsText = markdown as NSString
        var blocks: [Block] = []
        var cursor = 0
        for paragraph in markdown.components(separatedBy: "\n\n") {
            let length = (paragraph as NSString).length
            let range = NSRange(location: cursor, length: length)
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                blocks.append(Block(
                    id: blocks.count,
                    range: range,
                    text: trimmed,
                    isHeading: trimmed.hasPrefix("#")
                ))
            }
            cursor += length + 2 // the separator
        }
        // Guard against separator-length drift on odd inputs.
        return blocks.filter { NSMaxRange($0.range) <= nsText.length + 2 }
    }

    /// The Phase 1 rule verbatim: offsets are the fast path, the quote is the
    /// truth. Valid offsets whose span still contains the quote win; otherwise
    /// find the quote; otherwise the edge maps to no block. Never an error.
    static func blockIndex(for edge: EdgeInput, in markdown: String, blocks: [Block]) -> Int? {
        let nsText = markdown as NSString
        var location: Int?
        if edge.start >= 0, edge.length >= 0, edge.start + edge.length <= nsText.length, edge.length > 0 {
            let spanned = nsText.substring(with: NSRange(location: edge.start, length: edge.length))
            if edge.quote.isEmpty || spanned.contains(edge.quote) {
                location = edge.start
            }
        }
        if location == nil, !edge.quote.isEmpty {
            let found = nsText.range(of: edge.quote)
            if found.location != NSNotFound { location = found.location }
        }
        guard let location else { return nil }
        return blocks.firstIndex { NSLocationInRange(location, $0.range) }
            ?? blocks.lastIndex { $0.range.location <= location }
    }

    // MARK: Shared upstream

    /// Group sources by the root of their recorded openedFromSourceId lineage;
    /// only fans (≥2 members) get a group number. Cycle-guarded — imported or
    /// hand-synced data must never hang the audit view.
    static func upstreamGroups(for sources: [SourceInput]) -> [UUID: Int] {
        let parent = Dictionary(uniqueKeysWithValues: sources.compactMap { source in
            source.openedFromSourceId.map { (source.sourceId, $0) }
        })
        func root(of id: UUID) -> UUID {
            var current = id
            var seen: [UUID] = [current]
            while let next = parent[current] {
                if let cycleStart = seen.firstIndex(of: next) {
                    // A lineage cycle (only possible via imported or hand-edited
                    // data): every member must resolve to ONE canonical root or
                    // the fan detection would split the family. Pick the
                    // smallest id — deterministic, order-independent.
                    return seen[cycleStart...].min { $0.uuidString < $1.uuidString } ?? next
                }
                seen.append(next)
                current = next
            }
            return current
        }
        var members: [UUID: [UUID]] = [:]
        for source in sources {
            members[root(of: source.sourceId), default: []].append(source.sourceId)
        }
        var groups: [UUID: Int] = [:]
        var groupNumber = 0
        // Deterministic numbering, so colors are stable across refreshes.
        for (rootId, ids) in members.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where ids.count >= 2 {
            for id in ids { groups[id] = groupNumber }
            if parent.values.contains(rootId) || members[rootId] != nil {
                // The root itself (when it is one of our sources) joins its fan.
                groups[rootId] = groups[rootId] ?? groupNumber
            }
            groupNumber += 1
        }
        return groups
    }
}
