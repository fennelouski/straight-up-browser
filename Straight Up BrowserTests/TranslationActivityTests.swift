//
//  TranslationActivityTests.swift
//  Straight Up BrowserTests
//

import Testing
import Foundation
@testable import Browser

struct TranslationHistoryStoreTests {

    private func store() -> TranslationHistoryStore {
        TranslationHistoryStore(defaults: UserDefaults(suiteName: "translation-history-\(UUID().uuidString)")!)
    }

    @Test func detectionThenTranslationMergeIntoOneRecord() {
        let store = store()
        store.recordDetection(host: "example.com", title: "Example", source: "fr", target: "en")
        store.recordTranslation(host: "example.com", title: "Example", source: "fr", target: "en")

        let record = store.records["example.com"]
        #expect(record?.detectCount == 1)
        #expect(record?.translateCount == 1)
        #expect(record?.translatedAt != nil)
    }

    @Test func detectionAloneLeavesTranslatedAtNil() {
        let store = store()
        store.recordDetection(host: "example.com", title: "Example", source: "fr", target: "en")
        #expect(store.records["example.com"]?.translatedAt == nil)
    }
}

struct TranslationLanguageUsageTests {

    private func usage() -> TranslationLanguageUsage {
        TranslationLanguageUsage(defaults: UserDefaults(suiteName: "translation-usage-\(UUID().uuidString)")!)
    }

    @Test func staleRequiresBothOldInstallAndLongUnused() {
        let usage = usage()
        let now = Date()
        usage.markInstalled("fr", now: now.addingTimeInterval(-90 * 86400))
        usage.markUsed("fr", now: now.addingTimeInterval(-70 * 86400))
        #expect(usage.staleCandidates(now: now).map(\.code) == ["fr"])
    }

    @Test func recentlyUsedIsNotStale() {
        let usage = usage()
        let now = Date()
        usage.markInstalled("fr", now: now.addingTimeInterval(-90 * 86400))
        usage.markUsed("fr", now: now.addingTimeInterval(-5 * 86400))
        #expect(usage.staleCandidates(now: now).isEmpty)
    }

    @Test func recentlyInstalledIsNotStaleEvenIfUnused() {
        let usage = usage()
        let now = Date()
        usage.markInstalled("fr", now: now.addingTimeInterval(-10 * 86400))
        #expect(usage.staleCandidates(now: now).isEmpty)
    }

    @Test func markInstalledDoesNotOverwriteAnExistingDate() {
        let usage = usage()
        let now = Date()
        let original = now.addingTimeInterval(-90 * 86400)
        usage.markInstalled("fr", now: original)
        usage.markInstalled("fr", now: now)
        #expect(usage.packs["fr"]?.installedAt == original)
    }
}

struct PageTranslatorTextTests {

    private let dutch = "Beste Nathan, hierbij stuur ik je de documenten die je gisteren hebt gevraagd. Laat het me weten als er nog iets ontbreekt."
    private let english = "Please find attached the documents you asked for yesterday. Let me know if anything is missing from the set."

    @Test func sampleTakesTheLongestNodesFirst() {
        let nodes: [PageTranslator.TextNode] = [("a", "Inbox"), ("b", dutch), ("c", "Sent")]
        #expect(PageTranslator.sample(from: nodes).hasPrefix(dutch))
        #expect(PageTranslator.sample(from: nodes, limit: 10).count == 10)
    }

    @Test func foreignNodesKeepsWhatIsNotConfidentlyInTheTarget() {
        let nodes: [PageTranslator.TextNode] = [("chrome", english), ("mail", dutch), ("short", "Inbox")]
        #expect(PageTranslator.foreignNodes(nodes, target: "en").map(\.id) == ["mail", "short"])
        #expect(PageTranslator.foreignNodes(nodes, target: "nl").map(\.id) == ["chrome", "short"])
    }

    @Test func detectLanguageHonorsConfidence() {
        #expect(PageTranslator.detectLanguage(dutch) == "nl")
        #expect(PageTranslator.detectLanguage(english) == "en")
        #expect(PageTranslator.detectLanguage("ok", minimumConfidence: 0.99) == nil)
    }
}
