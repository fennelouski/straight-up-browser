#if os(macOS)
import AppKit
import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security

// MARK: - Persisted connections and legacy migration

typealias BrowserAgentMCPConnection = MCPConnection

extension MCPConnection {
    /// Source-compatible bridge for the pre-2.0 connection model. New code
    /// should validate an `MCPEndpoint` explicitly and use `displayName`.
    nonisolated init(name: String, endpoint: String, enabled: Bool = true) {
        guard let validatedEndpoint = try? MCPEndpoint(endpoint) else {
            preconditionFailure("BrowserAgentMCPConnection requires a secure or loopback endpoint")
        }
        self.init(
            displayName: name,
            endpoint: validatedEndpoint,
            enabled: enabled
        )
    }

    nonisolated var name: String {
        get { displayName }
        set { displayName = newValue }
    }
}

/// Compatibility reader for bearer tokens saved by the pre-2.0 MCP store.
/// New credentials are written only through `MCPKeychainSecretVault`.
enum BrowserAgentMCPKeychain {
    private static let service = "com.nathanfennel.Straight-Up-Browser.agent-mcp"

    static func read(_ id: UUID) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func write(_ value: String, id: UUID) {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        if value.isEmpty {
            SecItemDelete(identity as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        if SecItemUpdate(
            identity as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        ) == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

nonisolated enum MCPKeychainSecretVaultError: Error, Equatable, Sendable, LocalizedError {
    case operationFailed(OSStatus)
    case malformedCredential

    var errorDescription: String? {
        switch self {
        case .operationFailed(let status):
            "Keychain could not complete the credential operation (status \(status))."
        case .malformedCredential:
            "Keychain contained malformed MCP credential data."
        }
    }
}

private nonisolated struct MCPKeychainOAuthRecord: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let tokenType: String
    let expiresAt: Date?
    let scopes: [String]
}

private nonisolated struct MCPKeychainTransientRecord: Codable, Sendable {
    let connectionID: UUID
    let secret: String
}

/// Production credential vault. Its private Codable records are encoded
/// directly into non-synchronizing, device-only Keychain items and never enter
/// settings, run persistence, diagnostics, or model messages.
actor MCPKeychainSecretVault: MCPSecretVault {
    private let service: String

    init(service: String = "com.nathanfennel.Straight-Up-Browser.agent-mcp.v2") {
        self.service = service
    }

    func bearerToken(for connectionID: UUID) throws -> MCPSecret? {
        guard let data = try read(account: bearerAccount(connectionID)),
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return MCPSecret(value)
    }

    func storeBearerToken(_ token: MCPSecret, for connectionID: UUID) throws {
        let data = token.withUnsafeStorage { Data($0.utf8) }
        try write(data, account: bearerAccount(connectionID))
    }

    func oauthTokens(for connectionID: UUID) throws -> MCPTokenBundle? {
        guard let data = try read(account: oauthAccount(connectionID)) else { return nil }
        guard let record = try? JSONDecoder().decode(MCPKeychainOAuthRecord.self, from: data) else {
            throw MCPKeychainSecretVaultError.malformedCredential
        }
        return MCPTokenBundle(
            accessToken: MCPSecret(record.accessToken),
            refreshToken: record.refreshToken.map(MCPSecret.init),
            tokenType: record.tokenType,
            expiresAt: record.expiresAt,
            scopes: record.scopes
        )
    }

    func storeOAuthTokens(_ tokens: MCPTokenBundle, for connectionID: UUID) throws {
        let accessToken = tokens.accessToken.withUnsafeStorage { $0 }
        let refreshToken = tokens.refreshToken?.withUnsafeStorage { $0 }
        let record = MCPKeychainOAuthRecord(
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: tokens.tokenType,
            expiresAt: tokens.expiresAt,
            scopes: tokens.scopes
        )
        try write(try JSONEncoder().encode(record), account: oauthAccount(connectionID))
    }

    func transientSecret(for reference: UUID) throws -> MCPSecret? {
        guard let data = try read(account: transientAccount(reference)),
              let record = try? JSONDecoder().decode(MCPKeychainTransientRecord.self, from: data) else {
            return nil
        }
        return MCPSecret(record.secret)
    }

    func storeTransientSecret(
        _ secret: MCPSecret,
        for reference: UUID,
        connectionID: UUID
    ) throws {
        let record = MCPKeychainTransientRecord(
            connectionID: connectionID,
            secret: secret.withUnsafeStorage { $0 }
        )
        try write(try JSONEncoder().encode(record), account: transientAccount(reference))
    }

    func removeTransientSecret(for reference: UUID) throws {
        try delete(account: transientAccount(reference))
    }

    func removeAllSecrets(for connectionID: UUID) throws {
        try delete(account: bearerAccount(connectionID))
        try delete(account: oauthAccount(connectionID))
        for item in try allItems() {
            guard item.account.hasPrefix("transient."),
                  let record = try? JSONDecoder().decode(MCPKeychainTransientRecord.self, from: item.data),
                  record.connectionID == connectionID else { continue }
            try delete(account: item.account)
        }
    }

    private func bearerAccount(_ id: UUID) -> String { "connection.\(id.uuidString).bearer" }
    private func oauthAccount(_ id: UUID) -> String { "connection.\(id.uuidString).oauth" }
    private func transientAccount(_ id: UUID) -> String { "transient.\(id.uuidString)" }

    private func read(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw MCPKeychainSecretVaultError.operationFailed(status)
        }
        return data
    }

    private func write(_ data: Data, account: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw MCPKeychainSecretVaultError.operationFailed(updateStatus)
        }
        var item = identity
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw MCPKeychainSecretVaultError.operationFailed(addStatus)
        }
    }

