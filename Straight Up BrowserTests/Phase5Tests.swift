//
//  Phase5Tests.swift
//  Straight Up BrowserTests
//
//  Bibliography matching (docs/phase5-design.md): the lexical matcher's
//  determinism, the protocol's mock seam, transcript windowing, and the
//  band semantics — all pure, no SwiftData, no inference.
//

import Foundation
import Testing
import SwiftData
@testable import Browser

private func passage(_ id: String, _ text: String, start: Int? = nil, end: Int? = nil) -> BibliographyPassage {
    BibliographyPassage(
        id: id, sourceId: UUID(), sourceKey: "https://s.example/\(id)",
        sourceTitle: "Source \(id)", sourceURL: URL(string: "https://s.example/\(id)"),
        text: text, startSeconds: start, endSeconds: end)
}

struct LexicalMatcherTests {

    private let corpus = [
        passage("a", "Fermentation of cabbage produces lactic acid bacteria in large numbers."),
        passage("b", "The gut microbiome changes composition after sustained dietary shifts."),
        passage("c", "Lactic acid bacteria from fermented foods can survive gastric transit."),
        passage("d", "A completely unrelated passage about typography and kerning."),
    ]

    @Test func ranksOverlapAboveNoise() {
        let matches = LexicalPassageMatcher().rank(
            query: "lactic acid bacteria from fermentation", passages: corpus)
        #expect(!matches.isEmpty)
        #expect(matches.first.map { ["a", "c"].contains($0.passage.id) } == true)
        #expect(!matches.contains { $0.passage.id == "d" }, "zero-overlap passages never appear")
    }

    @Test func tokenizerDropsStopwordsAndPunctuation() {
        let tokens = LexicalPassageMatcher.tokens("The gut, and THE microbiome — of mice!")
        #expect(tokens == ["gut", "microbiome", "mice"])
    }

    @Test func coverageDecidesTheBand() {
        let matches = LexicalPassageMatcher().rank(
            query: "lactic acid bacteria survive gastric transit", passages: corpus)
        let c = matches.first { $0.passage.id == "c" }
        #expect(c?.band == .strong, "most query terms present = strong")
        // One matched term out of many query terms is only ever "possible".
        let weak = LexicalPassageMatcher().rank(
            query: "typography alignment ligatures hyphenation grids", passages: corpus)
        #expect(weak.first { $0.passage.id == "d" }?.band == .possible)
    }

    @Test func emptyQueriesAndCorporaAreSilent() {
        #expect(LexicalPassageMatcher().rank(query: "", passages: corpus).isEmpty)
        #expect(LexicalPassageMatcher().rank(query: "the of and", passages: corpus).isEmpty)
        #expect(LexicalPassageMatcher().rank(query: "bacteria", passages: []).isEmpty)
    }

    @Test func deterministicOrderOnTies() {
        let twins = [passage("t2", "identical twin passage"), passage("t1", "identical twin passage")]
        let first = LexicalPassageMatcher().rank(query: "identical twin", passages: twins)
        let second = LexicalPassageMatcher().rank(query: "identical twin", passages: twins)
        #expect(first.map(\.passage.id) == second.map(\.passage.id))
        #expect(first.map(\.passage.id) == ["t1", "t2"], "ties break on id, not input order")
    }
}

struct MatcherProtocolSeamTests {

    /// The SPEC-mandated mock seam: any conforming type slots in.
    private struct FixedMatcher: PassageMatcher {
        let result: [PassageMatch]
        func rank(query: String, passages: [BibliographyPassage]) -> [PassageMatch] { result }
    }

