import Foundation
import Testing
@testable import Browser

struct SemanticPageReferenceTests {
    @Test func pageHandleRoundTripsAutomationAddress() throws {
        let windowID = UUID()
        let tabID = UUID()
        let handle = PageHandle(windowID: windowID, tabID: tabID)

        #expect(handle.description == "\(windowID.uuidString):\(tabID.uuidString)")
        #expect(try PageHandle(parsing: handle.description) == handle)
        let encoded = try JSONEncoder().encode(handle)
        #expect(String(data: encoded, encoding: .utf8) == "\"\(handle.description)\"")
        #expect(try JSONDecoder().decode(PageHandle.self, from: encoded) == handle)
    }

    @Test func waitRequestRequiresPositiveMaximumTimeout() throws {
        let page = PageHandle(windowID: UUID(), tabID: UUID())

        #expect(throws: PageWaitRequestError.invalidMaximumTimeout(.zero)) {
            try PageWaitRequest(
                page: page,
                condition: .pageClosed,
                maximumTimeout: .zero
            )
        }
    }

    @Test func loadWaitCanCompleteFromInitialBackgroundPageState() async throws {
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let source = FakePageWaitEventSource(
            state: PageWaitState(page: page, loadState: .complete)
        )
        let coordinator = PageWaitCoordinator(source: source)
        let request = try PageWaitRequest(
            page: page,
            condition: .load(.complete),
            maximumTimeout: .seconds(1)
        )

        #expect(try await coordinator.wait(for: request) == .load(.complete))
        #expect(await source.cleanupCount() == 1)
        #expect(await source.focusRequestCount() == 0)
    }

    @Test func selectorTextAndURLWaitsUseSnapshotsAndNavigationEvents() async throws {
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let navigation = PageNavigationGeneration(rawValue: 3)
        let document = PageDocumentGeneration(rawValue: UUID())
        let node = SemanticNodeSnapshot(
            localID: "checkout",
            role: "link",
            name: "Checkout",
            states: [.visible, .enabled],
            geometryDigest: SemanticGeometryDigest(rawValue: "1:2:3:4"),
            matchedSelectors: ["a.checkout"],
            text: "Checkout"
        )
        let snapshot = SemanticPageSnapshot(
            page: page,
            navigationGeneration: navigation,
            documentGeneration: document,
            nodes: [node],
            visibleText: "Cart ready for checkout"
        )
        let source = FakePageWaitEventSource(
            state: PageWaitState(page: page, semanticSnapshot: snapshot)
        )
        let coordinator = PageWaitCoordinator(source: source)

        let selectorRequest = try PageWaitRequest(
            page: page,
            condition: .selector("a.checkout"),
            maximumTimeout: .seconds(1)
        )
        let expectedReference = node.reference(
            on: page,
            navigationGeneration: navigation,
            documentGeneration: document
        )
        #expect(try await coordinator.wait(for: selectorRequest) == .selector(
            selector: "a.checkout",
            references: [expectedReference]
        ))

        let textRequest = try PageWaitRequest(
            page: page,
            condition: .text(.contains("ready for")),
            maximumTimeout: .seconds(1)
        )
        #expect(try await coordinator.wait(for: textRequest) == .text(
            expectation: .contains("ready for"),
            observedText: "Cart ready for checkout"
        ))

        let destination = try #require(URL(string: "https://example.test/complete"))
        let urlRequest = try PageWaitRequest(
            page: page,
            condition: .url(.equals(destination)),
            maximumTimeout: .seconds(1)
        )
        let urlWait = Task {
            try await coordinator.wait(for: urlRequest)
        }
        await source.emit(.navigation(
            url: destination,
            navigationGeneration: navigation.advanced(),
            documentGeneration: PageDocumentGeneration(rawValue: UUID())
        ))

        #expect(try await urlWait.value == .url(destination))
        #expect(await source.cleanupCount() == 3)
        #expect(await source.focusRequestCount() == 0)
    }

    @Test func elementStateWaitObservesDelayedEnablementWithoutChangingIdentity() async throws {
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let navigation = PageNavigationGeneration(rawValue: 1)
        let document = PageDocumentGeneration(rawValue: UUID())
        let disabledNode = SemanticNodeSnapshot(
            localID: "continue",
            role: "button",
            name: "Continue",
            states: [.visible, .disabled],
            geometryDigest: SemanticGeometryDigest(rawValue: "10:10:80:30")
        )
        let initialSnapshot = SemanticPageSnapshot(
            page: page,
            navigationGeneration: navigation,
            documentGeneration: document,
            nodes: [disabledNode]
        )
        let source = FakePageWaitEventSource(
            state: PageWaitState(page: page, semanticSnapshot: initialSnapshot)
        )
        let coordinator = PageWaitCoordinator(source: source)
        let reference = disabledNode.reference(
            on: page,
            navigationGeneration: navigation,
            documentGeneration: document
        )
        let request = try PageWaitRequest(
            page: page,
            condition: .elementState(
                reference: reference,
                state: .enabled,
                isPresent: true
            ),
            maximumTimeout: .seconds(1)
        )
        let wait = Task {
            try await coordinator.wait(for: request)
        }

        var enabledNode = disabledNode
        enabledNode.states = [.visible, .enabled]
        await source.emit(.semanticSnapshot(SemanticPageSnapshot(
            page: page,
            navigationGeneration: navigation,
            documentGeneration: document,
            nodes: [enabledNode]
        )))

        #expect(try await wait.value == .elementState(
            reference: reference,
            state: .enabled,
            isPresent: true
        ))
        #expect(await source.cleanupCount() == 1)
    }

    @Test func dialogDownloadAndPageCloseWaitsAreEventDriven() async throws {
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let source = FakePageWaitEventSource(state: PageWaitState(page: page))
        let coordinator = PageWaitCoordinator(source: source)
        let dialog = PageDialogObservation(
            dialogID: UUID(),
            kind: .confirm,
            message: "Continue?",
            defaultText: nil
        )
        let dialogRequest = try PageWaitRequest(
            page: page,
            condition: .dialog(.confirm),
            maximumTimeout: .seconds(1)
        )
        let dialogWait = Task { try await coordinator.wait(for: dialogRequest) }
        await source.emit(.dialogPresented(dialog))
        #expect(try await dialogWait.value == .dialog(dialog))

        let downloadID = UUID()
        let started = PageDownloadObservation(
            downloadID: downloadID,
            phase: .started,
            suggestedFilename: "report.pdf"
        )
        let startRequest = try PageWaitRequest(
            page: page,
            condition: .downloadStarted(downloadID),
            maximumTimeout: .seconds(1)
        )
        let startWait = Task { try await coordinator.wait(for: startRequest) }
        await source.emit(.download(started))
        #expect(try await startWait.value == .downloadStarted(started))

        let completed = PageDownloadObservation(
            downloadID: downloadID,
            phase: .completed,
            suggestedFilename: "report.pdf"
        )
        let completionRequest = try PageWaitRequest(
            page: page,
            condition: .downloadCompleted(downloadID),
            maximumTimeout: .seconds(1)
        )
        let completionWait = Task { try await coordinator.wait(for: completionRequest) }
        await source.emit(.download(completed))
        #expect(try await completionWait.value == .downloadCompleted(completed))

        let closeRequest = try PageWaitRequest(
            page: page,
            condition: .pageClosed,
            maximumTimeout: .seconds(1)
        )
        let closeWait = Task { try await coordinator.wait(for: closeRequest) }
        await source.emit(.pageClosed)
        #expect(try await closeWait.value == .pageClosed(page))

        #expect(await source.cleanupCount() == 4)
        #expect(await source.focusRequestCount() == 0)
    }

    @Test func waitTimeoutIsTypedAndCleansUpSubscription() async throws {
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let source = FakePageWaitEventSource(state: PageWaitState(page: page))
        let coordinator = PageWaitCoordinator(source: source)
        let timeout = Duration.milliseconds(20)
        let request = try PageWaitRequest(
            page: page,
            condition: .selector("#never"),
            maximumTimeout: timeout
        )

        do {
            _ = try await coordinator.wait(for: request)
            Issue.record("Expected the wait to time out")
        } catch let error as PageWaitError {
            #expect(error == .timedOut(
                page: page,
                condition: .selector("#never"),
                maximumTimeout: timeout
            ))
        }
        #expect(await source.cleanupCount() == 1)
    }

    @Test func cancellingWaitReturnsTypedErrorAndCleansUpOnce() async throws {
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let source = FakePageWaitEventSource(state: PageWaitState(page: page))
        let coordinator = PageWaitCoordinator(source: source)
        let request = try PageWaitRequest(
            page: page,
            condition: .text(.contains("never")),
            maximumTimeout: .seconds(10)
        )
        let wait = Task {
            try await coordinator.wait(for: request)
        }
        for _ in 0..<100 where await source.activeSubscriptionCount() == 0 {
            await Task.yield()
        }

        wait.cancel()
        do {
            _ = try await wait.value
            Issue.record("Expected the wait to be cancelled")
        } catch let error as PageWaitError {
            #expect(error == .cancelled(
                page: page,
                condition: .text(.contains("never"))
            ))
        }
        #expect(await source.cleanupCount() == 1)
    }

    @Test func mutationObserverScriptsAreBoundedAndExposeFrameBoundaries() {
        let configuration = WebKitAgentMutationObserverConfiguration(
            token: "wait-'quoted",
            maximumNodesPerReport: 100_000,
            maximumObservedRoots: 0,
            maximumTextLength: -4,
            maximumFrameDepth: 200,
            minimumReportIntervalMilliseconds: 1
        )
        let scripts = WebKitAgentMutationObserverScripts(configuration: configuration)

        #expect(configuration.maximumNodesPerReport == 4_096)
        #expect(configuration.maximumObservedRoots == 1)
        #expect(configuration.maximumTextLength == 1)
        #expect(configuration.maximumFrameDepth == 32)
        #expect(configuration.minimumReportIntervalMilliseconds == 16)
        #expect(scripts.installation.contains("MutationObserver"))
        #expect(scripts.installation.contains("shadowRoot"))
        #expect(scripts.installation.contains("contentDocument"))
        #expect(scripts.installation.contains("crossOrigin"))
        #expect(scripts.installation.contains("observer.disconnect()"))
        #expect(scripts.installation.contains("maxNodes = 4096"))
        #expect(!scripts.installation.contains("querySelectorAll"))
        #expect(scripts.cleanup.contains("registry.get(token)"))
        #expect(scripts.cleanup.contains("cleanup()"))
    }

    @Test func semanticReferenceRejectsAnotherNavigationOrDocumentGeneration() throws {
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let navigation = PageNavigationGeneration(rawValue: 4)
        let document = PageDocumentGeneration(rawValue: UUID())
        let node = SemanticNodeSnapshot(
            localID: "node-submit",
            legacySubID: 3,
            role: "button",
            name: "Submit",
            states: [.enabled, .visible],
            frameContext: .mainDocument,
            geometryDigest: SemanticGeometryDigest(rawValue: "10:20:80:30")
        )
        let snapshot = SemanticPageSnapshot(
            page: page,
            navigationGeneration: navigation,
            documentGeneration: document,
            nodes: [node]
        )
        let reference = node.reference(
            on: page,
            navigationGeneration: navigation,
            documentGeneration: document
        )

        #expect(try SemanticElementResolver.resolve(reference, in: snapshot) == node)

        let replacementDocument = PageDocumentGeneration(rawValue: UUID())
        let replacedSnapshot = SemanticPageSnapshot(
            page: page,
            navigationGeneration: navigation,
            documentGeneration: replacementDocument,
            nodes: [node]
        )
        #expect(throws: SemanticReferenceResolutionError.documentChanged(
            expected: document,
            actual: replacementDocument
        )) {
            try SemanticElementResolver.resolve(reference, in: replacedSnapshot)
        }

        let nextNavigation = navigation.advanced()
        let navigatedSnapshot = SemanticPageSnapshot(
            page: page,
            navigationGeneration: nextNavigation,
            documentGeneration: document,
            nodes: [node]
        )
        #expect(throws: SemanticReferenceResolutionError.navigationChanged(
            expected: navigation,
            actual: nextNavigation
        )) {
            try SemanticElementResolver.resolve(reference, in: navigatedSnapshot)
        }
    }

    @Test func referenceCarriesStateAndRejectsSubstitutionOrAmbiguity() throws {
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let navigation = PageNavigationGeneration(rawValue: 8)
        let document = PageDocumentGeneration(rawValue: UUID())
        let node = SemanticNodeSnapshot(
            localID: "node-save",
            legacySubID: 12,
            role: "button",
            name: "Save",
            states: [.visible, .disabled],
            geometryDigest: SemanticGeometryDigest(x: 4, y: 8, width: 80, height: 32)
        )
        let reference = node.reference(
            on: page,
            navigationGeneration: navigation,
            documentGeneration: document,
            preferLegacyIdentifier: true
        )

        #expect(reference.identifier == .legacySub(12))
        #expect(reference.states == [.visible, .disabled])
        #expect(try SemanticElementIdentifier(parsing: "sub-12") == .legacySub(12))
        #expect(reference.identifier.compatibilityString == "sub-12")

        var replacement = node
        replacement.name = "Delete"
        let substitutedSnapshot = SemanticPageSnapshot(
            page: page,
            navigationGeneration: navigation,
            documentGeneration: document,
            nodes: [replacement]
        )
        #expect(throws: SemanticReferenceResolutionError.substituted(.legacySub(12))) {
            try SemanticElementResolver.resolve(reference, in: substitutedSnapshot)
        }

        let ambiguousSnapshot = SemanticPageSnapshot(
            page: page,
            navigationGeneration: navigation,
            documentGeneration: document,
            nodes: [node, node]
        )
        #expect(throws: SemanticReferenceResolutionError.ambiguous(
            identifier: .legacySub(12),
            matches: 2
        )) {
            try SemanticElementResolver.resolve(reference, in: ambiguousSnapshot)
        }
    }

    @Test func referenceRetainsShadowAndSameOriginFrameContext() throws {
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let navigation = PageNavigationGeneration(rawValue: 2)
        let document = PageDocumentGeneration(rawValue: UUID())
        let context = SemanticFrameContext(path: [
            .sameOriginFrame(localID: "frame-checkout", origin: "https://shop.example"),
            .openShadowRoot(hostLocalID: "payment-widget")
        ])
        let node = SemanticNodeSnapshot(
            localID: "pay-button",
            legacySubID: 1,
            role: "button",
            name: "Pay",
            states: [.visible, .enabled],
            frameContext: context,
            geometryDigest: SemanticGeometryDigest(rawValue: "12:24:100:40")
        )
        let boundary = SemanticFrameBoundary(
            parentContext: .mainDocument,
            frameLocalID: "third-party-frame",
            sourceURL: URL(string: "https://payments.example/checkout"),
            reason: .crossOrigin
        )
        let snapshot = SemanticPageSnapshot(
            page: page,
            navigationGeneration: navigation,
            documentGeneration: document,
            nodes: [
                SemanticNodeSnapshot(
                    localID: "main-button",
                    legacySubID: 1,
                    role: "button",
                    name: "Main action",
                    geometryDigest: SemanticGeometryDigest(rawValue: "1:1:10:10")
                ),
                node
            ],
            inaccessibleFrameBoundaries: [boundary]
        )
        let reference = node.reference(
            on: page,
            navigationGeneration: navigation,
            documentGeneration: document,
            preferLegacyIdentifier: true
        )

        #expect(reference.frameContext == context)
        #expect(snapshot.inaccessibleFrameBoundaries == [boundary])
        #expect(try SemanticElementResolver.resolve(reference, in: snapshot) == node)
        #expect(throws: SemanticReferenceResolutionError.invalidIdentifier("sub-zero")) {
            try SemanticElementIdentifier(parsing: "sub-zero")
        }
    }
}

private actor FakePageWaitEventSource: PageWaitEventSource {
    private var state: PageWaitState
    private var continuations: [UUID: AsyncStream<PageWaitEvent>.Continuation] = [:]
    private var cleanups = 0
    private var focusRequests = 0

    init(state: PageWaitState) {
        self.state = state
    }

    func currentState(for page: PageHandle) async throws -> PageWaitState {
        state
    }

    func subscribe(to page: PageHandle) async throws -> PageWaitSubscription {
        let subscriptionID = UUID()
        let (stream, continuation) = AsyncStream<PageWaitEvent>.makeStream()
        continuations[subscriptionID] = continuation
        return PageWaitSubscription(events: stream) { [weak self] in
            await self?.cancelSubscription(subscriptionID)
        }
    }

    func emit(_ event: PageWaitEvent) {
        state.apply(event)
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    func cleanupCount() -> Int {
        cleanups
    }

    func focusRequestCount() -> Int {
        focusRequests
    }

    func activeSubscriptionCount() -> Int {
        continuations.count
    }

    private func cancelSubscription(_ subscriptionID: UUID) {
        guard let continuation = continuations.removeValue(forKey: subscriptionID) else {
            return
        }
        continuation.finish()
        cleanups += 1
    }
}
