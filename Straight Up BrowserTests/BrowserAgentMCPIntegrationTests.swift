import Foundation
import Testing
@testable import Browser

@MainActor
struct BrowserAgentMCPIntegrationTests {
    @Test func legacyRecordsMigrateToSecretFreeMCPConnections() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("connections.json")
        let validID = UUID(uuidString: "91000000-0000-0000-0000-000000000001")!
        let invalidID = UUID(uuidString: "91000000-0000-0000-0000-000000000002")!
        let legacy = """
        [
          {"id":"\(validID.uuidString)","name":" Calendar ","endpoint":"http://127.0.0.1:8123/mcp","enabled":true},
          {"id":"\(invalidID.uuidString)","name":"Unsafe","endpoint":"http://example.com/mcp","enabled":true}
        ]
        """
        try Data(legacy.utf8).write(to: url)

        let loaded = BrowserAgentMCPConnectionPersistence.load(from: url)
        #expect(loaded.migratedLegacyRecords)
        #expect(loaded.discardedRecordCount == 1)
        #expect(loaded.connections.count == 1)
        #expect(loaded.connections.first?.id == validID)
        #expect(loaded.connections.first?.displayName == "Calendar")
        #expect(loaded.connections.first?.endpoint.canonicalString == "http://127.0.0.1:8123/mcp")
        #expect(loaded.connections.first?.authorization == MCPAuthorizationState.none)

