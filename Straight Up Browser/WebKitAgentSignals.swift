import Foundation

// MARK: - Scope, retention, and coverage

nonisolated enum WebKitAgentSignalSession: Codable, Equatable, Hashable, Sendable {
    case normal
    case container(UUID)
    case incognito(UUID)

    var isIncognito: Bool {
        if case .incognito = self { return true }
        return false
    }
}

nonisolated struct WebKitAgentSignalScope: Codable, Equatable, Hashable, Sendable {
    let runID: UUID
    let page: PageHandle
    let browserSession: WebKitAgentSignalSession

    init(
        runID: UUID,
        page: PageHandle,
        browserSession: WebKitAgentSignalSession
    ) {
        self.runID = runID
        self.page = page
        self.browserSession = browserSession
    }
}

nonisolated enum WebKitAgentSignalRetention: Codable, Equatable, Sendable {
    /// Never eligible for durable storage. The coordinator clears this at scope end.
    case memoryOnly
    /// Only the payload's content-free projection is eligible for durable storage.
    case metadataOnly
    /// Content may be stored locally until the supplied deadline.
    case contentUntil(Date)
}

nonisolated enum WebKitAgentSignalSourceTrust: String, Codable, Equatable, Sendable {
    case webKitMetadata
    case hostilePageData
}

nonisolated enum WebKitAgentSignalCoverage: String, Codable, Equatable, Hashable, Sendable {
    case mainNavigationDelegate
    case frameNavigationDelegate
    case documentScriptBridge
    case sameOriginFrameScriptBridge
    case crossOriginBoundary
    case contentRuleList
    case customURLScheme
    case downloadDelegate
    case uiDelegate
    case pageLifecycle
}

nonisolated enum WebKitAgentSignalSupport: String, Codable, Equatable, Sendable {
    case supported
    case optInScriptBridge
    case mainAndFrameNavigationsOnly
    case reportedWebKitHooksOnly
    case unsupported
}

nonisolated struct WebKitAgentSignalCapabilityMatrix: Codable, Equatable, Sendable {
    var consoleMessages: WebKitAgentSignalSupport
    var navigationResponses: WebKitAgentSignalSupport
    var resourceFailures: WebKitAgentSignalSupport
    var downloads: WebKitAgentSignalSupport
    var dialogs: WebKitAgentSignalSupport
    var pageLifecycle: WebKitAgentSignalSupport
    var networkRequestIdentifiers: WebKitAgentSignalSupport
    var responseBodies: WebKitAgentSignalSupport
    var timingWaterfalls: WebKitAgentSignalSupport
    var cacheInternals: WebKitAgentSignalSupport

    static let nativeWebKit = Self(
        consoleMessages: .optInScriptBridge,
        navigationResponses: .mainAndFrameNavigationsOnly,
        resourceFailures: .reportedWebKitHooksOnly,
        downloads: .supported,
        dialogs: .supported,
        pageLifecycle: .supported,
        networkRequestIdentifiers: .unsupported,
        responseBodies: .unsupported,
        timingWaterfalls: .unsupported,
        cacheInternals: .unsupported
    )
}

nonisolated struct WebKitAgentSignalToolMetadata: Equatable, Sendable {
    let toolName: String
    let risk: AgentToolRisk
    let baseRequiredCapabilities: Set<AgentCapability>
    let additionalCapabilitiesByKind: [WebKitAgentSignalKind: Set<AgentCapability>]
    let retentionIsExplicit: Bool
    let coverageDescription: String

    static let canonical: [Self] = [
        Self(
            toolName: "observe_webkit_signals",
            risk: .observe,
            baseRequiredCapabilities: [.pageRead],
            additionalCapabilitiesByKind: [
                .console: [.pageScript],
                .download: [.download],
            ],
            retentionIsExplicit: true,
            coverageDescription: "Reads bounded WebKit-native signals. HTTP status and redirects describe main-frame navigation and frame-navigation delegate callbacks; resource failures are only those surfaced by supported WebKit hooks, not a complete subresource log."
        ),
        Self(
            toolName: "wait_for_webkit_signal",
            risk: .observe,
            baseRequiredCapabilities: [.pageRead],
            additionalCapabilitiesByKind: [
                .console: [.pageScript],
                .download: [.download],
            ],
            retentionIsExplicit: true,
            coverageDescription: "Waits for a bounded WebKit delegate or opted-in page-bridge observation. It does not promise general network interception or Chromium request lifecycle semantics."
        ),
    ]
}

// MARK: - Privacy-safe values

nonisolated enum WebKitAgentURLRedaction: String, Codable, Equatable, Hashable, Sendable {
    case credentials
    case path
    case query
    case fragment
    case unparseable
}

nonisolated struct WebKitAgentObservedURL: Codable, Equatable, Sendable {
    let origin: String?
    let path: String?
    let redactions: Set<WebKitAgentURLRedaction>

    /// Signals intentionally never retain URL query strings.
    var queryIsRetained: Bool { false }
}

nonisolated enum WebKitAgentSignalRedactionReason: String, Codable, Equatable, Sendable {
    case privacyPolicy
    case retentionPolicy
    case crossOrigin
    case incognito
}

nonisolated enum WebKitAgentSensitiveText: Codable, Equatable, Sendable {
    case captured(String, truncated: Bool)
    case redacted(WebKitAgentSignalRedactionReason)
}

nonisolated enum WebKitAgentConsoleLevel: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case debug
    case log
    case info
    case warning
    case error
}

nonisolated enum WebKitAgentFrameSource: Codable, Equatable, Hashable, Sendable {
    case mainFrame
    case sameOriginSubframe(origin: String?)
    case crossOriginBoundary(origin: String?)

    private enum CodingKeys: String, CodingKey {
        case kind
        case origin
    }

    private enum Kind: String, Codable {
        case mainFrame
        case sameOriginSubframe
        case crossOriginBoundary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .mainFrame:
            self = .mainFrame
        case .sameOriginSubframe:
            self = .sameOriginSubframe(
                origin: try container.decodeIfPresent(String.self, forKey: .origin)
            )
        case .crossOriginBoundary:
            self = .crossOriginBoundary(
                origin: try container.decodeIfPresent(String.self, forKey: .origin)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .mainFrame:
            try container.encode(Kind.mainFrame, forKey: .kind)
        case .sameOriginSubframe(let origin):
            try container.encode(Kind.sameOriginSubframe, forKey: .kind)
            try container.encodeIfPresent(origin, forKey: .origin)
        case .crossOriginBoundary(let origin):
            try container.encode(Kind.crossOriginBoundary, forKey: .kind)
            try container.encodeIfPresent(origin, forKey: .origin)
        }
    }

    var coverage: WebKitAgentSignalCoverage {
        switch self {
        case .mainFrame: .documentScriptBridge
        case .sameOriginSubframe: .sameOriginFrameScriptBridge
        case .crossOriginBoundary: .crossOriginBoundary
        }
    }

    var isCrossOrigin: Bool {
        if case .crossOriginBoundary = self { return true }
        return false
    }
}

// MARK: - Final signal payloads

nonisolated struct WebKitAgentConsoleSignal: Codable, Equatable, Sendable {
    let level: WebKitAgentConsoleLevel
    let message: WebKitAgentSensitiveText
    let sourceURL: WebKitAgentObservedURL?
    let line: UInt?
    let column: UInt?
    let frame: WebKitAgentFrameSource
    let coverage: WebKitAgentSignalCoverage
}

