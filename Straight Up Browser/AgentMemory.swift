import CryptoKit
import Foundation

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Durable memory contracts

/// A normalized web origin. Paths, queries, fragments, and default ports are
/// deliberately excluded so an origin scope has one stable representation.
nonisolated struct AgentMemoryOrigin: Codable, Equatable, Hashable, Sendable,
    CustomStringConvertible
{
    let scheme: String
    let host: String
    let port: Int?

    init(pageURL: URL) throws {
        guard let components = URLComponents(
            url: pageURL,
            resolvingAgainstBaseURL: false
        ), let scheme = components.scheme?.lowercased(),
        let host = components.host?.lowercased(), !host.isEmpty,
        components.user == nil, components.password == nil,
        scheme == "https" || scheme == "http"
        else {
            throw AgentMemoryError.invalidOrigin
        }

        let candidatePort = components.port
        let defaultPort = (scheme == "https" && candidatePort == 443)
            || (scheme == "http" && candidatePort == 80)
        self.scheme = scheme
        self.host = host
        port = defaultPort ? nil : candidatePort
    }

    init(_ value: String) throws {
        guard let url = URL(string: value) else {
            throw AgentMemoryError.invalidOrigin
        }
        try self.init(pageURL: url)
    }

    var description: String {
        let renderedHost = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(renderedHost)" + (port.map { ":\($0)" } ?? "")
    }
}

nonisolated enum AgentMemoryScope: Equatable, Hashable, Sendable {
    case global
    case origin(AgentMemoryOrigin)
    case task(UUID)
    case conversation(UUID)

    fileprivate var rank: Int {
        switch self {
        case .conversation: 4
        case .task: 3
        case .origin: 2
        case .global: 1
        }
    }

    fileprivate var reviewLabel: String {
        switch self {
        case .global: "Global"
        case .origin(let origin): "Origin \(origin.description)"
        case .task(let id): "Task \(id.uuidString)"
        case .conversation(let id): "Conversation \(id.uuidString)"
        }
    }
}

extension AgentMemoryScope: Codable {
    private enum CodingKeys: String, CodingKey { case kind, origin, id }
    private enum Kind: String, Codable { case global, origin, task, conversation }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .global:
            self = .global
        case .origin:
            self = .origin(try container.decode(AgentMemoryOrigin.self, forKey: .origin))
        case .task:
            self = .task(try container.decode(UUID.self, forKey: .id))
        case .conversation:
            self = .conversation(try container.decode(UUID.self, forKey: .id))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .global:
            try container.encode(Kind.global, forKey: .kind)
        case .origin(let origin):
            try container.encode(Kind.origin, forKey: .kind)
            try container.encode(origin, forKey: .origin)
        case .task(let id):
            try container.encode(Kind.task, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .conversation(let id):
            try container.encode(Kind.conversation, forKey: .kind)
            try container.encode(id, forKey: .id)
        }
    }
}

/// Persistent memory is never bound to an incognito Session. A broad scope is
/// named explicitly instead of being an implicit wildcard.
nonisolated enum AgentMemoryPersistentSessionScope: Equatable, Hashable, Sendable {
    case normal
    case container(UUID)
    case allPersistentSessions

    fileprivate func matches(_ session: AgentMemoryBrowserSession) -> Bool {
        switch (self, session) {
        case (.normal, .normal): true
        case (.container(let expected), .container(let actual)): expected == actual
        case (.allPersistentSessions, .normal),
             (.allPersistentSessions, .container): true
        default: false
        }
    }
}

extension AgentMemoryPersistentSessionScope: Codable {
    private enum CodingKeys: String, CodingKey { case kind, id }
    private enum Kind: String, Codable { case normal, container, allPersistentSessions }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .normal: self = .normal
        case .container: self = .container(try container.decode(UUID.self, forKey: .id))
        case .allPersistentSessions: self = .allPersistentSessions
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .normal:
            try container.encode(Kind.normal, forKey: .kind)
        case .container(let id):
            try container.encode(Kind.container, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .allPersistentSessions:
            try container.encode(Kind.allPersistentSessions, forKey: .kind)
        }
    }
}

nonisolated enum AgentMemoryBrowserSession: Equatable, Hashable, Sendable {
    case normal
    case container(UUID)
    case incognito(UUID)

    var isIncognito: Bool {
        if case .incognito = self { return true }
        return false
    }
}

extension AgentMemoryBrowserSession: Codable {
    private enum CodingKeys: String, CodingKey { case kind, id }
    private enum Kind: String, Codable { case normal, container, incognito }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .normal: self = .normal
        case .container: self = .container(try container.decode(UUID.self, forKey: .id))
        case .incognito: self = .incognito(try container.decode(UUID.self, forKey: .id))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .normal:
            try container.encode(Kind.normal, forKey: .kind)
        case .container(let id):
            try container.encode(Kind.container, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .incognito(let id):
            try container.encode(Kind.incognito, forKey: .kind)
            try container.encode(id, forKey: .id)
        }
    }
}

nonisolated enum AgentMemorySensitivity: String, Codable, CaseIterable, Sendable {
    case preference
    case personal
    case sensitive
    /// Authentication material is a prohibited memory category, not a more
    /// sensitive storage tier.
    case authentication
}

nonisolated enum AgentMemorySourceKind: String, Codable, Sendable {
    case user
    case modelProposal
    case untrustedObservation
    case migration
}

nonisolated struct AgentMemorySource: Codable, Equatable, Sendable {
    var kind: AgentMemorySourceKind
    var reason: String
    var runID: UUID?
    var stepID: UUID?
    var origin: AgentMemoryOrigin?

    static func user(reason: String) -> Self {
        Self(kind: .user, reason: reason)
    }

    static func modelProposal(runID: UUID, reason: String) -> Self {
        Self(kind: .modelProposal, reason: reason, runID: runID)
    }

    static func observation(
        runID: UUID,
        stepID: UUID,
        origin: AgentMemoryOrigin? = nil,
        reason: String
    ) -> Self {
        Self(
            kind: .untrustedObservation,
            reason: reason,
            runID: runID,
            stepID: stepID,
            origin: origin
        )
    }

    fileprivate static func migration(reason: String) -> Self {
        Self(kind: .migration, reason: reason)
    }

    init(
        kind: AgentMemorySourceKind,
        reason: String,
        runID: UUID? = nil,
        stepID: UUID? = nil,
        origin: AgentMemoryOrigin? = nil
    ) {
        self.kind = kind
        self.reason = reason
        self.runID = runID
        self.stepID = stepID
        self.origin = origin
    }
}

typealias AgentMemoryProvenance = AgentMemorySource

nonisolated struct AgentMemoryEditRecord: Codable, Equatable, Sendable {
    let editedAt: Date
    let previousTextSHA256: String
    let editor: AgentMemorySourceKind
}

nonisolated struct AgentMemoryConsumption: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let runID: UUID
    let stepID: UUID?
    let usedAt: Date
    let matchedScope: AgentMemoryScope
    let reason: String

    init(
        id: UUID = UUID(),
        runID: UUID,
        stepID: UUID? = nil,
        usedAt: Date,
        matchedScope: AgentMemoryScope,
        reason: String
    ) {
        self.id = id
        self.runID = runID
        self.stepID = stepID
        self.usedAt = usedAt
        self.matchedScope = matchedScope
        self.reason = reason
    }
}

nonisolated struct AgentMemoryProposal: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var text: String
    var scope: AgentMemoryScope
    var sessionScope: AgentMemoryPersistentSessionScope
    var sensitivity: AgentMemorySensitivity
    var provenance: AgentMemorySource
    var proposedAt: Date
    var expiresAt: Date?

    init(
        id: UUID = UUID(),
        text: String,
        scope: AgentMemoryScope,
        sessionScope: AgentMemoryPersistentSessionScope = .normal,
        sensitivity: AgentMemorySensitivity,
        provenance: AgentMemorySource,
        proposedAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.scope = scope
        self.sessionScope = sessionScope
        self.sensitivity = sensitivity
        self.provenance = provenance
        self.proposedAt = proposedAt
        self.expiresAt = expiresAt
    }

    func digest() throws -> String {
        try agentMemorySHA256(AgentMemoryCoding.encoder().encode(self))
    }
}