    private func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MCPKeychainSecretVaultError.operationFailed(status)
        }
    }

    private func allItems() throws -> [(account: String, data: Data)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw MCPKeychainSecretVaultError.operationFailed(status)
        }
        let dictionaries: [[String: Any]]
        if let values = result as? [[String: Any]] {
            dictionaries = values
        } else if let value = result as? [String: Any] {
            dictionaries = [value]
        } else {
            throw MCPKeychainSecretVaultError.malformedCredential
        }
        return dictionaries.compactMap { value in
            guard let account = value[kSecAttrAccount as String] as? String,
                  let data = value[kSecValueData as String] as? Data else { return nil }
            return (account, data)
        }
    }
}

nonisolated enum BrowserAgentMCPConnectionPersistence {
    private struct LegacyConnection: Codable {
        let id: UUID
        var name: String
        var endpoint: String
        var enabled: Bool
    }

    struct LoadResult: Sendable {
        var connections: [MCPConnection]
        var migratedLegacyRecords: Bool
        var discardedRecordCount: Int
    }

    static func load(from url: URL) -> LoadResult {
        guard let data = try? Data(contentsOf: url) else {
            return LoadResult(connections: [], migratedLegacyRecords: false, discardedRecordCount: 0)
        }
        if let decoded = try? JSONDecoder().decode([MCPConnection].self, from: data) {
            let unique = uniqueConnections(decoded)
            return LoadResult(
                connections: unique,
                migratedLegacyRecords: false,
                discardedRecordCount: decoded.count - unique.count
            )
        }
        guard let legacy = try? JSONDecoder().decode([LegacyConnection].self, from: data) else {
            return LoadResult(connections: [], migratedLegacyRecords: false, discardedRecordCount: 1)
        }
        var discarded = 0
        var migrated: [MCPConnection] = []
        var ids = Set<UUID>()
        for record in legacy {
            guard ids.insert(record.id).inserted,
                  let endpoint = try? MCPEndpoint(record.endpoint) else {
                discarded += 1
                continue
            }
            let name = cleanedName(record.name)
            migrated.append(MCPConnection(
                id: record.id,
                displayName: name.isEmpty ? "MCP Server" : name,
                endpoint: endpoint,
                enabled: record.enabled
            ))
        }
        return LoadResult(
            connections: migrated,
            migratedLegacyRecords: true,
            discardedRecordCount: discarded
        )
    }

    static func save(_ connections: [MCPConnection], to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(connections).write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func uniqueConnections(_ values: [MCPConnection]) -> [MCPConnection] {
        var ids = Set<UUID>()
        return values.filter { ids.insert($0.id).inserted }
    }

    private static func cleanedName(_ value: String) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - System OAuth presentation

@MainActor
protocol BrowserAgentMCPAuthorizationPresenting: AnyObject {
    func prepareRedirectURI() async throws -> URL
    func callbackURL(for authorizationURL: URL, redirectURI: URL) async throws -> URL
    func cancelAuthorization()
}

@MainActor
final class BrowserAgentMCPSystemAuthorizationPresenter: NSObject,
    BrowserAgentMCPAuthorizationPresenting,
    ASWebAuthenticationPresentationContextProviding {
    static let registrationRedirectURI = BrowserAgentMCPLoopbackAuthorizationListener.registrationRedirectURI

    private var session: ASWebAuthenticationSession?
    private var callbackListener: BrowserAgentMCPLoopbackAuthorizationListener?

    func prepareRedirectURI() async throws -> URL {
        guard session == nil, callbackListener == nil else {
            throw MCPConnectionError.authorizationDenied
        }
        let listener = try BrowserAgentMCPLoopbackAuthorizationListener()
        callbackListener = listener
        do {
            return try await listener.start()
        } catch {
            callbackListener = nil
            throw error
        }
    }

    func cancelAuthorization() {
        session?.cancel()
        session = nil
        callbackListener?.cancel(with: .authorizationDenied)
        callbackListener = nil
    }

    func callbackURL(for authorizationURL: URL, redirectURI: URL) async throws -> URL {
        guard session == nil,
              let callbackListener,
              callbackListener.redirectURI?.absoluteString == redirectURI.absoluteString,
              let state = Self.uniqueQueryValue(named: "state", in: authorizationURL),
              !state.isEmpty else {
            throw MCPConnectionError.authorizationStateMismatch
        }

        // ASWebAuthenticationSession does not expose a modern HTTP-loopback
        // callback matcher. A nil legacy matcher still provides the secure
        // system authentication surface; the one-shot loopback listener owns
        // completion and validates the exact URI and state.
        let authenticationSession = ASWebAuthenticationSession(
            url: authorizationURL,
            callbackURLScheme: nil
        ) { [weak callbackListener] _, error in
            guard error != nil else { return }
            callbackListener?.cancel(with: .authorizationDenied)
        }
        authenticationSession.presentationContextProvider = self
        authenticationSession.prefersEphemeralWebBrowserSession = true
        session = authenticationSession
        guard authenticationSession.start() else {
            session = nil
            self.callbackListener = nil
            callbackListener.cancel(with: .transportFailure)
            throw MCPConnectionError.transportFailure
        }

        return try await withTaskCancellationHandler {
            do {
                let callback = try await callbackListener.waitForCallback(expectedState: state)
                authenticationSession.cancel()
                session = nil
                self.callbackListener = nil
                return callback
            } catch {
                authenticationSession.cancel()
                session = nil
                self.callbackListener = nil
                throw error
            }
        } onCancel: {
            callbackListener.cancel(with: .authorizationDenied)
        }
    }

    private static func uniqueQueryValue(named name: String, in url: URL) -> String? {
        let values = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .filter { $0.name == name }
            .compactMap(\.value)
        guard values.count == 1 else { return nil }
        return values[0]
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) ?? ASPresentationAnchor()
    }
}

// MARK: - Browser agent routing

struct BrowserAgentMCPRoute: Sendable {
    struct ConnectionIdentity: Sendable {
        let id: UUID
        /// The legacy run-loop calls this `endpoint`, but policy scope uses the
        /// value as the server identity. Binding the normalized endpoint to the
        /// exact trust generation makes old approval digests unusable after an
        /// endpoint, identity, schema, capability, or scope change.
        let endpoint: String
    }

    let connection: ConnectionIdentity
    let toolName: String
    let exposedToolName: String
    let policyIdentity: MCPToolPolicyIdentity
}

/// Stable for retries of one persisted invocation, but distinct for two
/// deliberate invocations whose policy digest and arguments are identical.
nonisolated struct BrowserAgentMCPInvocationIdentity: Equatable, Sendable {
    let permitDigest: String
    let persistedStepID: UUID

    var idempotencyKey: String {
        let domain = "straight-up-browser:mcp-invocation:v1"
        let payload = "\(domain)|\(permitDigest.utf8.count)|\(permitDigest)|\(persistedStepID.uuidString.lowercased())"
        let digest = SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "sub-mcp-v1-\(digest)"
    }
}

struct BrowserAgentExternalTools {
    var definitions: [[String: Any]] = []
    var routes: [String: BrowserAgentMCPRoute] = [:]
}

@MainActor
final class BrowserAgentMCPStore: ObservableObject {
    static let shared: BrowserAgentMCPStore = {
        let transport = URLSessionMCPTransport()
        let vault = MCPKeychainSecretVault()
        let oauthClient = MCPHTTPTokenClient(transport: transport)
        let reservedNames = Set(
            AgentToolCatalog.canonical.allDescriptors.map(\.name)
                + AgentToolCatalog.canonical.aliases.map(\.name)
        )
        return BrowserAgentMCPStore(
            storeURL: BrowserCLI.supportDirectory.appendingPathComponent("agent-mcp-connections.json"),
            lifecycle: MCPConnectionLifecycle(
                transport: transport,
                vault: vault,
                oauthClient: oauthClient,
                reservedToolNames: reservedNames
            ),
            authorizationPresenter: BrowserAgentMCPSystemAuthorizationPresenter()
        )
    }()

    @Published private(set) var connections: [BrowserAgentMCPConnection]
    @Published private(set) var status: [UUID: String] = [:]
    @Published private(set) var activeOperations = Set<UUID>()
    @Published private(set) var oauthRedirectURIs: [UUID: URL] = [:]
    @Published private(set) var persistenceWarning: String?

    private let lifecycle: MCPConnectionLifecycle
    private let authorizationPresenter: any BrowserAgentMCPAuthorizationPresenting
    private let storeURL: URL

    init(
        storeURL: URL,
        lifecycle: MCPConnectionLifecycle,
        authorizationPresenter: any BrowserAgentMCPAuthorizationPresenting
    ) {
        self.storeURL = storeURL
        self.lifecycle = lifecycle
        self.authorizationPresenter = authorizationPresenter
        let loaded = BrowserAgentMCPConnectionPersistence.load(from: storeURL)
        connections = loaded.connections
        if loaded.discardedRecordCount > 0 {
            persistenceWarning = "Some saved MCP connections were invalid and were not loaded."
        }
        if loaded.migratedLegacyRecords {
            do {
                try BrowserAgentMCPConnectionPersistence.save(connections, to: storeURL)
            } catch {
                persistenceWarning = "Legacy MCP connections loaded, but their migrated records could not be saved."
            }
        }
    }

    func add(name: String, endpoint: String, bearerToken: String) async throws {
        let cleanName = Self.cleanedName(name)
        guard !cleanName.isEmpty else { throw MCPConnectionError.invalidEndpoint }
        var connection = MCPConnection(
            displayName: cleanName,
            endpoint: try MCPEndpoint(endpoint)
        )
        if !bearerToken.isEmpty {
            connection = try await lifecycle.configureBearerToken(
                MCPSecret(bearerToken),
                for: connection
            )
        }
        connections.append(connection)
        do {
            try persist()
        } catch {
            connections.removeAll { $0.id == connection.id }
            _ = await lifecycle.revoke(connection)
            throw error
        }
        status[connection.id] = connection.authorization == .bearer
            ? "Saved · Bearer credential in Keychain"
            : "Saved · Connect to inspect identity and tools"
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = index(of: id) else { return }
        connections[index].enabled = enabled
        if enabled {
            status[id] = "Enabled · Reconnect to refresh tools"
        } else {
            let connection = connections[index]
            status[id] = "Disabled"
            Task { await lifecycle.disconnect(connection) }
        }
        persistOrWarn()
    }

    /// A schedule may name only connections that are enabled, still bound to
    /// an explicitly approved trust snapshot, and backed by usable local
    /// authorization material. Resolution never performs a network request.
    func trustedLocallyAuthorizedConnectionIDs() async -> Set<UUID> {
        var result = Set<UUID>()
        for connection in connections where connection.enabled
            && connection.trust?.status == .trusted
        {
            if await lifecycle.hasLocalAuthorizationMaterial(for: connection) {
                result.insert(connection.id)
            }
        }
        return result
    }

    /// Returns the exact trust-bound identities used by policy for a saved set
    /// of connection IDs. Missing, disabled, revoked, untrusted, or locally
    /// unauthorized connections are omitted so the scheduler can fail closed.
    func trustedServerIdentities(
        for requestedIDs: Set<UUID>
    ) async -> [UUID: String] {
        let usableIDs = await trustedLocallyAuthorizedConnectionIDs()
        return Dictionary(uniqueKeysWithValues: connections.compactMap { connection in
            guard requestedIDs.contains(connection.id),
                  usableIDs.contains(connection.id),
                  let trust = connection.trust,
                  trust.status == .trusted else {
                return nil
            }
            return (
                connection.id,
                "\(connection.endpoint.canonicalString)#\(trust.binding)"
            )
        })
    }

    /// Reconnects and revalidates the exact saved set before an unattended Run
    /// starts. A selected server with no currently trusted route is omitted and
    /// therefore rejected by `AgentScheduledTaskDependencyResolver`.
    func prepareTrustedServerIdentities(
        for requestedIDs: Set<UUID>
    ) async -> [UUID: String] {
        guard !requestedIDs.isEmpty else { return [:] }
        let prepared = await prepareTools()
        var identities: [UUID: String] = [:]
        for route in prepared.routes.values
            where requestedIDs.contains(route.connection.id) {
            identities[route.connection.id] = route.connection.endpoint
        }
        return identities
    }

    func remove(_ id: UUID) async {
        guard let connection = connection(id: id) else { return }
        activeOperations.insert(id)
        status[id] = "Removing credentials…"
        _ = await lifecycle.revoke(connection)
        BrowserAgentMCPKeychain.write("", id: id)
        connections.removeAll { $0.id == id }
        status.removeValue(forKey: id)
        activeOperations.remove(id)
        persistOrWarn()
    }

    func test(_ connection: BrowserAgentMCPConnection) async {
        await reconnect(connection.id)
    }

    func reconnect(_ id: UUID) async {
        guard let current = connection(id: id), !activeOperations.contains(id) else { return }
        guard current.authorization.status != .revoked, current.trust?.status != .revoked else {
            status[id] = "Revoked · Reauthorize before reconnecting"
            return
        }
        activeOperations.insert(id)
        defer { activeOperations.remove(id) }
        status[id] = "Connecting with bounded transport…"
        do {
            let connected = try await connectAndPersist(current)
            status[id] = Self.connectionStatus(connected)
        } catch {
            recordFailure(id: id, error: error)
            status[id] = "Failed · \(Self.safeMessage(error))"
        }
    }

    func approveTrust(_ id: UUID) {
        guard let index = index(of: id), connections[index].trust?.status == .needsReview else { return }
        connections[index].approveCurrentTrust()
        status[id] = Self.connectionStatus(connections[index])
        persistOrWarn()
    }

    func authorizeOAuth(_ id: UUID, clientID: String, requestedScopes: [String]) async {
        guard var current = connection(id: id), !activeOperations.contains(id) else { return }
        let cleanClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanClientID.isEmpty else {
            status[id] = "Failed · Enter the OAuth public client ID registered for this server."
            return
        }
        activeOperations.insert(id)
        defer {
            authorizationPresenter.cancelAuthorization()
            oauthRedirectURIs[id] = nil
            activeOperations.remove(id)
        }
        status[id] = "Discovering OAuth metadata…"
        var pendingAuthorization: MCPOAuthPendingAuthorization?
        do {
            let discovery = try await lifecycle.discoverAuthorization(for: current)
            let redirectURI = try await authorizationPresenter.prepareRedirectURI()
            oauthRedirectURIs[id] = redirectURI
            let client = try MCPPublicOAuthClient(
                clientID: cleanClientID,
                redirectURI: redirectURI
            )
            let pending: MCPOAuthPendingAuthorization
            if current.authorization == .none {
                pending = try await lifecycle.beginAuthorization(
                    connection: current,
                    discovery: discovery,
                    client: client,
                    requestedScopes: requestedScopes
                )
            } else {
                let authorization = try await lifecycle.beginReauthorization(
                    connection: current,
                    discovery: discovery,
                    client: client,
                    requestedScopes: requestedScopes
                )
                current = authorization.connection
                replace(current)
                try persist()
                pending = authorization.pending
            }
            pendingAuthorization = pending
            BrowserAgentMCPKeychain.write("", id: id)
            status[id] = "Waiting for system authorization…"
            let callback = try await authorizationPresenter.callbackURL(
                for: pending.authorizationURL,
                redirectURI: pending.client.redirectURI
            )
            current = try await lifecycle.completeAuthorization(
                connection: current,
                pending: pending,
                callbackURL: callback
            )
            pendingAuthorization = nil
            replace(current)
            try persist()
        } catch {
            if let pendingAuthorization {
                var cancellation = URLComponents(
                    url: pendingAuthorization.client.redirectURI,
                    resolvingAgainstBaseURL: false
                )
                cancellation?.queryItems = [
                    URLQueryItem(name: "error", value: "access_denied"),
                    URLQueryItem(name: "state", value: pendingAuthorization.state),
                ]
                if let cancellationURL = cancellation?.url {
                    _ = try? await lifecycle.completeAuthorization(
                        connection: current,
                        pending: pendingAuthorization,
                        callbackURL: cancellationURL
                    )
                }
            }
            status[id] = "Authorization failed · \(Self.safeMessage(error))"
            return
        }

        status[id] = "Authorized · Verifying server identity…"
        do {
            let connected = try await connectAndPersist(current)
            status[id] = Self.connectionStatus(connected)
        } catch {
            recordFailure(id: id, error: error)
            status[id] = "Authorized; verification failed · \(Self.safeMessage(error))"
        }
    }

    func revoke(_ id: UUID) async {
        guard let current = connection(id: id), !activeOperations.contains(id) else { return }
        activeOperations.insert(id)
        status[id] = "Revoking and deleting Keychain credentials…"
        let result = await lifecycle.revoke(current)
        BrowserAgentMCPKeychain.write("", id: id)
        replace(result.connection)
        persistOrWarn()
        activeOperations.remove(id)
        switch result.remoteRevocation {
        case .succeeded:
            status[id] = "Revoked · Local credentials deleted and server notified"
        case .failed:
            status[id] = "Revoked locally · Server revocation endpoint was unavailable"
        case .notAvailable:
            status[id] = "Revoked · Local credentials deleted"
        }
    }

    func trustChanges(for connection: BrowserAgentMCPConnection) -> String? {
        guard let trust = connection.trust, !trust.changedDimensions.isEmpty else { return nil }
        return trust.changedDimensions
            .sorted { $0.rawValue < $1.rawValue }
            .map(Self.trustDimensionName)
            .joined(separator: ", ")
    }

    func prepareTools() async -> BrowserAgentExternalTools {
        var bundle = BrowserAgentExternalTools()
        let ids = connections.filter(\.enabled).map(\.id)
        for id in ids {
            guard let current = connection(id: id) else { continue }
            if current.authorization.status == .revoked || current.trust?.status == .revoked {
                status[id] = "Revoked · Reauthorize before reconnecting"
                continue
            }
            do {
                let connected = try await connectAndPersist(current)
                guard connected.trust?.status == .trusted else {
                    status[id] = Self.connectionStatus(connected)
                    continue
                }
                let tools = await lifecycle.tools(for: connected)
                for tool in tools {
                    let identity = try await lifecycle.policyIdentity(
                        for: connected,
                        exposedToolName: tool.exposedName
                    )
                    guard bundle.routes[tool.exposedName] == nil else { continue }
                    bundle.definitions.append([
                        "type": "function",
                        "function": [
                            "name": tool.exposedName,
                            "description": "\(connected.displayName): \(tool.description)",
                            "parameters": Self.foundationValue(tool.inputSchema),
                        ],
                    ])
                    bundle.routes[tool.exposedName] = BrowserAgentMCPRoute(
                        connection: .init(
                            id: connected.id,
                            endpoint: "\(identity.normalizedEndpoint)#\(identity.trustBinding)"
                        ),
                        toolName: tool.originalName,
                        exposedToolName: tool.exposedName,
                        policyIdentity: identity
                    )
                }
                status[id] = Self.connectionStatus(connected)
            } catch {
                recordFailure(id: id, error: error)
                status[id] = "Unavailable · \(Self.safeMessage(error))"
            }
        }
        return bundle
    }

    func call(
        _ route: BrowserAgentMCPRoute,
        arguments: [String: Any],
        invocation: BrowserAgentMCPInvocationIdentity
    ) async -> String {
        do {
            guard !invocation.permitDigest.isEmpty else {
                throw MCPConnectionError.malformedResponse
            }
            guard let current = connection(id: route.connection.id) else {
                throw MCPConnectionError.connectionRevoked
            }
            guard current.authorization.status != .revoked, current.trust?.status != .revoked else {
                throw MCPConnectionError.connectionRevoked
            }
            let liveIdentity = try await lifecycle.policyIdentity(
                for: current,
                exposedToolName: route.exposedToolName
            )
            guard liveIdentity == route.policyIdentity else {
                throw MCPConnectionError.trustRequired
            }
            let value = try MCPJSONValue(foundationValue: arguments)
            let result = try await lifecycle.call(
                connection: current,
                exposedToolName: route.exposedToolName,
                arguments: value,
                safety: .mutation(idempotencyKey: invocation.idempotencyKey)
            )
            return Self.jsonString(result.value)
        } catch {
            if error as? MCPConnectionError == .sessionExpired {
                status[route.connection.id] = "Session expired · Reconnect required"
            } else if error as? MCPConnectionError == .trustRequired {
                status[route.connection.id] = "Trust changed · Review and reconnect"
            }
            return Self.jsonString(.object(["error": .string(Self.safeMessage(error))]))
        }
    }

    private func connectAndPersist(_ original: MCPConnection) async throws -> MCPConnection {
        var connection = original
        let legacyToken = BrowserAgentMCPKeychain.read(connection.id)
        if connection.authorization == .none, !legacyToken.isEmpty {
            connection = try await lifecycle.configureBearerToken(
                MCPSecret(legacyToken),
                for: connection
            )
            replace(connection)
            try persist()
            BrowserAgentMCPKeychain.write("", id: connection.id)
        }
        do {
            let connected = try await lifecycle.reconnect(connection)
            replace(connected)
            try persist()
            return connected
        } catch MCPConnectionError.authorizationScopeChanged {
            let reconciled = try await lifecycle.reconcileAuthorization(connection)
            replace(reconciled)
            try persist()
            throw MCPConnectionError.authorizationScopeChanged
        }
    }

    private func recordFailure(id: UUID, error: Error) {
        guard let index = index(of: id) else { return }
        connections[index].lastTest = MCPConnectionTestResult(
            testedAt: Date(),
            succeeded: false,
            failureCode: Self.failureCode(error)
        )
        persistOrWarn()
    }

    private func connection(id: UUID) -> MCPConnection? {
        connections.first { $0.id == id }
    }

    private func index(of id: UUID) -> Int? {
        connections.firstIndex { $0.id == id }
    }

    private func replace(_ connection: MCPConnection) {
        guard let index = index(of: connection.id) else { return }
        connections[index] = connection
    }

    private func persist() throws {
        try BrowserAgentMCPConnectionPersistence.save(connections, to: storeURL)
        persistenceWarning = nil
    }

    private func persistOrWarn() {
        do {
            try persist()
        } catch {
            persistenceWarning = "MCP connection changes could not be saved."
        }
    }

    private static func cleanedName(_ value: String) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func connectionStatus(_ connection: MCPConnection) -> String {
        guard let trust = connection.trust else { return "Connected · Awaiting trust metadata" }
        if trust.status == .needsReview {
            let changes = trust.changedDimensions
                .sorted { $0.rawValue < $1.rawValue }
                .map(trustDimensionName)
                .joined(separator: ", ")
            return "Review required · \(changes)"
        }
        if trust.status == .revoked { return "Revoked · Reauthorization required" }
        return "Connected and trusted · \(connection.negotiation?.toolCount ?? 0) tools · trust v\(trust.generation)"
    }

    private static func trustDimensionName(_ value: MCPTrustDimension) -> String {
        switch value {
        case .endpoint: "endpoint"
        case .serverIdentity: "server identity"
        case .protocolVersion: "protocol"
        case .capabilities: "capabilities"
        case .toolSchema: "tool schemas"
        case .authorizationScopes: "OAuth scopes"
        case .authorization: "authorization"
        }
    }

    private static func failureCode(_ error: Error) -> String {
        guard let error = error as? MCPConnectionError else { return "integration_error" }
        return switch error {
        case .timeout: "timeout"
        case .unauthorized: "unauthorized"
        case .authorizationScopeChanged: "scope_changed"
        case .trustRequired: "trust_required"
        case .unsupportedProtocol: "protocol_mismatch"
        case .responseTooLarge: "response_too_large"
        case .responseTooDeep: "response_too_deep"
        case .connectionRevoked: "revoked"
        default: "mcp_error"
        }
    }

    private static func safeMessage(_ error: Error) -> String {
        if let error = error as? MCPConnectionError { return error.description }
        if let error = error as? MCPKeychainSecretVaultError { return error.localizedDescription }
        if error is CancellationError { return "The MCP operation was cancelled." }
        return "The MCP integration could not complete the operation."
    }

    private static func foundationValue(_ value: MCPJSONValue) -> Any {
        switch value {
        case .null: NSNull()
        case .boolean(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map(Self.foundationValue)
        case .object(let values): values.mapValues(Self.foundationValue)
        }
    }

    private static func jsonString(_ value: MCPJSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{\"error\":\"Invalid MCP response\"}" }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
