import Foundation
import Testing
import AppKit
@testable import Browser

@MainActor struct ShortcutDiagnosticsTests {
    private func store() -> ShortcutStore {
        ShortcutStore(defaults: UserDefaults(suiteName: "ShortcutDiagnosticsTests.\(UUID())")!)
    }

    @Test func comparisonIncludesShiftedPunctuationAndModifiers() {
        #expect(!Shortcut(key: ":", command: true).normalizedChord.shift)
        #expect(Shortcut(key: "K", command: true).normalizedChord == Shortcut(key: "k", command: true))
        #expect(Shortcut(key: "k", command: true).normalizedChord != Shortcut(key: "k", command: true, shift: true))
    }

    @Test func unshiftedPunctuationDoesNotAcquireAUSShiftModifier() throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil,
            characters: ":", charactersIgnoringModifiers: ":", isARepeat: false, keyCode: 41))
        #expect(Shortcut(key: ":", command: true).matches(event))
        #expect(Shortcut(event: event)?.shift == false)
    }

    @Test func repairedCollisionPreservesPeerAndRejectsUnsafeUndo() throws {
        let store = store()
        let peer = store.shortcut(for: .newTab)
        store.rebind(.reload, to: peer)
        let preview = try #require(ShortcutRepair.preview(.reload, store: store))
        #expect(preview.after == ShortcutCommand.reload.defaultShortcut)
        let receipt = try #require(preview.apply(to: store))
        #expect(store.shortcut(for: .newTab) == peer)
        #expect(store.shortcut(for: .reload) == preview.after)
        #expect(!receipt.undo(in: store)) // Would recreate the duplicate.
    }

    @Test func previewCannotOverwriteAnAwayAndBackEdit() throws {
        let store = store()
        store.rebind(.reload, to: Shortcut(key: "x", command: true, control: true))
        let preview = try #require(ShortcutRepair.preview(.reload, store: store))
        store.reset(.reload)
        store.rebind(.reload, to: preview.before)
        #expect(preview.apply(to: store) == nil)
        #expect(store.shortcut(for: .reload) == preview.before)
    }

    @Test func undoRestoresASafeBindingButPreservesLaterEdits() throws {
        let store = store()
        store.rebind(.reload, to: Shortcut(key: "x", command: true, control: true))
        let receipt = try #require(ShortcutRepair.preview(.reload, store: store)?.apply(to: store))
        #expect(receipt.undo(in: store))
        let next = try #require(ShortcutRepair.preview(.reload, store: store)?.apply(to: store))
        store.rebind(.newTab, to: Shortcut(key: "z", command: true, option: true))
        #expect(next.undo(in: store))
        #expect(store.shortcut(for: .newTab) == Shortcut(key: "z", command: true, option: true))
    }

    @Test func fixedBrowserAliasesAreDiagnosedWithoutAnOSScan() {
        let store = store()
        store.rebind(.reload, to: Shortcut(key: "n", command: true))
        #expect(ShortcutDiagnostics.issues(for: .reload, store: store).contains(where: { $0.confirmed && $0.explanation.contains("New Window") }))
        store.rebind(.reload, to: Shortcut(key: " ", command: true))
        #expect(ShortcutDiagnostics.issues(for: .reload, store: store).contains(where: { !$0.confirmed && $0.explanation.contains("normally") }))
    }

    @Test func undoCannotRestoreAnAliasEnabledAfterTheRepair() {
        let store = store()
        let before = Shortcut(key: "\\", command: true)
        let after = ShortcutCommand.reload.defaultShortcut
        store.rebind(.reload, to: after)
        let receipt = ShortcutRepair(commandID: ShortcutCommand.reload.id,
                                     before: before, after: after,
                                     revision: store.revision(for: .reload))
        #expect(!receipt.undo(in: store, expandedNavigationAliases: true))
        #expect(store.shortcut(for: .reload) == after)
        #expect(receipt.undo(in: store, expandedNavigationAliases: false))
        #expect(store.shortcut(for: .reload) == before)
    }

}
