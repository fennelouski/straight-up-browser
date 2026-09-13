import Foundation
import Security
import Testing
@testable import Browser

struct SavedCredentialStoreTests {
    @Test func savesListsUpdatesAndDeletesMultipleAccounts() throws {
        let domain = "vault-test-\(UUID().uuidString).invalid"
        defer {
            SavedCredentialStore.delete(domain: domain, username: "alice")
            SavedCredentialStore.delete(domain: domain, username: "bob")
        }
        #expect(SavedCredentialStore.save(domain: domain, username: "alice", password: "first") == errSecSuccess)
        #expect(SavedCredentialStore.save(domain: domain, username: "bob", password: "second") == errSecSuccess)
        #expect(SavedCredentialStore.usernames(domain: domain) == ["alice", "bob"])
        #expect(SavedCredentialStore.password(domain: domain, username: "alice") == "first")
        #expect(SavedCredentialStore.save(domain: domain, username: "alice", password: "updated") == errSecSuccess)
        #expect(SavedCredentialStore.password(domain: domain, username: "alice") == "updated")
        #expect(SavedCredentialStore.password(domain: domain, username: "bob") == "second")
        #expect(SavedCredentialStore.all().filter { $0.domain == domain }.map(\.username) == ["alice", "bob"])
        SavedCredentialStore.delete(domain: domain, username: "alice")
        #expect(SavedCredentialStore.usernames(domain: domain) == ["bob"])
    }

    @Test func authenticationFlagRoundTripsAndSurvivesPasswordUpdate() {
        let domain = "vault-auth-\(UUID().uuidString).invalid"
        defer { SavedCredentialStore.delete(domain: domain, username: "alice") }
        #expect(SavedCredentialStore.save(domain: domain, username: "alice", password: "p", requiresAuthentication: true) == errSecSuccess)
        #expect(SavedCredentialStore.requiresAuthentication(domain: domain, username: "alice"))
        #expect(SavedCredentialStore.all().first { $0.domain == domain }?.requiresAuthentication == true)
        #expect(SavedCredentialStore.setRequiresAuthentication(false, domain: domain, username: "alice") == errSecSuccess)
        #expect(!SavedCredentialStore.requiresAuthentication(domain: domain, username: "alice"))
        #expect(SavedCredentialStore.requiresAuthentication(domain: domain, username: "nobody") == false)
    }

    @Test func doesNotReadOrOverwriteAnotherVault() {
        let domain = "vault-isolation-\(UUID().uuidString).invalid"
        let foreign: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: "foreign-test-\(UUID().uuidString)",
            kSecAttrServer as String: domain,
            kSecAttrAccount as String: "alice",
        ]
        var item = foreign
        item[kSecValueData as String] = Data("foreign".utf8)
        #expect(SecItemAdd(item as CFDictionary, nil) == errSecSuccess)
        defer {
            SecItemDelete(foreign as CFDictionary)
            SavedCredentialStore.delete(domain: domain, username: "alice")
        }
        #expect(SavedCredentialStore.usernames(domain: domain).isEmpty)
        #expect(SavedCredentialStore.password(domain: domain, username: "alice") == nil)
        #expect(SavedCredentialStore.save(domain: domain, username: "alice", password: "own") == errSecSuccess)
        #expect(SavedCredentialStore.password(domain: domain, username: "alice") == "own")
        var query = foreign
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        #expect(result as? Data == Data("foreign".utf8))
    }
}

// Serialized: neverSaveHostAndSilentModeSkipThePrompt flips the global prompt-style preference.
@Suite(.serialized)
@MainActor
struct CredentialSavePromptTests {
    @Test func changedPasswordOffersUpdateAndIdenticalSubmissionClearsStalePrompt() async throws {
        let domain = "prompt-test-\(UUID().uuidString.lowercased()).invalid"
        let username = "test-user"
        defer { SavedCredentialStore.delete(domain: domain, username: username) }
        let manager = CredentialManager()
        let tabID = UUID()
        func submit(_ password: String) async throws {
            NotificationCenter.default.post(name: .browserCredentialSubmitted, object: nil, userInfo: [
                "tabID": tabID, "domain": domain, "username": username, "password": password,
            ])
            try await Task.sleep(for: .milliseconds(50))
        }
        try await submit("original")
        #expect(manager.savePrompt?.isUpdate == false)
        manager.acceptSavePrompt()
        #expect(manager.savePrompt == nil)
        #expect(SavedCredentialStore.password(domain: domain, username: username) == "original")
        try await submit("replacement")
        #expect(manager.savePrompt?.isUpdate == true)
        manager.acceptSavePrompt()
        #expect(SavedCredentialStore.password(domain: domain, username: username) == "replacement")
        try await submit("stale")
        #expect(manager.savePrompt != nil)
        try await submit("replacement")
        #expect(manager.savePrompt == nil)
    }

    @Test func neverSaveHostAndSilentModeSkipThePrompt() async throws {
        let domain = "prompt-pref-\(UUID().uuidString.lowercased()).invalid"
        let style = CredentialPreferences.promptStyle, silent = CredentialPreferences.savesSilently
        defer {
            CredentialPreferences.setNeverSave(domain, false)
            CredentialPreferences.promptStyle = style
            CredentialPreferences.savesSilently = silent
            SavedCredentialStore.delete(domain: domain, username: "u")
        }
        let manager = CredentialManager()
        func submit(_ password: String) async throws {
            NotificationCenter.default.post(name: .browserCredentialSubmitted, object: nil, userInfo: [
                "tabID": UUID(), "domain": domain, "username": "u", "password": password,
            ])
            try await Task.sleep(for: .milliseconds(50))
        }
        CredentialPreferences.promptStyle = .card
        CredentialPreferences.setNeverSave(domain, true)
        try await submit("a")
        #expect(manager.savePrompt == nil)
        CredentialPreferences.setNeverSave(domain, false)
        CredentialPreferences.promptStyle = .none
        CredentialPreferences.savesSilently = false
        try await submit("a")
        #expect(manager.savePrompt == nil)
        #expect(SavedCredentialStore.password(domain: domain, username: "u") == nil)
        CredentialPreferences.savesSilently = true
        try await submit("a")
        #expect(manager.savePrompt == nil)
        #expect(SavedCredentialStore.password(domain: domain, username: "u") == "a")
    }
}
