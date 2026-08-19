//
//  AuditView.swift
//  Straight Up Browser
//
//  The graph / audit view (Phase 4, docs/phase4-design.md): one document's
//  text down the left, its workspace's sources down the right, bezier
//  connectors between — one per edge. Both columns are lazy, and connectors
//  come from anchor preferences, so only on-screen rows draw lines: "filtered
//  to the visible passage" by construction, and no layout engine anywhere.
//

import SwiftUI
import SwiftData

// MARK: - Mode

enum AuditMode: String, CaseIterable, Identifiable {
    case all
    case unsupported
    case unused
    case sharedUpstream

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .unsupported: String(localized: "Unsupported Claims")
        case .unused: String(localized: "Unused Sources")
        case .sharedUpstream: String(localized: "Shared Upstream")
        }
    }
}

// MARK: - Anchor plumbing

private struct AuditAnchorKey: PreferenceKey {
    struct Entry: Equatable {
        enum Kind: Hashable { case block(Int), source(UUID) }
        let kind: Kind
        let bounds: Anchor<CGRect>
        static func == (a: Entry, b: Entry) -> Bool { a.kind == b.kind }
    }
    static let defaultValue: [Entry] = []
    static func reduce(value: inout [Entry], nextValue: () -> [Entry]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - The view

struct AuditView: View {
    let document: WorkspaceDocument
    let workspaceId: UUID
    /// Injected loader so previews/tests can hand in a ready model.
    let loadModel: () async -> AuditModel?
    var onClose: (() -> Void)? = nil

    @State private var model: AuditModel?
    @State private var mode: AuditMode = .all

    private static let groupPalette: [Color] = [.orange, .purple, .teal, .pink, .indigo, .brown]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(uiOrNSBackground))
        .task { model = await loadModel() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .foregroundStyle(.secondary)
            Text(document.displayName)
                .font(.headline)
                .lineLimit(1)
            Picker("", selection: $mode) {
                ForEach(AuditMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 520)
            Spacer()
            if let onClose {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(String(localized: "Close audit view"))
            }
        }
        .padding(12)
    }

    @ViewBuilder private var content: some View {
        if let model {
            if model.blocks.isEmpty && model.sources.isEmpty {
                emptyState(String(localized: "Nothing to audit yet — anchor some sources into this document first."))
            } else {
                columns(model)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Columns + connectors

    private func columns(_ model: AuditModel) -> some View {
        HStack(alignment: .top, spacing: 28) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.blocks) { block in
                        blockRow(block, model: model)
                    }
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.sources) { source in
                        sourceCard(source, model: model)
                    }
                }
                .padding(16)
            }
            .frame(width: 300)
        }
        .overlayPreferenceValue(AuditAnchorKey.self) { entries in
            connectorCanvas(entries: entries, model: model)
        }
    }

    private func blockRow(_ block: AuditModel.Block, model: AuditModel) -> some View {
        let unsupported = model.unsupportedBlockIds.contains(block.id)
        let highlighted = mode == .unsupported && unsupported
        let dimmed = mode == .unused || (mode == .sharedUpstream && block.edgeIds.isEmpty)
        return Text(block.text)
            .font(block.isHeading ? .headline : .body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(highlighted ? Color.yellow.opacity(0.22)
                          : block.edgeIds.isEmpty ? Color.clear
                          : Color.accentColor.opacity(0.06))
            )
            .overlay(alignment: .leading) {
                if highlighted {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.yellow)
                        .frame(width: 3)
                }
            }
            .opacity(dimmed ? 0.45 : 1)
            .anchorPreference(key: AuditAnchorKey.self, value: .bounds) {
                [AuditAnchorKey.Entry(kind: .block(block.id), bounds: $0)]
            }
            .accessibilityLabel(unsupported && block.isProse
                ? String(localized: "Unsupported: \(block.text)")
                : block.text)
    }

    private func sourceCard(_ source: AuditModel.SourceCard, model: AuditModel) -> some View {
        let dimmedByMode = (mode == .unsupported)
            || (mode == .unused && !source.isUnusedInWorkspace)
            || (mode == .sharedUpstream && source.upstreamGroup == nil)
        let groupColor = source.upstreamGroup.map { Self.groupPalette[$0 % Self.groupPalette.count] }
        return Button {
            openSource(source)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: dispositionSymbol(source.disposition))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(source.title.isEmpty ? source.sourceKey : source.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if let host = source.url?.host {
                        Text(host).font(.caption2).foregroundStyle(.secondary)
                    }
                    if source.isUnusedInWorkspace {
                        Text("Unused")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    if let groupColor {
                        Label(String(localized: "Shared upstream"), systemImage: "arrow.triangle.merge")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(groupColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(groupColor)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(groupColor?.opacity(mode == .sharedUpstream ? 0.8 : 0.3)
                                  ?? Color.primary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .opacity(dimmedByMode ? 0.4 : 1)
        .anchorPreference(key: AuditAnchorKey.self, value: .bounds) {
            [AuditAnchorKey.Entry(kind: .source(source.sourceId), bounds: $0)]
        }
        .accessibilityLabel(source.title)
        .accessibilityHint(String(localized: "Open source"))
    }

    private func connectorCanvas(entries: [AuditAnchorKey.Entry], model: AuditModel) -> some View {
        GeometryReader { proxy in
            let blockFrames = Dictionary(uniqueKeysWithValues: entries.compactMap { entry -> (Int, CGRect)? in
                guard case .block(let id) = entry.kind else { return nil }
                return (id, proxy[entry.bounds])
            })
            let sourceFrames = Dictionary(uniqueKeysWithValues: entries.compactMap { entry -> (UUID, CGRect)? in
                guard case .source(let id) = entry.kind else { return nil }
                return (id, proxy[entry.bounds])
            })
            Canvas { context, _ in
                for connection in model.connections {
                    // Lazy stacks only report visible rows — offscreen ends
                    // simply have no frame, which IS the passage filter.
                    guard let from = blockFrames[connection.blockId],
                          let to = sourceFrames[connection.sourceId] else { continue }
                    if mode == .unused { continue } // that mode is about absences
                    let start = CGPoint(x: from.maxX, y: from.midY)
                    let end = CGPoint(x: to.minX, y: to.midY)
                    var path = Path()
                    path.move(to: start)
                    let bend = (end.x - start.x) * 0.45
                    path.addCurve(
                        to: end,
                        control1: CGPoint(x: start.x + bend, y: start.y),
                        control2: CGPoint(x: end.x - bend, y: end.y)
                    )
                    let groupColor = model.sources.first { $0.sourceId == connection.sourceId }?
                        .upstreamGroup.map { Self.groupPalette[$0 % Self.groupPalette.count] }
                    let color: Color = mode == .sharedUpstream
                        ? (groupColor ?? .secondary.opacity(0.25))
                        : .accentColor.opacity(0.55)
                    context.stroke(path, with: .color(color), lineWidth: 1.5)
                }
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Helpers

    private func dispositionSymbol(_ disposition: SourceDisposition?) -> String {
        switch disposition {
        case .open: "circle"
        case .kept: "checkmark.circle"
        case .dismissed: "xmark.circle"
        case nil: "questionmark.circle"
        }
    }

    private func openSource(_ source: AuditModel.SourceCard) {
        guard let url = source.url else { return }
        // Reuses the anchor-open path, so the user's "Anchor links open"
        // setting governs (split-beside on Mac, full screen on iPhone).
        NotificationCenter.default.post(
            name: .browserOpenAnchor, object: nil,
            userInfo: ["url": url]
        )
        onClose?()
    }

    private var uiOrNSBackground: CGColor {
        #if os(macOS)
        NSColor.windowBackgroundColor.cgColor
        #else
        UIColor.systemBackground.cgColor
        #endif
    }
}

// MARK: - Store-backed loader

@MainActor
enum AuditLoader {

    /// Assemble the model from the real stores: a coordinated read of the
    /// document, its edges, their anchors, and every non-dismissed source the
    /// workspace references. "Unused" is workspace-wide: cited by no edge in
    /// any of the workspace's documents.
    static func load(
        document: WorkspaceDocument,
        workspaceId: UUID,
        ledgerStore: LedgerStore,
        documentStore: DocumentStore
    ) -> AuditModel? {
        guard let url = documentStore.url(for: document) else { return nil }
        var markdown = ""
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { url in
            markdown = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        let edges = ledgerStore.edges(documentId: document.id).map {
            AuditModel.EdgeInput(id: $0.id, anchorId: $0.anchorId, quote: $0.rangeQuote,
                                 start: $0.rangeStart, length: $0.rangeLength)
        }

        var anchors: [AuditModel.AnchorInput] = []
        var anchorSourceIds: Set<UUID> = []
        for edge in edges {
            guard let anchor = ledgerStore.anchor(id: edge.anchorId) else { continue }
            anchors.append(AuditModel.AnchorInput(id: anchor.id, sourceId: anchor.sourceId, sourceKey: anchor.sourceKey))
            anchorSourceIds.insert(anchor.sourceId)
        }

        // The source rail: everything the workspace holds (not dismissed),
        // plus anything this document cites from elsewhere.
        var sources: [AuditModel.SourceInput] = []
        var seenSourceIds: Set<UUID> = []
        for ref in ledgerStore.references(workspaceId: workspaceId) where ref.disposition != .dismissed {
            guard let article = ledgerStore.source(sourceKey: ref.sourceKey), seenSourceIds.insert(article.id).inserted else { continue }
            sources.append(AuditModel.SourceInput(
                sourceId: article.id, sourceKey: article.sourceKey,
                title: article.title, url: article.url,
                disposition: ref.disposition,
                openedFromSourceId: ref.openedFromSourceId))
        }
        for anchor in anchors where !seenSourceIds.contains(anchor.sourceId) {
            guard let article = ledgerStore.source(sourceKey: anchor.sourceKey) else { continue }
            seenSourceIds.insert(article.id)
            sources.append(AuditModel.SourceInput(
                sourceId: article.id, sourceKey: article.sourceKey,
                title: article.title, url: article.url,
                disposition: nil, openedFromSourceId: nil))
        }

        // Cited anywhere in the workspace = the union over its documents' edges.
        var cited: Set<UUID> = []
        for row in documentStore.documents(workspaceId: workspaceId) {
            for edge in ledgerStore.edges(documentId: row.id) {
                if let anchor = ledgerStore.anchor(id: edge.anchorId) {
                    cited.insert(anchor.sourceId)
                }
            }
        }

        return AuditModel.build(
            markdown: markdown,
            edges: edges,
            anchors: anchors,
            sources: sources,
            citedSourceIdsInWorkspace: cited
        )
    }
}
