//
//  OmnibarView.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import AppKit

// Ordered by how likely it is to be what you meant: a tab already open beats a
// site you go to often, which beats a bookmark, which beats a raw history URL.
enum SuggestionType: Int, Comparable {
    case openTab = 0
    case site
    case bookmark
    case history
    /// "said at 6:57 in <video>" — cross-transcript recall (Phase 2, design §8.3).
    case transcript

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct Suggestion: Identifiable {
    let id = UUID()
    let url: URL
    let title: String?
    let type: SuggestionType
    let tabId: UUID?    // .openTab only: which tab to switch to
    /// Prior encounter from the research ledger ("Rated 4 in Fermentation").
    /// Decorates whichever row you were already going to see rather than adding
    /// a competing one.
    var ledgerNote: String?

    init(url: URL, title: String? = nil, type: SuggestionType, tabId: UUID? = nil) {
        self.url = url
        self.title = title
        self.type = type
        self.tabId = tabId
    }

    init(historyURL: URL) {
        self.url = historyURL
        self.title = nil
        self.type = .history
        self.tabId = nil
    }
}

private struct OmnibarSuggestionLabel: View {
    let suggestion: Suggestion
    /// This page finished loading before you pressed Return.
    var isReady: Bool = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(suggestion.title ?? suggestion.url.host ?? suggestion.url.absoluteString)
                        .font(.system(size: 14))
                        .foregroundColor(.primary)
                    badge
                    if isReady { readyBadge }
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.7), value: isReady)
                if let note = suggestion.ledgerNote {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Text(suggestion.url.absoluteString)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    // Deliberately quiet: it only ever appears when the page really did finish
    // loading ahead of you, so it doubles as proof the head start happened.
    private var readyBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "bolt.fill")
            Text("Ready")
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Color.green.opacity(0.15), in: Capsule())
        .foregroundColor(.green)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    @ViewBuilder
    private var badge: some View {
        switch suggestion.type {
        case .bookmark:
            Image(systemName: "bookmark.fill")
                .font(.system(size: 10))
                .foregroundColor(.blue)
        case .openTab:
            Text("Switch to Tab")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.blue.opacity(0.15), in: Capsule())
                .foregroundColor(.blue)
        case .site:
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        case .history:
            EmptyView()
        case .transcript:
            Image(systemName: "play.circle")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}

private struct OmnibarSuggestionButton: View {
    let suggestion: Suggestion
    let isSelected: Bool
    var isReady: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            OmnibarSuggestionLabel(suggestion: suggestion, isReady: isReady)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(isReady
            ? String(localized: "Ready. \(suggestion.url.absoluteString)")
            : suggestion.url.absoluteString)
        .accessibilityHint(suggestion.tabId == nil ? "Open suggestion" : "Switch to open tab")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityTitle: String {
        suggestion.title ?? suggestion.url.host ?? suggestion.url.absoluteString
    }
}

// How the omnibar's Return key was pressed, so the caller can decide where
// the result should land.
enum OmnibarCommit {
    case navigate       // Return: current tab
    case newTab         // Shift+Return: new tab
    case newSplitPane   // Cmd+Return: new split pane next to the current tab
}

