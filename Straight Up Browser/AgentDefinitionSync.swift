import CryptoKit
import Foundation

#if canImport(CloudKit)
import CloudKit
#endif

// AI-014 deliberately syncs a small, typed projection of reusable agent
// definitions. It never accepts an arbitrary configuration dictionary: fields
// which can carry execution evidence or authority are therefore absent from the
// wire model instead of relying on a redaction pass to remember every secret.

// MARK: - Opt-in categories

nonisolated enum AgentDefinitionSyncCategory: String, Codable, CaseIterable,
    Hashable, Sendable
{
    case schedules = "schedule"
    case providerPresets = "provider-preset"
    case userAuthoredMemory = "user-memory"
}

nonisolated struct AgentDefinitionSyncPreferences: Codable, Equatable, Sendable {
    var schedules: Bool
    var providerPresets: Bool
    var userAuthoredMemory: Bool

    static let disabled = Self(
        schedules: false,
        providerPresets: false,
        userAuthoredMemory: false
    )

    init(
        schedules: Bool = false,
        providerPresets: Bool = false,
        userAuthoredMemory: Bool = false
    ) {
        self.schedules = schedules
        self.providerPresets = providerPresets
        self.userAuthoredMemory = userAuthoredMemory
    }

    func isEnabled(_ category: AgentDefinitionSyncCategory) -> Bool {
        switch category {
        case .schedules: schedules
        case .providerPresets: providerPresets
        case .userAuthoredMemory: userAuthoredMemory
        }
    }

    mutating func setEnabled(
        _ enabled: Bool,
        for category: AgentDefinitionSyncCategory
    ) {
        switch category {
        case .schedules: schedules = enabled
        case .providerPresets: providerPresets = enabled
        case .userAuthoredMemory: userAuthoredMemory = enabled
        }
    }
}

nonisolated enum AgentDefinitionSyncSettings {
    enum Key {
        static let schedules = "agentDefinitionSync.schedules.enabled"
        static let providerPresets = "agentDefinitionSync.providerPresets.enabled"
        static let userAuthoredMemory = "agentDefinitionSync.userAuthoredMemory.enabled"
    }

    static func preferences(
        from defaults: UserDefaults = .standard
    ) -> AgentDefinitionSyncPreferences {
        AgentDefinitionSyncPreferences(
            schedules: defaults.bool(forKey: Key.schedules),
            providerPresets: defaults.bool(forKey: Key.providerPresets),
            userAuthoredMemory: defaults.bool(forKey: Key.userAuthoredMemory)
        )
    }

    static func save(
        _ preferences: AgentDefinitionSyncPreferences,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(preferences.schedules, forKey: Key.schedules)
        defaults.set(preferences.providerPresets, forKey: Key.providerPresets)
        defaults.set(
            preferences.userAuthoredMemory,
            forKey: Key.userAuthoredMemory
        )
    }
}

// MARK: - Safe definition payloads

nonisolated struct AgentSyncedProviderPreset: Codable, Equatable, Identifiable,
    Sendable
{
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    let id: UUID
    var revision: Int
    var name: String
    var providerID: String
    var model: String
    var endpointIdentity: String
    var reportsUsage: Bool
    var supportsStreaming: Bool
    /// True means the receiving device must independently have local provider
    /// access (normally a Keychain item). No credential identifier or value is
    /// represented in this record.
    var requiresLocalProviderAccess: Bool
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        revision: Int = 1,
        name: String,
        providerID: String,
        model: String,
        endpointIdentity: String,
        reportsUsage: Bool = false,
        supportsStreaming: Bool = true,
        requiresLocalProviderAccess: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.revision = revision
        self.name = try AgentDefinitionSyncValidation.safeText(
            name,
            field: "providerPreset.name",
            maximumUTF8Bytes: 512
        )
        self.providerID = try AgentDefinitionSyncValidation.safeIdentifier(
            providerID,
            field: "providerPreset.providerID"
        )
        self.model = try AgentDefinitionSyncValidation.safeText(
            model,
            field: "providerPreset.model",
            maximumUTF8Bytes: 1_024
        )
        self.endpointIdentity = try AgentDefinitionSyncValidation.endpoint(
            endpointIdentity
        )
        self.reportsUsage = reportsUsage
        self.supportsStreaming = supportsStreaming
        self.requiresLocalProviderAccess = requiresLocalProviderAccess
        self.createdAt = AgentDefinitionSyncValidation.canonicalDate(createdAt)
        self.updatedAt = AgentDefinitionSyncValidation.canonicalDate(
            updatedAt ?? createdAt
        )
        try validate()
    }

    init(
        id: UUID = UUID(),
        revision: Int = 1,
        name: String,
        snapshot: AgentProviderSnapshot,
        requiresLocalProviderAccess: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) throws {
        try self.init(
            id: id,
            revision: revision,
            name: name,
            providerID: snapshot.providerID,
            model: snapshot.model,
            endpointIdentity: snapshot.endpointIdentity,
            reportsUsage: snapshot.reportsUsage,
            supportsStreaming: snapshot.supportsStreaming,
            requiresLocalProviderAccess: requiresLocalProviderAccess,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    var providerSnapshot: AgentProviderSnapshot {
        AgentProviderSnapshot(
            providerID: providerID,
            model: model,
            endpointIdentity: endpointIdentity,
            reportsUsage: reportsUsage,
            supportsStreaming: supportsStreaming
        )
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw AgentDefinitionSyncError.unsupportedPayloadSchema(
                category: .providerPresets,
                version: schemaVersion
            )
        }
        try AgentDefinitionSyncValidation.positiveRevision(revision)
        let normalizedName = try AgentDefinitionSyncValidation.safeText(
            name,
            field: "providerPreset.name",
            maximumUTF8Bytes: 512
        )
        let normalizedProviderID = try AgentDefinitionSyncValidation.safeIdentifier(
            providerID,
            field: "providerPreset.providerID"
        )
        let normalizedModel = try AgentDefinitionSyncValidation.safeText(
            model,
            field: "providerPreset.model",
            maximumUTF8Bytes: 1_024
        )
        guard normalizedName == name,
              normalizedProviderID == providerID,
              normalizedModel == model,
              try AgentDefinitionSyncValidation.endpoint(endpointIdentity)
                  == endpointIdentity
        else {
            throw AgentDefinitionSyncError.nonCanonicalValue(
                field: "providerPreset.endpointIdentity"
            )
        }
        guard updatedAt >= createdAt,
              AgentDefinitionSyncValidation.isCanonicalDate(createdAt),
              AgentDefinitionSyncValidation.isCanonicalDate(updatedAt)
        else {
            throw AgentDefinitionSyncError.invalidTimestamp
        }
    }
}

nonisolated enum AgentSyncedBrowserSessionRequirement: Codable, Equatable,
    Hashable, Sendable
{
    case normal
    /// This is only a dependency identity. It contains no cookies, tokens, or
    /// website data and does not grant access on a receiving device.
    case persistentContainer(UUID)
}

