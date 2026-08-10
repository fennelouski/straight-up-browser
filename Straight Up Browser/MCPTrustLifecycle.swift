import CryptoKit
import Foundation

// MARK: - Bounded JSON

/// A Foundation-only JSON value used at the MCP trust boundary. Keeping this
/// distinct from provider and tool-catalog values makes depth enforcement an
/// explicit part of decoding untrusted server metadata and results.
nonisolated indirect enum MCPJSONValue: Codable, Equatable, Sendable {
    case null
    case boolean(Bool)
    case number(Double)
    case string(String)
    case array([MCPJSONValue])
    case object([String: MCPJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([MCPJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: MCPJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .boolean(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    init(foundationValue value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .boolean(value)
        case let value as NSNumber:
            self = .number(value.doubleValue)
        case let value as String:
            self = .string(value)
        case let values as [Any]:
            self = .array(try values.map(MCPJSONValue.init(foundationValue:)))
        case let values as [String: Any]:
            self = .object(try values.mapValues(MCPJSONValue.init(foundationValue:)))
        default:
            throw MCPConnectionError.malformedResponse
        }
    }

    var depth: Int {
        switch self {
        case .null, .boolean, .number, .string: 1
        case .array(let values): 1 + (values.map(\.depth).max() ?? 0)
        case .object(let values): 1 + (values.values.map(\.depth).max() ?? 0)
        }
    }

    var objectValue: [String: MCPJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [MCPJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .boolean(let value) = self else { return nil }
        return value
    }
}

// MARK: - Safe errors and endpoint identity

nonisolated enum MCPConnectionError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    case invalidEndpoint
    case insecureEndpoint
    case endpointCredentialsForbidden
    case endpointFragmentForbidden
    case endpointRedirected
    case invalidRedirectURI
    case invalidDiscoveryMetadata
    case metadataIdentityMismatch
    case unsupportedPKCE
    case unsupportedOAuthFlow
    case unsupportedScope
    case authorizationDenied
    case authorizationStateMismatch
    case authorizationExpired
    case missingAuthorizationCode
    case missingCredentials
    case missingRefreshToken
    case authorizationScopeChanged
    case connectionRevoked
    case trustRequired
    case unsupportedProtocol(String)
    case missingToolsCapability
    case invalidSessionIdentifier
    case invalidToolMetadata
    case duplicateToolName
    case unknownTool
    case requestTooLarge(limit: Int)
    case responseTooLarge(limit: Int)
    case responseTooDeep(limit: Int)
    case timeout(milliseconds: Int)
    case unauthorized(retrySuppressed: Bool)
    case sessionExpired
    case remoteRPCError(code: Int)
    case malformedResponse
    case transportFailure

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .invalidEndpoint: "The MCP endpoint is invalid."
        case .insecureEndpoint: "MCP endpoints require HTTPS except on loopback."
        case .endpointCredentialsForbidden: "MCP endpoint URLs cannot contain credentials."
        case .endpointFragmentForbidden: "MCP endpoint URLs cannot contain fragments."
        case .endpointRedirected: "MCP endpoint redirects are not accepted without explicit reconnection."
        case .invalidRedirectURI: "The OAuth redirect URI must use HTTPS or loopback HTTP."
        case .invalidDiscoveryMetadata: "The OAuth discovery metadata is invalid."
        case .metadataIdentityMismatch: "The OAuth metadata identity does not match the requested resource."
        case .unsupportedPKCE: "The authorization server does not advertise S256 PKCE."
        case .unsupportedOAuthFlow: "The authorization server does not support the required authorization-code flow."
        case .unsupportedScope: "A requested OAuth scope is not advertised for this resource."
        case .authorizationDenied: "Authorization was denied."
        case .authorizationStateMismatch: "The OAuth callback state did not match."
        case .authorizationExpired: "The OAuth authorization attempt expired."
        case .missingAuthorizationCode: "The OAuth callback did not include an authorization code."
        case .missingCredentials: "The MCP connection has no usable credentials."
        case .missingRefreshToken: "The MCP connection has no refresh token."
        case .authorizationScopeChanged: "The OAuth server changed the effective scopes; review is required."
        case .connectionRevoked: "The MCP connection has been revoked."
        case .trustRequired: "The MCP connection must be reviewed before tools can run."
        case .unsupportedProtocol: "The MCP server selected an unsupported protocol version."
        case .missingToolsCapability: "The MCP server did not negotiate tool support."
        case .invalidSessionIdentifier: "The MCP server returned an invalid session identifier."
        case .invalidToolMetadata: "The MCP server returned invalid tool metadata."
        case .duplicateToolName: "The MCP server returned duplicate tool names."
        case .unknownTool: "The requested MCP tool is not part of the trusted schema."
        case .requestTooLarge(let limit): "The MCP request exceeded the \(limit)-byte limit."
        case .responseTooLarge(let limit): "The MCP response exceeded the \(limit)-byte limit."
        case .responseTooDeep(let limit): "The MCP response exceeded the JSON depth limit of \(limit)."
        case .timeout(let milliseconds): "The MCP request exceeded its \(milliseconds)-millisecond timeout."
        case .unauthorized(let retrySuppressed): retrySuppressed
            ? "MCP authentication failed; retry was suppressed for mutation safety."
            : "MCP authentication failed."
        case .sessionExpired: "The MCP session expired and must be reconnected."
        case .remoteRPCError(let code): "The MCP server returned JSON-RPC error \(code)."
        case .malformedResponse: "The MCP server returned a malformed response."
        case .transportFailure: "The MCP transport failed."
        }
    }
}

nonisolated struct MCPEndpoint: Codable, Hashable, Sendable, CustomStringConvertible {
    let canonicalString: String
    let isLoopback: Bool

    init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let originalScheme = components.scheme?.lowercased(),
              let originalHost = components.host?.lowercased(),
              !originalHost.isEmpty else {
            throw MCPConnectionError.invalidEndpoint
        }
        guard components.user == nil, components.password == nil else {
            throw MCPConnectionError.endpointCredentialsForbidden
        }
        guard components.fragment == nil else {
            throw MCPConnectionError.endpointFragmentForbidden
        }
        guard components.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw MCPConnectionError.invalidEndpoint
        }

        let loopback = Self.loopbackHost(originalHost)
        guard originalScheme == "https" || (originalScheme == "http" && loopback) else {
            throw MCPConnectionError.insecureEndpoint
        }

        let decodedSegments = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .compactMap { String($0).removingPercentEncoding }
        guard !decodedSegments.contains("."), !decodedSegments.contains("..") else {
            throw MCPConnectionError.invalidEndpoint
        }

        components.scheme = originalScheme
        components.host = originalHost
        if (originalScheme == "https" && components.port == 443)
            || (originalScheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.percentEncodedPath == "/" { components.percentEncodedPath = "" }
        guard let canonical = components.string, let url = components.url, url.host != nil else {
            throw MCPConnectionError.invalidEndpoint
        }
        canonicalString = canonical
        isLoopback = loopback
    }

    var url: URL { URL(string: canonicalString)! }
    var description: String { canonicalString }

    var protectedResourceMetadataURL: URL {
        Self.wellKnownURL(identifier: url, suffix: "oauth-protected-resource")
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(canonicalString)
    }

    fileprivate static func wellKnownURL(identifier: URL, suffix: String) -> URL {
        var components = URLComponents(url: identifier, resolvingAgainstBaseURL: false)!
        let originalPath = components.percentEncodedPath == "/" ? "" : components.percentEncodedPath
        components.percentEncodedPath = "/.well-known/\(suffix)\(originalPath)"
        return components.url!
    }

    fileprivate static func loopbackHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host == "[::1]"
            || host == "0:0:0:0:0:0:0:1" || host == "[0:0:0:0:0:0:0:1]" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              let first = Int(octets[0]), first == 127,
              octets.allSatisfy({ part in
                  !part.isEmpty
                      && (part.count == 1 || part.first != "0")
                      && part.allSatisfy(\.isNumber)
                      && Int(part).map { (0...255).contains($0) } == true
              }) else { return false }
        return true
    }
}

nonisolated struct MCPAuthorizationIssuer: Codable, Hashable, Sendable {
    let canonicalString: String

    init(_ rawValue: String) throws {
        let endpoint = try MCPEndpoint(rawValue)
        guard endpoint.url.query == nil else { throw MCPConnectionError.invalidDiscoveryMetadata }
        canonicalString = endpoint.canonicalString
    }

    var url: URL { URL(string: canonicalString)! }
    var metadataURL: URL {
        MCPEndpoint.wellKnownURL(identifier: url, suffix: "oauth-authorization-server")
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(canonicalString)
    }
}

// MARK: - OAuth discovery and PKCE contracts

nonisolated struct MCPProtectedResourceMetadata: Codable, Equatable, Sendable {
    var resource: String
    var authorizationServers: [String]
    var scopesSupported: [String]

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }

    init(resource: String, authorizationServers: [String], scopesSupported: [String] = []) {
        self.resource = resource
        self.authorizationServers = authorizationServers
        self.scopesSupported = scopesSupported
    }
}

nonisolated struct MCPAuthorizationServerMetadata: Codable, Equatable, Sendable {
    var issuer: String
    var authorizationEndpoint: String
    var tokenEndpoint: String
    var revocationEndpoint: String?
    var registrationEndpoint: String?
    var scopesSupported: [String]
    var responseTypesSupported: [String]
    var grantTypesSupported: [String]
    var codeChallengeMethodsSupported: [String]
    var tokenEndpointAuthMethodsSupported: [String]

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case revocationEndpoint = "revocation_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case scopesSupported = "scopes_supported"
        case responseTypesSupported = "response_types_supported"
        case grantTypesSupported = "grant_types_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
    }

    init(
        issuer: String,
        authorizationEndpoint: String,
        tokenEndpoint: String,
        revocationEndpoint: String? = nil,
        registrationEndpoint: String? = nil,
        scopesSupported: [String] = [],
        responseTypesSupported: [String] = [],
        grantTypesSupported: [String] = [],
        codeChallengeMethodsSupported: [String] = [],
        tokenEndpointAuthMethodsSupported: [String] = []
    ) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.revocationEndpoint = revocationEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.scopesSupported = scopesSupported
        self.responseTypesSupported = responseTypesSupported
        self.grantTypesSupported = grantTypesSupported
        self.codeChallengeMethodsSupported = codeChallengeMethodsSupported
        self.tokenEndpointAuthMethodsSupported = tokenEndpointAuthMethodsSupported
    }
}