        try BrowserAgentMCPConnectionPersistence.save(loaded.connections, to: url)
        let persistedData = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([MCPConnection].self, from: persistedData)
        #expect(decoded == loaded.connections)
        let persistedText = String(decoding: persistedData, as: UTF8.self)
        #expect(!persistedText.contains("Bearer"))
        #expect(!persistedText.contains("token"))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(permissions & 0o777 == 0o600)
    }

    @Test func storeExposesOnlyTrustedPolicyBoundToolsAndRevocationBlocksOldRoutes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("connections.json")
        let secret = "bearer-secret-must-not-be-persisted"
        let transport = BrowserAgentMCPQueueTransport(
            Self.connectResponses(sessionID: "session-one")
                + Self.connectResponses(sessionID: "session-two")
        )
        let vault = MCPInMemorySecretVault()
        let oauthClient = MCPHTTPTokenClient(transport: transport)
        let lifecycle = MCPConnectionLifecycle(
            transport: transport,
            vault: vault,
            oauthClient: oauthClient,
            reservedToolNames: Set(AgentToolCatalog.canonical.allDescriptors.map(\.name))
        )
        let store = BrowserAgentMCPStore(
            storeURL: storeURL,
            lifecycle: lifecycle,
            authorizationPresenter: BrowserAgentMCPUnusedAuthorizationPresenter()
        )

        try await store.add(
            name: "Fixture",
            endpoint: "http://127.0.0.1:8123/mcp",
            bearerToken: secret
        )
        let added = try #require(store.connections.first)
        let persistedBeforeTrust = String(decoding: try Data(contentsOf: storeURL), as: UTF8.self)
        #expect(!persistedBeforeTrust.contains(secret))
        #expect(added.authorization == .bearer)

        await store.test(added)
        let reviewed = try #require(store.connections.first)
        #expect(reviewed.trust?.status == .needsReview)
        let unavailable = await store.prepareTools()
        #expect(unavailable.routes.isEmpty)

        // The prior prepare attempt consumed the second handshake while trust
        // remained unapproved, so approve its current snapshot and reconnect
        // once more for the route fixture.
        store.approveTrust(added.id)
        await transport.append(contentsOf: Self.connectResponses(sessionID: "session-three"))
        await transport.append(Self.jsonResponse(status: 200, object: [
            "jsonrpc": "2.0",
            "id": "call",
            "result": ["content": [["type": "text", "text": "ok"]]],
        ]))
        let tools = await store.prepareTools()
        #expect(tools.definitions.count == 1)
        #expect(tools.routes.count == 1)
        let route = try #require(tools.routes.values.first)
        let trusted = try #require(store.connections.first)
        #expect(route.policyIdentity.connectionID == trusted.id)
        #expect(route.policyIdentity.normalizedEndpoint == trusted.endpoint.canonicalString)
        #expect(route.policyIdentity.trustBinding == trusted.trust?.binding)
        #expect(route.policyIdentity.dataLeavesDevice)

        let invocation = BrowserAgentMCPInvocationIdentity(
            permitDigest: "fixture-invocation-digest",
            persistedStepID: UUID(uuidString: "91000000-0000-0000-0000-000000000101")!
        )
        let result = await store.call(
            route,
            arguments: ["query": "hello"],
            invocation: invocation
        )
        #expect(result.contains("ok"))
        let requests = await transport.requests()
        #expect(requests.last?.headers["Authorization"] == "Bearer \(secret)")
        #expect(requests.last?.headers["Mcp-Session-Id"] == "session-three")
        #expect(requests.last?.headers["Idempotency-Key"] == invocation.idempotencyKey)
        let persisted = String(decoding: try Data(contentsOf: storeURL), as: UTF8.self)
        #expect(!persisted.contains(secret))

        let countBeforeRevocation = requests.count
        await store.revoke(trusted.id)
        let storedBearer = await vault.bearerToken(for: trusted.id)
        #expect(storedBearer == nil)
        let blocked = await store.call(
            route,
            arguments: ["query": "after revoke"],
            invocation: BrowserAgentMCPInvocationIdentity(
                permitDigest: "revoked-invocation-digest",
                persistedStepID: UUID(uuidString: "91000000-0000-0000-0000-000000000102")!
            )
        )
        #expect(blocked.contains("revoked"))
        #expect(await transport.requestCount() == countBeforeRevocation)
    }

    @Test func storeCompletesOAuthPKCEWithoutPersistingCodesOrTokens() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-oauth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("connections.json")
        let endpoint = "http://127.0.0.1:8123/mcp"
        let issuer = "http://127.0.0.1:8124"
        let authorizationCode = "authorization-code-must-not-be-persisted"
        let accessToken = "oauth-access-must-not-be-persisted"
        let refreshToken = "oauth-refresh-must-not-be-persisted"
        let transport = BrowserAgentMCPQueueTransport([
            Self.jsonResponse(status: 200, object: [
                "resource": endpoint,
                "authorization_servers": [issuer],
                "scopes_supported": ["files.read"],
            ]),
            Self.jsonResponse(status: 200, object: [
                "issuer": issuer,
                "authorization_endpoint": "\(issuer)/authorize",
                "token_endpoint": "\(issuer)/token",
                "revocation_endpoint": "\(issuer)/revoke",
                "scopes_supported": ["files.read"],
                "response_types_supported": ["code"],
                "grant_types_supported": ["authorization_code", "refresh_token"],
                "code_challenge_methods_supported": ["S256"],
                "token_endpoint_auth_methods_supported": ["none"],
            ]),
            Self.jsonResponse(status: 200, object: [
                "access_token": accessToken,
                "refresh_token": refreshToken,
                "token_type": "Bearer",
                "expires_in": 3_600,
                "scope": "files.read",
            ]),
        ] + Self.connectResponses(sessionID: "oauth-session"))
        let vault = MCPInMemorySecretVault()
        let tokenClient = MCPHTTPTokenClient(transport: transport)
        let lifecycle = MCPConnectionLifecycle(
            transport: transport,
            vault: vault,
            oauthClient: tokenClient
        )
        let presenter = BrowserAgentMCPSuccessAuthorizationPresenter(code: authorizationCode)
        let store = BrowserAgentMCPStore(
            storeURL: storeURL,
            lifecycle: lifecycle,
            authorizationPresenter: presenter
        )

        try await store.add(name: "OAuth Fixture", endpoint: endpoint, bearerToken: "")
        let id = try #require(store.connections.first?.id)
        await store.authorizeOAuth(
            id,
            clientID: "straight-up-browser-test",
            requestedScopes: ["files.read"]
        )

        let authorized = try #require(store.connections.first)
        #expect(authorized.authorization.status == .authorized)
        #expect(authorized.authorization.effectiveScopes == ["files.read"])
        #expect(authorized.trust?.status == .needsReview)
        #expect(await vault.hasOAuthTokens(for: id))
        let launchURL = try #require(presenter.authorizationURL)
        let launchQuery = URLComponents(url: launchURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(launchQuery.contains { $0.name == "code_challenge_method" && $0.value == "S256" })
        #expect(launchQuery.contains { $0.name == "resource" && $0.value == endpoint })

        let persisted = String(decoding: try Data(contentsOf: storeURL), as: UTF8.self)
        #expect(!persisted.contains(authorizationCode))
        #expect(!persisted.contains(accessToken))
        #expect(!persisted.contains(refreshToken))
        #expect(!String(describing: await transport.requests()).contains(authorizationCode))

        store.approveTrust(id)
        await transport.append(contentsOf: Self.connectResponses(sessionID: "oauth-session-two"))
        await transport.append(MCPTransportResponse(statusCode: 401, headers: [:], body: Data()))
        await transport.append(Self.jsonResponse(status: 200, object: [
            "access_token": "refreshed-oauth-access",
            "refresh_token": "rotated-oauth-refresh",
            "token_type": "Bearer",
            "expires_in": 3_600,
            "scope": "files.read",
        ]))
        await transport.append(Self.jsonResponse(status: 200, object: [
            "jsonrpc": "2.0",
            "id": "retried-call",
            "result": ["content": [["type": "text", "text": "recovered"]]],
        ]))
        let tools = await store.prepareTools()
        let route = try #require(tools.routes.values.first)
        let requestCountBeforeCall = await transport.requestCount()
        let invocationDigest = "persisted-policy-invocation-digest"
        let invocation = BrowserAgentMCPInvocationIdentity(
            permitDigest: invocationDigest,
            persistedStepID: UUID(uuidString: "91000000-0000-0000-0000-000000000201")!
        )
        let separateInvocation = BrowserAgentMCPInvocationIdentity(
            permitDigest: invocationDigest,
            persistedStepID: UUID(uuidString: "91000000-0000-0000-0000-000000000202")!
        )
        #expect(invocation.idempotencyKey != separateInvocation.idempotencyKey)
        let recovered = await store.call(
            route,
            arguments: ["query": "refresh once"],
            invocation: invocation
        )
        #expect(recovered.contains("recovered"))

        let recoveryRequests = Array((await transport.requests()).dropFirst(requestCountBeforeCall))
        let toolCalls = recoveryRequests.filter { Self.rpcMethod(in: $0) == "tools/call" }
        #expect(toolCalls.count == 2)
        #expect(toolCalls.allSatisfy { $0.headers["Idempotency-Key"] == invocation.idempotencyKey })
        #expect(toolCalls.allSatisfy { Self.rpcIdempotencyKey(in: $0) == invocation.idempotencyKey })
        #expect(toolCalls.first?.headers["Authorization"] == "Bearer \(accessToken)")
        #expect(toolCalls.last?.headers["Authorization"] == "Bearer refreshed-oauth-access")
        #expect(recoveryRequests.filter { $0.url.path == "/token" }.count == 1)

        await transport.append(MCPTransportResponse(statusCode: 200, headers: [:], body: Data()))
        await store.revoke(id)
        #expect(!(await vault.hasOAuthTokens(for: id)))
        #expect(store.connections.first?.authorization.status == .revoked)
    }

    private static func connectResponses(sessionID: String) -> [MCPTransportResponse] {
        [
            jsonResponse(
                status: 200,
                headers: ["Mcp-Session-Id": sessionID],
                object: [
                    "jsonrpc": "2.0",
                    "id": "initialize",
                    "result": [
                        "protocolVersion": "2025-06-18",
                        "serverInfo": ["name": "Fixture MCP", "version": "2.0"],
                        "capabilities": ["tools": ["listChanged": true]],
                    ],
                ]
            ),
            MCPTransportResponse(statusCode: 202, headers: [:], body: Data()),
            jsonResponse(status: 200, object: [
                "jsonrpc": "2.0",
                "id": "tools",
                "result": [
                    "tools": [[
                        "name": "search records",
                        "description": "Search fixture records",
                        "inputSchema": [
                            "type": "object",
                            "properties": ["query": ["type": "string"]],
                            "required": ["query"],
                        ],
                    ]],
                ],
            ]),
        ]
    }

    private static func jsonResponse(
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

    private static func rpcMethod(in request: MCPTransportRequest) -> String? {
        guard let body = request.body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return object["method"] as? String
    }

    private static func rpcIdempotencyKey(in request: MCPTransportRequest) -> String? {
        guard let body = request.body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let params = object["params"] as? [String: Any],
              let metadata = params["_meta"] as? [String: Any] else { return nil }
        return metadata["com.straightupbrowser/idempotencyKey"] as? String
    }
}