nonisolated struct AgentSyncedScheduleDefinition: Codable, Equatable, Identifiable,
    Sendable
{
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    let id: UUID
    var revision: Int
    var name: String
    var prompt: String
    var enabled: Bool
    var schedule: AgentTaskSchedule
    var timeZoneIdentifier: String
    var daylightSavingPolicy: AgentTaskDaylightSavingPolicy
    var providerPresetID: UUID
    var allowedOrigins: Set<String>
    var browserSessionRequirement: AgentSyncedBrowserSessionRequirement
    var requiredCapabilities: Set<AgentCapability>
    var requiredMCPConnectionIDs: Set<UUID>
    /// An opaque local dependency identity, never a security-scoped bookmark.
    var requiredCoworkRootID: UUID?
    var budgets: AgentTaskBudgets
    var timeoutSeconds: Int
    var concurrencyPolicy: AgentTaskConcurrencyPolicy
    var retentionPolicy: AgentTaskRetentionPolicy
    var catchUpPolicy: AgentTaskCatchUpPolicy
    var notificationPolicy: AgentTaskNotificationPolicy
    let createdAt: Date
    var updatedAt: Date

    init(
        definition: AgentTaskDefinition,
        providerPresetID: UUID
    ) throws {
        guard definition.validationIssues().isEmpty else {
            throw AgentDefinitionSyncError.invalidScheduleDefinition
        }
        guard definition.execution.browserScope.pageIDs.isEmpty else {
            throw AgentDefinitionSyncError.prohibitedField("pageHandles")
        }
        let sessionRequirement: AgentSyncedBrowserSessionRequirement
        switch definition.execution.browserScope.session {
        case .normal:
            sessionRequirement = .normal
        case .container(let id):
            sessionRequirement = .persistentContainer(id)
        case .incognito:
            throw AgentDefinitionSyncError.prohibitedField("incognito")
        }

        schemaVersion = Self.currentSchemaVersion
        id = definition.id
        revision = definition.revision
        name = try AgentDefinitionSyncValidation.safeText(
            definition.name,
            field: "schedule.name",
            maximumUTF8Bytes: 1_024
        )
        prompt = try AgentDefinitionSyncValidation.safeText(
            definition.prompt,
            field: "schedule.prompt",
            maximumUTF8Bytes: 64 * 1_024
        )
        enabled = definition.enabled
        switch definition.schedule {
        case .interval(let seconds, let anchor):
            schedule = .interval(
                everySeconds: seconds,
                anchor: AgentDefinitionSyncValidation.canonicalDate(anchor)
            )
        case .daily:
            schedule = definition.schedule
        }
        timeZoneIdentifier = definition.timeZoneIdentifier
        daylightSavingPolicy = definition.daylightSavingPolicy
        self.providerPresetID = providerPresetID
        allowedOrigins = Set(try definition.execution.browserScope.origins.map(
            AgentDefinitionSyncValidation.canonicalOrigin
        ))
        browserSessionRequirement = sessionRequirement
        requiredCapabilities = definition.execution.capabilities
        requiredMCPConnectionIDs = definition.execution.mcpConnectionIDs
        requiredCoworkRootID = definition.execution.coworkRootID
        budgets = definition.budgets
        timeoutSeconds = definition.timeoutSeconds
        concurrencyPolicy = definition.concurrencyPolicy
        retentionPolicy = definition.retentionPolicy
        catchUpPolicy = definition.catchUpPolicy
        notificationPolicy = definition.notificationPolicy
        createdAt = AgentDefinitionSyncValidation.canonicalDate(
            definition.createdAt
        )
        updatedAt = AgentDefinitionSyncValidation.canonicalDate(
            definition.updatedAt
        )
        try validate()
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw AgentDefinitionSyncError.unsupportedPayloadSchema(
                category: .schedules,
                version: schemaVersion
            )
        }
        try AgentDefinitionSyncValidation.positiveRevision(revision)
        let normalizedName = try AgentDefinitionSyncValidation.safeText(
            name,
            field: "schedule.name",
            maximumUTF8Bytes: 1_024
        )
        let normalizedPrompt = try AgentDefinitionSyncValidation.safeText(
            prompt,
            field: "schedule.prompt",
            maximumUTF8Bytes: 64 * 1_024
        )
        guard normalizedName == name, normalizedPrompt == prompt else {
            throw AgentDefinitionSyncError.nonCanonicalValue(field: "schedule.text")
        }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw AgentDefinitionSyncError.invalidTimeZone(timeZoneIdentifier)
        }
        guard allowedOrigins.allSatisfy(AgentDefinitionSyncValidation.isCanonicalOrigin)
        else {
            throw AgentDefinitionSyncError.nonCanonicalValue(
                field: "schedule.allowedOrigins"
            )
        }
        let scheduleDateIsCanonical: Bool
        switch schedule {
        case .interval(_, let anchor):
            scheduleDateIsCanonical = AgentDefinitionSyncValidation
                .isCanonicalDate(anchor)
        case .daily:
            scheduleDateIsCanonical = true
        }
        guard updatedAt >= createdAt,
              AgentDefinitionSyncValidation.isCanonicalDate(createdAt),
              AgentDefinitionSyncValidation.isCanonicalDate(updatedAt),
              scheduleDateIsCanonical
        else {
            throw AgentDefinitionSyncError.invalidTimestamp
        }
        let placeholderProvider = AgentProviderSnapshot(
            providerID: "synced-provider",
            model: "synced-model",
            endpointIdentity: "https://sync.invalid"
        )
        let session: AgentBrowserSession
        switch browserSessionRequirement {
        case .normal: session = .normal
        case .persistentContainer(let id): session = .container(id)
        }
        let candidate = try AgentTaskDefinition(
            id: id,
            revision: revision,
            name: name,
            prompt: prompt,
            enabled: enabled,
            schedule: schedule,
            timeZoneIdentifier: timeZoneIdentifier,
            daylightSavingPolicy: daylightSavingPolicy,
            execution: AgentTaskExecutionSnapshot(
                provider: placeholderProvider,
                browserScope: AgentTaskBrowserScope(
                    origins: allowedOrigins,
                    session: session
                ),
                capabilities: requiredCapabilities,
                mcpConnectionIDs: requiredMCPConnectionIDs,
                coworkRootID: requiredCoworkRootID
            ),
            budgets: budgets,
            timeoutSeconds: timeoutSeconds,
            concurrencyPolicy: concurrencyPolicy,
            retentionPolicy: retentionPolicy,
            catchUpPolicy: catchUpPolicy,
            notificationPolicy: notificationPolicy,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        guard candidate.validationIssues().isEmpty else {
            throw AgentDefinitionSyncError.invalidScheduleDefinition
        }
    }

    func occurrenceID(scheduledAt: Date) -> AgentTaskOccurrenceID {
        AgentTaskOccurrenceID(
            taskID: id,
            definitionRevision: revision,
            scheduledAt: scheduledAt
        )
    }

    fileprivate func materialize(
        providerPreset: AgentSyncedProviderPreset
    ) throws -> AgentTaskDefinition {
        guard providerPreset.id == providerPresetID else {
            throw AgentDefinitionSyncError.providerPresetMismatch
        }
        let session: AgentBrowserSession
        switch browserSessionRequirement {
        case .normal: session = .normal
        case .persistentContainer(let id): session = .container(id)
        }
        return try AgentTaskDefinition(
            id: id,
            revision: revision,
            name: name,
            prompt: prompt,
            enabled: enabled,
            schedule: schedule,
            timeZoneIdentifier: timeZoneIdentifier,
            daylightSavingPolicy: daylightSavingPolicy,
            execution: AgentTaskExecutionSnapshot(
                provider: providerPreset.providerSnapshot,
                browserScope: AgentTaskBrowserScope(
                    pageIDs: [],
                    origins: allowedOrigins,
                    session: session
                ),
                capabilities: requiredCapabilities,
                mcpConnectionIDs: requiredMCPConnectionIDs,
                coworkRootID: requiredCoworkRootID
            ),
            budgets: budgets,
            timeoutSeconds: timeoutSeconds,
            concurrencyPolicy: concurrencyPolicy,
            retentionPolicy: retentionPolicy,
            catchUpPolicy: catchUpPolicy,
            notificationPolicy: notificationPolicy,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

nonisolated enum AgentSyncedMemoryScope: Codable, Equatable, Hashable, Sendable {
    case global
    case origin(AgentMemoryOrigin)
    case task(UUID)
}

nonisolated enum AgentSyncedMemorySessionScope: String, Codable, Equatable,
    Sendable
{
    case normal
    case allPersistentSessions
}

nonisolated struct AgentSyncedUserMemory: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    let id: UUID
    var revision: Int
    var text: String
    var scope: AgentSyncedMemoryScope
    var sessionScope: AgentSyncedMemorySessionScope
    var sensitivity: AgentMemorySensitivity
    let createdAt: Date
    var updatedAt: Date
    var expiresAt: Date?
    var isEnabled: Bool

    init(entry: AgentMemoryEntry, revision: Int) throws {
        guard entry.provenance.kind == .user else {
            throw AgentDefinitionSyncError.memoryWasNotUserAuthored
        }
        let safeScope: AgentSyncedMemoryScope
        switch entry.scope {
        case .global: safeScope = .global
        case .origin(let origin): safeScope = .origin(origin)
        case .task(let id): safeScope = .task(id)
        case .conversation:
            throw AgentDefinitionSyncError.prohibitedField("conversationID")
        }
        let safeSessionScope: AgentSyncedMemorySessionScope
        switch entry.sessionScope {
        case .normal: safeSessionScope = .normal
        case .allPersistentSessions: safeSessionScope = .allPersistentSessions
        case .container:
            throw AgentDefinitionSyncError.prohibitedField("BrowserSessionID")
        }
        try self.init(
            id: entry.id,
            revision: revision,
            text: entry.text,
            scope: safeScope,
            sessionScope: safeSessionScope,
            sensitivity: entry.sensitivity,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            expiresAt: entry.expiresAt,
            isEnabled: entry.isEnabled
        )
    }

    init(
        id: UUID = UUID(),
        revision: Int = 1,
        text: String,
        scope: AgentSyncedMemoryScope,
        sessionScope: AgentSyncedMemorySessionScope = .normal,
        sensitivity: AgentMemorySensitivity,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        expiresAt: Date? = nil,
        isEnabled: Bool = true
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.revision = revision
        self.text = try AgentDefinitionSyncValidation.safeText(
            text,
            field: "userMemory.text",
            maximumUTF8Bytes: 8 * 1_024
        )
        self.scope = scope
        self.sessionScope = sessionScope
        self.sensitivity = sensitivity
        self.createdAt = AgentDefinitionSyncValidation.canonicalDate(createdAt)
        self.updatedAt = AgentDefinitionSyncValidation.canonicalDate(
            updatedAt ?? createdAt
        )
        self.expiresAt = expiresAt.map(AgentDefinitionSyncValidation.canonicalDate)
        self.isEnabled = isEnabled
        try validate()
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw AgentDefinitionSyncError.unsupportedPayloadSchema(
                category: .userAuthoredMemory,
                version: schemaVersion
            )
        }
        try AgentDefinitionSyncValidation.positiveRevision(revision)
        let normalizedText = try AgentDefinitionSyncValidation.safeText(
            text,
            field: "userMemory.text",
            maximumUTF8Bytes: 8 * 1_024
        )
        guard normalizedText == text else {
            throw AgentDefinitionSyncError.nonCanonicalValue(
                field: "userMemory.text"
            )
        }
        guard sensitivity != .authentication else {
            throw AgentDefinitionSyncError.prohibitedField("authenticationMemory")
        }
        guard updatedAt >= createdAt,
              expiresAt.map({ $0 > createdAt }) ?? true,
              AgentDefinitionSyncValidation.isCanonicalDate(createdAt),
              AgentDefinitionSyncValidation.isCanonicalDate(updatedAt),
              expiresAt.map(AgentDefinitionSyncValidation.isCanonicalDate) ?? true
        else {
            throw AgentDefinitionSyncError.invalidTimestamp
        }
    }

    var proposal: AgentMemoryProposal {
        let localScope: AgentMemoryScope
        switch scope {
        case .global: localScope = .global
        case .origin(let origin): localScope = .origin(origin)
        case .task(let id): localScope = .task(id)
        }
        let localSessionScope: AgentMemoryPersistentSessionScope =
            sessionScope == .normal ? .normal : .allPersistentSessions
        return AgentMemoryProposal(
            id: id,
            text: text,
            scope: localScope,
            sessionScope: localSessionScope,
            sensitivity: sensitivity,
            provenance: .user(reason: "Synced user-authored memory"),
            proposedAt: createdAt,
            expiresAt: expiresAt
        )
    }
}

