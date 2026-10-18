#if os(macOS)
import SwiftUI
import AppKit

/// Diagnostics describe only dispatch paths Browser owns. Website routing
/// remains in ShortcutPriorityStore; it is not a duplicate or an OS scan.
enum ShortcutDiagnostics {
    struct Issue: Equatable {
        let explanation: String
        let confirmed: Bool
    }

    static let fixedBindings: [(String, Shortcut)] = [
        ("New Window", Shortcut(key: "n", command: true)),
        ("Save to Newspaper", Shortcut(key: "n", command: true, shift: true)),
        ("Keyboard Shortcuts (fixed alternate)", Shortcut(key: "k", command: true, shift: true)),
        ("Hold to Quit", Shortcut(key: "q", command: true)),
        ("Close Window", Shortcut(key: "w", command: true, shift: true, option: true)),
        ("Developer Tools", Shortcut(key: "i", command: true, option: true)),
        ("Developer Console", Shortcut(key: "j", command: true, option: true)),
        ("Select Page Element", Shortcut(key: "c", command: true, option: true)),
        ("Toggle Full Screen (alternate)", Shortcut(key: "f", command: true, option: true, control: true))
    ]

    static func issues(for command: ShortcutCommand, store: ShortcutStore) -> [Issue] {
        let chord = store.shortcut(for: command)
        var result = store.commandsSharing(chord, excluding: command).map {
            Issue(explanation: "Also assigned to \(String(localized: $0.title)) in Browser.", confirmed: true)
        }
        for (title, fixed) in fixedBindings where fixed.normalizedChord == chord.normalizedChord {
            result.append(Issue(explanation: "Browser reserves this for \(title). Choose another binding for \(String(localized: command.title)).", confirmed: true))
        }
        // A standard's intended Browser action is not an accidental collision.
        if chord.normalizedChord != command.defaultShortcut.normalizedChord,
           let standard = store.systemConflict(chord) {
            result.append(Issue(explanation: "macOS normally uses this for \(standard). It may take priority; your system overrides weren't inspected.", confirmed: false))
        }
        if SettingsManager.shared.expandBackForwardShortcuts,
           [Shortcut(key: "p", command: true), Shortcut(key: "\\", command: true)].contains(chord.normalizedChord) {
            result.append(Issue(explanation: "General → expanded Back/Forward shortcuts currently takes this chord before menu commands.", confirmed: true))
        }
        return result
    }

    static func replacement(for command: ShortcutCommand, store: ShortcutStore) -> Shortcut? {
        // Restore this command's documented default first. Do not invent a
        // chord by adding modifiers, or move the other command implicitly.
        let candidate = command.defaultShortcut
        guard candidate.normalizedChord != store.shortcut(for: command).normalizedChord,
              store.commandsSharing(candidate, excluding: command).isEmpty,
              !fixedBindings.contains(where: { $0.1.normalizedChord == candidate.normalizedChord }),
              store.systemConflict(candidate) == nil else { return nil }
        if SettingsManager.shared.expandBackForwardShortcuts,
           candidate.normalizedChord == Shortcut(key: "p", command: true) { return nil }
        return candidate
    }
}

struct ShortcutRepair: Equatable {
    let commandID: String
    let before: Shortcut
    let after: Shortcut
    let revision: Int

    static func preview(_ command: ShortcutCommand, store: ShortcutStore) -> Self? {
        guard let after = ShortcutDiagnostics.replacement(for: command, store: store) else { return nil }
        return Self(commandID: command.id, before: store.shortcut(for: command), after: after, revision: store.revision(for: command))
    }

    func apply(to store: ShortcutStore) -> ShortcutRepair? {
        guard let command = ShortcutCommand.by(id: commandID),
              revision == store.revision(for: command), store.shortcut(for: command) == before,
              ShortcutDiagnostics.replacement(for: command, store: store) == after else { return nil }
        store.rebind(command, to: after)
        return Self(commandID: commandID, before: before, after: after, revision: store.revision(for: command))
    }

    func undo(in store: ShortcutStore, expandedNavigationAliases: Bool = SettingsManager.shared.expandBackForwardShortcuts) -> Bool {
        guard let command = ShortcutCommand.by(id: commandID),
              revision == store.revision(for: command), store.shortcut(for: command) == after,
              store.commandsSharing(before, excluding: command).isEmpty,
              store.systemConflict(before) == nil,
              !(expandedNavigationAliases && [Shortcut(key: "p", command: true), Shortcut(key: "\\", command: true)].contains(before.normalizedChord)),
              !ShortcutDiagnostics.fixedBindings.contains(where: { $0.1.normalizedChord == before.normalizedChord }) else { return false }
        store.rebind(command, to: before)
        return true
    }
}

struct ShortcutIssueButton: View {
    let command: ShortcutCommand
    @State private var showing = false
    @State private var preview: ShortcutRepair?
    @State private var receipt: ShortcutRepair?
    @State private var status: String?
    private var store: ShortcutStore { .shared }
    private var issues: [ShortcutDiagnostics.Issue] { ShortcutDiagnostics.issues(for: command, store: store) }

    var body: some View {
        if !issues.isEmpty || receipt != nil {
            Button {
                preview = ShortcutRepair.preview(command, store: store)
                showing = true
            } label: {
                Image(systemName: issues.isEmpty ? "info.circle" : "exclamationmark.triangle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Shortcut details for \(String(localized: command.title))")
            .accessibilityValue(issues.map(\.explanation).joined(separator: " "))
            .help(issues.first?.explanation ?? "Shortcut changed. Undo is available.")
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(command.title).font(.headline)
                    Text(store.shortcut(for: command).displayString).monospaced()
                    ForEach(issues, id: \.explanation) { Text($0.explanation) }
                    Text("Other apps' shortcuts aren't fully checked.").font(.caption).foregroundStyle(.secondary)
                    if let preview {
                        Button("Use \(preview.after.displayString) for \(String(localized: command.title))") {
                            if let applied = preview.apply(to: store) {
                                receipt = applied
                                self.preview = nil
                                status = "Changed to \(applied.after.displayString)."
                            } else {
                                self.preview = ShortcutRepair.preview(command, store: store)
                                status = "Shortcuts changed. Review the refreshed suggestion."
                            }
                        }
                    } else if receipt == nil {
                        Text("Choose another binding with the recorder on this row.").font(.caption)
                    }
                    if let receipt {
                        Button("Undo shortcut change") {
                            if receipt.undo(in: store) { self.receipt = nil; status = "Shortcut restored." }
                            else { status = "The old binding is no longer safe to restore. Use the recorder to choose another." }
                        }
                    }
                    if let status { Text(status).font(.caption).accessibilityAddTraits(.updatesFrequently) }
                }
                .padding(16).frame(width: 360, alignment: .leading)
            }
        }
    }
}
#endif
