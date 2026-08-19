//
//  BibliographyMatcher.swift
//  Straight Up Browser
//
//  Bibliography matching (Phase 5, docs/phase5-design.md): "does anything in
//  my bibliography support this sentence?" — retrieval over the user's own
//  saved sources ONLY. No open-web search, no hallucination surface: every
//  result is a verbatim passage that already sits in the ledger.
//
//  All matching is behind PassageMatcher (mock-first, per SPEC's on-device AI
//  constraint). The default is lexical and deterministic; an NLEmbedding
//  re-rank layers on where the OS provides one. Nothing leaves the device.
//

import Foundation
import NaturalLanguage

// MARK: - Values

nonisolated struct BibliographyPassage: Identifiable, Equatable, Sendable {
    let id: String
    let sourceId: UUID
    let sourceKey: String
    let sourceTitle: String
    let sourceURL: URL?
    let text: String
    /// Non-nil for transcript passages: the spoken window this text covers.
    let startSeconds: Int?
    let endSeconds: Int?

    var isTranscript: Bool { startSeconds != nil }
}

nonisolated struct PassageMatch: Equatable, Sendable {
    enum Band: Equatable, Sendable {
        case strong
        case possible
    }
    let passage: BibliographyPassage
    let score: Double
    /// Shown to the user instead of a raw float — scores are internal.
    let band: Band
}

/// The seam SPEC demands: matching built against mocks before any inference.
/// Phase 6's claim extraction reuses this corpus and this contract.
nonisolated protocol PassageMatcher: Sendable {
    func rank(query: String, passages: [BibliographyPassage]) -> [PassageMatch]
}

// MARK: - Lexical default

/// BM25-shaped token overlap: IDF-weighted, length-dampened, deterministic,
/// pure Swift. No model, no download, identical on every platform.
nonisolated struct LexicalPassageMatcher: PassageMatcher {

    var limit = 8

    /// Deliberately tiny stopword list — over-filtering hurts recall on short
    /// research queries more than noise words hurt precision.
    static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "is", "are", "was",
        "were", "that", "this", "it", "for", "on", "with", "as", "by", "be"
    ]

    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
    }

    func rank(query: String, passages: [BibliographyPassage]) -> [PassageMatch] {
        let queryTerms = Set(Self.tokens(query))
        guard !queryTerms.isEmpty, !passages.isEmpty else { return [] }

        // Document frequencies over the corpus.
        var documentFrequency: [String: Int] = [:]
        let tokenized = passages.map { Set(Self.tokens($0.text)) }
        for passageTerms in tokenized {
            for term in passageTerms where queryTerms.contains(term) {
                documentFrequency[term, default: 0] += 1
            }
        }
        let corpusSize = Double(passages.count)

        var matches: [(match: PassageMatch, matched: Int)] = []
        for (index, passage) in passages.enumerated() {
            let passageTerms = tokenized[index]
            let matchedTerms = queryTerms.intersection(passageTerms)
            guard !matchedTerms.isEmpty else { continue }
            var score = 0.0
            for term in matchedTerms {
                let df = Double(documentFrequency[term] ?? 1)
                score += log(1 + corpusSize / df)
            }
            // Mild length damping: a matched term in a tight passage says more
            // than one in a wall of text.
            score /= log(2 + Double(passageTerms.count))
            let coverage = Double(matchedTerms.count) / Double(queryTerms.count)
            let band: PassageMatch.Band = coverage >= 0.5 && matchedTerms.count >= 2 ? .strong : .possible
            matches.append((PassageMatch(passage: passage, score: score, band: band), matchedTerms.count))
        }
        return matches
            .sorted {
                $0.match.score != $1.match.score
                    ? $0.match.score > $1.match.score
                    : $0.match.passage.id < $1.match.passage.id
            }
            .prefix(limit)
            .map(\.match)
    }
}

// MARK: - On-device embedding re-rank

