//
//  OmnibarView.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import AppKit
import Combine

// Ordered by how likely it is to be what you meant: a tab already open beats a
// site you go to often, which beats a bookmark, which beats a raw history URL.
nonisolated enum SuggestionType: Int, Comparable, Sendable {
    case openTab = 0
    case site
    case bookmark
    case history
    /// "said at 6:57 in <video>" — cross-transcript recall (Phase 2, design §8.3).
    case transcript

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

nonisolated struct Suggestion: Identifiable, Equatable, Sendable {
    var id: String { "\(type.rawValue):\(tabId?.uuidString ?? ""):\(url.absoluteString)" }
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
        coordinator.parent.shouldFocus = false
        coordinator.stopMonitoringCommandReturn()
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Do not touch the field editor when a render merely echoes its text.
        if nsView.stringValue != text {
            nsView.stringValue = text
        }

        // Focus and select all text when shouldFocus becomes true (only on initial open)
        if shouldFocus && !context.coordinator.hasFocused && !context.coordinator.focusPending {
            context.coordinator.focusPending = true
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
        guard coordinator.parent.shouldFocus else {
            coordinator.focusPending = false
            return
        }
        if let window = nsView.window, window.makeFirstResponder(nsView) {
            if autoSelectAll {
                nsView.selectText(nil)
                coordinator.hasAutoSelected = true
            }
            coordinator.hasFocused = true
            coordinator.focusPending = false
        } else if retriesLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusField(nsView, coordinator: coordinator, retriesLeft: retriesLeft - 1)
            }
        } else {
            coordinator.focusPending = false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OmnibarTextField
        var hasAutoSelected = false
        var hasFocused = false
        var focusPending = false
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
            // AppKit owns the text, caret, selection, undo, and marked text.
            // Suggestions must never rewrite the field from this callback.
            if parent.text != textField.stringValue {
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
    var transcriptHits: ((String) async -> [Suggestion])? = nil
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

    @State private var readyURL: URL?

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

    @StateObject private var suggestions = OmnibarSuggestionUpdates()

    private var filteredSuggestions: [Suggestion] {
        suggestions.results(for: inputText, historyMode: historyMode)
    }

    private func pollSuggestions() {
        suggestions.poll(query: inputText, historyMode: historyMode) {
            let snapshot = OmnibarSuggestionSnapshot(
                inputText: inputText, historyMode: historyMode,
                tabs: tabs.map { .init(id: $0.id, url: $0.url, title: $0.title, lastAccessed: $0.lastAccessed) },
                currentTabId: currentTabId, sites: SiteHistory.shared.sites,
                bookmarkSuggestions: bookmarkSuggestions, allHistoryURLs: allHistoryURLs,
                visits: BrowsingHistoryStore.shared.visits
            )
            return Task { @MainActor in
                let worker = Task.detached(priority: .utility) { snapshot.undecoratedSuggestions }
                var result = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return [] }
                if !snapshot.historyMode {
                    result += await transcriptHits?(snapshot.inputText) ?? []
                }
                var seen: Set<String> = []
                result = result.filter { seen.insert($0.id).inserted }
                for index in result.indices {
                    guard !Task.isCancelled else { return [] }
                    result[index].ledgerNote = ledgerNote?(result[index].url) ?? result[index].ledgerNote
                    await Task.yield()
                }
                return result
            }
        }
        Prefetcher.shared.consider(filteredSuggestions, typed: inputText,
                                   openURLs: openURLs, session: activeSession)
        if readyURL != Prefetcher.shared.readyURL { readyURL = Prefetcher.shared.readyURL }
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
                    }
                )
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
                .onChange(of: inputText) { _, typed in
                    selectedSuggestionIndex = -1

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
                            isReady: suggestion.url == readyURL
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
        .frame(minWidth: 0, idealWidth: 600, maxWidth: 600, alignment: .top)
        .onChange(of: historyMode) { _, _ in
            selectedSuggestionIndex = -1
        }
        .onAppear {
            inputText = urlString
            shouldFocusTextField = true
            loadHistoryURLs()
            Prefetcher.shared.prime()
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
                pollSuggestions()
            }
        }
        .onDisappear {
            suggestions.cancel()
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
                urlString = NavigationManager.searchURL(for: urlString)
            }
        }

        // A prefetch of this very page should finish — stopping it mid-flight would
        // throw away the head start. A guess at anywhere else gets dropped.
        Prefetcher.shared.committed(to: urlString)
        onNavigate(urlString, commit)
        isPresented = false
    }

}

