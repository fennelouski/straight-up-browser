//
//  ShareIngest.swift
//  Straight Up Browser
//
//  The app side of share-sheet capture (Phase 3): drain the app-group inbox
//  into the ledger. Runs when the app becomes active — never in the background,
//  never in the extension. Separate from ShareQueue.swift so the extension can
//  compile the queue without dragging SwiftData in.
//

import Foundation
import CryptoKit

@MainActor
enum ShareIngest {

    struct Result: Equatable {
        var ingested = 0
        /// The workspace the LAST item landed in, for the transient note.
        var workspaceName: String?
    }

    private static var drainingContainers: Set<URL> = []

    /// Permanent home for imported file bytes (design §4): content-hashed, so
    /// the same bytes shared twice land on one file.
    static func importsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Imports", isDirectory: true)
    }

    /// Ingest everything queued. Items whose workspace no longer exists are
    /// dropped (cleared) rather than retried forever; items that fail to
    /// persist stay queued for the next drain.
    @discardableResult
    static func drain(
        ledgerStore: LedgerStore,
        container: URL? = ShareQueue.containerURL(),
        importsDirectory: URL = importsDirectory()
    ) async -> Result {
        guard let container, drainingContainers.insert(container).inserted else { return Result() }
        defer { drainingContainers.remove(container) }
        var result = Result()
        for (item, fileURL) in await pending(container: container) {
            guard !Task.isCancelled else { break }
            guard let workspace = ledgerStore.workspace(id: item.workspaceId) else {
                await clear(item, container: container)
                continue
            }
            let article: NewspaperArticle
            if let url = item.url {
                article = ledgerStore.recordShareCapture(url: url, title: item.title, workspaceId: workspace.id)
            } else if let fileURL {
                guard let prepared = try? await prepare(fileURL, directory: importsDirectory),
                      !Task.isCancelled,
                      ledgerStore.workspace(id: item.workspaceId) != nil else { continue }
                article = ledgerStore.recordPreparedFileImport(url: prepared.url, hash: prepared.hash,
                    name: item.fileName ?? item.title, workspaceId: workspace.id)
            } else {
                await clear(item, container: container)
                continue
            }
            // Failed persistence must leave the item queued for a retry.
            do { try ledgerStore.flush() } catch { continue }
            guard ledgerStore.source(sourceKey: article.sourceKey)?.id == article.id,
                  ledgerStore.reference(workspaceId: item.workspaceId, sourceKey: article.sourceKey) != nil
            else { continue }
            await clear(item, container: container)
            result.ingested += 1
            result.workspaceName = workspace.name
        }
        return result
    }

    @concurrent private static func pending(container: URL) async -> [(item: ShareQueue.SharedItem, fileURL: URL?)] {
        ShareQueue.pending(container: container)
    }

    @concurrent private static func clear(_ item: ShareQueue.SharedItem, container: URL) async {
        ShareQueue.clear(item, container: container)
    }

    @concurrent static func prepare(_ source: URL, directory: URL) async throws -> (url: URL, hash: String) {
        assert(!Thread.isMainThread)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        var digest = SHA256()
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        try output.close()
        try Task.checkCancellation()
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let ext = source.pathExtension
        let destination = directory.appendingPathComponent(hash + (ext.isEmpty ? "" : "." + ext))
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        return (destination, hash)
    }

    /// Refresh the extension's picker mirror from the live workspace list.
    static func updateMirror(workspaces: [Workspace], activeWorkspaceId: UUID?) {
        ShareQueue.updateMirror(
            workspaces.filter { !$0.isArchived }.map {
                ShareQueue.MirroredWorkspace(id: $0.id, name: $0.name, lastActiveAt: $0.lastActiveAt)
            },
            activeWorkspaceId: activeWorkspaceId
        )
    }
}
