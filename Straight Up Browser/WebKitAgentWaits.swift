import Foundation

nonisolated enum PageLoadState: Int, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case provisional
    case committed
    case domContentLoaded
    case complete

    func hasReached(_ expected: Self) -> Bool {
        rawValue >= expected.rawValue
    }
}

nonisolated enum PageURLExpectation: Equatable, Hashable, Sendable {
    case equals(URL)
    case hasPrefix(String)
    case host(String)

    func matches(_ url: URL) -> Bool {
        switch self {
        case .equals(let expected):
            url == expected
        case .hasPrefix(let prefix):
            url.absoluteString.hasPrefix(prefix)
        case .host(let expectedHost):
            url.host()?.localizedCaseInsensitiveCompare(expectedHost) == .orderedSame
        }
    }
}

nonisolated enum PageTextExpectation: Equatable, Hashable, Sendable {
    case contains(String)
    case equals(String)

    func matches(_ text: String) -> Bool {
        switch self {
        case .contains(let expected): text.contains(expected)
        case .equals(let expected): text == expected
        }
    }
}

nonisolated enum PageDialogKind: String, Codable, Equatable, Hashable, Sendable {
    case alert
    case confirm
    case prompt
    case beforeUnload
}

nonisolated struct PageDialogObservation: Codable, Equatable, Hashable, Sendable {
    var dialogID: UUID
    var kind: PageDialogKind
    var message: String
    var defaultText: String?
}

nonisolated enum PageDownloadPhase: String, Codable, Equatable, Hashable, Sendable {
    case started
    case completed
}

nonisolated struct PageDownloadObservation: Codable, Equatable, Hashable, Sendable {
    var downloadID: UUID
    var phase: PageDownloadPhase
    var suggestedFilename: String?
}

nonisolated enum PageWaitCondition: Equatable, Hashable, Sendable {
    case load(PageLoadState)
    case url(PageURLExpectation)
    case selector(String)
    case text(PageTextExpectation)
    case elementState(
        reference: SemanticElementReference,
        state: SemanticElementState,
        isPresent: Bool
    )
    case dialog(PageDialogKind?)
    case downloadStarted(UUID?)
    case downloadCompleted(UUID?)
    case pageClosed
}

nonisolated enum PageWaitRequestError: Error, Equatable, Sendable {
    case invalidMaximumTimeout(Duration)
    case emptySelector
    case emptyTextExpectation
}

nonisolated struct PageWaitRequest: Equatable, Sendable {
    let page: PageHandle
    let condition: PageWaitCondition
    let maximumTimeout: Duration

    init(
        page: PageHandle,
        condition: PageWaitCondition,
        maximumTimeout: Duration
    ) throws {
        guard maximumTimeout > .zero else {
            throw PageWaitRequestError.invalidMaximumTimeout(maximumTimeout)
        }
        switch condition {
        case .selector(let selector) where selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            throw PageWaitRequestError.emptySelector
        case .text(.contains(let text)) where text.isEmpty:
            throw PageWaitRequestError.emptyTextExpectation
        case .text(.equals(let text)) where text.isEmpty:
            throw PageWaitRequestError.emptyTextExpectation
        default:
            break
        }
        self.page = page
        self.condition = condition
        self.maximumTimeout = maximumTimeout
    }
}

nonisolated enum PageWaitResult: Equatable, Sendable {
    case load(PageLoadState)
    case url(URL)
    case selector(selector: String, references: [SemanticElementReference])
    case text(expectation: PageTextExpectation, observedText: String)
    case elementState(
        reference: SemanticElementReference,
        state: SemanticElementState,
        isPresent: Bool
    )
    case dialog(PageDialogObservation)
    case downloadStarted(PageDownloadObservation)
    case downloadCompleted(PageDownloadObservation)
    case pageClosed(PageHandle)
}

nonisolated enum PageWaitEvent: Equatable, Sendable {
    case loadState(PageLoadState)
    case navigation(
        url: URL,
        navigationGeneration: PageNavigationGeneration,
        documentGeneration: PageDocumentGeneration
    )
    case semanticSnapshot(SemanticPageSnapshot)
    case dialogPresented(PageDialogObservation)
    case dialogDismissed(UUID)
    case download(PageDownloadObservation)
    case pageClosed
}