nonisolated struct AgentMemoryWriteContext: Codable, Equatable, Sendable {
    var session: AgentMemoryBrowserSession
    var attended: Bool

    static let attendedPersistent = Self(session: .normal, attended: true)

    init(session: AgentMemoryBrowserSession, attended: Bool = true) {
        self.session = session
        self.attended = attended
    }
}

nonisolated struct AgentMemoryApprovalRequest: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let proposalID: UUID
    let proposalDigest: String
    let scope: AgentMemoryScope
    let sessionScope: AgentMemoryPersistentSessionScope
    let sensitivity: AgentMemorySensitivity
    let reason: String
    let requestedAt: Date
    let expiresAt: Date

    init(
        id: UUID = UUID(),
        proposalID: UUID,
        proposalDigest: String,
        scope: AgentMemoryScope,
        sessionScope: AgentMemoryPersistentSessionScope,
        sensitivity: AgentMemorySensitivity,
        reason: String,
        requestedAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.proposalID = proposalID
        self.proposalDigest = proposalDigest
        self.scope = scope
        self.sessionScope = sessionScope
        self.sensitivity = sensitivity
        self.reason = reason
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
    }
}

nonisolated struct AgentMemoryApprovalGrant: Codable, Equatable, Sendable {
    let requestID: UUID
    let proposalID: UUID
    let proposalDigest: String
    let approvedAt: Date
    let expiresAt: Date

    init(
        request: AgentMemoryApprovalRequest,
        approvedAt: Date = Date(),
        validFor: TimeInterval = 300
    ) {
        requestID = request.id
        proposalID = request.proposalID
        proposalDigest = request.proposalDigest
        self.approvedAt = approvedAt
        expiresAt = min(request.expiresAt, approvedAt.addingTimeInterval(validFor))
    }
}

nonisolated enum AgentMemoryPolicyDecision: Codable, Equatable, Sendable {
    case allow(reason: String)
    case deny(reason: String)
    case requireApproval(AgentMemoryApprovalRequest)
    case approved(AgentMemoryApprovalGrant)
}

nonisolated enum AgentMemoryPolicy {
    static func evaluate(
        proposal: AgentMemoryProposal,
        context: AgentMemoryWriteContext,
        at date: Date = Date(),
        approvalLifetime: TimeInterval = 300
    ) throws -> AgentMemoryPolicyDecision {
        if context.session.isIncognito {
            return .deny(reason: "Incognito runs do not write durable memory")
        }
        if proposal.sensitivity == .authentication
            || AgentMemoryText.containsAuthenticationMaterial(proposal.text)
        {
            return .deny(reason: "Authentication data is prohibited in memory")
        }

        let requiresApproval = proposal.sensitivity == .sensitive
            || proposal.provenance.kind == .untrustedObservation
            || AgentMemoryText.looksLikePersistentInstruction(proposal.text)
            || (!context.attended && proposal.provenance.kind != .user)
        if requiresApproval {
            let reason: String
            if proposal.sensitivity == .sensitive {
                reason = "Sensitive inferred facts require explicit approval"
            } else if !context.attended {
                reason = "Unattended work cannot silently create memory"
            } else {
                reason = "Untrusted or instruction-like content requires explicit approval"
            }
            return .requireApproval(AgentMemoryApprovalRequest(
                proposalID: proposal.id,
                proposalDigest: try proposal.digest(),
                scope: proposal.scope,
                sessionScope: proposal.sessionScope,
                sensitivity: proposal.sensitivity,
                reason: reason,
                requestedAt: date,
                expiresAt: date.addingTimeInterval(max(1, approvalLifetime))
            ))
        }

        return .allow(reason: proposal.provenance.kind == .user
            ? "Explicit user memory write"
            : "Bounded non-sensitive model proposal passed policy")
    }
}

nonisolated struct AgentMemoryEntry: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    let id: UUID
    var text: String
    var scope: AgentMemoryScope
    var sessionScope: AgentMemoryPersistentSessionScope
    var sensitivity: AgentMemorySensitivity
    var provenance: AgentMemorySource
    let createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var expiresAt: Date?
    var isEnabled: Bool
    var wasUserEdited: Bool
    var edits: [AgentMemoryEditRecord]
    var consumptions: [AgentMemoryConsumption]

    fileprivate init(
        proposal: AgentMemoryProposal,
        normalizedText: String,
        expiresAt: Date?,
        isEnabled: Bool = true
    ) {
        schemaVersion = Self.schemaVersion
        id = proposal.id
        text = normalizedText
        scope = proposal.scope
        sessionScope = proposal.sessionScope
        sensitivity = proposal.sensitivity
        provenance = proposal.provenance
        createdAt = proposal.proposedAt
        updatedAt = proposal.proposedAt
        lastUsedAt = nil
        self.expiresAt = expiresAt
        self.isEnabled = isEnabled
        wasUserEdited = false
        edits = []
        consumptions = []
    }

    var whyItExists: String {
        "\(provenance.reason) · \(scope.reviewLabel)"
    }

    var consumerRunIDs: [UUID] {
        Array(Set(consumptions.map(\.runID))).sorted { $0.uuidString < $1.uuidString }
    }
}

nonisolated enum AgentMemoryWriteOutcome: Equatable, Sendable {
    case stored(AgentMemoryEntry)
    case denied(reason: String)
    case requiresApproval(AgentMemoryApprovalRequest)
    case suppressed(reason: String)

    var storedEntry: AgentMemoryEntry {
        get throws {
            guard case .stored(let entry) = self else {
                throw AgentMemoryError.memoryWasNotStored
            }
            return entry
        }
    }
}

nonisolated struct AgentMemoryRetrievalLimits: Codable, Equatable, Sendable {
    var maximumEntries: Int
    var maximumEstimatedTokens: Int
    var maximumUTF8Bytes: Int

    init(
        maximumEntries: Int = 8,
        maximumEstimatedTokens: Int = 2_048,
        maximumUTF8Bytes: Int = 16_384
    ) {
        self.maximumEntries = maximumEntries
        self.maximumEstimatedTokens = maximumEstimatedTokens
        self.maximumUTF8Bytes = maximumUTF8Bytes
    }
}

nonisolated struct AgentMemoryRetrievalRequest: Codable, Equatable, Sendable {
    let runID: UUID
    var stepID: UUID?
    var conversationID: UUID?
    var taskID: UUID?
    var origin: AgentMemoryOrigin?
    var session: AgentMemoryBrowserSession
    var query: String?
    var limits: AgentMemoryRetrievalLimits
    var requestedAt: Date

    init(
        runID: UUID,
        stepID: UUID? = nil,
        conversationID: UUID? = nil,
        taskID: UUID? = nil,
        origin: AgentMemoryOrigin? = nil,
        session: AgentMemoryBrowserSession = .normal,
        query: String? = nil,
        limits: AgentMemoryRetrievalLimits = AgentMemoryRetrievalLimits(),
        requestedAt: Date = Date()
    ) {
        self.runID = runID
        self.stepID = stepID
        self.conversationID = conversationID
        self.taskID = taskID
        self.origin = origin
        self.session = session
        self.query = query
        self.limits = limits
        self.requestedAt = requestedAt
    }
}

nonisolated enum AgentMemoryContextRole: String, Codable, Sendable {
    /// Provider adapters must render this as an observation/content part, never
    /// as a system or developer instruction.
    case untrustedMemoryObservation
}

nonisolated struct AgentMemoryContextPart: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let role: AgentMemoryContextRole
    let text: String
    let sourceLabel: String
    let matchedScope: AgentMemoryScope
    let canGrantAuthority: Bool
    let estimatedTokens: Int
    let utf8Bytes: Int
}

nonisolated struct AgentMemoryRetrievalResult: Codable, Equatable, Sendable {
    let runID: UUID
    let entries: [AgentMemoryContextPart]
    let totalEstimatedTokens: Int
    let totalUTF8Bytes: Int
    let candidateCount: Int
    let omittedByLimitCount: Int
    let omittedByBacklinkQuotaCount: Int
    let suppressionReason: String?
}

