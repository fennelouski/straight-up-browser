//
//  BookmarkManager.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import Foundation
import SwiftData

class BookmarkManager {
    private let modelContext: ModelContext
    private var importTask: Task<Int, Error>?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - CRUD Operations

    func addBookmark(title: String, url: URL, category: String? = nil) -> Bookmark {
        let bookmark = Bookmark(title: title, url: url, category: category)
        modelContext.insert(bookmark)
        save("Save bookmark")
        return bookmark
    }

    func addBookmark(from tab: Tab) -> Bookmark? {
        guard let url = tab.url else { return nil }
        let title = tab.title.isEmpty ? Tab.extractDomain(from: tab.url) : tab.title
        return addBookmark(title: title, url: url)
    }

    func removeBookmark(_ bookmark: Bookmark) {
        modelContext.delete(bookmark)
        save("Remove bookmark")
    }

    func updateBookmark(_ bookmark: Bookmark, title: String, url: URL, category: String?) {
        bookmark.title = title
        bookmark.url = url
        bookmark.category = category
        bookmark.lastVisited = Date()
        save("Update bookmark")
    }

    // MARK: - Query Operations

    func fetchAllBookmarks() -> [Bookmark] {
        let descriptor = FetchDescriptor<Bookmark>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            PersistenceDiagnostics.shared.report(operation: "Load bookmarks", error: error)
            return []
        }
    }

    func fetchBookmarks(matching query: String) -> [Bookmark] {
        let allBookmarks = fetchAllBookmarks()
        let lowercasedQuery = query.lowercased()

        return allBookmarks.filter { bookmark in
            bookmark.title.lowercased().contains(lowercasedQuery) ||
            bookmark.url.absoluteString.lowercased().contains(lowercasedQuery) ||
            (bookmark.url.host?.lowercased().contains(lowercasedQuery) ?? false)
        }
    }

    func isBookmarked(_ url: URL) -> Bool {
        let allBookmarks = fetchAllBookmarks()
        return allBookmarks.contains { $0.url.absoluteString == url.absoluteString }
    }

    /// Imports are serialized, with bounded saves and a yield between batches.
    func importBookmarks(_ items: [(title: String, url: URL)]) async throws -> Int {
        try await importBookmarks(items.map { ImportedLibraryBookmark(title: $0.title, url: $0.url, category: nil) })
    }

    func importBookmarks(_ items: [ImportedLibraryBookmark]) async throws -> Int {
        let previous = importTask
        let task = Task {
            _ = try? await previous?.value
            var existing = Set(fetchAllBookmarks().map { $0.url.absoluteString })
            var added = 0
            var pending = 0
            for (index, item) in items.enumerated() {
                if existing.insert(item.url.absoluteString).inserted {
                    modelContext.insert(Bookmark(title: item.title, url: item.url, category: item.category))
                    pending += 1
                }
                if index % 100 == 99 {
                    try saveImportBatch()
                    added += pending
                    pending = 0
                    await Task.yield()
                }
            }
            try saveImportBatch()
            return added + pending
        }
        importTask = task
        return try await task.value
    }

    private func saveImportBatch() throws {
        do { try modelContext.save() }
        catch {
            modelContext.rollback()
            PersistenceDiagnostics.shared.report(operation: "Import bookmarks", error: error)
            throw error
        }
    }

    @discardableResult
    private func save(_ operation: String) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            PersistenceDiagnostics.shared.report(operation: operation, error: error)
            return false
        }
    }
}