nonisolated struct MCPOAuthDiscovery: Codable, Equatable, Sendable {
    let protectedResource: MCPProtectedResourceMetadata
    let authorizationServer: MCPAuthorizationServerMetadata
    let resourceEndpoint: MCPEndpoint
    let issuer: MCPAuthorizationIssuer
    let authorizationURL: URL
    let tokenURL: URL
    let revocationURL: URL?
    let registrationURL: URL?

    init(
        protectedResource: MCPProtectedResourceMetadata,
        authorizationServer: MCPAuthorizationServerMetadata,
        endpoint: MCPEndpoint
    ) throws {
        guard protectedResource.resource == endpoint.canonicalString,
              let advertisedIssuer = protectedResource.authorizationServers.first,
              !advertisedIssuer.isEmpty else {
            throw MCPConnectionError.metadataIdentityMismatch
        }
        let normalizedIssuer = try MCPAuthorizationIssuer(advertisedIssuer)
        guard authorizationServer.issuer == normalizedIssuer.canonicalString else {
            throw MCPConnectionError.metadataIdentityMismatch
        }
        guard authorizationServer.responseTypesSupported.isEmpty
                || authorizationServer.responseTypesSupported.contains("code"),
              authorizationServer.grantTypesSupported.isEmpty
                || authorizationServer.grantTypesSupported.contains("authorization_code") else {
            throw MCPConnectionError.unsupportedOAuthFlow
        }
        guard authorizationServer.codeChallengeMethodsSupported.contains("S256") else {
            throw MCPConnectionError.unsupportedPKCE
        }
        if !authorizationServer.tokenEndpointAuthMethodsSupported.isEmpty,
           !authorizationServer.tokenEndpointAuthMethodsSupported.contains("none") {
            throw MCPConnectionError.unsupportedOAuthFlow
        }

        resourceEndpoint = endpoint
        issuer = normalizedIssuer
        self.protectedResource = protectedResource
        self.authorizationServer = authorizationServer
        authorizationURL = try Self.validatedNetworkURL(authorizationServer.authorizationEndpoint)
        tokenURL = try Self.validatedNetworkURL(authorizationServer.tokenEndpoint)
        revocationURL = try authorizationServer.revocationEndpoint.map(Self.validatedNetworkURL)
        registrationURL = try authorizationServer.registrationEndpoint.map(Self.validatedNetworkURL)
    }

    private static func validatedNetworkURL(_ rawValue: String) throws -> URL {
        try MCPEndpoint(rawValue).url
    }
}

nonisolated struct MCPPublicOAuthClient: Codable, Equatable, Sendable {
    let clientID: String
    let redirectURI: URL

    init(clientID: String, redirectURI: URL) throws {
        guard !clientID.isEmpty,
              let scheme = redirectURI.scheme?.lowercased(),
              redirectURI.fragment == nil,
              redirectURI.user == nil,
              redirectURI.password == nil else {
            throw MCPConnectionError.invalidRedirectURI
        }
        let secure = scheme == "https"
        let loopback = scheme == "http"
            && redirectURI.host.map { MCPEndpoint.loopbackHost($0.lowercased()) } == true
        guard secure || loopback else { throw MCPConnectionError.invalidRedirectURI }
        self.clientID = clientID
        self.redirectURI = redirectURI
    }
}

/// Secret values intentionally do not conform to Codable and always redact
/// their textual representation. Concrete vault adapters may place them in
/// Keychain, but settings/run records can only persist public authorization
/// state.
nonisolated struct MCPSecret: Equatable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    fileprivate let storage: String

    init(_ value: String) { storage = value }
    var description: String { "<redacted>" }
    var debugDescription: String { "<redacted>" }
    var isEmpty: Bool { storage.isEmpty }

    /// Gives credential adapters narrowly scoped access to the underlying
    /// value without making secrets Codable or renderable. Callers must keep
    /// the value inside a protected credential boundary such as Keychain.
    func withUnsafeStorage<Result>(_ body: (String) throws -> Result) rethrows -> Result {
        try body(storage)
    }
}

nonisolated struct MCPAuthorizationCode: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    fileprivate let storage: String

    fileprivate init(_ value: String) { storage = value }
    var description: String { "<redacted authorization code>" }
    var debugDescription: String { description }
}

nonisolated enum MCPAuthorizationStatus: String, Codable, Equatable, Sendable {
    case authorizationRequired
    case authorized
    case revoked
}

nonisolated struct MCPOAuthPublicState: Codable, Equatable, Sendable {
    var discovery: MCPOAuthDiscovery
    var client: MCPPublicOAuthClient
    var status: MCPAuthorizationStatus
    var effectiveScopes: [String]
    var accessTokenExpiresAt: Date?

    init(
        discovery: MCPOAuthDiscovery,
        client: MCPPublicOAuthClient,
        status: MCPAuthorizationStatus,
        effectiveScopes: [String],
        accessTokenExpiresAt: Date?
    ) {
        self.discovery = discovery
        self.client = client
        self.status = status
        self.effectiveScopes = Array(Set(effectiveScopes)).sorted()
        self.accessTokenExpiresAt = accessTokenExpiresAt
    }
}

nonisolated enum MCPAuthorizationState: Codable, Equatable, Sendable {
    case none
    case bearer
    case oauth(MCPOAuthPublicState)

    var status: MCPAuthorizationStatus {
        switch self {
        case .none, .bearer: .authorized
        case .oauth(let state): state.status
        }
    }

    var effectiveScopes: [String] {
        guard case .oauth(let state) = self else { return [] }
        return state.effectiveScopes
    }
}

nonisolated struct MCPOAuthPendingAuthorization: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let id: UUID
    let connectionID: UUID
    let discovery: MCPOAuthDiscovery
    let client: MCPPublicOAuthClient
    let requestedScopes: [String]
    let authorizationURL: URL
    let state: String
    let nonce: String
    let codeChallenge: String
    let createdAt: Date
    fileprivate let verifierReference: UUID

    var description: String {
        "MCPOAuthPendingAuthorization(id: \(id), connectionID: \(connectionID), secrets: <redacted>)"
    }
    var debugDescription: String { description }
}

nonisolated protocol MCPOAuthEntropySource: Sendable {
    func randomBytes(count: Int) -> Data
}

nonisolated struct MCPSystemOAuthEntropy: MCPOAuthEntropySource {
    func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

// MARK: - Secret vault and token lifecycle

nonisolated struct MCPTokenBundle: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let accessToken: MCPSecret
    let refreshToken: MCPSecret?
    let tokenType: String
    let expiresAt: Date?
    let scopes: [String]

    init(
        accessToken: MCPSecret,
        refreshToken: MCPSecret?,
        tokenType: String,
        expiresAt: Date?,
        scopes: [String]
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresAt = expiresAt
        self.scopes = Array(Set(scopes)).sorted()
    }

    var description: String { "MCPTokenBundle(<redacted>)" }
    var debugDescription: String { description }
}

nonisolated protocol MCPSecretVault: Sendable {
    func bearerToken(for connectionID: UUID) async throws -> MCPSecret?
    func storeBearerToken(_ token: MCPSecret, for connectionID: UUID) async throws
    func oauthTokens(for connectionID: UUID) async throws -> MCPTokenBundle?
    func storeOAuthTokens(_ tokens: MCPTokenBundle, for connectionID: UUID) async throws
    func transientSecret(for reference: UUID) async throws -> MCPSecret?
    func storeTransientSecret(_ secret: MCPSecret, for reference: UUID, connectionID: UUID) async throws
    func removeTransientSecret(for reference: UUID) async throws
    func removeAllSecrets(for connectionID: UUID) async throws
}

actor MCPInMemorySecretVault: MCPSecretVault {
    private var bearerTokens: [UUID: MCPSecret] = [:]
    private var oauthTokenSets: [UUID: MCPTokenBundle] = [:]
    private var transientSecrets: [UUID: (connectionID: UUID, secret: MCPSecret)] = [:]

    func bearerToken(for connectionID: UUID) -> MCPSecret? { bearerTokens[connectionID] }
    func storeBearerToken(_ token: MCPSecret, for connectionID: UUID) {
        bearerTokens[connectionID] = token
    }
    func oauthTokens(for connectionID: UUID) -> MCPTokenBundle? { oauthTokenSets[connectionID] }
    func storeOAuthTokens(_ tokens: MCPTokenBundle, for connectionID: UUID) {
        oauthTokenSets[connectionID] = tokens
    }
    func transientSecret(for reference: UUID) -> MCPSecret? { transientSecrets[reference]?.secret }
    func storeTransientSecret(_ secret: MCPSecret, for reference: UUID, connectionID: UUID) {
        transientSecrets[reference] = (connectionID, secret)
    }
    func removeTransientSecret(for reference: UUID) { transientSecrets[reference] = nil }
    func removeAllSecrets(for connectionID: UUID) {
        bearerTokens[connectionID] = nil
        oauthTokenSets[connectionID] = nil
        transientSecrets = transientSecrets.filter { $0.value.connectionID != connectionID }
    }
    func hasOAuthTokens(for connectionID: UUID) -> Bool { oauthTokenSets[connectionID] != nil }
}

nonisolated struct MCPAuthorizationCodeExchange: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let code: MCPAuthorizationCode
    let codeVerifier: MCPSecret
    let discovery: MCPOAuthDiscovery
    let client: MCPPublicOAuthClient
    let requestedScopes: [String]

    var description: String { "MCPAuthorizationCodeExchange(<redacted>)" }
    var debugDescription: String { description }
}

nonisolated struct MCPTokenRefreshRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let refreshToken: MCPSecret
    let priorAccessToken: MCPSecret
    let discovery: MCPOAuthDiscovery
    let client: MCPPublicOAuthClient
    let requestedScopes: [String]

    var description: String { "MCPTokenRefreshRequest(<redacted>)" }
    var debugDescription: String { description }
}

