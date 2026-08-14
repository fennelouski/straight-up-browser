import Foundation

nonisolated enum AgentRunStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case queued
    case running
    case waitingForApproval
    case waitingForHuman
    case succeeded
    case failed
    case cancelled
    case interrupted

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: true
        default: false
        }
    }

    var isRecoverable: Bool { self == .interrupted }

    var isWaiting: Bool {
        self == .waitingForApproval || self == .waitingForHuman
    }
}

nonisolated enum AgentRunStateMachine {
    private static let transitions: [AgentRunStatus: Set<AgentRunStatus>] = [
        .queued: [.running, .cancelled, .interrupted],
        .running: [
            .waitingForApproval, .waitingForHuman, .succeeded, .failed,
            .cancelled, .interrupted,
        ],
        .waitingForApproval: [.running, .cancelled, .interrupted],
        .waitingForHuman: [.running, .cancelled, .interrupted],
        .interrupted: [.queued, .cancelled],
        .succeeded: [],
        .failed: [],
        .cancelled: [],
    ]

    static func validateTransition(from: AgentRunStatus, to: AgentRunStatus) throws {
        guard transitions[from, default: []].contains(to) else {
            throw TransitionError.invalid(from: from, to: to)
        }
    }

    enum TransitionError: Error, Equatable {
        case invalid(from: AgentRunStatus, to: AgentRunStatus)
    }
}

nonisolated enum AgentRunEntryPoint: String, Codable, CaseIterable, Sendable {
    case attended
    case scheduled
    case localMCP
    case commandLine
    case childRun
}

nonisolated enum AgentStepKind: String, Codable, CaseIterable, Sendable {
    case stateTransition
    case userMessage
    case modelText
    case modelToolCall
    case toolInvocation
    case toolResult
    case policyDecision
    case approvalRequest
    case approvalResponse
    case handoff
    case artifact
    case usage
    case limit
    case warning
    case error
    case system
}

nonisolated enum AgentRedactionState: String, Codable, Sendable {
    case metadataOnly
    case redacted
    case retained
    case expired
}

nonisolated struct AgentProviderSnapshot: Codable, Equatable, Sendable {
    var providerID: String
    var model: String
    var endpointIdentity: String
    var reportsUsage: Bool
    var supportsStreaming: Bool

    init(
        providerID: String,
        model: String,
        endpointIdentity: String,
        reportsUsage: Bool = false,
        supportsStreaming: Bool = false
    ) {
        self.providerID = providerID
        self.model = model
        self.endpointIdentity = endpointIdentity
        self.reportsUsage = reportsUsage
        self.supportsStreaming = supportsStreaming
    }
}

nonisolated struct AgentConfigurationSnapshot: Codable, Equatable, Sendable {
    var toolCatalogVersion: Int
    var provider: AgentProviderSnapshot?
    var enabledCapabilities: Set<AgentCapability>
    var settings: [String: JSONValue]

    init(
        toolCatalogVersion: Int = 1,
        provider: AgentProviderSnapshot? = nil,
        enabledCapabilities: Set<AgentCapability> = [],
        settings: [String: JSONValue] = [:]
    ) {
        self.toolCatalogVersion = toolCatalogVersion
        self.provider = provider
        self.enabledCapabilities = enabledCapabilities
        self.settings = settings
    }
}

nonisolated struct AgentConversation: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var runIDs: [UUID]
    var importedFromLegacy: Bool
    /// A metadata-only routing key. Nil is decoded as the legacy continuous
    /// chat so existing conversation indexes remain compatible.
    var scopeKey: String?

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        runIDs: [UUID] = [],
        importedFromLegacy: Bool = false,
        scopeKey: String? = nil
    ) {
        schemaVersion = Self.schemaVersion
        self.id = id
        self.title = title
        self.createdAt = createdAt
        updatedAt = createdAt
        self.runIDs = runIDs
        self.importedFromLegacy = importedFromLegacy
        self.scopeKey = scopeKey
    }
}

