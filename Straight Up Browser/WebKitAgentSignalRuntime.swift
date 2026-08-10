import Foundation

nonisolated enum BrowserAgentWebKitSignalRuntimeError: Error, Equatable, Sendable {
    case inactiveScope(WebKitAgentSignalScope)
}

/// Run-scoped bridge between WebKit delegate callbacks and the bounded signal hub.
///
/// A tab is deliberately silent until an agent run activates a scope for it. This
/// keeps ordinary browsing out of the agent diagnostics path and gives run cleanup
/// one place to terminate subscriptions and discard incognito observations.
actor BrowserAgentWebKitSignalRuntime: WebKitAgentSignalEventSource {
    static let shared = BrowserAgentWebKitSignalRuntime(configuration: .init(
        privacy: .init(
            captureConsoleMessages: true,
            captureDialogText: true,
            captureSuggestedFilenames: true,
            captureErrorDescriptions: true,
            standardRetention: .metadataOnly
        )
    ))

    private let hub: WebKitAgentSignalHub
    private var scopesByTabID: [UUID: Set<WebKitAgentSignalScope>] = [:]
    private var consoleBridgeTokensByTabID: [UUID: String] = [:]

    init(configuration: WebKitAgentSignalHubConfiguration = .init()) {
        hub = WebKitAgentSignalHub(configuration: configuration)
    }

    var activeScopeCount: Int {
        scopesByTabID.values.reduce(0) { $0 + $1.count }
    }

    @discardableResult
    func activate(
        runID: UUID,
        page: PageHandle,
        browserSession: WebKitAgentSignalSession
    ) async throws -> WebKitAgentSignalScope {
        let scope = WebKitAgentSignalScope(
            runID: runID,
            page: page,
            browserSession: browserSession
        )
        // Snapshotting establishes the scope in the hub and enforces its limits and
        // browser-session binding before delegate callbacks can be routed to it.
        _ = try await hub.snapshot(in: scope)
        scopesByTabID[page.tabID, default: []].insert(scope)
        if consoleBridgeTokensByTabID[page.tabID] == nil {
            consoleBridgeTokensByTabID[page.tabID] = UUID().uuidString.lowercased()
        }
        return scope
    }

    func consoleBridgeToken(tabID: UUID) -> String? {
        guard scopesByTabID[tabID]?.isEmpty == false else { return nil }
        return consoleBridgeTokensByTabID[tabID]
    }

    /// Console messages have an additional per-tab activation token. A bridge
    /// left behind by a completed run is therefore logically inert even before
    /// WebKit destroys its document world on the next navigation.
    func publishConsole(_ message: WebKitAgentConsoleBridgeMessage, tabID: UUID) async {
        guard let expectedToken = consoleBridgeTokensByTabID[tabID],
              scopesByTabID[tabID]?.isEmpty == false,
              let draft = try? message.signalDraft(expectedToken: expectedToken) else {
            return
        }
        await publish(draft, tabID: tabID)
    }

    /// Publishes only to scopes that explicitly activated this tab. A delegate
    /// callback must never fail browsing because an observation buffer is full.
    func publish(_ draft: WebKitAgentSignalDraft, tabID: UUID) async {
        guard let scopes = scopesByTabID[tabID] else { return }
        for scope in scopes {
            _ = try? await hub.publish(draft, in: scope)
        }
    }

    func snapshot(
        in scope: WebKitAgentSignalScope,
        matching filter: WebKitAgentSignalFilter
    ) async throws -> WebKitAgentSignalSnapshot {
        try requireActive(scope)
        return try await hub.snapshot(in: scope, matching: filter)
    }

    func subscribe(
        to scope: WebKitAgentSignalScope,
        matching filter: WebKitAgentSignalFilter
    ) async throws -> WebKitAgentSignalSubscription {
        try requireActive(scope)
        return try await hub.subscribe(to: scope, matching: filter)
    }

    func observe(
        _ query: WebKitAgentObservationQuery,
        in scope: WebKitAgentSignalScope
    ) async throws -> WebKitAgentObservationResult {
        try requireActive(scope)
        return try await hub.observe(query, in: scope)
    }

    func wait(for request: WebKitAgentSignalWaitRequest) async throws -> WebKitAgentSignalEnvelope {
        try requireActive(request.scope)
        return try await WebKitAgentSignalWaiter(source: hub).wait(for: request)
    }

    private func requireActive(_ scope: WebKitAgentSignalScope) throws {
        guard scopesByTabID[scope.page.tabID]?.contains(scope) == true else {
            throw BrowserAgentWebKitSignalRuntimeError.inactiveScope(scope)
        }
    }

    func finish(_ scope: WebKitAgentSignalScope) async {
        await hub.finish(scope)
        scopesByTabID[scope.page.tabID]?.remove(scope)
        if scopesByTabID[scope.page.tabID]?.isEmpty == true {
            scopesByTabID.removeValue(forKey: scope.page.tabID)
            consoleBridgeTokensByTabID.removeValue(forKey: scope.page.tabID)
        }
    }

    func finishRun(_ runID: UUID) async {
        await hub.finishRun(runID)
        for tabID in Array(scopesByTabID.keys) {
            scopesByTabID[tabID] = scopesByTabID[tabID]?.filter { $0.runID != runID }
            if scopesByTabID[tabID]?.isEmpty == true {
                scopesByTabID.removeValue(forKey: tabID)
                consoleBridgeTokensByTabID.removeValue(forKey: tabID)
            }
        }
    }

    func pageClosed(tabID: UUID) async {
        await publish(
            .pageLifecycle(.init(phase: .closed, url: nil)),
            tabID: tabID
        )
        scopesByTabID.removeValue(forKey: tabID)
        consoleBridgeTokensByTabID.removeValue(forKey: tabID)
    }
}