nonisolated struct MCPTokenRevocationRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let token: MCPSecret
    let discovery: MCPOAuthDiscovery
    let client: MCPPublicOAuthClient

    var description: String { "MCPTokenRevocationRequest(<redacted>)" }
    var debugDescription: String { description }
}

nonisolated protocol MCPOAuthTokenExchanging: Sendable {
    func exchangeAuthorizationCode(_ request: MCPAuthorizationCodeExchange) async throws -> MCPTokenBundle
    func refresh(_ request: MCPTokenRefreshRequest) async throws -> MCPTokenBundle
    func revoke(_ request: MCPTokenRevocationRequest) async throws
}

nonisolated struct MCPAccessGrant: Equatable, Sendable, CustomStringConvertible {
    let token: MCPSecret
    let effectiveScopes: [String]
    let expiresAt: Date?

    var description: String { "MCPAccessGrant(<redacted>)" }
}

actor MCPTokenManager {
    private let vault: any MCPSecretVault
    private let oauthClient: any MCPOAuthTokenExchanging
    private let now: @Sendable () -> Date
    private let refreshLeeway: TimeInterval
    private var refreshTasks: [UUID: Task<MCPTokenBundle, Error>] = [:]

    init(
        vault: any MCPSecretVault,
        oauthClient: any MCPOAuthTokenExchanging,
        now: @escaping @Sendable () -> Date = Date.init,
        refreshLeeway: TimeInterval = 30
    ) {
        self.vault = vault
        self.oauthClient = oauthClient
        self.now = now
        self.refreshLeeway = refreshLeeway
    }

    func accessToken(connectionID: UUID, authorization: MCPOAuthPublicState) async throws -> MCPSecret {
        try await accessGrant(connectionID: connectionID, authorization: authorization).token
    }

    func accessGrant(connectionID: UUID, authorization: MCPOAuthPublicState) async throws -> MCPAccessGrant {
        guard authorization.status == .authorized else { throw MCPConnectionError.connectionRevoked }
        guard let tokens = try await vault.oauthTokens(for: connectionID) else {
            throw MCPConnectionError.missingCredentials
        }
        if let expiry = tokens.expiresAt, expiry <= now().addingTimeInterval(refreshLeeway) {
            let refreshed = try await refreshSingleFlight(
                connectionID: connectionID,
                authorization: authorization,
                tokens: tokens
            )
            return MCPAccessGrant(
                token: refreshed.accessToken,
                effectiveScopes: refreshed.scopes,
                expiresAt: refreshed.expiresAt
            )
        }
        return MCPAccessGrant(
            token: tokens.accessToken,
            effectiveScopes: tokens.scopes,
            expiresAt: tokens.expiresAt
        )
    }

    func refreshAfterUnauthorized(
        connectionID: UUID,
        authorization: MCPOAuthPublicState,
        rejectedAccessToken: MCPSecret
    ) async throws -> MCPSecret {
        try await refreshGrantAfterUnauthorized(
            connectionID: connectionID,
            authorization: authorization,
            rejectedAccessToken: rejectedAccessToken
        ).token
    }

    func refreshGrantAfterUnauthorized(
        connectionID: UUID,
        authorization: MCPOAuthPublicState,
        rejectedAccessToken: MCPSecret
    ) async throws -> MCPAccessGrant {
        guard let current = try await vault.oauthTokens(for: connectionID) else {
            throw MCPConnectionError.missingCredentials
        }
        let refreshed: MCPTokenBundle
        if current.accessToken != rejectedAccessToken {
            refreshed = current
        } else {
            refreshed = try await refreshSingleFlight(
            connectionID: connectionID,
            authorization: authorization,
            tokens: current
            )
        }
        return MCPAccessGrant(
            token: refreshed.accessToken,
            effectiveScopes: refreshed.scopes,
            expiresAt: refreshed.expiresAt
        )
    }

    private func refreshSingleFlight(
        connectionID: UUID,
        authorization: MCPOAuthPublicState,
        tokens: MCPTokenBundle
    ) async throws -> MCPTokenBundle {
        if let active = refreshTasks[connectionID] { return try await active.value }
        guard let refreshToken = tokens.refreshToken else { throw MCPConnectionError.missingRefreshToken }

        let vault = self.vault
        let oauthClient = self.oauthClient
        let task = Task<MCPTokenBundle, Error> {
            let refreshed = try await oauthClient.refresh(MCPTokenRefreshRequest(
                refreshToken: refreshToken,
                priorAccessToken: tokens.accessToken,
                discovery: authorization.discovery,
                client: authorization.client,
                requestedScopes: authorization.effectiveScopes
            ))
            let retainedRefresh = MCPTokenBundle(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken ?? refreshToken,
                tokenType: refreshed.tokenType,
                expiresAt: refreshed.expiresAt,
                scopes: refreshed.scopes.isEmpty ? authorization.effectiveScopes : refreshed.scopes
            )
            try await vault.storeOAuthTokens(retainedRefresh, for: connectionID)
            return retainedRefresh
        }
        refreshTasks[connectionID] = task
        do {
            let result = try await task.value
            refreshTasks[connectionID] = nil
            return result
        } catch {
            refreshTasks[connectionID] = nil
            throw error
        }
    }
}

// MARK: - Server identity, negotiated capabilities, and trust versions

nonisolated struct MCPServerIdentity: Codable, Equatable, Hashable, Sendable {
    var name: String
    var version: String
    var title: String?

    init(name: String, version: String, title: String? = nil) {
        self.name = name
        self.version = version
        self.title = title
    }
}

nonisolated struct MCPListCapability: Codable, Equatable, Sendable {
    var listChanged: Bool
    var subscribe: Bool

    init(listChanged: Bool = false, subscribe: Bool = false) {
        self.listChanged = listChanged
        self.subscribe = subscribe
    }
}

nonisolated struct MCPServerCapabilities: Codable, Equatable, Sendable {
    var tools: MCPListCapability?
    var resources: MCPListCapability?
    var prompts: MCPListCapability?
    var logging: Bool
    var completions: Bool
    var experimentalKeys: [String]
    var metadataDigest: String

    init(
        tools: MCPListCapability? = nil,
        resources: MCPListCapability? = nil,
        prompts: MCPListCapability? = nil,
        logging: Bool = false,
        completions: Bool = false,
        experimentalKeys: [String] = [],
        metadataDigest: String? = nil
    ) {
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
        self.logging = logging
        self.completions = completions
        self.experimentalKeys = Array(Set(experimentalKeys)).sorted()
        self.metadataDigest = metadataDigest ?? mcpSHA256Hex([
            String(tools != nil),
            String(resources != nil),
            String(prompts != nil),
            String(logging),
            String(completions),
            self.experimentalKeys.joined(separator: "\u{0}"),
        ])
    }

    fileprivate init(json: MCPJSONValue) {
        let object = json.objectValue ?? [:]
        func listCapability(_ key: String) -> MCPListCapability? {
            guard let value = object[key]?.objectValue else { return nil }
            return MCPListCapability(
                listChanged: value["listChanged"]?.boolValue ?? false,
                subscribe: value["subscribe"]?.boolValue ?? false
            )
        }
        tools = listCapability("tools")
        resources = listCapability("resources")
        prompts = listCapability("prompts")
        logging = object["logging"] != nil
        completions = object["completions"] != nil
        experimentalKeys = object["experimental"]?.objectValue?.keys.sorted() ?? []
        metadataDigest = mcpCanonicalDigest(json)
    }
}

nonisolated struct MCPNegotiatedConnection: Codable, Equatable, Sendable {
    var protocolVersion: String
    var capabilities: MCPServerCapabilities
    var hasSession: Bool
    var connectedAt: Date
    var toolCount: Int
}

nonisolated enum MCPTrustStatus: String, Codable, Equatable, Sendable {
    case needsReview
    case trusted
    case revoked
}

nonisolated enum MCPTrustDimension: String, Codable, CaseIterable, Hashable, Sendable {
    case endpoint
    case serverIdentity
    case protocolVersion
    case capabilities
    case toolSchema
    case authorizationScopes
    case authorization
}

nonisolated struct MCPTrustSnapshot: Codable, Equatable, Sendable {
    var endpoint: String
    var serverIdentityDigest: String
    var protocolVersion: String
    var capabilitiesDigest: String
    var toolSchemaDigest: String
    var scopeDigest: String

    var digest: String {
        mcpSHA256Hex([
            endpoint,
            serverIdentityDigest,
            protocolVersion,
            capabilitiesDigest,
            toolSchemaDigest,
            scopeDigest,
        ])
    }

    func changedDimensions(comparedTo other: MCPTrustSnapshot) -> Set<MCPTrustDimension> {
        var changes = Set<MCPTrustDimension>()
        if endpoint != other.endpoint { changes.insert(.endpoint) }
        if serverIdentityDigest != other.serverIdentityDigest { changes.insert(.serverIdentity) }
        if protocolVersion != other.protocolVersion { changes.insert(.protocolVersion) }
        if capabilitiesDigest != other.capabilitiesDigest { changes.insert(.capabilities) }
        if toolSchemaDigest != other.toolSchemaDigest { changes.insert(.toolSchema) }
        if scopeDigest != other.scopeDigest { changes.insert(.authorizationScopes) }
        return changes
    }
}

