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
    var id: String { "\(domain)\u{0}\(username)" }
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

    @discardableResult
    static func save(domain: String, username: String, password: String) -> OSStatus {
        guard !domain.isEmpty, !username.isEmpty, !password.isEmpty else { return errSecParam }
        let data = Data(password.utf8)
        let status = SecItemUpdate(
            identity(domain: domain, username: username) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard status == errSecItemNotFound else { return status }
        var item = identity(domain: domain, username: username)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil)
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
            return SavedCredential(domain: domain, username: username)
        }
        .sorted { $0.domain == $1.domain ? $0.username < $1.username : $0.domain < $1.domain }
    }
}
