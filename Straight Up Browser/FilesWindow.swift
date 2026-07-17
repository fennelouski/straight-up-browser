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
    let icon: NSImage
    let exists: Bool
    let sizeText: String?
    let typeText: String?
    let created: Date?
    let accessed: Date?

    var id: UUID { record.id }

    static func make(from record: FileRecord) -> FileRow {
        let url = record.url
        let exists = FileManager.default.fileExists(atPath: url.path)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)

        var sizeText: String?, typeText: String?, created: Date?, accessed: Date?
        if exists, let v = try? url.resourceValues(forKeys: [
            .totalFileSizeKey, .fileSizeKey, .contentTypeKey, .creationDateKey, .contentAccessDateKey,
        ]) {
            if let size = v.totalFileSize ?? v.fileSize {
                sizeText = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            }
            typeText = v.contentType?.localizedDescription
            created = v.creationDate
            accessed = v.contentAccessDate
        }
        return FileRow(record: record, icon: icon, exists: exists,
                       sizeText: sizeText, typeText: typeText, created: created, accessed: accessed)
    }

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
        if let typeText { parts.append(typeText) }
        if let sizeText { parts.append(sizeText) }
        parts.append(whereText)
        if let sourceText { parts.append(sourceText) }
        return parts.joined(separator: " · ")
    }

    var detail: String? {
        var parts: [String] = []
        if let created { parts.append(String(localized: "Created \(HumanDate.compact(created))")) }
        if let accessed { parts.append(String(localized: "Opened \(HumanDate.compact(accessed))")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Window

enum KindFilter: String, CaseIterable, Identifiable {
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

struct FilesWindow: View {
    @ObservedObject private var manager = DownloadManager.shared

    @State private var rows: [FileRow] = []
    @State private var search = ""
    @State private var filter: KindFilter = .all
    @State private var selection: UUID?
    @State private var previewURL: URL?
    @State private var showClearConfirm = false

    private var visibleRows: [FileRow] {
        rows.filter { row in
            switch filter {
            case .all: break
            case .downloads where row.record.kind != .download: return false
            case .uploads where row.record.kind != .upload: return false
            default: break
            }
            guard !search.isEmpty else { return true }
            let q = search.lowercased()
            return row.record.name.lowercased().contains(q)
                || (row.record.source?.lowercased().contains(q) ?? false)
        }
    }

    private var groupedDays: [(day: Date, rows: [FileRow])] {
        let groups = Dictionary(grouping: visibleRows) { Calendar.current.startOfDay(for: $0.record.date) }
        return groups.keys.sorted(by: >).map { day in
            (day, groups[day]!.sorted { $0.record.date > $1.record.date })
        }
    }

    var body: some View {
        Group {
            if manager.records.isEmpty {
                ContentUnavailableView(
                    "Nothing here yet",
                    systemImage: "tray.and.arrow.down",
                    description: Text("Files you download or upload will show up here."))
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
                    .help("Refresh")
            }
            ToolbarItem {
                Button(role: .destructive) { showClearConfirm = true } label: { Image(systemName: "trash") }
                    .help("Clear history")
                    .disabled(manager.records.isEmpty)
            }
        }
        .confirmationDialog("Clear this list?", isPresented: $showClearConfirm) {
            Button("Clear", role: .destructive) { manager.clear(); refresh() }
        } message: {
            Text("This only clears the list. Your files stay exactly where they are.")
        }
        .quickLookPreview($previewURL)
        .onAppear(perform: refresh)
        .onChange(of: manager.records) { _, _ in refresh() }
        .preferredColorScheme(SettingsManager.shared.colorScheme)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(groupedDays, id: \.day) { group in
                Section(HumanDate.day(group.day)) {
                    ForEach(group.rows) { row in
                        FileRowView(row: row)
                            .contextMenu { menu(for: row) }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { open(row) })
                    }
                }
            }
        }
        .onKeyPress(.space) {
            if let row = visibleRows.first(where: { $0.id == selection }), row.exists {
                previewURL = row.record.url
                return .handled
            }
            return .ignored
        }
    }

    @ViewBuilder
    private func menu(for row: FileRow) -> some View {
        Button("Quick Look") { previewURL = row.record.url }.disabled(!row.exists)
        Button("Open") { open(row) }.disabled(!row.exists)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.record.url]) }.disabled(!row.exists)
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.record.path, forType: .string)
        }
        Divider()
        Button("Remove from List", role: .destructive) { manager.remove(row.record); refresh() }
    }

    private func open(_ row: FileRow) {
        guard row.exists else { return }
        NSWorkspace.shared.open(row.record.url)
    }

    private func refresh() {
        rows = manager.records.map(FileRow.make)
    }
}

private struct FileRowView: View {
    let row: FileRow

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: row.icon)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)
                .opacity(row.exists ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: row.record.kind == .download ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                        .font(.caption)
                        .foregroundStyle(row.record.kind == .download ? Color.blue : Color.green)
                    Text(row.record.name)
                        .fontWeight(.medium)
                        .lineLimit(1).truncationMode(.middle)
                        .opacity(row.exists ? 1 : 0.5)
                    if !row.exists {
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