nonisolated struct MCPTrustRecord: Codable, Equatable, Sendable {
    var generation: UInt64
    var status: MCPTrustStatus
    var snapshot: MCPTrustSnapshot
    var changedDimensions: Set<MCPTrustDimension>
    var reviewedAt: Date?

    var binding: String { "mcp-trust-v\(generation)-\(snapshot.digest)" }

    fileprivate static func reconcile(
        previous: MCPTrustRecord?,
        snapshot: MCPTrustSnapshot
    ) -> MCPTrustRecord {
        guard let previous else {
            return MCPTrustRecord(
                generation: 1,
                status: .needsReview,
                snapshot: snapshot,
                changedDimensions: Set(MCPTrustDimension.allCases.filter { $0 != .authorization }),
                reviewedAt: nil
            )
        }
        let changes = snapshot.changedDimensions(comparedTo: previous.snapshot)
        guard !changes.isEmpty else { return previous }
        return MCPTrustRecord(
            generation: previous.generation + 1,
            status: .needsReview,
            snapshot: snapshot,
            changedDimensions: changes,
            reviewedAt: nil
        )
    }

    fileprivate func invalidating(_ dimension: MCPTrustDimension) -> MCPTrustRecord {
        var updated = self
        updated.generation += 1
        updated.status = .needsReview
        updated.changedDimensions = [dimension]
        updated.reviewedAt = nil
        return updated
    }
}

nonisolated struct MCPConnectionTestResult: Codable, Equatable, Sendable {
    var testedAt: Date
    var succeeded: Bool
    var failureCode: String?
}

nonisolated struct MCPConnection: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    var endpoint: MCPEndpoint
    var enabled: Bool
    var serverIdentity: MCPServerIdentity?
    var negotiation: MCPNegotiatedConnection?
    var toolSchemaDigest: String?
    var authorization: MCPAuthorizationState
    var trust: MCPTrustRecord?
    var lastTest: MCPConnectionTestResult?

    init(
        id: UUID = UUID(),
        displayName: String,
        endpoint: MCPEndpoint,
        enabled: Bool = true,
        authorization: MCPAuthorizationState = .none
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.enabled = enabled
        self.authorization = authorization
    }

    mutating func approveCurrentTrust(at date: Date = Date()) {
        guard var trust else { return }
        trust.status = .trusted
        trust.changedDimensions = []
        trust.reviewedAt = date
        self.trust = trust
    }

    mutating func retarget(to endpoint: MCPEndpoint) {
        guard self.endpoint != endpoint else { return }
        self.endpoint = endpoint
        serverIdentity = nil
        negotiation = nil
        toolSchemaDigest = nil
        if var trust {
            trust.snapshot.endpoint = endpoint.canonicalString
            self.trust = trust.invalidating(.endpoint)
        }
    }
}

// MARK: - Tool schemas and collision-safe model names

nonisolated struct MCPRemoteTool: Codable, Equatable, Sendable {
    var name: String
    var title: String?
    var description: String
    var inputSchema: MCPJSONValue
    var outputSchema: MCPJSONValue?

    init(
        name: String,
        title: String? = nil,
        description: String,
        inputSchema: MCPJSONValue,
        outputSchema: MCPJSONValue? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }
}

nonisolated struct MCPExposedTool: Codable, Equatable, Sendable {
    var exposedName: String
    var originalName: String
    var connectionID: UUID
    var serverIdentity: MCPServerIdentity
    var description: String
    var inputSchema: MCPJSONValue
    var outputSchema: MCPJSONValue?
    var schemaDigest: String
}

nonisolated enum MCPToolNamespace {
    static func expose<S: Sequence>(
        tools: S,
        connectionID: UUID,
        reservedNames: Set<String> = []
    ) throws -> [MCPExposedTool] where S.Element == MCPRemoteTool {
        let ordered = Array(tools).sorted { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.description < rhs.description
        }
        guard Set(ordered.map(\.name)).count == ordered.count else {
            throw MCPConnectionError.duplicateToolName
        }

        let connectionHash = String(mcpSHA256Hex([connectionID.uuidString]).prefix(10))
        var used = reservedNames
        var exposed: [MCPExposedTool] = []
        for tool in ordered {
            let sanitized = sanitize(tool.name)
            let toolHash = mcpSHA256Hex([connectionID.uuidString, tool.name])
            var ordinal = 0
            var candidate: String
            repeat {
                let prefix = "mcp_\(connectionHash)_"
                let suffix = String(mcpSHA256Hex([
                    toolHash,
                    String(ordinal),
                ]).prefix(16))
                let budget = max(1, 64 - prefix.count - suffix.count - 1)
                candidate = prefix + String(sanitized.prefix(budget)) + "_" + suffix
                ordinal += 1
            } while used.contains(candidate)
            used.insert(candidate)
            exposed.append(MCPExposedTool(
                exposedName: candidate,
                originalName: tool.name,
                connectionID: connectionID,
                serverIdentity: MCPServerIdentity(name: "Pending", version: ""),
                description: tool.description,
                inputSchema: tool.inputSchema,
                outputSchema: tool.outputSchema,
                schemaDigest: schemaDigest(tool)
            ))
        }
        return exposed
    }

    fileprivate static func bind(
        tools: [MCPRemoteTool],
        connectionID: UUID,
        serverIdentity: MCPServerIdentity,
        reservedNames: Set<String>
    ) throws -> [MCPExposedTool] {
        try expose(tools: tools, connectionID: connectionID, reservedNames: reservedNames).map { exposed in
            var bound = exposed
            bound.serverIdentity = serverIdentity
            return bound
        }
    }

    private static func sanitize(_ name: String) -> String {
        let mapped = name.unicodeScalars.map { scalar -> Character in
            let asciiAlphaNumeric = scalar.isASCII
                && ((65...90).contains(Int(scalar.value))
                    || (97...122).contains(Int(scalar.value))
                    || (48...57).contains(Int(scalar.value)))
            return asciiAlphaNumeric || scalar == "_" ? Character(String(scalar)) : "_"
        }
        let value = String(mapped)
        return value.isEmpty ? "tool" : value
    }

    fileprivate static func schemaDigest(_ tool: MCPRemoteTool) -> String {
        let data = (try? JSONEncoder.mcpCanonical.encode(tool)) ?? Data()
        return mcpSHA256Hex([data.base64EncodedString()])
    }
}

// MARK: - Bounded, redacted transport

nonisolated struct MCPTransportLimits: Codable, Equatable, Sendable {
    var maxResponseBytes: Int
    var maxRequestBytes: Int
    var maxJSONDepth: Int
    var timeoutMilliseconds: Int
    var maxTools: Int
    var maxToolNameBytes: Int
    var maxDescriptionBytes: Int

    init(
        maxResponseBytes: Int = 8 * 1_024 * 1_024,
        maxRequestBytes: Int = 4 * 1_024 * 1_024,
        maxJSONDepth: Int = 64,
        timeoutMilliseconds: Int = 45_000,
        maxTools: Int = 512,
        maxToolNameBytes: Int = 128,
        maxDescriptionBytes: Int = 4_096
    ) {
        self.maxResponseBytes = max(1, maxResponseBytes)
        self.maxRequestBytes = max(1, maxRequestBytes)
        self.maxJSONDepth = max(1, maxJSONDepth)
        self.timeoutMilliseconds = max(1, timeoutMilliseconds)
        self.maxTools = max(1, maxTools)
        self.maxToolNameBytes = max(1, maxToolNameBytes)
        self.maxDescriptionBytes = max(1, maxDescriptionBytes)
    }
}

nonisolated enum MCPHTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case delete = "DELETE"
}

nonisolated struct MCPTransportRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let url: URL
    let method: MCPHTTPMethod
    let headers: [String: String]
    let body: Data?
    let timeoutMilliseconds: Int

    init(
        url: URL,
        method: MCPHTTPMethod,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeoutMilliseconds: Int
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    var description: String {
        let renderedHeaders = headers.keys.sorted().map { key in
            let sensitive = key.caseInsensitiveCompare("Authorization") == .orderedSame
                || key.caseInsensitiveCompare("Cookie") == .orderedSame
                || key.caseInsensitiveCompare("Mcp-Session-Id") == .orderedSame
            return "\(key)=\(sensitive ? "<redacted>" : "<set>")"
        }.joined(separator: ",")
        return "MCPTransportRequest(method: \(method.rawValue), origin: \(url.mcpOrigin), headers: [\(renderedHeaders)], body: <\(body?.count ?? 0) bytes>)"
    }
    var debugDescription: String { description }
}

nonisolated struct MCPTransportResponse: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
    let finalURL: URL?

    init(statusCode: Int, headers: [String: String], body: Data, finalURL: URL? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.finalURL = finalURL
    }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var description: String {
        "MCPTransportResponse(status: \(statusCode), headers: \(headers.keys.sorted()), body: <\(body.count) bytes>)"
    }
    var debugDescription: String { description }
}

nonisolated protocol MCPTransport: Sendable {
    func send(_ request: MCPTransportRequest) async throws -> MCPTransportResponse
}

nonisolated final class URLSessionMCPTransport: MCPTransport, @unchecked Sendable {
    private let session: URLSession
    private let redirectDelegate: MCPRedirectRejectingDelegate

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        let delegate = MCPRedirectRejectingDelegate()
        redirectDelegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    init(configuration: URLSessionConfiguration) {
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let delegate = MCPRedirectRejectingDelegate()
        redirectDelegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func send(_ request: MCPTransportRequest) async throws -> MCPTransportResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = TimeInterval(request.timeoutMilliseconds) / 1_000
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw MCPConnectionError.transportFailure
            }
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                guard let name = pair.key as? String else { return }
                result[name] = String(describing: pair.value)
            }
            return MCPTransportResponse(
                statusCode: http.statusCode,
                headers: headers,
                body: data,
                finalURL: http.url
            )
        } catch let error as MCPConnectionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MCPConnectionError.transportFailure
        }
    }
}

private nonisolated final class MCPRedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

