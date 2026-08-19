//
//  DocumentEditSession.swift
//  Straight Up Browser
//
//  One open document: the buffer, its anchor resolution, the save pass, and
//  the external-change / conflict behavior (Phase 2, design §5–6). Headless on
//  purpose — the platform text views render `text` and call back into here, so
//  the whole round trip (insert → save → external modification → reopen →
//  resolution fallbacks) is testable without UI.
//

import Combine
import Foundation

@MainActor
final class DocumentEditSession: ObservableObject {
    let documentId: UUID
    let workspaceId: UUID

    /// Nil while the iCloud container is unavailable: the pane renders read-only.
    private let file: WorkspaceDocumentFileProtocol?
    private let resolver: AnchorResolver
    private let ledgerStore: LedgerStore
    private weak var store: DocumentStore?

    @Published private(set) var text: String = ""
    @Published private(set) var resolvedLinks: [AnchorResolver.ResolvedLink] = []
    /// Bumped whenever `text` was replaced from OUTSIDE the editor (external
    /// reload, title repair, append) — the text view resets its buffer on this,
    /// and only this, so ordinary typing never round-trips.
    @Published private(set) var externalRevision = 0
    @Published private(set) var isLoaded = false

    /// Autosave debounce after the last keystroke (design §2.3).
    static let saveDebounce: Duration = .seconds(2)
    private var pendingSave: Task<Void, Never>?

    init(
        documentId: UUID,
        workspaceId: UUID,
        file: WorkspaceDocumentFileProtocol?,
        resolver: AnchorResolver,
        ledgerStore: LedgerStore,
        store: DocumentStore?
    ) {
        self.documentId = documentId
        self.workspaceId = workspaceId
        self.file = file
        self.resolver = resolver
        self.ledgerStore = ledgerStore
        self.store = store
        file?.onExternalChange = { [weak self] in
            Task { @MainActor in self?.handleExternalChange() }
        }
    }

    func open() async {
        guard let file else { isLoaded = true; return }
        _ = await file.openFile()
        text = file.documentText
        refreshResolution()
        isLoaded = true
    }

    // MARK: Editing

    /// Every keystroke funnels through here from the text view.
    func editorDidChangeText(_ newText: String) {
        guard newText != text else { return }
        text = newText
        file?.documentText = newText
        refreshResolution()
        scheduleSave()
    }

    /// The anchor path while this document is open: buffer and disk stay agreed
    /// because the append goes through the buffer.
    func appendLine(_ line: String) {
        var newText = text
        if !newText.isEmpty && !newText.hasSuffix("\n") { newText += "\n" }
        newText += line + "\n"
        text = newText
        file?.documentText = newText
        externalRevision += 1
        refreshResolution()
        scheduleSave()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    // MARK: The save pass (design §6.3)

    /// 1. Title repair — fallback-#2 links get their "^id" marker written.
    /// 2. Edge reconciliation — the document's links ARE its edge set.
    /// Both ride every save trigger: debounce, pane blur/close, app background.
    func saveNow() async {
        pendingSave?.cancel()
        pendingSave = nil
        let result = resolver.processForSave(markdown: text, workspaceId: workspaceId)
        if result.markdown != text {
            text = result.markdown
            file?.documentText = result.markdown
            externalRevision += 1
        }
        if let file {
            _ = await file.saveFile()
            // A save can surface iCloud versions that raced ours.
            if let url = file.presentedURL, let row = store?.document(id: documentId) {
                store?.resolveVersionConflicts(at: url, displayName: row.displayName)
            }
        }
        ledgerStore.reconcileEdges(documentId: documentId, occurrences: result.occurrences)
        refreshResolution()
    }

    func close() async {
        await saveNow()
        await file?.closeFile()
    }

    /// Closing without saving — the document was deleted out from under us.
    func discardAndClose() async {
        pendingSave?.cancel()
        pendingSave = nil
        await file?.closeFile()
    }

    // MARK: External changes (design §4.4, §5)

    func handleExternalChange() {
        guard let file else { return }
        Task { [weak self] in
            guard let self else { return }
            if file.isDirty {
                // Keep the user's buffer; today's disk bytes become a sibling,
                // then our save wins the path. Never silently drop either.
                if let row = self.store?.document(id: self.documentId) {
                    self.store?.preserveDiskVersionAsSibling(for: row)
                }
                await self.saveNow()
            } else {
                // Clean buffer: silently reload, re-resolve, repair offsets.
                _ = await file.revertFromDisk()
                self.text = file.documentText
                self.externalRevision += 1
                self.refreshResolution()
            }
        }
    }

    // MARK: Resolution

    /// ponytail: full re-resolve on every edit — one fetch per distinct link
    /// against small tables. Cache per (url, idPrefix) if typing in a document
    /// with hundreds of links ever stutters.
    private func refreshResolution() {
        resolvedLinks = resolver.resolve(markdown: text, workspaceId: workspaceId)
    }
}
