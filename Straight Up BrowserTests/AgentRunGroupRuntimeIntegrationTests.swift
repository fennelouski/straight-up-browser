import Foundation
import Testing
@testable import Browser

struct AgentRunGroupRuntimeIntegrationTests {
    @Test func delegationParserRequiresAnExactAuthorityAndBudgetSubset() throws {
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let parentAuthority = AgentDelegationAuthority(
            allowedTools: [
                "take_snapshot", "delegate_child_run", "inspect_run_group",
                "cancel_child_run",
            ],
            allowedPages: [page],
            allowedOrigins: ["https://example.com"],
            allowedBrowserSessions: [.normal]
        )
        let parentBudget = try AgentResourceBudget(
            maximumProviderCostMicrounits: 1_000_000,
            maximumElapsedMilliseconds: 60_000,
            maximumSteps: 20,
            maximumToolCalls: 10,
            maximumOutputBytes: 20_000,
            maximumChildCreatedPages: 2
        )
        let arguments = delegationArguments(
            page: page,
            maximumSteps: 10,
            allowedTools: ["take_snapshot"]
        )

        let contract = try AgentDelegationRequestParser.contract(
            arguments: arguments,
            childRunID: UUID(),
            parentRunID: UUID(),
            runGroupID: UUID(),
            depth: 1,
            parentAuthority: parentAuthority,
            parentBudget: parentBudget
        )

        #expect(contract.objective == "Inspect the account")
        #expect(contract.authority.allowedTools == ["take_snapshot"])
        #expect(contract.authority.allowedPages == [page])
        #expect(contract.authority.allowedOrigins == ["https://example.com"])
        #expect(contract.authority.allowedBrowserSessions == [.normal])
        #expect(contract.budget.maximumSteps == 10)
        #expect(contract.returnSchema.validationErrors(for: .object([
            "summary": .string("done"),
        ])).isEmpty)

        var escalatedTools = arguments
        escalatedTools["allowedTools"] = ["delete_history_url"]
        #expect(throws: AgentRunGroupError.authorityEscalation("allowedTools")) {
            try AgentDelegationRequestParser.contract(
                arguments: escalatedTools,
                parentRunID: UUID(),
                runGroupID: UUID(),
                depth: 1,
                parentAuthority: parentAuthority,
                parentBudget: parentBudget
            )
        }

        var escalatedBudget = arguments
        var budget = try #require(escalatedBudget["budget"] as? [String: Any])
        budget["maximumSteps"] = 21
        escalatedBudget["budget"] = budget
        #expect(throws: AgentRunGroupError.budgetEscalation("steps")) {
            try AgentDelegationRequestParser.contract(
                arguments: escalatedBudget,
                parentRunID: UUID(),
                runGroupID: UUID(),
                depth: 1,
                parentAuthority: parentAuthority,
                parentBudget: parentBudget
            )
        }
    }

    @Test func delegationParserRejectsUnsupportedOrUnboundedReturnSchemas() throws {
        let authority = AgentDelegationAuthority(
            allowedTools: [],
            allowedBrowserSessions: [.normal]
        )
        let budget = try AgentResourceBudget(
            maximumProviderCostMicrounits: 100,
            maximumElapsedMilliseconds: 1_000,
            maximumSteps: 2,
            maximumToolCalls: 0,
            maximumOutputBytes: 100,
            maximumChildCreatedPages: 0
        )
        var arguments = delegationArguments(
            page: nil,
            maximumSteps: 1,
            allowedTools: []
        )
        arguments["returnSchema"] = [
            "type": "object",
            "properties": [:],
            "oneOf": [],
        ] as [String: Any]

        #expect(throws: AgentDelegationRuntimeError.invalidReturnSchema(
            "unsupported keyword oneOf"
        )) {
            try AgentDelegationRequestParser.contract(
                arguments: arguments,
                parentRunID: UUID(),
                runGroupID: UUID(),
                depth: 1,
                parentAuthority: authority,
                parentBudget: budget
            )
        }
    }

    @Test func delegatedExternalToolsUseTheInjectedRuntimeCatalog() async throws {
        var external = try #require(
            AgentToolCatalog.canonical.descriptor(named: "take_snapshot")
        )
        external.name = "app_fixture_lookup"
        external.description = "Look up a fixture through a trusted MCP server."
        external.inputSchema = .object(["query": .string()], required: ["query"])
        external.outputSchema = .object([:], additionalProperties: true)
        external.requiredCapabilities = [.externalMCP]
        external.risk = .externalEffect
        external.origin = .mcp
        external.route = .dynamicMCP
        external.visibility = [.builtInAgent]
        let catalog = AgentToolCatalog(
            descriptors: AgentToolCatalog.canonical.allDescriptors + [external],
            aliases: AgentToolCatalog.canonical.aliases
        )
        try catalog.validate()

        let parentRunID = UUID()
        let authority = AgentDelegationAuthority(
            allowedTools: [external.name],
            allowedBrowserSessions: [.normal],
            mcpServerIdentities: ["fixture-server"],
            permitsDataEgress: true
        )
        let budget = try AgentResourceBudget(
            maximumProviderCostMicrounits: 1_000_000,
            maximumElapsedMilliseconds: 60_000,
            maximumSteps: 20,
            maximumToolCalls: 10,
            maximumOutputBytes: 20_000,
            maximumChildCreatedPages: 0
        )
        let group = try AgentRunGroup(
            rootRunID: parentRunID,
            objective: "Root",
            authority: authority,
            budget: budget,
            maximumDepth: 2,
            maximumFanOut: 2,
            failurePolicy: .continueIndependent,
            cleanupPolicy: .secureDefault,
            catalog: catalog
        )
        let coordinator = AgentRunGroupCoordinator(
            group: group,
            validationCatalog: catalog
        )
        let contract = try AgentDelegationRequestParser.contract(
            arguments: delegationArguments(
                page: nil,
                maximumSteps: 10,
                allowedTools: [external.name]
            ),
            parentRunID: parentRunID,
            runGroupID: group.id,
            depth: 1,
            parentAuthority: authority,
            parentBudget: budget,
            catalog: catalog
        )
        try await coordinator.registerChild(contract)

        #expect(contract.authority.allowedTools == [external.name])
        #expect(contract.authority.mcpServerIdentities == ["fixture-server"])
        #expect(contract.authority.permitsDataEgress)
        #expect(await coordinator.child(contract.childRunID) != nil)

        var unknownArguments = delegationArguments(
            page: nil,
            maximumSteps: 10,
            allowedTools: ["app_missing"]
        )
        unknownArguments["allowedTools"] = ["app_missing"]
        let unknownAuthority = AgentDelegationAuthority(
            allowedTools: ["app_missing"],
            allowedBrowserSessions: [.normal],
            mcpServerIdentities: ["fixture-server"],
            permitsDataEgress: true
        )
        #expect(throws: AgentRunGroupError.unknownTool("app_missing")) {
            try AgentDelegationRequestParser.contract(
                arguments: unknownArguments,
                parentRunID: parentRunID,
                runGroupID: group.id,
                depth: 1,
                parentAuthority: unknownAuthority,
                parentBudget: budget,
                catalog: catalog
            )
        }
    }

    @Test func treeProjectionIsParentFirstAndUUIDDeterministic() async throws {
        let rootID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let authority = AgentDelegationAuthority(
            allowedTools: [],
            allowedBrowserSessions: [.normal]
        )
        let budget = try AgentResourceBudget(
            maximumProviderCostMicrounits: 1_000,
            maximumElapsedMilliseconds: 60_000,
            maximumSteps: 20,
            maximumToolCalls: 10,
            maximumOutputBytes: 20_000,
            maximumChildCreatedPages: 0
        )
        let group = try AgentRunGroup(
            rootRunID: rootID,
            objective: "Root objective",
            authority: authority,
            budget: budget,
            maximumDepth: 2,
            maximumFanOut: 4,
            failurePolicy: .continueIndependent,
            cleanupPolicy: .secureDefault
        )
        let coordinator = AgentRunGroupCoordinator(group: group)
        for (id, objective) in [(secondID, "Second"), (firstID, "First")] {
            let contract = try AgentChildRunContract(
                childRunID: id,
                parentRunID: rootID,
                runGroupID: group.id,
                depth: 1,
                objective: objective,
                authority: authority,
                budget: budget,
                returnSchema: .object(["summary": .string()], required: ["summary"]),
                validatingAgainst: authority,
                parentBudget: budget
            )
            try await coordinator.registerChild(contract)
        }

        let rows = AgentRunGroupTreeProjector.rows(from: await coordinator.snapshot())
        #expect(rows.map(\.id) == [rootID, firstID, secondID])
        #expect(rows.map(\.depth) == [0, 1, 1])
        #expect(rows.first?.isRoot == true)
    }

    @Test func cancellationHandleClosesCancelBeforeInstallRace() async {
        let handle = AgentChildTaskHandle()
        let recorder = CancellationFlag()
        handle.cancel()
        let task = Task {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                await recorder.markCancelled()
            }
        }
        handle.install(task)
        await handle.wait()
        #expect(await recorder.cancelled)
    }

    @Test func scheduledLimitsUseTheSmallerGlobalOrTaskCeiling() throws {
        let global = try AgentExecutionLimits(
            maximumTurns: 10,
            maximumToolCalls: 5,
            maximumElapsedMilliseconds: 30_000,
            maximumProviderTokens: 500,
            maximumProviderCostMicrounits: 1_000,
            maximumOpenPages: 4,
            maximumModelResultBytes: 1_000,
            maximumDownloads: 7,
            maximumDownloadBytes: 8_000,
            maximumArtifacts: 8,
            maximumArtifactBytes: 1_000
        )
        let task = AgentTaskBudgets(
            maximumModelTurns: 3,
            maximumToolCalls: 9,
            maximumOutputBytes: 2_000,
            maximumOpenBackgroundPages: 2,
            maximumArtifactBytes: 400,
            maximumProviderCostMicrounits: 500,
            maximumProviderTokens: 300,
            maximumDownloads: 3,
            maximumDownloadBytes: 4_000,
            maximumArtifacts: 4
        )

        let limits = try AgentScheduledExecutionLimits.resolve(
            budgets: task,
            timeoutSeconds: 60,
            global: global
        )
        #expect(limits.maximumTurns == 3)
        #expect(limits.maximumToolCalls == 5)
        #expect(limits.maximumElapsedMilliseconds == 30_000)
        #expect(limits.maximumProviderTokens == 300)
        #expect(limits.maximumProviderCostMicrounits == 500)
        #expect(limits.maximumOpenPages == 2)
        #expect(limits.maximumModelResultBytes == 1_000)
        #expect(limits.maximumDownloads == 3)
        #expect(limits.maximumDownloadBytes == 4_000)
        #expect(limits.maximumArtifacts == 4)
        #expect(limits.maximumArtifactBytes == 400)

        let raisedGlobals = try AgentExecutionLimits(
            maximumTurns: 100,
            maximumToolCalls: 100,
            maximumElapsedMilliseconds: 600_000,
            maximumProviderTokens: 50_000,
            maximumProviderCostMicrounits: 50_000,
            maximumOpenPages: 100,
            maximumModelResultBytes: 50_000,
            maximumDownloads: 100,
            maximumDownloadBytes: 50_000,
            maximumArtifacts: 100,
            maximumArtifactBytes: 50_000
        )
        let afterGlobalChange = try AgentScheduledExecutionLimits.resolve(
            budgets: task,
            timeoutSeconds: 60,
            global: raisedGlobals
        )
        #expect(afterGlobalChange.maximumTurns == 3)
        #expect(afterGlobalChange.maximumToolCalls == 9)
        #expect(afterGlobalChange.maximumProviderTokens == 300)
        #expect(afterGlobalChange.maximumProviderCostMicrounits == 500)
        #expect(afterGlobalChange.maximumOpenPages == 2)
        #expect(afterGlobalChange.maximumModelResultBytes == 2_000)
        #expect(afterGlobalChange.maximumDownloads == 3)
        #expect(afterGlobalChange.maximumDownloadBytes == 4_000)
        #expect(afterGlobalChange.maximumArtifacts == 4)
        #expect(afterGlobalChange.maximumArtifactBytes == 400)
    }
}