nonisolated enum AgentSyncedDefinition: Codable, Equatable, Sendable {
    case schedule(AgentSyncedScheduleDefinition)
    case providerPreset(AgentSyncedProviderPreset)
    case userAuthoredMemory(AgentSyncedUserMemory)

    var category: AgentDefinitionSyncCategory {
        switch self {
        case .schedule: .schedules
        case .providerPreset: .providerPresets
        case .userAuthoredMemory: .userAuthoredMemory
        }
    }

    var definitionID: UUID {
        switch self {
        case .schedule(let value): value.id
        case .providerPreset(let value): value.id
        case .userAuthoredMemory(let value): value.id
        }
    }

    var revision: Int {
        switch self {
        case .schedule(let value): value.revision
        case .providerPreset(let value): value.revision
        case .userAuthoredMemory(let value): value.revision
        }
    }

    var schemaVersion: Int {
        switch self {
        case .schedule(let value): value.schemaVersion
        case .providerPreset(let value): value.schemaVersion
        case .userAuthoredMemory(let value): value.schemaVersion
        }
    }

    func validate() throws {
        switch self {
        case .schedule(let value): try value.validate()
        case .providerPreset(let value): try value.validate()
        case .userAuthoredMemory(let value): try value.validate()
        }
    }
}

// MARK: - Stable envelopes, tombstones, and conflict resolution

nonisolated struct AgentDefinitionSyncEnvelope: Codable, Equatable, Identifiable,
    Sendable
{
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var category: AgentDefinitionSyncCategory
    var definitionID: UUID
    var revision: Int
    var modifiedAt: Date
    var modifiedByDeviceID: String
    var isTombstone: Bool
    var payload: AgentSyncedDefinition?

    var id: String { recordName }

    var recordName: String {
        AgentDefinitionCloudRecordCodec.recordName(
            category: category,
            definitionID: definitionID
        )
    }

    fileprivate init(
        schemaVersion: Int,
        category: AgentDefinitionSyncCategory,
        definitionID: UUID,
        revision: Int,
        modifiedAt: Date,
        modifiedByDeviceID: String,
        isTombstone: Bool,
        payload: AgentSyncedDefinition?
    ) {
        self.schemaVersion = schemaVersion
        self.category = category
        self.definitionID = definitionID
        self.revision = revision
        self.modifiedAt = modifiedAt
        self.modifiedByDeviceID = modifiedByDeviceID
        self.isTombstone = isTombstone
        self.payload = payload
    }

    init(
        payload: AgentSyncedDefinition,
        modifiedAt: Date? = nil,
        modifiedByDeviceID: String
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        category = payload.category
        definitionID = payload.definitionID
        revision = payload.revision
        self.modifiedAt = AgentDefinitionSyncValidation.canonicalDate(
            modifiedAt ?? AgentDefinitionSyncEnvelope.updatedAt(payload)
        )
        self.modifiedByDeviceID = try AgentDefinitionSyncValidation.safeIdentifier(
            modifiedByDeviceID,
            field: "modifiedByDeviceID",
            maximumUTF8Bytes: 128
        )
        isTombstone = false
        self.payload = payload
        try validate()
    }

    static func tombstone(
        category: AgentDefinitionSyncCategory,
        definitionID: UUID,
        revision: Int,
        modifiedAt: Date = Date(),
        modifiedByDeviceID: String
    ) throws -> Self {
        let value = Self(
            schemaVersion: Self.currentSchemaVersion,
            category: category,
            definitionID: definitionID,
            revision: revision,
            modifiedAt: AgentDefinitionSyncValidation.canonicalDate(modifiedAt),
            modifiedByDeviceID: try AgentDefinitionSyncValidation.safeIdentifier(
                modifiedByDeviceID,
                field: "modifiedByDeviceID",
                maximumUTF8Bytes: 128
            ),
            isTombstone: true,
            payload: nil
        )
        try value.validate()
        return value
    }

    func replacingWithTombstone(
        at date: Date = Date(),
        modifiedByDeviceID: String
    ) throws -> Self {
        try Self.tombstone(
            category: category,
            definitionID: definitionID,
            revision: revision + 1,
            modifiedAt: date,
            modifiedByDeviceID: modifiedByDeviceID
        )
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw AgentDefinitionSyncError.unsupportedEnvelopeSchema(schemaVersion)
        }
        try AgentDefinitionSyncValidation.positiveRevision(revision)
        let normalizedDeviceID = try AgentDefinitionSyncValidation.safeIdentifier(
            modifiedByDeviceID,
            field: "modifiedByDeviceID",
            maximumUTF8Bytes: 128
        )
        guard normalizedDeviceID == modifiedByDeviceID else {
            throw AgentDefinitionSyncError.nonCanonicalValue(
                field: "modifiedByDeviceID"
            )
        }
        guard AgentDefinitionSyncValidation.isCanonicalDate(modifiedAt) else {
            throw AgentDefinitionSyncError.invalidTimestamp
        }
        if isTombstone {
            guard payload == nil else {
                throw AgentDefinitionSyncError.tombstoneContainsPayload
            }
        } else {
            guard let payload else {
                throw AgentDefinitionSyncError.missingPayload
            }
            guard payload.category == category,
                  payload.definitionID == definitionID,
                  payload.revision == revision
            else {
                throw AgentDefinitionSyncError.envelopePayloadMismatch
            }
            try payload.validate()
        }
    }

    private static func updatedAt(_ payload: AgentSyncedDefinition) -> Date {
        switch payload {
        case .schedule(let value): value.updatedAt
        case .providerPreset(let value): value.updatedAt
        case .userAuthoredMemory(let value): value.updatedAt
        }
    }
}

