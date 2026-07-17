//
//  DownloadManager.swift
//  Straight Up Browser
//
//  Remembers files that passed through the browser (downloaded or uploaded).
//  Deliberately NOT SwiftData/CloudKit: these are absolute paths on THIS Mac,
//  so syncing them to other devices would just be broken links. Plain local
//  JSON. The app is not sandboxed, so raw paths are fine (no security scopes).
//

import Foundation
import Combine

enum FileTransferKind: String, Codable {
    case download
    case upload
}

struct FileRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: FileTransferKind
    var path: String        // absolute file path
    var source: String?     // web page/origin involved, if known
    var date: Date          // when it passed through the browser

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var records: [FileRecord] = []

    // ponytail: hard cap keeps the JSON small; add paging if anyone hoards 500+.
    private let maxRecords = 500
    private let storeURL: URL

    private init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Straight Up Browser", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("file-history.json")
        load()
    }

    func record(_ url: URL, kind: FileTransferKind, source: URL?) {
        records.insert(FileRecord(kind: kind, path: url.path, source: source?.absoluteString, date: Date()), at: 0)
        if records.count > maxRecords { records.removeLast(records.count - maxRecords) }
        save()
    }

    func remove(_ record: FileRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    func clear() {
        records.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([FileRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
