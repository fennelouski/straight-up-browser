//
//  DownloadManager.swift
//  Straight Up Browser
//
//  Remembers files that passed through the browser (downloaded or uploaded).
//  Deliberately NOT SwiftData/CloudKit: these are device-local file URLs, so
//  syncing them to another device would create broken links. Plain local JSON
//  keeps the history beside the files it describes.
//

import Foundation
import Combine
import SwiftUI

/// A coordinator serves many tab WebViews, so download URL recovery must be
/// keyed by the tab that successfully loaded the page—not by whichever tab is
/// active when WebKit turns a navigation into a download.
struct DownloadNavigationHistory {
    private var lastSuccessfulURLByTab: [UUID: URL] = [:]

    mutating func recordSuccessfulLoad(_ url: URL, for tabId: UUID) {
        lastSuccessfulURLByTab[tabId] = url
    }

    func restorationURL(for tabId: UUID) -> URL? {
        lastSuccessfulURLByTab[tabId]
    }

    mutating func retainOnly(_ tabIds: Set<UUID>) {
        lastSuccessfulURLByTab = lastSuccessfulURLByTab.filter { tabIds.contains($0.key) }
    }
}

nonisolated enum FileTransferKind: String, Codable, Sendable {
    case download
    case upload
}

enum FileTransferPrivacy: Equatable {
    case standard
    case privateSession

    var persistsHistory: Bool { self == .standard }
}

nonisolated struct FileRecord: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var kind: FileTransferKind
    var path: String        // absolute file path
    var source: String?     // web page/origin involved, if known
    var date: Date          // when it passed through the browser

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

nonisolated enum DownloadTransferState: String, Codable, Equatable, Sendable {
    case downloading
    case pausing
    case paused
    case failed

    var label: String {
        switch self {
        case .downloading: return String(localized: "Downloading")
        case .pausing: return String(localized: "Pausing…")
        case .paused: return String(localized: "Paused")
        case .failed: return String(localized: "Failed")
        }
    }
}

nonisolated private struct PersistedIncompleteDownload: Codable, Sendable {
    let id: UUID
    var filename: String
    var destinationPath: String?
    var source: String?
    let startedAt: Date
    var progress: Double
    var state: DownloadTransferState
    var errorMessage: String?
}

nonisolated private struct DownloadStore: Codable, Sendable {
    var records: [FileRecord]
    var incompleteDownloads: [PersistedIncompleteDownload]

    init(records: [FileRecord], incompleteDownloads: [PersistedIncompleteDownload]) {
        self.records = records
        self.incompleteDownloads = incompleteDownloads
    }

    private enum CodingKeys: CodingKey { case records, incompleteDownloads }
    init(from decoder: any Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
            records = try keyed.decode([FileRecord].self, forKey: .records)
            incompleteDownloads = try keyed.decode([PersistedIncompleteDownload].self, forKey: .incompleteDownloads)
        } else {
            // The original history was just an array of completed transfers.
            records = try decoder.singleValueContainer().decode([FileRecord].self)
            incompleteDownloads = []
        }
    }
}

struct ActiveDownload: Identifiable, Equatable {
    let id: UUID
    let tabId: UUID
    var filename: String
    var destinationPath: String?
    let source: URL?
    let privacy: FileTransferPrivacy
    let startedAt: Date
    var progress: Double
    var state: DownloadTransferState
    var errorMessage: String?
    let colorIndex: Int

    var destinationURL: URL? {
        destinationPath.map { URL(fileURLWithPath: $0) }
    }
}

enum DownloadFailureFeedback {
    static func newMessage(
        previous: [ActiveDownload],
        current: [ActiveDownload]
    ) -> String? {
        let previouslyFailed = Set(
            previous.filter { $0.state == .failed }.map(\.id)
        )
        guard let failure = current.first(where: {
            $0.state == .failed && !previouslyFailed.contains($0.id)
        }) else { return nil }
        let reason = failure.errorMessage
            ?? String(localized: "The download failed.")
        return "\(failure.filename): \(reason)"
    }
}

