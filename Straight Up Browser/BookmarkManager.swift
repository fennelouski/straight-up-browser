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

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - CRUD Operations

    func addBookmark(title: String, url: URL, category: String? = nil) -> Bookmark {
        let bookmark = Bookmark(title: title, url: url, category: category)
        modelContext.insert(bookmark)
        try? modelContext.save()
        return bookmark
    }

    func addBookmark(from tab: Tab) -> Bookmark? {
        guard let url = tab.url else { return nil }
        let title = tab.title.isEmpty ? Tab.extractDomain(from: tab.url) : tab.title
        return addBookmark(title: title, url: url)
    }

    func removeBookmark(_ bookmark: Bookmark) {
        modelContext.delete(bookmark)
        try? modelContext.save()
    }

    func updateBookmark(_ bookmark: Bookmark, title: String? = nil, url: URL? = nil, category: String? = nil) {
        if let title = title {
            bookmark.title = title
        }
        if let url = url {
            bookmark.url = url
        }
        if let category = category {
            bookmark.category = category
        }
        bookmark.lastVisited = Date()
        try? modelContext.save()
    }

    // MARK: - Query Operations

    func fetchAllBookmarks() -> [Bookmark] {
        let descriptor = FetchDescriptor<Bookmark>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? modelContext.fetch(descriptor)) ?? []
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
}