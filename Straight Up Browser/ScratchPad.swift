import Foundation
import SwiftData

nonisolated enum ScratchPadItemKind: String, CaseIterable, Codable, Sendable {
    case note
    case text
    case link
    case image

    var systemImage: String {
        switch self {
        case .note: "square.and.pencil"
        case .text: "quote.opening"
        case .link: "link"
        case .image: "photo"
        }
    }
}

nonisolated enum ScratchPadLimits {
    static let maximumTextCharacters = 200_000
    static let maximumAgentContextCharacters = 24_000
    static let maximumSourceTitleCharacters = 1_000
    static let maximumImageBytes = 20 * 1_024 * 1_024
}

/// A small, portable artifact captured while browsing. Scratch items are not
/// agent messages or memories: nothing reads them until the user drags one or
/// explicitly chooses an action such as Ask Agent.
@Model
final class ScratchPadItem {
    var id: UUID = UUID()
    var kindRaw: String = ScratchPadItemKind.note.rawValue
    var text: String = ""
    var sourceURL: URL?
    var sourceTitle: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    @Attribute(.externalStorage) var imageData: Data?

    init(
        kind: ScratchPadItemKind,
        text: String = "",
        sourceURL: URL? = nil,
        sourceTitle: String = "",
        imageData: Data? = nil
    ) {
        id = UUID()
        kindRaw = kind.rawValue
        self.text = String(text.prefix(ScratchPadLimits.maximumTextCharacters))
        self.sourceURL = sourceURL
        self.sourceTitle = String(sourceTitle.prefix(ScratchPadLimits.maximumSourceTitleCharacters))
        self.imageData = imageData.flatMap {
            $0.count <= ScratchPadLimits.maximumImageBytes ? $0 : nil
        }
        createdAt = Date()
        updatedAt = Date()
    }

    var kind: ScratchPadItemKind {
        get { ScratchPadItemKind(rawValue: kindRaw) ?? .note }
        set { kindRaw = newValue.rawValue }
    }

    var agentContext: String {
        var parts: [String] = []
        if !sourceTitle.isEmpty { parts.append("Source: \(sourceTitle)") }
        if let sourceURL { parts.append("URL: \(sourceURL.absoluteString)") }
        if !text.isEmpty { parts.append(text) }
        if kind == .image { parts.append("[Clipped image]") }
        return String(parts.joined(separator: "\n").prefix(
            ScratchPadLimits.maximumAgentContextCharacters
        ))
    }
}

#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ScratchPadView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScratchPadItem.createdAt, order: .reverse)
    private var items: [ScratchPadItem]

    let pageTitle: String
    let pageURL: URL?
    let onAskAgent: (ScratchPadItem) -> Void
    let onAddSourceToNewspaper: (URL, String) -> Void
    let onClose: () -> Void

    @State private var note = ""
    @State private var isDropTargeted = false
    @State private var status: String?
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            composer
            Divider()
            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(items) { item in
                            ScratchPadItemRow(
                                item: item,
                                onAskAgent: { onAskAgent(item) },
                                onAddToNewspaper: {
                                    guard let url = item.sourceURL else { return }
                                    onAddSourceToNewspaper(url, item.sourceTitle)
                                    status = "Opening the source and adding it to Newspaper…"
                                },
                                onDelete: { delete(item) }
                            )
                        }
                    }
                    .padding(12)
                }
            }
            if let status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .background(.ultraThickMaterial)
        .contentShape(Rectangle())
        .onDrop(of: [.url, .plainText, .image, .fileURL], isTargeted: $isDropTargeted) { providers in
            importDrop(providers)
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    .padding(7)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { DispatchQueue.main.async { noteFocused = true } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "note.text")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Scratch Pad").font(.headline)
                Text("Private until you choose where it goes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) { Image(systemName: "sparkles") }
                .buttonStyle(.plain)
                .help("Back to Agent")
                .accessibilityLabel("Back to Agent")
        }
        .padding(12)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            TextField("Jot down a thought…", text: $note, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...6)
                .focused($noteFocused)
                .onSubmit(saveNote)
            HStack {
                Button(action: clipCurrentPage) {
                    Label("Clip page", systemImage: "link.badge.plus")
                }
                .disabled(pageURL == nil)
                Spacer()
                Text("Drop text, links, or images anywhere here")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button(action: saveNote) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Save note")
            }
        }
        .padding(12)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("A quiet place to collect things", systemImage: "note.text")
        } description: {
            Text("Write a note, clip this page, or drag in a quote, link, or image. The Agent only sees an item when you choose Ask Agent.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func saveNote() {
        let cleaned = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        insert(ScratchPadItem(kind: .note, text: cleaned))
        note = ""
    }

    private func clipCurrentPage() {
        guard let pageURL else { return }
        insert(ScratchPadItem(
            kind: .link,
            text: pageTitle,
            sourceURL: pageURL,
            sourceTitle: pageTitle
        ))
        status = "Clipped this page"
    }

    private func insert(_ item: ScratchPadItem) {
        modelContext.insert(item)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            status = "Couldn’t save that clip: \(error.localizedDescription)"
        }
    }

    private func delete(_ item: ScratchPadItem) {
        modelContext.delete(item)
        try? modelContext.save()
    }

    private func importDrop(_ providers: [NSItemProvider]) {
        // Prefer the richest representation and create one clip per drag item.
        for provider in providers {
            if let imageType = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .image) == true
            }) {
                provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        guard data.count <= ScratchPadLimits.maximumImageBytes else {
                            status = "That image is larger than the 20 MB clip limit"
                            return
                        }
                        guard NSImage(data: data) != nil else { return }
                        insert(ScratchPadItem(
                            kind: .image,
                            sourceURL: pageURL,
                            sourceTitle: pageTitle,
                            imageData: data
                        ))
                        status = "Clipped an image"
                    }
                }
            } else if provider.canLoadObject(ofClass: NSURL.self) {
                provider.loadObject(ofClass: NSURL.self) { object, _ in
                    guard let url = object as? URL else { return }
                    Task { @MainActor in
                        insert(ScratchPadItem(
                            kind: .link,
                            text: url.absoluteString,
                            sourceURL: url,
                            sourceTitle: url.host ?? url.absoluteString
                        ))
                        status = "Clipped a link"
                    }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let value = object as? String else { return }
                    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty else { return }
                    Task { @MainActor in
                        if let url = URL(string: cleaned), url.scheme != nil {
                            insert(ScratchPadItem(
                                kind: .link,
                                text: cleaned,
                                sourceURL: url,
                                sourceTitle: url.host ?? cleaned
                            ))
                        } else {
                            insert(ScratchPadItem(
                                kind: .text,
                                text: cleaned,
                                sourceURL: pageURL,
                                sourceTitle: pageTitle
                            ))
                        }
                        status = "Clipped text"
                    }
                }
            }
        }
    }
}