nonisolated struct MCPBoundedTransport: Sendable {
    let transport: any MCPTransport
    let limits: MCPTransportLimits

    func send(_ request: MCPTransportRequest) async throws -> MCPTransportResponse {
        let response: MCPTransportResponse
        do {
            response = try await withThrowingTaskGroup(of: MCPTransportResponse.self) { group in
                group.addTask { try await transport.send(request) }
                group.addTask {
                    try await Task.sleep(for: .milliseconds(limits.timeoutMilliseconds))
                    throw MCPConnectionError.timeout(milliseconds: limits.timeoutMilliseconds)
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw MCPConnectionError.transportFailure }
                return first
            }
        } catch let error as MCPConnectionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MCPConnectionError.transportFailure
        }
        guard response.body.count <= limits.maxResponseBytes else {
            throw MCPConnectionError.responseTooLarge(limit: limits.maxResponseBytes)
        }
        if let finalURL = response.finalURL, finalURL.absoluteString != request.url.absoluteString {
            throw MCPConnectionError.endpointRedirected
        }
        return response
    }

    func json(from response: MCPTransportResponse) throws -> MCPJSONValue {
        let payload: Data
        if response.header("Content-Type")?.lowercased().contains("text/event-stream") == true {
            payload = try lastSSEPayload(response.body)
        } else {
            payload = response.body
        }
        guard !payload.isEmpty,
              let foundation = try? JSONSerialization.jsonObject(with: payload),
              let value = try? MCPJSONValue(foundationValue: foundation) else {
            throw MCPConnectionError.malformedResponse
        }
        guard value.depth <= limits.maxJSONDepth else {
            throw MCPConnectionError.responseTooDeep(limit: limits.maxJSONDepth)
        }
        return value
    }

    private func lastSSEPayload(_ data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPConnectionError.malformedResponse
        }
        var candidates: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("data:") else { continue }
            candidates.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
        guard let candidate = candidates.last, let data = candidate.data(using: .utf8) else {
            throw MCPConnectionError.malformedResponse
        }
        return data
    }
}

nonisolated enum MCPInvocationSafety: Codable, Equatable, Sendable {
    case readOnly
    case mutation(idempotencyKey: String?)

    var allowsAuthenticationRetry: Bool {
        switch self {
        case .readOnly: true
        case .mutation(let idempotencyKey): !(idempotencyKey?.isEmpty ?? true)
        }
    }

    var idempotencyKey: String? {
        guard case .mutation(let key) = self else { return nil }
        return key
    }
}

nonisolated struct MCPToolCallResult: Equatable, Sendable {
    var value: MCPJSONValue
    var isError: Bool
}

/// Secret-free identity passed into policy decisions and replay records.
/// `dataLeavesDevice` is intentionally explicit: every remote MCP tool call is
/// an egress boundary even when the tool is described as read-only.
nonisolated struct MCPToolPolicyIdentity: Codable, Equatable, Sendable {
    var connectionID: UUID
    var normalizedEndpoint: String
    var serverIdentity: MCPServerIdentity
    var protocolVersion: String
    var exposedToolName: String
    var originalToolName: String
    var toolSchemaDigest: String
    var effectiveScopes: [String]
    var trustBinding: String
    var dataLeavesDevice: Bool
}

nonisolated enum MCPRemoteRevocationStatus: String, Equatable, Sendable {
    case notAvailable
    case succeeded
    case failed
}

nonisolated struct MCPRevocationResult: Equatable, Sendable {
    var connection: MCPConnection
    var remoteRevocation: MCPRemoteRevocationStatus
}

// MARK: - Standards discovery and OAuth token HTTP client

nonisolated struct MCPAuthorizationDiscoveryInput: Equatable, Sendable {
    let resourceEndpoint: MCPEndpoint
    let protectedResourceMetadataURL: URL

    init(resourceEndpoint: MCPEndpoint, wwwAuthenticate: String? = nil) throws {
        self.resourceEndpoint = resourceEndpoint
        if let wwwAuthenticate,
           let advertised = Self.quotedParameter("resource_metadata", in: wwwAuthenticate) {
            protectedResourceMetadataURL = try MCPEndpoint(advertised).url
        } else {
            protectedResourceMetadataURL = resourceEndpoint.protectedResourceMetadataURL
        }
    }

    private static func quotedParameter(_ name: String, in header: String) -> String? {
        let lowered = header.lowercased()
        guard let range = lowered.range(of: "\(name.lowercased())=") else { return nil }
        let suffix = header[range.upperBound...].drop(while: { $0.isWhitespace })
        guard suffix.first == "\"" else { return nil }
        var escaped = false
        var result = ""
        for character in suffix.dropFirst() {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return result
            } else {
                result.append(character)
            }
        }
        return nil
    }
}