nonisolated enum AgentDefinitionConflictReason: String, Codable, Sendable {
    case identical
    case higherRevision
    case tombstoneAtEqualRevision
    case laterModification
    case deviceTieBreak
    case contentDigestTieBreak
}

nonisolated struct AgentDefinitionConflictResolution: Equatable, Sendable {
    let winner: AgentDefinitionSyncEnvelope
    let loser: AgentDefinitionSyncEnvelope?
    let reason: AgentDefinitionConflictReason
}

nonisolated enum AgentDefinitionConflictResolver {
    static func resolve(
        _ lhs: AgentDefinitionSyncEnvelope,
        _ rhs: AgentDefinitionSyncEnvelope
    ) throws -> AgentDefinitionConflictResolution {
        try lhs.validate()
        try rhs.validate()
        guard lhs.recordName == rhs.recordName else {
            throw AgentDefinitionSyncError.conflictingRecordIdentities
        }
        if lhs == rhs {
            return AgentDefinitionConflictResolution(
                winner: lhs,
                loser: nil,
                reason: .identical
            )
        }
        if lhs.revision != rhs.revision {
            return selected(
                lhs.revision > rhs.revision ? lhs : rhs,
                lhs.revision > rhs.revision ? rhs : lhs,
                .higherRevision
            )
        }
        if lhs.isTombstone != rhs.isTombstone {
            return selected(
                lhs.isTombstone ? lhs : rhs,
                lhs.isTombstone ? rhs : lhs,
                .tombstoneAtEqualRevision
            )
        }
        if lhs.modifiedAt != rhs.modifiedAt {
            return selected(
                lhs.modifiedAt > rhs.modifiedAt ? lhs : rhs,
                lhs.modifiedAt > rhs.modifiedAt ? rhs : lhs,
                .laterModification
            )
        }
        if lhs.modifiedByDeviceID != rhs.modifiedByDeviceID {
            return selected(
                lhs.modifiedByDeviceID > rhs.modifiedByDeviceID ? lhs : rhs,
                lhs.modifiedByDeviceID > rhs.modifiedByDeviceID ? rhs : lhs,
                .deviceTieBreak
            )
        }
        let lhsDigest = try AgentDefinitionCloudRecordCodec.digest(lhs)
        let rhsDigest = try AgentDefinitionCloudRecordCodec.digest(rhs)
        return selected(
            lhsDigest >= rhsDigest ? lhs : rhs,
            lhsDigest >= rhsDigest ? rhs : lhs,
            .contentDigestTieBreak
        )
    }

    static func merge(
        local: [String: AgentDefinitionSyncEnvelope],
        remote: [AgentDefinitionSyncEnvelope]
    ) throws -> [String: AgentDefinitionSyncEnvelope] {
        var merged = local
        for incoming in remote.sorted(by: { $0.recordName < $1.recordName }) {
            if let existing = merged[incoming.recordName] {
                merged[incoming.recordName] = try resolve(existing, incoming).winner
            } else {
                try incoming.validate()
                merged[incoming.recordName] = incoming
            }
        }
        return merged
    }

    private static func selected(
        _ winner: AgentDefinitionSyncEnvelope,
        _ loser: AgentDefinitionSyncEnvelope,
        _ reason: AgentDefinitionConflictReason
    ) -> AgentDefinitionConflictResolution {
        AgentDefinitionConflictResolution(
            winner: winner,
            loser: loser,
            reason: reason
        )
    }
}

// MARK: - Receiving-device capability and policy gate

nonisolated enum AgentDefinitionDevicePlatform: String, Codable, Equatable,
    Hashable, Sendable
{
    case macOS
    case iPadOS
}

nonisolated struct AgentDefinitionDeviceCapabilities: Codable, Equatable, Sendable {
    var deviceID: String
    var platform: AgentDefinitionDevicePlatform
    var supportedSchemaVersions: [AgentDefinitionSyncCategory: Set<Int>]
    var installedProviderPresetIDs: Set<UUID>
    var providerPresetIDsWithLocalAccess: Set<UUID>
    var trustedMCPConnectionIDs: Set<UUID>
    var authorizedCoworkRootIDs: Set<UUID>
    var availableBrowserSessionIDs: Set<UUID>
    var supportedCapabilities: Set<AgentCapability>
    var policyGrantedScheduledCapabilities: Set<AgentCapability>
    var scheduledExecutionPolicySatisfied: Bool

    init(
        deviceID: String,
        platform: AgentDefinitionDevicePlatform,
        supportedSchemaVersions: [AgentDefinitionSyncCategory: Set<Int>] = [
            .schedules: [AgentSyncedScheduleDefinition.currentSchemaVersion],
            .providerPresets: [AgentSyncedProviderPreset.currentSchemaVersion],
            .userAuthoredMemory: [AgentSyncedUserMemory.currentSchemaVersion],
        ],
        installedProviderPresetIDs: Set<UUID> = [],
        providerPresetIDsWithLocalAccess: Set<UUID> = [],
        trustedMCPConnectionIDs: Set<UUID> = [],
        authorizedCoworkRootIDs: Set<UUID> = [],
        availableBrowserSessionIDs: Set<UUID> = [],
        supportedCapabilities: Set<AgentCapability> = [],
        policyGrantedScheduledCapabilities: Set<AgentCapability> = [],
        scheduledExecutionPolicySatisfied: Bool = false
    ) {
        self.deviceID = deviceID
        self.platform = platform
        self.supportedSchemaVersions = supportedSchemaVersions
        self.installedProviderPresetIDs = installedProviderPresetIDs
        self.providerPresetIDsWithLocalAccess = providerPresetIDsWithLocalAccess
        self.trustedMCPConnectionIDs = trustedMCPConnectionIDs
        self.authorizedCoworkRootIDs = authorizedCoworkRootIDs
        self.availableBrowserSessionIDs = availableBrowserSessionIDs
        self.supportedCapabilities = supportedCapabilities
        self.policyGrantedScheduledCapabilities = policyGrantedScheduledCapabilities
        self.scheduledExecutionPolicySatisfied = scheduledExecutionPolicySatisfied
    }
}

nonisolated enum AgentDefinitionUnavailabilityReason: Codable, Equatable, Hashable,
    Sendable
{
    case categorySyncDisabled(AgentDefinitionSyncCategory)
    case tombstone
    case definitionDisabled
    case unsupportedSchema(category: AgentDefinitionSyncCategory, version: Int)
    case unsupportedPlatform(AgentDefinitionDevicePlatform)
    case missingProviderPreset(UUID)
    case missingLocalProviderAccess(UUID)
    case missingMCPConnection(UUID)
    case missingCoworkScope(UUID)
    case missingBrowserSession(UUID)
    case unsupportedCapability(AgentCapability)
    case capabilityNotGranted(AgentCapability)
    case scheduledPolicyNotSatisfied

    fileprivate var sortKey: String {
        switch self {
        case .categorySyncDisabled(let value): "01-\(value.rawValue)"
        case .tombstone: "02"
        case .definitionDisabled: "03"
        case .unsupportedSchema(let category, let version):
            "04-\(category.rawValue)-\(version)"
        case .unsupportedPlatform(let value): "05-\(value.rawValue)"
        case .missingProviderPreset(let id): "06-\(id.uuidString)"
        case .missingLocalProviderAccess(let id): "07-\(id.uuidString)"
        case .missingMCPConnection(let id): "08-\(id.uuidString)"
        case .missingCoworkScope(let id): "09-\(id.uuidString)"
        case .missingBrowserSession(let id): "10-\(id.uuidString)"
        case .unsupportedCapability(let value): "11-\(value.rawValue)"
        case .capabilityNotGranted(let value): "12-\(value.rawValue)"
        case .scheduledPolicyNotSatisfied: "13"
        }
    }
}

nonisolated struct AgentDefinitionAvailability: Codable, Equatable, Sendable {
    /// Unsupported definitions stay visible and round-trippable. Retention is
    /// independent of permission to execute them.
    let retainOnDevice: Bool
    let mayRun: Bool
    let reasons: [AgentDefinitionUnavailabilityReason]
}

