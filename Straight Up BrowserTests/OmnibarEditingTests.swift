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
            updates.poll(query: query, historyMode: history) {
                starts += 1
                return Task { [suggestion] in [suggestion] }
            }
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
}