enum DownloadVisuals {
    static func color(for index: Int) -> Color {
        // Golden-angle spacing keeps adjacent transfers visually distinct
        // without cycling through a short palette when many are active.
        let hue = (Double(index) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
        return Color(hue: hue, saturation: 0.72, brightness: 0.9)
    }
}

#if os(macOS)
enum SecurityScopedBookmark {
    static func data(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resolve(_ data: Data) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), url.startAccessingSecurityScopedResource() else { return nil }
        return url
    }
}

@MainActor
final class SecurityScopedFolderRegistry {
    static let shared = SecurityScopedFolderRegistry()

    private static let bookmarksKey = "securityScopedFolderBookmarks"
    private let defaults: UserDefaults
    private var activeURLs: [String: URL] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    @discardableResult
    func remember(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard let data = SecurityScopedBookmark.data(for: standardized),
              let resolved = SecurityScopedBookmark.resolve(data) else {
            return false
        }
        activeURLs[standardized.path]?
            .stopAccessingSecurityScopedResource()
        activeURLs[standardized.path] = resolved
        var bookmarks = bookmarkDataByPath()
        bookmarks[standardized.path] = data.base64EncodedString()
        defaults.set(bookmarks, forKey: Self.bookmarksKey)
        return true
    }

    func accessibleURL(for url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if let active = activeURLs[standardized.path] {
            return active
        }
        guard let encoded = bookmarkDataByPath()[standardized.path],
              let data = Data(base64Encoded: encoded),
              let resolved = SecurityScopedBookmark.resolve(data) else {
            return standardized
        }
        activeURLs[standardized.path] = resolved
        return resolved
    }

    func forget(_ url: URL) {
        let path = url.standardizedFileURL.path
        activeURLs.removeValue(forKey: path)?
            .stopAccessingSecurityScopedResource()
        var bookmarks = bookmarkDataByPath()
        bookmarks.removeValue(forKey: path)
        defaults.set(bookmarks, forKey: Self.bookmarksKey)
    }

    private func bookmarkDataByPath() -> [String: String] {
        defaults.dictionary(forKey: Self.bookmarksKey) as? [String: String] ?? [:]
    }

    deinit {
        activeURLs.values.forEach {
            $0.stopAccessingSecurityScopedResource()
        }
    }
}

@MainActor
final class DownloadFolderAccess {
    static let shared = DownloadFolderAccess()

    private enum Key {
        static let bookmark = "downloadsFolderSecurityScopedBookmark"
        static let path = "downloadsFolderSecurityScopedPath"
        static let configuredPath = "downloadsFolder"
    }

    private let defaults: UserDefaults
    private var activeURL: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    @discardableResult
    func remember(_ url: URL) -> Bool {
        guard let data = SecurityScopedBookmark.data(for: url),
              let resolved = SecurityScopedBookmark.resolve(data) else {
            return false
        }
        activeURL?.stopAccessingSecurityScopedResource()
        activeURL = resolved
        defaults.set(data, forKey: Key.bookmark)
        defaults.set(url.standardizedFileURL.path, forKey: Key.path)
        defaults.set(url.standardizedFileURL.path, forKey: Key.configuredPath)
        return true
    }

    func configuredFolder() -> URL? {
        guard let configuredPath = defaults.string(forKey: Key.configuredPath),
              !configuredPath.isEmpty,
              configuredPath
                == defaults.string(forKey: Key.path) else { return nil }
        if let activeURL {
            return activeURL
        }
        guard let data = defaults.data(forKey: Key.bookmark),
              let resolved = SecurityScopedBookmark.resolve(data),
              resolved.standardizedFileURL.path == configuredPath else {
            return nil
        }
        activeURL = resolved
        return resolved
    }

    func useSystemDownloadsFolder() {
        activeURL?.stopAccessingSecurityScopedResource()
        activeURL = nil
        defaults.removeObject(forKey: Key.bookmark)
        defaults.removeObject(forKey: Key.path)
        defaults.set("", forKey: Key.configuredPath)
    }

