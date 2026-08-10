import Foundation
import Testing
@testable import Browser

struct MCPTrustLifecycleTests {
    @Test func endpointPolicyAndRFCWellKnownLocationsFailClosed() throws {
        let remote = try MCPEndpoint(" HTTPS://Example.COM:443/team/mcp ")
        #expect(remote.canonicalString == "https://example.com/team/mcp")
        #expect(remote.protectedResourceMetadataURL.absoluteString ==
            "https://example.com/.well-known/oauth-protected-resource/team/mcp")

        let loopback = try MCPEndpoint("http://127.9.8.7:8123/mcp")
        #expect(loopback.canonicalString == "http://127.9.8.7:8123/mcp")
        #expect(try MCPEndpoint("http://[::1]:8123/mcp").isLoopback)

        #expect(throws: MCPConnectionError.self) { try MCPEndpoint("http://example.com/mcp") }
        #expect(throws: MCPConnectionError.self) { try MCPEndpoint("https://user:secret@example.com/mcp") }
        #expect(throws: MCPConnectionError.self) { try MCPEndpoint("https://example.com/mcp#fragment") }

        let issuer = try MCPAuthorizationIssuer("https://login.example.com/tenant")
        #expect(issuer.metadataURL.absoluteString ==
            "https://login.example.com/.well-known/oauth-authorization-server/tenant")
    }

    @Test func oauthPKCESuccessAndDenialHaveExplicitSecretFreeContracts() async throws {
        let endpoint = try MCPEndpoint("http://localhost:8123/mcp")
        let connection = MCPConnection(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            displayName: "Fixture",
            endpoint: endpoint
        )
        let discovery = try fixtureDiscovery(endpoint: endpoint)
        let vault = MCPInMemorySecretVault()
        let tokenClient = FixtureOAuthTokenClient()
        let transport = QueueMCPTransport([])
        let lifecycle = MCPConnectionLifecycle(
            transport: transport,
            vault: vault,
            oauthClient: tokenClient,
            entropy: RepeatingEntropy(byte: 0x2a),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let client = try MCPPublicOAuthClient(
            clientID: "straight-up-browser",
            redirectURI: URL(string: "http://127.0.0.1:9432/callback")!
        )

        let pending = try await lifecycle.beginAuthorization(
            connection: connection,
            discovery: discovery,
            client: client,
            requestedScopes: ["calendar.read"]
        )
        let query = try #require(URLComponents(url: pending.authorizationURL, resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: (query.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(values["response_type"] == "code")
        #expect(values["code_challenge_method"] == "S256")
        #expect(values["resource"] == endpoint.canonicalString)
        #expect(values["state"] == pending.state)
        #expect(values["nonce"] == pending.nonce)
        #expect(values["code_challenge"] == pending.codeChallenge)

        var callback = URLComponents(url: client.redirectURI, resolvingAgainstBaseURL: false)!
        callback.queryItems = [
            URLQueryItem(name: "code", value: "authorization-code-must-not-leak"),
            URLQueryItem(name: "state", value: pending.state),
        ]
        let authorized = try await lifecycle.completeAuthorization(
            connection: connection,
            pending: pending,
            callbackURL: try #require(callback.url)
        )
        #expect(authorized.authorization.effectiveScopes == ["calendar.read"])
        #expect(await vault.hasOAuthTokens(for: connection.id))

        let encoded = String(decoding: try JSONEncoder().encode(authorized), as: UTF8.self)
        #expect(!encoded.contains("authorization-code-must-not-leak"))
        #expect(!encoded.contains("access-token-must-not-leak"))
        #expect(!String(describing: pending).contains(pending.state))
        #expect(!String(describing: await tokenClient.lastExchange()).contains("authorization-code-must-not-leak"))
        let redactedRequest = MCPTransportRequest(
            url: endpoint.url,
            method: .post,
            headers: ["Authorization": "Bearer access-token-must-not-leak"],
            body: Data("authorization-code-must-not-leak".utf8),
            timeoutMilliseconds: 100
        )
        #expect(!String(describing: redactedRequest).contains("access-token-must-not-leak"))
        #expect(!String(reflecting: redactedRequest).contains("authorization-code-must-not-leak"))

        let denied = try await lifecycle.beginAuthorization(
            connection: connection,
            discovery: discovery,
            client: client,
            requestedScopes: []
        )
        var denial = URLComponents(url: client.redirectURI, resolvingAgainstBaseURL: false)!
        denial.queryItems = [
            URLQueryItem(name: "error", value: "access_denied"),
            URLQueryItem(name: "error_description", value: "server text must not be reflected"),
            URLQueryItem(name: "state", value: denied.state),
        ]
        await #expect(throws: MCPConnectionError.authorizationDenied) {
            try await lifecycle.completeAuthorization(
                connection: authorized,
                pending: denied,
                callbackURL: try #require(denial.url)
            )
        }
    }

    @Test func oauthDiscoveryUsesProtectedResourceThenIssuerMetadataAndPinsIdentities() async throws {
        let endpoint = try MCPEndpoint("http://127.0.0.1:8123/team/mcp")
        let connection = MCPConnection(displayName: "Fixture", endpoint: endpoint)
        let resource = MCPProtectedResourceMetadata(
            resource: endpoint.canonicalString,
            authorizationServers: ["https://login.example.com/tenant"],
            scopesSupported: ["files.read"]
        )
        let authorization = MCPAuthorizationServerMetadata(
            issuer: "https://login.example.com/tenant",
            authorizationEndpoint: "https://login.example.com/authorize",
            tokenEndpoint: "https://login.example.com/token",
            revocationEndpoint: "https://login.example.com/revoke",
            scopesSupported: ["files.read"],
            responseTypesSupported: ["code"],
            grantTypesSupported: ["authorization_code", "refresh_token"],
            codeChallengeMethodsSupported: ["S256"],
            tokenEndpointAuthMethodsSupported: ["none"]
        )
        let transport = QueueMCPTransport([
            .json(status: 200, encodable: resource),
            .json(status: 200, encodable: authorization),
        ])
        let lifecycle = MCPConnectionLifecycle(
            transport: transport,
            vault: MCPInMemorySecretVault(),
            oauthClient: FixtureOAuthTokenClient()
        )

        let discovery = try await lifecycle.discoverAuthorization(for: connection)
        #expect(discovery.resourceEndpoint == endpoint)
        #expect(discovery.issuer.canonicalString == "https://login.example.com/tenant")
        #expect(discovery.tokenURL.absoluteString == "https://login.example.com/token")

        let mismatchedTransport = QueueMCPTransport([
            .json(status: 200, encodable: MCPProtectedResourceMetadata(
                resource: "https://attacker.example/mcp",
                authorizationServers: ["https://login.example.com"],
                scopesSupported: []
            )),
        ])
        let mismatched = MCPConnectionLifecycle(
            transport: mismatchedTransport,
            vault: MCPInMemorySecretVault(),
            oauthClient: FixtureOAuthTokenClient()
        )
        await #expect(throws: MCPConnectionError.metadataIdentityMismatch) {
            try await mismatched.discoverAuthorization(for: connection)
        }
    }

    @Test func successfulNegotiationProducesReviewableTrustAndSchemaChangeInvalidatesIt() async throws {
        let endpoint = try MCPEndpoint("http://localhost:8123/mcp")
        var connection = MCPConnection(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            displayName: "Fixture",
            endpoint: endpoint
        )
        let transport = QueueMCPTransport(
            connectResponses(sessionID: "session-one", schemaDescription: "Before")
            + connectResponses(sessionID: "session-two", schemaDescription: "After")
        )
        let lifecycle = MCPConnectionLifecycle(
            transport: transport,
            vault: MCPInMemorySecretVault(),
            oauthClient: FixtureOAuthTokenClient()
        )

        connection = try await lifecycle.connect(connection)
        #expect(connection.serverIdentity?.name == "Fixture MCP")
        #expect(connection.negotiation?.protocolVersion == "2025-06-18")
        #expect(connection.negotiation?.hasSession == true)
        #expect(connection.toolSchemaDigest != nil)
        #expect(connection.trust?.status == .needsReview)
        connection.approveCurrentTrust(at: Date(timeIntervalSince1970: 10))
        let firstBinding = try #require(connection.trust?.binding)
        let exposedName = try #require(await lifecycle.tools(for: connection).first?.exposedName)
        let policyIdentity = try await lifecycle.policyIdentity(
            for: connection,
            exposedToolName: exposedName
        )
        #expect(policyIdentity.connectionID == connection.id)
        #expect(policyIdentity.originalToolName == "fixture_tool")
        #expect(policyIdentity.trustBinding == firstBinding)
        #expect(policyIdentity.dataLeavesDevice)

        connection = try await lifecycle.reconnect(connection)
        #expect(connection.trust?.status == .needsReview)
        #expect(connection.trust?.changedDimensions.contains(.toolSchema) == true)
        #expect(connection.trust?.binding != firstBinding)
        #expect(connection.trust?.generation == 2)
    }

    @Test func namespacedToolNamesAreBoundedDeterministicAndCollisionSafe() throws {
        let connectionID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let tools = [
            MCPRemoteTool(name: "create invoice", description: "One", inputSchema: .object([:])),
            MCPRemoteTool(name: "create?invoice", description: "Two", inputSchema: .object([:])),
            MCPRemoteTool(name: String(repeating: "very-long-name-", count: 10), description: "Three", inputSchema: .object([:])),
        ]

        let first = try MCPToolNamespace.expose(
            tools: tools,
            connectionID: connectionID,
            reservedNames: ["mcp_reserved"]
        )
        let second = try MCPToolNamespace.expose(
            tools: tools.reversed(),
            connectionID: connectionID,
            reservedNames: ["mcp_reserved"]
        )

        #expect(Set(first.map(\.exposedName)).count == tools.count)
        #expect(first.allSatisfy { $0.exposedName.count <= 64 })
        #expect(first.allSatisfy { $0.exposedName.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } })
        #expect(Dictionary(uniqueKeysWithValues: first.map { ($0.originalName, $0.exposedName) }) ==
            Dictionary(uniqueKeysWithValues: second.map { ($0.originalName, $0.exposedName) }))
    }

    @Test func negotiationFailsClosedForProtocolMismatchOversizeDepthAndTimeout() async throws {
        let endpoint = try MCPEndpoint("http://localhost:8123/mcp")
        let connection = MCPConnection(displayName: "Fixture", endpoint: endpoint)

        let mismatch = QueueMCPTransport([
            .json(status: 200, object: initializeResult(protocolVersion: "2025-11-25")),
        ])
        let mismatchLifecycle = MCPConnectionLifecycle(
            transport: mismatch,
            vault: MCPInMemorySecretVault(),
            oauthClient: FixtureOAuthTokenClient()
        )
        await #expect(throws: MCPConnectionError.unsupportedProtocol("2025-11-25")) {
            try await mismatchLifecycle.connect(connection)
        }

        let oversized = QueueMCPTransport([
            MCPTransportResponse(statusCode: 200, headers: [:], body: Data(repeating: 0x20, count: 129)),
        ])
        let oversizedLifecycle = MCPConnectionLifecycle(
            transport: oversized,
            vault: MCPInMemorySecretVault(),
            oauthClient: FixtureOAuthTokenClient(),
            limits: MCPTransportLimits(maxResponseBytes: 128, maxJSONDepth: 16, timeoutMilliseconds: 1_000)
        )
        await #expect(throws: MCPConnectionError.responseTooLarge(limit: 128)) {
            try await oversizedLifecycle.connect(connection)
        }

        let tooDeep = QueueMCPTransport([
            .json(status: 200, object: [
                "jsonrpc": "2.0",
                "id": "fixture",
                "result": ["one": ["two": ["three": ["four": true]]]],
            ]),
        ])
        let depthLifecycle = MCPConnectionLifecycle(
            transport: tooDeep,
            vault: MCPInMemorySecretVault(),
            oauthClient: FixtureOAuthTokenClient(),
            limits: MCPTransportLimits(maxResponseBytes: 1_024, maxJSONDepth: 4, timeoutMilliseconds: 1_000)
        )
        await #expect(throws: MCPConnectionError.responseTooDeep(limit: 4)) {
            try await depthLifecycle.connect(connection)
        }

        let slow = QueueMCPTransport([
            .json(status: 200, object: initializeResult(protocolVersion: "2025-06-18")),
        ], delay: .milliseconds(100))
        let timeoutLifecycle = MCPConnectionLifecycle(
            transport: slow,
            vault: MCPInMemorySecretVault(),
            oauthClient: FixtureOAuthTokenClient(),
            limits: MCPTransportLimits(maxResponseBytes: 1024, maxJSONDepth: 16, timeoutMilliseconds: 5)
        )
        await #expect(throws: MCPConnectionError.timeout(milliseconds: 5)) {
            try await timeoutLifecycle.connect(connection)
        }
    }

    @Test func tokenRefreshIsSingleFlightAcrossConcurrentCallers() async throws {
        let connectionID = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
        let vault = MCPInMemorySecretVault()
        let expired = MCPTokenBundle(
            accessToken: MCPSecret("expired-access"),
            refreshToken: MCPSecret("refresh-token-must-not-leak"),
            tokenType: "Bearer",
            expiresAt: Date(timeIntervalSince1970: 10),
            scopes: ["files.read"]
        )
        await vault.storeOAuthTokens(expired, for: connectionID)
        let client = FixtureOAuthTokenClient(refreshDelay: .milliseconds(20))
        let manager = MCPTokenManager(
            vault: vault,
            oauthClient: client,
            now: { Date(timeIntervalSince1970: 1_000) },
            refreshLeeway: 0
        )
        let state = fixtureOAuthState(scopes: ["files.read"])

        try await withThrowingTaskGroup(of: MCPSecret.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await manager.accessToken(connectionID: connectionID, authorization: state)
                }
            }
            var tokens: [MCPSecret] = []
            for try await token in group { tokens.append(token) }
            #expect(tokens.count == 20)
            #expect(Set(tokens).count == 1)
        }
        #expect(await client.refreshCount() == 1)
    }

    @Test func revokeDeletesSecretsAndBlocksCallsBeforeRemoteRevocationCompletes() async throws {
        let endpoint = try MCPEndpoint("http://localhost:8123/mcp")
        let id = UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
        let vault = MCPInMemorySecretVault()
        await vault.storeOAuthTokens(
            MCPTokenBundle(
                accessToken: MCPSecret("access-token-must-not-leak"),
                refreshToken: MCPSecret("refresh-token-must-not-leak"),
                tokenType: "Bearer",
                expiresAt: Date.distantFuture,
                scopes: ["files.write"]
            ),
            for: id
        )
        let oauth = FixtureOAuthTokenClient(revokeDelay: .milliseconds(40))
        let lifecycle = MCPConnectionLifecycle(
            transport: QueueMCPTransport([]),
            vault: vault,
            oauthClient: oauth
        )
        var connection = MCPConnection(id: id, displayName: "Fixture", endpoint: endpoint)
        connection.authorization = .oauth(fixtureOAuthState(scopes: ["files.write"]))
        let activeConnection = connection

        async let revoked = lifecycle.revoke(activeConnection)
        try await Task.sleep(for: .milliseconds(5))
        #expect(!(await vault.hasOAuthTokens(for: id)))
        await #expect(throws: MCPConnectionError.connectionRevoked) {
            try await lifecycle.call(
                connection: activeConnection,
                exposedToolName: "anything",
                arguments: .object([:]),
                safety: .readOnly
            )
        }
        let result = await revoked
        #expect(result.connection.authorization.status == .revoked)
        #expect(result.remoteRevocation == .succeeded)
    }

    @Test func authenticationRetryNeverDuplicatesUnsafeMutation() async throws {
        let endpoint = try MCPEndpoint("http://localhost:8123/mcp")
        let id = UUID(uuidString: "60000000-0000-0000-0000-000000000006")!
        let vault = MCPInMemorySecretVault()
        await vault.storeOAuthTokens(
            MCPTokenBundle(
                accessToken: MCPSecret("stale-access"),
                refreshToken: MCPSecret("refresh-token"),
                tokenType: "Bearer",
                expiresAt: Date.distantFuture,
                scopes: ["write"]
            ),
            for: id
        )
        let transport = Mutation401Transport()
        let oauth = FixtureOAuthTokenClient()
        let lifecycle = MCPConnectionLifecycle(transport: transport, vault: vault, oauthClient: oauth)
        var connection = MCPConnection(id: id, displayName: "Fixture", endpoint: endpoint)
        connection.authorization = .oauth(fixtureOAuthState(scopes: ["write"]))
        connection = try await lifecycle.connectUsingFixture(
            connection,
            serverIdentity: MCPServerIdentity(name: "Fixture MCP", version: "1"),
            tools: [MCPRemoteTool(name: "mutate", description: "Mutate", inputSchema: .object([:]))],
            sessionID: "fixture-session"
        )
        connection.approveCurrentTrust()
        let exposed = try #require(await lifecycle.tools(for: connection).first?.exposedName)

        await #expect(throws: MCPConnectionError.unauthorized(retrySuppressed: true)) {
            try await lifecycle.call(
                connection: connection,
                exposedToolName: exposed,
                arguments: .object([:]),
                safety: .mutation(idempotencyKey: nil)
            )
        }
        #expect(await transport.effectCount == 1)
        #expect(await transport.requestCount == 1)
        #expect(await oauth.refreshCount() == 0)
    }

    @Test func idempotentMutationRetriesExactlyOnceAfterSingleFlightRefresh() async throws {
        let endpoint = try MCPEndpoint("http://localhost:8123/mcp")
        let id = UUID(uuidString: "70000000-0000-0000-0000-000000000007")!
        let vault = MCPInMemorySecretVault()
        await vault.storeOAuthTokens(
            MCPTokenBundle(
                accessToken: MCPSecret("stale-access"),
                refreshToken: MCPSecret("refresh-token"),
                tokenType: "Bearer",
                expiresAt: Date.distantFuture,
                scopes: ["write"]
            ),
            for: id
        )
        let transport = IdempotentMutationTransport()
        let oauth = FixtureOAuthTokenClient(refreshDelay: .milliseconds(10))
        let lifecycle = MCPConnectionLifecycle(transport: transport, vault: vault, oauthClient: oauth)
        var connection = MCPConnection(id: id, displayName: "Fixture", endpoint: endpoint)
        connection.authorization = .oauth(fixtureOAuthState(scopes: ["write"]))
        connection = try await lifecycle.connectUsingFixture(
            connection,
            serverIdentity: MCPServerIdentity(name: "Fixture MCP", version: "1"),
            tools: [MCPRemoteTool(name: "mutate", description: "Mutate", inputSchema: .object([:]))],
            sessionID: "fixture-session"
        )
        connection.approveCurrentTrust()
        let exposed = try #require(await lifecycle.tools(for: connection).first?.exposedName)
        let approvedConnection = connection

        let results = try await withThrowingTaskGroup(of: MCPToolCallResult.self) { group in
            for index in 0..<8 {
                group.addTask {
                    try await lifecycle.call(
                        connection: approvedConnection,
                        exposedToolName: exposed,
                        arguments: .object(["index": .number(Double(index))]),
                        safety: .mutation(idempotencyKey: "operation-\(index)")
                    )
                }
            }
            var values: [MCPToolCallResult] = []
            for try await value in group { values.append(value) }
            return values
        }
        #expect(results.count == 8)
        #expect(await oauth.refreshCount() == 1)
        #expect(await transport.effectCount == 8)
        #expect(await transport.requestCount == 16)
    }

    @Test func concurrentConnectionsNeverCrossSessionOrAuthorizationHeaders() async throws {
        let transport = SessionCheckingTransport()
        let vault = MCPInMemorySecretVault()
        let lifecycle = MCPConnectionLifecycle(
            transport: transport,
            vault: vault,
            oauthClient: FixtureOAuthTokenClient()
        )
        let firstID = UUID(uuidString: "80000000-0000-0000-0000-000000000008")!
        let secondID = UUID(uuidString: "90000000-0000-0000-0000-000000000009")!
        await vault.storeBearerToken(MCPSecret("token-one"), for: firstID)
        await vault.storeBearerToken(MCPSecret("token-two"), for: secondID)
        var first = MCPConnection(id: firstID, displayName: "One", endpoint: try MCPEndpoint("http://127.0.0.1:8101/mcp"))
        var second = MCPConnection(id: secondID, displayName: "Two", endpoint: try MCPEndpoint("http://127.0.0.1:8102/mcp"))
        first.authorization = .bearer
        second.authorization = .bearer
        first = try await lifecycle.connectUsingFixture(
            first,
            serverIdentity: MCPServerIdentity(name: "One", version: "1"),
            tools: [MCPRemoteTool(name: "read", description: "Read", inputSchema: .object([:]))],
            sessionID: "session-one"
        )
        second = try await lifecycle.connectUsingFixture(
            second,
            serverIdentity: MCPServerIdentity(name: "Two", version: "1"),
            tools: [MCPRemoteTool(name: "read", description: "Read", inputSchema: .object([:]))],
            sessionID: "session-two"
        )
        first.approveCurrentTrust()
        second.approveCurrentTrust()
        let firstTool = try #require(await lifecycle.tools(for: first).first?.exposedName)
        let secondTool = try #require(await lifecycle.tools(for: second).first?.exposedName)

        async let firstResult = lifecycle.call(
            connection: first,
            exposedToolName: firstTool,
            arguments: .object([:]),
            safety: .readOnly
        )
        async let secondResult = lifecycle.call(
            connection: second,
            exposedToolName: secondTool,
            arguments: .object([:]),
            safety: .readOnly
        )
        _ = try await (firstResult, secondResult)
        #expect(await transport.failures.isEmpty)
    }
}

