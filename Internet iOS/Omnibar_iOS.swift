//
//  Omnibar_iOS.swift
//  Internet (iPadOS)
//
//  The iPad omnibar: an always-visible address/search field in the toolbar
//  (⌘L focuses it) plus a suggestions panel drawn under it. The input-resolution
//  and suggestion-ranking logic mirrors the Mac OmnibarView; the AppKit
//  NSTextField chrome is replaced by a native SwiftUI TextField in BrowserView.
//

import SwiftUI

enum SuggestionType {
    case history
    case bookmark
}

struct Suggestion: Identifiable {
    let id = UUID()
    let url: URL
    let title: String?
    let type: SuggestionType
}

// Turns raw omnibar text into a loadable URL string: adds https:// to a bare
// domain, otherwise sends it to the configured search engine. Pure + testable.
enum OmnibarInput {
    static func searchURLPrefix(_ engine: String?) -> String {
        switch engine {
        case "DuckDuckGo": return "https://duckduckgo.com/?q="
        case "Bing":       return "https://www.bing.com/search?q="
        case "Yahoo":      return "https://search.yahoo.com/search?p="
        default:           return "https://www.google.com/search?q="
        }
    }

    /// Resolve trimmed omnibar text to a URL string, or nil if empty.
    static func resolve(_ text: String, searchEngine: String? = UserDefaults.standard.string(forKey: "searchEngine")) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return trimmed }
        // URL-ish: no spaces and either a dot (example.com) or a colon (localhost:3000)
        if !trimmed.contains(" ") && (trimmed.contains(".") || trimmed.contains(":")) {
            return "https://" + trimmed
        }
        let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        return searchURLPrefix(searchEngine) + query
    }

    #if DEBUG
    // ponytail: one runnable check for the branch logic; called at DEBUG launch.
    static func selfCheck() {
        assert(resolve("", searchEngine: nil) == nil)
        assert(resolve("  ", searchEngine: nil) == nil)
        assert(resolve("example.com", searchEngine: nil) == "https://example.com")
        assert(resolve("localhost:3000", searchEngine: nil) == "https://localhost:3000")
        assert(resolve("https://a.b/c", searchEngine: nil) == "https://a.b/c")
        assert(resolve("hello world", searchEngine: "DuckDuckGo") == "https://duckduckgo.com/?q=hello%20world")
        assert(resolve("swift", searchEngine: nil) == "https://www.google.com/search?q=swift")
    }
    #endif
}

// Ranked history + bookmark matches for the current omnibar text (ported from
// the Mac OmnibarView.filteredSuggestions).
func omnibarSuggestions(input: String, tabs: [Tab], bookmarks: [(title: String, url: URL)]) -> [Suggestion] {
    let lowercased = input.lowercased()
    guard !lowercased.isEmpty else { return [] }

    let matchingBookmarks = bookmarks.filter {
        $0.title.lowercased().contains(lowercased)
            || $0.url.absoluteString.lowercased().contains(lowercased)
            || ($0.url.host?.lowercased().contains(lowercased) ?? false)
    }.map { Suggestion(url: $0.url, title: $0.title, type: .bookmark) }

    let bookmarkedURLs = Set(bookmarks.map { $0.url.absoluteString })
    var historyURLs = Set<URL>()
    for tab in tabs { historyURLs.formUnion(tab.history) }
    let matchingHistory = historyURLs.filter { url in
        !bookmarkedURLs.contains(url.absoluteString)
            && (url.absoluteString.lowercased().contains(lowercased)
                || (url.host?.lowercased().contains(lowercased) ?? false))
    }.map { Suggestion(url: $0, title: nil, type: .history) }

    let all = matchingBookmarks + matchingHistory
    return Array(all.sorted { a, b in
        if a.type == .bookmark && b.type == .history { return true }
        if a.type == .history && b.type == .bookmark { return false }
        let aStr = a.url.absoluteString.lowercased(), bStr = b.url.absoluteString.lowercased()
        let aStarts = aStr.hasPrefix(lowercased) || (a.url.host?.lowercased().hasPrefix(lowercased) ?? false)
        let bStarts = bStr.hasPrefix(lowercased) || (b.url.host?.lowercased().hasPrefix(lowercased) ?? false)
        if aStarts != bStarts { return aStarts }
        return aStr.count < bStr.count
    }.prefix(8))
}

// The dropdown under the omnibar field. Selection is keyboard-navigable
// (↑/↓ move `selectedIndex`, Return commits) and tap-selectable.
struct SuggestionsPanel: View {
    let suggestions: [Suggestion]
    let selectedIndex: Int
    let onPick: (Suggestion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button { onPick(suggestion) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: suggestion.type == .bookmark ? "bookmark.fill" : "clock.arrow.circlepath")
                            .font(.system(size: 12))
                            .foregroundStyle(suggestion.type == .bookmark ? Color.accentColor : .secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.title ?? suggestion.url.host ?? suggestion.url.absoluteString)
                                .font(.system(size: 15))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(suggestion.url.absoluteString)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == selectedIndex ? Color.accentColor.opacity(0.15) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
    }
}