@MainActor
struct BrowserAgentRunGroupEndToEndTests {

    @Test func scheduledRootPageIsForcedHiddenAndClosedByOwnershipCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-agent-scheduled-page-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentRunStore(baseDirectory: directory)
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let allowedURL = "https://allowed.example/report"
        let runID = UUID()
        let arguments: JSONValue = .object([
            "url": .string(allowedURL),
            "incognito": .boolean(false),
        ])
        let scope = try scheduledPageScope(
            runID: runID,
            tool: "new_page",
            arguments: arguments,
            allowedOrigin: "https://allowed.example"
        )
        let adapter = PageAuthorityRouterAdapter(
            scenario: .scheduledCreation(url: allowedURL)
        )
        let executor = PageAuthorityExecutor(pageID: page.description)
        let agent = BrowserAgent(
            storageDirectory: directory,
            runStore: store,
            providerAdapterFactory: { _ in adapter }
        )

        agent.submit(
            "Open the saved report scope",
            pageTitle: "Scheduled",
            pageURL: "",
            configuration: try pageAuthorityConfiguration(),
            entryPoint: .scheduled,
            preassignedRunID: runID,
            runScopeOverride: scope,
            resolvePageAuthority: { pageIDs in
                await executor.resolve(pageIDs: pageIDs)
            },
            execute: { tool, arguments, _, _ in
                await executor.execute(
                    tool: tool,
                    url: arguments["url"] as? String,
                    background: arguments["background"] as? Bool
                )
            }
        )
        await waitForAgent(agent)

