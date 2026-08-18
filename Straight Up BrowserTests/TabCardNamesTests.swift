import Foundation
import Testing
@testable import Browser

@Suite("Tab card names")
@MainActor
struct TabCardNamesTests {
    // The whole point of two lines: which half leads depends on the company a
    // tab keeps. Alone, the site names it; among siblings, only the page does.
    @Test("A lone tab leads with its site, siblings lead with the page")
    func siteAndPageSwapByPeerCount() throws {
        let budget = Tab(title: "Q3 Budget", url: URL(string: "https://docs.google.com/document/d/budget"))
        let roadmap = Tab(title: "Roadmap", url: URL(string: "https://docs.google.com/document/d/roadmap"))

        let alone = TabCardNames.shared.labels(for: budget, among: [budget])
        #expect(alone.title == "Google")
        #expect(alone.detail == "Q3 Budget")

        let crowded = TabCardNames.shared.labels(for: budget, among: [budget, roadmap])
        #expect(crowded.title == "Q3 Budget")
        #expect(crowded.detail == "Google")
    }

    @Test("The two lines are never the same string")
    func linesNeverRepeat() throws {
        // A page whose title is just its domain — the case that used to print
        // the same words twice.
        let bare = Tab(title: "example.com", url: URL(string: "https://example.com"))
        let labels = TabCardNames.shared.labels(for: bare, among: [bare])
        #expect(labels.title != labels.detail)
    }
}
