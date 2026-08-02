import Foundation
import Combine

struct HistoryVisit: Codable, Identifiable, Equatable {
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

    private let storeURL: URL
    private let maxVisits: Int

    init(storeURL: URL? = nil, maxVisits: Int = 5_000) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let directory = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Straight Up Browser", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                PersistenceDiagnostics.shared.report(
                    operation: "Create browsing history folder",
                    error: error
                )
            }
            self.storeURL = directory.appendingPathComponent("browsing-history.json")
        }
        self.maxVisits = max(1, maxVisits)
        load()
    }

    var recentVisits: [HistoryVisit] {
        var seen: Set<String> = []
        return visits.filter { seen.insert($0.url.absoluteString).inserted }
    }

    func record(
        url: URL,
        title: String?,
        sessionKind: SessionKind,
        visitedAt: Date = Date()
    ) {
        guard sessionKind != .incognito,
              url.scheme == "http" || url.scheme == "https" else { return }
        visits.insert(
            HistoryVisit(
                url: url,
                title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? url.host
                    ?? url.absoluteString,
                visitedAt: visitedAt
            ),
            at: 0
        )
        if visits.count > maxVisits {
            visits.removeLast(visits.count - maxVisits)
        }
        save()
    }

    func remove(url: URL) {
        visits.removeAll { $0.url.absoluteString == url.absoluteString }
        save()
    }

    func clear() {
        visits.removeAll()
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: storeURL)
        } catch {
            PersistenceDiagnostics.shared.report(operation: "Clear browsing history", error: error)
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoded = try JSONDecoder().decode([HistoryVisit].self, from: data)
            visits = Array(decoded.sorted { $0.visitedAt > $1.visitedAt }.prefix(maxVisits))
        } catch {
            PersistenceDiagnostics.shared.report(operation: "Load browsing history", error: error)
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(visits)
            try data.write(to: storeURL, options: [.atomic, .completeFileProtection])
        } catch {
            PersistenceDiagnostics.shared.report(operation: "Save browsing history", error: error)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
