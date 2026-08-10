import Foundation
import Testing
@testable import Browser

struct WebKitAgentSignalRuntimeTests {
    @Test func routesNativeSignalsOnlyToActiveRunPageScopes() async throws {
        let runtime = BrowserAgentWebKitSignalRuntime(configuration: .init(
            maximumBufferedEventsPerScope: 8,
            privacy: .init(standardRetention: .metadataOnly)
        ))
        let runID = UUID()
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let otherPage = PageHandle(windowID: UUID(), tabID: UUID())
        let scope = try await runtime.activate(
            runID: runID,
            page: page,
            browserSession: .normal
        )

        await runtime.publish(
            .pageLifecycle(.init(phase: .loadStarted, url: URL(string: "https://example.test/private?q=secret"))),
            tabID: otherPage.tabID
        )
        await runtime.publish(
            .pageLifecycle(.init(phase: .loadCompleted, url: URL(string: "https://example.test/private?q=secret"))),
            tabID: page.tabID
        )

        let snapshot = try await runtime.snapshot(
            in: scope,
            matching: .init(kinds: [.pageLifecycle])
        )
        #expect(snapshot.events.count == 1)
        #expect(snapshot.events.first?.retention == .metadataOnly)
        guard case .pageLifecycle(let lifecycle) = snapshot.events.first?.signal else {
            Issue.record("Expected a lifecycle signal")
            return
        }
        #expect(lifecycle.phase == .loadCompleted)
        #expect(lifecycle.url?.origin == "https://example.test")
        #expect(lifecycle.url?.path == nil)
        #expect(lifecycle.url?.redactions.contains(.query) == true)
    }

    @Test func finishRunCancelsSubscriptionsAndClearsIncognitoScopes() async throws {
        let runtime = BrowserAgentWebKitSignalRuntime()
        let runID = UUID()
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let scope = try await runtime.activate(
            runID: runID,
            page: page,
            browserSession: .incognito(UUID())
        )
        let subscription = try await runtime.subscribe(
            to: scope,
            matching: .init(kinds: [.pageLifecycle])
        )

        #expect(await runtime.activeScopeCount == 1)
        await runtime.finishRun(runID)
        #expect(await runtime.activeScopeCount == 0)

        var iterator = subscription.events.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test func signalWaitUsesSequenceBoundaryAndRequiredTimeout() async throws {
        let runtime = BrowserAgentWebKitSignalRuntime()
        let runID = UUID()
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let scope = try await runtime.activate(
            runID: runID,
            page: page,
            browserSession: .normal
        )
        await runtime.publish(
            .navigation(.init(
                observationID: UUID(),
                phase: .committed,
                url: URL(string: "https://example.test"),
                isMainFrame: true
            )),
            tabID: page.tabID
        )
        let before = try await runtime.snapshot(in: scope)
        let request = try WebKitAgentSignalWaitRequest(
            scope: scope,
            condition: .navigation(.finished),
            afterSequence: before.latestSequence,
            maximumTimeout: .seconds(1)
        )

        let waiter = Task { try await runtime.wait(for: request) }
        await Task.yield()
        await runtime.publish(
            .navigation(.init(
                observationID: UUID(),
                phase: .finished,
                url: URL(string: "https://example.test/done"),
                isMainFrame: true
            )),
            tabID: page.tabID
        )
        let result = try await waiter.value
        #expect(result.sequence > before.latestSequence)
        guard case .navigation(let navigation) = result.signal else {
            Issue.record("Expected a navigation signal")
            return
        }
        #expect(navigation.phase == .finished)
    }

    @Test func signalsPublishedAfterPageAdmissionRemainAvailableBeforeObserveCall() async throws {
        let runtime = BrowserAgentWebKitSignalRuntime()
        let runID = UUID()
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let scope = try await runtime.activate(
            runID: runID,
            page: page,
            browserSession: .normal
        )

        // Admission happens before the page action. The action's dialog and
        // download callbacks may both precede the model's later observe call.
        let dialogID = UUID()
        let downloadID = UUID()
        await runtime.publish(
            .dialog(.init(dialogID: dialogID, phase: .presented, kind: .confirm)),
            tabID: page.tabID
        )
        await runtime.publish(
            .download(.init(downloadID: downloadID, phase: .started)),
            tabID: page.tabID
        )

        let observed = try await runtime.snapshot(in: scope)
        #expect(observed.events.map(\.signal.kind) == [.dialog, .download])
    }

    @Test func completedRunLogicallyDisablesItsConsoleBridgeToken() async throws {
        let runtime = BrowserAgentWebKitSignalRuntime(configuration: .init(
            privacy: .init(captureConsoleMessages: true)
        ))
        let runID = UUID()
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let scope = try await runtime.activate(
            runID: runID,
            page: page,
            browserSession: .incognito(UUID())
        )
        let token = try #require(await runtime.consoleBridgeToken(tabID: page.tabID))
        let message = WebKitAgentConsoleBridgeMessage(
            token: token,
            level: .log,
            message: "memory-only incognito message"
        )
        await runtime.publishConsole(message, tabID: page.tabID)
        let beforeFinish = try await runtime.snapshot(in: scope)
        #expect(beforeFinish.events.first?.retention == .memoryOnly)

        await runtime.finishRun(runID)
        #expect(await runtime.consoleBridgeToken(tabID: page.tabID) == nil)
        await runtime.publishConsole(message, tabID: page.tabID)
        #expect(await runtime.activeScopeCount == 0)
        await #expect(throws: BrowserAgentWebKitSignalRuntimeError.inactiveScope(scope)) {
            _ = try await runtime.snapshot(in: scope)
        }
    }
}
