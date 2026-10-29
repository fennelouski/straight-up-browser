import Foundation
import CoreGraphics
import Testing
@testable import Browser

@Suite("Mobile chrome boundaries")
struct MobileChromePolicyTests {
    @Test func widthAndPositionClampCorruptPreferences() {
        let viewport = CGRect(x: 12, y: 60, width: 360, height: 650)
        let frame = MobileChromeLayout.frame(viewport: viewport, containerWidth: 390, x: -.infinity, y: 50, width: -10)
        #expect(frame.width == 117)
        #expect(frame.height == 44)
        #expect(frame.midX == viewport.midX)
        #expect(frame.maxY == viewport.maxY)
        #expect(MobileChromeLayout.widthFraction(.nan) == 0.5)
    }

    @Test func normalizedPlacementSurvivesKeyboardAndRotation() {
        for viewport in [CGRect(x: 8, y: 60, width: 374, height: 680), CGRect(x: 60, y: 48, width: 700, height: 250), CGRect(x: 8, y: 60, width: 374, height: 230)] {
            let frame = MobileChromeLayout.frame(viewport: viewport, containerWidth: viewport.width + 2 * viewport.minX, x: 0.8, y: 0.7, width: 0.4)
            #expect(viewport.contains(frame))
            let position = MobileChromeLayout.normalized(center: CGPoint(x: frame.midX, y: frame.midY), frame: frame, viewport: viewport)
            #expect(abs(position.x - 0.8) < 0.00001)
            #expect(abs(position.y - 0.7) < 0.00001)
        }
    }

    @Test func minimumWidthUsesContainingViewInPortraitAndLandscape() {
        let portrait = CGRect(x: 8, y: 60, width: 374, height: 680)
        let portraitBar = MobileChromeLayout.frame(viewport: portrait, containerWidth: 390, x: 0.5, y: 1, width: 0.3)
        #expect(abs(portraitBar.width - 117) < 0.000001)
        #expect(portrait.contains(portraitBar))
        let landscape = CGRect(x: 67, y: 48, width: 710, height: 280)
        let landscapeBar = MobileChromeLayout.frame(viewport: landscape, containerWidth: 844, x: 0.5, y: 1, width: 0.3)
        #expect(abs(landscapeBar.width - 253.2) < 0.000001)
        #expect(landscape.contains(landscapeBar))
    }

    @Test func insufficientSafeAreaStillContainsTheBar() {
        let viewport = CGRect(x: 155, y: 60, width: 80, height: 200)
        let bar = MobileChromeLayout.frame(viewport: viewport, containerWidth: 390, x: 0.5, y: 1, width: 0.3)
        #expect(bar.width == 80)
        #expect(viewport.contains(bar))
    }

    @Test func snapHysteresisDoesNotChaseDistantOrRemovedTargets() {
        #expect(MobileChromeLayout.snap(107, targets: [100, 110], held: nil) == 110)
        #expect(MobileChromeLayout.snap(107, targets: [100, 110], held: 100) == 100)
        #expect(MobileChromeLayout.snap(117, targets: [100], held: 100) == nil)
        #expect(MobileChromeLayout.snap(100, targets: [200], held: 100) == nil)
        #expect(MobileChromeLayout.snap(100, targets: [.nan], held: nil) == nil)
    }

    @Test func domainRulesMatchExactHostsAndCanBeReset() throws {
        let url = try #require(URL(string: "https://News.Example/article"))
        let data = MobileDomainRotation.setting("locked", for: url, in: Data())
        #expect(MobileDomainRotation.rules(data) == ["news.example": "locked"])
        #expect(MobileDomainRotation.host(URL(string: "http://news.example/other")) == "news.example")
        #expect(MobileDomainRotation.rules(data)["notnews.example"] == nil)
        #expect(MobileDomainRotation.rules(data)["sub.news.example"] == nil)
        #expect(MobileDomainRotation.rules(MobileDomainRotation.setting(nil, for: url, in: data)).isEmpty)
        #expect(MobileDomainRotation.setting("unsupported", for: url, in: data) == data)
        #expect(MobileDomainRotation.host(URL(string: "file:///private/data")) == nil)
        #expect(MobileDomainRotation.rules(Data("invalid".utf8)).isEmpty)
    }

    @Test func localSuggestionsDeduplicateWithoutCollapsingDistinctQueries() async throws {
        let url = try #require(URL(string: "https://EXAMPLE.com:443"))
        let historyURL = try #require(URL(string: "https://example.com/"))
        let result = await omnibarSuggestions(input: "example", tabHistory: [[historyURL.absoluteString]],
            bookmarks: [("Example bookmark", url)], durableHistory: [HistoryVisit(url: historyURL, title: "Example history")],
            openTabs: [MobileOpenTabSuggestion(url: historyURL, title: "Example tab", lastAccessed: Date())])
        #expect(result.count == 1)
        #expect(result.first?.type == .bookmark)
        #expect(MobileChromeLayout.canonicalURL(URL(string: "https://example.com/?a=1")!) != MobileChromeLayout.canonicalURL(URL(string: "https://example.com/?a=2")!))
    }

