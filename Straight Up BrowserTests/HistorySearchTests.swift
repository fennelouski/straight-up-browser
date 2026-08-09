//
//  HistorySearchTests.swift
//  Straight Up BrowserTests
//

import Testing
import Foundation
@testable import Browser

@MainActor
struct HistorySearchTests {

    private func store(_ visits: [(String, String, Date)]) -> BrowsingHistoryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-\(UUID().uuidString).json")
        let store = BrowsingHistoryStore(storeURL: url)
        for (link, title, date) in visits {
            store.record(url: URL(string: link)!, title: title, sessionKind: .normal, visitedAt: date)
        }
        return store
    }

    @Test func fuzzyMatchesOutOfOrderCharactersInOrder() {
        #expect(BrowsingHistoryStore.fuzzyScore(Array("ghrp"), in: "github.com/acme/repo/pulls") != nil)
        #expect(BrowsingHistoryStore.fuzzyScore(Array("zzz"), in: "github.com") == nil)
        // Order matters: the same letters backwards are not a match.
        #expect(BrowsingHistoryStore.fuzzyScore(Array("prhg"), in: "github.com/acme/repo/pulls") == nil)
    }

    @Test func wordStartsBeatBuriedLetters() {
        let starts = BrowsingHistoryStore.fuzzyScore(Array("gp"), in: "github.com/pulls")!
        let buried = BrowsingHistoryStore.fuzzyScore(Array("gp"), in: "gxxpxx.com")!
        #expect(starts > buried)
    }

    @Test func findsPageByTitleNotJustURL() {
        let store = store([("https://mail.google.com/", "Inbox", Date())])
        #expect(store.search("inbx").first?.title == "Inbox")
    }

    @Test func frequentlyVisitedPageOutranksOneOff() {
        let now = Date()
        var visits = [(String, String, Date)]()
        for i in 0..<10 {
            visits.append(("https://news.example.com/", "News", now.addingTimeInterval(-Double(i) * 3600)))
        }
        visits.append(("https://newsletter.example.com/", "Newsletter", now))
        let results = store(visits).search("news")
        #expect(results.first?.url.host == "news.example.com")
    }

    @Test func emptyQueryReturnsMostRecent() {
        let now = Date()
        let store = store([
            ("https://old.example.com/", "Old", now.addingTimeInterval(-9999)),
            ("https://new.example.com/", "New", now)
        ])
        #expect(store.search("").first?.url.host == "new.example.com")
    }

    @Test func deletingRangeKeepsVisitsOutsideInclusiveBounds() {
        let now = Date()
        let history = store([
            ("https://before.example.com/", "Before", now.addingTimeInterval(-300)),
            ("https://inside.example.com/", "Inside", now.addingTimeInterval(-200)),
            ("https://after.example.com/", "After", now.addingTimeInterval(-100)),
        ])

        history.remove(
            from: now.addingTimeInterval(-250),
            through: now.addingTimeInterval(-150)
        )

        #expect(history.visits.map(\.url.host) == ["after.example.com", "before.example.com"])
    }
}
