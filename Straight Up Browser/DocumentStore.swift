//
//  DocumentStore.swift
//  Straight Up Browser
//
//  The single owner of workspace-document file operations (Phase 2, design
//  §4.2), mirroring LedgerStore's "every write goes through me" role: container
//  resolution, create/rename/delete/append, the metadata query that reconciles
//  rows with files, and iCloud conflict resolution.
//
//  Two sync systems, two latencies: WorkspaceDocument rows ride CloudKit while
//  file bytes ride iCloud Drive. "Row exists, file not local yet" is a normal
//  transient state, never corruption.
//

import Combine
import Foundation
import SwiftData

@MainActor
final class DocumentStore: ObservableObject {

    enum ContainerState: Equatable {
        case resolving
        /// iCloud Drive signed out or the container unavailable. Rows still render.
        case unavailable
        case ready(URL)
    }

    @Published private(set) var containerState: ContainerState = .resolving
    /// Rows whose file the metadata query cannot see anywhere — moved or deleted
    /// externally. Distinct from "in the cloud, not downloaded yet".
    @Published private(set) var missingDocumentIds: Set<UUID> = []

    private let modelContext: ModelContext
    private let ledgerStore: LedgerStore
    private var metadataQuery: NSMetadataQuery?
    private let fileMaintenance = DocumentFileMaintenance()
    private var reconciliation: Task<Void, Never>?
    private var presentPaths: Set<String> = []
    private var pendingMetadata: [String: DocumentMetadataUpdate] = [:]
    private var metadataRevision = 0
    private var queryObservers: [NSObjectProtocol] = []
    /// Open edit sessions by document id, so appends reach a live buffer and
    /// panes share one session per document.
    private var sessions: [UUID: DocumentEditSession] = [:]

    /// `containerOverride` is the test seam: a local directory standing in for
    /// the iCloud container, with the metadata query left off.
    init(modelContext: ModelContext, ledgerStore: LedgerStore, containerOverride: URL? = nil) {
        self.modelContext = modelContext
        self.ledgerStore = ledgerStore
        if let containerOverride {
            containerState = .ready(containerOverride)
        } else {
            resolveContainer()
        }
    }

    isolated deinit {
        for observer in queryObservers { NotificationCenter.default.removeObserver(observer) }
        metadataQuery?.stop()
        reconciliation?.cancel()
    }

    // MARK: Container

    private func resolveContainer() {
        let containerID = TabSync.containerID
        Task.detached(priority: .userInitiated) {
            // First call can be slow and must be off-main.
            let url = FileManager.default.url(
                forUbiquityContainerIdentifier: containerID
            )?.appendingPathComponent("Documents", isDirectory: true)
            if let url {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let url {
                    self.containerState = .ready(url)
                    self.startMetadataQuery()
                } else {
                    self.containerState = .unavailable
                }
            }
        }
    }

    var documentsRootURL: URL? {
        if case .ready(let url) = containerState { return url }
        return nil
    }

    func url(for document: WorkspaceDocument) -> URL? {
        documentsRootURL?.appendingPathComponent(document.relativePath)
    }

    // MARK: Row lookups

    func documents(workspaceId: UUID) -> [WorkspaceDocument] {
        let rows = (try? modelContext.fetch(FetchDescriptor<WorkspaceDocument>(
            predicate: #Predicate { $0.workspaceId == workspaceId }
        ))) ?? []
        return rows.sorted {
            $0.orderIndex != $1.orderIndex ? $0.orderIndex < $1.orderIndex : $0.createdAt < $1.createdAt
        }
    }

    func allDocuments() -> [WorkspaceDocument] {
        (try? modelContext.fetch(FetchDescriptor<WorkspaceDocument>())) ?? []
    }

