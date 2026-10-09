import Foundation
import SwiftData
import Testing
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Browser

@MainActor struct NewspaperEditionTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "NewspaperEditionTests." + UUID().uuidString)! }
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: NewspaperArticle.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }
    @Test func localeRecommendationsNeedNoLocationAndIllustrationsInfluenceFormat() {
        #expect(NewspaperEditionStyle.recommendation(region: "JP", language: "en", illustrated: false) == .pacificMorning)
        #expect(NewspaperEditionStyle.recommendation(region: "FR", language: "en", illustrated: false) == .continental)
        #expect(NewspaperEditionStyle.recommendation(region: nil, language: "de", illustrated: false) == .alpine)
        #expect(NewspaperEditionStyle.recommendation(region: "US", language: "en", illustrated: true).recommendedLayout == .cover)
        #expect(NewspaperEditionStyle.allCases.count == 30)
    }
    @Test func firstOpeningPreservesExplicitChoicesAndDoesNotSeedExistingArticles() async throws {
        let defaults = defaults(), context = try context()
        defaults.set(NewspaperEditionStyle.signal.rawValue, forKey: NewspaperEditionPreferences.style)
        defaults.set(NewspaperLayout.ink.rawValue, forKey: NewspaperPreferences.Key.layout)
        let store = NewspaperStore(modelContext: context)
        _ = store.enqueue(url: URL(string: "https://example.com/story")!, title: "My article")
        await NewspaperEditionPreparation.prepare(context: context, defaults: defaults, locale: Locale(identifier: "ja_JP"))
        #expect(defaults.string(forKey: NewspaperEditionPreferences.style) == "signal")
        #expect(defaults.string(forKey: NewspaperPreferences.Key.layout) == "ink")
        #expect(try context.fetchCount(FetchDescriptor<NewspaperArticle>()) == 1)
        for article in try context.fetch(FetchDescriptor<NewspaperArticle>()) { store.remove(article) }
        await NewspaperEditionPreparation.prepare(context: context, defaults: defaults)
        #expect(try context.fetchCount(FetchDescriptor<NewspaperArticle>()) == 0)
    }
    @Test func emptyFirstEditionHasAttributedOfflineTextOnlyOnce() async throws {
        let defaults = defaults(), context = try context()
        await NewspaperEditionPreparation.prepare(context: context, defaults: defaults, locale: Locale(identifier: "fr_FR"))
        let articles = try context.fetch(FetchDescriptor<NewspaperArticle>())
        #expect(articles.count == 2)
        #expect(articles.allSatisfy { $0.captureState == .ready && !$0.cardExcerpt.isEmpty && $0.url.host == "nathanfennel.com" })
        #expect(defaults.string(forKey: NewspaperEditionPreferences.style) == "continental")
        await NewspaperEditionPreparation.prepare(context: context, defaults: defaults)
        #expect(try context.fetchCount(FetchDescriptor<NewspaperArticle>()) == 2)
    }
    @Test func welcomeAndRegionalRecommendationsCanBeDisabled() async throws {
        let defaults = defaults(), context = try context()
        defaults.set(false, forKey: NewspaperEditionPreferences.welcomeEnabled)
        defaults.set(false, forKey: NewspaperEditionPreferences.regionalStyle)
        await NewspaperEditionPreparation.prepare(context: context, defaults: defaults, locale: Locale(identifier: "ja_JP"))
        #expect(defaults.string(forKey: NewspaperEditionPreferences.style) == "metropolitan")
        #expect(try context.fetchCount(FetchDescriptor<NewspaperArticle>()) == 0)
    }
    @Test func shoppingIsOptInBoundedExpiresAndHonorsExclusions() throws {
        let defaults = defaults(), now = Date()
        let url = try #require(URL(string: "https://shop.example/product/camera"))
        NewspaperShoppingStore.record(url: url, title: "Travel Camera", defaults: defaults, now: now)
        #expect(defaults.data(forKey: NewspaperEditionPreferences.shoppingSignals) == nil)
        defaults.set(true, forKey: NewspaperEditionPreferences.captureShopping)
        for index in 0..<20 {
            NewspaperShoppingStore.record(url: URL(string: "https://shop.example/product/\(index)")!, title: "Camera \(index)", defaults: defaults, now: now)
        }
        #expect(NewspaperShoppingStore.signals(defaults: defaults, now: now).count == 12)
        #expect(NewspaperShoppingStore.signals(defaults: defaults, now: now.addingTimeInterval(31 * 86400)).isEmpty)
        defaults.set("shop.example", forKey: NewspaperPreferences.Key.excludedHosts)
        #expect(NewspaperShoppingStore.signals(defaults: defaults, now: now).isEmpty)
        NewspaperShoppingStore.clear(defaults: defaults)
        #expect(defaults.data(forKey: NewspaperEditionPreferences.shoppingSignals) == nil)
    }
    @Test func namingContextIsBoundedAndSiteNamesNeverContainCredentialsOrPaths() throws {
        let defaults = defaults()
        let now = Date()
        let visits = ["https://news.example/story", "https://news.example/second", "https://bank.example/article", "https://shop.example/product?token=secret", "https://user:password@news.example/article", "https://medical.example/article"].map {
            HistoryVisit(url: URL(string: $0)!, title: "A private page title", visitedAt: now)
        }
        #expect(NewspaperNaming.eligibleHosts(visits, defaults: defaults, now: now) == ["news.example"])
        let context = NewspaperNaming.context(style: "Magazine", name: nil, device: nil, region: nil,
            sections: Array(repeating: "Science", count: 50), titles: Array(repeating: String(repeating: "a", count: 1000), count: 30), hosts: [])
        #expect(context.utf8.count < 1600)
        #expect(!context.contains("password"))
        #expect(NewspaperNaming.validName("https://example.com") == nil)
        #expect(NewspaperNaming.validName("Secret\nName") == nil)
        #expect(NewspaperNaming.title("", fallback: "Metropolitan") == "Metropolitan")
    }
    @Test func namingShortlistCannotInventNewCandidatesAndMakesAtMostTwoCalls() async throws {
        var calls = 0
        let names = try await NewspaperNameGenerator.generate(context: "{}", refine: true) { _ in
            calls += 1
            return calls == 1 ? #"["Orbit Journal","Morning Garden","The Curious Reader","City Light","Orbit Journal","https://bad.example"]"# : #"["Morning Garden","Invented Second Pass","Orbit Journal"]"#
        }
        #expect(calls == 2)
        #expect(names == ["Morning Garden", "Orbit Journal", "The Curious Reader", "City Light"])
        calls = 0
        _ = try await NewspaperNameGenerator.generate(context: "{}", refine: false) { _ in calls += 1; return #"["Morning Garden"]"# }
        #expect(calls == 1)
    }
    @Test func coverDecodeBoundsImageSizeAndInvalidInputFallsBack() throws {
        #expect(NewspaperCoverImageWorker.decode(Data("not an image".utf8), cutout: true) == nil)
        let drawing = try #require(CGContext(data: nil, width: 2400, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        drawing.setFillColor(CGColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 1)); drawing.fill(CGRect(x: 0, y: 0, width: 2400, height: 1600))
        let image = try #require(drawing.makeImage()), data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let decoded = try #require(NewspaperCoverImageWorker.decode(data as Data, cutout: false))
        #expect(decoded.original.width == 1200 && decoded.original.height == 800)
        #expect(decoded.subject == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_NEWSPAPER_NAMING_LIVE_TEST"] == "1"))
    func liveAppleIntelligenceNamesAnEditionWithoutPersonalContext() async throws {
        guard NewspaperNameGenerator.localAvailable, SettingsManager.shared.aiFeaturesEnabled else { throw NewspaperNameGenerator.Failure.unavailable }
        let context = NewspaperNaming.context(style: "Literary magazine", name: nil, device: nil, region: nil,
            sections: ["Science", "Gardens"], titles: [], hosts: [])
        let names = try await NewspaperNameGenerator.generate(context: context, refine: true, respond: NewspaperNameGenerator.local)
        #expect(names.count >= 3)
        #expect(names.allSatisfy { NewspaperNaming.validName($0) != nil })
    }

    @Test func coverSubjectIsolationKeepsTheMastheadLayerTransparent() throws {
        let data = try #require(NSImage(named: "OnboardingAstronautCurious")?.tiffRepresentation)
        let decoded = try #require(NewspaperCoverImageWorker.decode(data, cutout: true))
        let subject = try #require(decoded.subject)
        #expect(subject.width == decoded.original.width && subject.height == decoded.original.height)
        #expect(subject.alphaInfo == .premultipliedLast || subject.alphaInfo == .premultipliedFirst || subject.alphaInfo == .last || subject.alphaInfo == .first)
    }

    @Test func anUnavailableOptionalShortlistRetainsFirstPassNames() async throws {
        var calls = 0
        let result = try await NewspaperNameGenerator.generate(context: "{}", refine: true) { _ in
            calls += 1
            if calls == 2 { throw NewspaperNameGenerator.Failure.unavailable }
            return #"["Morning Garden","Orbit Journal","The Curious Reader","City Light"]"#
        }
        #expect(result.count == 4 && calls == 2)
    }

}
