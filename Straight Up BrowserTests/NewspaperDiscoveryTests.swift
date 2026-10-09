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
    @Test func discoveryIsEntirelyOptInAndBoundsItsBudget() {
        let defaults = defaults()
        let options = NewspaperDiscoveryOptions(defaults: defaults)
        #expect(!options.visited && !options.prefetched && !options.related)
        #expect(!options.onDevice && !options.external && !options.idle)
        #expect(options.dailyLimit == 3)
        defaults.set(1000, forKey: NewspaperPreferences.Key.dailyDiscoveryLimit)
        #expect(NewspaperDiscoveryOptions(defaults: defaults).dailyLimit == 20)
        defaults.set(-4, forKey: NewspaperPreferences.Key.dailyDiscoveryLimit)
        #expect(NewspaperDiscoveryOptions(defaults: defaults).dailyLimit == 1)
    }
    @Test func exclusionsCoverSubdomainsAndUnsafeDestinationsAreRejected() throws {
        let defaults = defaults()
        defaults.set("bank.example, health.example", forKey: NewspaperPreferences.Key.excludedHosts)
        let options = NewspaperDiscoveryOptions(defaults: defaults)
        for value in ["http://news.example/story", "https://localhost/story", "https://127.0.0.1/story", "https://[::1]/story", "https://printer.local/story", "https://bank.example/story", "https://accounts.bank.example/story", "https://bank.example./story", "https://news.example:8443/story", "https://news.example/story?token=secret", "https://name:secret@news.example/story"] {
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

}


@MainActor
private final class NewspaperFixtureNavigation: NSObject, WKNavigationDelegate {
    var finished = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
}
