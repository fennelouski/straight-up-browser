import Foundation

nonisolated enum SuggestionType: Sendable {
    case openTab
    case history
    case bookmark
    /// "said at 6:57 in <video>" — cross-transcript recall (Phase 2, design §8.3).
    case transcript
}

nonisolated struct Suggestion: Identifiable, Sendable {
    var id: String { MobileChromeLayout.canonicalURL(url) }
    let url: URL
    let title: String?
    let type: SuggestionType
    /// Prior encounter from the research ledger ("Rated 4 in Fermentation").
    var ledgerNote: String?
}

nonisolated struct MobileOpenTabSuggestion: Sendable {
    let url: URL
    let title: String
    let lastAccessed: Date
    var isPrivate = false
}

/// Pure local ranking. Remote records can only arrive through existing opted-in
/// same-user CloudKit sync. This function performs no networking or persistence.
@concurrent func omnibarSuggestions(
    input: String,
    tabHistory: [[String]],
    bookmarks: [(title: String, url: URL)],
    durableHistory: [HistoryVisit] = [],
    openTabs: [MobileOpenTabSuggestion] = [],
    now: Date = Date()
) async -> [Suggestion] {
    let query = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty, !Task.isCancelled else { return [] }
    var records: [String: (suggestion: Suggestion, score: Double)] = [:]
    func insert(_ url: URL, title: String?, type: SuggestionType, recency: Date? = nil, frequency: Int = 0) {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return }
        let text = url.absoluteString.lowercased(), host = url.host?.lowercased() ?? ""
        guard text.contains(query) || (title?.lowercased().contains(query) ?? false) else { return }
        let prefix = host.hasPrefix(query) || text.hasPrefix(query)
        let kind = type == .bookmark ? 3000.0 : (type == .openTab ? 2000 : 0)
        let age = recency.map { max(0, now.timeIntervalSince($0)) / 86400 } ?? 365
        let score = kind + (prefix ? 1000 : 0) + max(0, 200 - age * 5) + Double(min(20, frequency)) * 3
        let key = MobileChromeLayout.canonicalURL(url)
        if let old = records[key], old.score >= score { return }
        records[key] = (Suggestion(url: url, title: title, type: type), score)
    }
    for bookmark in bookmarks {
        if Task.isCancelled { return [] }
        insert(bookmark.url, title: bookmark.title, type: .bookmark)
    }
    for tab in openTabs where !tab.isPrivate {
        if Task.isCancelled { return [] }
        insert(tab.url, title: tab.title, type: .openTab, recency: tab.lastAccessed)
    }
    var frequencies: [String: Int] = [:]
    for visit in durableHistory {
        if Task.isCancelled { return [] }
        frequencies[MobileChromeLayout.canonicalURL(visit.url), default: 0] += 1
    }
    for visit in durableHistory {
        if Task.isCancelled { return [] }
        insert(visit.url, title: visit.title, type: .history, recency: visit.visitedAt,
               frequency: frequencies[MobileChromeLayout.canonicalURL(visit.url)] ?? 0)
    }
    for history in tabHistory {
        for raw in history {
            if Task.isCancelled { return [] }
            if let url = URL(string: raw) { insert(url, title: nil, type: .history) }
        }
    }
    let ranked = records.values.sorted {
        if $0.score != $1.score { return $0.score > $1.score }
        let a = $0.suggestion.id, b = $1.suggestion.id
        return a.count != b.count ? a.count < b.count : a < b
    }.prefix(8).map(\.suggestion)
    return Task.isCancelled ? [] : ranked
}