nonisolated struct AgentMemoryQuery: Equatable, Sendable {
    var text: String?
    var scope: AgentMemoryScope?
    var sessionScope: AgentMemoryPersistentSessionScope?
    var sensitivity: AgentMemorySensitivity?
    var isEnabled: Bool?
    var sourceRunID: UUID?
    var consumedByRunID: UUID?
    var includeExpired: Bool

    init(
        text: String? = nil,
        scope: AgentMemoryScope? = nil,
        sessionScope: AgentMemoryPersistentSessionScope? = nil,
        sensitivity: AgentMemorySensitivity? = nil,
        isEnabled: Bool? = nil,
        sourceRunID: UUID? = nil,
        consumedByRunID: UUID? = nil,
        includeExpired: Bool = false
    ) {
        self.text = text
        self.scope = scope
        self.sessionScope = sessionScope
        self.sensitivity = sensitivity
        self.isEnabled = isEnabled
        self.sourceRunID = sourceRunID
        self.consumedByRunID = consumedByRunID
        self.includeExpired = includeExpired
    }
}

nonisolated enum AgentMemoryRetentionPolicy: String, Codable, CaseIterable, Sendable {
    case doNotRetain
    case hours24
    case days7
    case days30
    case untilManuallyDeleted

    fileprivate func expiry(from date: Date) -> Date? {
        switch self {
        case .doNotRetain: date
        case .hours24: date.addingTimeInterval(24 * 60 * 60)
        case .days7: date.addingTimeInterval(7 * 24 * 60 * 60)
        case .days30: date.addingTimeInterval(30 * 24 * 60 * 60)
        case .untilManuallyDeleted: nil
        }
    }
}

nonisolated struct AgentMemoryConfiguration: Codable, Equatable, Sendable {
    var maximumEntries: Int
    var maximumEntryUTF8Bytes: Int
    var maximumStoreBytes: Int
    var maximumLoadedFileBytes: Int
    var maximumConsumptionsPerEntry: Int
    var maximumEditRecordsPerEntry: Int
    var retrievalLimits: AgentMemoryRetrievalLimits
    var defaultRetention: AgentMemoryRetentionPolicy

    init(
        maximumEntries: Int = 1_000,
        maximumEntryUTF8Bytes: Int = 16_384,
        maximumStoreBytes: Int = 5 * 1_024 * 1_024,
        maximumLoadedFileBytes: Int = 8 * 1_024 * 1_024,
        maximumConsumptionsPerEntry: Int = 2_048,
        maximumEditRecordsPerEntry: Int = 128,
        retrievalLimits: AgentMemoryRetrievalLimits = AgentMemoryRetrievalLimits(),
        defaultRetention: AgentMemoryRetentionPolicy = .untilManuallyDeleted
    ) {
        self.maximumEntries = maximumEntries
        self.maximumEntryUTF8Bytes = maximumEntryUTF8Bytes
        self.maximumStoreBytes = maximumStoreBytes
        self.maximumLoadedFileBytes = maximumLoadedFileBytes
        self.maximumConsumptionsPerEntry = maximumConsumptionsPerEntry
        self.maximumEditRecordsPerEntry = maximumEditRecordsPerEntry
        self.retrievalLimits = retrievalLimits
        self.defaultRetention = defaultRetention
    }

    fileprivate func validate() throws {
        guard (1...100_000).contains(maximumEntries),
              (64...131_072).contains(maximumEntryUTF8Bytes),
              maximumStoreBytes >= maximumEntryUTF8Bytes,
              maximumStoreBytes <= 128 * 1_024 * 1_024,
              maximumLoadedFileBytes >= maximumStoreBytes,
              maximumLoadedFileBytes <= 256 * 1_024 * 1_024,
              (1...100_000).contains(maximumConsumptionsPerEntry),
              (1...4_096).contains(maximumEditRecordsPerEntry),
              retrievalLimits.maximumEntries > 0,
              retrievalLimits.maximumEstimatedTokens > 0,
              retrievalLimits.maximumUTF8Bytes > 0
        else {
            throw AgentMemoryError.invalidConfiguration
        }
    }
}

nonisolated enum AgentMemoryRecoverySource: String, Codable, Sendable {
    case empty
    case primary
    case backup
    case migratedV0
}

nonisolated struct AgentMemoryRecoveryReport: Codable, Equatable, Sendable {
    let source: AgentMemoryRecoverySource
    let entryCount: Int
    let removedOrphanTemporaryFiles: Int
    let repairedPrimary: Bool
    let migratedEntryCount: Int
}

nonisolated enum AgentMemoryRelatedRecord: Equatable, Sendable {
    case browsingHistory
    case conversation(UUID)
    case run(UUID)
}

nonisolated struct AgentMemoryRelatedDeletionImpact: Equatable, Sendable {
    let relatedRecord: AgentMemoryRelatedRecord
    let defaultKeepsMemory: Bool
    let linkedEntryIDs: [UUID]
    let explanation: String
}

nonisolated enum AgentMemoryUnaffectedStore: String, Codable, Sendable {
    case browsingHistory
    case bookmarks
    case conversations
    case runs
    case providerContextCaches
}

nonisolated struct AgentMemoryDeletionReceipt: Codable, Equatable, Sendable {
    let deletedEntryIDs: [UUID]
    let deletedAt: Date
    let unaffectedStores: [AgentMemoryUnaffectedStore]
    let explanation: String
}

nonisolated enum AgentMemoryExportRedaction: String, Codable, Sendable {
    case redacted
    case includeNonSensitiveContent
    case includeAllContent
}

nonisolated struct AgentMemoryExportOptions: Codable, Equatable, Sendable {
    var redaction: AgentMemoryExportRedaction
    var includeDisabled: Bool
    var includeExpired: Bool
    var includeConsumerRunIDs: Bool

    init(
        redaction: AgentMemoryExportRedaction = .redacted,
        includeDisabled: Bool = true,
        includeExpired: Bool = false,
        includeConsumerRunIDs: Bool = false
    ) {
        self.redaction = redaction
        self.includeDisabled = includeDisabled
        self.includeExpired = includeExpired
        self.includeConsumerRunIDs = includeConsumerRunIDs
    }
}

nonisolated struct AgentMemoryExportItem: Codable, Equatable, Sendable {
    let id: UUID
    let text: String?
    let contentRedacted: Bool
    let scope: AgentMemoryScope
    let sessionScope: AgentMemoryPersistentSessionScope
    let sensitivity: AgentMemorySensitivity
    let sourceKind: AgentMemorySourceKind
    let sourceReason: String?
    let createdAt: Date
    let updatedAt: Date
    let expiresAt: Date?
    let isEnabled: Bool
    let wasUserEdited: Bool
    let consumerRunIDs: [UUID]?
}

nonisolated struct AgentMemoryExportDocument: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Date
    let localOnly: Bool
    let containsSecrets: Bool
    let redaction: AgentMemoryExportRedaction
    let entries: [AgentMemoryExportItem]
    let note: String
}

nonisolated struct AgentMemoryStorageSummary: Codable, Equatable, Sendable {
    let entryCount: Int
    let enabledEntryCount: Int
    let expiredEntryCount: Int
    let approximateBytes: Int
    let defaultRetention: AgentMemoryRetentionPolicy
    let syncEnabled: Bool
}

nonisolated enum AgentMemoryError: Error, Equatable, Sendable {
    case invalidOrigin
    case invalidConfiguration
    case emptyText
    case invalidControlCharacter
    case entryTooLarge(maximumBytes: Int, actualBytes: Int)
    case metadataTooLarge
    case authenticationDataProhibited
    case entryQuotaExceeded(maximumEntries: Int)
    case storeQuotaExceeded(maximumBytes: Int)
    case unknownEntry(UUID)
    case duplicateProposalConflict(UUID)
    case invalidRetrievalLimits
    case approvalRequired
    case invalidApproval
    case expiredApproval
    case memoryWasNotStored
    case unsupportedSchema(Int)
    case corruptStore
    case persistenceFailure
}

// MARK: - User-directed deletion contracts

nonisolated struct AgentMemoryForgetRequest: Equatable, Sendable {
    var entryIDs: Set<UUID>
    var scope: AgentMemoryScope?
    var sourceRunID: UUID?
    var consumedByRunID: UUID?

    init(
        entryIDs: Set<UUID> = [],
        scope: AgentMemoryScope? = nil,
        sourceRunID: UUID? = nil,
        consumedByRunID: UUID? = nil
    ) {
        self.entryIDs = entryIDs
        self.scope = scope
        self.sourceRunID = sourceRunID
        self.consumedByRunID = consumedByRunID
    }

    fileprivate var hasSelector: Bool {
        !entryIDs.isEmpty || scope != nil || sourceRunID != nil || consumedByRunID != nil
    }
}