nonisolated struct AgentSyncedScheduleExecutionPermit: Equatable, Sendable {
    fileprivate let recordName: String
    fileprivate let definitionRevision: Int
    fileprivate let providerPresetID: UUID
    fileprivate let providerPresetRevision: Int
    fileprivate let providerPresetDigest: String
    fileprivate let envelopeDigest: String
    let evaluatedDeviceID: String
}

nonisolated enum AgentDefinitionActivationDecision: Equatable, Sendable {
    case runnable(AgentSyncedScheduleExecutionPermit)
    case unavailable(AgentDefinitionAvailability)
}

nonisolated enum AgentDefinitionActivationGate {
    static func evaluate(
        _ envelope: AgentDefinitionSyncEnvelope,
        providerPresets: [UUID: AgentSyncedProviderPreset],
        preferences: AgentDefinitionSyncPreferences,
        device: AgentDefinitionDeviceCapabilities
    ) throws -> AgentDefinitionActivationDecision {
        try envelope.validate()
        let normalizedDeviceID = try AgentDefinitionSyncValidation.safeIdentifier(
            device.deviceID,
            field: "device.deviceID",
            maximumUTF8Bytes: 128
        )
        guard normalizedDeviceID == device.deviceID else {
            throw AgentDefinitionSyncError.nonCanonicalValue(
                field: "device.deviceID"
            )
        }
        var reasons: Set<AgentDefinitionUnavailabilityReason> = []
        if !preferences.isEnabled(.schedules) {
            reasons.insert(.categorySyncDisabled(.schedules))
        }
        if envelope.isTombstone {
            reasons.insert(.tombstone)
        }
        guard case .schedule(let schedule)? = envelope.payload,
              envelope.category == .schedules
        else {
            let availability = AgentDefinitionAvailability(
                retainOnDevice: true,
                mayRun: false,
                reasons: Array(reasons.union([.tombstone])).sorted {
                    $0.sortKey < $1.sortKey
                }
            )
            return .unavailable(availability)
        }

        if device.supportedSchemaVersions[.schedules]?.contains(
            schedule.schemaVersion
        ) != true {
            reasons.insert(.unsupportedSchema(
                category: .schedules,
                version: schedule.schemaVersion
            ))
        }
        if device.platform != .macOS {
            reasons.insert(.unsupportedPlatform(device.platform))
        }
        if !schedule.enabled { reasons.insert(.definitionDisabled) }

        let provider = providerPresets[schedule.providerPresetID]
        if provider == nil
            || !device.installedProviderPresetIDs.contains(schedule.providerPresetID)
        {
            reasons.insert(.missingProviderPreset(schedule.providerPresetID))
        }
        if let provider {
            try provider.validate()
            if device.supportedSchemaVersions[.providerPresets]?.contains(
                provider.schemaVersion
            ) != true {
                reasons.insert(.unsupportedSchema(
                    category: .providerPresets,
                    version: provider.schemaVersion
                ))
            }
            if provider.requiresLocalProviderAccess
                && !device.providerPresetIDsWithLocalAccess.contains(provider.id)
            {
                reasons.insert(.missingLocalProviderAccess(provider.id))
            }
        } else if !device.providerPresetIDsWithLocalAccess.contains(
            schedule.providerPresetID
        ) {
            reasons.insert(.missingLocalProviderAccess(schedule.providerPresetID))
        }

        for id in schedule.requiredMCPConnectionIDs
            where !device.trustedMCPConnectionIDs.contains(id)
        {
            reasons.insert(.missingMCPConnection(id))
        }
        if let id = schedule.requiredCoworkRootID,
           !device.authorizedCoworkRootIDs.contains(id) {
            reasons.insert(.missingCoworkScope(id))
        }
        if case .persistentContainer(let id) = schedule.browserSessionRequirement,
           !device.availableBrowserSessionIDs.contains(id) {
            reasons.insert(.missingBrowserSession(id))
        }
        for capability in schedule.requiredCapabilities
            where !device.supportedCapabilities.contains(capability)
        {
            reasons.insert(.unsupportedCapability(capability))
        }
        for capability in schedule.requiredCapabilities
            where !device.policyGrantedScheduledCapabilities.contains(capability)
        {
            reasons.insert(.capabilityNotGranted(capability))
        }
        if !device.scheduledExecutionPolicySatisfied {
            reasons.insert(.scheduledPolicyNotSatisfied)
        }

        let sortedReasons = reasons.sorted { $0.sortKey < $1.sortKey }
        guard sortedReasons.isEmpty, let provider else {
            return .unavailable(AgentDefinitionAvailability(
                retainOnDevice: true,
                mayRun: false,
                reasons: sortedReasons
            ))
        }
        return .runnable(AgentSyncedScheduleExecutionPermit(
            recordName: envelope.recordName,
            definitionRevision: schedule.revision,
            providerPresetID: provider.id,
            providerPresetRevision: provider.revision,
            providerPresetDigest: try AgentDefinitionCloudRecordCodec.digest(
                provider
            ),
            envelopeDigest: try AgentDefinitionCloudRecordCodec.digest(envelope),
            evaluatedDeviceID: device.deviceID
        ))
    }

    static func materialize(
        _ envelope: AgentDefinitionSyncEnvelope,
        providerPreset: AgentSyncedProviderPreset,
        permit: AgentSyncedScheduleExecutionPermit
    ) throws -> AgentTaskDefinition {
        guard case .schedule(let schedule)? = envelope.payload,
              envelope.recordName == permit.recordName,
              schedule.revision == permit.definitionRevision,
              schedule.providerPresetID == permit.providerPresetID,
              providerPreset.id == permit.providerPresetID,
              providerPreset.revision == permit.providerPresetRevision,
              try AgentDefinitionCloudRecordCodec.digest(providerPreset)
                  == permit.providerPresetDigest,
              try AgentDefinitionCloudRecordCodec.digest(envelope)
                  == permit.envelopeDigest
        else {
            throw AgentDefinitionSyncError.activationPermitMismatch
        }
        return try schedule.materialize(providerPreset: providerPreset)
    }
}

// MARK: - Allowlisted CloudKit representation

nonisolated enum AgentDefinitionCloudFieldValue: Codable, Equatable, Sendable {
    case integer(Int64)
    case string(String)
    case date(Date)
    case data(Data)
}

nonisolated struct AgentDefinitionCloudRecord: Codable, Equatable, Sendable {
    let recordType: String
    let recordName: String
    let fields: [String: AgentDefinitionCloudFieldValue]
}

