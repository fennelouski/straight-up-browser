import Foundation
import SwiftUI
import SwiftData
import WebKit
import Testing
@testable import Browser

@MainActor
struct NewspaperDiscoveryTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "NewspaperDiscoveryTests." + UUID().uuidString)!
    }
    @Test func visitedReadingDefaultsOnAndOtherSourcesRemainOptIn() {
        let defaults = defaults()
        let options = NewspaperDiscoveryOptions(defaults: defaults)
        #expect(options.visited && options.recent && options.related && !options.prefetched)
        #expect(!options.onDevice && !options.external && !options.idle)
        #expect(!options.shopping)
        #expect(options.dailyLimit == 24)
        defaults.set(1000, forKey: NewspaperPreferences.Key.dailyDiscoveryLimit)
        #expect(NewspaperDiscoveryOptions(defaults: defaults).dailyLimit == 100)
        defaults.set(-4, forKey: NewspaperPreferences.Key.dailyDiscoveryLimit)
        #expect(NewspaperDiscoveryOptions(defaults: defaults).dailyLimit == 1)
        defaults.set(false, forKey: NewspaperPreferences.Key.discoverVisited)
        defaults.set(false, forKey: NewspaperPreferences.Key.discoverRecent)
        #expect(!NewspaperDiscoveryOptions(defaults: defaults).visited)
        #expect(!NewspaperDiscoveryOptions(defaults: defaults).recent)
    }
    @Test func recentReadingIsBoundedDeduplicatedAndSkipsSensitivePaths() throws {
        let now = Date(), options = NewspaperDiscoveryOptions(defaults: defaults())
        let url = try #require(URL(string: "https://gizmodo.com/a-long-public-article"))
        var visits = [HistoryVisit(url: url, title: "Article", visitedAt: now), HistoryVisit(url: url, title: "Again", visitedAt: now)]
        for value in ["https://news.example/account/private-details", "https://news.example/a-long-article?token=private", "https://reddit.com/user/private-profile"] {
            visits.append(HistoryVisit(url: try #require(URL(string: value)), title: "Skip", visitedAt: now))
        }
        visits.append(HistoryVisit(url: try #require(URL(string: "https://news.example/expired-article")), title: "Old", visitedAt: now.addingTimeInterval(-31 * 86400)))
        #expect(NewspaperRecentReading.candidates(visits, options: options, now: now) == [url])
        #expect(NewspaperRecentReading.candidates((0..<120).map { HistoryVisit(url: URL(string: "https://news.example/article-number-\($0)")!, title: "News", visitedAt: now) }, options: options, now: now).count == 96)
        let article = ReaderArticle(title: "Camera report", byline: nil, blocks: [])
        #expect(NewspaperRecentReading.section(for: article, url: URL(string: "https://petapixel.com/news/article")!) == "Photography")
        #expect(NewspaperRecentReading.section(for: article, url: url) == "Technology")
        let frontPage = URL(string: "https://engadget.com/")!
        #expect(NewspaperRecentReading.candidates([HistoryVisit(url: frontPage, title: "Front page", visitedAt: now)], options: options, now: now) == [frontPage])
        #expect(NewspaperRecentReading.isLikelyStoryURL(URL(string: "https://engadget.com/cameras/a-new-camera-review-123456.html")!))
        #expect(!NewspaperRecentReading.isLikelyStoryURL(URL(string: "https://engadget.com/tag/camera-reviews")!))
        #expect(NewspaperDiscoveryOptions.publicURL(URL(string: "https://news.example/public-story?utm_source=feed&fbclid=tracking")!) == URL(string: "https://news.example/public-story"))
    }
    @Test func pageProjectionAndSwipesAreBounded() {
        #expect(NewspaperPageProjection.pageCount(articleCount: 9, layout: .broadsheet) == 3)
        #expect(NewspaperPageProjection.pageCount(articleCount: 3, layout: .flipbook) == 3)
        #expect(NewspaperPageProjection.pageCount(articleCount: 0, layout: .broadsheet) == 1)
        var swipe = NewspaperSwipeAccumulator()
        #expect(swipe.consume(x: 10, y: 40) == nil)
        #expect(swipe.consume(x: 40, y: 0) == nil)
        #expect(swipe.consume(x: 40, y: 0) == -1)
        #expect(swipe.consume(x: 100, y: 0) == nil)
        swipe.reset()
        #expect(swipe.consume(x: -80, y: 0) == 1)
    }
    @Test func exclusionsCoverSubdomainsAndUnsafeDestinationsAreRejected() throws {
        let defaults = defaults()
        defaults.set("bank.example, health.example", forKey: NewspaperPreferences.Key.excludedHosts)
        let options = NewspaperDiscoveryOptions(defaults: defaults)
        for value in ["http://news.example/story", "https://localhost/story", "https://127.0.0.1/story", "https://[::1]/story", "https://printer.local/story", "https://bank.example/story", "https://accounts.bank.example/story", "https://bank.example./story", "https://news.example:8443/story", "https://news.example/story?token=secret", "https://news.example/account/private-details", "https://news.example/checkout/order-details", "https://name:secret@news.example/story"] {
            #expect(!options.permits(try #require(URL(string: value))))
        }
        #expect(options.permits(try #require(URL(string: "https://news.example/story"))))
        #expect(options.permits(try #require(URL(string: "https://notbank.example/story"))))
    }
    @Test func boilerplateDoesNotQualifyAsAnArticle() {
        let prose = Array(repeating: "A substantive sentence with useful information.", count: 40).joined(separator: " ")
        #expect(!NewspaperDiscoveryOptions.isReadableArticle(ReaderArticle(title: "Dashboard", byline: nil, blocks: [.paragraph(runs: [.plain(prose)])])))
        #expect(NewspaperDiscoveryOptions.isReadableArticle(ReaderArticle(title: "A feature", byline: nil, blocks: Array(repeating: .paragraph(runs: [.plain(prose)]), count: 3))))
    }
    @Test func frontPagesQueueEligibleArticleLinksWithoutSavingNavigation() async throws {
        let defaults = defaults()
        let container = try ModelContainer(for: NewspaperArticle.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let coordinator = NewspaperDiscoveryCoordinator(defaults: defaults, modelContext: context)
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let navigation = NewspaperFixtureNavigation()
        view.navigationDelegate = navigation
        let url = URL(string: "https://engadget.com/")!
        let links = "<article><a href='/cameras/a-new-camera-review-123456.html'>First</a></article><article><a href='/science/a-new-science-story-123456.html?utm_source=home'>Second</a></article><a href='https://other.example/a-cross-site-story.html'>Other</a><a href='/tag/camera-reviews'>Tag</a>"
        view.loadHTMLString("<html><body>" + links + "</body></html>", baseURL: url)
        for _ in 0..<100 { if navigation.finished { break }; try await Task.sleep(for: .milliseconds(100)) }
        #expect(navigation.finished)
        defaults.set(false, forKey: NewspaperPreferences.Key.discoverRelated)
        await coordinator.inspect(view, expectedURL: url, source: .visited)
        #expect(defaults.stringArray(forKey: "newspaperRelatedCandidates") == nil)
        defaults.set(true, forKey: NewspaperPreferences.Key.discoverRelated)
        await coordinator.inspect(view, expectedURL: url, source: .visited)
        #expect(defaults.stringArray(forKey: "newspaperRelatedCandidates") == ["https://engadget.com/cameras/a-new-camera-review-123456.html", "https://engadget.com/science/a-new-science-story-123456.html"])
        #expect(try context.fetchCount(FetchDescriptor<NewspaperArticle>()) == 0)
    }
    @Test func redditCapturePreservesOriginalPostAndExcludesComments() async throws {
        let defaults = defaults()
        let container = try ModelContainer(for: NewspaperArticle.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let coordinator = NewspaperDiscoveryCoordinator(defaults: defaults, modelContext: context)
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let navigation = NewspaperFixtureNavigation()
        view.navigationDelegate = navigation
        let url = URL(string: "https://reddit.com/r/photography/comments/abc123/a_camera_discussion/")!
        let prose = Array(repeating: "Photography brings people together to learn about light and composition.", count: 10).joined(separator: " ")
        view.loadHTMLString("<html><body><shreddit-post post-title='A camera discussion' author='Photographer'><div slot='text-body'><p>" + prose + "</p></div></shreddit-post><p>COMMENT SHOULD NOT BE CAPTURED</p></body></html>", baseURL: url)
        for _ in 0..<100 { if navigation.finished { break }; try await Task.sleep(for: .milliseconds(100)) }
        #expect(navigation.finished)
        await coordinator.inspect(view, expectedURL: url, source: .visited)
        let article = try #require(context.fetch(FetchDescriptor<NewspaperArticle>()).first)
        #expect(article.title == "A camera discussion")
        #expect(article.section == "Community")
        let document = try #require(article.document)
        #expect(!document.plainText.contains("COMMENT SHOULD NOT BE CAPTURED"))
    }
    @Test func trackingFrameDoesNotFailTheParentArticleLoad() async throws {
        let navigation = NewspaperDiscoveryNavigation(defaults: defaults())
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = navigation
        view.loadHTMLString("<html><body><iframe src='https://www.googletagmanager.com/ns.html?id=tracking'></iframe><article><h1>Public reading</h1><p>An article remains readable when a tracking frame is blocked.</p></article></body></html>", baseURL: URL(string: "https://news.example/public-reading")!)
        for _ in 0..<100 { if navigation.finished || navigation.failed { break }; try await Task.sleep(for: .milliseconds(100)) }
        #expect(!navigation.failed)
        #expect(navigation.finished)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_NEWSPAPER_DISCOVERY_LIVE_TEST"] == "1", "Live publication catch-up is an explicit network probe.")) func liveFrontPageBuildsAnEditionFromPublicArticles() async throws {
        let defaults = defaults()
        let container = try ModelContainer(for: NewspaperArticle.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let coordinator = NewspaperDiscoveryCoordinator(defaults: defaults, modelContext: context)
        await coordinator.catchUpRecentVisits(modelContext: context, recentVisits: [HistoryVisit(url: URL(string: "https://www.engadget.com/")!, title: "Engadget", visitedAt: Date())])
        let articles = try context.fetch(FetchDescriptor<NewspaperArticle>())
        print("LIVE_NEWSPAPER_ARTICLE_COUNT=\(articles.count) CANDIDATES=\((defaults.stringArray(forKey: "newspaperRelatedCandidates") ?? []).count) STATUS=\(coordinator.catchUpStatus)")
        #expect(articles.count == NewspaperDiscoveryOptions(defaults: defaults).dailyLimit)
        #expect(articles.allSatisfy { $0.document != nil && !$0.section.isEmpty && $0.section != "Front Page" })
    }
    @Test func privateCoordinationRequiresBothExplicitSharingAndBrowserSync() {
        let defaults = defaults()
        defaults.set(true, forKey: NewspaperPreferences.Key.shareDiscovery)
        defaults.set(true, forKey: NewspaperPreferences.Key.discoverRelated)
        #expect(!NewspaperDiscoveryPeers.enabled(defaults: defaults))
        defaults.set(true, forKey: TabSync.Key.enabled)
        #expect(NewspaperDiscoveryPeers.enabled(defaults: defaults))
    }
    @Test func staleAndActiveWorkersCannotWinTheIdleElection() {
        let now = Date()
        let rows: [String: NewspaperDiscoveryPeers.Advertisement] = [
            "a": .init(updatedAt: now.addingTimeInterval(-181), idle: true, links: [], linksUpdatedAt: now),
            "b": .init(updatedAt: now, idle: false, links: [], linksUpdatedAt: now),
            "d": .init(updatedAt: now, idle: true, links: [], linksUpdatedAt: now),
            "c": .init(updatedAt: now, idle: true, links: [], linksUpdatedAt: now)
        ]
        #expect(NewspaperDiscoveryPeers.electedWorker(advertisements: rows, now: now) == "c")
        #expect(NewspaperDiscoveryPeers.electedWorker(advertisements: rows, now: now.addingTimeInterval(181)) == nil)
    }
    @Test func appearanceIsIndependentOfLayoutAndFollowsSystemByDefault() {
        #expect(NewspaperPreferences.defaultLayout == NewspaperLayout.broadsheet.rawValue)
        #expect(NewspaperPreferences.defaultAppearance == NewspaperAppearance.system.rawValue)
        #expect(NewspaperAppearance.system.colorScheme == nil)
        #expect(NewspaperAppearance.light.colorScheme == .light)
        #expect(NewspaperAppearance.dark.colorScheme == .dark)
    }
    @Test func loadedArticleRequiresConsentAndIsSavedOnlyOnce() async throws {
        let defaults = defaults()
        defaults.set(false, forKey: NewspaperPreferences.Key.discoverVisited)
        let container = try ModelContainer(for: NewspaperArticle.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let coordinator = NewspaperDiscoveryCoordinator(defaults: defaults, modelContext: context)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        let navigation = NewspaperFixtureNavigation()
        view.navigationDelegate = navigation
        let prose = Array(repeating: "This report describes the city's new public gardens and the residents who care for them.", count: 20).joined(separator: " ")
        let url = try #require(URL(string: "https://news.example/community-gardens"))
        view.loadHTMLString("<html><head><title>Community gardens</title></head><body><article><h1>Community gardens</h1><p>\(prose)</p><p>\(prose)</p><p>\(prose)</p></article></body></html>", baseURL: url)
        for _ in 0..<100 {
            if navigation.finished { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(navigation.finished)
        await coordinator.inspect(view, expectedURL: url, source: .visited)
        #expect(try context.fetchCount(FetchDescriptor<NewspaperArticle>()) == 0)
        defaults.set(true, forKey: NewspaperPreferences.Key.discoverVisited)
        await coordinator.inspect(view, expectedURL: url, source: .visited)
        #expect(try context.fetchCount(FetchDescriptor<NewspaperArticle>()) == 1)
        await coordinator.inspect(view, expectedURL: url, source: .visited)
        #expect(try context.fetchCount(FetchDescriptor<NewspaperArticle>()) == 1)
        #expect(defaults.integer(forKey: "newspaperDiscoveryCount") == 1)
    }

    @Test func productClippingsRequireIndependentConsentAndRejectCredentialForms() async throws {
        let defaults = defaults()
        let container = try ModelContainer(for: NewspaperArticle.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let coordinator = NewspaperDiscoveryCoordinator(defaults: defaults, modelContext: context)
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        let url = URL(string: "https://shop.example/product/camera")!
        let metadata = #"<script type="application/ld+json">{"@type":"Product","name":"Travel Camera"}</script>"#
        for credentialForm in [false, true] {
            let navigation = NewspaperFixtureNavigation(); view.navigationDelegate = navigation
            view.loadHTMLString("<html><head>" + metadata + "</head><body>" + (credentialForm ? "<input type='password'>" : "<h1>Travel Camera</h1>") + "</body></html>", baseURL: url)
            for _ in 0..<100 { if navigation.finished { break }; try await Task.sleep(for: .milliseconds(100)) }
            #expect(navigation.finished)
            NewspaperShoppingStore.clear(defaults: defaults)
            defaults.set(false, forKey: NewspaperEditionPreferences.captureShopping)
            await coordinator.inspect(view, expectedURL: url, source: .visited)
            #expect(NewspaperShoppingStore.signals(defaults: defaults).isEmpty)
            defaults.set(true, forKey: NewspaperEditionPreferences.captureShopping)
            await coordinator.inspect(view, expectedURL: url, source: .visited)
            #expect(NewspaperShoppingStore.signals(defaults: defaults).count == (credentialForm ? 0 : 1))
            #expect(try context.fetchCount(FetchDescriptor<NewspaperArticle>()) == 0)
        }
    }

}


@MainActor
private final class NewspaperFixtureNavigation: NSObject, WKNavigationDelegate {
    var finished = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
}