// MARK: - Actor-backed local store

/// Foundation-only, local, owner-readable storage for explicitly approved
/// Agent memory. The supplied directory should be `agent/memory/` under
/// Application Support; it is intentionally independent from browsing history,
/// bookmarks, conversations, and provider caches.
actor AgentMemoryStore {
    nonisolated static let primaryFilename = "memory-v1.json"
    nonisolated static let backupFilename = "memory-v1.backup.json"

    private let directoryURL: URL
    private let primaryURL: URL
    private let backupURL: URL
    private let configuration: AgentMemoryConfiguration
    private var entriesByID: [UUID: AgentMemoryEntry]
    private var launchRecoveryReport: AgentMemoryRecoveryReport

    init(
        directoryURL: URL,
        configuration: AgentMemoryConfiguration = AgentMemoryConfiguration()
    ) throws {
        try configuration.validate()
        let prepared = try Self.prepareStore(
            directoryURL: directoryURL,
            configuration: configuration
        )
        self.directoryURL = directoryURL
        primaryURL = directoryURL.appendingPathComponent(Self.primaryFilename)
        backupURL = directoryURL.appendingPathComponent(Self.backupFilename)
        self.configuration = configuration
        entriesByID = Dictionary(uniqueKeysWithValues: prepared.entries.map { ($0.id, $0) })
        launchRecoveryReport = prepared.report
    }

    func recoveryReport() -> AgentMemoryRecoveryReport {
        launchRecoveryReport
    }

    func apply(
        proposal: AgentMemoryProposal,
        decision suppliedDecision: AgentMemoryPolicyDecision,
        context: AgentMemoryWriteContext = .attendedPersistent,
        at date: Date = Date()
    ) async throws -> AgentMemoryWriteOutcome {
        try Task.checkCancellation()

        guard !context.session.isIncognito else {
            return .suppressed(reason: "Incognito runs do not write durable memory")
        }
        guard proposal.sessionScope.matches(context.session) else {
            return .denied(reason: "The proposed browser Session scope does not match the run")
        }

        let normalizedText = try AgentMemoryText.normalize(
            proposal.text,
            maximumBytes: configuration.maximumEntryUTF8Bytes
        )
        try AgentMemoryText.validateMetadata(proposal.provenance.reason)
        if proposal.sensitivity == .authentication
            || AgentMemoryText.containsAuthenticationMaterial(normalizedText)
            || AgentMemoryText.containsAuthenticationMaterial(proposal.provenance.reason)
        {
            return .denied(reason: "Authentication data is prohibited in memory")
        }

        var normalizedProposal = proposal
        normalizedProposal.text = normalizedText
        let baselineDecision = try AgentMemoryPolicy.evaluate(
            proposal: normalizedProposal,
            context: context,
            at: date
        )

        switch suppliedDecision {
        case .deny(let reason):
            return .denied(reason: AgentMemoryText.safeReason(reason))
        case .requireApproval(let request):
            let proposalDigest = try normalizedProposal.digest()
            guard request.proposalID == normalizedProposal.id,
                  request.proposalDigest == proposalDigest
            else {
                throw AgentMemoryError.invalidApproval
            }
            return .requiresApproval(request)
        case .allow:
            switch baselineDecision {
            case .allow:
                break
            case .deny(let reason):
                return .denied(reason: reason)
            case .requireApproval(let request):
                return .requiresApproval(request)
            case .approved:
                throw AgentMemoryError.invalidApproval
            }
        case .approved(let grant):
            switch baselineDecision {
            case .deny(let reason):
                return .denied(reason: reason)
            case .allow, .requireApproval:
                try Self.validate(
                    grant: grant,
                    for: normalizedProposal,
                    at: date
                )
            case .approved:
                throw AgentMemoryError.invalidApproval
            }
        }

        let policyExpiry = configuration.defaultRetention.expiry(
            from: normalizedProposal.proposedAt
        )
        let effectiveExpiry = Self.earliest(normalizedProposal.expiresAt, policyExpiry)
        if let effectiveExpiry, effectiveExpiry <= date {
            return .suppressed(reason: "The configured retention policy does not retain this memory")
        }

        let newEntry = AgentMemoryEntry(
            proposal: normalizedProposal,
            normalizedText: normalizedText,
            expiresAt: effectiveExpiry
        )
        if let existing = entriesByID[newEntry.id] {
            guard Self.isSameProposal(existing, as: newEntry) else {
                throw AgentMemoryError.duplicateProposalConflict(newEntry.id)
            }
            return .stored(existing)
        }

        var staged = entriesByID
        Self.removeExpired(from: &staged, at: date)
        guard staged.count < configuration.maximumEntries else {
            throw AgentMemoryError.entryQuotaExceeded(
                maximumEntries: configuration.maximumEntries
            )
        }
        staged[newEntry.id] = newEntry
        try Task.checkCancellation()
        try persist(staged)
        entriesByID = staged
        return .stored(newEntry)
    }

    func retrieve(
        _ request: AgentMemoryRetrievalRequest
    ) async throws -> AgentMemoryRetrievalResult {
        try Task.checkCancellation()
        guard !request.session.isIncognito else {
            return AgentMemoryRetrievalResult(
                runID: request.runID,
                entries: [],
                totalEstimatedTokens: 0,
                totalUTF8Bytes: 0,
                candidateCount: 0,
                omittedByLimitCount: 0,
                omittedByBacklinkQuotaCount: 0,
                suppressionReason: "Incognito runs do not read durable memory"
            )
        }

        let limits = try effectiveLimits(request.limits)
        var staged = entriesByID
        let removedExpired = Self.removeExpired(from: &staged, at: request.requestedAt)
        let queryTerms = AgentMemoryText.searchTerms(request.query)
        let candidates = staged.values.compactMap { entry -> RankedEntry? in
            guard entry.isEnabled,
                  entry.expiresAt.map({ $0 > request.requestedAt }) ?? true,
                  entry.sessionScope.matches(request.session),
                  Self.scope(entry.scope, matches: request),
                  queryTerms.isEmpty || AgentMemoryText.relevance(
                      of: entry.text,
                      for: queryTerms
                  ) > 0
            else { return nil }

            return RankedEntry(
                entry: entry,
                relevance: AgentMemoryText.relevance(of: entry.text, for: queryTerms)
            )
        }.sorted(by: Self.rankedBefore)

        var contextParts: [AgentMemoryContextPart] = []
        var totalTokens = 0
        var totalBytes = 0
        var omittedByLimit = 0
        var omittedByBacklinkQuota = 0

        for ranked in candidates {
            try Task.checkCancellation()
            let entry = ranked.entry
            let bytes = entry.text.lengthOfBytes(using: .utf8)
            let tokens = AgentMemoryText.estimatedTokens(forUTF8Bytes: bytes)
            guard contextParts.count < limits.maximumEntries,
                  totalTokens + tokens <= limits.maximumEstimatedTokens,
                  totalBytes + bytes <= limits.maximumUTF8Bytes
            else {
                omittedByLimit += 1
                continue
            }

            let alreadyLinked = entry.consumptions.contains { $0.runID == request.runID }
            guard alreadyLinked
                    || entry.consumptions.count < configuration.maximumConsumptionsPerEntry
            else {
                omittedByBacklinkQuota += 1
                continue
            }

            let reason = Self.retrievalReason(for: entry.scope)
            contextParts.append(AgentMemoryContextPart(
                id: entry.id,
                role: .untrustedMemoryObservation,
                text: entry.text,
                sourceLabel: "User-approved memory \(entry.id.uuidString) · \(entry.scope.reviewLabel)",
                matchedScope: entry.scope,
                canGrantAuthority: false,
                estimatedTokens: tokens,
                utf8Bytes: bytes
            ))
            totalTokens += tokens
            totalBytes += bytes

            var updated = entry
            updated.lastUsedAt = request.requestedAt
            if !alreadyLinked {
                updated.consumptions.append(AgentMemoryConsumption(
                    runID: request.runID,
                    stepID: request.stepID,
                    usedAt: request.requestedAt,
                    matchedScope: entry.scope,
                    reason: reason
                ))
            }
            staged[entry.id] = updated
        }

        if removedExpired > 0 || !contextParts.isEmpty {
            try Task.checkCancellation()
            try persist(staged)
            entriesByID = staged
        }

        return AgentMemoryRetrievalResult(
            runID: request.runID,
            entries: contextParts,
            totalEstimatedTokens: totalTokens,
            totalUTF8Bytes: totalBytes,
            candidateCount: candidates.count,
            omittedByLimitCount: omittedByLimit,
            omittedByBacklinkQuotaCount: omittedByBacklinkQuota,
            suppressionReason: nil
        )
    }

    func review(
        _ query: AgentMemoryQuery = AgentMemoryQuery(),
        at date: Date = Date()
    ) -> [AgentMemoryEntry] {
        let terms = AgentMemoryText.searchTerms(query.text)
        return entriesByID.values.filter { entry in
            (query.includeExpired || entry.expiresAt.map { $0 > date } ?? true)
                && query.scope.map { $0 == entry.scope } ?? true
                && query.sessionScope.map { $0 == entry.sessionScope } ?? true
                && query.sensitivity.map { $0 == entry.sensitivity } ?? true
                && query.isEnabled.map { $0 == entry.isEnabled } ?? true
                && query.sourceRunID.map { $0 == entry.provenance.runID } ?? true
                && query.consumedByRunID.map { runID in
                    entry.consumptions.contains { $0.runID == runID }
                } ?? true
                && (terms.isEmpty
                    || AgentMemoryText.relevance(
                        of: entry.text + " " + entry.provenance.reason,
                        for: terms
                    ) > 0)
        }.sorted(by: Self.reviewBefore)
    }

    func entry(id: UUID) throws -> AgentMemoryEntry {
        guard let entry = entriesByID[id] else {
            throw AgentMemoryError.unknownEntry(id)
        }
        return entry
    }

    @discardableResult
    func edit(
        id: UUID,
        text: String,
        at date: Date = Date()
    ) async throws -> AgentMemoryEntry {
        try Task.checkCancellation()
        guard var entry = entriesByID[id] else {
            throw AgentMemoryError.unknownEntry(id)
        }
        let normalized = try AgentMemoryText.normalize(
            text,
            maximumBytes: configuration.maximumEntryUTF8Bytes
        )
        guard !AgentMemoryText.containsAuthenticationMaterial(normalized) else {
            throw AgentMemoryError.authenticationDataProhibited
        }
        if normalized != entry.text {
            guard entry.edits.count < configuration.maximumEditRecordsPerEntry else {
                throw AgentMemoryError.storeQuotaExceeded(
                    maximumBytes: configuration.maximumStoreBytes
                )
            }
            entry.edits.append(AgentMemoryEditRecord(
                editedAt: date,
                previousTextSHA256: agentMemorySHA256(Data(entry.text.utf8)),
                editor: .user
            ))
            entry.text = normalized
            entry.updatedAt = date
            entry.wasUserEdited = true
        }
        var staged = entriesByID
        staged[id] = entry
        try Task.checkCancellation()
        try persist(staged)
        entriesByID = staged
        return entry
    }

    @discardableResult
    func setEnabled(
        id: UUID,
        _ enabled: Bool,
        at date: Date = Date()
    ) async throws -> AgentMemoryEntry {
        try Task.checkCancellation()
        guard var entry = entriesByID[id] else {
            throw AgentMemoryError.unknownEntry(id)
        }
        entry.isEnabled = enabled
        entry.updatedAt = date
        var staged = entriesByID
        staged[id] = entry
        try persist(staged)
        entriesByID = staged
        return entry
    }

    @discardableResult
    func updateScope(
        id: UUID,
        scope: AgentMemoryScope,
        sessionScope: AgentMemoryPersistentSessionScope,
        at date: Date = Date()
    ) async throws -> AgentMemoryEntry {
        try Task.checkCancellation()
        guard var entry = entriesByID[id] else {
            throw AgentMemoryError.unknownEntry(id)
        }
        entry.scope = scope
        entry.sessionScope = sessionScope
        entry.updatedAt = date
        entry.wasUserEdited = true
        var staged = entriesByID
        staged[id] = entry
        try persist(staged)
        entriesByID = staged
        return entry
    }

    /// Atomically applies the complete allowlisted projection of an existing
    /// user-authored synced entry. Callers must perform the separate sensitive
    /// review gate before invoking this method. Authentication material remains
    /// prohibited even for an already-existing entry.
    @discardableResult
    func updateSyncedUserProjection(
        id: UUID,
        text: String,
        scope: AgentMemoryScope,
        sessionScope: AgentMemoryPersistentSessionScope,
        sensitivity: AgentMemorySensitivity,
        expiresAt: Date?,
        isEnabled: Bool,
        at date: Date = Date()
    ) async throws -> AgentMemoryEntry {
        try Task.checkCancellation()
        guard var entry = entriesByID[id] else {
            throw AgentMemoryError.unknownEntry(id)
        }
        guard entry.provenance.kind == .user,
              sensitivity != .authentication,
              expiresAt.map({ $0 > entry.createdAt }) ?? true
        else {
            throw AgentMemoryError.authenticationDataProhibited
        }
        let normalized = try AgentMemoryText.normalize(
            text,
            maximumBytes: configuration.maximumEntryUTF8Bytes
        )
        guard !AgentMemoryText.containsAuthenticationMaterial(normalized) else {
            throw AgentMemoryError.authenticationDataProhibited
        }
        if normalized != entry.text {
            guard entry.edits.count < configuration.maximumEditRecordsPerEntry else {
                throw AgentMemoryError.storeQuotaExceeded(
                    maximumBytes: configuration.maximumStoreBytes
                )
            }
            entry.edits.append(AgentMemoryEditRecord(
                editedAt: date,
                previousTextSHA256: agentMemorySHA256(Data(entry.text.utf8)),
                editor: .user
            ))
        }
        entry.text = normalized
        entry.scope = scope
        entry.sessionScope = sessionScope
        entry.sensitivity = sensitivity
        entry.expiresAt = expiresAt
        entry.isEnabled = isEnabled
        entry.updatedAt = date
        var staged = entriesByID
        staged[id] = entry
        try Task.checkCancellation()
        try persist(staged)
        entriesByID = staged
        return entry
    }

    @discardableResult
    func delete(id: UUID, at date: Date = Date()) async throws -> AgentMemoryDeletionReceipt {
        try await forget(AgentMemoryForgetRequest(entryIDs: [id]), at: date)
    }

    @discardableResult
    func forget(
        _ request: AgentMemoryForgetRequest,
        at date: Date = Date()
    ) async throws -> AgentMemoryDeletionReceipt {
        try Task.checkCancellation()
        guard request.hasSelector else {
            throw AgentMemoryError.persistenceFailure
        }
        let ids = entriesByID.values.filter { entry in
            (!request.entryIDs.isEmpty && request.entryIDs.contains(entry.id))
                || request.scope.map { $0 == entry.scope } ?? false
                || request.sourceRunID.map { $0 == entry.provenance.runID } ?? false
                || request.consumedByRunID.map { runID in
                    entry.consumptions.contains { $0.runID == runID }
                } ?? false
        }.map(\.id).sorted { $0.uuidString < $1.uuidString }

        var staged = entriesByID
        ids.forEach { staged.removeValue(forKey: $0) }
        try persist(staged)
        entriesByID = staged
        return Self.deletionReceipt(ids: ids, at: date)
    }

    @discardableResult
    func deleteAll(at date: Date = Date()) async throws -> AgentMemoryDeletionReceipt {
        try Task.checkCancellation()
        let ids = entriesByID.keys.sorted { $0.uuidString < $1.uuidString }
        try persist([:])
        entriesByID = [:]
        return Self.deletionReceipt(ids: ids, at: date)
    }

    @discardableResult
    func purgeExpired(at date: Date = Date()) async throws -> AgentMemoryDeletionReceipt {
        try Task.checkCancellation()
        var staged = entriesByID
        let ids = staged.values.filter { $0.expiresAt.map { $0 <= date } ?? false }
            .map(\.id).sorted { $0.uuidString < $1.uuidString }
        ids.forEach { staged.removeValue(forKey: $0) }
        if !ids.isEmpty {
            try persist(staged)
            entriesByID = staged
        }
        return Self.deletionReceipt(ids: ids, at: date)
    }

    func relatedDeletionImpact(
        for record: AgentMemoryRelatedRecord
    ) -> AgentMemoryRelatedDeletionImpact {
        let linked: [UUID]
        switch record {
        case .browsingHistory:
            linked = []
        case .conversation(let conversationID):
            linked = entriesByID.values.filter {
                $0.scope == .conversation(conversationID)
            }.map(\.id)
        case .run(let runID):
            linked = entriesByID.values.filter { entry in
                entry.provenance.runID == runID
                    || entry.consumptions.contains { $0.runID == runID }
            }.map(\.id)
        }
        return AgentMemoryRelatedDeletionImpact(
            relatedRecord: record,
            defaultKeepsMemory: true,
            linkedEntryIDs: linked.sorted { $0.uuidString < $1.uuidString },
            explanation: "Deleting browsing history, a Conversation, or a Run keeps memory by default. Forget linked memory is a separate explicit action."
        )
    }

    @discardableResult
    func deleteMemoryLinked(
        to record: AgentMemoryRelatedRecord,
        at date: Date = Date()
    ) async throws -> AgentMemoryDeletionReceipt {
        let impact = relatedDeletionImpact(for: record)
        guard !impact.linkedEntryIDs.isEmpty else {
            return Self.deletionReceipt(ids: [], at: date)
        }
        return try await forget(
            AgentMemoryForgetRequest(entryIDs: Set(impact.linkedEntryIDs)),
            at: date
        )
    }

    func previewExport(
        options: AgentMemoryExportOptions = AgentMemoryExportOptions(),
        at date: Date = Date()
    ) -> AgentMemoryExportDocument {
        let entries = entriesByID.values.filter { entry in
            (options.includeDisabled || entry.isEnabled)
                && (options.includeExpired || entry.expiresAt.map { $0 > date } ?? true)
        }.sorted(by: Self.reviewBefore).map { entry in
            let includeText: Bool
            switch options.redaction {
            case .redacted:
                includeText = false
            case .includeNonSensitiveContent:
                includeText = entry.sensitivity != .sensitive
                    && entry.sensitivity != .authentication
            case .includeAllContent:
                includeText = entry.sensitivity != .authentication
            }
            return AgentMemoryExportItem(
                id: entry.id,
                text: includeText ? entry.text : nil,
                contentRedacted: !includeText,
                scope: entry.scope,
                sessionScope: entry.sessionScope,
                sensitivity: entry.sensitivity,
                sourceKind: entry.provenance.kind,
                sourceReason: includeText
                    ? AgentMemoryText.redactAuthenticationMaterial(entry.provenance.reason)
                    : nil,
                createdAt: entry.createdAt,
                updatedAt: entry.updatedAt,
                expiresAt: entry.expiresAt,
                isEnabled: entry.isEnabled,
                wasUserEdited: entry.wasUserEdited,
                consumerRunIDs: options.includeConsumerRunIDs
                    ? entry.consumerRunIDs
                    : nil
            )
        }
        return AgentMemoryExportDocument(
            schemaVersion: AgentMemoryExportDocument.schemaVersion,
            generatedAt: date,
            localOnly: true,
            containsSecrets: false,
            redaction: options.redaction,
            entries: entries,
            note: "Memory export only. Browsing history, bookmarks, Conversations, Runs, provider caches, screenshots, and secrets are not included."
        )
    }

    func exportData(
        options: AgentMemoryExportOptions = AgentMemoryExportOptions(),
        at date: Date = Date()
    ) throws -> Data {
        try AgentMemoryCoding.encoder().encode(previewExport(options: options, at: date))
    }

    func storageSummary(at date: Date = Date()) throws -> AgentMemoryStorageSummary {
        let data = try Self.encodedSnapshot(
            entries: Array(entriesByID.values),
            configuration: configuration,
            generatedAt: date
        )
        return AgentMemoryStorageSummary(
            entryCount: entriesByID.count,
            enabledEntryCount: entriesByID.values.filter(\.isEnabled).count,
            expiredEntryCount: entriesByID.values.filter {
                $0.expiresAt.map { $0 <= date } ?? false
            }.count,
            approximateBytes: data.count,
            defaultRetention: configuration.defaultRetention,
            syncEnabled: false
        )
    }

    // MARK: Persistence and matching

    private func persist(_ staged: [UUID: AgentMemoryEntry]) throws {
        let data = try Self.encodedSnapshot(
            entries: Array(staged.values),
            configuration: configuration,
            generatedAt: Date()
        )
        try Self.writeMirrored(
            data,
            primaryURL: primaryURL,
            backupURL: backupURL,
            directoryURL: directoryURL
        )
    }

    private func effectiveLimits(
        _ requested: AgentMemoryRetrievalLimits
    ) throws -> AgentMemoryRetrievalLimits {
        guard requested.maximumEntries > 0,
              requested.maximumEstimatedTokens > 0,
              requested.maximumUTF8Bytes > 0
        else {
            throw AgentMemoryError.invalidRetrievalLimits
        }
        return AgentMemoryRetrievalLimits(
            maximumEntries: min(
                requested.maximumEntries,
                configuration.retrievalLimits.maximumEntries
            ),
            maximumEstimatedTokens: min(
                requested.maximumEstimatedTokens,
                configuration.retrievalLimits.maximumEstimatedTokens
            ),
            maximumUTF8Bytes: min(
                requested.maximumUTF8Bytes,
                configuration.retrievalLimits.maximumUTF8Bytes
            )
        )
    }
}

