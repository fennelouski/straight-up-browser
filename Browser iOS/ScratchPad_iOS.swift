import SwiftData
import SwiftUI
import UIKit

struct ScratchPad_iOS: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScratchPadItem.createdAt, order: .reverse)
    private var items: [ScratchPadItem]

    let pageTitle: String
    let pageURL: URL?

    @State private var note = ""
    @State private var activityItems: [Any] = []
    @State private var isSharing = false

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        "A quiet place to collect things",
                        systemImage: "note.text",
                        description: Text("Write a note or clip this page. Items sync with your browser data and stay separate from AI until you share them.")
                    )
                } else {
                    List {
                        ForEach(items) { item in
                            row(item)
                                .draggable(item.agentContext)
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle("Scratch Pad")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: clipCurrentPage) {
                        Label("Clip Page", systemImage: "link.badge.plus")
                    }
                    .disabled(pageURL == nil)
                }
            }
            .sheet(isPresented: $isSharing) {
                ActivitySheet_iOS(items: activityItems)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Jot down a thought…", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit(saveNote)
            Button(action: saveNote) {
                Image(systemName: "plus.circle.fill").font(.title2)
            }
            .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Save note")
        }
        .padding()
        .background(.bar)
    }

    @ViewBuilder
    private func row(_ item: ScratchPadItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(label(for: item.kind), systemImage: item.kind.systemImage)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(item.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if item.kind == .image,
               let data = item.imageData,
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if !item.text.isEmpty {
                Text(item.text).textSelection(.enabled)
            }
            if let url = item.sourceURL {
                Link(item.sourceTitle.isEmpty ? url.absoluteString : item.sourceTitle, destination: url)
                    .font(.caption)
                    .lineLimit(1)
            }
            Button { share(item) } label: {
                Label("Share or send to AI", systemImage: "square.and.arrow.up")
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private func label(for kind: ScratchPadItemKind) -> String {
        switch kind {
        case .note: "Note"
        case .text: "Clip"
        case .link: "Link"
        case .image: "Image"
        }
    }

    private func saveNote() {
        let cleaned = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        modelContext.insert(ScratchPadItem(kind: .note, text: cleaned))
        try? modelContext.save()
        note = ""
    }

    private func clipCurrentPage() {
        guard let pageURL else { return }
        modelContext.insert(ScratchPadItem(
            kind: .link,
            text: pageTitle,
            sourceURL: pageURL,
            sourceTitle: pageTitle
        ))
        try? modelContext.save()
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { modelContext.delete(items[index]) }
        try? modelContext.save()
    }

    private func share(_ item: ScratchPadItem) {
        var payload: [Any] = []
        if item.kind == .image,
           let data = item.imageData,
           let image = UIImage(data: data) {
            payload.append(image)
        }
        if !item.agentContext.isEmpty { payload.append(item.agentContext) }
        if let sourceURL = item.sourceURL { payload.append(sourceURL) }
        activityItems = payload
        isSharing = !payload.isEmpty
    }
}