nonisolated enum WebKitAgentNavigationPhase: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case provisionalStarted
    case serverRedirectObserved
    case responseReceived
    case committed
    case finished
    case failed
}

nonisolated enum WebKitAgentTLSState: String, Codable, Equatable, Hashable, Sendable {
    case secure
    case insecure
    case userOverridden
    case notApplicable
    case unknown
    case unsupported
}

nonisolated struct WebKitAgentNavigationSignal: Codable, Equatable, Sendable {
    /// Local correlation for one WKNavigation observation. This is not a network request ID.
    let observationID: UUID
    let phase: WebKitAgentNavigationPhase
    let url: WebKitAgentObservedURL?
    let redirectSourceURL: WebKitAgentObservedURL?
    let statusCode: Int?
    let mimeType: String?
    let canShowMIMEType: Bool?
    let tlsState: WebKitAgentTLSState
    let coverage: WebKitAgentSignalCoverage
}

nonisolated enum WebKitAgentResourceFailureSurface: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case mainNavigationDelegate
    case frameNavigationDelegate
    case contentRuleList
    case customURLScheme
    case documentScriptError

    var coverage: WebKitAgentSignalCoverage {
        switch self {
        case .mainNavigationDelegate: .mainNavigationDelegate
        case .frameNavigationDelegate: .frameNavigationDelegate
        case .contentRuleList: .contentRuleList
        case .customURLScheme: .customURLScheme
        case .documentScriptError: .documentScriptBridge
        }
    }
}

nonisolated struct WebKitAgentResourceFailureSignal: Codable, Equatable, Sendable {
    /// Locally generated observation identity, never a fabricated CDP request ID.
    let observationID: UUID
    let surface: WebKitAgentResourceFailureSurface
    let coverage: WebKitAgentSignalCoverage
    let url: WebKitAgentObservedURL?
    let errorDomain: String
    let errorCode: Int
    let errorDescription: WebKitAgentSensitiveText
}

nonisolated enum WebKitAgentDownloadPhase: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case started
    case destinationSelected
    case progress
    case completed
    case failed
    case cancelled
}

nonisolated struct WebKitAgentDownloadSignal: Codable, Equatable, Sendable {
    let downloadID: UUID
    let phase: WebKitAgentDownloadPhase
    let sourceURL: WebKitAgentObservedURL?
    let suggestedFilename: WebKitAgentSensitiveText
    let progress: Double?
    let receivedBytes: UInt64?
    let expectedBytes: UInt64?
    let errorDomain: String?
    let errorCode: Int?
    let errorDescription: WebKitAgentSensitiveText
    let coverage: WebKitAgentSignalCoverage
}

nonisolated enum WebKitAgentDialogPhase: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case presented
    case dismissed
}

nonisolated enum WebKitAgentDialogKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case alert
    case confirm
    case prompt
    case beforeUnload
}

nonisolated struct WebKitAgentDialogSignal: Codable, Equatable, Sendable {
    let dialogID: UUID
    let phase: WebKitAgentDialogPhase
    let kind: WebKitAgentDialogKind
    let message: WebKitAgentSensitiveText
    let defaultText: WebKitAgentSensitiveText
    let coverage: WebKitAgentSignalCoverage
}

nonisolated enum WebKitAgentPageLifecyclePhase: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case loadStarted
    case contentCommitted
    case domContentLoaded
    case loadCompleted
    case webContentProcessTerminated
    case closed
}

nonisolated struct WebKitAgentPageLifecycleSignal: Codable, Equatable, Sendable {
    let phase: WebKitAgentPageLifecyclePhase
    let url: WebKitAgentObservedURL?
    let coverage: WebKitAgentSignalCoverage

    init(
        phase: WebKitAgentPageLifecyclePhase,
        url: WebKitAgentObservedURL? = nil,
        coverage: WebKitAgentSignalCoverage = .pageLifecycle
    ) {
        self.phase = phase
        self.url = url
        self.coverage = coverage
    }
}

nonisolated enum WebKitAgentSignalKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case console
    case navigation
    case resourceFailure
    case download
    case dialog
    case pageLifecycle
}

nonisolated enum WebKitAgentSignal: Codable, Equatable, Sendable {
    case console(WebKitAgentConsoleSignal)
    case navigation(WebKitAgentNavigationSignal)
    case resourceFailure(WebKitAgentResourceFailureSignal)
    case download(WebKitAgentDownloadSignal)
    case dialog(WebKitAgentDialogSignal)
    case pageLifecycle(WebKitAgentPageLifecycleSignal)

    var kind: WebKitAgentSignalKind {
        switch self {
        case .console: .console
        case .navigation: .navigation
        case .resourceFailure: .resourceFailure
        case .download: .download
        case .dialog: .dialog
        case .pageLifecycle: .pageLifecycle
        }
    }

    var sourceTrust: WebKitAgentSignalSourceTrust {
        switch self {
        case .console, .dialog:
            .hostilePageData
        case .navigation, .resourceFailure, .download, .pageLifecycle:
            .webKitMetadata
        }
    }

    fileprivate func metadataOnlyProjection() -> Self {
        switch self {
        case .console(let value):
            .console(WebKitAgentConsoleSignal(
                level: value.level,
                message: .redacted(.retentionPolicy),
                sourceURL: value.sourceURL,
                line: value.line,
                column: value.column,
                frame: value.frame,
                coverage: value.coverage
            ))
        case .navigation:
            self
        case .resourceFailure(let value):
            .resourceFailure(WebKitAgentResourceFailureSignal(
                observationID: value.observationID,
                surface: value.surface,
                coverage: value.coverage,
                url: value.url,
                errorDomain: value.errorDomain,
                errorCode: value.errorCode,
                errorDescription: .redacted(.retentionPolicy)
            ))
        case .download(let value):
            .download(WebKitAgentDownloadSignal(
                downloadID: value.downloadID,
                phase: value.phase,
                sourceURL: value.sourceURL,
                suggestedFilename: .redacted(.retentionPolicy),
                progress: value.progress,
                receivedBytes: value.receivedBytes,
                expectedBytes: value.expectedBytes,
                errorDomain: value.errorDomain,
                errorCode: value.errorCode,
                errorDescription: .redacted(.retentionPolicy),
                coverage: value.coverage
            ))
        case .dialog(let value):
            .dialog(WebKitAgentDialogSignal(
                dialogID: value.dialogID,
                phase: value.phase,
                kind: value.kind,
                message: .redacted(.retentionPolicy),
                defaultText: .redacted(.retentionPolicy),
                coverage: value.coverage
            ))
        case .pageLifecycle:
            self
        }
    }
}

nonisolated struct WebKitAgentSignalEnvelope: Codable, Equatable, Sendable {
    let sequence: UInt64
    let timestamp: Date
    let scope: WebKitAgentSignalScope
    let retention: WebKitAgentSignalRetention
    let sourceTrust: WebKitAgentSignalSourceTrust
    let signal: WebKitAgentSignal

    /// Page content and WebKit observations are evidence only. They never add authority.
    var canGrantAuthority: Bool { false }

    func persistableProjection() -> Self? {
        switch retention {
        case .memoryOnly:
            nil
        case .metadataOnly:
            Self(
                sequence: sequence,
                timestamp: timestamp,
                scope: scope,
                retention: retention,
                sourceTrust: sourceTrust,
                signal: signal.metadataOnlyProjection()
            )
        case .contentUntil:
            self
        }
    }
}

// MARK: - Unsanitized inputs (native delegate/script boundaries)

