//
//  ClaimExtraction.swift
//  Straight Up Browser
//
//  Background claim extraction (Phase 6, docs/phase6-design.md): paragraphs of
//  the user's own writing → candidate claims, advisory until promoted. The
//  default extractor is deterministic and model-free; the on-device
//  FoundationModels extractor layers on ONLY where the OS provides it and the
//  user's AI Features switch is on — and it may only SELECT verbatim sentences,
//  never write: anything the paragraph doesn't literally contain is discarded.
//

import Combine
import CryptoKit
import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - The seam (SPEC: mock-first, like Phase 5's PassageMatcher)

nonisolated protocol ClaimExtractor: Sendable {
    func claims(in paragraph: String) async -> [String]
}

// MARK: - Heuristic default

/// Sentence segmentation plus a deterministic claim-shape test. Misses subtle
/// claims by design — advisory output has no completeness contract.
nonisolated struct HeuristicClaimExtractor: ClaimExtractor {

    /// Single-token markers, matched against the sentence's own tokens — a
    /// phrase list broke on inflection ("reduce" vs "reduces") and on split
    /// comparatives ("more vitamin C than").
    static let markerTokens: Set<String> = [
        "cause", "causes", "caused", "causing",
        "reduce", "reduces", "reduced", "increase", "increases", "increased",
        "improve", "improves", "improved", "prevent", "prevents", "prevented",
        "leads", "linked", "associated", "results", "higher", "lower",
        "significantly", "shows", "found", "evidence", "percent", "likely",
        "risk", "most", "least", "faster", "slower", "stronger", "weaker"
    ]
    /// "more … than" / "less … than": a split comparative is a claim shape too.
    static let comparativeHeads: Set<String> = ["more", "less", "fewer", "better", "worse"]

    func claims(in paragraph: String) async -> [String] {
        Self.sentences(in: paragraph).filter(Self.isClaimShaped)
    }

    static func sentences(in paragraph: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = paragraph
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
            let sentence = paragraph[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        return sentences
    }

    /// Declarative, bounded, and carrying a number or a causal/comparative
    /// marker — the shape of something checkable.
    static func isClaimShaped(_ sentence: String) -> Bool {
        guard sentence.count >= 30, sentence.count <= 240 else { return false }
        guard !sentence.hasSuffix("?") else { return false }
        // Markdown furniture and citation lines are not prose claims.
        for prefix in ["#", "-", ">", "*", "|", "```"] where sentence.hasPrefix(prefix) { return false }
        guard !sentence.contains("](") else { return false }
        let tokens = Set(sentence.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
        let hasNumber = sentence.rangeOfCharacter(from: .decimalDigits) != nil
        let hasMarker = !tokens.isDisjoint(with: markerTokens)
        let hasComparative = tokens.contains("than") && !tokens.isDisjoint(with: comparativeHeads)
        return hasNumber || hasMarker || hasComparative
    }
}

// MARK: - On-device model, verbatim-only

/// The AgentPageAI pattern: availability-gated FoundationModels, graceful
/// fallback on any error. The model may only pick sentences that already exist
/// in the paragraph; the containment guard makes paraphrase impossible.
nonisolated struct FoundationModelClaimExtractor: ClaimExtractor {

    var fallback: any ClaimExtractor = HeuristicClaimExtractor()

    func claims(in paragraph: String) async -> [String] {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let aiEnabled = await MainActor.run { SettingsManager.shared.aiFeaturesEnabled }
            if aiEnabled, SystemLanguageModel.default.availability == .available {
                if let picked = await modelClaims(in: paragraph) { return picked }
            }
        }
        #endif
        return await fallback.claims(in: paragraph)
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, iOS 26.0, *)
    private func modelClaims(in paragraph: String) async -> [String]? {
        let session = LanguageModelSession(instructions: """
            List the checkable factual claims in the user's paragraph.
            Reply with each claim as ONE exact sentence copied verbatim from the paragraph, one per line.
            Reply with exactly NONE if there are no checkable claims.
            Never invent, rephrase, shorten, or explain.
            """)
        do {
            let response = try await session.respond(to: String(paragraph.prefix(1200))).content
            if response.trimmingCharacters(in: .whitespacesAndNewlines) == "NONE" { return [] }
            // The containment guard: selection, never generation.
            let lines = response.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && paragraph.contains($0) }
            return lines
        } catch {
            return nil
        }
    }
    #endif
}

// MARK: - Candidates

nonisolated struct ClaimCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    /// UTF-16 range of the containing paragraph in the document.
    let paragraphRange: NSRange
    /// True when the paragraph already has at least one edge — it leaves the
    /// research plan and joins the supported group.
    let hasSupport: Bool
}

// MARK: - The scout

/// Paragraph-settle extraction with the never-re-extract cache: paragraphs are
/// SHA-256 hashed; only new hashes are extracted, for the scout's lifetime.
/// Nothing persists — silence is the default, and everything dies with the
/// panel (SPEC's suspension constraint, satisfied by owning no background work).
@MainActor
final class ClaimScout: ObservableObject {

    @Published private(set) var candidates: [ClaimCandidate] = []
    @Published private(set) var isExtracting = false

    private let extractor: any ClaimExtractor
    /// Session-scope dismissals; a dismissed candidate vanishes and is never
    /// recorded anywhere.
    private var dismissed: Set<String> = []
    private var cache: [String: [String]] = [:]
    /// Filters candidates already promoted in the ledger (normalized match).
    var isAlreadyPromoted: (String) -> Bool = { _ in false }

    /// SPEC: paragraph-settle debounce, never per keystroke.
    static let settleDebounce: Duration = .seconds(3)
    private var pending: Task<Void, Never>?

    init(extractor: any ClaimExtractor = FoundationModelClaimExtractor()) {
        self.extractor = extractor
    }

    /// Text changed (or the panel opened): re-scan after the settle debounce.
    func noteText(_ markdown: String, resolvedLinkRanges: [NSRange], immediate: Bool = false) {
        pending?.cancel()
        pending = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: Self.settleDebounce)
                guard !Task.isCancelled else { return }
            }
            await self?.rescan(markdown: markdown, resolvedLinkRanges: resolvedLinkRanges)
        }
    }

    func dismiss(_ candidate: ClaimCandidate) {
        dismissed.insert(candidate.id)
        candidates.removeAll { $0.id == candidate.id }
    }

    private func rescan(markdown: String, resolvedLinkRanges: [NSRange]) async {
        isExtracting = true
        defer { isExtracting = false }
        let blocks = AuditModel.parseBlocks(markdown)
        var next: [ClaimCandidate] = []
        for block in blocks where block.isProse {
            let hash = Self.hash(block.text)
            let claims: [String]
            if let cached = cache[hash] {
                claims = cached
            } else {
                claims = await extractor.claims(in: block.text)
                cache[hash] = claims
            }
            let hasSupport = resolvedLinkRanges.contains { NSLocationInRange($0.location, block.range) }
            for (index, text) in claims.enumerated() {
                let id = "\(hash)-\(index)"
                guard !dismissed.contains(id), !isAlreadyPromoted(text) else { continue }
                next.append(ClaimCandidate(
                    id: id, text: text, paragraphRange: block.range, hasSupport: hasSupport))
            }
        }
        candidates = next
    }

    nonisolated static func hash(_ paragraph: String) -> String {
        SHA256.hash(data: Data(paragraph.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
