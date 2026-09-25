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

    func call(arguments: [String: Any]) async -> String {
        let query = (arguments["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return json(["error": "A query is required."]) }
        let limit = min(max(arguments["limit"] as? Int ?? 8, 1), 20)
        let matches = await search(query: query, limit: limit)
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

    func search(query: String, limit: Int) async -> [PassageMatch] {
        guard let ledgerStore else { return [] }
        var passages = await BibliographyCorpus.passages(ledgerStore: ledgerStore)
        passages.append(contentsOf: await notePassages())
        return await PassageRanking.shared.rank(query: query, passages: passages, limit: limit)
    }

    /// Workspace notes are Markdown on disk; one passage per paragraph. Rows
    /// whose file has not synced down yet simply contribute nothing.
    private func notePassages() async -> [BibliographyPassage] {
        guard let documentStore else { return [] }
        let notes = documentStore.allDocuments().compactMap { row -> Note? in
            guard let url = documentStore.url(for: row) else { return nil }
            return Note(id: row.id, path: row.relativePath, title: row.displayName, url: url)
        }
        return await Self.readNotes(notes)
    }

    nonisolated struct Note: Sendable {
        let id: UUID
        let path: String
        let title: String
        let url: URL
    }

    @concurrent static func readNotes(_ notes: [Note]) async -> [BibliographyPassage] {
        assert(!Thread.isMainThread)
        var passages: [BibliographyPassage] = []
        for note in notes {
            guard !Task.isCancelled else { return [] }
            guard let text = try? String(contentsOf: note.url, encoding: .utf8) else { continue }
            for (index, paragraph) in text.components(separatedBy: "\n\n").enumerated() {
                let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= BibliographyCorpus.minimumPassageCharacters else { continue }
                passages.append(BibliographyPassage(
                    id: "note:\(note.id.uuidString)#\(index)", sourceId: note.id, sourceKey: note.path,
                    sourceTitle: "Note: \(note.title)", sourceURL: nil,
                    text: trimmed, startSeconds: nil, endSeconds: nil))
            }
        }
        return passages
    }

    private func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{\"error\":\"Encoding failed.\"}" }
        return string
    }
}
