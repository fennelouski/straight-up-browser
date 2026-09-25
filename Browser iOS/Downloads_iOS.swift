import SwiftUI

struct Downloads_iOS: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = DownloadManager.shared
    @State private var showClearConfirmation = false

    @State private var completedDownloads: [FileRecord] = []
    @State private var fileExists: [UUID: Bool] = [:]
    @State private var metadataGeneration = 0
    @State private var metadataLoader = FileMetadataLoader()

    var body: some View {
        NavigationStack {
            Group {
                if manager.activeDownloads.isEmpty && completedDownloads.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text(
                            "Active downloads, failures, and downloaded files will appear here."
                        )
                    )
                } else {
                    List {
                        if !manager.activeDownloads.isEmpty {
                            Section("Incomplete Downloads") {
                                ForEach(manager.activeDownloads) {
                                    activeRow($0)
                                }
                            }
                        }
                        if !completedDownloads.isEmpty {
                            Section("Downloaded Files") {
                                ForEach(completedDownloads) {
                                    completedRow($0)
                                }
                            }
                        }
                    }
                    .refreshable { refresh() }
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Clear Download History")
                    .disabled(completedDownloads.isEmpty)
                }
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: manager.records, initial: true) { _, records in
            completedDownloads = records.filter { $0.kind == .download }
            let ids = Set(completedDownloads.map(\.id))
            fileExists = fileExists.filter { ids.contains($0.key) }
        }
        .confirmationDialog(
            "Clear download history?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                manager.clear(kind: .download)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded files remain in the app’s Downloads folder.")
        }
    }

    private func refresh() {
        fileExists.removeAll()
        metadataGeneration += 1
    }

    private func activeRow(_ transfer: ActiveDownload) -> some View {
        HStack(spacing: 12) {
            ProgressView(value: transfer.progress)
                .progressViewStyle(.circular)
                .tint(DownloadVisuals.color(for: transfer.colorIndex))

            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.filename)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(status(for: transfer))
                    .font(.caption)
                    .foregroundStyle(
                        transfer.state == .failed
                            ? Color.red
                            : Color.secondary
                    )
                    .lineLimit(2)
            }

            Spacer()

            if transfer.state == .failed || transfer.state == .paused {
                Button {
                    manager.dismiss(transfer.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss \(transfer.filename)")
            }
        }
        .padding(.vertical, 4)
    }

    private func status(for transfer: ActiveDownload) -> String {
        let progress = String(
            localized: "\(transfer.state.label) · \(Int(transfer.progress * 100))%"
        )
        guard let error = transfer.errorMessage else { return progress }
        return "\(progress) · \(error)"
    }

    private func completedRow(_ record: FileRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .foregroundStyle(.blue)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(record.date, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if fileExists[record.id] == true {
                ShareLink(item: record.url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share \(record.name)")
            } else if fileExists[record.id] == false {
                Text("Missing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: metadataGeneration) {
            guard fileExists[record.id] == nil else { return }
            let generation = metadataGeneration
            if let result = try? await metadataLoader.exists(record.url),
               !Task.isCancelled, generation == metadataGeneration,
               manager.records.contains(where: { $0.id == record.id }) {
                fileExists[record.id] = result
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                manager.remove(record)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }
}