    func document(id: UUID) -> WorkspaceDocument? {
        var descriptor = FetchDescriptor<WorkspaceDocument>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func document(relativePath: String) -> WorkspaceDocument? {
        var descriptor = FetchDescriptor<WorkspaceDocument>(
            predicate: #Predicate { $0.relativePath == relativePath }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// The anchor-append target: newest lastOpenedAt, else the only document,
    /// else nil (the composer auto-creates "Notes").
    func currentDocument(workspaceId: UUID) -> WorkspaceDocument? {
        let rows = documents(workspaceId: workspaceId)
        return rows.max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
            ?? rows.first
    }

    // MARK: Naming

    /// Human-readable, because "Nothing is trapped" means legible in the Files
    /// app. Frozen at first document creation; renaming the workspace later does
    /// not move the folder — the same freeze rule as Workspace.sectionName.
    func folderName(for workspace: Workspace) -> String {
        if let existing = documents(workspaceId: workspace.id).first,
           let folder = existing.relativePath.components(separatedBy: "/").first,
           !folder.isEmpty {
            return folder
        }
        var name = Self.sanitize(workspace.name)
        // A different workspace already claimed this folder → suffix ours.
        let all = (try? modelContext.fetch(FetchDescriptor<WorkspaceDocument>())) ?? []
        let claimed = all.contains {
            $0.workspaceId != workspace.id
                && $0.relativePath.components(separatedBy: "/").first == name
        }
        if claimed {
            name += "-" + workspace.id.uuidString.prefix(4).lowercased()
        }
        return name
    }

    nonisolated static func sanitize(_ name: String) -> String {
        var cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 80 { cleaned = String(cleaned.prefix(80)) }
        return cleaned.isEmpty ? String(localized: "Untitled") : cleaned
    }

    // MARK: Create / rename / delete / append

    @discardableResult
    func createDocument(in workspace: Workspace, name: String? = nil) -> WorkspaceDocument? {
        guard let root = documentsRootURL else { return nil }
        let folder = folderName(for: workspace)
        let base = Self.sanitize(name ?? String(localized: "Untitled"))
        let siblings = documents(workspaceId: workspace.id)
        var candidate = base
        var counter = 2
        while siblings.contains(where: { $0.relativePath == "\(folder)/\(candidate).md" })
            || FileManager.default.fileExists(atPath: root.appendingPathComponent("\(folder)/\(candidate).md").path) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        let relativePath = "\(folder)/\(candidate).md"
        let fileURL = root.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var writeError: NSError?
        var writeFailed = false
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forReplacing, error: &writeError) { url in
            do { try Data().write(to: url, options: .atomic) } catch { writeFailed = true }
        }
        guard writeError == nil, !writeFailed else { return nil }

        // Fetch-then-insert (no @Attribute(.unique) under CloudKit).
        if let existing = document(relativePath: relativePath) { return existing }
        let row = WorkspaceDocument(
            workspaceId: workspace.id,
            displayName: candidate,
            relativePath: relativePath,
            orderIndex: (siblings.map(\.orderIndex).max() ?? -1) + 1
        )
        row.lastOpenedAt = Date()
        modelContext.insert(row)
        save("Create workspace document")
        return row
    }

    @discardableResult
    func renameDocument(_ row: WorkspaceDocument, to newName: String) -> Bool {
        guard let root = documentsRootURL else { return false }
        let cleaned = Self.sanitize(newName)
        guard !cleaned.isEmpty, cleaned != row.displayName else { return false }
        let folder = row.relativePath.components(separatedBy: "/").dropLast().joined(separator: "/")
        var candidate = cleaned
        var counter = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent("\(folder)/\(candidate).md").path) {
            candidate = "\(cleaned) \(counter)"
            counter += 1
        }
        let newRelative = folder.isEmpty ? "\(candidate).md" : "\(folder)/\(candidate).md"
        let oldURL = root.appendingPathComponent(row.relativePath)
        let newURL = root.appendingPathComponent(newRelative)
        var moveError: NSError?
        var moved = false
        NSFileCoordinator().coordinate(
            writingItemAt: oldURL, options: .forMoving,
            writingItemAt: newURL, options: .forReplacing,
            error: &moveError
        ) { from, to in
            moved = (try? FileManager.default.moveItem(at: from, to: to)) != nil
        }
        guard moved else { return false }
        row.displayName = candidate
        row.relativePath = newRelative
        save("Rename workspace document")
        return true
    }

    func deleteDocument(_ row: WorkspaceDocument) {
        let documentId = row.id
        if let session = sessions.removeValue(forKey: documentId) {
            Task { await session.discardAndClose() }
        }
        if let url = url(for: row) {
            var deleteError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &deleteError) { url in
                try? FileManager.default.removeItem(at: url)
            }
        }
        // Edges go with the document; anchors belong to sources and stay.
        ledgerStore.deleteEdges(documentId: documentId)
        missingDocumentIds.remove(documentId)
        modelContext.delete(row)
        save("Delete workspace document")
    }