nonisolated struct PageWaitState: Equatable, Sendable {
    var page: PageHandle
    var loadState: PageLoadState?
    var url: URL?
    var navigationGeneration: PageNavigationGeneration?
    var documentGeneration: PageDocumentGeneration?
    var semanticSnapshot: SemanticPageSnapshot?
    var dialog: PageDialogObservation?
    var downloads: [UUID: PageDownloadObservation]
    var isClosed: Bool

    init(
        page: PageHandle,
        loadState: PageLoadState? = nil,
        url: URL? = nil,
        navigationGeneration: PageNavigationGeneration? = nil,
        documentGeneration: PageDocumentGeneration? = nil,
        semanticSnapshot: SemanticPageSnapshot? = nil,
        dialog: PageDialogObservation? = nil,
        downloads: [UUID: PageDownloadObservation] = [:],
        isClosed: Bool = false
    ) {
        self.page = page
        self.loadState = loadState
        self.url = url
        self.navigationGeneration = navigationGeneration
        self.documentGeneration = documentGeneration
        self.semanticSnapshot = semanticSnapshot
        self.dialog = dialog
        self.downloads = downloads
        self.isClosed = isClosed
    }

    mutating func apply(_ event: PageWaitEvent) {
        switch event {
        case .loadState(let loadState):
            self.loadState = loadState
        case .navigation(let url, let navigationGeneration, let documentGeneration):
            self.url = url
            self.navigationGeneration = navigationGeneration
            self.documentGeneration = documentGeneration
            loadState = .provisional
            semanticSnapshot = nil
            dialog = nil
        case .semanticSnapshot(let snapshot):
            semanticSnapshot = snapshot
            navigationGeneration = snapshot.navigationGeneration
            documentGeneration = snapshot.documentGeneration
        case .dialogPresented(let dialog):
            self.dialog = dialog
        case .dialogDismissed(let dialogID):
            if dialog?.dialogID == dialogID {
                dialog = nil
            }
        case .download(let download):
            downloads[download.downloadID] = download
        case .pageClosed:
            isClosed = true
        }
    }
}

nonisolated enum PageWaitError: Error, Equatable, Sendable {
    case timedOut(
        page: PageHandle,
        condition: PageWaitCondition,
        maximumTimeout: Duration
    )
    case cancelled(page: PageHandle, condition: PageWaitCondition)
    case sourceEnded(page: PageHandle, condition: PageWaitCondition)
    case sourcePageMismatch(expected: PageHandle, actual: PageHandle)
}

nonisolated protocol PageWaitEventSource: Sendable {
    func currentState(for page: PageHandle) async throws -> PageWaitState
    func subscribe(to page: PageHandle) async throws -> PageWaitSubscription
}