nonisolated struct WebKitAgentConsoleSignalDraft: Equatable, Sendable {
    var level: WebKitAgentConsoleLevel
    var message: String
    var sourceURL: URL?
    var line: UInt?
    var column: UInt?
    var frame: WebKitAgentFrameSource

    init(
        level: WebKitAgentConsoleLevel,
        message: String,
        sourceURL: URL? = nil,
        line: UInt? = nil,
        column: UInt? = nil,
        frame: WebKitAgentFrameSource = .mainFrame
    ) {
        self.level = level
        self.message = message
        self.sourceURL = sourceURL
        self.line = line
        self.column = column
        self.frame = frame
    }
}

nonisolated struct WebKitAgentNavigationSignalDraft: Equatable, Sendable {
    var observationID: UUID
    var phase: WebKitAgentNavigationPhase
    var url: URL?
    var redirectSourceURL: URL?
    var statusCode: Int?
    var mimeType: String?
    var canShowMIMEType: Bool?
    var tlsState: WebKitAgentTLSState
    var isMainFrame: Bool
    var isCrossOrigin: Bool

    init(
        observationID: UUID,
        phase: WebKitAgentNavigationPhase,
        url: URL? = nil,
        redirectSourceURL: URL? = nil,
        statusCode: Int? = nil,
        mimeType: String? = nil,
        canShowMIMEType: Bool? = nil,
        tlsState: WebKitAgentTLSState = .unknown,
        isMainFrame: Bool,
        isCrossOrigin: Bool = false
    ) {
        self.observationID = observationID
        self.phase = phase
        self.url = url
        self.redirectSourceURL = redirectSourceURL
        self.statusCode = statusCode
        self.mimeType = mimeType
        self.canShowMIMEType = canShowMIMEType
        self.tlsState = tlsState
        self.isMainFrame = isMainFrame
        self.isCrossOrigin = isCrossOrigin
    }
}

nonisolated struct WebKitAgentResourceFailureSignalDraft: Equatable, Sendable {
    var observationID: UUID
    var surface: WebKitAgentResourceFailureSurface
    var url: URL?
    var errorDomain: String
    var errorCode: Int
    var errorDescription: String

    init(
        observationID: UUID,
        surface: WebKitAgentResourceFailureSurface,
        url: URL? = nil,
        errorDomain: String,
        errorCode: Int,
        errorDescription: String
    ) {
        self.observationID = observationID
        self.surface = surface
        self.url = url
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.errorDescription = errorDescription
    }
}

nonisolated struct WebKitAgentDownloadSignalDraft: Equatable, Sendable {
    var downloadID: UUID
    var phase: WebKitAgentDownloadPhase
    var sourceURL: URL?
    var suggestedFilename: String?
    var progress: Double?
    var receivedBytes: UInt64?
    var expectedBytes: UInt64?
    var errorDomain: String?
    var errorCode: Int?
    var errorDescription: String?

    init(
        downloadID: UUID,
        phase: WebKitAgentDownloadPhase,
        sourceURL: URL? = nil,
        suggestedFilename: String? = nil,
        progress: Double? = nil,
        receivedBytes: UInt64? = nil,
        expectedBytes: UInt64? = nil,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        errorDescription: String? = nil
    ) {
        self.downloadID = downloadID
        self.phase = phase
        self.sourceURL = sourceURL
        self.suggestedFilename = suggestedFilename
        self.progress = progress
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.errorDescription = errorDescription
    }
}

nonisolated struct WebKitAgentDialogSignalDraft: Equatable, Sendable {
    var dialogID: UUID
    var phase: WebKitAgentDialogPhase
    var kind: WebKitAgentDialogKind
    var message: String?
    var defaultText: String?

    init(
        dialogID: UUID,
        phase: WebKitAgentDialogPhase,
        kind: WebKitAgentDialogKind,
        message: String? = nil,
        defaultText: String? = nil
    ) {
        self.dialogID = dialogID
        self.phase = phase
        self.kind = kind
        self.message = message
        self.defaultText = defaultText
    }
}

nonisolated struct WebKitAgentPageLifecycleSignalDraft: Equatable, Sendable {
    var phase: WebKitAgentPageLifecyclePhase
    var url: URL?

    init(phase: WebKitAgentPageLifecyclePhase, url: URL? = nil) {
        self.phase = phase
        self.url = url
    }
}

nonisolated enum WebKitAgentSignalDraft: Equatable, Sendable {
    case console(WebKitAgentConsoleSignalDraft)
    case navigation(WebKitAgentNavigationSignalDraft)
    case resourceFailure(WebKitAgentResourceFailureSignalDraft)
    case download(WebKitAgentDownloadSignalDraft)
    case dialog(WebKitAgentDialogSignalDraft)
    case pageLifecycle(WebKitAgentPageLifecycleSignalDraft)
}

// MARK: - Configuration and observation contracts

nonisolated struct WebKitAgentSignalPrivacyPolicy: Equatable, Sendable {
    static let maximumTextByteLimit = 64 * 1_024

    var captureConsoleMessages: Bool
    var captureDialogText: Bool
    var captureSuggestedFilenames: Bool
    var captureErrorDescriptions: Bool
    var allowSameOriginURLPaths: Bool
    var captureCrossOriginConsole: Bool
    var maximumConsoleMessageBytes: Int
    var maximumDialogTextBytes: Int
    var maximumFilenameBytes: Int
    var maximumErrorDescriptionBytes: Int
    var standardRetention: WebKitAgentSignalRetention
    var incognitoContentRetentionOptIn: Bool

    init(
        captureConsoleMessages: Bool = false,
        captureDialogText: Bool = false,
        captureSuggestedFilenames: Bool = false,
        captureErrorDescriptions: Bool = false,
        allowSameOriginURLPaths: Bool = false,
        captureCrossOriginConsole: Bool = false,
        maximumConsoleMessageBytes: Int = 4_096,
        maximumDialogTextBytes: Int = 2_048,
        maximumFilenameBytes: Int = 512,
        maximumErrorDescriptionBytes: Int = 1_024,
        standardRetention: WebKitAgentSignalRetention = .metadataOnly,
        incognitoContentRetentionOptIn: Bool = false
    ) {
        self.captureConsoleMessages = captureConsoleMessages
        self.captureDialogText = captureDialogText
        self.captureSuggestedFilenames = captureSuggestedFilenames
        self.captureErrorDescriptions = captureErrorDescriptions
        self.allowSameOriginURLPaths = allowSameOriginURLPaths
        self.captureCrossOriginConsole = captureCrossOriginConsole
        self.maximumConsoleMessageBytes = Self.clampText(maximumConsoleMessageBytes)
        self.maximumDialogTextBytes = Self.clampText(maximumDialogTextBytes)
        self.maximumFilenameBytes = Self.clampText(maximumFilenameBytes)
        self.maximumErrorDescriptionBytes = Self.clampText(maximumErrorDescriptionBytes)
        self.standardRetention = standardRetention
        self.incognitoContentRetentionOptIn = incognitoContentRetentionOptIn
    }

    private static func clampText(_ value: Int) -> Int {
        min(max(value, 1), maximumTextByteLimit)
    }
}