// MARK: - Store internals

private nonisolated struct AgentMemorySnapshot: Codable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Date
    let entries: [AgentMemoryEntry]
}

/// Oldest supported pre-release fixture. V0 records are deliberately migrated
/// disabled, so the user must review and enable them before retrieval.
private nonisolated struct AgentMemoryLegacySnapshotV0: Codable, Sendable {
    let schemaVersion: Int
    let items: [AgentMemoryLegacyItemV0]
}

private nonisolated struct AgentMemoryLegacyItemV0: Codable, Sendable {
    let id: UUID
    let text: String
    let origin: String?
    let taskID: UUID?
    let conversationID: UUID?
    let containerID: UUID?
    let createdAt: Date
    let reason: String?
}

private nonisolated struct AgentMemorySnapshotHeader: Codable, Sendable {
    let schemaVersion: Int
}

private nonisolated struct AgentMemoryPreparedStore: Sendable {
    let entries: [AgentMemoryEntry]
    let report: AgentMemoryRecoveryReport
}

private nonisolated struct AgentMemoryLoadedCandidate: Sendable {
    let entries: [AgentMemoryEntry]
    let migrated: Bool
}

private nonisolated struct RankedEntry: Sendable {
    let entry: AgentMemoryEntry
    let relevance: Int
}