/// In-memory production buffer used by WebKit-backed waits. The browser bridge
/// publishes typed events into this actor; PageWaitCoordinator owns timeout,
/// cancellation, identity validation, and deterministic subscription cleanup.
actor WebKitPageWaitEventBuffer: PageWaitEventSource {
    private let page: PageHandle
    private var state: PageWaitState
    private var continuations: [UUID: AsyncStream<PageWaitEvent>.Continuation] = [:]
    private var ended = false

    init(page: PageHandle, initialState: PageWaitState? = nil) {
        self.page = page
        state = initialState ?? PageWaitState(page: page)
    }

    func currentState(for requestedPage: PageHandle) throws -> PageWaitState {
        guard requestedPage == page else {
            throw PageWaitError.sourcePageMismatch(expected: requestedPage, actual: page)
        }
        return state
    }

    func subscribe(to requestedPage: PageHandle) throws -> PageWaitSubscription {
        guard requestedPage == page else {
            throw PageWaitError.sourcePageMismatch(expected: requestedPage, actual: page)
        }
        let subscriptionID = UUID()
        let pair = AsyncStream<PageWaitEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        if ended {
            pair.continuation.finish()
        } else {
            continuations[subscriptionID] = pair.continuation
        }
        return PageWaitSubscription(events: pair.stream) { [weak self] in
            await self?.cancel(subscriptionID)
        }
    }

    func emit(_ event: PageWaitEvent) {
        guard !ended else { return }
        state.apply(event)
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    func finish() {
        guard !ended else { return }
        ended = true
        let active = continuations.values
        continuations.removeAll()
        for continuation in active { continuation.finish() }
    }

    private func cancel(_ subscriptionID: UUID) {
        guard let continuation = continuations.removeValue(forKey: subscriptionID) else {
            return
        }
        continuation.finish()
    }
}

nonisolated struct PageWaitSubscription: Sendable {
    let events: AsyncStream<PageWaitEvent>
    private let cancellationGate: PageWaitCancellationGate

    init(
        events: AsyncStream<PageWaitEvent>,
        onCancel: @escaping @Sendable () async -> Void
    ) {
        self.events = events
        cancellationGate = PageWaitCancellationGate(onCancel: onCancel)
    }

    func cancel() async {
        let task = cancellationGate.cancellationTask()
        await task.value
    }
}

nonisolated private final class PageWaitCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () async -> Void)?
    private var task: Task<Void, Never>?

    init(onCancel: @escaping @Sendable () async -> Void) {
        action = onCancel
    }

    func cancellationTask() -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let task {
            return task
        }
        guard let action else {
            let completedTask = Task<Void, Never> {}
            task = completedTask
            return completedTask
        }
        self.action = nil
        let cancellationTask = Task.detached {
            await action()
        }
        task = cancellationTask
        return cancellationTask
    }
}

nonisolated struct PageWaitCoordinator: Sendable {
    private let source: any PageWaitEventSource

    init<Source: PageWaitEventSource>(source: Source) {
        self.source = source
    }

    func wait(for request: PageWaitRequest) async throws -> PageWaitResult {
        let subscription: PageWaitSubscription
        do {
            subscription = try await source.subscribe(to: request.page)
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw PageWaitError.cancelled(
                    page: request.page,
                    condition: request.condition
                )
            }
            throw error
        }
        return try await withTaskCancellationHandler {
            do {
                let result = try await observe(request, subscription: subscription)
                await subscription.cancel()
                return result
            } catch {
                await subscription.cancel()
                if error is CancellationError || Task.isCancelled {
                    throw PageWaitError.cancelled(
                        page: request.page,
                        condition: request.condition
                    )
                }
                throw error
            }
        } onCancel: {
            Task {
                await subscription.cancel()
            }
        }
    }

    private func observe(
        _ request: PageWaitRequest,
        subscription: PageWaitSubscription
    ) async throws -> PageWaitResult {
        let initialState = try await source.currentState(for: request.page)
        try validate(initialState, for: request.page)
        if let result = try PageWaitEvaluator.evaluate(request.condition, in: initialState) {
            return result
        }

        return try await withThrowingTaskGroup(of: PageWaitResult.self) { group in
            group.addTask {
                var state = initialState
                for await event in subscription.events {
                    try Task.checkCancellation()
                    state.apply(event)
                    try validate(state, for: request.page)
                    if let result = try PageWaitEvaluator.evaluate(request.condition, in: state) {
                        return result
                    }
                }
                try Task.checkCancellation()
                throw PageWaitError.sourceEnded(
                    page: request.page,
                    condition: request.condition
                )
            }
            group.addTask {
                try await ContinuousClock().sleep(for: request.maximumTimeout)
                throw PageWaitError.timedOut(
                    page: request.page,
                    condition: request.condition,
                    maximumTimeout: request.maximumTimeout
                )
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw PageWaitError.sourceEnded(
                    page: request.page,
                    condition: request.condition
                )
            }
            return result
        }
    }

    private func validate(_ state: PageWaitState, for page: PageHandle) throws {
        guard state.page == page else {
            throw PageWaitError.sourcePageMismatch(expected: page, actual: state.page)
        }
        if let snapshot = state.semanticSnapshot, snapshot.page != page {
            throw PageWaitError.sourcePageMismatch(expected: page, actual: snapshot.page)
        }
    }
}