nonisolated struct AgentRun: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    let id: UUID
    var conversationID: UUID?
    var taskDefinitionID: UUID?
    var parentRunID: UUID?
    var runGroupID: UUID?
    var entryPoint: AgentRunEntryPoint
    var status: AgentRunStatus
    let createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var lastUpdatedAt: Date
    var configuration: AgentConfigurationSnapshot
    var nextSequence: Int
    var incognito: Bool
    var importedFromLegacy: Bool
    var failureCategory: String?

    init(
        id: UUID = UUID(),
        conversationID: UUID? = nil,
        taskDefinitionID: UUID? = nil,
        parentRunID: UUID? = nil,
        runGroupID: UUID? = nil,
        entryPoint: AgentRunEntryPoint,
        status: AgentRunStatus = .queued,
        createdAt: Date = Date(),
        configuration: AgentConfigurationSnapshot = AgentConfigurationSnapshot(),
        incognito: Bool = false,
        importedFromLegacy: Bool = false
    ) {
        schemaVersion = Self.schemaVersion
        self.id = id
        self.conversationID = conversationID
        self.taskDefinitionID = taskDefinitionID
        self.parentRunID = parentRunID
        self.runGroupID = runGroupID
        self.entryPoint = entryPoint
        self.status = status
        self.createdAt = createdAt
        startedAt = status == .running ? createdAt : nil
        finishedAt = status.isTerminal ? createdAt : nil
        lastUpdatedAt = createdAt
        self.configuration = configuration
        nextSequence = 0
        self.incognito = incognito
        self.importedFromLegacy = importedFromLegacy
        failureCategory = nil
    }
}

nonisolated struct AgentRunQuery: Equatable, Sendable {
    var conversationID: UUID?
    var taskDefinitionID: UUID?
    var status: AgentRunStatus?
    var providerID: String?
    var createdAtInterval: DateInterval?
    var parentRunID: UUID?

    init(
        conversationID: UUID? = nil,
        taskDefinitionID: UUID? = nil,
        status: AgentRunStatus? = nil,
        providerID: String? = nil,
        createdAtInterval: DateInterval? = nil,
        parentRunID: UUID? = nil
    ) {
        self.conversationID = conversationID
        self.taskDefinitionID = taskDefinitionID
        self.status = status
        self.providerID = providerID
        self.createdAtInterval = createdAtInterval
        self.parentRunID = parentRunID
    }
}

nonisolated struct AgentStep: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    let id: UUID
    let runID: UUID
    let sequence: Int
    let timestamp: Date
    let kind: AgentStepKind
    let summary: String
    let payload: JSONValue?
    let artifactID: UUID?
    let policyDecisionStepID: UUID?
    let redactionState: AgentRedactionState

    init(
        id: UUID = UUID(),
        runID: UUID,
        sequence: Int,
        timestamp: Date = Date(),
        kind: AgentStepKind,
        summary: String,
        payload: JSONValue? = nil,
        artifactID: UUID? = nil,
        policyDecisionStepID: UUID? = nil,
        redactionState: AgentRedactionState = .metadataOnly
    ) {
        schemaVersion = Self.schemaVersion
        self.id = id
        self.runID = runID
        self.sequence = sequence
        self.timestamp = timestamp
        self.kind = kind
        self.summary = summary
        self.payload = payload
        self.artifactID = artifactID
        self.policyDecisionStepID = policyDecisionStepID
        self.redactionState = redactionState
    }
}

nonisolated struct AgentArtifact: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    let id: UUID
    let runID: UUID
    let sourceStepID: UUID
    let contentType: String
    let byteCount: Int
    let sha256: String
    let relativePath: String
    let redactionState: AgentRedactionState
    let createdAt: Date

    init(
        id: UUID = UUID(),
        runID: UUID,
        sourceStepID: UUID,
        contentType: String,
        byteCount: Int,
        sha256: String,
        relativePath: String,
        redactionState: AgentRedactionState,
        createdAt: Date = Date()
    ) {
        schemaVersion = Self.schemaVersion
        self.id = id
        self.runID = runID
        self.sourceStepID = sourceStepID
        self.contentType = contentType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.relativePath = relativePath
        self.redactionState = redactionState
        self.createdAt = createdAt
    }
}