/// Re-ranks the lexical top-K by NLEmbedding sentence distance when the OS has
/// an embedding for the query's language; otherwise the lexical order stands.
/// Entirely on-device (NaturalLanguage framework); never a network call.
nonisolated struct EmbeddingPassageMatcher: PassageMatcher {

    var base: any PassageMatcher = LexicalPassageMatcher(limit: 20)
    var limit = 8
    /// Test seam: inject a fake distance function; nil = real NLEmbedding.
    var distanceOverride: (@Sendable (String, String) -> Double?)? = nil

    func rank(query: String, passages: [BibliographyPassage]) -> [PassageMatch] {
        let lexical = base.rank(query: query, passages: passages)
        guard lexical.count > 1 else { return Array(lexical.prefix(limit)) }
        guard let distance = makeDistance(query: query) else { return Array(lexical.prefix(limit)) }

        let reranked = lexical.compactMap { match -> (PassageMatch, Double)? in
            guard let d = distance(query, match.passage.text) else { return nil }
            return (match, d)
        }
        guard reranked.count == lexical.count else { return Array(lexical.prefix(limit)) }
        return reranked
            .sorted { $0.1 < $1.1 } // smaller distance = closer meaning
            .prefix(limit)
            .map(\.0)
    }

    // NLEmbedding loads a model from disk; cache one per language across
    // queries instead of rebuilding it per panel keystroke. A cached miss (nil)
    // is remembered too, so unsupported languages don't retry the disk.
    private static let embeddingLock = NSLock()
    nonisolated(unsafe) private static var embeddingCache: [NLLanguage: NLEmbedding?] = [:]

    private static func cachedEmbedding(for language: NLLanguage) -> NLEmbedding? {
        embeddingLock.lock()
        defer { embeddingLock.unlock() }
        if let cached = embeddingCache[language] { return cached }
        let embedding = NLEmbedding.sentenceEmbedding(for: language)
        embeddingCache[language] = embedding
        return embedding
    }

    private func makeDistance(query: String) -> ((String, String) -> Double?)? {
        if let distanceOverride { return distanceOverride }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(query)
        let language = recognizer.dominantLanguage ?? .english
        guard let embedding = Self.cachedEmbedding(for: language) else { return nil }
        return { a, b in
            let d = embedding.distance(between: a, and: b)
            return d.isFinite ? d : nil
        }
    }
}

// MARK: - Corpus assembly

@MainActor
enum BibliographyCorpus {

    /// Transcript captions are short lines; retrieval wants paragraph-ish
    /// windows. Merge consecutive segments up to this many characters.
    nonisolated static let transcriptWindowCharacters = 280
    /// Reader blocks shorter than this carry no evidential weight.
    nonisolated static let minimumPassageCharacters = 40

    /// The workspace's bibliography as passages: reader-extracted blocks plus
    /// windowed transcript segments. Dismissed sources are excluded; sources
    /// with no extracted text contribute nothing (open them once to fill in).
    static func passages(workspaceId: UUID, ledgerStore: LedgerStore) -> [BibliographyPassage] {
        var passages: [BibliographyPassage] = []
        var seenSourceIds: Set<UUID> = []
        for ref in ledgerStore.references(workspaceId: workspaceId) where ref.disposition != .dismissed {
            guard let article = ledgerStore.source(sourceKey: ref.sourceKey),
                  seenSourceIds.insert(article.id).inserted else { continue }

            if let document = article.document {
                for block in document.blocks {
                    let text = block.content.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard text.count >= minimumPassageCharacters else { continue }
                    passages.append(BibliographyPassage(
                        id: "\(article.sourceKey)#\(block.id)",
                        sourceId: article.id, sourceKey: article.sourceKey,
                        sourceTitle: article.title, sourceURL: article.url,
                        text: text, startSeconds: nil, endSeconds: nil))
                }
            }
            if let transcript = ledgerStore.transcript(sourceKey: article.sourceKey) {
                passages.append(contentsOf: windowedTranscript(
                    transcript.segments, article: article))
            }
        }
        return passages
    }

    nonisolated static func windowedTranscript(
        _ segments: [TranscriptSegment],
        article: NewspaperArticle
    ) -> [BibliographyPassage] {
        windowed(segments).enumerated().map { index, window in
            BibliographyPassage(
                id: "\(article.sourceKey)#t\(index)",
                sourceId: article.id, sourceKey: article.sourceKey,
                sourceTitle: article.title, sourceURL: article.url,
                text: window.text,
                startSeconds: window.start, endSeconds: window.end)
        }
    }

    nonisolated static func windowed(
        _ segments: [TranscriptSegment]
    ) -> [(text: String, start: Int, end: Int)] {
        var windows: [(String, Int, Int)] = []
        var currentText = ""
        var start: Int?
        var end = 0
        for segment in segments {
            if start == nil { start = segment.startSeconds }
            currentText += (currentText.isEmpty ? "" : " ") + segment.t
            end = segment.endSeconds
            if currentText.count >= transcriptWindowCharacters {
                windows.append((currentText, start ?? 0, end))
                currentText = ""
                start = nil
            }
        }
        if let start, !currentText.isEmpty {
            windows.append((currentText, start, end))
        }
        return windows.map { (text: $0.0, start: $0.1, end: $0.2) }
    }
}