private extension AgentMemoryStore {
    nonisolated static func prepareStore(
        directoryURL: URL,
        configuration: AgentMemoryConfiguration
    ) throws -> AgentMemoryPreparedStore {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
        } catch {
            throw AgentMemoryError.persistenceFailure
        }

        let removedTemps = try removeOrphanTemporaryFiles(in: directoryURL)
        let primaryURL = directoryURL.appendingPathComponent(primaryFilename)
        let backupURL = directoryURL.appendingPathComponent(backupFilename)
        let primaryExists = fileManager.fileExists(atPath: primaryURL.path)
        let backupExists = fileManager.fileExists(atPath: backupURL.path)

        if primaryExists {
            do {
                let loaded = try loadCandidate(
                    at: primaryURL,
                    configuration: configuration
                )
                let data = try encodedSnapshot(
                    entries: loaded.entries,
                    configuration: configuration,
                    generatedAt: Date()
                )
                try writeMirrored(
                    data,
                    primaryURL: primaryURL,
                    backupURL: backupURL,
                    directoryURL: directoryURL
                )
                return AgentMemoryPreparedStore(
                    entries: loaded.entries,
                    report: AgentMemoryRecoveryReport(
                        source: loaded.migrated ? .migratedV0 : .primary,
                        entryCount: loaded.entries.count,
                        removedOrphanTemporaryFiles: removedTemps,
                        repairedPrimary: false,
                        migratedEntryCount: loaded.migrated ? loaded.entries.count : 0
                    )
                )
            } catch AgentMemoryError.unsupportedSchema(let version) {
                throw AgentMemoryError.unsupportedSchema(version)
            } catch {
                // The backup is an independently atomic mirror. Never partially
                // decode or salvage attacker-controlled/corrupt primary bytes.
            }
        }

