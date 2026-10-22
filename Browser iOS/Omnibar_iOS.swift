//
//  Omnibar_iOS.swift
//  Browser (iPadOS)
//
//  The iPad omnibar: an always-visible address/search field in the toolbar
//  (⌘L focuses it) plus a suggestions panel drawn under it. The input-resolution
//  and suggestion-ranking logic mirrors the Mac OmnibarView; the AppKit
//  NSTextField chrome is replaced by a native SwiftUI TextField in BrowserView.
//

import SwiftUI

// Turns raw omnibar text into a loadable URL string: adds https:// to a bare
// domain, otherwise sends it to the configured search engine. Pure + testable.
enum OmnibarInput {
    /// Resolve trimmed omnibar text to a URL string, or nil if empty.
    static func resolve(_ text: String, searchEngine: String? = BrowserProfile.defaults.string(forKey: "searchEngine")) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return trimmed }
        // URL-ish: no spaces and either a dot (example.com) or a colon (localhost:3000)
        if !trimmed.contains(" ") && (trimmed.contains(".") || trimmed.contains(":")) {
            return "https://" + trimmed
        }
        return NavigationManager.searchURL(for: trimmed, engine: searchEngine)
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

// The dropdown under the omnibar field. Selection is keyboard-navigable
// (↑/↓ move `selectedIndex`, Return commits) and tap-selectable.
struct SuggestionsPanel: View {
    let suggestions: [Suggestion]
    let selectedIndex: Int
    let onPick: (Suggestion) -> Void

    private func suggestionIcon(_ type: SuggestionType) -> String {
        switch type {
        case .bookmark: "bookmark.fill"
        case .openTab: "square.on.square"
        case .history: "clock.arrow.circlepath"
        case .transcript: "play.circle"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button { onPick(suggestion) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: suggestionIcon(suggestion.type))
                            .font(.system(size: 12))
                            .foregroundStyle(suggestion.type == .bookmark ? Color.accentColor : .secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.title ?? suggestion.url.host ?? suggestion.url.absoluteString)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if let note = suggestion.ledgerNote {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text(suggestion.url.absoluteString)
                                .font(.caption)
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
                .accessibilityLabel(suggestion.title ?? suggestion.url.host ?? suggestion.url.absoluteString)
                .accessibilityValue(suggestion.url.absoluteString)
                .accessibilityHint("Open suggestion")
                .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
    }
}