// MARK: - Deterministic fixtures

private struct RepeatingEntropy: MCPOAuthEntropySource {
    let byte: UInt8
    func randomBytes(count: Int) -> Data { Data(repeating: byte, count: count) }
}

private actor FixtureOAuthTokenClient: MCPOAuthTokenExchanging {
    private var exchanges: [MCPAuthorizationCodeExchange] = []
    private var refreshes = 0
    private var revocations = 0
    private let refreshDelay: Duration
    private let revokeDelay: Duration

    init(refreshDelay: Duration = .zero, revokeDelay: Duration = .zero) {
        self.refreshDelay = refreshDelay
        self.revokeDelay = revokeDelay
    }

    func exchangeAuthorizationCode(_ request: MCPAuthorizationCodeExchange) async throws -> MCPTokenBundle {
        exchanges.append(request)
        return MCPTokenBundle(
            accessToken: MCPSecret("access-token-must-not-leak"),
            refreshToken: MCPSecret("refresh-token-must-not-leak"),
            tokenType: "Bearer",
            expiresAt: Date(timeIntervalSince1970: 3_000),
            scopes: request.requestedScopes
        )
    }

    func refresh(_ request: MCPTokenRefreshRequest) async throws -> MCPTokenBundle {
        refreshes += 1
        if refreshDelay != .zero { try await Task.sleep(for: refreshDelay) }
        return MCPTokenBundle(
            accessToken: MCPSecret("fresh-access"),
            refreshToken: request.refreshToken,
            tokenType: "Bearer",
            expiresAt: Date.distantFuture,
            scopes: request.requestedScopes
        )
    }

    func revoke(_ request: MCPTokenRevocationRequest) async throws {
        revocations += 1
        if revokeDelay != .zero { try await Task.sleep(for: revokeDelay) }
    }

    func refreshCount() -> Int { refreshes }
    func lastExchange() -> MCPAuthorizationCodeExchange? { exchanges.last }
}