/// Production OAuth form exchange over the injected transport. Bodies are
/// intentionally absent from descriptions and errors because they contain
/// authorization codes, verifiers, and refresh tokens.
actor MCPHTTPTokenClient: MCPOAuthTokenExchanging {
    private let wire: MCPBoundedTransport
    private let now: @Sendable () -> Date

    init(
        transport: any MCPTransport,
        limits: MCPTransportLimits = MCPTransportLimits(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        wire = MCPBoundedTransport(transport: transport, limits: limits)
        self.now = now
    }

    func exchangeAuthorizationCode(_ request: MCPAuthorizationCodeExchange) async throws -> MCPTokenBundle {
        try await tokenRequest(
            url: request.discovery.tokenURL,
            parameters: [
                "grant_type": "authorization_code",
                "code": request.code.storage,
                "client_id": request.client.clientID,
                "redirect_uri": request.client.redirectURI.absoluteString,
                "code_verifier": request.codeVerifier.storage,
                "resource": request.discovery.resourceEndpoint.canonicalString,
            ],
            priorRefreshToken: nil,
            fallbackScopes: request.requestedScopes
        )
    }

    func refresh(_ request: MCPTokenRefreshRequest) async throws -> MCPTokenBundle {
        try await tokenRequest(
            url: request.discovery.tokenURL,
            parameters: [
                "grant_type": "refresh_token",
                "refresh_token": request.refreshToken.storage,
                "client_id": request.client.clientID,
                "resource": request.discovery.resourceEndpoint.canonicalString,
                "scope": request.requestedScopes.joined(separator: " "),
            ],
            priorRefreshToken: request.refreshToken,
            fallbackScopes: request.requestedScopes
        )
    }

    func revoke(_ request: MCPTokenRevocationRequest) async throws {
        guard let url = request.discovery.revocationURL else { return }
        let response = try await wire.send(MCPTransportRequest(
            url: url,
            method: .post,
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded",
            ],
            body: Self.formBody([
                "token": request.token.storage,
                "client_id": request.client.clientID,
            ]),
            timeoutMilliseconds: wire.limits.timeoutMilliseconds
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw MCPConnectionError.transportFailure
        }
    }

    private func tokenRequest(
        url: URL,
        parameters: [String: String],
        priorRefreshToken: MCPSecret?,
        fallbackScopes: [String]
    ) async throws -> MCPTokenBundle {
        let response = try await wire.send(MCPTransportRequest(
            url: url,
            method: .post,
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded",
            ],
            body: Self.formBody(parameters),
            timeoutMilliseconds: wire.limits.timeoutMilliseconds
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw response.statusCode == 401
                ? MCPConnectionError.unauthorized(retrySuppressed: false)
                : MCPConnectionError.transportFailure
        }
        guard let object = try wire.json(from: response).objectValue,
              let accessToken = object["access_token"]?.stringValue,
              !accessToken.isEmpty else {
            throw MCPConnectionError.malformedResponse
        }
        let tokenType = object["token_type"]?.stringValue ?? "Bearer"
        guard tokenType.caseInsensitiveCompare("Bearer") == .orderedSame else {
            throw MCPConnectionError.malformedResponse
        }
        let refreshToken = object["refresh_token"]?.stringValue.map(MCPSecret.init) ?? priorRefreshToken
        let expiresAt = object["expires_in"].flatMap { value -> Date? in
            guard case .number(let seconds) = value, seconds.isFinite, seconds >= 0 else { return nil }
            return now().addingTimeInterval(seconds)
        }
        let scopes = object["scope"]?.stringValue?
            .split(whereSeparator: \.isWhitespace)
            .map(String.init) ?? fallbackScopes
        return MCPTokenBundle(
            accessToken: MCPSecret(accessToken),
            refreshToken: refreshToken,
            tokenType: tokenType,
            expiresAt: expiresAt,
            scopes: scopes
        )
    }

    private static func formBody(_ values: [String: String]) -> Data {
        let rendered = values
            .filter { !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { "\(formEncode($0.key))=\(formEncode($0.value))" }
            .joined(separator: "&")
        return Data(rendered.utf8)
    }

    private static func formEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

// MARK: - Connection and invocation lifecycle

actor MCPConnectionLifecycle {
    private struct Runtime: Sendable {
        var endpoint: MCPEndpoint
        var sessionID: MCPSecret?
        var serverIdentity: MCPServerIdentity
        var negotiation: MCPNegotiatedConnection
        var tools: [MCPExposedTool]
        var trustSnapshot: MCPTrustSnapshot
    }

    private struct Authentication: Sendable {
        var header: String?
        var accessToken: MCPSecret?
        var oauthState: MCPOAuthPublicState?
    }

    private let wire: MCPBoundedTransport
    private let vault: any MCPSecretVault
    private let oauthClient: any MCPOAuthTokenExchanging
    private let entropy: any MCPOAuthEntropySource
    private let now: @Sendable () -> Date
    private let supportedProtocolVersions: Set<String>
    private let preferredProtocolVersion: String
    private let reservedToolNames: Set<String>
    private let tokenManager: MCPTokenManager
    private var runtimes: [UUID: Runtime] = [:]
    private var revokedConnections = Set<UUID>()

    init(
        transport: any MCPTransport,
        vault: any MCPSecretVault,
        oauthClient: any MCPOAuthTokenExchanging,
        entropy: any MCPOAuthEntropySource = MCPSystemOAuthEntropy(),
        now: @escaping @Sendable () -> Date = Date.init,
        limits: MCPTransportLimits = MCPTransportLimits(),
        supportedProtocolVersions: Set<String> = ["2025-06-18"],
        preferredProtocolVersion: String = "2025-06-18",
        reservedToolNames: Set<String> = []
    ) {
        self.wire = MCPBoundedTransport(transport: transport, limits: limits)
        self.vault = vault
        self.oauthClient = oauthClient
        self.entropy = entropy
        self.now = now
        self.supportedProtocolVersions = supportedProtocolVersions
        self.preferredProtocolVersion = preferredProtocolVersion
        self.reservedToolNames = reservedToolNames
        tokenManager = MCPTokenManager(vault: vault, oauthClient: oauthClient, now: now)
    }

    func discoverAuthorization(
        for connection: MCPConnection,
        wwwAuthenticate: String? = nil
    ) async throws -> MCPOAuthDiscovery {
        let input = try MCPAuthorizationDiscoveryInput(
            resourceEndpoint: connection.endpoint,
            wwwAuthenticate: wwwAuthenticate
        )
        let resourceResponse = try await wire.send(MCPTransportRequest(
            url: input.protectedResourceMetadataURL,
            method: .get,
            headers: ["Accept": "application/json"],
            timeoutMilliseconds: wire.limits.timeoutMilliseconds
        ))
        guard (200..<300).contains(resourceResponse.statusCode) else {
            throw MCPConnectionError.invalidDiscoveryMetadata
        }
        let protectedMetadata = try decode(
            MCPProtectedResourceMetadata.self,
            from: wire.json(from: resourceResponse)
        )
        guard protectedMetadata.resource == connection.endpoint.canonicalString,
              let issuerValue = protectedMetadata.authorizationServers.first else {
            throw MCPConnectionError.metadataIdentityMismatch
        }
        let issuer = try MCPAuthorizationIssuer(issuerValue)
        let authorizationResponse = try await wire.send(MCPTransportRequest(
            url: issuer.metadataURL,
            method: .get,
            headers: ["Accept": "application/json"],
            timeoutMilliseconds: wire.limits.timeoutMilliseconds
        ))
        guard (200..<300).contains(authorizationResponse.statusCode) else {
            throw MCPConnectionError.invalidDiscoveryMetadata
        }
        let authorizationMetadata = try decode(
            MCPAuthorizationServerMetadata.self,
            from: wire.json(from: authorizationResponse)
        )
        return try MCPOAuthDiscovery(
            protectedResource: protectedMetadata,
            authorizationServer: authorizationMetadata,
            endpoint: connection.endpoint
        )
    }

    func beginAuthorization(
        connection: MCPConnection,
        discovery: MCPOAuthDiscovery,
        client: MCPPublicOAuthClient,
        requestedScopes: [String]
    ) async throws -> MCPOAuthPendingAuthorization {
        guard discovery.resourceEndpoint == connection.endpoint else {
            throw MCPConnectionError.metadataIdentityMismatch
        }
        let scopes = Array(Set(requestedScopes)).sorted()
        try validate(scopes: scopes, discovery: discovery)

        let state = entropyValue(label: "state", bytes: 32)
        let nonce = entropyValue(label: "nonce", bytes: 32)
        let verifier = mcpBase64URL(entropy.randomBytes(count: 64))
        guard (43...128).contains(verifier.count) else { throw MCPConnectionError.unsupportedPKCE }
        let challenge = mcpBase64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let verifierReference = UUID()
        try await vault.storeTransientSecret(
            MCPSecret(verifier),
            for: verifierReference,
            connectionID: connection.id
        )

        var components = URLComponents(url: discovery.authorizationURL, resolvingAgainstBaseURL: false)
        var query = components?.queryItems ?? []
        query += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: client.redirectURI.absoluteString),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "resource", value: connection.endpoint.canonicalString),
        ]
        if !scopes.isEmpty { query.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " "))) }
        components?.queryItems = query
        guard let authorizationURL = components?.url else { throw MCPConnectionError.invalidDiscoveryMetadata }
        return MCPOAuthPendingAuthorization(
            id: UUID(),
            connectionID: connection.id,
            discovery: discovery,
            client: client,
            requestedScopes: scopes,
            authorizationURL: authorizationURL,
            state: state,
            nonce: nonce,
            codeChallenge: challenge,
            createdAt: now(),
            verifierReference: verifierReference
        )
    }

    func beginReauthorization(
        connection: MCPConnection,
        discovery: MCPOAuthDiscovery,
        client: MCPPublicOAuthClient,
        requestedScopes: [String]
    ) async throws -> (connection: MCPConnection, pending: MCPOAuthPendingAuthorization) {
        try await vault.removeAllSecrets(for: connection.id)
        runtimes[connection.id] = nil
        revokedConnections.insert(connection.id)
        var updated = connection
        updated.authorization = .oauth(MCPOAuthPublicState(
            discovery: discovery,
            client: client,
            status: .authorizationRequired,
            effectiveScopes: [],
            accessTokenExpiresAt: nil
        ))
        if let trust = updated.trust { updated.trust = trust.invalidating(.authorization) }
        let pending = try await beginAuthorization(
            connection: updated,
            discovery: discovery,
            client: client,
            requestedScopes: requestedScopes
        )
        return (updated, pending)
    }

    func completeAuthorization(
        connection: MCPConnection,
        pending: MCPOAuthPendingAuthorization,
        callbackURL: URL
    ) async throws -> MCPConnection {
        guard pending.connectionID == connection.id else {
            throw MCPConnectionError.authorizationStateMismatch
        }
        guard now().timeIntervalSince(pending.createdAt) <= 600 else {
            try await vault.removeTransientSecret(for: pending.verifierReference)
            throw MCPConnectionError.authorizationExpired
        }
        guard Self.sameRedirect(callbackURL, pending.client.redirectURI),
              let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
              let parameters = Self.uniqueQueryItems(items),
              parameters["state"] == pending.state else {
            try await vault.removeTransientSecret(for: pending.verifierReference)
            throw MCPConnectionError.authorizationStateMismatch
        }
        if parameters["error"] != nil {
            try await vault.removeTransientSecret(for: pending.verifierReference)
            throw MCPConnectionError.authorizationDenied
        }
        guard let codeValue = parameters["code"], !codeValue.isEmpty else {
            try await vault.removeTransientSecret(for: pending.verifierReference)
            throw MCPConnectionError.missingAuthorizationCode
        }
        guard let verifier = try await vault.transientSecret(for: pending.verifierReference) else {
            throw MCPConnectionError.authorizationExpired
        }
        try await vault.removeTransientSecret(for: pending.verifierReference)

        let bundle = try await oauthClient.exchangeAuthorizationCode(MCPAuthorizationCodeExchange(
            code: MCPAuthorizationCode(codeValue),
            codeVerifier: verifier,
            discovery: pending.discovery,
            client: pending.client,
            requestedScopes: pending.requestedScopes
        ))
        guard !bundle.accessToken.isEmpty else { throw MCPConnectionError.malformedResponse }
        try await vault.storeOAuthTokens(bundle, for: connection.id)
        revokedConnections.remove(connection.id)

        var updated = connection
        let oldAuthorization = connection.authorization
        let scopes = bundle.scopes.isEmpty ? pending.requestedScopes : bundle.scopes
        updated.authorization = .oauth(MCPOAuthPublicState(
            discovery: pending.discovery,
            client: pending.client,
            status: .authorized,
            effectiveScopes: scopes,
            accessTokenExpiresAt: bundle.expiresAt
        ))
        updateTrustForAuthorizationChange(
            connection: &updated,
            previous: oldAuthorization,
            replacement: updated.authorization
        )
        return updated
    }

    func configureBearerToken(_ token: MCPSecret, for connection: MCPConnection) async throws -> MCPConnection {
        try await vault.removeAllSecrets(for: connection.id)
        try await vault.storeBearerToken(token, for: connection.id)
        revokedConnections.remove(connection.id)
        runtimes[connection.id] = nil
        var updated = connection
        let previous = updated.authorization
        updated.authorization = .bearer
        updateTrustForAuthorizationChange(connection: &updated, previous: previous, replacement: .bearer)
        return updated
    }

    /// Answers only whether this device currently holds enough local
    /// authorization material to reconnect. This deliberately performs no
    /// network request and never exposes the credential itself.
    func hasLocalAuthorizationMaterial(for connection: MCPConnection) async -> Bool {
        guard !revokedConnections.contains(connection.id),
              connection.authorization.status == .authorized else {
            return false
        }
        switch connection.authorization {
        case .none:
            return true
        case .bearer:
            guard let token = try? await vault.bearerToken(for: connection.id) else {
                return false
            }
            return !token.isEmpty
        case .oauth(let state):
            guard let tokens = try? await vault.oauthTokens(for: connection.id),
                  !tokens.accessToken.isEmpty,
                  tokens.scopes.sorted() == state.effectiveScopes.sorted() else {
                return false
            }
            if let expiry = tokens.expiresAt, expiry <= now() {
                return tokens.refreshToken?.isEmpty == false
            }
            return true
        }
    }

    func connect(_ connection: MCPConnection) async throws -> MCPConnection {
        try ensureNotRevoked(connection)
        runtimes[connection.id] = nil
        let authentication = try await authentication(for: connection)
        let initialize = try await sendRPC(
            connection: connection,
            method: "initialize",
            params: .object([
                "protocolVersion": .string(preferredProtocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("Straight Up Browser"),
                    "version": .string(
                        Bundle.main.object(
                            forInfoDictionaryKey: "CFBundleShortVersionString"
                        ) as? String ?? "development"
                    ),
                ]),
            ]),
            sessionID: nil,
            authentication: authentication,
            notification: false
        )
        let initializeValue = try successfulRPCValue(initialize.response)
        guard let result = initializeValue.objectValue,
              let protocolVersion = result["protocolVersion"]?.stringValue else {
            throw MCPConnectionError.malformedResponse
        }
        guard supportedProtocolVersions.contains(protocolVersion) else {
            throw MCPConnectionError.unsupportedProtocol(protocolVersion)
        }
        guard let identityValue = result["serverInfo"]?.objectValue,
              let identityName = identityValue["name"]?.stringValue,
              let identityVersion = identityValue["version"]?.stringValue,
              !identityName.isEmpty, !identityVersion.isEmpty else {
            throw MCPConnectionError.malformedResponse
        }
        let sanitizedIdentityName = sanitizeMetadata(
            identityName,
            byteLimit: wire.limits.maxDescriptionBytes
        )
        let sanitizedIdentityVersion = sanitizeMetadata(identityVersion, byteLimit: 256)
        guard !sanitizedIdentityName.isEmpty, !sanitizedIdentityVersion.isEmpty else {
            throw MCPConnectionError.malformedResponse
        }
        let identity = MCPServerIdentity(
            name: sanitizedIdentityName,
            version: sanitizedIdentityVersion,
            title: identityValue["title"]?.stringValue.map {
                sanitizeMetadata($0, byteLimit: wire.limits.maxDescriptionBytes)
            }
        )
        let capabilities = MCPServerCapabilities(json: result["capabilities"] ?? .object([:]))
        guard capabilities.tools != nil else { throw MCPConnectionError.missingToolsCapability }
        let sessionID = try initialize.response.header("Mcp-Session-Id").map(validatedSessionID)
        let negotiation = MCPNegotiatedConnection(
            protocolVersion: protocolVersion,
            capabilities: capabilities,
            hasSession: sessionID != nil,
            connectedAt: now(),
            toolCount: 0
        )

        _ = try await sendRPC(
            connection: connection,
            method: "notifications/initialized",
            params: .object([:]),
            sessionID: sessionID,
            authentication: authentication,
            notification: true,
            protocolVersion: protocolVersion
        )
        let listed = try await sendRPC(
            connection: connection,
            method: "tools/list",
            params: .object([:]),
            sessionID: sessionID,
            authentication: authentication,
            notification: false,
            protocolVersion: protocolVersion
        )
        let tools = try parseTools(from: successfulRPCValue(listed.response))
        return try install(
            connection: connection,
            identity: identity,
            negotiation: negotiation,
            sessionID: sessionID,
            tools: tools
        )
    }

    func reconnect(_ connection: MCPConnection) async throws -> MCPConnection {
        runtimes[connection.id] = nil
        return try await connect(connection)
    }

    func disconnect(_ connection: MCPConnection) async {
        guard let runtime = runtimes.removeValue(forKey: connection.id),
              let sessionID = runtime.sessionID,
              let authentication = try? await authentication(for: connection) else { return }
        var headers = baseHeaders(protocolVersion: runtime.negotiation.protocolVersion)
        headers["Mcp-Session-Id"] = sessionID.storage
        if let header = authentication.header { headers["Authorization"] = header }
        _ = try? await wire.send(MCPTransportRequest(
            url: connection.endpoint.url,
            method: .delete,
            headers: headers,
            timeoutMilliseconds: wire.limits.timeoutMilliseconds
        ))
    }

    func tools(for connection: MCPConnection) -> [MCPExposedTool] {
        guard let runtime = runtimes[connection.id], runtime.endpoint == connection.endpoint else { return [] }
        return runtime.tools
    }

    func policyIdentity(
        for connection: MCPConnection,
        exposedToolName: String
    ) throws -> MCPToolPolicyIdentity {
        guard let runtime = runtimes[connection.id], runtime.endpoint == connection.endpoint,
              let trust = connection.trust,
              trust.status == .trusted,
              trust.snapshot == runtime.trustSnapshot else {
            throw MCPConnectionError.trustRequired
        }
        guard let tool = runtime.tools.first(where: { $0.exposedName == exposedToolName }) else {
            throw MCPConnectionError.unknownTool
        }
        return MCPToolPolicyIdentity(
            connectionID: connection.id,
            normalizedEndpoint: connection.endpoint.canonicalString,
            serverIdentity: runtime.serverIdentity,
            protocolVersion: runtime.negotiation.protocolVersion,
            exposedToolName: tool.exposedName,
            originalToolName: tool.originalName,
            toolSchemaDigest: tool.schemaDigest,
            effectiveScopes: connection.authorization.effectiveScopes,
            trustBinding: trust.binding,
            dataLeavesDevice: true
        )
    }

    func call(
        connection: MCPConnection,
        exposedToolName: String,
        arguments: MCPJSONValue,
        safety: MCPInvocationSafety
    ) async throws -> MCPToolCallResult {
        try ensureNotRevoked(connection)
        guard arguments.depth <= wire.limits.maxJSONDepth else {
            throw MCPConnectionError.responseTooDeep(limit: wire.limits.maxJSONDepth)
        }
        guard let runtime = runtimes[connection.id], runtime.endpoint == connection.endpoint,
              let trust = connection.trust,
              trust.status == .trusted,
              trust.snapshot == runtime.trustSnapshot else {
            throw MCPConnectionError.trustRequired
        }
        guard let tool = runtime.tools.first(where: { $0.exposedName == exposedToolName }) else {
            throw MCPConnectionError.unknownTool
        }
        var authentication = try await authentication(for: connection)
        try ensureNotRevoked(connection)
        var response = try await sendToolCall(
            connection: connection,
            runtime: runtime,
            tool: tool,
            arguments: arguments,
            safety: safety,
            authentication: authentication
        )
        if response.statusCode == 401 {
            guard safety.allowsAuthenticationRetry else {
                throw MCPConnectionError.unauthorized(retrySuppressed: true)
            }
            guard let oauthState = authentication.oauthState,
                  let rejectedToken = authentication.accessToken else {
                throw MCPConnectionError.unauthorized(retrySuppressed: false)
            }
            let refreshed = try await tokenManager.refreshGrantAfterUnauthorized(
                connectionID: connection.id,
                authorization: oauthState,
                rejectedAccessToken: rejectedToken
            )
            guard refreshed.effectiveScopes.sorted() == oauthState.effectiveScopes.sorted() else {
                runtimes[connection.id] = nil
                throw MCPConnectionError.authorizationScopeChanged
            }
            try ensureNotRevoked(connection)
            authentication.header = "Bearer \(refreshed.token.storage)"
            authentication.accessToken = refreshed.token
            response = try await sendToolCall(
                connection: connection,
                runtime: runtime,
                tool: tool,
                arguments: arguments,
                safety: safety,
                authentication: authentication
            )
            guard response.statusCode != 401 else {
                throw MCPConnectionError.unauthorized(retrySuppressed: false)
            }
        }
        if response.statusCode == 404 { throw MCPConnectionError.sessionExpired }
        let value = try successfulRPCValue(response)
        return MCPToolCallResult(
            value: value,
            isError: value.objectValue?["isError"]?.boolValue ?? false
        )
    }

    func revoke(_ connection: MCPConnection) async -> MCPRevocationResult {
        let tokens = try? await vault.oauthTokens(for: connection.id)
        try? await vault.removeAllSecrets(for: connection.id)
        runtimes[connection.id] = nil
        revokedConnections.insert(connection.id)

        var updated = connection
        if case .oauth(var state) = updated.authorization {
            state.status = .revoked
            state.accessTokenExpiresAt = nil
            updated.authorization = .oauth(state)
        } else {
            updated.authorization = .none
        }
        if var trust = updated.trust {
            trust = trust.invalidating(.authorization)
            trust.status = .revoked
            updated.trust = trust
        }

        guard case .oauth(let state) = connection.authorization,
              state.discovery.revocationURL != nil,
              let tokens,
              let token = tokens.refreshToken ?? Optional(tokens.accessToken) else {
            return MCPRevocationResult(connection: updated, remoteRevocation: .notAvailable)
        }
        do {
            try await oauthClient.revoke(MCPTokenRevocationRequest(
                token: token,
                discovery: state.discovery,
                client: state.client
            ))
            return MCPRevocationResult(connection: updated, remoteRevocation: .succeeded)
        } catch {
            return MCPRevocationResult(connection: updated, remoteRevocation: .failed)
        }
    }

    /// Reconciles public expiry/scope metadata after a refresh. A changed scope
    /// advances the trust generation, so policy grants bound to the previous
    /// connection version stop applying before another tool call.
    func reconcileAuthorization(_ connection: MCPConnection) async throws -> MCPConnection {
        guard case .oauth(var state) = connection.authorization,
              let tokens = try await vault.oauthTokens(for: connection.id) else {
            return connection
        }
        var updated = connection
        let previous = updated.authorization
        state.effectiveScopes = tokens.scopes
        state.accessTokenExpiresAt = tokens.expiresAt
        state.status = .authorized
        updated.authorization = .oauth(state)
        updateTrustForAuthorizationChange(
            connection: &updated,
            previous: previous,
            replacement: updated.authorization
        )
        return updated
    }