nonisolated enum AgentDefinitionCloudRecordCodec {
    static let recordType = "AgentDefinition"
    static let maximumPayloadBytes = 256 * 1_024
    static let allowedFieldNames: Set<String> = [
        "schemaVersion",
        "category",
        "definitionID",
        "revision",
        "modifiedAt",
        "modifiedByDeviceID",
        "tombstone",
        "payload",
        "payloadSHA256",
    ]

    static func recordName(
        category: AgentDefinitionSyncCategory,
        definitionID: UUID
    ) -> String {
        "agent-definition.\(category.rawValue).\(definitionID.uuidString.lowercased())"
    }

    static func encode(
        _ envelope: AgentDefinitionSyncEnvelope
    ) throws -> AgentDefinitionCloudRecord {
        try envelope.validate()
        var fields: [String: AgentDefinitionCloudFieldValue] = [
            "schemaVersion": .integer(Int64(envelope.schemaVersion)),
            "category": .string(envelope.category.rawValue),
            "definitionID": .string(envelope.definitionID.uuidString.lowercased()),
            "revision": .integer(Int64(envelope.revision)),
            "modifiedAt": .date(envelope.modifiedAt),
            "modifiedByDeviceID": .string(envelope.modifiedByDeviceID),
            "tombstone": .integer(envelope.isTombstone ? 1 : 0),
        ]
        if let payload = envelope.payload {
            let data = try encodePayload(payload)
            guard data.count <= maximumPayloadBytes else {
                throw AgentDefinitionSyncError.payloadTooLarge(
                    maximumBytes: maximumPayloadBytes,
                    actualBytes: data.count
                )
            }
            fields["payload"] = .data(data)
            fields["payloadSHA256"] = .string(sha256(data))
        }
        return AgentDefinitionCloudRecord(
            recordType: recordType,
            recordName: envelope.recordName,
            fields: fields
        )
    }

    static func decode(
        _ record: AgentDefinitionCloudRecord
    ) throws -> AgentDefinitionSyncEnvelope {
        guard record.recordType == recordType else {
            throw AgentDefinitionSyncError.invalidCloudRecordType(record.recordType)
        }
        let unexpected = Set(record.fields.keys).subtracting(allowedFieldNames)
        guard unexpected.isEmpty else {
            throw AgentDefinitionSyncError.unexpectedCloudFields(unexpected)
        }
        let schemaVersion = try integer("schemaVersion", from: record)
        guard schemaVersion == AgentDefinitionSyncEnvelope.currentSchemaVersion else {
            throw AgentDefinitionSyncError.unsupportedEnvelopeSchema(schemaVersion)
        }
        let categoryRaw = try string("category", from: record)
        guard let category = AgentDefinitionSyncCategory(rawValue: categoryRaw) else {
            throw AgentDefinitionSyncError.invalidCategory(categoryRaw)
        }
        let definitionIDRaw = try string("definitionID", from: record)
        guard let definitionID = UUID(uuidString: definitionIDRaw) else {
            throw AgentDefinitionSyncError.invalidDefinitionID(definitionIDRaw)
        }
        let expectedRecordName = self.recordName(
            category: category,
            definitionID: definitionID
        )
        guard record.recordName == expectedRecordName else {
            throw AgentDefinitionSyncError.cloudRecordNameMismatch
        }
        let revision = try integer("revision", from: record)
        let modifiedAt = try date("modifiedAt", from: record)
        let deviceID = try string("modifiedByDeviceID", from: record)
        let tombstoneValue = try integer("tombstone", from: record)
        guard tombstoneValue == 0 || tombstoneValue == 1 else {
            throw AgentDefinitionSyncError.invalidCloudField("tombstone")
        }

        if tombstoneValue == 1 {
            guard record.fields["payload"] == nil,
                  record.fields["payloadSHA256"] == nil
            else {
                throw AgentDefinitionSyncError.tombstoneContainsPayload
            }
            return try .tombstone(
                category: category,
                definitionID: definitionID,
                revision: revision,
                modifiedAt: modifiedAt,
                modifiedByDeviceID: deviceID
            )
        }

        let payloadData = try data("payload", from: record)
        guard payloadData.count <= maximumPayloadBytes else {
            throw AgentDefinitionSyncError.payloadTooLarge(
                maximumBytes: maximumPayloadBytes,
                actualBytes: payloadData.count
            )
        }
        guard try string("payloadSHA256", from: record) == sha256(payloadData) else {
            throw AgentDefinitionSyncError.payloadDigestMismatch
        }
        let payload = try decodePayload(payloadData, category: category)
        let envelope = AgentDefinitionSyncEnvelope(
            schemaVersion: schemaVersion,
            category: category,
            definitionID: definitionID,
            revision: revision,
            modifiedAt: modifiedAt,
            modifiedByDeviceID: deviceID,
            isTombstone: false,
            payload: payload
        )
        try envelope.validate()
        return envelope
    }

    static func digest(_ envelope: AgentDefinitionSyncEnvelope) throws -> String {
        sha256(try codingEncoder().encode(envelope))
    }

    static func digest(_ preset: AgentSyncedProviderPreset) throws -> String {
        sha256(try codingEncoder().encode(preset))
    }

    private static func encodePayload(_ payload: AgentSyncedDefinition) throws -> Data {
        switch payload {
        case .schedule(let value): return try codingEncoder().encode(value)
        case .providerPreset(let value): return try codingEncoder().encode(value)
        case .userAuthoredMemory(let value): return try codingEncoder().encode(value)
        }
    }

    private static func decodePayload(
        _ data: Data,
        category: AgentDefinitionSyncCategory
    ) throws -> AgentSyncedDefinition {
        do {
            switch category {
            case .schedules:
                return .schedule(try codingDecoder().decode(
                    AgentSyncedScheduleDefinition.self,
                    from: data
                ))
            case .providerPresets:
                return .providerPreset(try codingDecoder().decode(
                    AgentSyncedProviderPreset.self,
                    from: data
                ))
            case .userAuthoredMemory:
                return .userAuthoredMemory(try codingDecoder().decode(
                    AgentSyncedUserMemory.self,
                    from: data
                ))
            }
        } catch let error as AgentDefinitionSyncError {
            throw error
        } catch {
            throw AgentDefinitionSyncError.invalidPayload
        }
    }

    private static func codingEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static func codingDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func integer(
        _ field: String,
        from record: AgentDefinitionCloudRecord
    ) throws -> Int {
        guard case .integer(let value) = record.fields[field],
              value >= Int64(Int.min), value <= Int64(Int.max)
        else {
            throw AgentDefinitionSyncError.invalidCloudField(field)
        }
        return Int(value)
    }

    private static func string(
        _ field: String,
        from record: AgentDefinitionCloudRecord
    ) throws -> String {
        guard case .string(let value) = record.fields[field] else {
            throw AgentDefinitionSyncError.invalidCloudField(field)
        }
        return value
    }

    private static func date(
        _ field: String,
        from record: AgentDefinitionCloudRecord
    ) throws -> Date {
        guard case .date(let value) = record.fields[field] else {
            throw AgentDefinitionSyncError.invalidCloudField(field)
        }
        return value
    }

    private static func data(
        _ field: String,
        from record: AgentDefinitionCloudRecord
    ) throws -> Data {
        guard case .data(let value) = record.fields[field] else {
            throw AgentDefinitionSyncError.invalidCloudField(field)
        }
        return value
    }
}

#if canImport(CloudKit)
extension AgentDefinitionCloudRecordCodec {
    nonisolated static func cloudKitRecord(
        for envelope: AgentDefinitionSyncEnvelope,
        zoneID: CKRecordZone.ID? = nil
    ) throws -> CKRecord {
        let portable = try encode(envelope)
        let recordID: CKRecord.ID
        if let zoneID {
            recordID = CKRecord.ID(recordName: portable.recordName, zoneID: zoneID)
        } else {
            recordID = CKRecord.ID(recordName: portable.recordName)
        }
        let record = CKRecord(recordType: portable.recordType, recordID: recordID)
        for (key, value) in portable.fields {
            switch value {
            case .integer(let item): record[key] = NSNumber(value: item)
            case .string(let item): record[key] = item as NSString
            case .date(let item): record[key] = item as NSDate
            case .data(let item): record[key] = item as NSData
            }
        }
        return record
    }

    nonisolated static func decode(
        _ record: CKRecord
    ) throws -> AgentDefinitionSyncEnvelope {
        var fields: [String: AgentDefinitionCloudFieldValue] = [:]
        for key in record.allKeys() {
            guard allowedFieldNames.contains(key) else {
                throw AgentDefinitionSyncError.unexpectedCloudFields([key])
            }
            switch record[key] {
            case let value as NSNumber: fields[key] = .integer(value.int64Value)
            case let value as NSString: fields[key] = .string(value as String)
            case let value as NSDate: fields[key] = .date(value as Date)
            case let value as NSData: fields[key] = .data(value as Data)
            default: throw AgentDefinitionSyncError.invalidCloudField(key)
            }
        }
        return try decode(AgentDefinitionCloudRecord(
            recordType: record.recordType,
            recordName: record.recordID.recordName,
            fields: fields
        ))
    }
}
#endif

// MARK: - Stateful sync boundary

nonisolated protocol AgentDefinitionSyncBackend: Sendable {
    func save(_ records: [AgentDefinitionCloudRecord]) async throws
    func fetch(
        categories: Set<AgentDefinitionSyncCategory>
    ) async throws -> [AgentDefinitionCloudRecord]
}

