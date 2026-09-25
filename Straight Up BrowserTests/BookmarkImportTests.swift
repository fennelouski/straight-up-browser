import Foundation
import SwiftData
import Testing
@testable import Browser

@MainActor
struct BookmarkImportTests {
    @Test func largeImportsParseOffMainAndConcurrentBatchesDeduplicate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let htmlURL = directory.appendingPathComponent("bookmarks.html")
        let html = (0..<1_000).map { "<A HREF=\"https://example.com/\($0)\">Item \($0)</A>" }.joined()
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        let bookmarks = try await BrowserLibrary.importBookmarksHTML(from: htmlURL)
        #expect(bookmarks.count == 1_000)
        let chromeURL = directory.appendingPathComponent("Bookmarks")
        let chrome: [String: Any] = ["roots": ["bookmark_bar": ["children": [
            ["type": "url", "name": "Chrome", "url": "https://example.com/chrome", "date_added": "invalid"]
        ]]]]
        try JSONSerialization.data(withJSONObject: chrome).write(to: chromeURL)
        let parsed = try await BookmarkImporter.importChromeBookmarks(from: chromeURL)
        #expect(parsed.first?.title == "Chrome")

        let container = try ModelContainer(for: Bookmark.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let manager = BookmarkManager(modelContext: ModelContext(container))
        async let first = manager.importBookmarks(bookmarks)
        async let second = manager.importBookmarks(bookmarks)
        let counts = try await [first, second]
        #expect(counts.reduce(0, +) == 1_000)
        #expect(manager.fetchAllBookmarks().count == 1_000)
    }
}
