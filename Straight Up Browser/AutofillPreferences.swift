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

/// A local autofill identity. Contact identifiers are opaque, device-local
/// references; the contact's actual values remain solely in Contacts.
nonisolated enum AutofillPersonReference: Hashable, Sendable {
    case manual(UUID)
    case me
    case contact(String)

    var storageValue: String {
        switch self {
        case .manual(let id): "manual:\(id.uuidString)"
        case .me: "me"
        case .contact(let identifier): "contact:\(identifier)"
        }
    }

    init?(storageValue: String) {
        if storageValue == "me" {
            self = .me
        } else if storageValue.hasPrefix("manual:"),
                  let id = UUID(uuidString: String(storageValue.dropFirst(7))) {
            self = .manual(id)
        } else if storageValue.hasPrefix("contact:") {
            let identifier = String(storageValue.dropFirst(8))
            guard !identifier.isEmpty else { return nil }
            self = .contact(identifier)
        } else {
            return nil
        }
    }
}

@Observable
final class AutofillPreferences {
    static let shared = AutofillPreferences()

    enum Key {
        static let enabled = "autofillEnabled"
        static let activePerson = "autofillActivePerson"
        /// Read only to migrate the old manual-profile preference.
        static let legacyActiveProfile = "autofillActiveProfileID"
        static let contactIdentifiers = "autofillContactIdentifiers"
        static let includesMyCard = "autofillIncludesMyCard"
        static let disabledCategories = "autofillDisabledCategories"
        static let disabledHosts = "autofillDisabledHosts"
        static let allowInIncognito = "autofillAllowInIncognito"

        /// Every key this store owns. Pinned by a test so a new setting can't be
        /// added without the settings UI and "delete everything" learning about it.
        static let all: Set<String> = [
            enabled, activePerson, contactIdentifiers, includesMyCard,
            disabledCategories, disabledHosts, allowInIncognito,
        ]

        static let reset: Set<String> = all.union([legacyActiveProfile])
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
        if let stored = defaults.string(forKey: Key.activePerson),
           let person = AutofillPersonReference(storageValue: stored) {
            activePerson = person
        } else if let legacy = defaults.string(forKey: Key.legacyActiveProfile)
            .flatMap(UUID.init(uuidString:)) {
            let person = AutofillPersonReference.manual(legacy)
            activePerson = person
            defaults.set(person.storageValue, forKey: Key.activePerson)
        } else {
            activePerson = nil
        }
        contactIdentifiers = Self.unique(defaults.stringArray(forKey: Key.contactIdentifiers) ?? [])
        includesMyCard = defaults.bool(forKey: Key.includesMyCard)
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

    // MARK: People

    var activePerson: AutofillPersonReference? {
        didSet {
            if let activePerson {
                defaults.set(activePerson.storageValue, forKey: Key.activePerson)
            } else {
                defaults.removeObject(forKey: Key.activePerson)
            }
        }
    }

    /// A compact, local-only roster. Values remain in the Contacts database.
    private(set) var contactIdentifiers: [String] {
        didSet { defaults.set(contactIdentifiers, forKey: Key.contactIdentifiers) }
    }

    var includesMyCard: Bool {
        didSet { defaults.set(includesMyCard, forKey: Key.includesMyCard) }
    }

    static let maximumContactPeople = 12

    var contactPeople: [AutofillPersonReference] {
        (includesMyCard ? [.me] : []) + contactIdentifiers.map(AutofillPersonReference.contact)
    }

    @discardableResult
    func addContact(identifier: String) -> Bool {
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty,
              !contactIdentifiers.contains(identifier),
              contactIdentifiers.count < Self.maximumContactPeople else {
            return false
        }
        contactIdentifiers.append(identifier)
        return true
    }

    func removeContact(identifier: String) {
        contactIdentifiers.removeAll { $0 == identifier }
        if activePerson == .contact(identifier) { activePerson = nil }
    }

    func replaceContact(identifier: String, with resolvedIdentifier: String) {
        guard identifier != resolvedIdentifier,
              let index = contactIdentifiers.firstIndex(of: identifier) else { return }
        contactIdentifiers[index] = resolvedIdentifier
        contactIdentifiers = Self.unique(contactIdentifiers)
        if activePerson == .contact(identifier) {
            activePerson = .contact(resolvedIdentifier)
        }
    }

    func setMyCardIncluded(_ included: Bool) {
        includesMyCard = included
        if !included, activePerson == .me { activePerson = nil }
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
        for key in Key.reset { defaults.removeObject(forKey: key) }
        isEnabled = true
        allowInIncognito = false
        disabledCategories = []
        disabledHosts = []
        activePerson = nil
        contactIdentifiers = []
        includesMyCard = false
    }

    private static func unique(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && seen.insert(value).inserted ? value : nil
        }
    }
}
