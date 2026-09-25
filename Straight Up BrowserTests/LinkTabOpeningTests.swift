import Foundation
import SwiftData
import Testing
@testable import Browser

@MainActor
struct LinkTabOpeningTests {
    @Test(arguments: ["normal", "container", "incognito"])
    func linkSelectsItsDestinationNextToActualSourceWithoutSidebar(kind: String) throws {
        let container = try ModelContainer(for: Tab.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let manager = TabManager(modelContext: context, terminateApplication: {})
        let source = kind == "incognito" ? manager.createIncognitoTab() : manager.createNewTab()
        source.sessionKind = try #require(SessionKind(rawValue: kind))
        if kind == "container" { source.sessionId = UUID() }
        source.workspaceId = UUID()
        source.groupId = UUID()
        source.isPinned = true
        let other = kind == "incognito" ? manager.createIncognitoTab() : manager.createNewTab()
        manager.selectedTabId = other.id
        let url = URL(string: "https://example.com/link")!

        let first = manager.openLinkInNewTab(url, from: source)
        let second = manager.openLinkInNewTab(url, from: source)
        #expect(manager.selectedTabId == second.id)
        #expect(second.url == url)
        #expect(second.openerId == source.id)
        #expect(second.groupId == source.groupId)
        #expect(second.workspaceId == source.workspaceId)
        #expect(second.sessionKind == source.sessionKind)
        #expect(second.sessionId == source.sessionId)
        #expect(second.isPinned == source.isPinned)
        let rows = kind == "incognito" ? manager.incognitoTabs : try context.fetch(FetchDescriptor<Tab>())
        let ordered = rows.sorted { $0.orderIndex < $1.orderIndex }
        let actual = ordered.map(\.id)
        let expected: [UUID] = [source.id, second.id, first.id, other.id]
        #expect(actual == expected)
        if kind == "incognito" {
            #expect(try context.fetchCount(FetchDescriptor<Tab>()) == 0)
        }
    }
}