nonisolated private enum PageWaitEvaluator {
    static func evaluate(
        _ condition: PageWaitCondition,
        in state: PageWaitState
    ) throws -> PageWaitResult? {
        switch condition {
        case .load(let expected):
            guard let observed = state.loadState, observed.hasReached(expected) else {
                return nil
            }
            return .load(observed)

        case .url(let expectation):
            guard let url = state.url, expectation.matches(url) else { return nil }
            return .url(url)

        case .selector(let selector):
            guard let snapshot = state.semanticSnapshot else { return nil }
            let references = snapshot.nodes
                .filter { $0.matchedSelectors.contains(selector) }
                .map {
                    $0.reference(
                        on: snapshot.page,
                        navigationGeneration: snapshot.navigationGeneration,
                        documentGeneration: snapshot.documentGeneration
                    )
                }
            guard !references.isEmpty else { return nil }
            return .selector(selector: selector, references: references)

        case .text(let expectation):
            guard let snapshot = state.semanticSnapshot else { return nil }
            let observedText = snapshot.visibleText.isEmpty
                ? snapshot.nodes.map(\.text).joined(separator: " ")
                : snapshot.visibleText
            guard expectation.matches(observedText) else { return nil }
            return .text(expectation: expectation, observedText: observedText)

        case .elementState(let reference, let expectedState, let isPresent):
            guard let snapshot = state.semanticSnapshot else { return nil }
            let node = try SemanticElementResolver.resolve(reference, in: snapshot)
            guard node.states.contains(expectedState) == isPresent else { return nil }
            return .elementState(
                reference: reference,
                state: expectedState,
                isPresent: isPresent
            )

        case .dialog(let expectedKind):
            guard let dialog = state.dialog,
                  expectedKind == nil || dialog.kind == expectedKind else {
                return nil
            }
            return .dialog(dialog)

        case .downloadStarted(let expectedID):
            guard let download = matchingDownload(expectedID, in: state.downloads) else {
                return nil
            }
            return .downloadStarted(download)

        case .downloadCompleted(let expectedID):
            guard let download = matchingDownload(expectedID, in: state.downloads),
                  download.phase == .completed else {
                return nil
            }
            return .downloadCompleted(download)

        case .pageClosed:
            guard state.isClosed else { return nil }
            return .pageClosed(state.page)
        }
    }

    private static func matchingDownload(
        _ expectedID: UUID?,
        in downloads: [UUID: PageDownloadObservation]
    ) -> PageDownloadObservation? {
        if let expectedID {
            return downloads[expectedID]
        }
        return downloads.values.sorted {
            $0.downloadID.uuidString < $1.downloadID.uuidString
        }.first
    }
}

nonisolated struct WebKitAgentMutationObserverConfiguration: Equatable, Sendable {
    static let maximumNodeLimit = 4_096
    static let maximumRootLimit = 128
    static let maximumTextLimit = 65_536
    static let maximumFrameDepthLimit = 32
    static let minimumReportIntervalLimit = 16
    static let maximumReportIntervalLimit = 1_000

    let token: String
    let maximumNodesPerReport: Int
    let maximumObservedRoots: Int
    let maximumTextLength: Int
    let maximumFrameDepth: Int
    let minimumReportIntervalMilliseconds: Int

    init(
        token: String,
        maximumNodesPerReport: Int = 512,
        maximumObservedRoots: Int = 32,
        maximumTextLength: Int = 16_384,
        maximumFrameDepth: Int = 8,
        minimumReportIntervalMilliseconds: Int = 50
    ) {
        self.token = String(token.prefix(128))
        self.maximumNodesPerReport = min(
            max(maximumNodesPerReport, 1),
            Self.maximumNodeLimit
        )
        self.maximumObservedRoots = min(
            max(maximumObservedRoots, 1),
            Self.maximumRootLimit
        )
        self.maximumTextLength = min(
            max(maximumTextLength, 1),
            Self.maximumTextLimit
        )
        self.maximumFrameDepth = min(
            max(maximumFrameDepth, 1),
            Self.maximumFrameDepthLimit
        )
        self.minimumReportIntervalMilliseconds = min(
            max(minimumReportIntervalMilliseconds, Self.minimumReportIntervalLimit),
            Self.maximumReportIntervalLimit
        )
    }
}