#if canImport(CloudKit)
/// Private-database backend for the user's existing Straight Up Browser
/// CloudKit container. Logical deletion is represented by the signed-off
/// tombstone envelope, allowing every device to converge before old content is
/// eventually purged by a retention job.
actor CloudKitAgentDefinitionSyncBackend: AgentDefinitionSyncBackend {
    static let defaultContainerIdentifier =
        "iCloud.com.nathanfennel.Straight-Up-Browser"

    private let containerIdentifier: String
    private var resolvedDatabase: CKDatabase?
    private let zoneID: CKRecordZone.ID?
    private let maximumRecordsPerFetch: Int

    init(
        containerIdentifier: String = defaultContainerIdentifier,
        zoneID: CKRecordZone.ID? = nil,
        maximumRecordsPerFetch: Int = 10_000
    ) {
        self.containerIdentifier = containerIdentifier
        self.zoneID = zoneID
        self.maximumRecordsPerFetch = max(1, maximumRecordsPerFetch)
    }

    func save(_ records: [AgentDefinitionCloudRecord]) async throws {
        guard !records.isEmpty else { return }
        let cloudRecords = try records.map { portable -> CKRecord in
            let envelope = try AgentDefinitionCloudRecordCodec.decode(portable)
            return try AgentDefinitionCloudRecordCodec.cloudKitRecord(
                for: envelope,
                zoneID: zoneID
            )
        }
        let result = try await database().modifyRecords(
            saving: cloudRecords,
            deleting: [],
            savePolicy: .allKeys,
            atomically: true
        )
        for saveResult in result.saveResults.values {
            _ = try saveResult.get()
        }
    }

    func fetch(
        categories: Set<AgentDefinitionSyncCategory>
    ) async throws -> [AgentDefinitionCloudRecord] {
        guard !categories.isEmpty else { return [] }
        let query = CKQuery(
            recordType: AgentDefinitionCloudRecordCodec.recordType,
            predicate: NSPredicate(value: true)
        )
        let desiredKeys = Array(
            AgentDefinitionCloudRecordCodec.allowedFieldNames
        ).sorted()
        let database = database()
        var page = try await database.records(
            matching: query,
            inZoneWith: zoneID,
            desiredKeys: desiredKeys,
            resultsLimit: min(CKQueryOperation.maximumResults, maximumRecordsPerFetch)
        )
        var cloudRecords: [CKRecord] = try page.matchResults.map { try $0.1.get() }
        while let cursor = page.queryCursor,
              cloudRecords.count < maximumRecordsPerFetch {
            page = try await database.records(
                continuingMatchFrom: cursor,
                desiredKeys: desiredKeys,
                resultsLimit: min(
                    CKQueryOperation.maximumResults,
                    maximumRecordsPerFetch - cloudRecords.count
                )
            )
            cloudRecords.append(contentsOf: try page.matchResults.map {
                try $0.1.get()
            })
        }
        if page.queryCursor != nil, cloudRecords.count >= maximumRecordsPerFetch {
            throw AgentDefinitionSyncError.cloudRecordLimitExceeded(
                maximumRecordsPerFetch
            )
        }
        return try cloudRecords.map(AgentDefinitionCloudRecordCodec.decode)
            .filter { categories.contains($0.category) }
            .map(AgentDefinitionCloudRecordCodec.encode)
            .sorted { $0.recordName < $1.recordName }
    }

    /// Resolving a CloudKit container can validate entitlements immediately.
    /// Keep that work behind an actual opted-in fetch/write so constructing the
    /// browser's scheduler and settings graph remains safe in unsigned test
    /// hosts and when every definition-sync category is disabled.
    private func database() -> CKDatabase {
        if let resolvedDatabase { return resolvedDatabase }
        let database = CKContainer(identifier: containerIdentifier)
            .privateCloudDatabase
        resolvedDatabase = database
        return database
    }
}
#endif

/// A deterministic backend used by previews/tests and as an offline queue
/// boundary. Production CloudKit integration implements the same protocol and
/// can only receive records already constrained by the allowlisted codec.
actor AgentDefinitionInMemorySyncBackend: AgentDefinitionSyncBackend {
    private var recordsByName: [String: AgentDefinitionCloudRecord]
    private var saves = 0

    init(records: [AgentDefinitionCloudRecord] = []) throws {
        recordsByName = [:]
        for record in records {
            let envelope = try AgentDefinitionCloudRecordCodec.decode(record)
            recordsByName[envelope.recordName] = record
        }
    }

    func save(_ records: [AgentDefinitionCloudRecord]) async throws {
        guard !records.isEmpty else { return }
        saves += 1
        for record in records {
            let incoming = try AgentDefinitionCloudRecordCodec.decode(record)
            if let currentRecord = recordsByName[incoming.recordName] {
                let current = try AgentDefinitionCloudRecordCodec.decode(currentRecord)
                let winner = try AgentDefinitionConflictResolver.resolve(
                    current,
                    incoming
                ).winner
                recordsByName[incoming.recordName] =
                    try AgentDefinitionCloudRecordCodec.encode(winner)
            } else {
                recordsByName[incoming.recordName] = record
            }
        }
    }

    func fetch(
        categories: Set<AgentDefinitionSyncCategory>
    ) async throws -> [AgentDefinitionCloudRecord] {
        try recordsByName.values.filter { record in
            let envelope = try AgentDefinitionCloudRecordCodec.decode(record)
            return categories.contains(envelope.category)
        }.sorted { $0.recordName < $1.recordName }
    }

    func saveCallCount() -> Int { saves }

    func storedRecords() -> [AgentDefinitionCloudRecord] {
        recordsByName.values.sorted { $0.recordName < $1.recordName }
    }
}

nonisolated enum AgentDefinitionSyncWriteSuppressionReason: Codable, Equatable,
    Sendable
{
    case categoryDisabled(AgentDefinitionSyncCategory)
}

nonisolated enum AgentDefinitionSyncPublishResult: Equatable, Sendable {
    case uploaded(recordName: String)
    case suppressed(AgentDefinitionSyncWriteSuppressionReason)
}

nonisolated enum AgentDefinitionSyncDisableDisposition: String, Codable, Equatable,
    Sendable
{
    case keepLocalCopies
    case deleteCloudCopies
}

nonisolated enum AgentDefinitionSyncLocalAction: String, Codable, Equatable, Sendable {
    case retainAsLocalOnly
}

nonisolated struct AgentDefinitionSyncDisableReceipt: Equatable, Sendable {
    let category: AgentDefinitionSyncCategory
    let disposition: AgentDefinitionSyncDisableDisposition
    let localAction: AgentDefinitionSyncLocalAction
    let cloudTombstones: [AgentDefinitionSyncEnvelope]
}

nonisolated struct AgentDefinitionSyncPullResult: Equatable, Sendable {
    let definitionsByRecordName: [String: AgentDefinitionSyncEnvelope]
    let downloadedRecordCount: Int
}

nonisolated enum AgentDefinitionSyncLogOperation: String, Codable, Sendable {
    case upload
    case download
    case disableKeepLocal
    case disableDeleteCloud
    case suppressed
}

nonisolated enum AgentDefinitionSyncLogOutcome: String, Codable, Sendable {
    case succeeded
    case categoryDisabled
}

/// Logs contain identities and outcomes only—never a definition name, prompt,
/// endpoint, memory text, dependency value, payload, or transport error body.
nonisolated struct AgentDefinitionSyncLogEvent: Codable, Equatable, Sendable {
    let occurredAt: Date
    let operation: AgentDefinitionSyncLogOperation
    let outcome: AgentDefinitionSyncLogOutcome
    let category: AgentDefinitionSyncCategory
    let recordName: String?
    let revision: Int?
}