nonisolated struct WebKitAgentSignalHubConfiguration: Equatable, Sendable {
    static let maximumScopeLimit = 1_024
    static let maximumEventCountLimit = 4_096
    static let maximumBufferByteLimit = 16 * 1_024 * 1_024
    static let maximumEventByteLimit = 1 * 1_024 * 1_024
    static let maximumSubscriberLimit = 64
    static let maximumSubscriptionBufferLimit = 1_024

    let maximumActiveScopes: Int
    let maximumBufferedEventsPerScope: Int
    let maximumBufferedBytesPerScope: Int
    let maximumEventBytes: Int
    let maximumSubscribersPerScope: Int
    let maximumSubscriptionBufferEvents: Int
    let privacy: WebKitAgentSignalPrivacyPolicy

    init(
        maximumActiveScopes: Int = 128,
        maximumBufferedEventsPerScope: Int = 256,
        maximumBufferedBytesPerScope: Int = 1 * 1_024 * 1_024,
        maximumEventBytes: Int = 64 * 1_024,
        maximumSubscribersPerScope: Int = 16,
        maximumSubscriptionBufferEvents: Int = 64,
        privacy: WebKitAgentSignalPrivacyPolicy = .init()
    ) {
        self.maximumActiveScopes = min(max(maximumActiveScopes, 1), Self.maximumScopeLimit)
        self.maximumBufferedEventsPerScope = min(
            max(maximumBufferedEventsPerScope, 1),
            Self.maximumEventCountLimit
        )
        self.maximumBufferedBytesPerScope = min(
            max(maximumBufferedBytesPerScope, 512),
            Self.maximumBufferByteLimit
        )
        self.maximumEventBytes = min(
            max(maximumEventBytes, 256),
            min(Self.maximumEventByteLimit, self.maximumBufferedBytesPerScope)
        )
        self.maximumSubscribersPerScope = min(
            max(maximumSubscribersPerScope, 1),
            Self.maximumSubscriberLimit
        )
        self.maximumSubscriptionBufferEvents = min(
            max(maximumSubscriptionBufferEvents, 1),
            Self.maximumSubscriptionBufferLimit
        )
        self.privacy = privacy
    }
}

nonisolated struct WebKitAgentSignalDropAccounting: Codable, Equatable, Sendable {
    var bufferEvictedEvents: UInt64 = 0
    var bufferEvictedBytes: UInt64 = 0
    var oversizedEvents: UInt64 = 0
    var subscriptionBackpressureEvents: UInt64 = 0
    var privacyFilteredEvents: UInt64 = 0
}

nonisolated struct WebKitAgentSignalFilter: Equatable, Sendable {
    static let maximumResultLimit = 512

    let kinds: Set<WebKitAgentSignalKind>
    let afterSequence: UInt64
    let maximumResults: Int

    init(
        kinds: Set<WebKitAgentSignalKind> = [],
        afterSequence: UInt64 = 0,
        maximumResults: Int = 200
    ) {
        self.kinds = kinds
        self.afterSequence = afterSequence
        self.maximumResults = min(max(maximumResults, 1), Self.maximumResultLimit)
    }

    func matches(_ event: WebKitAgentSignalEnvelope) -> Bool {
        event.sequence > afterSequence && (kinds.isEmpty || kinds.contains(event.signal.kind))
    }
}

nonisolated struct WebKitAgentSignalSnapshot: Codable, Equatable, Sendable {
    let scope: WebKitAgentSignalScope
    let events: [WebKitAgentSignalEnvelope]
    let latestSequence: UInt64
    let dropAccounting: WebKitAgentSignalDropAccounting
    let isClosed: Bool
}

nonisolated enum WebKitAgentUnsupportedDetail: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case networkRequestIdentifier
    case completeSubresourceRequestLog
    case requestTimingWaterfall
    case cacheInternals
    case responseBody
    case rawResponseHeaders
    case remoteIPAddress
    case serviceWorkerInternals
}

nonisolated struct WebKitAgentUnsupportedResult: Codable, Equatable, Sendable {
    let detail: WebKitAgentUnsupportedDetail
    let reason: String
    let nativeAlternative: String?
}

nonisolated enum WebKitAgentObservationQuery: Equatable, Sendable {
    case buffered(WebKitAgentSignalFilter = .init())
    case detail(WebKitAgentUnsupportedDetail)
}

nonisolated enum WebKitAgentObservationResult: Equatable, Sendable {
    case buffered(WebKitAgentSignalSnapshot)
    case unsupported(WebKitAgentUnsupportedResult)
}

nonisolated enum WebKitAgentSignalDiscardReason: String, Codable, Equatable, Sendable {
    case consoleCaptureNotEnabled
    case crossOriginConsoleDenied
    case eventTooLarge
    case scopeClosed
}

nonisolated enum WebKitAgentSignalPublishDisposition: Equatable, Sendable {
    case accepted(sequence: UInt64, evictedEvents: Int, subscriberDrops: Int)
    case discarded(WebKitAgentSignalDiscardReason)
}

nonisolated enum WebKitAgentSignalHubError: Error, Equatable, Sendable {
    case browserSessionMismatch(
        runID: UUID,
        page: PageHandle,
        expected: WebKitAgentSignalSession,
        actual: WebKitAgentSignalSession
    )
    case activeScopeLimit(Int)
    case subscriberLimit(scope: WebKitAgentSignalScope, maximum: Int)
    case encodingFailed
}

// MARK: - Subscription and event source

nonisolated protocol WebKitAgentSignalEventSource: Sendable {
    func snapshot(
        in scope: WebKitAgentSignalScope,
        matching filter: WebKitAgentSignalFilter
    ) async throws -> WebKitAgentSignalSnapshot

    func subscribe(
        to scope: WebKitAgentSignalScope,
        matching filter: WebKitAgentSignalFilter
    ) async throws -> WebKitAgentSignalSubscription
}

nonisolated extension WebKitAgentSignalEventSource {
    func snapshot(in scope: WebKitAgentSignalScope) async throws -> WebKitAgentSignalSnapshot {
        try await snapshot(in: scope, matching: .init())
    }

    func subscribe(to scope: WebKitAgentSignalScope) async throws -> WebKitAgentSignalSubscription {
        try await subscribe(to: scope, matching: .init())
    }
}

nonisolated struct WebKitAgentSignalSubscription: Sendable {
    let events: AsyncStream<WebKitAgentSignalEnvelope>
    private let cancellationGate: WebKitAgentSignalCancellationGate

    fileprivate init(
        events: AsyncStream<WebKitAgentSignalEnvelope>,
        onCancel: @escaping @Sendable () async -> Void
    ) {
        self.events = events
        cancellationGate = WebKitAgentSignalCancellationGate(onCancel: onCancel)
    }

    func cancel() async {
        await cancellationGate.cancellationTask().value
    }
}

nonisolated private final class WebKitAgentSignalCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () async -> Void)?
    private var task: Task<Void, Never>?

    init(onCancel: @escaping @Sendable () async -> Void) {
        action = onCancel
    }

    func cancellationTask() -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let task { return task }
        guard let action else {
            let completed = Task<Void, Never> {}
            task = completed
            return completed
        }
        self.action = nil
        let created = Task.detached { await action() }
        task = created
        return created
    }
}

// MARK: - Bounded signal hub

