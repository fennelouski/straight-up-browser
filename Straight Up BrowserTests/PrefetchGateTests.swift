//
//  PrefetchGateTests.swift
//  Straight Up BrowserTests
//

import Testing
import Foundation
@testable import Browser

@MainActor
struct PrefetchGateTests {

    private func suggestion(_ link: String, type: SuggestionType = .site) -> Suggestion {
        Suggestion(url: URL(string: link)!, title: nil, type: type)
    }

    private func candidate(
        _ suggestions: [Suggestion],
        typed: String = "mail",
        open: [String] = [],
        visits: Int = 5
    ) -> URL? {
        Prefetcher.candidate(
            from: suggestions,
            typed: typed,
            openURLs: Set(open.compactMap { Tab.normalizeURLForComparison(URL(string: $0)) }),
            visitCount: { _ in visits }
        )
    }

    @Test func prefetchesTheOneSiteYouMeant() {
        let url = candidate([suggestion("https://mail.google.com")])
        #expect(url?.absoluteString == "https://mail.google.com")
    }

    @Test func waitsUntilEnoughIsTyped() {
        #expect(candidate([suggestion("https://mail.google.com")], typed: "ma") == nil)
    }

    @Test func staysOutWhenTwoSitesAreStillInPlay() {
        let suggestions = [suggestion("https://mail.google.com"), suggestion("https://mailchimp.com")]
        #expect(candidate(suggestions) == nil)
    }

    // Two pages on one host is still one destination — that stays a prefetch.
    @Test func sameHostTwiceIsStillOneCandidate() {
        let suggestions = [suggestion("https://mail.google.com"), suggestion("https://mail.google.com/u/1")]
        #expect(candidate(suggestions) != nil)
    }

    @Test func skipsSomewhereYouHaveBarelyBeen() {
        #expect(candidate([suggestion("https://mail.google.com")], visits: 2) == nil)
    }

    @Test func skipsAPageAlreadyOpen() {
        let suggestions = [suggestion("https://mail.google.com")]
        #expect(candidate(suggestions, open: ["https://mail.google.com/"]) == nil)
    }

    @Test func skipsWhenTheTopHitIsATabSwitch() {
        // Return would switch to the tab, not load anything — nothing to prefetch.
        #expect(candidate([suggestion("https://mail.google.com", type: .openTab)]) == nil)
    }

    @Test func skipsNonWebSchemes() {
        #expect(candidate([suggestion("file:///Users/me/notes.html")], typed: "notes") == nil)
    }
}
