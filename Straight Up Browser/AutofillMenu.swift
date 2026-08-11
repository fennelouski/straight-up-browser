//
//  AutofillMenu.swift
//  Straight Up Browser
//
//  The autofill menu, defined once and placed twice: in the tab sidebar header
//  next to Containers, and in the menu bar so the feature survives ⌥⌘` hiding
//  the tab bar entirely.
//
//  It reads profiles from a roster rather than @Query because the menu bar can't
//  see the model container — `.modelContainer(_:)` is applied to each scene's
//  content view, not to the scene, so it never reaches `.commands`. ContentView
//  owns the @Query and pushes a name-and-id projection in here.
//

import SwiftUI

struct AutofillProfileSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
}

/// Shared, view-facing autofill state: which profiles exist and what page is in
/// front. Deliberately a projection — no profile *values* live here, so nothing
/// in the menu layer holds the user's address.
@Observable
final class AutofillMenuState {
    static let shared = AutofillMenuState()

    private(set) var profiles: [AutofillProfileSummary] = []
    var currentPageURL: URL?

    var currentHost: String? { ShortcutPriorityStore.normalize(currentPageURL?.host) }

    func update(profiles: [AutofillProfileSummary]) {
        guard profiles != self.profiles else { return }
        self.profiles = profiles
    }
}

/// Keeps `AutofillMenuState` in step with the browser window that owns the
/// @Query. Bundled into one modifier because ContentView's body is already at
/// the type-checker's limit — three loose `.onChange`s there fail to compile.
struct AutofillWindowBridge: ViewModifier {
    /// Summaries, not models: comparing `[AutofillProfile]` only sees insertions
    /// and deletions, so renaming a profile would never reach the menus.
    let profiles: [AutofillProfileSummary]
    let pageURL: URL?
    let onEnabledChange: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {
                AutofillMenuState.shared.update(profiles: profiles)
                AutofillMenuState.shared.currentPageURL = pageURL
            }
            .onChange(of: profiles) { _, value in
                AutofillMenuState.shared.update(profiles: value)
            }
            .onChange(of: pageURL) { _, value in
                AutofillMenuState.shared.currentPageURL = value
            }
            .onChange(of: AutofillPreferences.shared.isEnabled) { _, value in
                onEnabledChange(value)
            }
    }
}

/// The menu's items, without the enclosing `Menu` — so the sidebar can wrap it
/// in a toolbar button and the menu bar can wrap it in a submenu.
struct AutofillMenuContent: View {
    /// Only the menu-bar copy carries ⌥⌘A. A popup menu's key equivalents don't
    /// register system-wide, so declaring it in both places would be noise.
    var hostsShortcut = false

    private var preferences: AutofillPreferences { .shared }
    private var state: AutofillMenuState { .shared }

    var body: some View {
        Toggle("Autofill", isOn: Binding(
            get: { preferences.isEnabled },
            set: { preferences.isEnabled = $0 }
        ))
        .modifier(AutofillShortcutModifier(active: hostsShortcut))

        if !state.profiles.isEmpty {
            Divider()
            Menu("Profile") {
                ForEach(state.profiles) { profile in
                    Button {
                        preferences.activeProfileID = profile.id
                    } label: {
                        if profile.id == resolvedActiveProfileID {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
            }
            .disabled(!preferences.isEnabled)
        }

        Divider()

        Menu("Include") {
            ForEach(AutofillCategory.allCases, id: \.self) { category in
                Toggle(isOn: Binding(
                    get: { preferences.allows(category) },
                    set: { preferences.setCategory(category, enabled: $0) }
                )) {
                    Label(category.label, systemImage: category.systemImage)
                }
            }
        }
        .disabled(!preferences.isEnabled)

        if let host = state.currentHost {
            Toggle("Never Autofill on \(host)", isOn: Binding(
                get: { !preferences.allows(host: host) },
                set: { preferences.setHost(host, enabled: !$0) }
            ))
            .disabled(!preferences.isEnabled)
        }

        Divider()

        Button("Autofill Settings…") {
            UserDefaults.standard.set(SettingsPane.autofill.rawValue, forKey: "settingsPane")
            NotificationCenter.default.post(name: .browserShowSettings, object: nil)
        }
    }

    private var resolvedActiveProfileID: UUID? {
        if let id = preferences.activeProfileID, state.profiles.contains(where: { $0.id == id }) {
            return id
        }
        return state.profiles.first?.id
    }
}

/// Applies ⌥⌘A only where it belongs. Reading the revision key keeps the binding
/// live when the user rebinds the chord in Settings, the same trick the app's
/// `sc(_:)` helper uses.
private struct AutofillShortcutModifier: ViewModifier {
    @AppStorage(ShortcutStore.revisionKey) private var revision = 0
    let active: Bool

    private var shortcut: KeyboardShortcut? {
        guard active, revision >= 0 else { return nil }
        return ShortcutStore.shared.shortcut(for: .toggleAutofill).keyboardShortcut
    }

    func body(content: Content) -> some View {
        content.keyboardShortcut(shortcut)
    }
}