    deinit {
        activeURL?.stopAccessingSecurityScopedResource()
    }
}
#endif

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var records: [FileRecord] = []
    @Published private(set) var activeDownloads: [ActiveDownload] = []

    // ponytail: hard cap keeps the JSON small; add paging if anyone hoards 500+.
    private let maxRecords = 500
    private let file: JSONHistoryFile<DownloadStore>
    private var loadingTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var isLoaded = false
    private var needsSave = false
    private var startupMutations: [(inout [FileRecord]) -> Void] = []
    private var discardedDuringLoad: Set<UUID> = []
    private var pauseHandlers: [UUID: () -> Void] = [:]
    private var restartHandlers: [UUID: () -> Void] = [:]
    private var nextColorIndex = 0

    private var persistedIncompleteDownloads: [PersistedIncompleteDownload] {
        activeDownloads.compactMap { transfer in
            guard transfer.privacy.persistsHistory else { return nil }
            return PersistedIncompleteDownload(
                id: transfer.id,
                filename: transfer.filename,
                destinationPath: transfer.destinationPath,
                source: transfer.source?.absoluteString,
                startedAt: transfer.startedAt,
                progress: transfer.progress,
                state: transfer.state,
                errorMessage: transfer.errorMessage
            )
        }
    }

    init(storeURL: URL? = nil) {
        #if os(macOS)
        _ = DownloadFolderAccess.shared.configuredFolder()
        #endif
        let url = storeURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Straight Up Browser", isDirectory: true)
            .appendingPathComponent("file-history.json")
        file = JSONHistoryFile(url: url)
        load()

    }

    func record(
        _ url: URL,
        kind: FileTransferKind,
        source: URL?,
        privacy: FileTransferPrivacy = .standard
    ) {
        guard privacy.persistsHistory else { return }
        let record = FileRecord(kind: kind, path: url.path, source: source?.absoluteString, date: Date())
        let limit = maxRecords
        mutateRecords { records in
            records.insert(record, at: 0)
            if records.count > limit { records.removeLast(records.count - limit) }
        }
    }

    @discardableResult
    func beginDownload(
        tabId: UUID,
        source: URL?,
        filename: String? = nil,
        privacy: FileTransferPrivacy = .standard
    ) -> UUID {
        let id = UUID()
        let colorIndex = nextColorIndex
        nextColorIndex += 1
        activeDownloads.append(
            ActiveDownload(
                id: id,
                tabId: tabId,
                filename: filename ?? source?.lastPathComponent.nonEmpty ?? String(localized: "Download"),
                destinationPath: nil,
                source: source,
                privacy: privacy,
                startedAt: Date(),
                progress: 0,
                state: .downloading,
                errorMessage: nil,
                colorIndex: colorIndex
            )
        )
        save()
        return id
    }

    func downloads(for tabId: UUID) -> [ActiveDownload] {
        activeDownloads.filter { $0.tabId == tabId }
    }

    func update(_ id: UUID, progress: Double) {
        mutate(id) {
            $0.progress = min(max(progress, 0), 1)
            if $0.state == .downloading { $0.errorMessage = nil }
        }
    }

    func setDestination(_ id: UUID, url: URL, suggestedFilename: String) {
        mutate(id) {
            $0.destinationPath = url.path
            $0.filename = suggestedFilename
        }
        save()
    }

    func setPauseHandler(_ id: UUID, _ handler: @escaping () -> Void) {
        pauseHandlers[id] = handler
    }

    func setRestartHandler(_ id: UUID, _ handler: @escaping () -> Void) {
        restartHandlers[id] = handler
    }

    func pause(_ id: UUID) {
        guard activeDownloads.first(where: { $0.id == id })?.state == .downloading,
              let handler = pauseHandlers[id] else { return }
        mutate(id) { $0.state = .pausing }
        handler()
    }

    func markPaused(_ id: UUID, canResume: Bool) {
        mutate(id) {
            $0.state = canResume ? .paused : .failed
            $0.errorMessage = canResume ? nil : String(localized: "This server cannot resume the download.")
        }
        pauseHandlers[id] = nil
        save()
    }

    func markFailed(_ id: UUID, error: Error, canRestart: Bool) {
        mutate(id) {
            $0.state = .failed
            $0.errorMessage = error.localizedDescription
        }
        pauseHandlers[id] = nil
        if !canRestart { restartHandlers[id] = nil }
        save()
    }

    func markRestarting(_ id: UUID) {
        mutate(id) {
            $0.state = .downloading
            $0.errorMessage = nil
        }
        save()
    }

    func restart(_ id: UUID) {
        restartHandlers[id]?()
    }

    func finish(_ id: UUID, at url: URL) {
        guard let transfer = activeDownloads.first(where: { $0.id == id }) else { return }
        record(url, kind: .download, source: transfer.source, privacy: transfer.privacy)
        discardTransfer(id)
        save()
    }

    func dismiss(_ id: UUID) {
        guard activeDownloads.first(where: { $0.id == id })?.state != .downloading else { return }
        discardTransfer(id)
        save()
    }

    func remove(_ record: FileRecord) {
        mutateRecords { $0.removeAll { $0.id == record.id } }
    }

    func clear(kind: FileTransferKind? = nil) {
        mutateRecords { records in
            if let kind { records.removeAll { $0.kind == kind } }
            else { records.removeAll() }
        }
    }

    private func mutateRecords(_ mutation: @escaping (inout [FileRecord]) -> Void) {
        mutation(&records)
        if !isLoaded { startupMutations.append(mutation) }
        save()
    }

    func waitUntilLoaded() async { await loadingTask?.value }

    func flush() async {
        await waitUntilLoaded()
        await persistenceTask?.value
    }

    private func mutate(_ id: UUID, _ mutation: (inout ActiveDownload) -> Void) {
        guard let index = activeDownloads.firstIndex(where: { $0.id == id }) else { return }
        mutation(&activeDownloads[index])
    }

    private func discardTransfer(_ id: UUID) {
        if !isLoaded { discardedDuringLoad.insert(id) }
        activeDownloads.removeAll { $0.id == id }
        pauseHandlers[id] = nil
        restartHandlers[id] = nil
    }

    private func load() {
        let file = file
        let limit = maxRecords
        loadingTask = Task { [weak self] in
            var stored: DownloadStore?
            do {
                stored = try await file.load(transform: { value in
                    var bounded = value
                    bounded.records = Array(value.records.prefix(limit))
                    return bounded
                })
            } catch {
                PersistenceDiagnostics.shared.report(operation: "Load download history", error: error)
            }
            guard let self else { return }
            let interruptedMessage = String(localized: "The download was interrupted.")
            var restored: [ActiveDownload] = []
            for (index, transfer) in (stored?.incompleteDownloads ?? []).enumerated() {
                let interrupted = transfer.state == .downloading || transfer.state == .pausing
                restored.append(ActiveDownload(id: transfer.id, tabId: UUID(), filename: transfer.filename,
                    destinationPath: transfer.destinationPath, source: transfer.source.flatMap(URL.init(string:)),
                    privacy: .standard, startedAt: transfer.startedAt, progress: transfer.progress,
                    state: interrupted ? .failed : transfer.state,
                    errorMessage: transfer.errorMessage ?? (interrupted ? interruptedMessage : nil),
                    colorIndex: self.nextColorIndex))
                self.nextColorIndex += 1
                if index % 100 == 99 { await Task.yield() }
            }
            self.activeDownloads.insert(contentsOf: restored.filter {
                !self.discardedDuringLoad.contains($0.id)
            }, at: 0)
            self.discardedDuringLoad.removeAll()
            var records = stored?.records ?? []
            for mutation in self.startupMutations { mutation(&records) }
            self.startupMutations.removeAll()
            self.records = records
            self.isLoaded = true
            // Save the cap, legacy migration and interrupted-transfer conversion.
            if stored != nil || self.needsSave { self.save() }
        }
    }

    private func save() {
        needsSave = true
        guard isLoaded, persistenceTask == nil else { return }
        persistenceTask = Task {
            while needsSave {
                needsSave = false
                let snapshot = DownloadStore(records: records, incompleteDownloads: persistedIncompleteDownloads)
                do {
                    try await file.write(snapshot.records.isEmpty && snapshot.incompleteDownloads.isEmpty ? nil : snapshot)
                } catch {
                    PersistenceDiagnostics.shared.report(operation: "Save download history", error: error)
                }
            }
            persistenceTask = nil
        }
    }

}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