struct OmnibarTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var autoSelectAll: Bool = false
    var shouldFocus: Bool = false
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onCommit: ((OmnibarCommit) -> Void)?
    var onCancel: (() -> Void)?
    var onTab: (() -> Void)?
    // Given what the user just typed, returns the full text to inline-complete to
    // (or nil for no completion). The added suffix is auto-selected.
    var completion: ((String) -> String?)?

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.placeholderString = placeholder
        textField.stringValue = text
        textField.font = NSFont.systemFont(ofSize: 16)
        textField.isBordered = false
        textField.focusRingType = .none
        textField.backgroundColor = .clear
        // Code-created fields default to wrap+clip, so a long URL "paginated"
        // line by line as the caret moved. Single-line + scrollable makes the
        // field editor scroll horizontally like a normal address bar.
        textField.usesSingleLineMode = true
        textField.cell?.isScrollable = true
        textField.cell?.wraps = false
        textField.lineBreakMode = .byClipping
        textField.delegate = context.coordinator
        context.coordinator.textField = textField
        context.coordinator.startMonitoringCommandReturn()
        return textField
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        coordinator.stopMonitoringCommandReturn()
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Guard the assignment so we don't stomp the field editor's selection —
        // inline completion sets stringValue + a selected suffix, and an
        // unconditional write here would collapse the caret to the end.
        if nsView.stringValue != text {
            nsView.stringValue = text
        }

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
        // Set while the current edit is a delete, so we don't re-complete the
        // suffix the user is trying to erase (which would trap them).
        var isDeleting = false
        weak var textField: NSTextField?
        // Modified Return is most reliable at the event level. In particular,
        // NSTextField can clear currentEvent before doCommandBy runs, which made
        // Shift+Return occasionally look like plain Return and switch tabs.
        private var commandReturnMonitor: Any?

        init(_ parent: OmnibarTextField) {
            self.parent = parent
        }

        func startMonitoringCommandReturn() {
            commandReturnMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let textField = self.textField, textField.currentEditor() != nil,
                      event.keyCode == 36 else { // Return
                    return event
                }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if modifiers.contains(.command) {
                    self.parent.onCommit?(.newSplitPane)
                    return nil
                }
                if modifiers.contains(.shift) {
                    self.parent.onCommit?(.newTab)
                    return nil
                }
                return event
            }
        }

        func stopMonitoringCommandReturn() {
            if let commandReturnMonitor {
                NSEvent.removeMonitor(commandReturnMonitor)
            }
            commandReturnMonitor = nil
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
            guard let textField = obj.object as? NSTextField else { return }
            let typed = textField.stringValue

            // A delete just updates the text; never re-complete over it.
            if isDeleting {
                isDeleting = false
                parent.text = typed
                return
            }

            // Inline-complete to the top match and select the added suffix, so the
            // next keystroke replaces it and Return accepts the whole thing.
            // Only when the caret sits at the end of the typed text — editing
            // mid-string after arrowing around must not teleport the caret.
            if let completion = parent.completion?(typed),
               (completion as NSString).length > (typed as NSString).length,
               let editor = textField.currentEditor(),
               editor.selectedRange == NSRange(location: (typed as NSString).length, length: 0) {
                let typedLen = (typed as NSString).length
                editor.string = completion
                editor.selectedRange = NSRange(location: typedLen,
                                               length: (completion as NSString).length - typedLen)
                parent.text = completion
            } else {
                parent.text = typed
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.deleteBackward(_:)),
                 #selector(NSResponder.deleteForward(_:)),
                 #selector(NSResponder.deleteWordBackward(_:)),
                 #selector(NSResponder.deleteWordForward(_:)),
                 #selector(NSResponder.deleteToBeginningOfLine(_:)),
                 #selector(NSResponder.deleteToEndOfLine(_:)):
                isDeleting = true
                return false // let the default delete happen, sans re-completion
            case #selector(NSResponder.moveUp(_:)):
                parent.onArrowUp?()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onArrowDown?()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                parent.onCommit?(shift ? .newTab : .navigate)
                return true
            case #selector(NSResponder.insertTab(_:)),
                 #selector(NSResponder.insertBacktab(_:)):
                // Consumed so Tab toggles history search instead of walking the
                // key-view loop out of the omnibar.
                parent.onTab?()
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
    /// Looks a URL up in the research ledger. Nil result = never seen.
    var ledgerNote: ((URL) -> String?)? = nil
    /// Cross-transcript search: "said at 6:57 in <video>" rows for the typed
    /// text, opening the video seeked. A new suggestion SOURCE — Phase 1's
    /// single ledgerNote decoration point is unchanged.
    var transcriptHits: ((String) -> [Suggestion])? = nil
    @Binding var isPresented: Bool
    @Binding var urlString: String
    var onNavigate: (String, OmnibarCommit) -> Void
    var errorMessage: String?
    var tabs: [Tab]
    var bookmarkSuggestions: [(title: String, url: URL)]
    var currentTabId: UUID? = nil
    var onSwitchToTab: ((UUID) -> Void)? = nil
    var thumbnail: ((UUID) -> NSImage?)? = nil
    var pageProtection: PageProtectionSummary? = nil
    /// Shown above the field when a workspace document owns focus — the omnibar
    /// then names the document rather than implying a page (Phase 2 deviation #9).
    var focusedDocumentName: String? = nil

    // Below this, a match is too weak to hijack a plain Return into a tab switch —
    // you can still arrow onto the suggestion at any length.
    private static let switchOnReturnMinLength = 3

    @State private var inputText: String = ""
    @State private var selectedSuggestionIndex: Int = -1
    @State private var shouldFocusTextField: Bool = false
    // Tab flips the omnibar into searching everywhere you've been instead of
    // guessing where you're going.
    @State private var historyMode: Bool = false

    @ObservedObject private var prefetcher = Prefetcher.shared

    private var showSuggestions: Bool {
        (historyMode || !inputText.isEmpty) && !filteredSuggestions.isEmpty
    }

    // All unique history URLs, computed once when the omnibar opens - not per
    // keystroke, which scanned every tab's full history on each character
    @State private var allHistoryURLs: [URL] = []

    private func loadHistoryURLs() {
        var urls = Set<URL>()
        for tab in tabs {
            urls.formUnion(tab.history)
        }
        allHistoryURLs = Array(urls)
    }

    // What prefetch needs to know about the current window: never guess a page
    // that's already open, and never prefetch out of a private session (the hidden
    // prefetch view browses the shared store).
    private var openURLs: Set<URL> {
        Set(tabs.compactMap { Tab.normalizeURLForComparison($0.url) })
    }

    private var activeSession: SessionKind {
        tabs.first { $0.id == currentTabId }?.sessionKind ?? .normal
    }

    // Get bookmark URLs
    private var bookmarkURLs: [URL] {
        return bookmarkSuggestions.map { $0.url }
    }

    // Tabs already open that match what's being typed — ranked by how well the
    // typed text starts their host/title, best first. The tab you're already
    // looking at is never a suggestion.
    private var openTabSuggestions: [Suggestion] {
        typealias Ranked = (suggestion: Suggestion, rank: Double, used: Date)
        let ranked: [Ranked] = tabs.compactMap { tab -> Ranked? in
            guard tab.id != currentTabId, let url = tab.url,
                  let host = SiteHistory.normalizedHost(url) else { return nil }
            // A restored tab's title is just its domain, so fold in the last real page
            // title we saw for that host — that's where "Gmail" lives — plus whatever
            // nicknames the site has earned.
            let known = SiteHistory.shared.sites[host]
            guard let rank = SiteHistory.matchRank(host: host,
                                                   title: tab.title + " " + (known?.title ?? ""),
                                                   aliases: known?.nicknames ?? [],
                                                   query: inputText) else { return nil }
            let suggestion = Suggestion(url: url, title: tab.title, type: .openTab, tabId: tab.id)
            return (suggestion, rank, tab.lastAccessed)
        }
        // Equally good matches (four "…google.com" tabs) order by the one you used
        // last, so Return lands on the live one rather than a stale sign-in page.
        return ranked
            .sorted { $0.rank == $1.rank ? $0.used > $1.used : $0.rank > $1.rank }
            .map(\.suggestion)
    }

    /// Every suggestion, decorated with any prior encounter in the research
    /// ledger. One decoration point, so no suggestion source can forget it.
    private var filteredSuggestions: [Suggestion] {
        guard let ledgerNote else { return undecoratedSuggestions }
        return undecoratedSuggestions.map { suggestion in
            var decorated = suggestion
            decorated.ledgerNote = ledgerNote(suggestion.url)
            return decorated
        }
    }

    // Filter suggestions based on input text
    private var undecoratedSuggestions: [Suggestion] {
        if historyMode {
            return BrowsingHistoryStore.shared.search(inputText).map {
                Suggestion(url: $0.url, title: $0.title, type: .history)
            }
        }
        guard !inputText.isEmpty else { return [] }

        let lowercasedInput = inputText.lowercased()

        let openTabs = openTabSuggestions
        let openHosts = Set(openTabs.compactMap { SiteHistory.normalizedHost($0.url) })

        // Sites visited often enough to have earned a nickname. Already-open ones
        // are dropped — the tab suggestion above says the same thing, better.
        let frequentSites = SiteHistory.shared.matches(inputText).compactMap { site -> Suggestion? in
            guard !openHosts.contains(site.host), let url = site.url else { return nil }
            return Suggestion(url: url, title: site.host, type: .site)
        }

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

        // Open tabs and frequent sites are already ranked; bookmarks and raw history
        // sort among themselves and fill in behind them.
        let rest = (matchingBookmarks + matchingHistory).sorted { (suggestion1, suggestion2) -> Bool in
            // Bookmarks come first
            if suggestion1.type != suggestion2.type {
                return suggestion1.type < suggestion2.type
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
        }

        let ranked = Array((openTabs + frequentSites + rest).prefix(8)) // Limit to 8 suggestions
        // Transcript recall rows ride BELOW the ranked list (at most 2), so they
        // can never displace a URL you were typing toward.
        return ranked + (transcriptHits?(inputText) ?? [])
    }

    // The open tab a plain Return should switch to, if any: whatever is arrowed to,
    // else the top suggestion once enough has been typed to be sure.
    private var switchTarget: Suggestion? {
        if let selected = selectedSuggestion {
            return selected.type == .openTab ? selected : nil
        }
        guard inputText.count >= Self.switchOnReturnMinLength,
              let top = filteredSuggestions.first, top.type == .openTab else { return nil }
        return top
    }

    // Inline autocomplete target: the top prefix match, as a bare host where
    // possible ("git" → "github.com"), else the full URL. nil when nothing the
    // user could mean starts with what they typed (e.g. a multi-word search).
    private func bestCompletion(for typed: String) -> String? {
        let t = typed.lowercased()
        guard !t.isEmpty, !t.contains(" "), !t.contains("://") else { return nil }
        for s in filteredSuggestions {
            if let host = s.url.host {
                let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                if bare.lowercased().hasPrefix(t) { return bare }
                if host.lowercased().hasPrefix(t) { return host }
            }
            let full = s.url.absoluteString
            if full.lowercased().hasPrefix(t) { return full }
        }
        return nil
    }

    // History search always has a row armed, so Return takes the top hit without
    // arrowing to it first.
    private var effectiveSelectionIndex: Int {
        if selectedSuggestionIndex >= 0 { return selectedSuggestionIndex }
        return historyMode && !filteredSuggestions.isEmpty ? 0 : -1
    }

    private var selectedSuggestion: Suggestion? {
        let index = effectiveSelectionIndex
        guard index >= 0 && index < filteredSuggestions.count else { return nil }
        return filteredSuggestions[index]
    }

    var body: some View {
        // Fixed height container to prevent layout shifts when suggestions appear/disappear
        VStack(spacing: 0) {
            if let focusedDocumentName {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                    Text(focusedDocumentName)
                        .lineLimit(1)
                    Spacer()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 32)
                .padding(.bottom, 4)
            }
            HStack {
                if let pageProtection {
                    PageProtectionButton(summary: pageProtection)
                        .padding(.leading, 12)
                }

                Image(systemName: historyMode ? "clock.arrow.circlepath" : "magnifyingglass")
                    .foregroundColor(historyMode ? .blue : .gray)
                    .padding(.leading, pageProtection == nil ? 12 : 0)

                if historyMode {
                    Text("History")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15), in: Capsule())
                        .foregroundColor(.blue)
                }

                OmnibarTextField(
                    text: $inputText,
                    placeholder: historyMode
                        ? String(localized: "Search your history")
                        : String(localized: "Search or enter address"),
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
                    onCommit: { commit in
                        // Return on a site you already have open switches to that tab
                        // instead of opening a second copy. Shift/Cmd+Return still
                        // force a new tab / split pane.
                        if commit == .navigate, let tabId = switchTarget?.tabId {
                            onSwitchToTab?(tabId)
                            isPresented = false
                            return
                        }
                        if let selectedSuggestion = selectedSuggestion {
                            inputText = selectedSuggestion.url.absoluteString
                        }
                        navigate(commit)
                    },
                    onCancel: {
                        isPresented = false
                    },
                    onTab: {
                        // The omnibar opens pre-filled with the current URL; that's a
                        // terrible history query, so drop it if it's untouched.
                        if !historyMode && inputText == urlString { inputText = "" }
                        historyMode.toggle()
                    },
                    // Inline completion fights fuzzy matching — off in history mode.
                    completion: { historyMode ? nil : bestCompletion(for: $0) }
                )
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
                .onChange(of: inputText) { _, typed in
                    selectedSuggestionIndex = -1
                    Prefetcher.shared.consider(
                        filteredSuggestions,
                        typed: typed,
                        openURLs: openURLs,
                        session: activeSession
                    )
                }

                Button(action: { navigate() }) {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundColor(.blue)
                        .padding(.trailing, 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Go")
                .accessibilityHint("Open the entered address or search")
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

            // Card preview of the tab Return would jump to, so you can see it's the
            // one you meant before committing.
            if let target = switchTarget, let tabId = target.tabId {
                HStack(spacing: 12) {
                    Group {
                        if let image = thumbnail?(tabId) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "macwindow")
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color.gray.opacity(0.12))
                        }
                    }
                    .frame(width: 120, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(target.title ?? target.url.host ?? "")
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Text(target.url.absoluteString)
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                            .lineLimit(1)
                        Text("Return to switch · ⇧Return for a new tab")
                            .font(.system(size: 11))
                            .foregroundColor(.blue)
                    }
                    Spacer()
                }
                .padding(10)
                .background(Color(.windowBackgroundColor).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.blue.opacity(0.4), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 4)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .padding(.top, -8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Open tab: \(target.title ?? target.url.host ?? target.url.absoluteString)")
                .accessibilityHint("Press Return to switch to this tab")
            }

            // Suggestions dropdown
            if showSuggestions && !filteredSuggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(filteredSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                        OmnibarSuggestionButton(
                            suggestion: suggestion,
                            isSelected: effectiveSelectionIndex == index,
                            isReady: suggestion.url == prefetcher.readyURL
                        ) {
                            if let tabId = suggestion.tabId {
                                onSwitchToTab?(tabId)
                                isPresented = false
                            } else {
                                inputText = suggestion.url.absoluteString
                                navigate()
                            }
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
        .onChange(of: historyMode) { _, _ in
            selectedSuggestionIndex = -1
        }
        .onAppear {
            inputText = urlString
            shouldFocusTextField = true
            loadHistoryURLs()
            Prefetcher.shared.prime()
        }
        .onDisappear {
            Prefetcher.shared.cancel()
        }
    }

    private func navigate(_ commit: OmnibarCommit = .navigate) {
        let trimmedText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        var urlString = trimmedText

        // Add https:// if no protocol is specified
        if !urlString.contains("://") {
            // URL-ish: no spaces and either a dot (example.com) or a colon (localhost:3000)
            if !urlString.contains(" ") && (urlString.contains(".") || urlString.contains(":")) {
                urlString = "https://" + urlString
            } else if let habit = SiteHistory.shared.habit(for: urlString), let habitURL = habit.url {
                // A bare word you've been going to for months isn't a search: "woot"
                // means woot.com, "gmail" means mail.google.com.
                urlString = habitURL.absoluteString
            } else {
                let query = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString
                urlString = searchURLPrefix + query
            }
        }

        // A prefetch of this very page should finish — stopping it mid-flight would
        // throw away the head start. A guess at anywhere else gets dropped.
        Prefetcher.shared.committed(to: urlString)
        onNavigate(urlString, commit)
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
