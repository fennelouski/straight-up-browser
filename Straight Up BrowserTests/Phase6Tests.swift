//
//  Phase6Tests.swift
//  Straight Up BrowserTests
//
//  Background claim extraction (docs/phase6-design.md): the heuristic's shape
//  test, the never-re-extract cache, the scout's candidate lifecycle, and
//  promotion's dedup + edge stamping.
//

import Foundation
import SwiftData
import Testing
@testable import Browser

struct HeuristicClaimTests {

    @Test func claimShapedSentencesCarryNumbersOrMarkers() {
        #expect(HeuristicClaimExtractor.isClaimShaped(
            "Fermented foods reduce inflammation markers in most adults."))
        #expect(HeuristicClaimExtractor.isClaimShaped(
            "The study followed 412 participants over two years."))
        #expect(!HeuristicClaimExtractor.isClaimShaped(
            "What does the microbiome even do?"), "questions are not claims")
        #expect(!HeuristicClaimExtractor.isClaimShaped(
            "I went for a walk and thought about the draft for a while today."),
            "no number, no marker: not checkable")
        #expect(!HeuristicClaimExtractor.isClaimShaped(
            "# Fermentation reduces spoilage in 90 percent of cases"), "headings are furniture")
        #expect(!HeuristicClaimExtractor.isClaimShaped(
            "See [the study](https://x.example) which found that gut flora shifted."),
            "citation lines are already anchored prose")
        #expect(!HeuristicClaimExtractor.isClaimShaped("Too short."), "length floor")
    }

    @Test func extractorReturnsOnlyClaimShapedSentences() async {
        let paragraph = "I drafted this yesterday. Sauerkraut contains more vitamin C than raw cabbage. Is that even true?"
        let claims = await HeuristicClaimExtractor().claims(in: paragraph)
        #expect(claims == ["Sauerkraut contains more vitamin C than raw cabbage."])
    }
}

@MainActor
struct ClaimScoutTests {

    /// Counts extraction calls to pin the never-re-extract rule.
    private final class CountingExtractor: ClaimExtractor, @unchecked Sendable {
        var seen: [String] = []
        func claims(in paragraph: String) async -> [String] {
            seen.append(paragraph)
            return await HeuristicClaimExtractor().claims(in: paragraph)
        }
    }

    @Test func unchangedParagraphsAreNeverReExtracted() async throws {
        let counter = CountingExtractor()
        let scout = ClaimScout(extractor: counter)
        let text = "Stable intro paragraph that never changes at all here.\n\nKimchi ferments faster at 21 degrees than at 4 degrees."
        scout.noteText(text, resolvedLinkRanges: [], immediate: true)
        try await Task.sleep(for: .milliseconds(300))
        let firstCount = counter.seen.count
        #expect(firstCount == 2)

        // Edit only the second paragraph: the first must come from cache.
        let edited = "Stable intro paragraph that never changes at all here.\n\nKimchi ferments faster at 21 degrees than at 6 degrees."
        scout.noteText(edited, resolvedLinkRanges: [], immediate: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.seen.count == firstCount + 1, "only the changed paragraph re-extracts")
    }

    @Test func supportSplitsThePlanFromTheSupported() async throws {
        let scout = ClaimScout(extractor: HeuristicClaimExtractor())
        let text = "Kimchi ferments faster at 21 degrees than at 4 degrees.\n\nSauerkraut contains more vitamin C than raw cabbage."
        let firstParagraph = (text as NSString).range(of: "Kimchi ferments faster at 21 degrees than at 4 degrees.")
        scout.noteText(text, resolvedLinkRanges: [NSRange(location: firstParagraph.location, length: 5)], immediate: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(scout.candidates.count == 2)
        #expect(scout.candidates.first { $0.text.hasPrefix("Kimchi") }?.hasSupport == true)
        #expect(scout.candidates.first { $0.text.hasPrefix("Sauerkraut") }?.hasSupport == false,
                "no edge in its paragraph → the research plan")
    }

    @Test func dismissalVanishesForTheSessionAndWritesNothing() async throws {
        let scout = ClaimScout(extractor: HeuristicClaimExtractor())
        let text = "Sauerkraut contains more vitamin C than raw cabbage."
        scout.noteText(text, resolvedLinkRanges: [], immediate: true)
        try await Task.sleep(for: .milliseconds(300))
        let candidate = try #require(scout.candidates.first)
        scout.dismiss(candidate)
        #expect(scout.candidates.isEmpty)
        scout.noteText(text, resolvedLinkRanges: [], immediate: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(scout.candidates.isEmpty, "a dismissed candidate stays gone this session")
    }

    @Test func promotedClaimsNeverReappearAsCandidates() async throws {
        let scout = ClaimScout(extractor: HeuristicClaimExtractor())
        scout.isAlreadyPromoted = { $0.contains("Sauerkraut") }
        scout.noteText("Sauerkraut contains more vitamin C than raw cabbage.",
                       resolvedLinkRanges: [], immediate: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(scout.candidates.isEmpty)
    }
}

@MainActor
struct ClaimPromotionTests {

    private func makeStore() throws -> (ModelContainer, ModelContext, LedgerStore) {
        let schema = Schema([
            NewspaperArticle.self, Workspace.self, WorkspaceSourceRef.self,
            WorkspaceDocument.self, LedgerAnchor.self, LedgerClaim.self,
            LedgerEdge.self, LedgerArchive.self, SourceTranscript.self, Tab.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        return (container, context, LedgerStore(modelContext: context))
    }

    @Test func promotionDeduplicatesOnNormalizedText() throws {
        let (_, _, ledger) = try makeStore()
        let first = ledger.promoteClaim(text: "Kimchi  ferments FASTER at 21 degrees.")
        let second = ledger.promoteClaim(text: "kimchi ferments faster at 21 degrees.")
        #expect(first.id == second.id, "same normalized text = same claim, across projects")
        #expect(ledger.claimExists(normalizedFrom: "KIMCHI ferments faster at 21 degrees."))
        #expect(!ledger.claimExists(normalizedFrom: "an entirely different claim"))
    }

    @Test func promotionStampsOnlyEdgesInsideTheParagraph() throws {
        let (_, context, ledger) = try makeStore()
        let documentId = UUID()
        let inside = LedgerEdge(documentId: documentId, anchorId: UUID(), rangeQuote: "in", rangeStart: 10, rangeLength: 5)
        let outside = LedgerEdge(documentId: documentId, anchorId: UUID(), rangeQuote: "out", rangeStart: 500, rangeLength: 5)
        context.insert(inside); context.insert(outside)
        try context.save()

        let claim = ledger.promoteClaim(text: "A claim about the paragraph at hand.")
        ledger.stampClaim(claim.id, documentId: documentId, within: NSRange(location: 0, length: 100))
        #expect(inside.claimId == claim.id, "LedgerEdge.claimId gains its first writer")
        #expect(outside.claimId == nil)
    }

    @Test func stampingNeverOverwritesAnEarlierClaim() throws {
        let (_, context, ledger) = try makeStore()
        let documentId = UUID()
        let earlier = UUID()
        let edge = LedgerEdge(documentId: documentId, anchorId: UUID(), rangeQuote: "q", rangeStart: 10, rangeLength: 5, claimId: earlier)
        context.insert(edge)
        try context.save()
        let claim = ledger.promoteClaim(text: "A second claim in the same paragraph.")
        ledger.stampClaim(claim.id, documentId: documentId, within: NSRange(location: 0, length: 100))
        #expect(edge.claimId == earlier, "first promotion wins; re-stamping is not a merge tool")
    }
}