actor WebKitAgentSignalHub: WebKitAgentSignalEventSource {
    private struct RunPageKey: Hashable {
        let runID: UUID
        let page: PageHandle
    }

    private struct StoredEvent {
        let envelope: WebKitAgentSignalEnvelope
        let bytes: Int
    }

    private struct Subscriber {
        let filter: WebKitAgentSignalFilter
        let continuation: AsyncStream<WebKitAgentSignalEnvelope>.Continuation
    }

    private struct ScopeState {
        var nextSequence: UInt64 = 1
        var events: [StoredEvent] = []
        var bufferedBytes = 0
        var dropAccounting = WebKitAgentSignalDropAccounting()
        var subscribers: [UUID: Subscriber] = [:]
        var isClosed = false
    }

    let configuration: WebKitAgentSignalHubConfiguration
    private let now: @Sendable () -> Date
    private var pageBindings: [RunPageKey: WebKitAgentSignalSession] = [:]
    private var scopes: [WebKitAgentSignalScope: ScopeState] = [:]

    init(
        configuration: WebKitAgentSignalHubConfiguration = .init(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.now = now
    }

    var activeScopeCount: Int { scopes.count }

    var activeSubscriptionCount: Int {
        scopes.values.reduce(0) { $0 + $1.subscribers.count }
    }

    func publish(
        _ draft: WebKitAgentSignalDraft,
        in scope: WebKitAgentSignalScope
    ) throws -> WebKitAgentSignalPublishDisposition {
        try ensureScope(scope)
        guard var state = scopes[scope] else {
            throw WebKitAgentSignalHubError.encodingFailed
        }
        guard !state.isClosed else { return .discarded(.scopeClosed) }

        let sanitized = WebKitAgentSignalSanitizer.sanitize(
            draft,
            policy: configuration.privacy
        )
        let signal: WebKitAgentSignal
        switch sanitized {
        case .accepted(let accepted):
            signal = accepted
        case .discarded(let reason):
            state.dropAccounting.privacyFilteredEvents &+= 1
            scopes[scope] = state
            return .discarded(reason)
        }

        let retention: WebKitAgentSignalRetention = if scope.browserSession.isIncognito,
                                                       !configuration.privacy.incognitoContentRetentionOptIn {
            .memoryOnly
        } else {
            configuration.privacy.standardRetention
        }
        let envelope = WebKitAgentSignalEnvelope(
            sequence: state.nextSequence,
            timestamp: now(),
            scope: scope,
            retention: retention,
            sourceTrust: signal.sourceTrust,
            signal: signal
        )
        let encodedSize: Int
        do {
            encodedSize = try JSONEncoder().encode(envelope).count
        } catch {
            throw WebKitAgentSignalHubError.encodingFailed
        }
        guard encodedSize <= configuration.maximumEventBytes,
              encodedSize <= configuration.maximumBufferedBytesPerScope else {
            state.dropAccounting.oversizedEvents &+= 1
            scopes[scope] = state
            return .discarded(.eventTooLarge)
        }

        state.nextSequence &+= 1
        state.events.append(StoredEvent(envelope: envelope, bytes: encodedSize))
        state.bufferedBytes += encodedSize
        var evictedEvents = 0
        while state.events.count > configuration.maximumBufferedEventsPerScope
                || state.bufferedBytes > configuration.maximumBufferedBytesPerScope {
            let removed = state.events.removeFirst()
            state.bufferedBytes -= removed.bytes
            state.dropAccounting.bufferEvictedEvents &+= 1
            state.dropAccounting.bufferEvictedBytes &+= UInt64(removed.bytes)
            evictedEvents += 1
        }

        var subscriberDrops = 0
        var terminated: [UUID] = []
        for (subscriptionID, subscriber) in state.subscribers {
            guard subscriber.filter.matches(envelope) else { continue }
            switch subscriber.continuation.yield(envelope) {
            case .enqueued:
                break
            case .dropped:
                state.dropAccounting.subscriptionBackpressureEvents &+= 1
                subscriberDrops += 1
            case .terminated:
                terminated.append(subscriptionID)
            @unknown default:
                terminated.append(subscriptionID)
            }
        }
        for subscriptionID in terminated {
            state.subscribers.removeValue(forKey: subscriptionID)
        }

        let closesPage: Bool = if case .pageLifecycle(let lifecycle) = signal {
            lifecycle.phase == .closed
        } else {
            false
        }
        if closesPage { state.isClosed = true }
        scopes[scope] = state
        if closesPage {
            finishSubscriptions(in: scope)
            if scope.browserSession.isIncognito,
               !configuration.privacy.incognitoContentRetentionOptIn {
                scopes.removeValue(forKey: scope)
            }
        }

        return .accepted(
            sequence: envelope.sequence,
            evictedEvents: evictedEvents,
            subscriberDrops: subscriberDrops
        )
    }

    func snapshot(
        in scope: WebKitAgentSignalScope,
        matching filter: WebKitAgentSignalFilter
    ) throws -> WebKitAgentSignalSnapshot {
        try ensureScope(scope)
        guard let state = scopes[scope] else {
            throw WebKitAgentSignalHubError.encodingFailed
        }
        let matching = state.events.lazy
            .map(\.envelope)
            .filter(filter.matches)
        let bounded = Array(matching.suffix(filter.maximumResults))
        return WebKitAgentSignalSnapshot(
            scope: scope,
            events: bounded,
            latestSequence: state.nextSequence &- 1,
            dropAccounting: state.dropAccounting,
            isClosed: state.isClosed
        )
    }

    func subscribe(
        to scope: WebKitAgentSignalScope,
        matching filter: WebKitAgentSignalFilter
    ) throws -> WebKitAgentSignalSubscription {
        try ensureScope(scope)
        guard var state = scopes[scope] else {
            throw WebKitAgentSignalHubError.encodingFailed
        }
        guard state.subscribers.count < configuration.maximumSubscribersPerScope else {
            throw WebKitAgentSignalHubError.subscriberLimit(
                scope: scope,
                maximum: configuration.maximumSubscribersPerScope
            )
        }

        let subscriptionID = UUID()
        let streamPair = AsyncStream<WebKitAgentSignalEnvelope>.makeStream(
            bufferingPolicy: .bufferingNewest(configuration.maximumSubscriptionBufferEvents)
        )
        streamPair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeSubscription(subscriptionID, from: scope) }
        }
        let subscriber = Subscriber(filter: filter, continuation: streamPair.continuation)
        state.subscribers[subscriptionID] = subscriber

        for event in state.events.lazy.map(\.envelope).filter(filter.matches) {
            switch streamPair.continuation.yield(event) {
            case .enqueued:
                break
            case .dropped:
                state.dropAccounting.subscriptionBackpressureEvents &+= 1
            case .terminated:
                state.subscribers.removeValue(forKey: subscriptionID)
            @unknown default:
                state.subscribers.removeValue(forKey: subscriptionID)
            }
        }
        if state.isClosed {
            state.subscribers.removeValue(forKey: subscriptionID)
            streamPair.continuation.finish()
        }
        scopes[scope] = state

        return WebKitAgentSignalSubscription(events: streamPair.stream) { [weak self] in
            await self?.removeSubscription(subscriptionID, from: scope)
        }
    }

    func observe(
        _ query: WebKitAgentObservationQuery,
        in scope: WebKitAgentSignalScope
    ) throws -> WebKitAgentObservationResult {
        switch query {
        case .buffered(let filter):
            return .buffered(try snapshot(in: scope, matching: filter))
        case .detail(let detail):
            try ensureScope(scope)
            return .unsupported(Self.unsupportedResult(for: detail))
        }
    }

    func dropAccounting(
        in scope: WebKitAgentSignalScope
    ) throws -> WebKitAgentSignalDropAccounting {
        try ensureScope(scope)
        return scopes[scope]?.dropAccounting ?? .init()
    }

    func finish(_ scope: WebKitAgentSignalScope) {
        finishSubscriptions(in: scope)
        scopes.removeValue(forKey: scope)
        pageBindings.removeValue(forKey: RunPageKey(runID: scope.runID, page: scope.page))
    }

    func finishRun(_ runID: UUID) {
        let matchingScopes = scopes.keys.filter { $0.runID == runID }
        for scope in matchingScopes {
            finishSubscriptions(in: scope)
            scopes.removeValue(forKey: scope)
        }
        pageBindings = pageBindings.filter { $0.key.runID != runID }
    }

    func clearIncognitoSignals(for runID: UUID? = nil) {
        let matchingScopes = scopes.keys.filter { scope in
            scope.browserSession.isIncognito && (runID == nil || scope.runID == runID)
        }
        for scope in matchingScopes {
            finishSubscriptions(in: scope)
            scopes.removeValue(forKey: scope)
            pageBindings.removeValue(forKey: RunPageKey(runID: scope.runID, page: scope.page))
        }
    }

    private func ensureScope(_ scope: WebKitAgentSignalScope) throws {
        let key = RunPageKey(runID: scope.runID, page: scope.page)
        if let expected = pageBindings[key], expected != scope.browserSession {
            throw WebKitAgentSignalHubError.browserSessionMismatch(
                runID: scope.runID,
                page: scope.page,
                expected: expected,
                actual: scope.browserSession
            )
        }
        if scopes[scope] == nil {
            guard scopes.count < configuration.maximumActiveScopes else {
                throw WebKitAgentSignalHubError.activeScopeLimit(
                    configuration.maximumActiveScopes
                )
            }
            pageBindings[key] = scope.browserSession
            scopes[scope] = ScopeState()
        }
    }

    private func removeSubscription(
        _ subscriptionID: UUID,
        from scope: WebKitAgentSignalScope
    ) {
        guard var state = scopes[scope],
              let subscriber = state.subscribers.removeValue(forKey: subscriptionID) else {
            return
        }
        scopes[scope] = state
        subscriber.continuation.finish()
    }

    private func finishSubscriptions(in scope: WebKitAgentSignalScope) {
        guard var state = scopes[scope] else { return }
        let subscribers = state.subscribers.values
        state.subscribers.removeAll()
        scopes[scope] = state
        for subscriber in subscribers {
            subscriber.continuation.finish()
        }
    }

    private static func unsupportedResult(
        for detail: WebKitAgentUnsupportedDetail
    ) -> WebKitAgentUnsupportedResult {
        let alternative: String?
        switch detail {
        case .networkRequestIdentifier:
            alternative = "Use the local navigation observation ID only to correlate WKNavigation delegate events."
        case .completeSubresourceRequestLog:
            alternative = "Use main/frame navigation responses and the bounded resource failures WebKit explicitly reports."
        case .requestTimingWaterfall:
            alternative = "Use coarse signal timestamps and locally measured tool latency."
        case .cacheInternals:
            alternative = nil
        case .responseBody:
            alternative = "Read explicitly authorized page content through semantic page tools."
        case .rawResponseHeaders:
            alternative = "Use status, MIME type, and TLS state exposed by the navigation delegate."
        case .remoteIPAddress, .serviceWorkerInternals:
            alternative = nil
        }
        return WebKitAgentUnsupportedResult(
            detail: detail,
            reason: "This detail is unsupported because public WebKit hooks do not expose it safely.",
            nativeAlternative: alternative
        )
    }
}

