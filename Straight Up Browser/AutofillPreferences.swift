//
//  AutofillPreferences.swift
//  Straight Up Browser
//
//  The user's autofill choices: the ⌥⌘A master switch, which categories of
//  information autofill may use, which sites it stays out of, and whether it
//  runs in incognito.
//
//  One store rather than five @AppStorage bools, because the menu and the
//  settings pane both render `ForEach(AutofillCategory.allCases)` and can't bind
//  to per-case @AppStorage. Sets persist as arrays, the same shape as
//  TabSync.locallyClosedIds.
//
//  The active profile lives HERE and not as an `isActive` flag on the model:
//  "active" is a per-device UI choice, and a synced Bool would give two writers,
//  last-writer-wins, and states with zero or two profiles active at once.
//

import Foundation

@Observable
final class AutofillPreferences {
    static let shared = AutofillPreferences()

    enum Key {
        static let enabled = "autofillEnabled"
        static let activeProfile = "autofillActiveProfileID"
        static let disabledCategories = "autofillDisabledCategories"
        static let disabledHosts = "autofillDisabledHosts"
        static let allowInIncognito = "autofillAllowInIncognito"

        /// Every key this store owns. Pinned by a test so a new setting can't be
        /// added without the settings UI and "delete everything" learning about it.
        static let all: Set<String> = [
            enabled, activeProfile, disabledCategories, disabledHosts, allowInIncognito,
        ]
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // On by default: the feature never writes without an explicit pick, so
        // there's nothing to protect the user from until they've saved a profile.
        // Read through `object(forKey:)` so "never set" is distinguishable from
        // "deliberately off" — `bool(forKey:)` alone would report false for both.
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        allowInIncognito = defaults.bool(forKey: Key.allowInIncognito)
        disabledCategories = Set(defaults.stringArray(forKey: Key.disabledCategories) ?? [])
        disabledHosts = Set(defaults.stringArray(forKey: Key.disabledHosts) ?? [])
        activeProfileID = (defaults.string(forKey: Key.activeProfile)).flatMap(UUID.init(uuidString:))
    }

    // MARK: Master switch

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.enabled) }
    }

    /// Incognito is opt-in: a private tab shouldn't quietly hand over a real name
    /// and address just because the feature is on elsewhere.
    var allowInIncognito: Bool {
        didSet { defaults.set(allowInIncognito, forKey: Key.allowInIncognito) }
    }

    // MARK: Active profile

    var activeProfileID: UUID? {
        didSet {
            if let activeProfileID {
                defaults.set(activeProfileID.uuidString, forKey: Key.activeProfile)
            } else {
                defaults.removeObject(forKey: Key.activeProfile)
            }
        }
    }

    // MARK: Categories

    /// Stored as the disabled set so a newly added category is on by default.
    private(set) var disabledCategories: Set<String> {
        didSet { defaults.set(Array(disabledCategories), forKey: Key.disabledCategories) }
    }

    func allows(_ category: AutofillCategory) -> Bool {
        !disabledCategories.contains(category.rawValue)
    }

    func setCategory(_ category: AutofillCategory, enabled: Bool) {
        if enabled {
            disabledCategories.remove(category.rawValue)
        } else {
            disabledCategories.insert(category.rawValue)
        }
    }

    // MARK: Per-site exceptions

    private(set) var disabledHosts: Set<String> {
        didSet { defaults.set(Array(disabledHosts), forKey: Key.disabledHosts) }
    }

    /// Sorted for a stable settings list.
    var disabledHostList: [String] { disabledHosts.sorted() }

    func allows(host: String?) -> Bool {
        guard let host = ShortcutPriorityStore.normalize(host) else { return true }
        return !disabledHosts.contains(host)
    }

    func setHost(_ host: String?, enabled: Bool) {
        guard let host = ShortcutPriorityStore.normalize(host) else { return }
        if enabled {
            disabledHosts.remove(host)
        } else {
            disabledHosts.insert(host)
        }
    }

    // MARK: Gates

    /// Whether autofill may offer anything on this page at all. Checked before a
    /// suggestion list is ever built.
    ///
    /// The scheme allowlist matters: a local file: page must not be able to
    /// summon a list of the user's real name and address.
    func shouldOffer(url: URL?, incognito: Bool) -> Bool {
        guard isEnabled else { return false }
        guard !incognito || allowInIncognito else { return false }
        guard let url, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        return allows(host: url.host)
    }

    /// Whether this specific field may be offered, once the page has passed.
    func shouldOffer(field: AutofillField, url: URL?, incognito: Bool) -> Bool {
        shouldOffer(url: url, incognito: incognito) && allows(field.category)
    }

    // MARK: Reset

    /// Clears every setting this store owns. The profiles themselves are
    /// SwiftData records and are deleted separately by the settings pane.
    func resetAll() {
        for key in Key.all { defaults.removeObject(forKey: key) }
        isEnabled = true
        allowInIncognito = false
        disabledCategories = []
        disabledHosts = []
        activeProfileID = nil
    }
}
