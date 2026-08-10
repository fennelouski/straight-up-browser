import AppKit
import Foundation
import Testing
@testable import Browser

@Suite("Browser CLI invocation lifecycle")
struct BrowserCLIInvocationTests {
    @Test("Replay encoding never returns bytes above the persistence cap")
    @MainActor
    func replayFrameEncodingIsBoundedBeforeMetering() throws {
        let representation = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.addRepresentation(representation)

        #expect(AgentReplayFrameEncoder.encode(image, maximumBytes: 1) == nil)
        let retained = try #require(AgentReplayFrameEncoder.encode(image))
        #expect(retained.data.count <= AgentRunStore.maximumReplayFrameBytes)
        #expect(retained.contentType == "image/png" || retained.contentType == "image/jpeg")
    }

    @Test("Mixed page and window listings omit every incognito page field")
    func mixedSessionListingsArePrivacyFiltered() throws {
        let normal: [String: Any] = [
            "pageId": "window:normal",
            "title": "Public title",
            "url": "https://public.example/path",
            "sessionKind": "normal",
            "incognito": false,
        ]
        let incognito: [String: Any] = [
            "pageId": "window:private",
            "title": "Secret title",
            "url": "https://private.example/secret",
            "sessionKind": "incognito",
            "incognito": true,
        ]

        let visible = BrowserAutomationRegistry.externallyVisiblePageSummaries([
            normal, incognito,
        ])
        #expect(visible.count == 1)
        #expect(visible.first?["pageId"] as? String == "window:normal")
        let visibleText = String(
            decoding: try JSONSerialization.data(withJSONObject: visible),
            as: UTF8.self
        )
        #expect(!visibleText.contains("Secret title"))
        #expect(!visibleText.contains("private.example"))
        #expect(!visibleText.contains("incognito"))

        let window = try #require(BrowserAutomationRegistry
            .externallyVisibleWindowSummary(
                ["windowId": "window", "title": "Private page title", "pageCount": 2],
                pages: [normal, incognito]
            ))
        #expect(window["title"] as? String == "Browser")
        #expect(window["pageCount"] as? Int == 1)
        #expect(BrowserAutomationRegistry.externallyVisibleWindowSummary(
            ["windowId": "private-window", "title": "Secret"],
            pages: [incognito]
        ) == nil)
    }

    @Test("Local MCP Page binding fails closed for stale, private, or changed targets")
    func pageDispatchBindingIsRevalidatedImmediatelyBeforeDispatch() throws {
        let pageID = "00000000-0000-0000-0000-000000000001:00000000-0000-0000-0000-000000000002"
        let version = AgentPageLeaseVersion(
            navigation: PageNavigationGeneration(rawValue: 4),
            document: PageDocumentGeneration(rawValue: UUID())
        )
        let expected = BrowserAutomationPageDispatchBinding(
            target: AgentPageTarget(
                pageID: pageID,
                origin: "https://example.com",
                session: .normal
            ),
            version: version
        )
        try expected.validate(live: expected)

        #expect(throws: BrowserAutomationPageBindingError.missingOrStaleTarget) {
            try expected.validate(live: nil)
        }
        #expect(throws: BrowserAutomationPageBindingError.pageMismatch) {
            try expected.validate(live: BrowserAutomationPageDispatchBinding(
                target: AgentPageTarget(
                    pageID: "00000000-0000-0000-0000-000000000003:00000000-0000-0000-0000-000000000004",
                    origin: "https://example.com",
                    session: .normal
                ),
                version: version
            ))
        }
        #expect(throws: BrowserAutomationPageBindingError.sessionMismatch) {
            try expected.validate(live: BrowserAutomationPageDispatchBinding(
                target: AgentPageTarget(
                    pageID: pageID,
                    origin: "https://example.com",
                    session: .container(UUID())
                ),
                version: version
            ))
        }
        #expect(throws: BrowserAutomationPageBindingError.originMismatch) {
            try expected.validate(live: BrowserAutomationPageDispatchBinding(
                target: AgentPageTarget(
                    pageID: pageID,
                    origin: "https://other.example",
                    session: .normal
                ),
                version: version
            ))
        }
        #expect(throws: BrowserAutomationPageBindingError.versionMismatch) {
            try expected.validate(live: BrowserAutomationPageDispatchBinding(
                target: expected.target,
                version: AgentPageLeaseVersion(
                    navigation: version.navigation.advanced(),
                    document: PageDocumentGeneration(rawValue: UUID())
                )
            ))
        }
        #expect(throws: BrowserAutomationPageBindingError.versionMismatch) {
            // A reload may preserve URL, origin, PageHandle, and the history
            // index. The isolated-world document token must still invalidate
            // the permit before dispatch.
            try expected.validate(live: BrowserAutomationPageDispatchBinding(
                target: expected.target,
                version: AgentPageLeaseVersion(
                    navigation: version.navigation,
                    document: PageDocumentGeneration(rawValue: UUID())
                )
            ))
        }
        #expect(throws: BrowserAutomationPageBindingError.incognitoDenied) {
            let privateBinding = BrowserAutomationPageDispatchBinding(
                target: AgentPageTarget(
                    pageID: pageID,
                    origin: "https://example.com",
                    session: .incognito
                ),
                version: version
            )
            try privateBinding.validate(live: privateBinding)
        }
    }

    @Test("Actual response decides the terminal result")
    func responseClassification() throws {
        let success = BrowserAutomationInvocationResult(
            responseData: try JSONSerialization.data(withJSONObject: [
                "ok": true,
                "result": "private DOM body",
            ])
        )
        let failure = BrowserAutomationInvocationResult(
            responseData: try JSONSerialization.data(withJSONObject: [
                "error": "private MCP failure body",
            ])
        )
        let malformed = BrowserAutomationInvocationResult(responseData: Data("not-json".utf8))

        #expect(success.kind == .succeeded)
        #expect(failure.kind == .failed)
        #expect(malformed.kind == .malformed)
    }

    @Test("Durable completion metadata never contains the response body")
    func metadataProjectionIsBodyFree() throws {
        let secret = "raw-dom-file-and-mcp-body-must-not-persist"
        let result = BrowserAutomationInvocationResult(
            responseData: try JSONSerialization.data(withJSONObject: [
                "ok": true,
                "result": secret,
            ])
        )
        let persisted = String(
            decoding: try JSONEncoder().encode(result.durableMetadata),
            as: UTF8.self
        )

        #expect(!persisted.contains(secret))
        #expect(persisted.contains(BrowserAutomationCompletionKind.succeeded.rawValue))
        #expect(persisted.contains("responseBodyRetained"))
        #expect(persisted.contains("false"))
    }

    @Test("Incognito canonical history remains metadata-only")
    func incognitoStoreProjectionIsMetadataOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "browser-cli-incognito-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentRunStore(baseDirectory: directory)
        let secret = "incognito-raw-arguments-and-result"
        let run = try await store.createRun(
            conversationID: nil,
            entryPoint: .localMCP,
            incognito: true
        )
        _ = try await store.transitionRun(run.id, to: .running, reason: "Received")
        _ = try await store.appendStep(
            runID: run.id,
            kind: .toolInvocation,
            summary: "get_dom",
            payload: .object(["tool": .string("get_dom")]),
            redactionState: .redacted
        )
        let result = BrowserAutomationInvocationResult(
            responseData: try JSONSerialization.data(withJSONObject: [
                "ok": true,
                "result": secret,
            ])
        )
        _ = try await store.appendStep(
            runID: run.id,
            kind: .toolResult,
            summary: "Browser automation completed",
            payload: result.durableMetadata,
            redactionState: .metadataOnly
        )
        _ = try await store.transitionRun(run.id, to: .succeeded, reason: "Completed")

        let metadataURL = directory.appendingPathComponent(
            "agent/runs/\(run.id.uuidString)/metadata.json"
        )
        let stepsURL = directory.appendingPathComponent(
            "agent/runs/\(run.id.uuidString)/steps.jsonl"
        )
        let persisted = String(decoding: try Data(contentsOf: metadataURL), as: UTF8.self)
            + String(decoding: try Data(contentsOf: stepsURL), as: UTF8.self)
        let storedRun = await store.run(id: run.id)
        #expect(storedRun?.incognito == true)
        #expect(!persisted.contains(secret))
        #expect(!persisted.contains("result"))
    }

    @Test("Local MCP meters tool calls, response bytes, and elapsed time")
    func localMCPBudgetAdmissions() async throws {
        let zeroToolCalls = AgentRunMeter(
            runID: UUID(),
            taskDefinitionID: nil,
            incognito: false,
            limits: try AgentExecutionLimits(maximumToolCalls: 0)
        )
        let callAdmission = await zeroToolCalls.admitToolCall()
        guard case .limited(let callLimit) = callAdmission else {
            Issue.record("Expected the local MCP tool-call admission to fail closed")
            return
        }
        #expect(callLimit.dimension == .toolCalls)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "browser-cli-budget-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentRunStore(baseDirectory: directory)
        let run = try await store.createRun(
            conversationID: nil,
            entryPoint: .localMCP
        )
        _ = try await store.transitionRun(run.id, to: .running, reason: "Received")
        let responseURL = directory.appendingPathComponent("limit-response.json")
        let admitted = try await BrowserAutomationRegistry.handleLocalMCPAdmission(
            callAdmission,
            runID: run.id,
            store: store,
            responseFilePath: responseURL.path
        )
        let limitSteps = try await store.steps(runID: run.id)
        let limitedRun = await store.run(id: run.id)
        #expect(!admitted)
        #expect(limitSteps.contains { $0.kind == .limit })
        #expect(limitedRun?.status == .failed)

        let bytesMeter = AgentRunMeter(
            runID: UUID(),
            taskDefinitionID: nil,
            incognito: false,
            limits: try AgentExecutionLimits(
                maximumToolCalls: 1,
                maximumModelResultBytes: 4
            )
        )
        #expect(await bytesMeter.admitToolCall().isAdmitted)
        guard case .limited(let byteLimit) = await bytesMeter.admitModelResult(bytes: 5) else {
            Issue.record("Expected oversized local MCP response bytes to be limited")
            return
        }
        #expect(byteLimit.dimension == .modelResultBytes)

        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let elapsedMeter = AgentRunMeter(
            runID: UUID(),
            taskDefinitionID: nil,
            incognito: false,
            limits: try AgentExecutionLimits(maximumElapsedMilliseconds: 50),
            startedAt: startedAt
        )
        guard case .limited(let elapsedLimit) = await elapsedMeter.admitToolCall(
            at: startedAt.addingTimeInterval(0.1)
        ) else {
            Issue.record("Expected elapsed local MCP work to be limited")
            return
        }
        #expect(elapsedLimit.dimension == .elapsedTime)
    }

    @Test("Unattended approval requests terminate unexecuted and cannot pretend to wait")
    func unattendedApprovalIsTerminal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "browser-cli-approval-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentRunStore(baseDirectory: directory)
        let run = try await store.createRun(
            conversationID: nil,
            entryPoint: .localMCP
        )
        _ = try await store.transitionRun(run.id, to: .running, reason: "Received")
        let now = Date()
        let request = AgentApprovalRequest(
            id: UUID(),
            runID: run.id,
            invocationDigest: String(repeating: "a", count: 64),
            toolName: "click",
            risk: .externalEffect,
            normalizedArguments: .object([:]),
            target: .none,
            effectSummary: "Click a page element",
            dataLeavesDevice: true,
            createdAt: now,
            expiresAt: now.addingTimeInterval(60),
            availableScopes: [.allowOnce]
        )
        let responseURL = directory.appendingPathComponent("approval-response.json")

        try await BrowserAutomationRegistry.terminateUnattendedApproval(
            request,
            runID: run.id,
            waitingStatus: .waitingForHuman,
            store: store,
            responseFilePath: responseURL.path
        )

        let storedRun = await store.run(id: run.id)
        let steps = try await store.steps(runID: run.id)
        let response = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: responseURL))
                as? [String: Any]
        )
        #expect(storedRun?.status == .cancelled)
        #expect(steps.contains { $0.kind == .approvalResponse })
        #expect(steps.contains { $0.summary.contains("not executed") })
        #expect(response["code"] as? String == "human_interaction_required")
        #expect(response["status"] as? String == AgentRunStatus.cancelled.rawValue)
        #expect(response["retryable"] as? Bool == false)
    }
}