    @Test func embeddingMatcherFallsBackWhenDistanceUnavailable() {
        let corpus = [passage("a", "alpha beta gamma"), passage("b", "alpha beta delta")]
        var matcher = EmbeddingPassageMatcher()
        matcher.distanceOverride = { _, _ in nil } // "no embedding for this language"
        let lexical = LexicalPassageMatcher(limit: 20).rank(query: "alpha beta", passages: corpus)
        let ranked = matcher.rank(query: "alpha beta", passages: corpus)
        #expect(ranked.map(\.passage.id) == Array(lexical.prefix(8)).map(\.passage.id),
                "no embedding → the lexical order stands")
    }

    @Test func embeddingDistanceReordersTheLexicalTopK() {
        let corpus = [passage("far", "alpha beta remote"), passage("near", "alpha beta close")]
        var matcher = EmbeddingPassageMatcher()
        matcher.distanceOverride = { _, text in text.contains("close") ? 0.1 : 0.9 }
        let ranked = matcher.rank(query: "alpha beta", passages: corpus)
        #expect(ranked.first?.passage.id == "near")
    }

    @Test func anyConformerSlotsIn() {
        let fixed = FixedMatcher(result: [PassageMatch(passage: passage("x", "x"), score: 1, band: .strong)])
        var matcher = EmbeddingPassageMatcher()
        matcher.base = fixed
        matcher.distanceOverride = { _, _ in nil }
        #expect(matcher.rank(query: "anything", passages: []).first?.passage.id == "x")
    }
}

struct TranscriptWindowingTests {

    @Test func shortSegmentsMergeIntoWindowsWithSpannedTimes() {
        let segments = (0..<30).map { index in
            TranscriptSegment(s: Double(index * 10), d: 9,
                              t: "caption line number \(index) with several words")
        }
        let windows = BibliographyCorpus.windowed(segments)
        #expect(windows.count > 1, "long transcripts split into windows")
        #expect(windows.allSatisfy { $0.text.count >= 40 })
        #expect(windows.first?.start == 0)
        for window in windows { #expect(window.end > window.start) }
        // Nothing is dropped: the last caption's words are in the last window.
        #expect(windows.last?.text.contains("number 29") == true)
    }

    @Test func aFewShortLinesStillMakeOneWindow() {
        let segments = [TranscriptSegment(s: 5, d: 3, t: "just one line")]
        let windows = BibliographyCorpus.windowed(segments)
        #expect(windows.count == 1)
        #expect(windows[0].start == 5)
        #expect(windows[0].text == "just one line")
    }

    @Test func emptyTranscriptsMakeNoWindows() {
        #expect(BibliographyCorpus.windowed([]).isEmpty)
    }
}

@MainActor
struct ResearchSearchWorkerTests {
    @Test func backgroundCorpusIncludesSavedTranscriptsAndExcludesDismissedSources() async throws {
        let container = try ModelContainer(for: NewspaperArticle.self, WorkspaceSourceRef.self, SourceTranscript.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let ledger = LedgerStore(modelContext: context)
        let source = NewspaperArticle(url: URL(string: "https://example.com/video")!, title: "Video")
        let reference = WorkspaceSourceRef(workspaceId: UUID(), sourceId: source.id,
                                           sourceKey: source.sourceKey, method: .settle)
        context.insert(source)
        context.insert(reference)
        context.insert(SourceTranscript(sourceId: source.id, sourceKey: source.sourceKey, languageCode: "en",
            isAutoGenerated: false, segmentsData: try JSONEncoder().encode([
                TranscriptSegment(s: 0, d: 4, t: "This stored transcript describes lactic acid fermentation in cabbage.")
            ])))
        try context.save()
        let loaded = await BibliographyCorpus.passages(ledgerStore: ledger)
        #expect(loaded.count == 1)
        #expect(loaded.first?.sourceId == source.id)
        reference.disposition = .dismissed
        try context.save()
        #expect(await BibliographyCorpus.passages(ledgerStore: ledger).isEmpty)
    }

    @Test func readsNotesAndRanksOffMainActor() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let text = "Fermented cabbage contains lactic acid bacteria and supports research into fermentation."
        try text.write(to: file, atomically: true, encoding: .utf8)
        let notes = await ResearchRecall.readNotes([.init(id: UUID(), path: "Notes.md", title: "Notes", url: file)])
        let matches = await PassageRanking.shared.rank(query: "lactic acid", passages: notes)
        #expect(matches.first?.passage.text == text)
        #expect(matches.first?.passage.sourceTitle == "Note: Notes")
        let cancelled = Task {
            while !Task.isCancelled { await Task.yield() }
            return await ResearchRecall.readNotes([.init(id: UUID(), path: "Notes.md", title: "Notes", url: file)])
        }
        cancelled.cancel()
        #expect(await cancelled.value.isEmpty)
    }
}
