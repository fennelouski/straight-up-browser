//
//  DownloadManager.swift
//  Straight Up Browser
//
//  Remembers files that passed through the browser (downloaded or uploaded).
//  Deliberately NOT SwiftData/CloudKit: these are absolute paths on THIS Mac,
//  so syncing them to other devices would just be broken links. Plain local
//  JSON. The app is not sandboxed, so raw paths are fine (no security scopes).
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

enum FileTransferKind: String, Codable {
    case download
    case upload
}

enum FileTransferPrivacy: Equatable {
    case standard
    case privateSession

    var persistsHistory: Bool { self == .standard }
}

struct FileRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: FileTransferKind
    var path: String        // absolute file path
    var source: String?     // web page/origin involved, if known
    var date: Date          // when it passed through the browser

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

enum DownloadTransferState: String, Equatable {
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

enum DownloadVisuals {
    static func color(for index: Int) -> Color {
        // Golden-angle spacing keeps adjacent transfers visually distinct
        // without cycling through a short palette when many are active.
        let hue = (Double(index) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
        return Color(hue: hue, saturation: 0.72, brightness: 0.9)
    }
}

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var records: [FileRecord] = []
    @Published private(set) var activeDownloads: [ActiveDownload] = []

    // ponytail: hard cap keeps the JSON small; add paging if anyone hoards 500+.
    private let maxRecords = 500
    private let storeURL: URL
    private var pauseHandlers: [UUID: () -> Void] = [:]
    private var restartHandlers: [UUID: () -> Void] = [:]
    private var nextColorIndex = 0

    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Straight Up Browser", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.storeURL = dir.appendingPathComponent("file-history.json")
        }
        load()
    }

    func record(
        _ url: URL,
        kind: FileTransferKind,
        source: URL?,
        privacy: FileTransferPrivacy = .standard
    ) {
        guard privacy.persistsHistory else { return }
        records.insert(FileRecord(kind: kind, path: url.path, source: source?.absoluteString, date: Date()), at: 0)
        if records.count > maxRecords { records.removeLast(records.count - maxRecords) }
        save()
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
    }

    func markFailed(_ id: UUID, error: Error, canRestart: Bool) {
        mutate(id) {
            $0.state = .failed
            $0.errorMessage = error.localizedDescription
        }
        pauseHandlers[id] = nil
        if !canRestart { restartHandlers[id] = nil }
    }

    func markRestarting(_ id: UUID) {
        mutate(id) {
            $0.state = .downloading
            $0.errorMessage = nil
        }
    }

    func restart(_ id: UUID) {
        restartHandlers[id]?()
    }

    func finish(_ id: UUID, at url: URL) {
        guard let transfer = activeDownloads.first(where: { $0.id == id }) else { return }
        record(url, kind: .download, source: transfer.source, privacy: transfer.privacy)
        discardTransfer(id)
    }

    func dismiss(_ id: UUID) {
        guard activeDownloads.first(where: { $0.id == id })?.state != .downloading else { return }
        discardTransfer(id)
    }

    func remove(_ record: FileRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    func clear() {
        records.removeAll()
        save()
    }

    private func mutate(_ id: UUID, _ mutation: (inout ActiveDownload) -> Void) {
        guard let index = activeDownloads.firstIndex(where: { $0.id == id }) else { return }
        mutation(&activeDownloads[index])
    }

    private func discardTransfer(_ id: UUID) {
        activeDownloads.removeAll { $0.id == id }
        pauseHandlers[id] = nil
        restartHandlers[id] = nil
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([FileRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