        #expect(agent.activeRunStatus == .succeeded)
        #expect(await executor.toolNames == ["new_page", "close_page"])
        #expect(await executor.firstBackgroundValue == true)
    }

    @Test func scheduledRunRegistersAndDispatchesEverySavedPage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-agent-scheduled-saved-pages-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentRunStore(baseDirectory: directory)
        let snapshots = [
            BrowserAutomationPageAuthoritySnapshot(
                target: AgentPageTarget(
                    pageID: PageHandle(windowID: UUID(), tabID: UUID()).description,
                    origin: "https://one.example",
                    session: .normal
                ),
                document: PageDocumentGeneration(rawValue: UUID())
            ),
            BrowserAutomationPageAuthoritySnapshot(
                target: AgentPageTarget(
                    pageID: PageHandle(windowID: UUID(), tabID: UUID()).description,
                    origin: "https://two.example",
                    session: .normal
                ),
                document: PageDocumentGeneration(rawValue: UUID())
            ),
        ]
        let descriptor = try #require(
            AgentToolCatalog.canonical.descriptor(named: "take_snapshot")
        )
        let scope = AgentRunScope(
            capabilities: descriptor.requiredCapabilities,
            pageIDs: Set(snapshots.map(\.target.pageID)),
            origins: Set(snapshots.map(\.target.origin)),
            session: .normal
        )
        let host = RevalidatingPageAuthorityHost(snapshots: snapshots)
        let adapter = PageAuthorityRouterAdapter(
            scenario: .observeSavedPages(snapshots.map(\.target.pageID))
        )
        let agent = BrowserAgent(
            storageDirectory: directory,
            runStore: store,
            providerAdapterFactory: { _ in adapter }
        )

        agent.submit(
            "Inspect every saved Page",
            pageTitle: "Scheduled",
            pageURL: "",
            configuration: try pageAuthorityConfiguration(),
            entryPoint: .scheduled,
            preassignedRunID: UUID(),
            runScopeOverride: scope,
            resolvePageAuthority: { pageIDs in
                await host.resolve(pageIDs: pageIDs)
            },
            execute: { tool, arguments, _, bindings in
                let arguments = UnsafePageToolArguments(arguments)
                return await host.execute(
                    tool: tool,
                    arguments: arguments,
                    bindings: bindings
                )
            }
        )
        await waitForAgent(agent)

        #expect(agent.activeRunStatus == .succeeded)
        #expect(await host.effectPageIDs == snapshots.map(\.target.pageID))
    }

    @Test func sameURLReloadDuringApprovalCannotReachThePageEffect() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-agent-approval-reload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentRunStore(baseDirectory: directory)
        let snapshot = BrowserAutomationPageAuthoritySnapshot(
            target: AgentPageTarget(
                pageID: PageHandle(windowID: UUID(), tabID: UUID()).description,
                origin: "https://approval.example",
                session: .normal
            ),
            document: PageDocumentGeneration(rawValue: UUID())
        )
        let host = RevalidatingPageAuthorityHost(snapshots: [snapshot])
        let adapter = PageAuthorityRouterAdapter(
            scenario: .clickPage(snapshot.target.pageID)
        )
        let agent = BrowserAgent(
            storageDirectory: directory,
            runStore: store,
            providerAdapterFactory: { _ in adapter }
        )

        agent.submit(
            "Click the saved control",
            pageTitle: "Approval",
            pageURL: "https://approval.example/path",
            configuration: try pageAuthorityConfiguration(),
            initialPage: snapshot.target,
            resolvePageAuthority: { pageIDs in
                await host.resolve(pageIDs: pageIDs)
            },
            execute: { tool, arguments, _, bindings in
                let arguments = UnsafePageToolArguments(arguments)
                return await host.execute(
                    tool: tool,
                    arguments: arguments,
                    bindings: bindings
                )
            }
        )
        // A deadline rather than a fixed 300 × 10ms budget. Three seconds is
        // plenty when this test runs alone, and not enough under a loaded full
        // suite or TSan — which is exactly when it was observed failing here on
        // `pendingApproval` still being nil. Matches waitForAgent's 20s wait.
        let approvalClock = ContinuousClock()
        let approvalDeadline = approvalClock.now.advanced(by: .seconds(20))
        while agent.pendingApproval == nil, approvalClock.now < approvalDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        _ = try #require(
            agent.pendingApproval,
            "Agent status: \(String(describing: agent.activeRunStatus)); messages: \(agent.messages.map(\.text))"
        )
        await host.reloadSameURL(pageID: snapshot.target.pageID)
        agent.approvePendingInvocation(scope: .allowOnce)
        await waitForAgent(agent)

        #expect(await host.attemptCount == 1)
        #expect(await host.effectPageIDs.isEmpty)
    }

    @Test func scheduledPageCreationCannotEscapeSavedOriginScope() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-agent-scheduled-escape-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentRunStore(baseDirectory: directory)
        let runID = UUID()
        let escapedURL = "https://escaped.example/report"
        let arguments: JSONValue = .object([
            "url": .string(escapedURL),
            "incognito": .boolean(false),
        ])
        let scope = try scheduledPageScope(
            runID: runID,
            tool: "new_hidden_page",
            arguments: arguments,
            allowedOrigin: "https://allowed.example"
        )
        let adapter = PageAuthorityRouterAdapter(
            scenario: .scheduledEscape(url: escapedURL)
        )
        let executor = PageAuthorityExecutor(
            pageID: PageHandle(windowID: UUID(), tabID: UUID()).description
        )
        let agent = BrowserAgent(
            storageDirectory: directory,
            runStore: store,
            providerAdapterFactory: { _ in adapter }
        )

        agent.submit(
            "Try an out-of-scope destination",
            pageTitle: "Scheduled",
            pageURL: "",
            configuration: try pageAuthorityConfiguration(),
            entryPoint: .scheduled,
            preassignedRunID: runID,
            runScopeOverride: scope,
            execute: { tool, arguments, _, _ in
                await executor.execute(
                    tool: tool,
                    url: arguments["url"] as? String,
                    background: arguments["background"] as? Bool
                )
            }
        )
        await waitForAgent(agent)

        #expect(agent.activeRunStatus == .succeeded)
        #expect(await executor.toolNames.isEmpty)
    }

    @Test func unregisteredPageIDNeverReachesTheBrowserExecutor() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-agent-unregistered-page-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentRunStore(baseDirectory: directory)
        let unregistered = PageHandle(windowID: UUID(), tabID: UUID())
        let adapter = PageAuthorityRouterAdapter(
            scenario: .unregisteredSnapshot(pageID: unregistered.description)
        )
        let executor = PageAuthorityExecutor(pageID: unregistered.description)
        let agent = BrowserAgent(
            storageDirectory: directory,
            runStore: store,
            providerAdapterFactory: { _ in adapter }
        )

        agent.submit(
            "Inspect an unregistered Page",
            pageTitle: "Test",
            pageURL: "",
            configuration: try pageAuthorityConfiguration(),
            execute: { tool, arguments, _, _ in
                await executor.execute(
                    tool: tool,
                    url: arguments["url"] as? String,
                    background: arguments["background"] as? Bool
                )
            }
        )
        await waitForAgent(agent)

        #expect(agent.activeRunStatus == .succeeded)
        #expect(await executor.toolNames.isEmpty)
        let run = try #require(await store.listRuns().first)
        let steps = try await store.steps(runID: run.id)
        #expect(steps.contains {
            $0.kind == .policyDecision
                && $0.summary.contains("targetOutsideRunScope")
        })
    }

    private func waitForAgent(
        _ agent: BrowserAgent,
        approvingPendingInvocations: Bool = false
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while agent.isRunning, clock.now < deadline {
            if approvingPendingInvocations, agent.pendingApproval != nil {
                agent.approvePendingInvocation(scope: .allowOnce)
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func pageAuthorityConfiguration() throws -> BrowserAgentConfiguration {
        BrowserAgentConfiguration(
            provider: .compatible,
            endpoint: "https://provider.example/v1/chat/completions",
            model: "fixture",
            apiKey: "fixture",
            pricing: try AgentProviderPricingMetadata(
                source: .userConfigured,
                currencyCode: "USD",
                inputMicrounitsPerMillionTokens: 0,
                outputMicrounitsPerMillionTokens: 0
            )
        )
    }

    private func scheduledPageScope(
        runID: UUID,
        tool: String,
        arguments: JSONValue,
        allowedOrigin: String
    ) throws -> AgentRunScope {
        let descriptor = try #require(
            AgentToolCatalog.canonical.descriptor(named: tool)
        )
        var scope = AgentRunScope(
            capabilities: [.browserControl],
            origins: [allowedOrigin],
            session: .normal
        )
        let context = AgentInvocationContext(
            runID: runID,
            entryPoint: .scheduled,
            humanPresent: false,
            toolName: tool,
            arguments: arguments,
            target: .none,
            runScope: scope
        )
        scope.preauthorizedScheduledEffects.insert(
            try AgentInvocationDigest.make(descriptor: descriptor, context: context)
        )
        return scope
    }
}

private func delegationArguments(
    page: PageHandle?,
    maximumSteps: Int,
    allowedTools: [String]
) -> [String: Any] {
    [
        "objective": "Inspect the account",
        "allowedTools": allowedTools,
        "allowedPages": page.map { [$0.description] } ?? [],
        "allowedOrigins": page == nil ? [] : ["https://example.com"],
        "browserSession": "normal",
        "returnSchema": [
            "type": "object",
            "properties": [
                "summary": ["type": "string"],
            ],
            "required": ["summary"],
            "additionalProperties": false,
        ] as [String: Any],
        "budget": [
            "maximumProviderCostMicrounits": 500_000,
            "maximumElapsedMilliseconds": 30_000,
            "maximumSteps": maximumSteps,
            "maximumToolCalls": 0,
            "maximumOutputBytes": 10_000,
            "maximumChildCreatedPages": 0,
        ],
    ]
}

private actor CancellationFlag {
    private(set) var cancelled = false
    func markCancelled() { cancelled = true }
}

private final class PageAuthorityRouterAdapter: AgentProviderAdapter, @unchecked Sendable {
    enum Scenario: Sendable {
        case attendedLifecycle(pageID: String, firstURL: String, secondURL: String)
        case scheduledCreation(url: String)
        case scheduledEscape(url: String)
        case unregisteredSnapshot(pageID: String)
        case observeSavedPages([String])
        case clickPage(String)
    }

    let providerID = "page-authority-router"
    let capabilities = AgentProviderCapabilities(Set(AgentProviderCapability.allCases))
    private let scenario: Scenario

    init(scenario: Scenario) {
        self.scenario = scenario
    }

    func events(
        for request: AgentModelRequest
    ) throws -> AsyncThrowingStream<AgentModelEvent, Error> {
        try validateCapabilities(for: request)
        let resultCount = Self.toolResultCount(request)
        switch scenario {
        case .attendedLifecycle(let pageID, let firstURL, let secondURL):
            switch resultCount {
            case 0:
                return Self.toolCall(
                    id: "new-page",
                    name: "new_page",
                    arguments: .object([
                        "url": .string(firstURL),
                        "incognito": .boolean(false),
                    ])
                )
            case 1:
                return Self.toolCall(
                    id: "first-snapshot",
                    name: "take_snapshot",
                    arguments: .object(["pageId": .string(pageID)])
                )
            case 2:
                return Self.toolCall(
                    id: "navigate",
                    name: "navigate_page",
                    arguments: .object([
                        "pageId": .string(pageID),
                        "url": .string(secondURL),
                    ])
                )
            case 3:
                return Self.toolCall(
                    id: "second-snapshot",
                    name: "take_snapshot",
                    arguments: .object(["pageId": .string(pageID)])
                )
            default:
                return Self.text("Attended Page lifecycle complete")
            }
        case .scheduledCreation(let url):
            guard resultCount == 0 else { return Self.text("Scheduled Page complete") }
            return Self.toolCall(
                id: "scheduled-page",
                name: "new_page",
                arguments: .object([
                    "url": .string(url),
                    "incognito": .boolean(false),
                ])
            )
        case .scheduledEscape(let url):
            guard resultCount == 0 else { return Self.text("Escape was denied") }
            return Self.toolCall(
                id: "scheduled-escape",
                name: "new_hidden_page",
                arguments: .object([
                    "url": .string(url),
                    "incognito": .boolean(false),
                ])
            )
        case .unregisteredSnapshot(let pageID):
            guard resultCount == 0 else { return Self.text("Unregistered Page was denied") }
            return Self.toolCall(
                id: "unregistered",
                name: "take_snapshot",
                arguments: .object(["pageId": .string(pageID)])
            )
        case .observeSavedPages(let pageIDs):
            guard resultCount < pageIDs.count else {
                return Self.text("Every saved Page was inspected")
            }
            return Self.toolCall(
                id: "saved-page-\(resultCount)",
                name: "take_snapshot",
                arguments: .object([
                    "pageId": .string(pageIDs[resultCount]),
                ])
            )
        case .clickPage(let pageID):
            guard resultCount == 0 else {
                return Self.text("Reloaded Page effect remained denied")
            }
            return Self.toolCall(
                id: "approved-click",
                name: "click",
                arguments: .object([
                    "pageId": .string(pageID),
                    "selector": .string("#submit"),
                ])
            )
        }
    }

    private static func toolCall(
        id: String,
        name: String,
        arguments: JSONValue
    ) -> AsyncThrowingStream<AgentModelEvent, Error> {
        let call = AgentToolCall(id: id, index: 0, name: name)
        return stream([
            .toolCallStarted(call),
            .toolCallCompleted(call: call, arguments: .valid(arguments)),
            .usage(.reported(
                inputTokens: 1,
                outputTokens: 1,
                totalTokens: 2,
                cachedInputTokens: nil
            )),
            .finished(.toolCalls),
        ])
    }

    private static func text(
        _ value: String
    ) -> AsyncThrowingStream<AgentModelEvent, Error> {
        stream([
            .textDelta(value),
            .usage(.reported(
                inputTokens: 1,
                outputTokens: 1,
                totalTokens: 2,
                cachedInputTokens: nil
            )),
            .finished(.stop),
        ])
    }

    private static func stream(
        _ events: [AgentModelEvent]
    ) -> AsyncThrowingStream<AgentModelEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    private static func toolResultCount(_ request: AgentModelRequest) -> Int {
        request.messages.flatMap(\.content).reduce(into: 0) { count, part in
            if case .toolResult = part { count += 1 }
        }
    }
}

private actor PageAuthorityExecutor {
    private struct Call: Sendable {
        let tool: String
        let background: Bool?
    }

    private let pageID: String
    private var calls: [Call] = []
    private var currentURL: String?
    private var document = PageDocumentGeneration(rawValue: UUID())

    init(pageID: String) {
        self.pageID = pageID
    }

    var toolNames: [String] { calls.map(\.tool) }
    var firstBackgroundValue: Bool? { calls.first?.background }

    func resolve(
        pageIDs: [String]
    ) -> [BrowserAutomationPageAuthoritySnapshot]? {
        guard pageIDs == [pageID],
              let currentURL,
              let components = URLComponents(string: currentURL),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        return [BrowserAutomationPageAuthoritySnapshot(
            target: AgentPageTarget(
                pageID: pageID,
                origin: "\(scheme)://\(host)\(port)",
                session: .normal
            ),
            document: document
        )]
    }

    func execute(tool: String, url: String?, background: Bool?) -> String {
        calls.append(Call(tool: tool, background: background))
        switch tool {
        case "new_page", "new_hidden_page", "navigate_page", "show_page":
            currentURL = url ?? "https://allowed.example/report"
            document = PageDocumentGeneration(rawValue: UUID())
            return Self.json([
                "ok": true,
                "page": [
                    "pageId": pageID,
                    "url": currentURL ?? "https://allowed.example/report",
                    "sessionKind": "normal",
                ],
            ])
        case "take_snapshot":
            return Self.json(["ok": true, "snapshot": "document"])
        case "close_page":
            currentURL = nil
            return Self.json(["ok": true])
        default:
            return Self.json(["error": "unexpected tool \(tool)"])
        }
    }

    private static func json(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys]
        ) else { return "{\"error\":\"encoding failed\"}" }
        return String(data: data, encoding: .utf8) ?? "{\"error\":\"encoding failed\"}"
    }
}

