import Foundation
import Testing
@testable import Browser

struct AgentScheduledTaskDependencyResolverTests {
    @Test func exactSavedScopeResolvesWithoutAddingAuthority() throws {
        let sessionID = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let mcpID = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
        let coworkID = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!
        let execution = fixtureExecution(
            session: .container(sessionID),
            mcpIDs: [mcpID],
            coworkID: coworkID
        )
        let resolved = try AgentScheduledTaskDependencyResolver.resolve(
            execution: execution,
            available: AgentScheduledTaskAvailableDependencies(
                providerIDsWithLocalAccess: ["OpenAI Responses", "unused-provider"],
                pagesByID: [
                    "window:page": AgentPageTarget(
                        pageID: "window:page",
                        origin: "https://saved.example",
                        session: .container(sessionID)
                    ),
                    "unused:page": AgentPageTarget(
                        pageID: "unused:page",
                        origin: "https://unused.example",
                        session: .normal
                    ),
                ],
                availableBrowserSessionIDs: [sessionID, UUID()],
                trustedMCPServerIdentitiesByConnectionID: [
                    mcpID: "https://mcp.example#trusted-v4",
                    UUID(): "https://unused-mcp.example#trusted-v1",
                ],
                coworkRootIdentitiesByBindingID: [
                    coworkID: "/saved/cowork",
                    UUID(): "/unused/cowork",
                ]
            )
        )

        #expect(resolved.mcpServerIdentities == ["https://mcp.example#trusted-v4"])
        #expect(resolved.coworkRootIdentity == "/saved/cowork")
        let run = execution.runConfiguration(
            toolCatalogVersion: 7,
            resolvedMCPServerIdentities: resolved.mcpServerIdentities,
            resolvedCoworkRootIdentity: resolved.coworkRootIdentity
        )
        #expect(run.configuration.provider == execution.provider)
        #expect(run.configuration.enabledCapabilities == execution.capabilities)
        #expect(run.scope.capabilities == execution.capabilities)
        #expect(run.scope.pageIDs == execution.browserScope.pageIDs)
        #expect(run.scope.origins == execution.browserScope.origins)
        #expect(run.scope.session == execution.browserScope.session)
        #expect(run.scope.mcpServerIdentities == resolved.mcpServerIdentities)
        #expect(run.scope.coworkRootIdentity == "/saved/cowork")
    }

    @Test func everyMissingOrChangedLiveDependencyFailsClosed() throws {
        let sessionID = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let mcpID = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
        let coworkID = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!
        let execution = fixtureExecution(
            session: .container(sessionID),
            mcpIDs: [mcpID],
            coworkID: coworkID
        )
        let page = AgentPageTarget(
            pageID: "window:page",
            origin: "https://saved.example",
            session: .container(sessionID)
        )
        let complete = AgentScheduledTaskAvailableDependencies(
            providerIDsWithLocalAccess: ["OpenAI Responses"],
            pagesByID: [page.pageID: page],
            availableBrowserSessionIDs: [sessionID],
            trustedMCPServerIdentitiesByConnectionID: [mcpID: "mcp-identity"],
            coworkRootIdentitiesByBindingID: [coworkID: "/cowork"]
        )

        var missingProvider = complete
        missingProvider.providerIDsWithLocalAccess = []
        #expect(throws: AgentScheduledTaskDependencyFailure.providerUnavailable(
            "OpenAI Responses"
        )) {
            try AgentScheduledTaskDependencyResolver.resolve(
                execution: execution,
                available: missingProvider
            )
        }

        var missingSession = complete
        missingSession.availableBrowserSessionIDs = []
        #expect(throws: AgentScheduledTaskDependencyFailure
            .browserSessionUnavailable(sessionID)) {
            try AgentScheduledTaskDependencyResolver.resolve(
                execution: execution,
                available: missingSession
            )
        }

        var missingPage = complete
        missingPage.pagesByID = [:]
        #expect(throws: AgentScheduledTaskDependencyFailure
            .pageUnavailable("window:page")) {
            try AgentScheduledTaskDependencyResolver.resolve(
                execution: execution,
                available: missingPage
            )
        }

        var changedPage = complete
        changedPage.pagesByID[page.pageID]?.origin = "https://changed.example"
        #expect(throws: AgentScheduledTaskDependencyFailure
            .pageOriginOutsideSavedScope("window:page")) {
            try AgentScheduledTaskDependencyResolver.resolve(
                execution: execution,
                available: changedPage
            )
        }

        var revokedMCP = complete
        revokedMCP.trustedMCPServerIdentitiesByConnectionID = [:]
        #expect(throws: AgentScheduledTaskDependencyFailure
            .mcpConnectionUnavailable(mcpID)) {
            try AgentScheduledTaskDependencyResolver.resolve(
                execution: execution,
                available: revokedMCP
            )
        }

        var revokedCowork = complete
        revokedCowork.coworkRootIdentitiesByBindingID = [:]
        #expect(throws: AgentScheduledTaskDependencyFailure
            .coworkBindingUnavailable(coworkID)) {
            try AgentScheduledTaskDependencyResolver.resolve(
                execution: execution,
                available: revokedCowork
            )
        }
    }

    private func fixtureExecution(
        session: AgentBrowserSession,
        mcpIDs: Set<UUID>,
        coworkID: UUID?
    ) -> AgentTaskExecutionSnapshot {
        AgentTaskExecutionSnapshot(
            provider: AgentProviderSnapshot(
                providerID: "OpenAI Responses",
                model: "saved-model",
                endpointIdentity: "https://api.openai.com/v1/responses",
                reportsUsage: true,
                supportsStreaming: true
            ),
            browserScope: AgentTaskBrowserScope(
                pageIDs: ["window:page"],
                origins: ["https://saved.example"],
                session: session
            ),
            capabilities: [.pageRead, .externalMCP, .coworkRead],
            mcpConnectionIDs: mcpIDs,
            coworkRootID: coworkID
        )
    }
}
