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

@MainActor
enum ShareIngest {

    struct Result: Equatable {
        var ingested = 0
        /// The workspace the LAST item landed in, for the transient note.
        var workspaceName: String?
    }

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
    ) -> Result {
        var result = Result()
        for (item, fileData) in ShareQueue.pending(container: container) {
            guard let workspace = ledgerStore.workspace(id: item.workspaceId) else {
                // Workspace deleted between share and drain: nothing to file
                // under. Dropping beats a poison-pill queue.
                ShareQueue.clear(item, container: container)
                continue
            }
            if let url = item.url {
                ledgerStore.recordShareCapture(url: url, title: item.title, workspaceId: workspace.id)
            } else if let fileData {
                guard ledgerStore.recordFileImport(
                    data: fileData,
                    suggestedName: item.fileName ?? item.title,
                    workspaceId: workspace.id,
                    importsDirectory: importsDirectory
                ) != nil else { continue } // disk full etc: retry next drain
            } else {
                ShareQueue.clear(item, container: container)
                continue
            }
            ShareQueue.clear(item, container: container)
            result.ingested += 1
            result.workspaceName = workspace.name
        }
        return result
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