actor AgentDefinitionSyncController {
    private var preferences: AgentDefinitionSyncPreferences
    private let deviceID: String
    private let backend: any AgentDefinitionSyncBackend
    private var logEvents: [AgentDefinitionSyncLogEvent] = []

    init(
        preferences: AgentDefinitionSyncPreferences = .disabled,
        deviceID: String,
        backend: any AgentDefinitionSyncBackend
    ) {
        self.preferences = preferences
        self.deviceID = deviceID
        self.backend = backend
    }

    func currentPreferences() -> AgentDefinitionSyncPreferences { preferences }

    func setEnabled(
        _ enabled: Bool,
        for category: AgentDefinitionSyncCategory
    ) {
        preferences.setEnabled(enabled, for: category)
    }

    func publish(
        _ envelope: AgentDefinitionSyncEnvelope,
        at date: Date = Date()
    ) async throws -> AgentDefinitionSyncPublishResult {
        try envelope.validate()
        guard preferences.isEnabled(envelope.category) else {
            logEvents.append(AgentDefinitionSyncLogEvent(
                occurredAt: date,
                operation: .suppressed,
                outcome: .categoryDisabled,
                category: envelope.category,
                recordName: envelope.recordName,
                revision: envelope.revision
            ))
            return .suppressed(.categoryDisabled(envelope.category))
        }
        let record = try AgentDefinitionCloudRecordCodec.encode(envelope)
        try await backend.save([record])
        logEvents.append(AgentDefinitionSyncLogEvent(
            occurredAt: date,
            operation: .upload,
            outcome: .succeeded,
            category: envelope.category,
            recordName: envelope.recordName,
            revision: envelope.revision
        ))
        return .uploaded(recordName: envelope.recordName)
    }

    func pull(
        merging local: [String: AgentDefinitionSyncEnvelope] = [:],
        at date: Date = Date()
    ) async throws -> AgentDefinitionSyncPullResult {
        let enabled = Set(AgentDefinitionSyncCategory.allCases.filter(
            preferences.isEnabled
        ))
        guard !enabled.isEmpty else {
            return AgentDefinitionSyncPullResult(
                definitionsByRecordName: local,
                downloadedRecordCount: 0
            )
        }
        let records = try await backend.fetch(categories: enabled)
        let envelopes = try records.map(AgentDefinitionCloudRecordCodec.decode)
            .filter { preferences.isEnabled($0.category) }
        let merged = try AgentDefinitionConflictResolver.merge(
            local: local,
            remote: envelopes
        )
        let reconciliation = try envelopes.compactMap { remote -> AgentDefinitionCloudRecord? in
            guard let winner = merged[remote.recordName], winner != remote else {
                return nil
            }
            return try AgentDefinitionCloudRecordCodec.encode(winner)
        }
        if !reconciliation.isEmpty {
            try await backend.save(reconciliation)
        }
        for envelope in envelopes {
            logEvents.append(AgentDefinitionSyncLogEvent(
                occurredAt: date,
                operation: .download,
                outcome: .succeeded,
                category: envelope.category,
                recordName: envelope.recordName,
                revision: envelope.revision
            ))
        }
        return AgentDefinitionSyncPullResult(
            definitionsByRecordName: merged,
            downloadedRecordCount: envelopes.count
        )
    }

    /// Disabling happens before any await. A concurrent publish entering while
    /// the delete-cloud transition is in flight therefore observes the category
    /// as disabled and cannot create a new backend write.
    func disable(
        _ category: AgentDefinitionSyncCategory,
        disposition: AgentDefinitionSyncDisableDisposition,
        knownLocalDefinitions: [AgentDefinitionSyncEnvelope] = [],
        at date: Date = Date()
    ) async throws -> AgentDefinitionSyncDisableReceipt {
        preferences.setEnabled(false, for: category)
        switch disposition {
        case .keepLocalCopies:
            logEvents.append(AgentDefinitionSyncLogEvent(
                occurredAt: date,
                operation: .disableKeepLocal,
                outcome: .succeeded,
                category: category,
                recordName: nil,
                revision: nil
            ))
            return AgentDefinitionSyncDisableReceipt(
                category: category,
                disposition: disposition,
                localAction: .retainAsLocalOnly,
                cloudTombstones: []
            )

        case .deleteCloudCopies:
            let remoteRecords = try await backend.fetch(categories: [category])
            let remote = try remoteRecords.map(AgentDefinitionCloudRecordCodec.decode)
            let local = try AgentDefinitionConflictResolver.merge(
                local: [:],
                remote: knownLocalDefinitions.filter { $0.category == category }
            )
            let winners = try AgentDefinitionConflictResolver.merge(
                local: local,
                remote: remote
            ).values.sorted { $0.recordName < $1.recordName }
            var tombstones: [AgentDefinitionSyncEnvelope] = []
            for winner in winners {
                if winner.isTombstone {
                    tombstones.append(winner)
                } else {
                    tombstones.append(try winner.replacingWithTombstone(
                        at: date,
                        modifiedByDeviceID: deviceID
                    ))
                }
            }
            if !tombstones.isEmpty {
                try await backend.save(try tombstones.map(
                    AgentDefinitionCloudRecordCodec.encode
                ))
            }
            logEvents.append(AgentDefinitionSyncLogEvent(
                occurredAt: date,
                operation: .disableDeleteCloud,
                outcome: .succeeded,
                category: category,
                recordName: nil,
                revision: nil
            ))
            return AgentDefinitionSyncDisableReceipt(
                category: category,
                disposition: disposition,
                localAction: .retainAsLocalOnly,
                cloudTombstones: tombstones
            )
        }
    }

    func privacySafeLog() -> [AgentDefinitionSyncLogEvent] { logEvents }
}

// MARK: - Validation

nonisolated enum AgentDefinitionSyncError: Error, Equatable, Sendable {
    case unsupportedEnvelopeSchema(Int)
    case unsupportedPayloadSchema(category: AgentDefinitionSyncCategory, version: Int)
    case invalidRevision(Int)
    case invalidText(field: String)
    case suspectedSecret(field: String)
    case invalidEndpointIdentity
    case nonCanonicalValue(field: String)
    case invalidTimestamp
    case invalidTimeZone(String)
    case invalidScheduleDefinition
    case prohibitedField(String)
    case memoryWasNotUserAuthored
    case providerPresetMismatch
    case tombstoneContainsPayload
    case missingPayload
    case envelopePayloadMismatch
    case conflictingRecordIdentities
    case payloadTooLarge(maximumBytes: Int, actualBytes: Int)
    case invalidCloudRecordType(String)
    case unexpectedCloudFields(Set<String>)
    case invalidCloudField(String)
    case invalidCategory(String)
    case invalidDefinitionID(String)
    case cloudRecordNameMismatch
    case payloadDigestMismatch
    case invalidPayload
    case syncDisabled(AgentDefinitionSyncCategory)
    case activationPermitMismatch
    case cloudRecordLimitExceeded(Int)
}

private nonisolated enum AgentDefinitionSyncValidation {
    static func canonicalDate(_ date: Date) -> Date {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    static func isCanonicalDate(_ date: Date) -> Bool {
        date == canonicalDate(date)
    }

    static func positiveRevision(_ revision: Int) throws {
        guard revision > 0 else {
            throw AgentDefinitionSyncError.invalidRevision(revision)
        }
    }

    static func safeIdentifier(
        _ value: String,
        field: String,
        maximumUTF8Bytes: Int = 256
    ) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= maximumUTF8Bytes,
              normalized.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw AgentDefinitionSyncError.invalidText(field: field)
        }
        guard !containsCredentialMaterial(normalized) else {
            throw AgentDefinitionSyncError.suspectedSecret(field: field)
        }
        return normalized
    }

    static func safeText(
        _ value: String,
        field: String,
        maximumUTF8Bytes: Int
    ) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= maximumUTF8Bytes,
              normalized.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
                      || scalar == "\n" || scalar == "\t"
              })
        else {
            throw AgentDefinitionSyncError.invalidText(field: field)
        }
        guard !containsCredentialMaterial(normalized) else {
            throw AgentDefinitionSyncError.suspectedSecret(field: field)
        }
        return normalized
    }

    static func endpoint(_ value: String) throws -> String {
        guard value.utf8.count <= 2_048,
              !containsCredentialMaterial(value),
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw AgentDefinitionSyncError.invalidEndpointIdentity
        }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw AgentDefinitionSyncError.invalidEndpointIdentity
        }
        components.scheme = scheme
        components.host = host
        guard let normalizedURL = components.url else {
            throw AgentDefinitionSyncError.invalidEndpointIdentity
        }
        var normalized = normalizedURL.absoluteString
        if normalized.count > "https://x/".count, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    static func isCanonicalOrigin(_ value: String) -> Bool {
        (try? canonicalOrigin(value)) == value
    }

    static func canonicalOrigin(_ value: String) throws -> String {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              scheme == "https" || scheme == "http",
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil
        else {
            throw AgentDefinitionSyncError.nonCanonicalValue(field: "origin")
        }
        let renderedHost = host.contains(":") ? "[\(host)]" : host
        var expected = "\(scheme)://\(renderedHost)"
        if let port = components.port,
           !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) {
            expected += ":\(port)"
        }
        return expected
    }

    static func containsCredentialMaterial(_ value: String) -> Bool {
        let lowercase = value.lowercased()
        let markers = [
            "authorization: bearer ",
            "api_key=",
            "apikey=",
            "api-key=",
            "access_token=",
            "refresh_token=",
            "client_secret=",
            "password=",
            "passwd=",
            "bearer eyj",
            "xoxb-",
            "xoxp-",
            "ghp_",
            "github_pat_",
        ]
        if markers.contains(where: lowercase.contains) { return true }
        let tokens = value.split(whereSeparator: \Character.isWhitespace)
        return tokens.contains { token in
            let candidate = String(token).trimmingCharacters(
                in: CharacterSet(charactersIn: "\"'`()[]{}<>,;:")
            )
            return candidate.hasPrefix("sk-") && candidate.count >= 20
        }
    }
}