private actor QueueMCPTransport: MCPTransport {
    private var responses: [MCPTransportResponse]
    private let delay: Duration

    init(_ responses: [MCPTransportResponse], delay: Duration = .zero) {
        self.responses = responses
        self.delay = delay
    }

    func send(_ request: MCPTransportRequest) async throws -> MCPTransportResponse {
        if delay != .zero { try await Task.sleep(for: delay) }
        guard !responses.isEmpty else { throw MCPConnectionError.transportFailure }
        return responses.removeFirst()
    }
}

private actor Mutation401Transport: MCPTransport {
    private(set) var requestCount = 0
    private(set) var effectCount = 0

    func send(_ request: MCPTransportRequest) async throws -> MCPTransportResponse {
        requestCount += 1
        effectCount += 1
        return MCPTransportResponse(statusCode: 401, headers: [:], body: Data())
    }
}

private actor IdempotentMutationTransport: MCPTransport {
    private(set) var requestCount = 0
    private(set) var effectCount = 0
    private var appliedKeys = Set<String>()

    func send(_ request: MCPTransportRequest) async throws -> MCPTransportResponse {
        requestCount += 1
        guard request.headers["Authorization"] == "Bearer fresh-access" else {
            return MCPTransportResponse(statusCode: 401, headers: [:], body: Data())
        }
        if let key = request.headers["Idempotency-Key"], appliedKeys.insert(key).inserted {
            effectCount += 1
        }
        return .json(status: 200, object: [
            "jsonrpc": "2.0", "id": "fixture", "result": ["content": []],
        ])
    }
}