// MARK: - Wait contract

nonisolated enum WebKitAgentSignalWaitCondition: Equatable, Sendable {
    case kind(WebKitAgentSignalKind)
    case console(WebKitAgentConsoleLevel?)
    case navigation(WebKitAgentNavigationPhase)
    case resourceFailure
    case download(downloadID: UUID?, phase: WebKitAgentDownloadPhase)
    case dialog(WebKitAgentDialogKind?)
    case pageLifecycle(WebKitAgentPageLifecyclePhase)

    fileprivate var kinds: Set<WebKitAgentSignalKind> {
        switch self {
        case .kind(let kind): [kind]
        case .console: [.console]
        case .navigation: [.navigation]
        case .resourceFailure: [.resourceFailure]
        case .download: [.download]
        case .dialog: [.dialog]
        case .pageLifecycle: [.pageLifecycle]
        }
    }

    fileprivate func matches(_ event: WebKitAgentSignalEnvelope) -> Bool {
        switch (self, event.signal) {
        case (.kind(let expected), let signal):
            signal.kind == expected
        case (.console(let expected), .console(let signal)):
            expected == nil || expected == signal.level
        case (.navigation(let expected), .navigation(let signal)):
            expected == signal.phase
        case (.resourceFailure, .resourceFailure):
            true
        case (.download(let downloadID, let phase), .download(let signal)):
            signal.phase == phase && (downloadID == nil || downloadID == signal.downloadID)
        case (.dialog(let expected), .dialog(let signal)):
            expected == nil || expected == signal.kind
        case (.pageLifecycle(let expected), .pageLifecycle(let signal)):
            expected == signal.phase
        default:
            false
        }
    }
}

nonisolated enum WebKitAgentSignalWaitRequestError: Error, Equatable, Sendable {
    case invalidMaximumTimeout(Duration)
}

nonisolated struct WebKitAgentSignalWaitRequest: Equatable, Sendable {
    let scope: WebKitAgentSignalScope
    let condition: WebKitAgentSignalWaitCondition
    let afterSequence: UInt64
    let maximumTimeout: Duration

    init(
        scope: WebKitAgentSignalScope,
        condition: WebKitAgentSignalWaitCondition,
        afterSequence: UInt64 = 0,
        maximumTimeout: Duration
    ) throws {
        guard maximumTimeout > .zero else {
            throw WebKitAgentSignalWaitRequestError.invalidMaximumTimeout(maximumTimeout)
        }
        self.scope = scope
        self.condition = condition
        self.afterSequence = afterSequence
        self.maximumTimeout = maximumTimeout
    }
}

nonisolated enum WebKitAgentSignalWaitError: Error, Equatable, Sendable {
    case timedOut(
        scope: WebKitAgentSignalScope,
        condition: WebKitAgentSignalWaitCondition,
        maximumTimeout: Duration
    )
    case cancelled(
        scope: WebKitAgentSignalScope,
        condition: WebKitAgentSignalWaitCondition
    )
    case sourceEnded(
        scope: WebKitAgentSignalScope,
        condition: WebKitAgentSignalWaitCondition
    )
}

nonisolated struct WebKitAgentSignalWaiter: Sendable {
    private let source: any WebKitAgentSignalEventSource

    init<Source: WebKitAgentSignalEventSource>(source: Source) {
        self.source = source
    }

    func wait(
        for request: WebKitAgentSignalWaitRequest
    ) async throws -> WebKitAgentSignalEnvelope {
        try Task.checkCancellation()
        let filter = WebKitAgentSignalFilter(
            kinds: request.condition.kinds,
            afterSequence: request.afterSequence,
            maximumResults: WebKitAgentSignalFilter.maximumResultLimit
        )
        let subscription: WebKitAgentSignalSubscription
        do {
            subscription = try await source.subscribe(to: request.scope, matching: filter)
            try Task.checkCancellation()
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw WebKitAgentSignalWaitError.cancelled(
                    scope: request.scope,
                    condition: request.condition
                )
            }
            throw error
        }

        return try await withTaskCancellationHandler {
            do {
                let result = try await withThrowingTaskGroup(
                    of: WebKitAgentSignalEnvelope.self
                ) { group in
                    group.addTask {
                        for await event in subscription.events {
                            try Task.checkCancellation()
                            if request.condition.matches(event) { return event }
                        }
                        try Task.checkCancellation()
                        throw WebKitAgentSignalWaitError.sourceEnded(
                            scope: request.scope,
                            condition: request.condition
                        )
                    }
                    group.addTask {
                        try await ContinuousClock().sleep(for: request.maximumTimeout)
                        throw WebKitAgentSignalWaitError.timedOut(
                            scope: request.scope,
                            condition: request.condition,
                            maximumTimeout: request.maximumTimeout
                        )
                    }
                    defer { group.cancelAll() }
                    guard let first = try await group.next() else {
                        throw WebKitAgentSignalWaitError.sourceEnded(
                            scope: request.scope,
                            condition: request.condition
                        )
                    }
                    return first
                }
                await subscription.cancel()
                return result
            } catch {
                await subscription.cancel()
                if error is CancellationError || Task.isCancelled {
                    throw WebKitAgentSignalWaitError.cancelled(
                        scope: request.scope,
                        condition: request.condition
                    )
                }
                throw error
            }
        } onCancel: {
            Task { await subscription.cancel() }
        }
    }
}

