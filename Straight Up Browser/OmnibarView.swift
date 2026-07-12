//
//  OmnibarView.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import AppKit

enum SuggestionType {
    case history
    case bookmark
}

struct Suggestion: Identifiable {
    let id = UUID()
    let url: URL
    let title: String?
    let type: SuggestionType

    init(url: URL, title: String? = nil, type: SuggestionType) {
        self.url = url
        self.title = title
        self.type = type
    }

    init(historyURL: URL) {
        self.url = historyURL
        self.title = nil
        self.type = .history
    }
}

struct OmnibarTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var autoSelectAll: Bool = false
    var shouldFocus: Bool = false
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.placeholderString = placeholder
        textField.stringValue = text
        textField.font = NSFont.systemFont(ofSize: 16)
        textField.isBordered = false
        textField.focusRingType = .none
        textField.backgroundColor = .clear
        textField.delegate = context.coordinator
        context.coordinator.textField = textField
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.stringValue = text

        // Focus and select all text when shouldFocus becomes true (only on initial open)
        if shouldFocus && !context.coordinator.hasFocused {
            DispatchQueue.main.async {
                focusField(nsView, coordinator: context.coordinator, retriesLeft: 3)
            }
        } else if !shouldFocus {
            context.coordinator.hasFocused = false
            context.coordinator.hasAutoSelected = false
        }
    }

    // makeFirstResponder silently fails if the overlay's window isn't key yet,
    // leaving the caret nowhere - retry briefly instead of giving up
    private func focusField(_ nsView: NSTextField, coordinator: Coordinator, retriesLeft: Int) {
        if let window = nsView.window, window.makeFirstResponder(nsView) {
            if autoSelectAll {
                nsView.selectText(nil)
                coordinator.hasAutoSelected = true
            }
            coordinator.hasFocused = true
        } else if retriesLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusField(nsView, coordinator: coordinator, retriesLeft: retriesLeft - 1)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OmnibarTextField
        var hasAutoSelected = false
        var hasFocused = false
        weak var textField: NSTextField?

        init(_ parent: OmnibarTextField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            if let textField = obj.object as? NSTextField {
                if parent.autoSelectAll && !hasAutoSelected {
                    // Select all text when the omnibar first opens
                    textField.selectText(nil)
                    hasAutoSelected = true
                }
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            if let textField = obj.object as? NSTextField {
                parent.text = textField.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onArrowUp?()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onArrowDown?()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommit?()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel?()
                return true
            default:
                return false
            }
        }
    }
}

struct OmnibarView: View {
    @Binding var isPresented: Bool
    @Binding var urlString: String
    var onNavigate: (String) -> Void
    var errorMessage: String?
    var tabs: [Tab]
    var bookmarkSuggestions: [(title: String, url: URL)]

    @State private var inputText: String = ""
    @State private var selectedSuggestionIndex: Int = -1
    @State private var showSuggestions: Bool = false
    @State private var shouldFocusTextField: Bool = false

    // Get all unique URLs from browsing history across all tabs
    private var allHistoryURLs: [URL] {
        var urls = Set<URL>()
        for tab in tabs {
            urls.formUnion(tab.history)
        }
        return Array(urls)
    }

    // Get bookmark URLs
    private var bookmarkURLs: [URL] {
        return bookmarkSuggestions.map { $0.url }
    }

    // Filter suggestions based on input text
    private var filteredSuggestions: [Suggestion] {
        guard !inputText.isEmpty else { return [] }

        let lowercasedInput = inputText.lowercased()

        // Get matching bookmarks
        let matchingBookmarks = bookmarkSuggestions.filter { bookmark in
            let titleMatch = bookmark.title.lowercased().contains(lowercasedInput)
            let urlMatch = bookmark.url.absoluteString.lowercased().contains(lowercasedInput)
            let domainMatch = bookmark.url.host?.lowercased().contains(lowercasedInput) ?? false
            return titleMatch || urlMatch || domainMatch
        }.map { Suggestion(url: $0.url, title: $0.title, type: .bookmark) }

        // Get matching history URLs (excluding bookmarked ones)
        let bookmarkedURLs = Set(bookmarkSuggestions.map { $0.url.absoluteString })
        let matchingHistory = allHistoryURLs.filter { url in
            !bookmarkedURLs.contains(url.absoluteString) &&
            (url.absoluteString.lowercased().contains(lowercasedInput) ||
             (url.host?.lowercased().contains(lowercasedInput) ?? false))
        }.map { Suggestion(historyURL: $0) }

        // Combine and sort: bookmarks first, then history
        let allSuggestions = matchingBookmarks + matchingHistory

        return Array(allSuggestions.sorted { (suggestion1, suggestion2) -> Bool in
            // Bookmarks come first
            if suggestion1.type == SuggestionType.bookmark && suggestion2.type == SuggestionType.history {
                return true
            } else if suggestion1.type == SuggestionType.history && suggestion2.type == SuggestionType.bookmark {
                return false
            }

            // Within same type, sort by relevance
            let url1String = suggestion1.url.absoluteString.lowercased()
            let url2String = suggestion2.url.absoluteString.lowercased()
            let url1Domain = suggestion1.url.host?.lowercased() ?? ""
            let url2Domain = suggestion2.url.host?.lowercased() ?? ""

            let url1StartsWith = url1String.hasPrefix(lowercasedInput) || url1Domain.hasPrefix(lowercasedInput)
            let url2StartsWith = url2String.hasPrefix(lowercasedInput) || url2Domain.hasPrefix(lowercasedInput)

            if url1StartsWith && !url2StartsWith {
                return true
            } else if !url1StartsWith && url2StartsWith {
                return false
            } else {
                // If both start with or both don't, sort by length (shorter first)
                return url1String.count < url2String.count
            }
        }.prefix(8)) // Limit to 8 suggestions
    }