private nonisolated struct UnsafePageToolArguments: @unchecked Sendable {
    let value: [String: Any]

    init(_ value: [String: Any]) {
        self.value = value
    }
}

private actor RevalidatingPageAuthorityHost {
    private var snapshotsByPageID: [String: BrowserAutomationPageAuthoritySnapshot]
    private(set) var effectPageIDs: [String] = []
    private(set) var attemptCount = 0

    init(snapshots: [BrowserAutomationPageAuthoritySnapshot]) {
        snapshotsByPageID = Dictionary(uniqueKeysWithValues: snapshots.map {
            ($0.target.pageID, $0)
        })
    }

    func resolve(
        pageIDs: [String]
    ) -> [BrowserAutomationPageAuthoritySnapshot]? {
        guard !pageIDs.isEmpty, Set(pageIDs).count == pageIDs.count else {
            return nil
        }
        var snapshots: [BrowserAutomationPageAuthoritySnapshot] = []
        for pageID in pageIDs {
            guard let snapshot = snapshotsByPageID[pageID] else { return nil }
            snapshots.append(snapshot)
        }
        return snapshots
    }

    func reloadSameURL(pageID: String) {
        guard let snapshot = snapshotsByPageID[pageID] else { return }
        snapshotsByPageID[pageID] = BrowserAutomationPageAuthoritySnapshot(
            target: snapshot.target,
            document: PageDocumentGeneration(rawValue: UUID())
        )
    }

    func execute(
        tool: String,
        arguments: UnsafePageToolArguments,
        bindings: [BrowserAutomationPageDispatchBinding]
    ) -> String {
        attemptCount += 1
        let arguments = arguments.value
        guard let pageID = arguments["pageId"] as? String,
              let authorized = bindings.first,
              bindings.count == 1,
              authorized.target.pageID == pageID,
              let live = snapshotsByPageID[pageID] else {
            return "{\"error\":\"missing Page authority\"}"
        }
        do {
            try authorized.validate(
                live: BrowserAutomationPageDispatchBinding(
                    target: live.target,
                    version: AgentPageLeaseVersion(
                        navigation: authorized.version.navigation,
                        document: live.document
                    )
                ),
                allowIncognito: true
            )
        } catch {
            return "{\"error\":\"authorized Page changed before dispatch\"}"
        }
        guard tool == "take_snapshot" || tool == "click" else {
            return "{\"error\":\"unexpected tool\"}"
        }
        effectPageIDs.append(pageID)
        return "{\"ok\":true}"
    }
}