#if DEBUG
    /// Deterministic test hook that installs a fully parsed handshake without
    /// weakening the production connect path.
    func connectUsingFixture(
        _ connection: MCPConnection,
        serverIdentity: MCPServerIdentity,
        tools: [MCPRemoteTool],
        sessionID: String?
    ) throws -> MCPConnection {
        let negotiation = MCPNegotiatedConnection(
            protocolVersion: preferredProtocolVersion,
            capabilities: MCPServerCapabilities(tools: MCPListCapability()),
            hasSession: sessionID != nil,
            connectedAt: now(),
            toolCount: tools.count
        )
        return try install(
            connection: connection,
            identity: serverIdentity,
            negotiation: negotiation,
            sessionID: try sessionID.map(validatedSessionID),
            tools: tools
        )
    }
#endif

    private func install(
        connection: MCPConnection,
        identity: MCPServerIdentity,
        negotiation: MCPNegotiatedConnection,
        sessionID: MCPSecret?,
        tools: [MCPRemoteTool]
    ) throws -> MCPConnection {
        let exposed = try MCPToolNamespace.bind(
            tools: tools,
            connectionID: connection.id,
            serverIdentity: identity,
            reservedNames: reservedToolNames
        )
        let schemaDigest = mcpSHA256Hex(tools.sorted { $0.name < $1.name }.map {
            MCPToolNamespace.schemaDigest($0)
        })
        let snapshot = MCPTrustSnapshot(
            endpoint: connection.endpoint.canonicalString,
            serverIdentityDigest: mcpCanonicalDigest(identity),
            protocolVersion: negotiation.protocolVersion,
            capabilitiesDigest: mcpCanonicalDigest(negotiation.capabilities),
            toolSchemaDigest: schemaDigest,
            scopeDigest: mcpSHA256Hex(connection.authorization.effectiveScopes.sorted())
        )
        let reconciled = MCPTrustRecord.reconcile(previous: connection.trust, snapshot: snapshot)
        var updatedNegotiation = negotiation
        updatedNegotiation.toolCount = tools.count
        var updated = connection
        updated.serverIdentity = identity
        updated.negotiation = updatedNegotiation
        updated.toolSchemaDigest = schemaDigest
        updated.trust = reconciled
        updated.lastTest = MCPConnectionTestResult(testedAt: now(), succeeded: true, failureCode: nil)
        runtimes[connection.id] = Runtime(
            endpoint: connection.endpoint,
            sessionID: sessionID,
            serverIdentity: identity,
            negotiation: updatedNegotiation,
            tools: exposed,
            trustSnapshot: snapshot
        )
        return updated
    }

    private func sendToolCall(
        connection: MCPConnection,
        runtime: Runtime,
        tool: MCPExposedTool,
        arguments: MCPJSONValue,
        safety: MCPInvocationSafety,
        authentication: Authentication
    ) async throws -> MCPTransportResponse {
        var params: [String: MCPJSONValue] = [
            "name": .string(tool.originalName),
            "arguments": arguments,
        ]
        if let key = safety.idempotencyKey {
            params["_meta"] = .object(["com.straightupbrowser/idempotencyKey": .string(key)])
        }
        return try await sendRPC(
            connection: connection,
            method: "tools/call",
            params: .object(params),
            sessionID: runtime.sessionID,
            authentication: authentication,
            notification: false,
            idempotencyKey: safety.idempotencyKey,
            protocolVersion: runtime.negotiation.protocolVersion
        ).response
    }

    private func sendRPC(
        connection: MCPConnection,
        method: String,
        params: MCPJSONValue,
        sessionID: MCPSecret?,
        authentication: Authentication,
        notification: Bool,
        idempotencyKey: String? = nil,
        protocolVersion: String? = nil
    ) async throws -> (response: MCPTransportResponse, requestID: String?) {
        let requestID = notification ? nil : UUID().uuidString.lowercased()
        var object: [String: MCPJSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ]
        if let requestID { object["id"] = .string(requestID) }
        let body = try JSONEncoder.mcpCanonical.encode(MCPJSONValue.object(object))
        guard body.count <= wire.limits.maxRequestBytes else {
            throw MCPConnectionError.requestTooLarge(limit: wire.limits.maxRequestBytes)
        }
        var headers = baseHeaders(protocolVersion: protocolVersion ?? preferredProtocolVersion)
        if let sessionID { headers["Mcp-Session-Id"] = sessionID.storage }
        if let authorization = authentication.header { headers["Authorization"] = authorization }
        if let idempotencyKey { headers["Idempotency-Key"] = idempotencyKey }
        let response = try await wire.send(MCPTransportRequest(
            url: connection.endpoint.url,
            method: .post,
            headers: headers,
            body: body,
            timeoutMilliseconds: wire.limits.timeoutMilliseconds
        ))
        if notification {
            guard (200..<300).contains(response.statusCode) else {
                throw response.statusCode == 401
                    ? MCPConnectionError.unauthorized(retrySuppressed: false)
                    : MCPConnectionError.transportFailure
            }
        }
        return (response, requestID)
    }

    private func successfulRPCValue(_ response: MCPTransportResponse) throws -> MCPJSONValue {
        if response.statusCode == 401 { throw MCPConnectionError.unauthorized(retrySuppressed: false) }
        if response.statusCode == 404 { throw MCPConnectionError.sessionExpired }
        guard (200..<300).contains(response.statusCode) else { throw MCPConnectionError.transportFailure }
        let root = try wire.json(from: response)
        guard let object = root.objectValue else { throw MCPConnectionError.malformedResponse }
        if let error = object["error"]?.objectValue {
            let code: Int
            if case .number(let value) = error["code"] { code = Int(value) } else { code = -32_000 }
            throw MCPConnectionError.remoteRPCError(code: code)
        }
        guard let result = object["result"] else { throw MCPConnectionError.malformedResponse }
        return result
    }

    private func parseTools(from value: MCPJSONValue) throws -> [MCPRemoteTool] {
        guard let values = value.objectValue?["tools"]?.arrayValue,
              values.count <= wire.limits.maxTools else {
            throw MCPConnectionError.invalidToolMetadata
        }
        var names = Set<String>()
        return try values.map { value in
            guard let object = value.objectValue,
                  let name = object["name"]?.stringValue,
                  !name.isEmpty,
                  name.lengthOfBytes(using: .utf8) <= wire.limits.maxToolNameBytes,
                  names.insert(name).inserted,
                  let inputSchema = object["inputSchema"],
                  inputSchema.objectValue != nil,
                  inputSchema.depth <= wire.limits.maxJSONDepth else {
                if let name = value.objectValue?["name"]?.stringValue, names.contains(name) {
                    throw MCPConnectionError.duplicateToolName
                }
                throw MCPConnectionError.invalidToolMetadata
            }
            let outputSchema = object["outputSchema"]
            if let outputSchema, outputSchema.depth > wire.limits.maxJSONDepth {
                throw MCPConnectionError.responseTooDeep(limit: wire.limits.maxJSONDepth)
            }
            return MCPRemoteTool(
                name: name,
                title: object["title"]?.stringValue.map {
                    sanitizeMetadata($0, byteLimit: wire.limits.maxDescriptionBytes)
                },
                description: sanitizeMetadata(
                    object["description"]?.stringValue ?? "External MCP tool.",
                    byteLimit: wire.limits.maxDescriptionBytes
                ),
                inputSchema: inputSchema,
                outputSchema: outputSchema
            )
        }
    }

    private func authentication(for connection: MCPConnection) async throws -> Authentication {
        switch connection.authorization {
        case .none:
            return Authentication()
        case .bearer:
            guard let token = try await vault.bearerToken(for: connection.id), !token.isEmpty else {
                throw MCPConnectionError.missingCredentials
            }
            return Authentication(header: "Bearer \(token.storage)", accessToken: token)
        case .oauth(let state):
            guard state.status == .authorized else { throw MCPConnectionError.connectionRevoked }
            let grant = try await tokenManager.accessGrant(connectionID: connection.id, authorization: state)
            guard grant.effectiveScopes.sorted() == state.effectiveScopes.sorted() else {
                runtimes[connection.id] = nil
                throw MCPConnectionError.authorizationScopeChanged
            }
            return Authentication(
                header: "Bearer \(grant.token.storage)",
                accessToken: grant.token,
                oauthState: state
            )
        }
    }

    private func ensureNotRevoked(_ connection: MCPConnection) throws {
        guard !revokedConnections.contains(connection.id), connection.authorization.status != .revoked else {
            throw MCPConnectionError.connectionRevoked
        }
    }

    private func validatedSessionID(_ value: String) throws -> MCPSecret {
        guard !value.isEmpty, value.utf8.count <= 512,
              value.unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) }) else {
            throw MCPConnectionError.invalidSessionIdentifier
        }
        return MCPSecret(value)
    }

    private func baseHeaders(protocolVersion: String) -> [String: String] {
        [
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
            "MCP-Protocol-Version": protocolVersion,
        ]
    }

    private func validate(scopes: [String], discovery: MCPOAuthDiscovery) throws {
        let resourceScopes = Set(discovery.protectedResource.scopesSupported)
        let authorizationScopes = Set(discovery.authorizationServer.scopesSupported)
        for scope in scopes {
            guard !scope.isEmpty,
                  (resourceScopes.isEmpty || resourceScopes.contains(scope)),
                  (authorizationScopes.isEmpty || authorizationScopes.contains(scope)) else {
                throw MCPConnectionError.unsupportedScope
            }
        }
    }

    private func entropyValue(label: String, bytes: Int) -> String {
        var data = entropy.randomBytes(count: bytes)
        data.append(contentsOf: label.utf8)
        return mcpBase64URL(Data(SHA256.hash(data: data)))
    }

    private func updateTrustForAuthorizationChange(
        connection: inout MCPConnection,
        previous: MCPAuthorizationState,
        replacement: MCPAuthorizationState
    ) {
        guard var trust = connection.trust else { return }
        let oldScopes = previous.effectiveScopes.sorted()
        let newScopes = replacement.effectiveScopes.sorted()
        if oldScopes != newScopes {
            trust.snapshot.scopeDigest = mcpSHA256Hex(newScopes)
            trust = trust.invalidating(.authorizationScopes)
        } else if previous != replacement {
            trust = trust.invalidating(.authorization)
        }
        connection.trust = trust
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: MCPJSONValue) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: JSONEncoder.mcpCanonical.encode(value))
        } catch {
            throw MCPConnectionError.invalidDiscoveryMetadata
        }
    }

    private func sanitizeMetadata(_ value: String, byteLimit: Int) -> String {
        var output = ""
        for scalar in value.unicodeScalars {
            let replacement = CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
            guard output.lengthOfBytes(using: .utf8) + replacement.lengthOfBytes(using: .utf8) <= byteLimit else {
                break
            }
            output += replacement
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sameRedirect(_ callback: URL, _ registered: URL) -> Bool {
        func base(_ url: URL) -> String? {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            components.query = nil
            components.fragment = nil
            components.scheme = components.scheme?.lowercased()
            components.host = components.host?.lowercased()
            if (components.scheme == "https" && components.port == 443)
                || (components.scheme == "http" && components.port == 80) {
                components.port = nil
            }
            return components.string
        }
        return base(callback) == base(registered)
    }

    private static func uniqueQueryItems(_ items: [URLQueryItem]) -> [String: String]? {
        var values: [String: String] = [:]
        for item in items {
            guard values[item.name] == nil else { return nil }
            values[item.name] = item.value ?? ""
        }
        return values
    }
}

// MARK: - Stable digest helpers

private nonisolated extension JSONEncoder {
    static var mcpCanonical: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}

private nonisolated extension URL {
    var mcpOrigin: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return "<invalid>" }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.string ?? "<invalid>"
    }
}

private nonisolated func mcpCanonicalDigest<T: Encodable>(_ value: T) -> String {
    let data = (try? JSONEncoder.mcpCanonical.encode(value)) ?? Data()
    return mcpSHA256Hex([data.base64EncodedString()])
}

private nonisolated func mcpSHA256Hex(_ values: [String]) -> String {
    var input = Data()
    for value in values {
        var length = UInt64(value.utf8.count).bigEndian
        withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
        input.append(contentsOf: value.utf8)
    }
    return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
}

private nonisolated func mcpBase64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