/// Only value snapshots cross to the background worker; SwiftData tabs and stores
/// remain on the main actor.
nonisolated struct OmnibarSuggestionSnapshot: Sendable {
    struct OpenTab: Sendable {
        let id: UUID
        let url: URL?
        let title: String
        let lastAccessed: Date
    }
    let inputText: String
    let historyMode: Bool
    let tabs: [OpenTab]
    let currentTabId: UUID?
    let sites: [String: SiteVisit]
    let bookmarkSuggestions: [(title: String, url: URL)]
    let allHistoryURLs: [URL]
    let visits: [HistoryVisit]

    // Tabs already open that match what's being typed — ranked by how well the
    // typed text starts their host/title, best first. The tab you're already
    // looking at is never a suggestion.
    var openTabSuggestions: [Suggestion] {
        typealias Ranked = (suggestion: Suggestion, rank: Double, used: Date)
        let ranked: [Ranked] = tabs.compactMap { tab -> Ranked? in
            guard tab.id != currentTabId, let url = tab.url,
                  let host = SiteHistory.normalizedHost(url) else { return nil }
            // A restored tab's title is just its domain, so fold in the last real page
            // title we saw for that host — that's where "Gmail" lives — plus whatever
            // nicknames the site has earned.
            let known = sites[host]
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

    // Filter suggestions based on input text
    var undecoratedSuggestions: [Suggestion] {
        guard !Task.isCancelled else { return [] }
        if historyMode {
            return BrowsingHistoryStore.search(inputText, visits: visits).map {
                Suggestion(url: $0.url, title: $0.title, type: .history)
            }
        }
        guard !inputText.isEmpty else { return [] }

        let lowercasedInput = inputText.lowercased()

        let openTabs = openTabSuggestions
        let openHosts = Set(openTabs.compactMap { SiteHistory.normalizedHost($0.url) })

        // Sites visited often enough to have earned a nickname. Already-open ones
        // are dropped — the tab suggestion above says the same thing, better.
        let matches = sites.values.compactMap { site in
            SiteHistory.score(site, query: inputText).map { (site, $0) }
        }.sorted { $0.1 > $1.1 }.prefix(5).map(\.0)
        let frequentSites = matches.compactMap { site -> Suggestion? in
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
        return ranked
    }

}

/// A mailbox, polled by the view. Finishing work does not invalidate SwiftUI.
@MainActor
final class OmnibarSuggestionUpdates: ObservableObject {
    struct Request: Equatable {
        let query: String
        let historyMode: Bool
    }
    @Published private var published: [Suggestion] = []
    private var publishedRequest: Request?
    private var requested: Request?
    private var pending: (Request, [Suggestion])?
    private var task: Task<Void, Never>?

    func results(for query: String, historyMode: Bool) -> [Suggestion] {
        publishedRequest == Request(query: query, historyMode: historyMode) ? published : []
    }

    func poll(query: String, historyMode: Bool,
              start: () -> Task<[Suggestion], Never>) {
        let request = Request(query: query, historyMode: historyMode)
        if let (finished, values) = pending {
            pending = nil
            if finished == request {
                publishedRequest = finished
                if published != values { published = values }
                else { objectWillChange.send() }
            }
        }
        guard requested != request else { return }
        task?.cancel()
        requested = request
        let worker = start()
        task = Task { [weak self] in
            let values = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            self?.pending = (request, values)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
        requested = nil
    }
}