    private var selectedSuggestion: Suggestion? {
        guard selectedSuggestionIndex >= 0 && selectedSuggestionIndex < filteredSuggestions.count else {
            return nil
        }
        return filteredSuggestions[selectedSuggestionIndex]
    }

    var body: some View {
        // Fixed height container to prevent layout shifts when suggestions appear/disappear
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                    .padding(.leading, 12)

                OmnibarTextField(
                    text: $inputText,
                    placeholder: "Search or enter address",
                    autoSelectAll: true,
                    shouldFocus: shouldFocusTextField,
                    onArrowUp: {
                        if selectedSuggestionIndex > 0 {
                            selectedSuggestionIndex -= 1
                        }
                    },
                    onArrowDown: {
                        if selectedSuggestionIndex < filteredSuggestions.count - 1 {
                            selectedSuggestionIndex += 1
                        }
                    },
                    onCommit: {
                        if let selectedSuggestion = selectedSuggestion {
                            inputText = selectedSuggestion.url.absoluteString
                        }
                        navigate()
                    },
                    onCancel: {
                        isPresented = false
                    }
                )
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
                .onChange(of: inputText) { oldValue, newValue in
                    selectedSuggestionIndex = -1
                    showSuggestions = !newValue.isEmpty && !filteredSuggestions.isEmpty
                }

                Button(action: navigate) {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundColor(.blue)
                        .padding(.trailing, 12)
                }
                .buttonStyle(.plain)
            }
            .background(Color(.windowBackgroundColor).opacity(0.95))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 4)
            .padding(.horizontal, 20)
            .padding(.vertical, 20)

            // Suggestions dropdown
            if showSuggestions && !filteredSuggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(filteredSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(suggestion.title ?? suggestion.url.host ?? suggestion.url.absoluteString)
                                        .font(.system(size: 14))
                                        .foregroundColor(.primary)
                                    if suggestion.type == .bookmark {
                                        Image(systemName: "bookmark.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(.blue)
                                    }
                                }
                                Text(suggestion.url.absoluteString)
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(selectedSuggestionIndex == index ? Color.blue.opacity(0.1) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            inputText = suggestion.url.absoluteString
                            navigate()
                        }
                    }
                }
                .background(Color(.windowBackgroundColor).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 4)
                .padding(.horizontal, 20)
                .padding(.top, -8)
            }

            // Error message
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.system(size: 12))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 600, alignment: .top) // Sized to content so the dimmer owns clicks below the bar
        .onAppear {
            inputText = urlString
            shouldFocusTextField = true
        }
    }

    private func navigate() {
        let trimmedText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        var urlString = trimmedText

        // Add https:// if no protocol is specified
        if !urlString.contains("://") {
            // URL-ish: no spaces and either a dot (example.com) or a colon (localhost:3000)
            if !urlString.contains(" ") && (urlString.contains(".") || urlString.contains(":")) {
                urlString = "https://" + urlString
            } else {
                let query = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString
                urlString = searchURLPrefix + query
            }
        }

        onNavigate(urlString)
        isPresented = false
    }

    private var searchURLPrefix: String {
        switch UserDefaults.standard.string(forKey: "searchEngine") {
        case "DuckDuckGo": return "https://duckduckgo.com/?q="
        case "Bing": return "https://www.bing.com/search?q="
        case "Yahoo": return "https://search.yahoo.com/search?p="
        default: return "https://www.google.com/search?q="
        }
    }
}
