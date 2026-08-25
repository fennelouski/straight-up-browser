//
//  ResearchRecall.swift
//  Straight Up Browser
//
//  The agent's read-only window into the research ledger: verbatim passages
//  from every captured source, transcript, and workspace note, ranked by the
//  same on-device matcher the Bibliography panel uses. No open web, nothing
//  leaves the device, and every hit carries the URL it must be cited with.
//

import Foundation

@MainActor
final class ResearchRecall {
    static let shared = ResearchRecall()
    nonisolated static let toolName = "search_research"

    var ledgerStore: LedgerStore?
    var documentStore: DocumentStore?

    func call(arguments: [String: Any]) -> String {
        let query = (arguments["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return json(["error": "A query is required."]) }
        let limit = min(max(arguments["limit"] as? Int ?? 8, 1), 20)
        let matches = search(query: query, limit: limit)
        return json([
            "count": matches.count,
            "passages": matches.map { match in
                var entry: [String: Any] = [
                    "text": match.passage.text,
                    "title": match.passage.sourceTitle,
                    "confidence": match.band == .strong ? "strong" : "possible",
                ]
                if let url = match.passage.sourceURL { entry["sourceURL"] = url.absoluteString }
                if let start = match.passage.startSeconds { entry["startSeconds"] = start }
                return entry
            },
        ])
    }

    func search(query: String, limit: Int) -> [PassageMatch] {
        guard let ledgerStore else { return [] }
        var passages = BibliographyCorpus.passages(ledgerStore: ledgerStore)
        passages.append(contentsOf: notePassages())
        return EmbeddingPassageMatcher(limit: limit).rank(query: query, passages: passages)
    }

    /// Workspace notes are Markdown on disk; one passage per paragraph. Rows
    /// whose file has not synced down yet simply contribute nothing.
    private func notePassages() -> [BibliographyPassage] {
        guard let documentStore else { return [] }
        return documentStore.allDocuments().flatMap { row -> [BibliographyPassage] in
            guard let url = documentStore.url(for: row),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.components(separatedBy: "\n\n").enumerated().compactMap { index, paragraph in
                let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= BibliographyCorpus.minimumPassageCharacters else { return nil }
                return BibliographyPassage(
                    id: "note:\(row.id.uuidString)#\(index)",
                    sourceId: row.id, sourceKey: row.relativePath,
                    sourceTitle: "Note: \(row.displayName)", sourceURL: nil,
                    text: trimmed, startSeconds: nil, endSeconds: nil)
            }
        }
    }

    private func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{\"error\":\"Encoding failed.\"}" }
        return string
    }
}
