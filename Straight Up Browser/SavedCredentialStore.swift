//
//  SavedCredentialStore.swift
//  Straight Up Browser
//
//  The browser's own password vault: a private Keychain item per
//  domain+username. Deliberately not the system Passwords store — a
//  sandboxed third-party app has no read access to that (it's what the
//  right-click "AutoFill > Passwords…" menu item is for) — this is a
//  separate, ordinary Keychain item scoped to this app, the same mechanism
//  BrowserAgentKeychain already uses for provider API keys.
//

import Foundation
import Security

nonisolated struct SavedCredential: Identifiable, Equatable, Sendable {
    let domain: String
    let username: String
    /// Ask for Touch ID (or the login password) before this one is filled.
    var requiresAuthentication: Bool = false
    var id: String { "\(domain)\u{0}\(username)" }
}

/// How Browser behaves when a login form is submitted with a password it
/// hasn't seen. Plain UserDefaults: three keys, read on every submit.
nonisolated enum CredentialPreferences {
    enum PromptStyle: String, CaseIterable, Identifiable {
        /// A card next to the login fields, with favicon and a Touch ID toggle.
        case card
        /// The original one-line banner at the top of the window.
        case banner
        /// Never ask; `savesSilently` decides whether to save anyway.
        case none
        var id: String { rawValue }
    }

    static let styleKey = "credentialSavePromptStyle"
    static let silentSaveKey = "credentialSavesSilently"
    static let neverSaveHostsKey = "credentialNeverSaveHosts"

    static var promptStyle: PromptStyle {
        get { UserDefaults.standard.string(forKey: styleKey).flatMap(PromptStyle.init) ?? .card }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: styleKey) }
    }

    /// Only consulted when `promptStyle == .none`.
    static var savesSilently: Bool {
        get { UserDefaults.standard.bool(forKey: silentSaveKey) }
        set { UserDefaults.standard.set(newValue, forKey: silentSaveKey) }
    }

    static var neverSaveHosts: [String] {
        get { (UserDefaults.standard.stringArray(forKey: neverSaveHostsKey) ?? []).sorted() }
        set { UserDefaults.standard.set(Array(Set(newValue)).sorted(), forKey: neverSaveHostsKey) }
    }

    static func setNeverSave(_ host: String, _ never: Bool) {
        let host = host.lowercased()
        var hosts = Set(neverSaveHosts)
        if never { hosts.insert(host) } else { hosts.remove(host) }
        neverSaveHosts = Array(hosts)
    }

    static func allowsSaving(host: String) -> Bool {
        !neverSaveHosts.contains(host.lowercased())
    }
}

nonisolated enum SavedCredentialStore {
    // Internet-password items use security domain, not the generic-password
    // service attribute. Include the bundle ID to isolate development vaults.
    private static let service = (Bundle.main.bundleIdentifier ?? "com.nathanfennel.Straight-Up-Browser") + ".credentials"

    private static func identity(domain: String, username: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: service,
            kSecAttrServer as String: domain,
            kSecAttrAccount as String: username,
        ]
    }

    /// The "ask for Touch ID first" flag rides along as the item's comment
    /// attribute, so it comes back with every attributes-only query.
    private static let authenticationMarker = "requires-authentication"

    @discardableResult
    static func save(domain: String, username: String, password: String, requiresAuthentication: Bool = false) -> OSStatus {
        guard !domain.isEmpty, !username.isEmpty, !password.isEmpty else { return errSecParam }
        let data = Data(password.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrComment as String: requiresAuthentication ? authenticationMarker : "",
        ]
        let status = SecItemUpdate(identity(domain: domain, username: username) as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var item = identity(domain: domain, username: username).merging(attributes) { $1 }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil)
    }

    @discardableResult
    static func setRequiresAuthentication(_ requires: Bool, domain: String, username: String) -> OSStatus {
        SecItemUpdate(
            identity(domain: domain, username: username) as CFDictionary,
            [kSecAttrComment as String: requires ? authenticationMarker : ""] as CFDictionary
        )
    }

    static func requiresAuthentication(domain: String, username: String) -> Bool {
        var query = identity(domain: domain, username: username)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let item = result as? [String: Any] else { return false }
        return item[kSecAttrComment as String] as? String == authenticationMarker
    }

    static func password(domain: String, username: String) -> String? {
        var query = identity(domain: domain, username: username)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Every saved username for a domain — a site can have more than one
    /// account. Never fetches a password; that only happens on pick.
    static func usernames(domain: String) -> [String] {
        guard !domain.isEmpty else { return [] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: service,
            kSecAttrServer as String: domain,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    static func delete(domain: String, username: String) {
        SecItemDelete(identity(domain: domain, username: username) as CFDictionary)
    }

    /// Every saved credential, domain + username only — for the Settings
    /// management list. Never returns a password.
    static func all() -> [SavedCredential] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let domain = item[kSecAttrServer as String] as? String,
                  let username = item[kSecAttrAccount as String] as? String else { return nil }
            return SavedCredential(
                domain: domain,
                username: username,
                requiresAuthentication: item[kSecAttrComment as String] as? String == authenticationMarker
            )
        }
        .sorted { $0.domain == $1.domain ? $0.username < $1.username : $0.domain < $1.domain }
    }
}
