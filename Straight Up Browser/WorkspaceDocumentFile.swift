//
//  WorkspaceDocumentFile.swift
//  Straight Up Browser
//
//  The document objects behind the Markdown editor (Phase 2, design §4.3):
//  UIDocument on iOS, NSDocument on the Mac — used EMBEDDED. The Mac document
//  is never registered with NSDocumentController and owns no windows; we use
//  the classes for coordinated reads/writes, change tracking, and NSFileVersion
//  conflict detection, and present them inside the pane ourselves.
//
//  A thin shared protocol keeps the edit session platform-agnostic.
//

import Foundation
import Synchronization
#if os(macOS)
import AppKit
#else
import UIKit
#endif

let markdownFileType = "net.daringfireball.markdown"

@MainActor
protocol WorkspaceDocumentFileProtocol: AnyObject {
    var documentText: String { get set }
    var isDirty: Bool { get }
    var presentedURL: URL? { get }
    /// The file changed under us (another device, an external editor). The edit
    /// session decides: clean buffer reloads, dirty buffer goes to conflict flow.
    /// @Sendable because file presenters fire on coordination queues; the setter
    /// hops to the main actor itself.
    var onExternalChange: (@Sendable () -> Void)? { get set }
    func openFile() async -> Bool
    func saveFile() async -> Bool
    func closeFile() async
    /// Re-read the file from disk into the buffer, discarding the buffer.
    func revertFromDisk() async -> Bool
}

#if os(macOS)

/// Embedded NSDocument. `hasUndoManager` is off — the text view owns undo.
/// The buffer sits behind a Mutex because NSDocument's read/data overrides are
/// nonisolated in the SDK and can run on coordination queues.
@MainActor
final class WorkspaceDocumentFile: NSDocument, WorkspaceDocumentFileProtocol {
    private let textBox = Mutex<String>("")
    private let externalChangeBox = Mutex<(@Sendable () -> Void)?>(nil)

    var onExternalChange: (@Sendable () -> Void)? {
        get { externalChangeBox.withLock { $0 } }
        set { externalChangeBox.withLock { $0 = newValue } }
    }

    var documentText: String {
        get { textBox.withLock { $0 } }
        set {
            let changed = textBox.withLock { current -> Bool in
                guard current != newValue else { return false }
                current = newValue
                return true
            }
            if changed { updateChangeCount(.changeDone) }
        }
    }

    var isDirty: Bool { isDocumentEdited }
    var presentedURL: URL? { fileURL }

    convenience init(url: URL) {
        self.init()
        hasUndoManager = false
        fileURL = url
        fileType = markdownFileType
    }

    override nonisolated class var autosavesInPlace: Bool { true }

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        let contents = String(data: data, encoding: .utf8) ?? ""
        textBox.withLock { $0 = contents }
    }

    override nonisolated func data(ofType typeName: String) throws -> Data {
        Data(textBox.withLock { $0 }.utf8)
    }

    override nonisolated func presentedItemDidChange() {
        super.presentedItemDidChange()
        externalChangeBox.withLock { $0 }?()
    }

    func openFile() async -> Bool {
        guard let url = fileURL else { return false }
        do {
            // Coordinated read through NSDocument's own machinery.
            try revert(toContentsOf: url, ofType: markdownFileType)
            return true
        } catch {
            // A row can sync before its bytes arrive (design §4.4): open empty,
            // the metadata query's download + external-change path fills it in.
            textBox.withLock { $0 = "" }
            updateChangeCount(.changeCleared)
            return false
        }
    }

    func saveFile() async -> Bool {
        guard let url = fileURL else { return false }
        // An external write bumps the on-disk date, and NSDocument refuses to
        // overwrite what it reads as someone else's changes. By the time this
        // runs, the conflict flow has already preserved the disk version as a
        // sibling (design §5), so adopt the current date and take the path.
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let onDisk = attributes[.modificationDate] as? Date {
            fileModificationDate = onDisk
        }
        return await withCheckedContinuation { continuation in
            save(to: url, ofType: markdownFileType, for: .saveOperation) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    func closeFile() async {
        close()
    }

    func revertFromDisk() async -> Bool {
        guard let url = fileURL else { return false }
        return (try? revert(toContentsOf: url, ofType: markdownFileType)) != nil
    }
}

#else

/// UIDocument: coordination, autosave hooks, and conflict state for free.
/// The buffer sits behind a Mutex because UIDocument's contents/load overrides
/// are nonisolated in the SDK and run on its background queue.
@MainActor
final class WorkspaceDocumentFile: UIDocument, WorkspaceDocumentFileProtocol {
    private let textBox = Mutex<String>("")
    private let dirtyBox = Mutex<Bool>(false)
    private let externalChangeBox = Mutex<(@Sendable () -> Void)?>(nil)

    var onExternalChange: (@Sendable () -> Void)? {
        get { externalChangeBox.withLock { $0 } }
        set { externalChangeBox.withLock { $0 = newValue } }
    }

    /// Explicit nonisolated override: the SDK's designated init is nonisolated,
    /// and the class's implicit MainActor isolation would otherwise conflict.
    override nonisolated init(fileURL url: URL) {
        super.init(fileURL: url)
    }

    var documentText: String {
        get { textBox.withLock { $0 } }
        set {
            let changed = textBox.withLock { current -> Bool in
                guard current != newValue else { return false }
                current = newValue
                return true
            }
            if changed {
                dirtyBox.withLock { $0 = true }
                updateChangeCount(.done)
            }
        }
    }

    var isDirty: Bool { dirtyBox.withLock { $0 } }
    var presentedURL: URL? { fileURL }

    override nonisolated func contents(forType typeName: String) throws -> Any {
        Data(textBox.withLock { $0 }.utf8)
    }

    override nonisolated func load(fromContents contents: Any, ofType typeName: String?) throws {
        if let data = contents as? Data {
            let text = String(data: data, encoding: .utf8) ?? ""
            textBox.withLock { $0 = text }
        }
        dirtyBox.withLock { $0 = false }
    }

    override nonisolated func presentedItemDidChange() {
        super.presentedItemDidChange()
        externalChangeBox.withLock { $0 }?()
    }

    func openFile() async -> Bool {
        await withCheckedContinuation { continuation in
            open { continuation.resume(returning: $0) }
        }
    }

    func saveFile() async -> Bool {
        let success = await withCheckedContinuation { continuation in
            save(to: fileURL, for: .forOverwriting) { continuation.resume(returning: $0) }
        }
        if success { dirtyBox.withLock { $0 = false } }
        return success
    }

    func closeFile() async {
        await withCheckedContinuation { continuation in
            close { _ in continuation.resume() }
        }
    }

    func revertFromDisk() async -> Bool {
        let success = await withCheckedContinuation { continuation in
            revert(toContentsOf: fileURL) { continuation.resume(returning: $0) }
        }
        if success { dirtyBox.withLock { $0 = false } }
        return success
    }
}

#endif
