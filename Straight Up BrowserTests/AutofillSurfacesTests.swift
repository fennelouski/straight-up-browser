import Foundation
import Testing
@testable import Browser

/// The places autofill has to be reachable from: the settings sidebar, the
/// shortcut registry, and the iCloud disclosure.
@MainActor
struct AutofillSurfacesTests {
    @Test func autofillIsAFirstClassSettingsDestination() {
        #expect(SettingsPane.allCases.contains(.autofill))
        #expect(SettingsPane.autofill.rawValue == "autofill")
        #expect(SettingsPane.autofill.title == "Autofill")
        #expect(SettingsPane.autofill.systemImage == "text.append")
        #expect(SettingsPane.autofill.subtitle.contains("Profiles"))
        #expect(SettingsPane.autofill.subtitle.contains("contacts"))
    }

    @Test func toggleAutofillIsRegisteredAndRebindable() {
        #expect(ShortcutCommand.all.contains { $0.id == ShortcutCommand.toggleAutofill.id })
        // ⌥⌘A — ⇧⌘A is already spoken for by the AI Agent panel.
        let shortcut = ShortcutCommand.toggleAutofill.defaultShortcut
        #expect(shortcut.key == "a")
        #expect(shortcut.command)
        #expect(shortcut.option)
        #expect(!shortcut.shift)
        #expect(!shortcut.control)
    }

    @Test func toggleAutofillCollidesWithNothing() {
        // ShortcutStore.selfCheck asserts this globally in DEBUG; pin the new
        // chord explicitly so a future default change fails here by name.
        let others = ShortcutCommand.all
            .filter { $0.id != ShortcutCommand.toggleAutofill.id }
            .map(\.defaultShortcut)
        #expect(!others.contains(ShortcutCommand.toggleAutofill.defaultShortcut))
    }

    @Test func autofillHasNoAgentTool() {
        // Profile data must never be reachable by the agent. No tool may mention
        // it, under any name.
        let names = AgentToolCatalog.canonical
            .descriptors(visibleIn: .builtInAgent)
            .map { $0.name.lowercased() }
        #expect(!names.contains { $0.contains("autofill") })
        #expect(!names.contains { $0.contains("profile") })
        #expect(names.count == 46, "the built-in tool count is pinned; autofill must not add one")
    }
}