// MARK: - Opt-in console bridge contract

nonisolated struct WebKitAgentConsoleBridgeConfiguration: Equatable, Sendable {
    static let maximumMessageByteLimit = 16_384
    static let maximumArgumentLimit = 32

    let token: String
    let maximumMessageBytes: Int
    let maximumArguments: Int

    init(
        token: String,
        maximumMessageBytes: Int = 4_096,
        maximumArguments: Int = 16
    ) {
        self.token = String(token.prefix(128))
        self.maximumMessageBytes = min(
            max(maximumMessageBytes, 1),
            Self.maximumMessageByteLimit
        )
        self.maximumArguments = min(max(maximumArguments, 1), Self.maximumArgumentLimit)
    }
}

nonisolated struct WebKitAgentConsoleBridgeScripts: Equatable, Sendable {
    static let messageHandlerName = "straightUpAgentConsole"

    let installation: String
    let cleanup: String

    init(configuration: WebKitAgentConsoleBridgeConfiguration) {
        let token = Self.javaScriptLiteral(configuration.token)
        installation = """
        (() => {
          'use strict';
          const token = \(token);
          const maxMessageLength = \(configuration.maximumMessageBytes);
          const maxArguments = \(configuration.maximumArguments);
          const registryKey = '__straightUpAgentConsoleBridges';
          const registry = window[registryKey] instanceof Map
            ? window[registryKey]
            : new Map();
          if (!(window[registryKey] instanceof Map)) {
            Object.defineProperty(window, registryKey, {
              value: registry,
              configurable: true,
              enumerable: false
            });
          }
          // A tab has one active native bridge token. Restore any wrapper from a
          // prior run before installing this one so completed runs cannot leave
          // an accumulating console-wrapper chain behind.
          for (const bridge of Array.from(registry.values())) {
            if (bridge && typeof bridge.restore === 'function') bridge.restore();
          }

          const handler = window.webkit
            && window.webkit.messageHandlers
            && window.webkit.messageHandlers.\(Self.messageHandlerName);
          if (!handler || typeof handler.postMessage !== 'function') return;

          let disposed = false;
          const originals = new Map();
          const methods = ['debug', 'log', 'info', 'warn', 'error'];
          const levelFor = { debug: 'debug', log: 'log', info: 'info', warn: 'warning', error: 'error' };

          const safeOrigin = (value) => {
            try { return new URL(value || location.href, location.href).origin; }
            catch (_) { return null; }
          };
          const safeValue = (value) => {
            try {
              if (typeof value === 'string') return value;
              if (value === null) return 'null';
              if (value === undefined) return 'undefined';
              if (typeof value === 'number' || typeof value === 'boolean' || typeof value === 'bigint') {
                return String(value);
              }
              return Object.prototype.toString.call(value);
            } catch (_) { return '[unprintable]'; }
          };
          const frame = () => {
            if (window.top === window) return { kind: 'mainFrame' };
            try {
              const ownOrigin = location.origin;
              const topOrigin = window.top.location.origin;
              return ownOrigin === topOrigin
                ? { kind: 'sameOriginSubframe', origin: ownOrigin }
                : { kind: 'crossOriginBoundary', origin: ownOrigin };
            } catch (_) {
              return { kind: 'crossOriginBoundary', origin: safeOrigin(location.href) };
            }
          };
          const post = (level, values, sourceOrigin = null, line = null, column = null) => {
            if (disposed) return;
            const message = values
              .slice(0, maxArguments)
              .map(safeValue)
              .join(' ')
              .slice(0, maxMessageLength);
            try {
              handler.postMessage({
                token,
                level,
                message,
                sourceOrigin: safeOrigin(sourceOrigin || location.href),
                line,
                column,
                frame: frame()
              });
            } catch (_) {}
          };

          for (const method of methods) {
            const original = console[method];
            if (typeof original !== 'function') continue;
            originals.set(method, original);
            const wrapped = function(...values) {
              post(levelFor[method], values);
              return Reflect.apply(original, console, values);
            };
            Object.defineProperty(wrapped, '__straightUpOriginal', { value: original });
            console[method] = wrapped;
          }

          const errorListener = (event) => {
            post('error', [event.message || 'Script error'], event.filename, event.lineno, event.colno);
          };
          window.addEventListener('error', errorListener);

          const restore = () => {
            if (disposed) return;
            disposed = true;
            window.removeEventListener('error', errorListener);
            for (const [method, original] of originals) {
              const current = console[method];
              if (current && current.__straightUpOriginal === original) console[method] = original;
            }
            originals.clear();
            if (registry.get(token)?.restore === restore) registry.delete(token);
          };
          registry.set(token, { restore });
        })();
        """
        cleanup = """
        (() => {
          const token = \(token);
          const registry = window.__straightUpAgentConsoleBridges;
          const bridge = registry instanceof Map ? registry.get(token) : null;
          if (bridge && typeof bridge.restore === 'function') bridge.restore();
        })();
        """
    }

    private static func javaScriptLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }
}

nonisolated enum WebKitAgentConsoleBridgeError: Error, Equatable, Sendable {
    case tokenMismatch
    case invalidSourceOrigin
}

nonisolated struct WebKitAgentConsoleBridgeMessage: Codable, Equatable, Sendable {
    let token: String
    let level: WebKitAgentConsoleLevel
    let message: String
    let sourceOrigin: String?
    let line: UInt?
    let column: UInt?
    let frame: WebKitAgentFrameSource

    init(
        token: String,
        level: WebKitAgentConsoleLevel,
        message: String,
        sourceOrigin: String? = nil,
        line: UInt? = nil,
        column: UInt? = nil,
        frame: WebKitAgentFrameSource = .mainFrame
    ) {
        self.token = token
        self.level = level
        self.message = message
        self.sourceOrigin = sourceOrigin
        self.line = line
        self.column = column
        self.frame = frame
    }

    func signalDraft(expectedToken: String) throws -> WebKitAgentSignalDraft {
        guard token == expectedToken else {
            throw WebKitAgentConsoleBridgeError.tokenMismatch
        }
        let sourceURL: URL?
        if let sourceOrigin {
            guard let parsed = URL(string: sourceOrigin), parsed.scheme != nil else {
                throw WebKitAgentConsoleBridgeError.invalidSourceOrigin
            }
            sourceURL = parsed
        } else {
            sourceURL = nil
        }
        return .console(WebKitAgentConsoleSignalDraft(
            level: level,
            message: message,
            sourceURL: sourceURL,
            line: line,
            column: column,
            frame: frame
        ))
    }
}