nonisolated struct WebKitAgentMutationObserverScripts: Equatable, Sendable {
    static let messageHandlerName = "straightUpAgentWait"

    let installation: String
    let cleanup: String

    init(configuration: WebKitAgentMutationObserverConfiguration) {
        let token = Self.javaScriptStringLiteral(configuration.token)
        installation = """
        (() => {
          'use strict';
          const token = \(token);
          const maxNodes = \(configuration.maximumNodesPerReport);
          const maxRoots = \(configuration.maximumObservedRoots);
          const maxTextLength = \(configuration.maximumTextLength);
          const maxFrameDepth = \(configuration.maximumFrameDepth);
          const reportInterval = \(configuration.minimumReportIntervalMilliseconds);
          const registryKey = '__straightUpAgentWaitObservers';
          const registry = window[registryKey] instanceof Map
            ? window[registryKey]
            : (window[registryKey] = new Map());
          const previousCleanup = registry.get(token);
          if (typeof previousCleanup === 'function') previousCleanup();

          let observer = null;
          let reportTimer = null;
          let disposed = false;
          let nextLocalID = 0;
          let nextLegacyOrdinal = 0;
          const localIDs = new WeakMap();
          const legacyOrdinals = new WeakMap();
          const observedRoots = new Set();

          const cleanup = () => {
            if (disposed) return;
            disposed = true;
            if (reportTimer !== null) clearTimeout(reportTimer);
            if (observer !== null) observer.disconnect();
            observedRoots.clear();
            if (registry.get(token) === cleanup) registry.delete(token);
          };
          registry.set(token, cleanup);

          const localIDFor = (element) => {
            let localID = localIDs.get(element);
            if (localID) return localID;
            localID = `semantic-${token}-${++nextLocalID}`;
            localIDs.set(element, localID);
            return localID;
          };

          const legacyOrdinalFor = (element) => {
            let ordinal = legacyOrdinals.get(element);
            if (ordinal) return ordinal;
            ordinal = ++nextLegacyOrdinal;
            legacyOrdinals.set(element, ordinal);
            return ordinal;
          };

          const boundedString = (value, limit = 512) =>
            String(value || '').slice(0, Math.min(limit, maxTextLength));

          const boundaryReason = (frame, ownerDocument) => {
            try {
              const source = new URL(frame.getAttribute('src') || '', ownerDocument.baseURI);
              return source.origin !== ownerDocument.location.origin
                ? 'crossOrigin'
                : 'inaccessible';
            } catch (_) {
              return 'inaccessible';
            }
          };

          const observeRoot = (root) => {
            if (disposed || observedRoots.has(root) || observedRoots.size >= maxRoots) return;
            observer.observe(root, {
              subtree: true,
              childList: true,
              characterData: true,
              attributes: true,
              attributeFilter: [
                'aria-label', 'aria-checked', 'aria-disabled', 'aria-expanded',
                'aria-selected', 'disabled', 'hidden', 'open', 'role', 'style',
                'value', 'class'
              ]
            });
            observedRoots.add(root);
          };

          const scan = () => {
            const nodes = [];
            const inaccessibleFrameBoundaries = [];
            const queue = [{ root: document, path: [], depth: 0 }];
            let enqueuedRoots = 1;
            let remainingText = maxTextLength;
            let visitedNodes = 0;

            const takeText = (value) => {
              if (remainingText <= 0) return '';
              const result = String(value || '').slice(0, remainingText);
              remainingText -= result.length;
              return result;
            };

            while (queue.length > 0 && visitedNodes < maxNodes) {
              const current = queue.shift();
              const root = current.root;
              const ownerDocument = root.nodeType === Node.DOCUMENT_NODE
                ? root
                : root.ownerDocument;
              if (!ownerDocument) continue;

              try {
                observeRoot(root);
              } catch (_) {
                continue;
              }

              const walker = ownerDocument.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
              let element = walker.nextNode();
              while (element && visitedNodes < maxNodes) {
                visitedNodes += 1;
                const localID = localIDFor(element);
                const legacyOrdinal = legacyOrdinalFor(element);
                const rectangle = element.getBoundingClientRect();
                const states = [];
                if (!element.hidden && rectangle.width > 0 && rectangle.height > 0) {
                  states.push('visible');
                }
                if ('disabled' in element && element.disabled) {
                  states.push('disabled');
                } else {
                  states.push('enabled');
                }
                if ('checked' in element && element.checked) states.push('checked');
                if (element.getAttribute('aria-selected') === 'true') states.push('selected');
                if (element.getAttribute('aria-expanded') === 'true') states.push('expanded');
                if (element.isContentEditable) states.push('editable');
                if (ownerDocument.activeElement === element) states.push('focused');

                nodes.push({
                  localID,
                  legacySubID: legacyOrdinal,
                  role: boundedString(
                    element.getAttribute('role') || element.tagName.toLowerCase()
                  ),
                  name: takeText(
                    element.getAttribute('aria-label') ||
                    element.getAttribute('alt') ||
                    element.getAttribute('title') ||
                    element.textContent || ''
                  ),
                  states,
                  frameContext: current.path,
                  geometryDigest: [
                    rectangle.x, rectangle.y, rectangle.width, rectangle.height
                  ].map(value => Math.round(value)).join(':'),
                  text: takeText(element.textContent || '')
                });

                if (element.shadowRoot && current.depth < maxFrameDepth && enqueuedRoots < maxRoots) {
                  queue.push({
                    root: element.shadowRoot,
                    path: current.path.concat([{
                      kind: 'openShadowRoot',
                      hostLocalID: localID
                    }]),
                    depth: current.depth + 1
                  });
                  enqueuedRoots += 1;
                }

                if (element.tagName === 'IFRAME' || element.tagName === 'FRAME') {
                  let frameDocument = null;
                  try {
                    frameDocument = element.contentDocument;
                  } catch (_) {
                    frameDocument = null;
                  }
                  if (frameDocument && current.depth < maxFrameDepth && enqueuedRoots < maxRoots) {
                    var origin = null;
                    try {
                      origin = frameDocument.location.origin;
                    } catch (_) {
                      origin = null;
                    }
                    queue.push({
                      root: frameDocument,
                      path: current.path.concat([{
                        kind: 'sameOriginFrame',
                        localID,
                        origin: boundedString(origin)
                      }]),
                      depth: current.depth + 1
                    });
                    enqueuedRoots += 1;
                  } else {
                    inaccessibleFrameBoundaries.push({
                      parentContext: current.path,
                      frameLocalID: localID,
                      sourceURL: boundedString(element.getAttribute('src')),
                      reason: frameDocument ? 'inaccessible' : boundaryReason(element, ownerDocument)
                    });
                  }
                }

                element = walker.nextNode();
              }
            }

            return {
              type: 'semanticPageMutation',
              token,
              nodes,
              inaccessibleFrameBoundaries,
              visibleText: nodes.map(node => node.text).join(' ').slice(0, maxTextLength),
              limits: { maxNodes, maxRoots, maxTextLength, maxFrameDepth }
            };
          };

          const publish = () => {
            reportTimer = null;
            if (disposed) return;
            const handler = window.webkit &&
              window.webkit.messageHandlers &&
              window.webkit.messageHandlers.\(Self.messageHandlerName);
            if (handler && typeof handler.postMessage === 'function') {
              handler.postMessage(scan());
            } else {
              scan();
            }
          };

          const schedule = () => {
            if (disposed || reportTimer !== null) return;
            reportTimer = setTimeout(publish, reportInterval);
          };

          observer = new MutationObserver(schedule);
          publish();
          return token;
        })();
        """

        cleanup = """
        (() => {
          'use strict';
          const token = \(token);
          const registry = window.__straightUpAgentWaitObservers;
          const cleanup = registry instanceof Map ? registry.get(token) : null;
          if (typeof cleanup === 'function') cleanup();
        })();
        """
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed]
        ), let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }
}
