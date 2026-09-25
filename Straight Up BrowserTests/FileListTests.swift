import Foundation
import Testing
@testable import Browser

@MainActor
struct FileListTests {
    @Test func clearingDownloadsDuringStartupPreservesUploadsAndNewTransfers() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let upload = FileRecord(kind: .upload, path: "/tmp/upload.txt", date: Date())
        let download = FileRecord(kind: .download, path: "/tmp/old.txt", date: Date())
        try JSONEncoder().encode([download, upload]).write(to: file)
        let manager = DownloadManager(storeURL: file)
        manager.clear(kind: .download)
        manager.record(URL(fileURLWithPath: "/tmp/new.txt"), kind: .download, source: nil)
        let live = manager.beginDownload(tabId: UUID(), source: URL(string: "https://example.com/live"))
        await manager.flush()
        #expect(manager.records.map(\.name) == ["new.txt", "upload.txt"])
        #expect(manager.activeDownloads.first?.id == live)
        #expect(manager.activeDownloads.first?.state == .downloading)
        let reopened = DownloadManager(storeURL: file)
        await reopened.flush()
        #expect(reopened.records == manager.records)
        #expect(reopened.activeDownloads.first?.state == .failed)
        reopened.clear()
        reopened.dismiss(live)
        await reopened.flush()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test(arguments: [false, true])
    func oversizedHistoryIsBoundedOnLoad(legacy: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("files-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let records = (0..<10_000).map {
            FileRecord(kind: .download, path: "/missing/\($0).txt", date: Date(timeIntervalSince1970: Double(10_000 - $0)))
        }
        let encoded = try JSONEncoder().encode(records)
        let data: Data
        if legacy {
            data = encoded
        } else {
            let array = try JSONSerialization.jsonObject(with: encoded)
            data = try JSONSerialization.data(withJSONObject: ["records": array, "incompleteDownloads": []])
        }
        try data.write(to: url)

        let manager = DownloadManager(storeURL: url)
        await manager.waitUntilLoaded()
        #expect(manager.records.map(\.id) == Array(records.prefix(500)).map(\.id))
        manager.record(URL(fileURLWithPath: "/missing/new.txt"), kind: .download, source: nil)
        #expect(manager.records.count == 500)
        #expect(manager.records.first?.name == "new.txt")
        await manager.flush()
        let reloaded = DownloadManager(storeURL: url)
        await reloaded.flush()
        #expect(reloaded.records == manager.records)
    }

    @Test func groupingPreservesIdentitySearchAndNewestFirstOrder() async throws {
        let day = Calendar.current.startOfDay(for: Date())
        let older = FileRecord(kind: .download, path: "/missing/Report.pdf", date: day.addingTimeInterval(-60))
        let newer = FileRecord(kind: .download, path: "/missing/other.pdf", source: "https://REPORT.example", date: day)
        let upload = FileRecord(kind: .upload, path: "/missing/Report-upload.pdf", date: day)
        let query = FileListQuery(records: [older, upload, newer], search: "REPORT", filter: .downloads)
        let days = try await query.groupedDays()
        #expect(days.flatMap(\.records).map(\.id) == [newer.id, older.id])
        #expect(days.count == 2)
        let uploads = try await FileListQuery(records: query.records, search: "", filter: .uploads).groupedDays()
        #expect(uploads.flatMap(\.records).map(\.id) == [upload.id])
        let empty = try await FileListQuery(records: query.records, search: "absent", filter: .all).groupedDays()
        #expect(empty.isEmpty)
    }

    @Test func metadataLoadsOffMainActorAndRefreshesDeletedFiles() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("hello".utf8).write(to: url)
        let loader = FileMetadataLoader()
        // The worker asserts that disk/icon access never runs on the main thread.
        let existing = try await loader.load(url)
        #expect(existing.exists)
        #expect(existing.sizeText != nil)
        #expect(existing.icon != nil)
        try FileManager.default.removeItem(at: url)
        let missing = try await loader.load(url)
        #expect(!missing.exists)
        #expect(missing.sizeText == nil)

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await loader.load(url)
        }
        do {
            _ = try await cancelled.value
            Issue.record("A cancelled metadata request must not return a result")
        } catch is CancellationError {
            // Expected, including requests cancelled before the actor starts them.
        }
    }
}
