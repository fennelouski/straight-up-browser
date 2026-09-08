import AppKit
import SwiftUI
import Testing
@testable import Browser

@MainActor
struct OmnibarEditingTests {
    @Test func editingPublishesExactlyWhatAppKitContains() {
        var text = "https://example.com/path"
        var writes = 0
        let field = OmnibarTextField(text: Binding(get: { text }, set: { text = $0; writes += 1 }), placeholder: "")
        let coordinator = field.makeCoordinator()
        let native = NSTextField()
        for edit in ["https://example.com/p", "https://example.com/", "https://example.com/new?x=🙂", "", "git"] {
            native.stringValue = edit
            coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: native))
            #expect(text == edit)
            #expect(native.stringValue == edit)
        }
        #expect(writes == 5)
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: native))
        #expect(writes == 5)
    }

    @Test func resultsOnlyPublishWhenPolledAndNeverMatchStaleText() async throws {
        let updates = OmnibarSuggestionUpdates()
        let suggestion = Suggestion(url: URL(string: "https://example.com")!, type: .site)
        var starts = 0
        func poll(_ query: String, history: Bool = false) {
            updates.request(query: query, historyMode: history) {
                starts += 1
                return [suggestion]
            }
            updates.poll(query: query, historyMode: history)
        }
        poll("exa")
        try await Task.sleep(for: .milliseconds(20))
        #expect(updates.results(for: "exa", historyMode: false).isEmpty)
        for _ in 0..<50 {
            poll("exa")
            if !updates.results(for: "exa", historyMode: false).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(updates.results(for: "exa", historyMode: false) == [suggestion])
        #expect(starts == 1)
        #expect(updates.results(for: "edited", historyMode: false).isEmpty)
        #expect(updates.results(for: "exa", historyMode: true).isEmpty)
        poll("old")
        try await Task.sleep(for: .milliseconds(20))
        poll("new")
        #expect(updates.results(for: "old", historyMode: false).isEmpty)
        #expect(updates.results(for: "new", historyMode: false).isEmpty)
        updates.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(updates.results(for: "new", historyMode: false).isEmpty)
    }

    @Test func backgroundRankingRetainsOpenTabPriorityAndStableIdentity() async {
        let url = URL(string: "https://example.com")!
        let snapshot = OmnibarSuggestionSnapshot(
            inputText: "exa", historyMode: false,
            tabs: [.init(id: UUID(), url: url, title: "Example", lastAccessed: Date())],
            currentTabId: nil, sites: [:], bookmarkSuggestions: [], allHistoryURLs: [], visits: []
        )
        let first = await Task.detached { snapshot.undecoratedSuggestions }.value
        let second = await Task.detached { snapshot.undecoratedSuggestions }.value
        #expect(first.first?.type == .openTab)
        #expect(first == second)
    }
    @Test func nativeTabAndCompositionAreNotIntercepted() {
        var commits = 0
        var arrows = 0
        let field = OmnibarTextField(text: .constant(""), placeholder: "",
                                    onArrowDown: { arrows += 1 }, onCommit: { _ in commits += 1 })
        let coordinator = field.makeCoordinator()
        let native = NSTextField()
        let editor = NSTextView()
        #expect(!coordinator.control(native, textView: editor,
                                     doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(!coordinator.control(native, textView: editor,
                                     doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(!coordinator.control(native, textView: editor,
                                     doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(!coordinator.control(native, textView: editor,
                                     doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(commits == 0)
        #expect(arrows == 0)
    }

    @Test func selectionRequiresIntentAndSurvivesReordering() {
        let first = Suggestion(url: URL(string: "https://one.example")!, type: .openTab, tabId: UUID())
        let second = Suggestion(url: URL(string: "https://two.example")!, type: .history)
        var selection = OmnibarSelection()
        #expect(selection.selected(in: [first, second]) == nil)
        selection.move(1, in: [first, second])
        #expect(selection.selected(in: [second, first]) == first)
        #expect(selection.selected(in: [second]) == nil)
        selection.move(-1, in: [first, second])
        #expect(selection.selected(in: [first, second]) == nil)
    }

    @Test func backgroundCompletionWaitsWhilePointerIsOverSuggestions() async throws {
        let updates = OmnibarSuggestionUpdates()
        let suggestion = Suggestion(url: URL(string: "https://example.com")!, type: .site)
        var completed = false
        updates.request(query: "exa", historyMode: false) {
            completed = true
            return [suggestion]
        }
        #expect(!completed, "Starting a request must not execute the search in the editing callback")
        for _ in 0..<50 where !completed { try await Task.sleep(for: .milliseconds(10)) }
        #expect(completed)
        updates.poll(query: "exa", historyMode: false, deferPublication: true)
        #expect(updates.results(for: "exa", historyMode: false).isEmpty)
        updates.poll(query: "exa", historyMode: false)
        #expect(updates.results(for: "exa", historyMode: false) == [suggestion])
    }

    @Test(arguments: [false, true])
    func returnOnlySwitchesTabsAfterExplicitSelection(selectSuggestion: Bool) async throws {
        let tab = Tab(title: "Example", url: URL(string: "https://example.com")!)
        var destination: String?
        var switched: UUID?
        let view = OmnibarView(isPresented: .constant(true), urlString: .constant("exa"),
                              onNavigate: { destination = $0; _ = $1 },
                              tabs: [tab], bookmarkSuggestions: [],
                              onSwitchToTab: { switched = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func field(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.delegate is OmnibarTextField.Coordinator { return field }
            return view.subviews.lazy.compactMap { field(in: $0) }.first
        }
        host.layoutSubtreeIfNeeded()
        // Allow the real background request and the next publication tick.
        try await Task.sleep(for: .milliseconds(700))
        let native = try #require(field(in: host))
        let coordinator = try #require(native.delegate as? OmnibarTextField.Coordinator)
        if selectSuggestion { coordinator.parent.onArrowDown?() }
        // SwiftUI supplies refreshed callbacks after explicit selection changes.
        try await Task.sleep(for: .milliseconds(50))
        coordinator.parent.onCommit?(.navigate)
        if selectSuggestion {
            #expect(switched == tab.id)
            #expect(destination == nil)
        } else {
            #expect(switched == nil)
            #expect(destination == NavigationManager.searchURL(for: "exa"))
        }
    }

    @Test func URLParameterEditingAndRepeatedWordSelectionStayNative() async throws {
        let base = "https://example.com"
        let suffix = "/" + String(repeating: "section/item/", count: 100) + "?page=12&q=café&emoji=🙂#details"
        let url = base + suffix
        var smartCalls = 0
        let view = OmnibarView(ledgerNote: { _ in smartCalls += 1; return nil },
                              transcriptHits: { _ in smartCalls += 1; return [] },
                              isPresented: .constant(true), urlString: .constant(url),
                              onNavigate: { _, _ in }, tabs: [], bookmarkSuggestions: [])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func field(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.delegate is OmnibarTextField.Coordinator { return field }
            return view.subviews.lazy.compactMap { field(in: $0) }.first
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        let native = try #require(field(in: host))
        #expect(window.makeFirstResponder(native))
        let editor = try #require(native.currentEditor() as? NSTextView)
        editor.selectedRange = NSRange(location: (base as NSString).length, length: 0)
        for index in 0..<1_000 {
            editor.moveWordRightAndModifySelection(nil)
            // Exercise selection across the polling ticks, including repeats at EOF.
            if index.isMultiple(of: 100) { try await Task.sleep(for: .milliseconds(60)) }
        }
        #expect(editor.string == url)
        #expect(editor.selectedRange == NSRange(location: (base as NSString).length,
                                                length: (suffix as NSString).length))
        editor.deleteBackward(nil)
        #expect(editor.string == base)
        editor.undoManager?.undo()
        #expect(editor.string == url)
        let parameter = (url as NSString).range(of: "page=12")
        editor.selectedRange = NSRange(location: parameter.location + 5, length: 2)
        editor.insertText("42", replacementRange: editor.selectedRange)
        #expect(editor.string == url.replacingOccurrences(of: "page=12", with: "page=42"))
        try await Task.sleep(for: .milliseconds(550))
        #expect(smartCalls == 0, "Full URL editing must not trigger transcript or ledger searches")
    }

    @Test func fullURLsOnlySearchSuggestionsInExplicitHistoryMode() {
        for url in ["https://example.com/path?page=2", "https://example.com", "file:///tmp/report.html"] {
            #expect(!OmnibarSuggestionSnapshot.shouldSuggest(query: url, historyMode: false))
            #expect(OmnibarSuggestionSnapshot.shouldSuggest(query: url, historyMode: true))
        }
        #expect(OmnibarSuggestionSnapshot.shouldSuggest(query: "exa", historyMode: false))
        #expect(!OmnibarSuggestionSnapshot.shouldSuggest(query: "", historyMode: false))
    }

}
