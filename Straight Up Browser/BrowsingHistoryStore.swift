import Foundation
import Combine

nonisolated struct HistoryVisit: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    var title: String
    var visitedAt: Date

    init(id: UUID = UUID(), url: URL, title: String, visitedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
    }
}

/// Local, durable browsing history. It is deliberately separate from SwiftData:
/// visits never sync to CloudKit, and private-session visits are rejected by the
/// recording interface before they can reach memory or disk.
@MainActor
final class BrowsingHistoryStore: ObservableObject {
    static let shared = BrowsingHistoryStore()

    @Published private(set) var visits: [HistoryVisit] = []

    private let file: JSONHistoryFile<[HistoryVisit]>
    private var loadingTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var isLoaded = false
    private var needsSave = false
    private var startupMutations: [(inout [HistoryVisit]) -> Void] = []
    private let maxVisits: Int

    init(storeURL: URL? = nil, maxVisits: Int = 5_000) {
        let url = storeURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Straight Up Browser", isDirectory: true)
            .appendingPathComponent("browsing-history.json")
        file = JSONHistoryFile(url: url)
        self.maxVisits = max(1, maxVisits)
        let file = file
        let limit = self.maxVisits
        loadingTask = Task { [weak self] in
            var loaded: [HistoryVisit] = []
            var hadFile = false
            do {
                if let values = try await file.load(transform: {
                    Array($0.sorted { $0.visitedAt > $1.visitedAt }.prefix(limit))
                }) {
                    loaded = values
                    hadFile = true
                }
            } catch {
                PersistenceDiagnostics.shared.report(operation: "Load browsing history", error: error)
            }
            guard let self else { return }
            for mutation in self.startupMutations { mutation(&loaded) }
            self.startupMutations.removeAll()
            self.visits = loaded
            self.isLoaded = true
            if hadFile || self.needsSave { self.save() }
        }
    }

    var recentVisits: [HistoryVisit] {
        var seen: Set<String> = []
        return visits.filter { seen.insert($0.url.absoluteString).inserted }
    }

    /// Fuzzy history search for the omnibar: the typed characters have to appear
    /// in order somewhere in the page's title or URL, and results are ranked by
    /// how cleanly they matched, how often you go there, and how recently.
    /// Empty query = your most recent pages.
    func search(_ query: String, limit: Int = 10) -> [HistoryVisit] {
        Self.search(query, visits: visits, limit: limit)
    }

    nonisolated static func search(_ query: String, visits: [HistoryVisit], limit: Int = 10) -> [HistoryVisit] {
        var seen: Set<String> = []
        let recents = visits.filter { seen.insert($0.url.absoluteString).inserted }
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return Array(recents.prefix(limit)) }

        var counts: [String: Int] = [:]
        for visit in visits { counts[visit.url.absoluteString, default: 0] += 1 }

        let now = Date()
        let scored = recents.compactMap { visit -> (HistoryVisit, Double)? in
            guard let match = Self.fuzzyScore(needle, in: visit.title + " " + visit.url.absoluteString)
            else { return nil }
            let count = Double(counts[visit.url.absoluteString] ?? 1)
            let days = max(0, now.timeIntervalSince(visit.visitedAt)) / 86_400
            return (visit, match + 2 * log2(count + 1) + 8 / (1 + days))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    // Greedy left-to-right subsequence match. Characters that continue a run, or
    // that start a word ("g" of "/gist"), are worth more than ones buried
    // mid-word — so "ghpr" ranks github.com/…/pulls above a stray letter soup.
    // ponytail: greedy, not optimal alignment; swap in a real fuzzy lib only if
    // rankings actually feel wrong.
    nonisolated static func fuzzyScore(_ needle: [Character], in haystack: String) -> Double? {
        let hay = Array(haystack.lowercased())
        var score = 0.0
        var matched = 0
        var lastMatch = -2
        for (i, character) in hay.enumerated() {
            guard matched < needle.count else { break }
            guard character == needle[matched] else { continue }
            let previous = i > 0 ? hay[i - 1] : " "
            if i == lastMatch + 1 {
                score += 3                                  // consecutive
            } else if !previous.isLetter && !previous.isNumber {
                score += 2                                  // start of a word
            } else {
                score += 1
            }
            lastMatch = i
            matched += 1
        }
        return matched == needle.count ? score : nil
    }

    func record(
        url: URL,
        title: String?,
        sessionKind: SessionKind,
        visitedAt: Date = Date()
    ) {
        guard sessionKind != .incognito,
              url.scheme == "http" || url.scheme == "https" else { return }
        let visit = HistoryVisit(url: url,
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? url.host ?? url.absoluteString, visitedAt: visitedAt)
        let limit = maxVisits
        mutate { visits in
            visits.insert(visit, at: 0)
            if visits.count > limit { visits.removeLast(visits.count - limit) }
        }
    }

    func remove(url: URL) {
        mutate { $0.removeAll { $0.url.absoluteString == url.absoluteString } }
    }

    func remove(from start: Date?, through end: Date?) {
        mutate { visits in
            visits.removeAll { visit in
                let afterStart = start.map { visit.visitedAt >= $0 } ?? true
                let beforeEnd = end.map { visit.visitedAt <= $0 } ?? true
                return afterStart && beforeEnd
            }
        }
    }

    func clear() { mutate { $0.removeAll() } }

    private func mutate(_ mutation: @escaping (inout [HistoryVisit]) -> Void) {
        mutation(&visits)
        if !isLoaded { startupMutations.append(mutation) }
        save()
    }

    func waitUntilLoaded() async { await loadingTask?.value }

    func flush() async {
        await waitUntilLoaded()
        await persistenceTask?.value
    }

    private func save() {
        needsSave = true
        guard isLoaded, persistenceTask == nil else { return }
        persistenceTask = Task {
            // Coalesce rapid changes while a write is in flight. One task owns
            // the writes, so a slow older snapshot cannot replace a newer one.
            while needsSave {
                needsSave = false
                let snapshot = visits
                do { try await file.write(snapshot.isEmpty ? nil : snapshot) }
                catch { PersistenceDiagnostics.shared.report(operation: "Save browsing history", error: error) }
            }
            persistenceTask = nil
        }
    }

}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Disk access for the two local history files. Values crossing this actor are
/// immutable Codable snapshots; UI state stays with its main-actor owner.
actor JSONHistoryFile<Value: Codable & Sendable> {
    private let url: URL
    init(url: URL) { self.url = url }

    func load(transform: @Sendable (Value) -> Value = { $0 }) throws -> Value? {
        assert(!Thread.isMainThread)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return transform(try JSONDecoder().decode(Value.self, from: Data(contentsOf: url)))
    }

    func write(_ value: Value?) throws {
        assert(!Thread.isMainThread)
        guard let value else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        let data = try JSONEncoder().encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