@MainActor
private final class BrowserAgentMCPUnusedAuthorizationPresenter: BrowserAgentMCPAuthorizationPresenting {
    func prepareRedirectURI() async throws -> URL {
        try #require(URL(string: "http://127.0.0.1:49152/oauth/callback"))
    }

    func callbackURL(for authorizationURL: URL, redirectURI: URL) async throws -> URL {
        throw MCPConnectionError.authorizationDenied
    }

    func cancelAuthorization() {}
}

@MainActor
private final class BrowserAgentMCPSuccessAuthorizationPresenter: BrowserAgentMCPAuthorizationPresenting {
    private let code: String
    private(set) var authorizationURL: URL?

    init(code: String) {
        self.code = code
    }

    func prepareRedirectURI() async throws -> URL {
        try #require(URL(string: "http://127.0.0.1:49153/oauth/callback"))
    }

    func callbackURL(for authorizationURL: URL, redirectURI: URL) async throws -> URL {
        self.authorizationURL = authorizationURL
        let state = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "state" })?
            .value
        var callback = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)
        callback?.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = callback?.url else { throw MCPConnectionError.invalidRedirectURI }
        return url
    }

    func cancelAuthorization() {}
}

private actor BrowserAgentMCPQueueTransport: MCPTransport {
    private var queued: [MCPTransportResponse]
    private var captured: [MCPTransportRequest] = []

    init(_ responses: [MCPTransportResponse]) {
        queued = responses
    }

    func send(_ request: MCPTransportRequest) async throws -> MCPTransportResponse {
        captured.append(request)
        guard !queued.isEmpty else { throw MCPConnectionError.transportFailure }
        return queued.removeFirst()
    }

    func append(_ response: MCPTransportResponse) {
        queued.append(response)
    }

    func append(contentsOf responses: [MCPTransportResponse]) {
        queued.append(contentsOf: responses)
    }

    func requests() -> [MCPTransportRequest] { captured }
    func requestCount() -> Int { captured.count }
}