private actor SessionCheckingTransport: MCPTransport {
    private(set) var failures: [String] = []

    func send(_ request: MCPTransportRequest) async throws -> MCPTransportResponse {
        let port = request.url.port
        let expectedSession = port == 8101 ? "session-one" : "session-two"
        let expectedToken = port == 8101 ? "Bearer token-one" : "Bearer token-two"
        if request.headers["Mcp-Session-Id"] != expectedSession { failures.append("session") }
        if request.headers["Authorization"] != expectedToken { failures.append("authorization") }
        return .json(status: 200, object: [
            "jsonrpc": "2.0", "id": "fixture", "result": ["content": []],
        ])
    }
}

private func fixtureDiscovery(endpoint: MCPEndpoint) throws -> MCPOAuthDiscovery {
    try MCPOAuthDiscovery(
        protectedResource: MCPProtectedResourceMetadata(
            resource: endpoint.canonicalString,
            authorizationServers: ["https://login.example.com"],
            scopesSupported: ["calendar.read", "files.read", "files.write"]
        ),
        authorizationServer: MCPAuthorizationServerMetadata(
            issuer: "https://login.example.com",
            authorizationEndpoint: "https://login.example.com/authorize",
            tokenEndpoint: "https://login.example.com/token",
            revocationEndpoint: "https://login.example.com/revoke",
            registrationEndpoint: nil,
            scopesSupported: ["calendar.read", "files.read", "files.write"],
            responseTypesSupported: ["code"],
            grantTypesSupported: ["authorization_code", "refresh_token"],
            codeChallengeMethodsSupported: ["S256"],
            tokenEndpointAuthMethodsSupported: ["none"]
        ),
        endpoint: endpoint
    )
}