    /// The anchor path: append a line without requiring an open editor. A live
    /// session takes it into the buffer (so screen and disk agree); otherwise a
    /// coordinated read-modify-write on the raw file.
    func append(line: String, to row: WorkspaceDocument) {
        if let session = sessions[row.id] {
            session.appendLine(line)
            return
        }
        guard let url = url(for: row) else { return }
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordError) { url in
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            var text = existing
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += line + "\n"
            try? Data(text.utf8).write(to: url, options: .atomic)
        }
    }

    // MARK: Edit sessions

    func session(for row: WorkspaceDocument, workspaceId: UUID) -> DocumentEditSession {
        if let existing = sessions[row.id] { return existing }
        let fileURL = url(for: row)
        #if os(macOS)
        let file = fileURL.map { WorkspaceDocumentFile(url: $0) }
        #else
        let file = fileURL.map { WorkspaceDocumentFile(fileURL: $0) }
        #endif
        let session = DocumentEditSession(
            documentId: row.id,
            workspaceId: workspaceId,
            file: file,
            resolver: AnchorResolver(ledgerStore: ledgerStore),
            ledgerStore: ledgerStore,
            store: self
        )
        sessions[row.id] = session
        row.lastOpenedAt = Date()
        save("Note document opened")
        return session
    }

    func closeSession(for documentId: UUID) {
        guard let session = sessions.removeValue(forKey: documentId) else { return }
        Task { await session.close() }
    }

    /// Close every open edit session (each flushes its save). Called when the
    /// active workspace changes — sessions belong to the workspace being left.
    func closeAllSessions() {
        for id in Array(sessions.keys) { closeSession(for: id) }
    }

    // MARK: Conflicts (design §5: newest wins, losers become siblings)

    /// Writes every unresolved NSFileVersion out as an ordinary sibling file,
    /// then marks it resolved. The sibling is adopted as a row by the stray-file
    /// rule, so it is openable, comparable by eye, and deletable. No modal,
    /// nothing discarded.
    func resolveVersionConflicts(at url: URL, displayName: String) async {
        if await fileMaintenance.resolveConflicts(at: url, displayName: displayName) {
            postNote(String(localized: "Kept both versions of “\(displayName)” — the other copy is beside it."))
        }
    }

    @discardableResult
    func preserveDiskVersionAsSibling(for row: WorkspaceDocument) async -> Bool {
        guard let url = url(for: row) else { return false }
        let name = row.displayName
        let preserved = await fileMaintenance.preserveDiskVersion(at: url, displayName: name)
        if preserved {
            postNote(String(localized: "Kept both versions of “\(name)” — the other copy is beside it."))
        }
        return preserved
    }

    func postNote(_ text: String) {
        NotificationCenter.default.post(name: .browserDocumentNote, object: nil, userInfo: ["text": text])
    }

    // MARK: Metadata query (design §4.4)

    private func startMetadataQuery() {
        guard metadataQuery == nil else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*.md'", NSMetadataItemFSNameKey)
        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            queryObservers.append(center.addObserver(forName: name, object: query, queue: .main) { [weak self] notification in
                // This observer is delivered synchronously on OperationQueue.main.
                nonisolated(unsafe) let mainThreadNotification = notification
                MainActor.assumeIsolated { self?.reconcileWithMetadata(mainThreadNotification) }
            })
        }
        metadataQuery = query
        query.start()
    }

    private func reconcileWithMetadata(_ notification: Notification) {
        guard let query = metadataQuery, let root = documentsRootURL else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        let initial = notification.name == .NSMetadataQueryDidFinishGathering
        let changed = initial ? query.results :
            (notification.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []) +
            (notification.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem] ?? [])
        let removed = notification.userInfo?[NSMetadataQueryUpdateRemovedItemsKey] as? [NSMetadataItem] ?? []
        func relativePath(_ item: NSMetadataItem) -> String? {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  url.path.hasPrefix(root.path + "/") else { return nil }
            return String(url.path.dropFirst(root.path.count + 1))
        }
        if initial { presentPaths.removeAll(keepingCapacity: true) }
        for item in removed {
            if let path = relativePath(item) {
                presentPaths.remove(path)
                pendingMetadata.removeValue(forKey: path)
            }
        }
        let updates = changed.compactMap { value -> DocumentMetadataUpdate? in
            guard let item = value as? NSMetadataItem, let path = relativePath(item) else { return nil }
            presentPaths.insert(path)
            return DocumentMetadataUpdate(relativePath: path,
                needsDownload: item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
                    == NSMetadataUbiquitousItemDownloadingStatusNotDownloaded,
                hasConflicts: item.value(forAttribute: NSMetadataUbiquitousItemHasUnresolvedConflictsKey) as? Bool == true)
        }
        for update in updates { pendingMetadata[update.relativePath] = update }
        metadataRevision += 1
        guard reconciliation == nil else { return }
        reconciliation = Task { [weak self] in
            // Merge bursts from iCloud into one pass, including updates that
            // arrive while a previous pass is coordinating files.
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else { return }
            defer { self.reconciliation = nil }
            while !Task.isCancelled {
                let revision = self.metadataRevision
                let updates = self.pendingMetadata.values.sorted { $0.relativePath < $1.relativePath }
                self.pendingMetadata.removeAll(keepingCapacity: true)
                await self.reconcile(updates, presentPaths: self.presentPaths, root: root)
                if revision == self.metadataRevision { break }
            }
        }
    }

    // One fetch per model type, and one save per batch. Yield between batches so
    // initial discovery of a large Drive folder does not monopolize the UI.
    func reconcile(_ updates: [DocumentMetadataUpdate], presentPaths: Set<String>, root: URL) async {
        let rows = allDocuments()
        var byPath = Dictionary(rows.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        let workspaces = (try? modelContext.fetch(FetchDescriptor<Workspace>())) ?? []
        let workspaceRows = Dictionary(workspaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let grouped = Dictionary(grouping: rows, by: \.workspaceId)
        var owners: [String: UUID] = [:]
        for workspace in workspaces {
            let existing = grouped[workspace.id]?.min { $0.orderIndex < $1.orderIndex }
            if let folder = existing?.relativePath.components(separatedBy: "/").first {
                owners[folder] = workspace.id
            }
        }
        for workspace in workspaces where grouped[workspace.id] == nil {
            var folder = Self.sanitize(workspace.name)
            if let owner = owners[folder], owner != workspace.id {
                folder += "-" + workspace.id.uuidString.prefix(4).lowercased()
            }
            if owners[folder] == nil { owners[folder] = workspace.id }
        }
        var nextOrder = grouped.mapValues { ($0.map(\.orderIndex).max() ?? -1) + 1 }
        for (index, update) in updates.enumerated() {
            let relative = update.relativePath
            let url = root.appendingPathComponent(relative)
            if update.needsDownload { await fileMaintenance.download(url) }
            if update.hasConflicts {
                await resolveVersionConflicts(at: url, displayName: byPath[relative]?.displayName
                    ?? url.deletingPathExtension().lastPathComponent)
            }
            if byPath[relative] == nil {
                let parts = relative.components(separatedBy: "/")
                if parts.count >= 2, let folder = parts.first, let owner = owners[folder],
                   workspaceRows[owner]?.isDeleted == false {
                    let row = WorkspaceDocument(workspaceId: owner,
                        displayName: url.deletingPathExtension().lastPathComponent,
                        relativePath: relative, orderIndex: nextOrder[owner, default: 0])
                    nextOrder[owner, default: 0] += 1
                    modelContext.insert(row)
                    byPath[relative] = row
                }
            }
            if index % 100 == 99 {
                save("Reconcile workspace documents")
                await Task.yield()
            }
        }
        save("Reconcile workspace documents")
        missingDocumentIds = Set(allDocuments().filter { !presentPaths.contains($0.relativePath) }.map(\.id))
    }

    private func save(_ operation: String) {
        do {
            try modelContext.save()
        } catch {
            PersistenceDiagnostics.shared.report(operation: operation, error: error)
        }
    }
}

nonisolated struct DocumentMetadataUpdate: Sendable {
    let relativePath: String
    var needsDownload = false
    var hasConflicts = false
}

private actor DocumentFileMaintenance {
    func download(_ url: URL) {
        assert(!Thread.isMainThread)
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    private let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH.mm"
        return formatter
    }()

    private func siblingURL(for url: URL, name: String) -> URL {
        let folder = url.deletingLastPathComponent()
        let base = DocumentStore.sanitize(name)
        var candidate = folder.appendingPathComponent(base + ".md")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(suffix).md")
            suffix += 1
        }
        return candidate
    }

    func resolveConflicts(at url: URL, displayName: String) -> Bool {
        assert(!Thread.isMainThread)
        let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        var preserved = false
        for version in versions {
            let device = version.localizedNameOfSavingComputer ?? String(localized: "another device")
            let stamp = stampFormatter.string(from: version.modificationDate ?? Date())
            let name = String(localized: "\(displayName) (conflict from \(device), \(stamp))")
            let sibling = siblingURL(for: url, name: name)
            var error: NSError?
            var copied = false
            NSFileCoordinator().coordinate(readingItemAt: version.url, options: [],
                writingItemAt: sibling, options: [], error: &error) { from, to in
                do { try FileManager.default.copyItem(at: from, to: to); copied = true } catch {}
            }
            if copied && error == nil {
                version.isResolved = true
                preserved = true
            }
        }
        // A failed copy must keep its original version available for retry.
        if !versions.isEmpty && versions.allSatisfy({ $0.isResolved }) {
            try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        }
        return preserved
    }

    func preserveDiskVersion(at url: URL, displayName: String) -> Bool {
        assert(!Thread.isMainThread)
        let stamp = stampFormatter.string(from: Date())
        let name = String(localized: "\(displayName) (conflict, \(stamp))")
        let sibling = siblingURL(for: url, name: name)
        var error: NSError?
        var copied = false
        NSFileCoordinator().coordinate(readingItemAt: url, options: [],
            writingItemAt: sibling, options: [], error: &error) { from, to in
            guard let size = try? from.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { return }
            do { try FileManager.default.copyItem(at: from, to: to); copied = true } catch {}
        }
        return copied && error == nil
    }
}