private struct ScratchPadItemRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var item: ScratchPadItem
    let onAskAgent: () -> Void
    let onAddToNewspaper: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: item.kind.systemImage)
                    .foregroundStyle(item.kind == .image ? .blue : .orange)
                Text(item.kind == .note ? "Note" : item.kind == .text ? "Clip" : item.kind == .link ? "Link" : "Image")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(item.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if item.kind == .image, let data = item.imageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }

            if item.kind == .note || item.kind == .text {
                TextEditor(text: $item.text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 38, maxHeight: 120)
                    .onChange(of: item.text) { _, _ in
                        item.updatedAt = Date()
                        try? modelContext.save()
                    }
            } else if !item.text.isEmpty {
                Text(item.text)
                    .font(.body)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            if let sourceURL = item.sourceURL {
                Link(destination: sourceURL) {
                    Label(item.sourceTitle.isEmpty ? sourceURL.absoluteString : item.sourceTitle, systemImage: "arrow.up.right")
                        .font(.caption)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 12) {
                Button(action: onAskAgent) {
                    Label("Ask Agent", systemImage: "sparkles")
                }
                .buttonStyle(.borderless)
                .disabled(item.agentContext.isEmpty)
                if item.sourceURL?.scheme == "http" || item.sourceURL?.scheme == "https" {
                    Button(action: onAddToNewspaper) {
                        Label("Newspaper", systemImage: "newspaper")
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete clip")
            }
            .font(.caption)
        }
        .padding(11)
        .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 10))
        .onDrag { item.itemProvider }
        .contextMenu {
            Button("Ask Agent", action: onAskAgent)
            if item.sourceURL?.scheme == "http" || item.sourceURL?.scheme == "https" {
                Button("Add Source to Newspaper", action: onAddToNewspaper)
            }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .accessibilityHint("Drag this item into a website or another app")
    }
}

private extension ScratchPadItem {
    var itemProvider: NSItemProvider {
        let provider: NSItemProvider
        if kind == .image, let imageData, let image = NSImage(data: imageData) {
            provider = NSItemProvider(object: image)
        } else if let sourceURL, kind == .link {
            provider = NSItemProvider(object: sourceURL as NSURL)
        } else {
            provider = NSItemProvider(object: agentContext as NSString)
        }

        if let sourceURL {
            provider.registerObject(sourceURL as NSURL, visibility: .all)
        }
        let portableText = agentContext
        if !portableText.isEmpty {
            provider.registerObject(portableText as NSString, visibility: .all)
        }
        return provider
    }
}

#endif