        if backupExists {
            do {
                let loaded = try loadCandidate(
                    at: backupURL,
                    configuration: configuration
                )
                let data = try encodedSnapshot(
                    entries: loaded.entries,
                    configuration: configuration,
                    generatedAt: Date()
                )
                try writeMirrored(
                    data,
                    primaryURL: primaryURL,
                    backupURL: backupURL,
                    directoryURL: directoryURL
                )
                return AgentMemoryPreparedStore(
                    entries: loaded.entries,
                    report: AgentMemoryRecoveryReport(
                        source: loaded.migrated ? .migratedV0 : .backup,
                        entryCount: loaded.entries.count,
                        removedOrphanTemporaryFiles: removedTemps,
                        repairedPrimary: true,
                        migratedEntryCount: loaded.migrated ? loaded.entries.count : 0
                    )
                )
            } catch AgentMemoryError.unsupportedSchema(let version) {
                throw AgentMemoryError.unsupportedSchema(version)
            } catch {
                throw AgentMemoryError.corruptStore
            }
        }

        if primaryExists {
            throw AgentMemoryError.corruptStore
        }

        let data = try encodedSnapshot(
            entries: [],
            configuration: configuration,
            generatedAt: Date()
        )
        try writeMirrored(
            data,
            primaryURL: primaryURL,
            backupURL: backupURL,
            directoryURL: directoryURL
        )
        return AgentMemoryPreparedStore(
            entries: [],
            report: AgentMemoryRecoveryReport(
                source: .empty,
                entryCount: 0,
                removedOrphanTemporaryFiles: removedTemps,
                repairedPrimary: false,
                migratedEntryCount: 0
            )
        )
    }

    nonisolated static func loadCandidate(
        at url: URL,
        configuration: AgentMemoryConfiguration
    ) throws -> AgentMemoryLoadedCandidate {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw AgentMemoryError.corruptStore
        }
        guard let size = attributes[.size] as? NSNumber,
              size.intValue <= configuration.maximumLoadedFileBytes
        else {
            throw AgentMemoryError.storeQuotaExceeded(
                maximumBytes: configuration.maximumLoadedFileBytes
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw AgentMemoryError.corruptStore
        }
        let decoder = AgentMemoryCoding.decoder()
        let header: AgentMemorySnapshotHeader
        do {
            header = try decoder.decode(AgentMemorySnapshotHeader.self, from: data)
        } catch {
            throw AgentMemoryError.corruptStore
        }

        switch header.schemaVersion {
        case AgentMemorySnapshot.schemaVersion:
            let snapshot: AgentMemorySnapshot
            do {
                snapshot = try decoder.decode(AgentMemorySnapshot.self, from: data)
            } catch {
                throw AgentMemoryError.corruptStore
            }
            try validateLoadedEntries(snapshot.entries, configuration: configuration)
            return AgentMemoryLoadedCandidate(entries: snapshot.entries, migrated: false)
        case 0:
            let legacy: AgentMemoryLegacySnapshotV0
            do {
                legacy = try decoder.decode(AgentMemoryLegacySnapshotV0.self, from: data)
            } catch {
                throw AgentMemoryError.corruptStore
            }
            let migrated = try migrate(legacy, configuration: configuration)
            return AgentMemoryLoadedCandidate(entries: migrated, migrated: true)
        default:
            throw AgentMemoryError.unsupportedSchema(header.schemaVersion)
        }
    }

    nonisolated static func migrate(
        _ legacy: AgentMemoryLegacySnapshotV0,
        configuration: AgentMemoryConfiguration
    ) throws -> [AgentMemoryEntry] {
        guard legacy.items.count <= configuration.maximumEntries else {
            throw AgentMemoryError.entryQuotaExceeded(
                maximumEntries: configuration.maximumEntries
            )
        }
        var seen: Set<UUID> = []
        return try legacy.items.map { item in
            guard seen.insert(item.id).inserted else {
                throw AgentMemoryError.corruptStore
            }
            let text = try AgentMemoryText.normalize(
                item.text,
                maximumBytes: configuration.maximumEntryUTF8Bytes
            )
            guard !AgentMemoryText.containsAuthenticationMaterial(text) else {
                throw AgentMemoryError.authenticationDataProhibited
            }
            let reason = try AgentMemoryText.normalizedMetadata(
                item.reason ?? "Imported from the legacy local memory store"
            )
            let scope: AgentMemoryScope
            if let conversationID = item.conversationID {
                scope = .conversation(conversationID)
            } else if let taskID = item.taskID {
                scope = .task(taskID)
            } else if let origin = item.origin {
                scope = .origin(try AgentMemoryOrigin(origin))
            } else {
                scope = .global
            }
            let proposal = AgentMemoryProposal(
                id: item.id,
                text: text,
                scope: scope,
                sessionScope: item.containerID.map {
                    AgentMemoryPersistentSessionScope.container($0)
                } ?? .normal,
                sensitivity: .personal,
                provenance: .migration(reason: reason),
                proposedAt: item.createdAt
            )
            return AgentMemoryEntry(
                proposal: proposal,
                normalizedText: text,
                expiresAt: configuration.defaultRetention.expiry(from: item.createdAt),
                isEnabled: false
            )
        }
    }

    nonisolated static func validateLoadedEntries(
        _ entries: [AgentMemoryEntry],
        configuration: AgentMemoryConfiguration
    ) throws {
        guard entries.count <= configuration.maximumEntries else {
            throw AgentMemoryError.entryQuotaExceeded(
                maximumEntries: configuration.maximumEntries
            )
        }
        var seen: Set<UUID> = []
        for entry in entries {
            guard entry.schemaVersion == AgentMemoryEntry.schemaVersion,
                  seen.insert(entry.id).inserted,
                  entry.sensitivity != .authentication,
                  entry.consumptions.count <= configuration.maximumConsumptionsPerEntry,
                  entry.edits.count <= configuration.maximumEditRecordsPerEntry
            else {
                throw AgentMemoryError.corruptStore
            }
            let normalized = try AgentMemoryText.normalize(
                entry.text,
                maximumBytes: configuration.maximumEntryUTF8Bytes
            )
            guard normalized == entry.text,
                  !AgentMemoryText.containsAuthenticationMaterial(entry.text),
                  !AgentMemoryText.containsAuthenticationMaterial(entry.provenance.reason)
            else {
                throw AgentMemoryError.corruptStore
            }
            try AgentMemoryText.validateMetadata(entry.provenance.reason)
        }
    }

    nonisolated static func encodedSnapshot(
        entries: [AgentMemoryEntry],
        configuration: AgentMemoryConfiguration,
        generatedAt: Date
    ) throws -> Data {
        let sortedEntries = entries.sorted { $0.id.uuidString < $1.id.uuidString }
        try validateLoadedEntries(sortedEntries, configuration: configuration)
        let snapshot = AgentMemorySnapshot(
            schemaVersion: AgentMemorySnapshot.schemaVersion,
            generatedAt: generatedAt,
            entries: sortedEntries
        )
        let data: Data
        do {
            data = try AgentMemoryCoding.encoder().encode(snapshot)
        } catch let error as AgentMemoryError {
            throw error
        } catch {
            throw AgentMemoryError.persistenceFailure
        }
        guard data.count <= configuration.maximumStoreBytes else {
            throw AgentMemoryError.storeQuotaExceeded(
                maximumBytes: configuration.maximumStoreBytes
            )
        }
        return data
    }

    nonisolated static func writeMirrored(
        _ data: Data,
        primaryURL: URL,
        backupURL: URL,
        directoryURL: URL
    ) throws {
        // Backup first: if a process dies before primary replacement, the
        // previous primary is still authoritative and valid. A successful
        // return means both contain the same complete snapshot.
        try atomicWrite(data, to: backupURL)
        try atomicWrite(data, to: primaryURL)
        try synchronizeDirectory(directoryURL)
    }

    nonisolated static func atomicWrite(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".memory.\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: temporary, options: [])
            try protectFile(at: temporary)
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
            #if canImport(Darwin)
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                throw AgentMemoryError.persistenceFailure
            }
            #else
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(
                    destination,
                    withItemAt: temporary
                )
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            #endif
            try protectFile(at: destination)
            let destinationHandle = try FileHandle(forWritingTo: destination)
            try destinationHandle.synchronize()
            try destinationHandle.close()
        } catch let error as AgentMemoryError {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw AgentMemoryError.persistenceFailure
        }
    }

    nonisolated static func protectFile(at url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        do {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        } catch {
            throw AgentMemoryError.persistenceFailure
        }
    }

    nonisolated static func synchronizeDirectory(_ url: URL) throws {
        #if canImport(Darwin)
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw AgentMemoryError.persistenceFailure }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw AgentMemoryError.persistenceFailure
        }
        #endif
    }

    nonisolated static func removeOrphanTemporaryFiles(in directory: URL) throws -> Int {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) + FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            ).filter { $0.lastPathComponent.hasPrefix(".memory.") }
        } catch {
            throw AgentMemoryError.persistenceFailure
        }
        let temporary = Dictionary(grouping: urls, by: \.path).values.compactMap(\.first)
            .filter {
                $0.lastPathComponent.hasPrefix(".memory.")
                    && $0.pathExtension == "tmp"
            }
        for url in temporary {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw AgentMemoryError.persistenceFailure
            }
        }
        return temporary.count
    }

    nonisolated static func validate(
        grant: AgentMemoryApprovalGrant,
        for proposal: AgentMemoryProposal,
        at date: Date
    ) throws {
        let proposalDigest = try proposal.digest()
        guard grant.proposalID == proposal.id,
              grant.proposalDigest == proposalDigest
        else {
            throw AgentMemoryError.invalidApproval
        }
        guard grant.approvedAt <= date, grant.expiresAt > date else {
            throw AgentMemoryError.expiredApproval
        }
    }

    nonisolated static func earliest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)): min(lhs, rhs)
        case (.some(let value), .none), (.none, .some(let value)): value
        case (.none, .none): nil
        }
    }

    nonisolated static func isSameProposal(
        _ lhs: AgentMemoryEntry,
        as rhs: AgentMemoryEntry
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.text == rhs.text
            && lhs.scope == rhs.scope
            && lhs.sessionScope == rhs.sessionScope
            && lhs.sensitivity == rhs.sensitivity
            && lhs.provenance == rhs.provenance
            && lhs.createdAt == rhs.createdAt
            && lhs.expiresAt == rhs.expiresAt
    }

    @discardableResult
    nonisolated static func removeExpired(
        from entries: inout [UUID: AgentMemoryEntry],
        at date: Date
    ) -> Int {
        let ids = entries.values.filter { $0.expiresAt.map { $0 <= date } ?? false }
            .map(\.id)
        ids.forEach { entries.removeValue(forKey: $0) }
        return ids.count
    }

    nonisolated static func scope(
        _ scope: AgentMemoryScope,
        matches request: AgentMemoryRetrievalRequest
    ) -> Bool {
        switch scope {
        case .global: true
        case .origin(let origin): request.origin == origin
        case .task(let taskID): request.taskID == taskID
        case .conversation(let conversationID): request.conversationID == conversationID
        }
    }

    nonisolated static func rankedBefore(_ lhs: RankedEntry, _ rhs: RankedEntry) -> Bool {
        if lhs.relevance != rhs.relevance { return lhs.relevance > rhs.relevance }
        if lhs.entry.scope.rank != rhs.entry.scope.rank {
            return lhs.entry.scope.rank > rhs.entry.scope.rank
        }
        let lhsDate = lhs.entry.lastUsedAt ?? lhs.entry.updatedAt
        let rhsDate = rhs.entry.lastUsedAt ?? rhs.entry.updatedAt
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return lhs.entry.id.uuidString < rhs.entry.id.uuidString
    }

    nonisolated static func reviewBefore(
        _ lhs: AgentMemoryEntry,
        _ rhs: AgentMemoryEntry
    ) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    nonisolated static func retrievalReason(for scope: AgentMemoryScope) -> String {
        switch scope {
        case .global: "Matched the explicitly scoped global memory"
        case .origin: "Matched the exact normalized origin"
        case .task: "Matched the exact AgentTaskDefinition"
        case .conversation: "Matched the exact AgentConversation"
        }
    }

    nonisolated static func deletionReceipt(
        ids: [UUID],
        at date: Date
    ) -> AgentMemoryDeletionReceipt {
        AgentMemoryDeletionReceipt(
            deletedEntryIDs: ids,
            deletedAt: date,
            unaffectedStores: [
                .browsingHistory,
                .bookmarks,
                .conversations,
                .runs,
                .providerContextCaches,
            ],
            explanation: "Only the selected memory records and their memory backlinks were deleted. Other browser and Agent stores are independent."
        )
    }
}