// MARK: - Sanitization

nonisolated private enum WebKitAgentSanitizationResult {
    case accepted(WebKitAgentSignal)
    case discarded(WebKitAgentSignalDiscardReason)
}

nonisolated private enum WebKitAgentSignalSanitizer {
    static func sanitize(
        _ draft: WebKitAgentSignalDraft,
        policy: WebKitAgentSignalPrivacyPolicy
    ) -> WebKitAgentSanitizationResult {
        switch draft {
        case .console(let value):
            guard policy.captureConsoleMessages else {
                return .discarded(.consoleCaptureNotEnabled)
            }
            guard !value.frame.isCrossOrigin || policy.captureCrossOriginConsole else {
                return .discarded(.crossOriginConsoleDenied)
            }
            let message = bounded(value.message, maximumBytes: policy.maximumConsoleMessageBytes)
            return .accepted(.console(WebKitAgentConsoleSignal(
                level: value.level,
                message: .captured(message.value, truncated: message.truncated),
                sourceURL: observedURL(
                    value.sourceURL,
                    allowPath: policy.allowSameOriginURLPaths && !value.frame.isCrossOrigin
                ),
                line: value.line.map { min($0, 10_000_000) },
                column: value.column.map { min($0, 10_000_000) },
                frame: value.frame,
                coverage: value.frame.coverage
            )))

        case .navigation(let value):
            let coverage: WebKitAgentSignalCoverage = value.isMainFrame
                ? .mainNavigationDelegate
                : .frameNavigationDelegate
            let allowPath = policy.allowSameOriginURLPaths && !value.isCrossOrigin
            return .accepted(.navigation(WebKitAgentNavigationSignal(
                observationID: value.observationID,
                phase: value.phase,
                url: observedURL(value.url, allowPath: allowPath),
                redirectSourceURL: observedURL(value.redirectSourceURL, allowPath: allowPath),
                statusCode: value.statusCode.flatMap { (100...599).contains($0) ? $0 : nil },
                mimeType: value.mimeType.map { bounded($0, maximumBytes: 256).value },
                canShowMIMEType: value.canShowMIMEType,
                tlsState: value.tlsState,
                coverage: coverage
            )))

        case .resourceFailure(let value):
            return .accepted(.resourceFailure(WebKitAgentResourceFailureSignal(
                observationID: value.observationID,
                surface: value.surface,
                coverage: value.surface.coverage,
                url: observedURL(value.url, allowPath: false),
                errorDomain: bounded(value.errorDomain, maximumBytes: 128).value,
                errorCode: value.errorCode,
                errorDescription: sensitiveErrorDescription(
                    value.errorDescription,
                    policy: policy
                )
            )))

        case .download(let value):
            return .accepted(.download(WebKitAgentDownloadSignal(
                downloadID: value.downloadID,
                phase: value.phase,
                sourceURL: observedURL(value.sourceURL, allowPath: false),
                suggestedFilename: sensitiveText(
                    value.suggestedFilename,
                    enabled: policy.captureSuggestedFilenames,
                    maximumBytes: policy.maximumFilenameBytes
                ),
                progress: value.progress.map { min(max($0, 0), 1) },
                receivedBytes: value.receivedBytes,
                expectedBytes: value.expectedBytes,
                errorDomain: value.errorDomain.map { bounded($0, maximumBytes: 128).value },
                errorCode: value.errorCode,
                errorDescription: value.errorDescription.map {
                    sensitiveErrorDescription($0, policy: policy)
                } ?? .redacted(.privacyPolicy),
                coverage: .downloadDelegate
            )))

        case .dialog(let value):
            return .accepted(.dialog(WebKitAgentDialogSignal(
                dialogID: value.dialogID,
                phase: value.phase,
                kind: value.kind,
                message: sensitiveText(
                    value.message,
                    enabled: policy.captureDialogText,
                    maximumBytes: policy.maximumDialogTextBytes
                ),
                defaultText: sensitiveText(
                    value.defaultText,
                    enabled: policy.captureDialogText,
                    maximumBytes: policy.maximumDialogTextBytes
                ),
                coverage: .uiDelegate
            )))

        case .pageLifecycle(let value):
            return .accepted(.pageLifecycle(WebKitAgentPageLifecycleSignal(
                phase: value.phase,
                url: observedURL(
                    value.url,
                    allowPath: policy.allowSameOriginURLPaths
                )
            )))
        }
    }

    private static func sensitiveText(
        _ value: String?,
        enabled: Bool,
        maximumBytes: Int
    ) -> WebKitAgentSensitiveText {
        guard enabled, let value else { return .redacted(.privacyPolicy) }
        let bounded = bounded(value, maximumBytes: maximumBytes)
        return .captured(bounded.value, truncated: bounded.truncated)
    }

    private static func sensitiveErrorDescription(
        _ value: String,
        policy: WebKitAgentSignalPrivacyPolicy
    ) -> WebKitAgentSensitiveText {
        guard policy.captureErrorDescriptions else {
            return .redacted(.privacyPolicy)
        }
        let redacted = redactSecretsAndPaths(value)
        let bounded = bounded(
            redacted,
            maximumBytes: policy.maximumErrorDescriptionBytes
        )
        return .captured(bounded.value, truncated: bounded.truncated)
    }

    private static func redactSecretsAndPaths(_ value: String) -> String {
        var result = value.replacingOccurrences(
            of: #"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+\-/]+=*"#,
            with: "$1 [REDACTED]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"/(?:Users|home)/[^\s,;]+"#,
            with: "[PATH]",
            options: .regularExpression
        )
        return result
    }

    private static func observedURL(
        _ url: URL?,
        allowPath: Bool
    ) -> WebKitAgentObservedURL? {
        guard let url else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased() else {
            return WebKitAgentObservedURL(
                origin: nil,
                path: nil,
                redactions: [.unparseable]
            )
        }

        var redactions: Set<WebKitAgentURLRedaction> = []
        if components.user != nil || components.password != nil {
            redactions.insert(.credentials)
        }
        if components.query != nil { redactions.insert(.query) }
        if components.fragment != nil { redactions.insert(.fragment) }

        let origin: String?
        if let host = components.host?.lowercased() {
            let defaultPort = (scheme == "https" && components.port == 443)
                || (scheme == "http" && components.port == 80)
            let port = components.port.flatMap { defaultPort ? nil : ":\($0)" } ?? ""
            let displayHost = host.contains(":") ? "[\(host)]" : host
            origin = "\(scheme)://\(displayHost)\(port)"
        } else {
            origin = "\(scheme)://"
        }

        let path: String?
        if allowPath {
            let rawPath = components.percentEncodedPath
            path = rawPath.isEmpty ? nil : bounded(rawPath, maximumBytes: 2_048).value
        } else {
            if !components.percentEncodedPath.isEmpty && components.percentEncodedPath != "/" {
                redactions.insert(.path)
            }
            path = nil
        }
        return WebKitAgentObservedURL(origin: origin, path: path, redactions: redactions)
    }

    private static func bounded(
        _ value: String,
        maximumBytes: Int
    ) -> (value: String, truncated: Bool) {
        guard value.utf8.count > maximumBytes else { return (value, false) }
        var result = ""
        result.reserveCapacity(maximumBytes)
        var used = 0
        for character in value {
            let fragment = String(character)
            let size = fragment.utf8.count
            guard used + size <= maximumBytes else { break }
            result.append(character)
            used += size
        }
        return (result, true)
    }
}