    @Test func titlesAndExistingSyncedOpenRecordsAreSearchableButPrivateSourcesAreExcluded() async {
        let now = Date(timeIntervalSince1970: 100_000)
        let results = await omnibarSuggestions(input: "project", tabHistory: [], bookmarks: [],
            durableHistory: [HistoryVisit(url: URL(string: "https://history.example/")!, title: "Project notes", visitedAt: now)],
            openTabs: [MobileOpenTabSuggestion(url: URL(string: "https://open.example/")!, title: "Project board", lastAccessed: now),
                       MobileOpenTabSuggestion(url: URL(string: "https://private.example/")!, title: "Project secret", lastAccessed: now, isPrivate: true)], now: now)
        #expect(results.count == 2)
        #expect(results.first?.type == .openTab)
        #expect(!results.contains { $0.url.host == "private.example" })
    }

    @Test func predictionUsesLocalRecencyAndFrequencyWithStableResults() async {
        let now = Date(timeIntervalSince1970: 9_000_000)
        let visits = [HistoryVisit(url: URL(string: "https://example.com/old")!, title: "Old", visitedAt: now.addingTimeInterval(-86400 * 100)),
                      HistoryVisit(url: URL(string: "https://example.com/recent")!, title: "Recent", visitedAt: now)]
        let a = await omnibarSuggestions(input: "example", tabHistory: [], bookmarks: [], durableHistory: visits, now: now)
        let b = await omnibarSuggestions(input: "example", tabHistory: [], bookmarks: [], durableHistory: visits.reversed(), now: now)
        #expect(a.first?.url.path == "/recent")
        #expect(a.map(\.id) == b.map(\.id))
    }

    @Test func emptyQueriesAndCredentialBearingURLsDoNotSuggest() async {
        let empty = await omnibarSuggestions(input: "  ", tabHistory: [["https://example.com"]], bookmarks: [])
        let unsafe = await omnibarSuggestions(input: "example", tabHistory: [["https://user:secret@example.com", "file:///example"]], bookmarks: [])
        #expect(empty.isEmpty)
        #expect(unsafe.isEmpty)
    }

    @Test func largeHistoryRankingCapsResultsAndHonorsCancellation() async {
        let rows = (0..<10_000).map { "https://example.com/item/\($0)" }
        let result = await omnibarSuggestions(input: "example", tabHistory: [rows], bookmarks: [])
        #expect(result.count == 8)
        let task = Task { await omnibarSuggestions(input: "example", tabHistory: [rows], bookmarks: []) }
        task.cancel()
        #expect(await task.value.isEmpty)
    }
}

@Suite("Mobile suggestion snapshot ownership")
struct MobileSuggestionSnapshotTests {
    private func request(
        query: String = "airfoil",
        tabID: UUID? = UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
        entryID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        revision: Int = 0,
        isPrivate: Bool = false
    ) -> MobileSuggestionRequest {
        MobileSuggestionRequest(query: query, tabID: tabID, entryID: entryID,
            revision: revision, isPrivate: isPrivate)
    }

    private func snapshot(for request: MobileSuggestionRequest) -> MobileSuggestionSnapshot {
        MobileSuggestionSnapshot(request: request, results: [
            Suggestion(url: URL(string: "https://received.example/airfoil")!,
                title: "Airfoil reference", type: .openTab)
        ])
    }

    @Test func onlyTheCurrentQueryCanDisplayCachedRows() {
        let original = request()
        let cache = snapshot(for: original)
        #expect(cache.matchingResults(for: original).count == 1)
        // The next lookup may still be debouncing. Old rows are already absent.
        #expect(cache.matchingResults(for: request(query: "another project")).isEmpty)
    }

    @Test func switchingTabsOrReopeningTheSameTextInvalidatesRows() {
        let cache = snapshot(for: request())
        #expect(cache.matchingResults(for: request(tabID: UUID())).isEmpty)
        #expect(cache.matchingResults(for: request(tabID: nil)).isEmpty)
        #expect(cache.matchingResults(for: request(entryID: UUID())).isEmpty)
    }

    @Test func dataRefreshInvalidatesOldRowsAndTheirIndices() {
        let original = request()
        let refreshed = request(revision: 1)
        // A late completion for an older request cannot become current again.
        #expect(snapshot(for: original).matchingResults(for: refreshed).isEmpty)
        #expect(snapshot(for: refreshed).matchingResults(for: refreshed).count == 1)
    }

    @Test func closedOrWhitespaceOnlyEditorsCannotDisplayRows() {
        let cache = snapshot(for: request())
        #expect(cache.matchingResults(for: request(query: "")).isEmpty)
        let blank = request(query: " \n\t ")
        #expect(snapshot(for: blank).matchingResults(for: blank).isEmpty)
    }

    @Test func privateEditorsCannotDisplayRegularOrPrivateSnapshots() {
        let privateRequest = request(isPrivate: true)
        #expect(snapshot(for: request()).matchingResults(for: privateRequest).isEmpty)
        #expect(snapshot(for: privateRequest).matchingResults(for: privateRequest).isEmpty)
    }
}