// MARK: - Validation, ranking, redaction, and stable coding

private nonisolated enum AgentMemoryText {
    static func normalize(_ value: String, maximumBytes: Int) throws -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw AgentMemoryError.emptyText }
        guard !normalized.unicodeScalars.contains(where: { scalar in
            scalar.value == 0
                || (scalar.value < 0x20
                    && scalar != "\n"
                    && scalar != "\r"
                    && scalar != "\t")
                || scalar.value == 0x7F
        }) else {
            throw AgentMemoryError.invalidControlCharacter
        }
        let bytes = normalized.lengthOfBytes(using: .utf8)
        guard bytes <= maximumBytes else {
            throw AgentMemoryError.entryTooLarge(
                maximumBytes: maximumBytes,
                actualBytes: bytes
            )
        }
        return normalized
    }

    static func normalizedMetadata(_ value: String) throws -> String {
        let result = try normalize(value, maximumBytes: 1_024)
        guard !containsAuthenticationMaterial(result) else {
            throw AgentMemoryError.authenticationDataProhibited
        }
        return result
    }

    static func validateMetadata(_ value: String) throws {
        _ = try normalizedMetadata(value)
    }

    static func containsAuthenticationMaterial(_ value: String) -> Bool {
        let patterns = [
            #"(?i)authorization\s*:\s*(bearer|basic)\s+[a-z0-9._~+/=-]{8,}"#,
            #"(?i)\b(api[_ -]?key|access[_ -]?token|refresh[_ -]?token|password|cookie)\s*[:=]\s*[^\s]{6,}"#,
            #"-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----"#,
        ]
        return patterns.contains { pattern in
            value.range(of: pattern, options: .regularExpression) != nil
        }
    }

    static func looksLikePersistentInstruction(_ value: String) -> Bool {
        let patterns = [
            #"(?i)\b(ignore|override|disregard)\b.{0,80}\b(previous|system|developer|user)\b.{0,40}\b(instruction|message|prompt)s?\b"#,
            #"(?i)\b(always|never)\b.{0,80}\b(tool|capabilit|permission|approval|secret|credential)"#,
            #"(?i)\b(system|developer)\s*(message|instruction)\s*:"#,
            #"(?i)\b(exfiltrate|bypass approval|grant (me )?permission)\b"#,
        ]
        return patterns.contains { pattern in
            value.range(of: pattern, options: .regularExpression) != nil
        }
    }

    static func safeReason(_ reason: String) -> String {
        let fallback = "Memory write denied by policy"
        guard let normalized = try? normalizedMetadata(reason) else { return fallback }
        return redactAuthenticationMaterial(normalized)
    }

    static func redactAuthenticationMaterial(_ value: String) -> String {
        guard containsAuthenticationMaterial(value) else { return value }
        return "[redacted authentication material]"
    }

    static func searchTerms(_ query: String?) -> [String] {
        guard let query else { return [] }
        return query.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func relevance(of value: String, for terms: [String]) -> Int {
        guard !terms.isEmpty else { return 0 }
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return terms.reduce(into: 0) { score, term in
            if folded == term { score += 8 }
            else if folded.hasPrefix(term) { score += 4 }
            else if folded.contains(term) { score += 1 }
        }
    }

    static func estimatedTokens(forUTF8Bytes bytes: Int) -> Int {
        max(1, (bytes + 3) / 4)
    }
}

private nonisolated enum AgentMemoryCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private nonisolated func agentMemorySHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
