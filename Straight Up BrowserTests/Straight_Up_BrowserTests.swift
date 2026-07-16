//
//  Straight_Up_BrowserTests.swift
//  Straight Up BrowserTests
//
//  Created by Nathan Fennel on 1/9/26.
//

import Testing
import SwiftUI
@testable import Browser

struct Straight_Up_BrowserTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

}

// Serialized: these mutate the shared ShortcutStore singleton, so they must not
// run in parallel with each other.
@Suite(.serialized)
struct ShortcutTests {

    @Test func shortcutValueConversions() {
        let cmdShiftT = Shortcut(key: "t", command: true, shift: true)
        #expect(cmdShiftT.displayString == "⇧⌘T")
        #expect(cmdShiftT.displayTokens == ["⇧", "⌘", "T"])
        #expect(cmdShiftT.eventModifiers.contains(.command))
        #expect(cmdShiftT.eventModifiers.contains(.shift))
        #expect(cmdShiftT.hasModifier)

        // Special keys render as glyphs, not raw characters.
        #expect(ShortcutCommand.nextTab.defaultShortcut.displayTokens == ["⌃", "⇥"])
        #expect(ShortcutCommand.omnibar.defaultShortcut.displayString == "⌃Space")

        // No two defaults collide.
        var seen = Set<Shortcut>()
        for command in ShortcutCommand.all {
            #expect(seen.insert(command.defaultShortcut).inserted, "duplicate default for \(command.id)")
        }
    }

    @Test func shortcutStoreRebindResetAndConflicts() {
        let store = ShortcutStore.shared
        store.resetAll()

        // Defaults
        #expect(store.shortcut(for: .newTab).displayString == "⌘T")
        #expect(store.shortcut(for: .closeTab).displayString == "⌘W")
        #expect(store.conflicts().isEmpty)
        #expect(!store.isCustomized(.newTab))

        // Rebind → lookup reflects it and it counts as customized.
        store.rebind(.newTab, to: Shortcut(key: "y", command: true))
        #expect(store.shortcut(for: .newTab).displayString == "⌘Y")
        #expect(store.isCustomized(.newTab))

        // Two commands on the same chord are flagged as conflicting.
        store.rebind(.closeTab, to: Shortcut(key: "y", command: true))
        let conflictIDs = Set(store.conflicts().map(\.id))
        #expect(conflictIDs.contains("newTab"))
        #expect(conflictIDs.contains("closeTab"))

        // Rebinding back to the default drops the customization entirely.
        store.rebind(.newTab, to: ShortcutCommand.newTab.defaultShortcut)
        #expect(!store.isCustomized(.newTab))

        // Per-command reset and reset-all.
        store.reset(.closeTab)
        #expect(store.shortcut(for: .closeTab).displayString == "⌘W")
        store.resetAll()
        #expect(store.custom.isEmpty)
        #expect(store.conflicts().isEmpty)
    }

    @Test func presetsAndSystemConflicts() {
        let store = ShortcutStore.shared
        store.resetAll()

        // A preset changes the bindings it specifies, leaving the rest at default.
        store.apply(preset: .firefox)
        #expect(store.shortcut(for: .fullScreen).displayString == "⌃⌘F")
        #expect(store.shortcut(for: .showBookmarks).displayString == "⇧⌘O")
        #expect(store.shortcut(for: .newTab).displayString == "⌘T")

        // Applying another preset replaces the previous one wholesale.
        store.apply(preset: .arc)
        #expect(store.shortcut(for: .toggleTabBar).displayString == "⌘S")
        #expect(store.shortcut(for: .showBookmarks).displayString == "⇧⌘B")

        store.resetAll()
        #expect(store.custom.isEmpty)

        // Well-known system chords are recognized; ordinary ones aren't.
        #expect(store.systemConflict(Shortcut(key: " ", command: true)) == "Spotlight")
        #expect(store.systemConflict(Shortcut(key: "q", command: true)) == "Quit")
        #expect(store.systemConflict(Shortcut(key: "t", command: true)) == nil)
    }

    @Test func liveHighlightState() {
        let live = LiveKeyState.shared
        live.deactivate()
        live.isActive = true

        // Holding ⌘ alone lights the ⌘ token but not the key, and the ⌘T chord
        // isn't fully held yet.
        live.command = true
        let cmdT = Shortcut(key: "t", command: true)
        #expect(live.isHeld("⌘", in: cmdT))
        #expect(!live.isHeld("T", in: cmdT))
        #expect(!live.fullyHeld(cmdT))

        // Pressing T completes the chord.
        live.pressedKey = "t"
        #expect(live.isHeld("T", in: cmdT))
        #expect(live.fullyHeld(cmdT))

        // ⌘T held is not ⇧⌘T.
        let shiftCmdT = Shortcut(key: "t", command: true, shift: true)
        #expect(!live.isHeld("⇧", in: shiftCmdT))
        #expect(!live.fullyHeld(shiftCmdT))

        live.deactivate()
        #expect(!live.isActive)
    }
}
