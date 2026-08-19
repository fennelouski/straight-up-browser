//
//  TranscriptPanel.swift
//  Straight Up Browser
//
//  The per-video transcript panel (Phase 2, design §8.2): caption lines with
//  timestamps, search-within-video, click to seek, select-and-anchor. Toggled
//  by the transcript key command and rendered inside an existing ContentView
//  overlay (the type-check budget forbids a new body modifier).
//

import SwiftUI
import WebKit

struct TranscriptPanelView: View {
    let article: NewspaperArticle
    let fetcher: TranscriptFetcher
    let composer: AnchorComposer?
    let workspaceId: UUID?
    /// The video tab's live web view, for reading captions and seeking.
    let webView: WKWebView?
    @Binding var isPresented: Bool

    @State private var segments: [TranscriptSegment] = []
    @State private var searchText = ""
    @State private var loadState: LoadState = .loading
    @State private var selectedSegmentIds: Set<Int> = []
    @State private var note: String?

    enum LoadState { case loading, loaded, unavailable }

    private var filtered: [(offset: Int, element: TranscriptSegment)] {
        let all = Array(segments.enumerated())
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all.map { (offset: $0.offset, element: $0.element) } }
        return all.filter { $0.element.t.lowercased().contains(needle) }
            .map { (offset: $0.offset, element: $0.element) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        #if os(macOS)
        .frame(width: 340)
        .frame(maxHeight: 480)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        #endif
        .task(id: article.sourceKey) { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.quote")
                .foregroundStyle(.secondary)
            TextField(String(localized: "Search transcript"), text: $searchText)
                .textFieldStyle(.plain)
            if !selectedSegmentIds.isEmpty {
                Button(String(localized: "Anchor")) { anchorSelection() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(String(localized: "Anchor the selected caption lines to your document"))
            }
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Close transcript"))
        }
        .padding(10)
    }

    @ViewBuilder private var content: some View {
        switch loadState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 120)
        case .unavailable:
            VStack(spacing: 8) {
                Text("No transcript available.")
                    .foregroundStyle(.secondary)
                Button(String(localized: "Retry")) { Task { await load(force: true) } }
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        case .loaded:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered, id: \.offset) { item in
                        segmentRow(item.offset, item.element)
                    }
                }
                .padding(8)
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
    }

    private func segmentRow(_ index: Int, _ segment: TranscriptSegment) -> some View {
        let selected = selectedSegmentIds.contains(index)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(AnchorComposer.formatTimestamp(segment.startSeconds))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.accentColor)
            Text(segment.t)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.accentColor.opacity(0.15) : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            #if os(macOS)
            // Shift-click extends the anchor selection across lines.
            let extending = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            #else
            let extending = !selectedSegmentIds.isEmpty
            #endif
            if extending {
                if selected { selectedSegmentIds.remove(index) } else { selectedSegmentIds.insert(index) }
            } else {
                selectedSegmentIds = []
                seek(to: segment.startSeconds)
            }
        }
        .contextMenu {
            Button(String(localized: "Anchor This Line")) {
                selectedSegmentIds = [index]
                anchorSelection()
            }
            Button(String(localized: "Jump to \(AnchorComposer.formatTimestamp(segment.startSeconds))")) {
                seek(to: segment.startSeconds)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(AnchorComposer.formatTimestamp(segment.startSeconds)), \(segment.t)")
    }

    private func load(force: Bool = false) async {
        loadState = .loading
        if !force, !segments.isEmpty { loadState = .loaded; return }
        let transcript = await fetcher.ensureTranscript(for: article, webView: webView)
        segments = transcript?.segments ?? []
        loadState = segments.isEmpty ? .unavailable : .loaded
    }

    private func seek(to seconds: Int) {
        webView?.evaluateJavaScript(
            "(() => { const v = document.querySelector('video'); if (v) { v.currentTime = \(seconds); v.play(); } })()",
            completionHandler: nil
        )
    }

    private func anchorSelection() {
        guard let composer, let workspaceId, !selectedSegmentIds.isEmpty else {
            note = String(localized: "Open a workspace to anchor sources into it.")
            return
        }
        let picked = selectedSegmentIds.sorted().compactMap { segments.indices.contains($0) ? segments[$0] : nil }
        guard let first = picked.first, let last = picked.last else { return }
        let text = picked.map(\.t).joined(separator: " ")
        note = composer.anchorTranscript(
            article: article,
            startSeconds: first.startSeconds,
            endSeconds: last.endSeconds,
            captionText: text,
            workspaceId: workspaceId
        )
        selectedSegmentIds = []
    }
}