private func fixtureOAuthState(scopes: [String]) -> MCPOAuthPublicState {
    let endpoint = try! MCPEndpoint("http://localhost:8123/mcp")
    return MCPOAuthPublicState(
        discovery: try! fixtureDiscovery(endpoint: endpoint),
        client: try! MCPPublicOAuthClient(
            clientID: "straight-up-browser",
            redirectURI: URL(string: "http://127.0.0.1:9432/callback")!
        ),
        status: .authorized,
        effectiveScopes: scopes,
        accessTokenExpiresAt: Date.distantFuture
    )
}

private func connectResponses(sessionID: String, schemaDescription: String) -> [MCPTransportResponse] {
    [
        .json(
            status: 200,
            headers: ["Mcp-Session-Id": sessionID],
            object: initializeResult(protocolVersion: "2025-06-18")
        ),
        MCPTransportResponse(statusCode: 202, headers: [:], body: Data()),
        .json(status: 200, object: [
            "jsonrpc": "2.0",
            "id": "tools",
            "result": [
                "tools": [[
                    "name": "fixture_tool",
                    "description": schemaDescription,
                    "inputSchema": ["type": "object", "properties": [:]],
                ]],
            ],
        ]),
    ]
}

private func initializeResult(protocolVersion: String) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": "initialize",
        "result": [
            "protocolVersion": protocolVersion,
            "serverInfo": ["name": "Fixture MCP", "version": "1.0"],
            "capabilities": ["tools": ["listChanged": true]],
        ],
    ]
}

private nonisolated extension MCPTransportResponse {
    static func json(
        status: Int,
        headers: [String: String] = [:],
        object: [String: Any]
    ) -> MCPTransportResponse {
        MCPTransportResponse(
            statusCode: status,
            headers: headers,
            body: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }


    static func json<T: Encodable>(
        status: Int,
        headers: [String: String] = [:],
        encodable: T
    ) -> MCPTransportResponse {
        MCPTransportResponse(
            statusCode: status,
            headers: headers,
            body: try! JSONEncoder().encode(encodable)
        )
    }
}
