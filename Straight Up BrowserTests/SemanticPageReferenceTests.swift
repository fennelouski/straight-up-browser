import Foundation
import Testing
import WebKit
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

    @Test func productionEventBufferDrivesHiddenPageWaitWithoutFocus() async throws {
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let source = WebKitPageWaitEventBuffer(page: page)
        let request = try PageWaitRequest(
            page: page,
            condition: .load(.complete),
            maximumTimeout: .seconds(1)
        )
        let wait = Task {
            try await PageWaitCoordinator(source: source).wait(for: request)
        }

        await source.emit(.loadState(.committed))
        await source.emit(.loadState(.complete))

        #expect(try await wait.value == .load(.complete))
        await source.finish()
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
        #expect(!scripts.installation.contains("data-sub-agent-id"))
        #expect(!scripts.installation.contains("data-straight-up-semantic-id"))
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

    @Test func productionSnapshotDecoderPreservesDocumentIdentityAndExplicitBoundaries() throws {
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let document = UUID()
        let payload: [String: Any] = [
            "documentToken": document.uuidString,
            "url": "https://shop.example/checkout?private=value",
            "title": "Checkout",
            "nodes": [[
                "localID": "semantic-node",
                "legacySubID": 9,
                "role": "button",
                "name": "Pay",
                "states": ["visible", "enabled"],
                "frameContext": [
                    [
                        "kind": "sameOriginFrame",
                        "localID": "frame-one",
                        "origin": "https://shop.example",
                    ],
                    [
                        "kind": "openShadowRoot",
                        "hostLocalID": "payment-widget",
                    ],
                ],
                "geometryDigest": "10:20:90:32",
                "matchedSelectors": ["button.pay"],
                "text": "Pay",
                "destinationURL": NSNull(),
                "isInteractive": true,
            ]],
            "inaccessibleFrameBoundaries": [[
                "parentContext": [],
                "frameLocalID": "third-party",
                "sourceURL": "https://payments.example",
                "reason": "crossOrigin",
            ]],
            "visibleText": "Ready to pay",
        ]
        var tracker = SemanticPageGenerationTracker()

        let first = try SemanticPageJavaScriptSnapshot.decode(
            payload,
            page: page,
            generationTracker: &tracker
        )
        let second = try SemanticPageJavaScriptSnapshot.decode(
            payload,
            page: page,
            generationTracker: &tracker
        )

        #expect(first.snapshot.documentGeneration.rawValue == document)
        #expect(first.snapshot.navigationGeneration == second.snapshot.navigationGeneration)
        #expect(first.snapshot.nodes.first?.frameContext.path == [
            .sameOriginFrame(localID: "frame-one", origin: "https://shop.example"),
            .openShadowRoot(hostLocalID: "payment-widget"),
        ])
        #expect(first.snapshot.nodes.first?.legacySubID == 9)
        #expect(first.snapshot.inaccessibleFrameBoundaries.first?.reason == .crossOrigin)

        var replacement = payload
        replacement["documentToken"] = UUID().uuidString
        let navigated = try SemanticPageJavaScriptSnapshot.decode(
            replacement,
            page: page,
            generationTracker: &tracker
        )
        #expect(navigated.snapshot.navigationGeneration == first.snapshot.navigationGeneration.advanced())
    }

    @Test func productionScriptsUseIsolatedStableIdentityAndAtomicEffectValidation() {
        #expect(SemanticPageJavaScript.bootstrap.contains("identityByElement: new WeakMap()"))
        #expect(SemanticPageJavaScript.bootstrap.contains("documentToken: uuid()"))
        #expect(SemanticPageJavaScript.bootstrap.contains("openShadowRoot"))
        #expect(SemanticPageJavaScript.bootstrap.contains("sameOriginFrame"))
        #expect(SemanticPageJavaScript.bootstrap.contains("crossOrigin"))
        #expect(SemanticPageJavaScript.bootstrap.contains("const refreshed = scan"))
        #expect(SemanticPageJavaScript.bootstrap.contains("semantic element was replaced or substituted"))
        #expect(SemanticPageJavaScript.bootstrap.contains("new MutationObserver"))
        #expect(!SemanticPageJavaScript.bootstrap.contains("data-sub-agent-id"))
        #expect(!SemanticPageJavaScript.effect.contains("querySelector"))
        #expect(!SemanticPageJavaScript.effect.contains("arguments.request"))
    }

    @Test @MainActor func productionWebKitRuntimeHandlesShadowFramesReplacementWaitAndNavigation() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: SemanticPageJavaScript.bootstrap,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .defaultClient
        ))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let loader = SemanticWebViewLoader()
        webView.navigationDelegate = loader
        try await loader.load(
            """
            <!doctype html><html><body>
              <button id="primary">Primary</button>
              <button id="delayed" disabled>Continue</button>
              <div id="shadow-host"></div>
              <iframe id="same" srcdoc='<button id="inside">Frame action</button>'></iframe>
              <iframe id="opaque" sandbox srcdoc='<button>Opaque action</button>'></iframe>
              <script>
                const root = document.querySelector('#shadow-host').attachShadow({mode:'open'});
                root.innerHTML = '<button id="shadow-action">Shadow action</button>';
              </script>
            </body></html>
            """,
            in: webView
        )
        try await Task.sleep(for: .milliseconds(100))

        let page = PageHandle(windowID: UUID(), tabID: UUID())
        var tracker = SemanticPageGenerationTracker()
        let firstRaw = try #require(await webView.callAsyncJavaScript(
            SemanticPageJavaScript.snapshot,
            arguments: ["selectors": ["#primary"]],
            in: nil,
            contentWorld: .defaultClient
        ))
        let first = try SemanticPageJavaScriptSnapshot.decode(
            firstRaw,
            page: page,
            generationTracker: &tracker
        )
        let primary = try #require(first.snapshot.nodes.first { $0.name == "Primary" })
        let shadow = try #require(first.snapshot.nodes.first { $0.name == "Shadow action" })
        let framed = try #require(first.snapshot.nodes.first { $0.name == "Frame action" })
        #expect(shadow.frameContext.path.contains { component in
            if case .openShadowRoot = component { return true }
            return false
        })
        #expect(framed.frameContext.path.contains { component in
            if case .sameOriginFrame = component { return true }
            return false
        })
        let primaryY = Int(primary.geometryDigest.rawValue.split(separator: ":")[1])
        let framedY = Int(framed.geometryDigest.rawValue.split(separator: ":")[1])
        #expect(framedY != nil && primaryY != nil && framedY! > primaryY!)
        #expect(first.snapshot.inaccessibleFrameBoundaries.contains { $0.reason == .crossOrigin })

        let delayed = try #require(first.snapshot.nodes.first { $0.name == "Continue" })
        let waitToken = UUID().uuidString
        let waitTask = Task { @MainActor () throws -> String? in
            let value = try await webView.callAsyncJavaScript(
                SemanticPageJavaScript.wait,
                arguments: ["request": [
                    "condition": "elementState",
                    "state": "enabled",
                    "isPresent": true,
                    "localID": delayed.localID,
                    "timeoutMilliseconds": 1_000,
                    "token": waitToken,
                ]],
                in: nil,
                contentWorld: .defaultClient
            )
            return (value as? [String: Any])?["status"] as? String
        }
        try await Task.sleep(for: .milliseconds(50))
        _ = try await webView.callAsyncJavaScript(
            "document.querySelector('#delayed').disabled = false; return true;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        #expect(try await waitTask.value == "matched")

        let reference = primary.reference(
            on: page,
            navigationGeneration: first.snapshot.navigationGeneration,
            documentGeneration: first.snapshot.documentGeneration,
            preferLegacyIdentifier: true
        )
        _ = try await webView.callAsyncJavaScript(
            "const old = document.querySelector('#primary'); const copy = old.cloneNode(true); old.replaceWith(copy); return true;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let replacedRaw = try #require(await webView.callAsyncJavaScript(
            SemanticPageJavaScript.snapshot,
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        ))
        let replaced = try SemanticPageJavaScriptSnapshot.decode(
            replacedRaw,
            page: page,
            generationTracker: &tracker
        )
        #expect(throws: SemanticReferenceResolutionError.missing(.legacySub(primary.legacySubID!))) {
            try SemanticElementResolver.resolve(reference, in: replaced.snapshot)
        }
        var effectFailedClosed = false
        do {
            _ = try await webView.callAsyncJavaScript(
                SemanticPageJavaScript.effect,
                arguments: ["request": [
                    "action": "click",
                    "reference": SemanticPageJavaScriptSnapshot.effectReference(
                        for: primary,
                        in: first.snapshot
                    ),
                ]],
                in: nil,
                contentWorld: .defaultClient
            )
        } catch {
            effectFailedClosed = true
        }
        #expect(effectFailedClosed)

        try await loader.load("<!doctype html><html><body>New document</body></html>", in: webView)
        let navigatedRaw = try #require(await webView.callAsyncJavaScript(
            SemanticPageJavaScript.snapshot,
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        ))
        let navigated = try SemanticPageJavaScriptSnapshot.decode(
            navigatedRaw,
            page: page,
            generationTracker: &tracker
        )
        #expect(navigated.snapshot.documentGeneration != first.snapshot.documentGeneration)
        #expect(navigated.snapshot.navigationGeneration == first.snapshot.navigationGeneration.advanced())
    }
}

@MainActor
private final class SemanticWebViewLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://semantic.example/"))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
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
