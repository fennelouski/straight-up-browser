//
//  BibliographyPanel.swift
//  Straight Up Browser
//
//  The bibliography-matching panel (Phase 5, docs/phase5-design.md §5):
//  advisory by design — dismissing it writes nothing, stores nothing. A match
//  becomes real only through its Anchor button, which runs the exact composer
//  tail the manual gesture would have.
//

import SwiftUI

struct BibliographyPanel: View {
    let workspaceId: UUID
    let initialQuery: String
    let ledgerStore: LedgerStore
    let composer: AnchorComposer?
    var onClose: (() -> Void)? = nil

    @State private var query = ""
    @State private var corpus: [BibliographyPassage] = []
    @State private var matches: [PassageMatch] = []
    @State private var note: String?
    @State private var loaded = false
    @State private var searchTask: Task<Void, Never>?

    private let matcher = EmbeddingPassageMatcher()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
        }
        #if os(macOS)
        .frame(width: 460)
        .frame(maxHeight: 560)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        #endif
        .task {
            query = initialQuery
            corpus = BibliographyCorpus.passages(workspaceId: workspaceId, ledgerStore: ledgerStore)
            loaded = true
            runSearch()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.book.closed")
                .foregroundStyle(.secondary)
            TextField(String(localized: "Does anything support…"), text: $query)
                .textFieldStyle(.plain)
                .onSubmit { runSearch() }
                .onChange(of: query) { _, _ in scheduleSearch() }
            Button {
                onClose?()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(String(localized: "Close bibliography search"))
        }
        .padding(10)
    }

    @ViewBuilder private var content: some View {
        if !loaded {
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        } else if corpus.isEmpty {
            Text("This workspace's sources have no extracted text yet — open a source once to fill it in.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if matches.isEmpty {
            Text(query.trimmingCharacters(in: .whitespaces).isEmpty
                 ? String(localized: "Type a claim, or select one in your document first.")
                 : String(localized: "Nothing in this bibliography matches. That is an answer too."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(matches, id: \.passage.id) { match in
                        matchCard(match)
                    }
                }
                .padding(10)
            }
        }
    }

    private func matchCard(_ match: PassageMatch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(match.band == .strong ? String(localized: "Strong match") : String(localized: "Possible match"))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((match.band == .strong ? Color.green : Color.secondary).opacity(0.15), in: Capsule())
                    .foregroundStyle(match.band == .strong ? Color.green : Color.secondary)
                if let start = match.passage.startSeconds {
                    Text(AnchorComposer.formatTimestamp(start))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
            }
            Text(match.passage.text)
                .font(.system(size: 12))
                .lineLimit(5)
            HStack {
                Text(match.passage.sourceTitle.isEmpty ? match.passage.sourceKey : match.passage.sourceTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(String(localized: "Open")) { open(match.passage) }
                    .controlSize(.small)
                Button(String(localized: "Anchor")) { anchor(match.passage) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .help(String(localized: "Anchor this passage to your document"))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }

    // MARK: Search

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            runSearch()
        }
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { matches = []; return }
        let corpus = corpus
        let matcher = matcher
        matches = matcher.rank(query: trimmed, passages: corpus)
    }

    // MARK: Actions — the ONLY writes, and only on explicit user acceptance

    private func anchor(_ passage: BibliographyPassage) {
        guard let composer, let article = ledgerStore.source(sourceKey: passage.sourceKey) else {
            note = String(localized: "Couldn't anchor this passage.")
            return
        }
        if let start = passage.startSeconds {
            note = composer.anchorTranscript(
                article: article, startSeconds: start, endSeconds: passage.endSeconds,
                captionText: passage.text, workspaceId: workspaceId)
        } else {
            note = composer.anchorPassage(
                article: article, passageText: passage.text, workspaceId: workspaceId)
        }
    }

    private func open(_ passage: BibliographyPassage) {
        guard let url = passage.sourceURL else { return }
        var target = url
        if let start = passage.startSeconds {
            target = AnchorLocator.timestamp(start: start, end: nil).url(base: url, modality: .video)
        }
        NotificationCenter.default.post(name: .browserOpenAnchor, object: nil, userInfo: ["url": target])
        onClose?()
    }
}
