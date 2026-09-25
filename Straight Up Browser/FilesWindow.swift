//
//  FilesWindow.swift
//  Straight Up Browser
//
//  The "browser folder": a human-readable history of everything you've
//  downloaded or uploaded. Grouped by day, with live file metadata (type,
//  size, where it lives, when it was made / last opened) and Quick Look.
//

import SwiftUI
import AppKit
import QuickLook
import UniformTypeIdentifiers

// MARK: - Human-friendly dates

// For humans, not bureaucrats: today collapses to a bare time, this week to a
// weekday, this year to "July 14", older to "July 14, 2025".
enum HumanDate {
    static func day(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return String(localized: "Today") }
        if cal.isDateInYesterday(date) { return String(localized: "Yesterday") }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
        if days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        if cal.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.month(.wide).day())
        }
        return date.formatted(.dateTime.month(.wide).day().year())
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    // Compact single value: today → time, else a short date.
    static func compact(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return date.formatted(.dateTime.hour().minute()) }
        if cal.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if cal.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

// MARK: - Row view model (metadata read live from disk)

struct FileRow: Identifiable {
    let record: FileRecord
    let metadata: FileMetadata?

    var id: UUID { record.id }
    var exists: Bool { metadata?.exists == true }

    var whereText: String {
        (record.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    var sourceText: String? {
        guard let s = record.source, let host = URL(string: s)?.host else { return nil }
        return record.kind == .download
            ? String(localized: "from \(host)")
            : String(localized: "to \(host)")
    }

    var subtitle: String {
        var parts: [String] = []
        if let typeText = metadata?.typeText { parts.append(typeText) }
        if let sizeText = metadata?.sizeText { parts.append(sizeText) }
        parts.append(whereText)
        if let sourceText { parts.append(sourceText) }
        return parts.joined(separator: " · ")
    }

    var detail: String? {
        var parts: [String] = []
        if let created = metadata?.created { parts.append(String(localized: "Created \(HumanDate.compact(created))")) }
        if let accessed = metadata?.accessed { parts.append(String(localized: "Opened \(HumanDate.compact(accessed))")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Window

nonisolated enum KindFilter: String, CaseIterable, Identifiable, Sendable {
    case all, downloads, uploads
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return String(localized: "All")
        case .downloads: return String(localized: "Downloads")
        case .uploads: return String(localized: "Uploads")
        }
    }
}

nonisolated struct FileDay: Identifiable, Sendable {
    let day: Date
    let records: [FileRecord]
    var id: Date { day }
}

nonisolated struct FileListQuery: Equatable, Sendable {
    let records: [FileRecord]
    let search: String
    let filter: KindFilter

    @concurrent
    func groupedDays() async throws -> [FileDay] {
        try Task.checkCancellation()
        let query = search.lowercased()
        let matching = records.filter { record in
            switch filter {
            case .downloads where record.kind != .download: return false
            case .uploads where record.kind != .upload: return false
            default: break
            }
            return query.isEmpty || record.name.lowercased().contains(query)
                || (record.source?.lowercased().contains(query) ?? false)
        }
        let calendar = Calendar.current
        let groups = Dictionary(grouping: matching) { calendar.startOfDay(for: $0.date) }
        let result = groups.keys.sorted(by: >).map { day in
            FileDay(day: day, records: groups[day]!.sorted { $0.date > $1.date })
        }
        try Task.checkCancellation()
        return result
    }
}

struct FilesWindow: View {
    @ObservedObject private var manager = DownloadManager.shared

    @State private var metadata: [UUID: FileMetadata] = [:]
    @State private var metadataGeneration = 0
    @State private var metadataLoader = FileMetadataLoader()
    @State private var groupedDays: [FileDay] = []
    @State private var search = ""
    @State private var filter: KindFilter = .all
    @State private var selection: UUID?
    @State private var previewURL: URL?
    @State private var showClearConfirm = false
    // @AppStorage (not SettingsManager.shared.colorScheme) so this window re-renders
    // when Theme changes instead of waiting for an unrelated update.
    @AppStorage("theme") private var themePreference = "System"

    private var colorScheme: ColorScheme? {
        switch themePreference {
        case "Light": return .light
        case "Dark": return .dark
        default: return nil
        }
    }

    private var query: FileListQuery {
        FileListQuery(records: manager.records, search: search, filter: filter)
    }

    private var visibleActiveDownloads: [ActiveDownload] {
        guard filter != .uploads else { return [] }
        guard !search.isEmpty else { return manager.activeDownloads }
        let query = search.lowercased()
        return manager.activeDownloads.filter {
            $0.filename.lowercased().contains(query)
                || ($0.source?.absoluteString.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        Group {
            if manager.records.isEmpty && manager.activeDownloads.isEmpty {
                ContentUnavailableView(
                    "Nothing here yet",
                    systemImage: "tray.and.arrow.down",
                    description: Text("In-progress, failed, and completed downloads will show up here."))
            } else {
                list
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .searchable(text: $search, prompt: Text("Search files"))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $filter) {
                    ForEach(KindFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            ToolbarItem {
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .delayedHelp("Refresh")
            }
            ToolbarItem {
                Button(role: .destructive) { showClearConfirm = true } label: { Image(systemName: "trash") }
                    .delayedHelp("Clear history")
                    .disabled(manager.records.isEmpty)
            }
        }
        .confirmationDialog("Clear this list?", isPresented: $showClearConfirm) {
            Button("Clear", role: .destructive) { manager.clear() }
        } message: {
            Text("This only clears the list. Your files stay exactly where they are.")
        }
        .quickLookPreview($previewURL)
        .onAppear(perform: refresh)
        .onChange(of: manager.records) { _, records in
            let ids = Set(records.map(\.id))
            metadata = metadata.filter { ids.contains($0.key) }
        }
        .task(id: query) {
            if let days = try? await query.groupedDays(), !Task.isCancelled {
                groupedDays = days
            }
        }
        .preferredColorScheme(colorScheme)
    }

    private var list: some View {
        List(selection: $selection) {
            if !visibleActiveDownloads.isEmpty {
                Section("Incomplete Downloads") {
                    ForEach(visibleActiveDownloads) { transfer in
                        ActiveDownloadRow(
                            transfer: transfer,
                            onPause: { manager.pause(transfer.id) },
                            onRestart: { manager.restart(transfer.id) },
                            onDismiss: { manager.dismiss(transfer.id) }
                        )
                        .tag(transfer.id)
                    }
                }
            }
            ForEach(groupedDays) { group in
                Section(HumanDate.day(group.day)) {
                    ForEach(group.records) { record in
                        let row = FileRow(record: record, metadata: metadata[record.id])
                        FileRowView(row: row)
                            .tag(record.id)
                            .task(id: metadataGeneration) {
                                guard metadata[record.id] == nil else { return }
                                let generation = metadataGeneration
                                if let result = try? await metadataLoader.load(record.url),
                                   !Task.isCancelled, generation == metadataGeneration,
                                   manager.records.contains(where: { $0.id == record.id }) {
                                    metadata[record.id] = result
                                }
                            }
                            .contextMenu { menu(for: row) }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { open(row) })
                    }
                }
            }
        }
        .onKeyPress(.space) {
            if let record = groupedDays.lazy.flatMap(\.records).first(where: { $0.id == selection }),
               metadata[record.id]?.exists == true {
                previewURL = record.url
                return .handled
            }
            return .ignored
        }
    }

    @ViewBuilder
    private func menu(for row: FileRow) -> some View {
        Button("Quick Look") { previewURL = row.record.url }.disabled(!row.exists)
        Button("Open") { open(row) }.disabled(!row.exists)
        Menu("Open With") {
            ForEach(openWithApps(for: row.record.url), id: \.self) { app in
                Button(FileManager.default.displayName(atPath: app.path)) { open(row, with: app) }
            }
            Divider()
            Button("Other…") { chooseApplication(for: row) }
        }
        .disabled(!row.exists)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.record.url]) }.disabled(!row.exists)
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.record.path, forType: .string)
        }
        Divider()
        Button("Move to Trash", role: .destructive) { moveToTrash(row) }.disabled(!row.exists)
        Button("Remove from List", role: .destructive) { manager.remove(row.record) }
    }

    private func open(_ row: FileRow) {
        guard row.exists else { return }
        NSWorkspace.shared.open(row.record.url)
    }

    private func open(_ row: FileRow, with app: URL) {
        guard row.exists else { return }
        NSWorkspace.shared.open([row.record.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private func openWithApps(for url: URL) -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: url)
            .sorted { FileManager.default.displayName(atPath: $0.path) < FileManager.default.displayName(atPath: $1.path) }
    }

    private func chooseApplication(for row: FileRow) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let app = panel.url {
            open(row, with: app)
        }
    }

    private func moveToTrash(_ row: FileRow) {
        try? FileManager.default.trashItem(at: row.record.url, resultingItemURL: nil)
        refresh()
    }

    private func refresh() {
        metadata.removeAll()
        metadataGeneration += 1
    }
}

private struct ActiveDownloadRow: View {
    let transfer: ActiveDownload
    let onPause: () -> Void
    let onRestart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(DownloadVisuals.color(for: transfer.colorIndex).opacity(0.18), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.015, transfer.progress))
                    .stroke(
                        DownloadVisuals.color(for: transfer.colorIndex),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Image(systemName: transfer.state == .failed ? "exclamationmark" : "arrow.down")
                    .font(.system(size: 11, weight: .bold))
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.filename)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                ProgressView(value: transfer.progress)
                    .tint(DownloadVisuals.color(for: transfer.colorIndex))

                HStack(spacing: 6) {
                    Text(transfer.state.label)
                    Text("\(Int(transfer.progress * 100))%").monospacedDigit()
                    if let host = transfer.source?.host { Text("from \(host)") }
                    if let error = transfer.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 12)

            switch transfer.state {
            case .downloading:
                Button(action: onPause) {
                    Image(systemName: "pause.fill")
                }
                .buttonStyle(.borderless)
                .delayedHelp("Pause")
            case .pausing:
                ProgressView().controlSize(.small)
            case .paused, .failed:
                Button(action: onRestart) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .delayedHelp("Restart")
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .delayedHelp("Remove from List")
            }
        }
        .padding(.vertical, 5)
    }
}

private struct FileRowView: View {
    let row: FileRow

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = row.metadata?.icon {
                    Image(decorative: icon, scale: 1)
                        .resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "doc")
                }
            }
            .frame(width: 32, height: 32)
            .opacity(row.metadata?.exists == false ? 0.4 : 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: row.record.kind == .download ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                        .font(.caption)
                        .foregroundStyle(row.record.kind == .download ? Color.blue : Color.green)
                    Text(row.record.name)
                        .fontWeight(.medium)
                        .lineLimit(1).truncationMode(.middle)
                        .opacity(row.metadata?.exists == false ? 0.5 : 1)
                    if row.metadata?.exists == false {
                        Text("missing")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.2)))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(row.subtitle)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let detail = row.detail {
                    Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Text(HumanDate.time(row.record.date))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 4)
    }
}
