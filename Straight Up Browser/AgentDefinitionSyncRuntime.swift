import Combine
import CryptoKit
import Foundation

nonisolated struct AgentDefinitionSyncRuntimeSnapshot: Sendable {
    let definitionsByRecordName: [String: AgentDefinitionSyncEnvelope]
    /// Payload-bearing copies retained only on this device after sync is
    /// disabled. They are deliberately separate from CloudKit reconciliation,
    /// so a cloud tombstone can never destroy the user's local definition.
    let localOnlyDefinitionsByRecordName: [String: AgentDefinitionSyncEnvelope]
    let preferences: AgentDefinitionSyncPreferences
    let deviceID: String
}

/// Durable local cache plus the real private-CloudKit synchronization boundary.
/// The cache contains only the allowlisted, secret-free envelope projection.
actor AgentDefinitionSyncRuntime {
    private struct Cache: Codable {
        static let currentSchemaVersion = 1
        var schemaVersion = currentSchemaVersion
        var definitions: [AgentDefinitionSyncEnvelope]
        /// Optional keeps the v1 cache forward-compatible with builds which
        /// predate retained local-only copies.
        var localOnlyDefinitions: [AgentDefinitionSyncEnvelope]?
    }

    private static let deviceIDKey = "agentDefinitionSync.deviceID"
    private let defaults: UserDefaults
    private let cacheURL: URL
    private let deviceID: String
    private let controller: AgentDefinitionSyncController
    private var definitionsByRecordName: [String: AgentDefinitionSyncEnvelope]
    private var localOnlyDefinitionsByRecordName: [String: AgentDefinitionSyncEnvelope]

    #if canImport(CloudKit)
    static let shared = AgentDefinitionSyncRuntime(
        baseDirectory: FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Straight Up Browser", isDirectory: true),
        backend: CloudKitAgentDefinitionSyncBackend()
    )
    #endif

    init(
        baseDirectory: URL,
        defaultsSuiteName: String? = nil,
        backend: any AgentDefinitionSyncBackend
    ) {
        let defaults = defaultsSuiteName.flatMap { UserDefaults(suiteName: $0) }
            ?? .standard
        self.defaults = defaults
        let directory = baseDirectory
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("definition-sync", isDirectory: true)
        cacheURL = directory.appendingPathComponent("definitions-v1.json")
        if let existing = defaults.string(forKey: Self.deviceIDKey), !existing.isEmpty {
            deviceID = existing
        } else {
            let generated = UUID().uuidString.lowercased()
            defaults.set(generated, forKey: Self.deviceIDKey)
            deviceID = generated
        }
        controller = AgentDefinitionSyncController(
            preferences: AgentDefinitionSyncSettings.preferences(from: defaults),
            deviceID: deviceID,
            backend: backend
        )
        let cache = Self.loadCache(at: cacheURL)
        definitionsByRecordName = cache.synced
        localOnlyDefinitionsByRecordName = cache.localOnly
    }

    func refresh(at date: Date = Date()) async throws -> AgentDefinitionSyncPullResult {
        let preferences = AgentDefinitionSyncSettings.preferences(from: defaults)
        for category in AgentDefinitionSyncCategory.allCases {
            await controller.setEnabled(preferences.isEnabled(category), for: category)
        }
        let pulled = try await controller.pull(
            merging: definitionsByRecordName,
            at: date
        )
        definitionsByRecordName = pulled.definitionsByRecordName
        try persistCache()
        return pulled
    }

    @discardableResult
    func publish(
        _ envelope: AgentDefinitionSyncEnvelope,
        at date: Date = Date()
    ) async throws -> AgentDefinitionSyncPublishResult {
        try envelope.validate()
        let preferences = AgentDefinitionSyncSettings.preferences(from: defaults)
        await controller.setEnabled(
            preferences.isEnabled(envelope.category),
            for: envelope.category
        )
        guard preferences.isEnabled(envelope.category) else {
            Self.merge(envelope, into: &localOnlyDefinitionsByRecordName)
            try persistCache()
            return try await controller.publish(envelope, at: date)
        }

        // Do not claim a definition is synchronized locally until the backend
        // accepted it. A failed upload leaves any retained local-only copy
        // available for the next retry.
        let result = try await controller.publish(envelope, at: date)
        Self.merge(envelope, into: &definitionsByRecordName)
        localOnlyDefinitionsByRecordName.removeValue(forKey: envelope.recordName)
        try persistCache()
        return result
    }

    /// Publishes a local product definition only when its allowlisted content
    /// changed. Revisions are rebased above both the cached cloud winner and a
    /// retained local-only copy, including a cloud tombstone.
    @discardableResult
    func publishLocalPayload(
        _ payload: AgentSyncedDefinition,
        at date: Date = Date()
    ) async throws -> AgentDefinitionSyncPublishResult? {
        try payload.validate()
        let recordName = AgentDefinitionCloudRecordCodec.recordName(
            category: payload.category,
            definitionID: payload.definitionID
        )
        let synced = definitionsByRecordName[recordName]
        let retained = localOnlyDefinitionsByRecordName[recordName]
        if let syncedPayload = synced?.payload,
           !synced!.isTombstone,
           Self.hasEquivalentContent(syncedPayload, payload) {
            localOnlyDefinitionsByRecordName.removeValue(forKey: recordName)
            try persistCache()
            return nil
        }
        // A tombstone received while sync is enabled is an authoritative
        // deletion, not an invitation for the still-present local product
        // object to recreate itself during the same sync pass. Explicitly
        // retained disable/re-enable copies are the exception; schedule models
        // with a genuinely higher intrinsic revision also represent a new edit.
        if let synced, synced.isTombstone, retained == nil,
           payload.revision <= synced.revision {
            return nil
        }

        let existingRevision = max(synced?.revision ?? 0, retained?.revision ?? 0)
        let desiredRevision = payload.revision
        let revision = existingRevision == 0
            ? desiredRevision
            : max(desiredRevision, existingRevision + 1)
        let createdAt = Self.createdAt(from: retained?.payload)
            ?? Self.createdAt(from: synced?.payload)
            ?? Self.createdAt(from: payload)
            ?? date
        let revised = try Self.revised(
            payload,
            revision: revision,
            createdAt: createdAt,
            updatedAt: date
        )
        return try await publish(AgentDefinitionSyncEnvelope(
            payload: revised,
            modifiedAt: date,
            modifiedByDeviceID: deviceID
        ), at: date)
    }

    func setEnabled(
        _ enabled: Bool,
        category: AgentDefinitionSyncCategory
    ) async throws -> AgentDefinitionSyncPullResult {
        var preferences = AgentDefinitionSyncSettings.preferences(from: defaults)
        preferences.setEnabled(enabled, for: category)
        AgentDefinitionSyncSettings.save(preferences, to: defaults)
        await controller.setEnabled(enabled, for: category)
        guard enabled else { return try await refresh() }

        // First learn any newer remote tombstone, then explicitly recreate
        // retained local definitions above that revision. This is what makes
        // delete-cloud reversible without resurrecting stale records.
        _ = try await refresh()
        let retained = localOnlyDefinitionsByRecordName.values
            .filter { $0.category == category && !$0.isTombstone }
            .sorted { $0.recordName < $1.recordName }
        for envelope in retained {
            guard let payload = envelope.payload else { continue }
            if let synced = definitionsByRecordName[envelope.recordName],
               !synced.isTombstone {
                let resolution = try AgentDefinitionConflictResolver.resolve(
                    synced,
                    envelope
                )
                guard resolution.winner == envelope else {
                    localOnlyDefinitionsByRecordName.removeValue(
                        forKey: envelope.recordName
                    )
                    try persistCache()
                    continue
                }
            }
            _ = try await publishLocalPayload(payload)
        }
        return try await refresh()
    }

    func disable(
        _ category: AgentDefinitionSyncCategory,
        disposition: AgentDefinitionSyncDisableDisposition
    ) async throws -> AgentDefinitionSyncDisableReceipt {
        // A delete-cloud choice should tombstone the newest revision this
        // device can observe. Keep-local remains an offline-capable operation.
        if disposition == .deleteCloudCopies {
            _ = try await refresh()
        }
        let receipt = try await controller.disable(
            category,
            disposition: disposition,
            knownLocalDefinitions: definitionsByRecordName.values.filter {
                $0.category == category
            }
        )
        var preferences = AgentDefinitionSyncSettings.preferences(from: defaults)
        preferences.setEnabled(false, for: category)
        AgentDefinitionSyncSettings.save(preferences, to: defaults)
        let localCopies = definitionsByRecordName.values.filter {
            $0.category == category && !$0.isTombstone && $0.payload != nil
        }
        for envelope in localCopies {
            Self.merge(envelope, into: &localOnlyDefinitionsByRecordName)
        }
        for tombstone in receipt.cloudTombstones {
            definitionsByRecordName[tombstone.recordName] = tombstone
        }
        try persistCache()
        return receipt
    }

    func snapshot() async -> AgentDefinitionSyncRuntimeSnapshot {
        let preferences = await controller.currentPreferences()
        var visible = definitionsByRecordName
        for (recordName, envelope) in localOnlyDefinitionsByRecordName
            where !preferences.isEnabled(envelope.category)
        {
            visible[recordName] = envelope
        }
        return AgentDefinitionSyncRuntimeSnapshot(
            definitionsByRecordName: visible,
            localOnlyDefinitionsByRecordName: localOnlyDefinitionsByRecordName,
            preferences: preferences,
            deviceID: deviceID
        )
    }

    func privacySafeLog() async -> [AgentDefinitionSyncLogEvent] {
        await controller.privacySafeLog()
    }

    private func persistCache() throws {
        let directory = cacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        // Foundation's built-in ISO-8601 strategy omits fractional seconds.
        // Synced definitions canonicalize dates to milliseconds, so dropping
        // that precision changes an otherwise identical envelope after an app
        // restart and can trigger a needless conflict/upload.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [
                .withInternetDateTime,
                .withFractionalSeconds,
            ]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Cache(
            definitions: definitionsByRecordName.values.sorted {
                $0.recordName < $1.recordName
            },
            localOnlyDefinitions: localOnlyDefinitionsByRecordName.values.sorted {
                $0.recordName < $1.recordName
            }
        ))
        try data.write(to: cacheURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: cacheURL.path
        )
    }

    private nonisolated static func loadCache(
        at url: URL
    ) -> (
        synced: [String: AgentDefinitionSyncEnvelope],
        localOnly: [String: AgentDefinitionSyncEnvelope]
    ) {
        guard let data = try? Data(contentsOf: url) else { return ([:], [:]) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let encodedDate = try container.decode(String.self)
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [
                .withInternetDateTime,
                .withFractionalSeconds,
            ]
            if let date = fractionalFormatter.date(from: encodedDate) {
                return date
            }

            // Cache schema v1 originally used JSONDecoder's `.iso8601`
            // strategy, so continue accepting its whole-second values.
            let legacyFormatter = ISO8601DateFormatter()
            legacyFormatter.formatOptions = [.withInternetDateTime]
            guard let date = legacyFormatter.date(from: encodedDate) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 cache date"
                )
            }
            return date
        }
        guard let cache = try? decoder.decode(Cache.self, from: data),
              cache.schemaVersion == Cache.currentSchemaVersion
        else { return ([:], [:]) }
        func validatedMap(
            _ envelopes: [AgentDefinitionSyncEnvelope]
        ) -> [String: AgentDefinitionSyncEnvelope] {
            var result: [String: AgentDefinitionSyncEnvelope] = [:]
            for envelope in envelopes {
                guard (try? envelope.validate()) != nil else { continue }
                if let existing = result[envelope.recordName] {
                    result[envelope.recordName] = (try? AgentDefinitionConflictResolver
                        .resolve(existing, envelope).winner) ?? existing
                } else {
                    result[envelope.recordName] = envelope
                }
            }
            return result
        }
        return (
            validatedMap(cache.definitions),
            validatedMap(cache.localOnlyDefinitions ?? [])
        )
    }

    private nonisolated static func merge(
        _ envelope: AgentDefinitionSyncEnvelope,
        into definitions: inout [String: AgentDefinitionSyncEnvelope]
    ) {
        if let existing = definitions[envelope.recordName] {
            definitions[envelope.recordName] = (try? AgentDefinitionConflictResolver
                .resolve(existing, envelope).winner) ?? existing
        } else {
            definitions[envelope.recordName] = envelope
        }
    }

    private nonisolated static func hasEquivalentContent(
        _ lhs: AgentSyncedDefinition,
        _ rhs: AgentSyncedDefinition
    ) -> Bool {
        switch (lhs, rhs) {
        case (.providerPreset(let a), .providerPreset(let b)):
            return a.id == b.id && a.name == b.name && a.providerID == b.providerID
                && a.model == b.model && a.endpointIdentity == b.endpointIdentity
                && a.reportsUsage == b.reportsUsage
                && a.supportsStreaming == b.supportsStreaming
                && a.requiresLocalProviderAccess == b.requiresLocalProviderAccess
        case (.schedule(let a), .schedule(let b)):
            return a.id == b.id && a.name == b.name && a.prompt == b.prompt
                && a.enabled == b.enabled && a.schedule == b.schedule
                && a.timeZoneIdentifier == b.timeZoneIdentifier
                && a.daylightSavingPolicy == b.daylightSavingPolicy
                && a.providerPresetID == b.providerPresetID
                && a.allowedOrigins == b.allowedOrigins
                && a.browserSessionRequirement == b.browserSessionRequirement
                && a.requiredCapabilities == b.requiredCapabilities
                && a.requiredMCPConnectionIDs == b.requiredMCPConnectionIDs
                && a.requiredCoworkRootID == b.requiredCoworkRootID
                && a.budgets == b.budgets && a.timeoutSeconds == b.timeoutSeconds
                && a.concurrencyPolicy == b.concurrencyPolicy
                && a.retentionPolicy == b.retentionPolicy
                && a.catchUpPolicy == b.catchUpPolicy
                && a.notificationPolicy == b.notificationPolicy
        case (.userAuthoredMemory(let a), .userAuthoredMemory(let b)):
            return a.id == b.id && a.text == b.text && a.scope == b.scope
                && a.sessionScope == b.sessionScope && a.sensitivity == b.sensitivity
                && a.expiresAt == b.expiresAt && a.isEnabled == b.isEnabled
        default:
            return false
        }
    }

    private nonisolated static func createdAt(
        from payload: AgentSyncedDefinition?
    ) -> Date? {
        switch payload {
        case .providerPreset(let value): value.createdAt
        case .schedule(let value): value.createdAt
        case .userAuthoredMemory(let value): value.createdAt
        case nil: nil
        }
    }

    private nonisolated static func revised(
        _ payload: AgentSyncedDefinition,
        revision: Int,
        createdAt: Date,
        updatedAt: Date
    ) throws -> AgentSyncedDefinition {
        switch payload {
        case .providerPreset(let value):
            return .providerPreset(try AgentSyncedProviderPreset(
                id: value.id,
                revision: revision,
                name: value.name,
                providerID: value.providerID,
                model: value.model,
                endpointIdentity: value.endpointIdentity,
                reportsUsage: value.reportsUsage,
                supportsStreaming: value.supportsStreaming,
                requiresLocalProviderAccess: value.requiresLocalProviderAccess,
                createdAt: createdAt,
                updatedAt: updatedAt
            ))
        case .schedule(var value):
            value.revision = revision
            value.updatedAt = canonicalDate(updatedAt)
            try value.validate()
            return .schedule(value)
        case .userAuthoredMemory(let value):
            return .userAuthoredMemory(try AgentSyncedUserMemory(
                id: value.id,
                revision: revision,
                text: value.text,
                scope: value.scope,
                sessionScope: value.sessionScope,
                sensitivity: value.sensitivity,
                createdAt: createdAt,
                updatedAt: updatedAt,
                expiresAt: value.expiresAt,
                isEnabled: value.isEnabled
            ))
        }
    }

    private nonisolated static func canonicalDate(_ date: Date) -> Date {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
}

#if os(macOS) && canImport(CloudKit)
nonisolated struct AgentDefinitionResolvedLocalDependencies: Equatable, Sendable {
    var trustedMCPConnectionIDs: Set<UUID>
    var authorizedCoworkRootIDs: Set<UUID>
    var availableBrowserSessionIDs: Set<UUID>

    static let unavailable = AgentDefinitionResolvedLocalDependencies(
        trustedMCPConnectionIDs: [],
        authorizedCoworkRootIDs: [],
        availableBrowserSessionIDs: []
    )
}

/// Device-only dependency projection used by receiving-device activation.
/// Implementations must return only currently usable local resources; an
/// unknown or unreadable resource is intentionally reported as unavailable.
@MainActor
protocol AgentDefinitionLocalDependencyResolving: AnyObject {
    var changes: AnyPublisher<Void, Never> { get }
    func resolve() async -> AgentDefinitionResolvedLocalDependencies
    func authorizeCurrentCoworkRoot(for dependencyID: UUID) -> Bool
    func revokeCoworkRootAuthorization(for dependencyID: UUID)
}

/// Production adapter for the three dependency sets that cannot be learned
/// from the synced definition itself. Cowork bindings are explicit and local
/// only; the persisted value is a digest of the selected folder's filesystem
/// identity, never its path or security-scoped bookmark.
@MainActor
final class AgentDefinitionLiveDependencyResolver:
    AgentDefinitionLocalDependencyResolving
{
    static let shared = AgentDefinitionLiveDependencyResolver()

    private enum Key {
        static let coworkRootBindings =
            "agentDefinitionSync.localCoworkRootBindings"
    }

    private let defaults: UserDefaults
    private let changesSubject = PassthroughSubject<Void, Never>()
    private var subscriptions = Set<AnyCancellable>()
    private var browserSessionIDs = Set<UUID>()

    var changes: AnyPublisher<Void, Never> {
        changesSubject.eraseToAnyPublisher()
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        BrowserAgentMCPStore.shared.$connections
            .dropFirst()
            .sink { [weak self] _ in self?.changesSubject.send() }
            .store(in: &subscriptions)
        BrowserAgentWorkspace.shared.$rootURL
            .dropFirst()
            .sink { [weak self] _ in self?.changesSubject.send() }
            .store(in: &subscriptions)
    }

    func updateAvailableBrowserSessionIDs(_ ids: Set<UUID>) {
        guard ids != browserSessionIDs else { return }
        browserSessionIDs = ids
        changesSubject.send()
    }

    func currentAvailableBrowserSessionIDs() -> Set<UUID> {
        browserSessionIDs
    }

    func resolve() async -> AgentDefinitionResolvedLocalDependencies {
        AgentDefinitionResolvedLocalDependencies(
            trustedMCPConnectionIDs: await BrowserAgentMCPStore.shared
                .trustedLocallyAuthorizedConnectionIDs(),
            authorizedCoworkRootIDs: authorizedCoworkRootIDs(),
            availableBrowserSessionIDs: browserSessionIDs
        )
    }

    @discardableResult
    func authorizeCurrentCoworkRoot(for dependencyID: UUID) -> Bool {
        guard let identity = currentCoworkRootIdentity() else { return false }
        var bindings = coworkRootBindings
        bindings[dependencyID.uuidString.lowercased()] = identity
        defaults.set(bindings, forKey: Key.coworkRootBindings)
        changesSubject.send()
        return true
    }

    func revokeCoworkRootAuthorization(for dependencyID: UUID) {
        var bindings = coworkRootBindings
        guard bindings.removeValue(
            forKey: dependencyID.uuidString.lowercased()
        ) != nil else { return }
        defaults.set(bindings, forKey: Key.coworkRootBindings)
        changesSubject.send()
    }

    /// Resolves an opaque saved binding to the current policy target without
    /// persisting or syncing the folder path. A changed folder identity fails
    /// closed even if a different Cowork folder is currently selected.
    func coworkRootPolicyIdentity(for dependencyID: UUID) -> String? {
        guard let boundIdentity = coworkRootBindings[
            dependencyID.uuidString.lowercased()
        ],
        boundIdentity == currentCoworkRootIdentity(),
        let rootURL = BrowserAgentWorkspace.shared.rootURL else {
            return nil
        }
        return rootURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private var coworkRootBindings: [String: String] {
        defaults.dictionary(forKey: Key.coworkRootBindings) as? [String: String]
            ?? [:]
    }

    private func authorizedCoworkRootIDs() -> Set<UUID> {
        guard let identity = currentCoworkRootIdentity() else { return [] }
        return Set(coworkRootBindings.compactMap { rawID, boundIdentity in
            guard boundIdentity == identity else { return nil }
            return UUID(uuidString: rawID)
        })
    }

    private func currentCoworkRootIdentity() -> String? {
        guard let rootURL = BrowserAgentWorkspace.shared.rootURL else {
            return nil
        }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: root.path
        ),
        let systemNumber = attributes[.systemNumber] as? NSNumber,
        let fileNumber = attributes[.systemFileNumber] as? NSNumber else {
            return nil
        }
        let material = [
            "agent-cowork-root-v1",
            systemNumber.stringValue,
            fileNumber.stringValue,
            root.path,
        ].joined(separator: "|")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Main-actor product integration. Remote definitions are retained even when
/// unavailable; schedules become executable only after an explicit local
/// authorization and a successful receiving-device activation gate.
@MainActor
final class AgentDefinitionSyncService: ObservableObject {
    static let shared = AgentDefinitionSyncService()

    enum Key {
        static let authorizedScheduleIDs = "agentDefinitionSync.authorizedScheduleIDs"
        static let installedSyncedScheduleIDs = "agentDefinitionSync.installedScheduleIDs"
        static let approvedSensitiveMemoryRevisions =
            "agentDefinitionSync.approvedSensitiveMemoryRevisions"
        static let localProviderPresetID = "agentDefinitionSync.localProviderPresetID"
    }

    @Published private(set) var definitions: [AgentDefinitionSyncEnvelope] = []
    @Published private(set) var unavailableSchedules: [UUID: AgentDefinitionAvailability] = [:]
    @Published private(set) var locallyAuthorizedScheduleIDs: Set<UUID> = []
    @Published private(set) var locallyAuthorizedCoworkRootIDs: Set<UUID> = []
    @Published private(set) var sensitiveMemoryAwaitingReview: Set<UUID> = []
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isSyncing = false

    private let defaults: UserDefaults
    private let runtime: AgentDefinitionSyncRuntime
    private let dependencyResolver: any AgentDefinitionLocalDependencyResolving
    private let memoryController: AgentMemoryController
    private var scheduleInstaller: ((AgentTaskDefinition) async -> Void)?
    private var scheduleUninstaller: ((UUID) async -> Void)?
    private var dependencyChanges: AnyCancellable?
    private var started = false

    private static var isRunningUnderTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return ProcessInfo.processInfo.arguments.contains("-uiTesting")
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCInjectBundleInto"] != nil
    }

    init(
        defaults: UserDefaults = .standard,
        runtime: AgentDefinitionSyncRuntime = .shared,
        dependencyResolver: any AgentDefinitionLocalDependencyResolving =
            AgentDefinitionLiveDependencyResolver.shared,
        memoryController: AgentMemoryController = .shared
    ) {
        self.defaults = defaults
        self.runtime = runtime
        self.dependencyResolver = dependencyResolver
        self.memoryController = memoryController
        locallyAuthorizedScheduleIDs = Self.identifiers(
            defaults.stringArray(forKey: Key.authorizedScheduleIDs) ?? []
        )
        dependencyChanges = dependencyResolver.changes.sink { [weak self] in
            Task { @MainActor [weak self] in
                await self?.localDependenciesChanged()
            }
        }
    }

    func registerScheduleInstaller(
        _ installer: @escaping (AgentTaskDefinition) async -> Void,
        uninstaller: @escaping (UUID) async -> Void
    ) {
        scheduleInstaller = installer
        scheduleUninstaller = uninstaller
        guard !Self.isRunningUnderTests else { return }
        Task { await activateRetainedDefinitions() }
    }

    func start() async {
        guard !Self.isRunningUnderTests else { return }
        guard !started else { return }
        started = true
        await synchronize()
    }

    func preferencesChanged() async {
        await synchronize()
    }

    func localDependenciesChanged() async {
        await activateRetainedDefinitions()
    }

    @discardableResult
    func enable(_ category: AgentDefinitionSyncCategory) async -> Bool {
        guard !isSyncing else { return false }
        isSyncing = true
        defer { isSyncing = false }
        do {
            _ = try await runtime.setEnabled(true, category: category)
            try await synchronizeAfterMutation()
            lastError = nil
            return true
        } catch {
            lastError = String(String(describing: error).prefix(500))
            return false
        }
    }

    @discardableResult
    func disable(
        _ category: AgentDefinitionSyncCategory,
        disposition: AgentDefinitionSyncDisableDisposition
    ) async -> Bool {
        guard !isSyncing else { return false }
        isSyncing = true
        defer { isSyncing = false }
        do {
            _ = try await runtime.disable(category, disposition: disposition)
            try await synchronizeAfterMutation(publishLocal: false)
            lastError = nil
            return true
        } catch {
            lastError = String(String(describing: error).prefix(500))
            return false
        }
    }

    func synchronize() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await synchronizeAfterMutation()
            lastError = nil
        } catch {
            lastError = String(String(describing: error).prefix(500))
        }
    }

    func authorizeSchedule(_ id: UUID) async {
        var ids = authorizedScheduleIDs
        ids.insert(id)
        defaults.set(ids.map(\.uuidString).sorted(), forKey: Key.authorizedScheduleIDs)
        locallyAuthorizedScheduleIDs = ids
        await activateRetainedDefinitions()
    }

    func revokeScheduleAuthorization(_ id: UUID) async {
        var ids = authorizedScheduleIDs
        ids.remove(id)
        defaults.set(ids.map(\.uuidString).sorted(), forKey: Key.authorizedScheduleIDs)
        locallyAuthorizedScheduleIDs = ids
        await activateRetainedDefinitions()
    }

    @discardableResult
    func authorizeCurrentCoworkRoot(for scheduleID: UUID) async -> Bool {
        guard let dependencyID = coworkRootDependencyID(for: scheduleID),
              dependencyResolver.authorizeCurrentCoworkRoot(
                for: dependencyID
              ) else {
            return false
        }
        await activateRetainedDefinitions()
        return true
    }

    func revokeCoworkRootAuthorization(for scheduleID: UUID) async {
        guard let dependencyID = coworkRootDependencyID(for: scheduleID) else {
            return
        }
        dependencyResolver.revokeCoworkRootAuthorization(for: dependencyID)
        await activateRetainedDefinitions()
    }

    func approveSensitiveMemory(_ id: UUID) async {
        guard let envelope = definitions.first(where: { $0.definitionID == id }),
              case .userAuthoredMemory(let memory)? = envelope.payload else { return }
        do {
            try await memoryController.importSyncedUserMemory(
                memory,
                sensitiveApproved: true
            )
            var approvals = approvedSensitiveMemoryRevisions
            approvals[memory.id] = memory.revision
            approvedSensitiveMemoryRevisions = approvals
            sensitiveMemoryAwaitingReview.remove(id)
            lastError = nil
        } catch {
            lastError = String(String(describing: error).prefix(500))
        }
    }

    private var authorizedScheduleIDs: Set<UUID> {
        Self.identifiers(defaults.stringArray(forKey: Key.authorizedScheduleIDs) ?? [])
    }

    private var installedSyncedScheduleIDs: Set<UUID> {
        get {
            Self.identifiers(
                defaults.stringArray(forKey: Key.installedSyncedScheduleIDs) ?? []
            )
        }
        set {
            defaults.set(
                newValue.map(\.uuidString).sorted(),
                forKey: Key.installedSyncedScheduleIDs
            )
        }
    }

    private var approvedSensitiveMemoryRevisions: [UUID: Int] {
        get {
            guard let stored = defaults.dictionary(
                forKey: Key.approvedSensitiveMemoryRevisions
            ) else { return [:] }
            return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
                guard let id = UUID(uuidString: key),
                      let revision = value as? Int,
                      revision > 0 else { return nil }
                return (id, revision)
            })
        }
        set {
            defaults.set(
                Dictionary(uniqueKeysWithValues: newValue.map {
                    ($0.key.uuidString, $0.value)
                }),
                forKey: Key.approvedSensitiveMemoryRevisions
            )
        }
    }

    private static func identifiers(_ values: [String]) -> Set<UUID> {
        Set(values.compactMap(UUID.init(uuidString:)))
    }

    private func coworkRootDependencyID(for scheduleID: UUID) -> UUID? {
        for envelope in definitions {
            guard envelope.definitionID == scheduleID,
                  !envelope.isTombstone,
                  case .schedule(let schedule)? = envelope.payload else {
                continue
            }
            return schedule.requiredCoworkRootID
        }
        return nil
    }

    private func synchronizeAfterMutation(publishLocal: Bool = true) async throws {
        _ = try await runtime.refresh()
        if publishLocal { try await publishLocalDefinitions() }
        _ = try await runtime.refresh()
        let snapshot = await runtime.snapshot()
        definitions = snapshot.definitionsByRecordName.values.sorted {
            $0.recordName < $1.recordName
        }
        try await activate(snapshot)
        lastSyncAt = Date()
    }

    private func activateRetainedDefinitions() async {
        let snapshot = await runtime.snapshot()
        definitions = snapshot.definitionsByRecordName.values.sorted {
            $0.recordName < $1.recordName
        }
        do {
            try await activate(snapshot)
        } catch {
            lastError = String(String(describing: error).prefix(500))
        }
    }

    func activate(_ snapshot: AgentDefinitionSyncRuntimeSnapshot) async throws {
        let presets = Dictionary(uniqueKeysWithValues: snapshot.definitionsByRecordName.values
            .compactMap { envelope -> (UUID, AgentSyncedProviderPreset)? in
                guard !envelope.isTombstone,
                      case .providerPreset(let value)? = envelope.payload else { return nil }
                return (value.id, value)
            })
        var unavailable: [UUID: AgentDefinitionAvailability] = [:]
        var awaitingSensitiveReview: Set<UUID> = []
        var runnableScheduleIDs: Set<UUID> = []
        let authorized = authorizedScheduleIDs
        let localDependencies = await dependencyResolver.resolve()
        var sensitiveApprovals = approvedSensitiveMemoryRevisions
        for envelope in snapshot.definitionsByRecordName.values.sorted(by: {
            $0.recordName < $1.recordName
        }) {
            if envelope.category == .userAuthoredMemory,
               snapshot.preferences.userAuthoredMemory {
                if envelope.isTombstone {
                    try await memoryController.deactivateSyncedUserMemory(
                        id: envelope.definitionID
                    )
                    sensitiveApprovals.removeValue(
                        forKey: envelope.definitionID
                    )
                    continue
                }
                guard case .userAuthoredMemory(let memory)? = envelope.payload else {
                    continue
                }
                if memory.sensitivity == .sensitive,
                   sensitiveApprovals[memory.id] != memory.revision {
                    awaitingSensitiveReview.insert(memory.id)
                    // An update which raises sensitivity must stop an older
                    // non-sensitive local copy from being consumed before the
                    // user reviews the new value.
                    await memoryController.setEnabled(
                        id: memory.id,
                        enabled: false
                    )
                } else {
                    try await memoryController.importSyncedUserMemory(
                        memory,
                        sensitiveApproved: memory.sensitivity == .sensitive
                    )
                }
                continue
            }
            guard case .schedule(let schedule)? = envelope.payload else { continue }
            let locallyAuthorized = authorized.contains(schedule.id)
            let device = deviceCapabilities(
                snapshot: snapshot,
                presets: presets,
                schedule: schedule,
                locallyAuthorized: locallyAuthorized,
                localDependencies: localDependencies
            )
            switch try AgentDefinitionActivationGate.evaluate(
                envelope,
                providerPresets: presets,
                preferences: snapshot.preferences,
                device: device
            ) {
            case .unavailable(let availability):
                unavailable[schedule.id] = availability
            case .runnable(let permit):
                guard let preset = presets[schedule.providerPresetID] else { continue }
                let definition = try AgentDefinitionActivationGate.materialize(
                    envelope,
                    providerPreset: preset,
                    permit: permit
                )
                await scheduleInstaller?(definition)
                if scheduleInstaller != nil { runnableScheduleIDs.insert(schedule.id) }
            }
        }
        // Startup sync may complete before the scheduler bridge registers.
        // Preserve the durable installed set until both sides of the lifecycle
        // are available, otherwise a startup tombstone could be forgotten
        // before it gets a chance to uninstall last launch's task.
        if scheduleInstaller != nil, scheduleUninstaller != nil {
            let noLongerRunnable = installedSyncedScheduleIDs
                .subtracting(runnableScheduleIDs)
            for id in noLongerRunnable.sorted(by: { $0.uuidString < $1.uuidString }) {
                await scheduleUninstaller?(id)
            }
            installedSyncedScheduleIDs = runnableScheduleIDs
        }
        unavailableSchedules = unavailable
        sensitiveMemoryAwaitingReview = awaitingSensitiveReview
        locallyAuthorizedScheduleIDs = authorized
        locallyAuthorizedCoworkRootIDs = localDependencies.authorizedCoworkRootIDs
        approvedSensitiveMemoryRevisions = sensitiveApprovals
    }

    private func deviceCapabilities(
        snapshot: AgentDefinitionSyncRuntimeSnapshot,
        presets: [UUID: AgentSyncedProviderPreset],
        schedule: AgentSyncedScheduleDefinition,
        locallyAuthorized: Bool,
        localDependencies: AgentDefinitionResolvedLocalDependencies
    ) -> AgentDefinitionDeviceCapabilities {
        let localAccess = Set(presets.values.compactMap { preset -> UUID? in
            guard let provider = BrowserAgentProvider(rawValue: preset.providerID) else {
                return nil
            }
            return !provider.needsAPIKey || !BrowserAgentKeychain.read(provider: provider).isEmpty
                ? preset.id : nil
        })
        return AgentDefinitionDeviceCapabilities(
            deviceID: snapshot.deviceID,
            platform: .macOS,
            installedProviderPresetIDs: Set(presets.keys),
            providerPresetIDsWithLocalAccess: localAccess,
            trustedMCPConnectionIDs: localDependencies.trustedMCPConnectionIDs,
            authorizedCoworkRootIDs: localDependencies.authorizedCoworkRootIDs,
            availableBrowserSessionIDs: localDependencies.availableBrowserSessionIDs,
            supportedCapabilities: Set(AgentCapability.allCases),
            policyGrantedScheduledCapabilities: locallyAuthorized
                ? schedule.requiredCapabilities : [],
            scheduledExecutionPolicySatisfied: locallyAuthorized
        )
    }

    private func publishLocalDefinitions() async throws {
        let preferences = AgentDefinitionSyncSettings.preferences(from: defaults)
        let presetID = localProviderPresetID
        let provider = BrowserAgentProvider(
            rawValue: defaults.string(forKey: AgentSettingsRuntimeKey.provider)
                ?? BrowserAgentProvider.openRouter.rawValue
        ) ?? .openRouter
        let savedModel = defaults.string(forKey: AgentSettingsRuntimeKey.model) ?? ""
        let savedEndpoint = defaults.string(forKey: AgentSettingsRuntimeKey.endpoint) ?? ""
        let model = savedModel.isEmpty ? provider.defaultModel : savedModel
        let providerPreset = try AgentSyncedProviderPreset(
            id: presetID,
            name: "Current \(provider.rawValue) provider",
            providerID: provider.rawValue,
            model: model,
            endpointIdentity: provider.endpointIdentity(
                customEndpoint: savedEndpoint,
                model: model
            ),
            reportsUsage: true,
            supportsStreaming: true,
            requiresLocalProviderAccess: provider.needsAPIKey
        )
        if preferences.providerPresets {
            _ = try await runtime.publishLocalPayload(.providerPreset(providerPreset))
        }
        if preferences.schedules {
            let importedScheduleIDs = installedSyncedScheduleIDs
            for definition in BrowserAgentScheduler.shared.tasks
                where !importedScheduleIDs.contains(definition.id)
            {
                let synced = try AgentSyncedScheduleDefinition(
                    definition: definition,
                    providerPresetID: presetID
                )
                _ = try await runtime.publishLocalPayload(.schedule(synced))
            }
        }
        if preferences.userAuthoredMemory {
            await memoryController.refresh()
            for entry in memoryController.entries
                where entry.provenance.kind == .user {
                guard let synced = try? AgentSyncedUserMemory(entry: entry, revision: 1) else {
                    continue
                }
                _ = try await runtime.publishLocalPayload(.userAuthoredMemory(synced))
            }
        }
    }

    private var localProviderPresetID: UUID {
        if let raw = defaults.string(forKey: Key.localProviderPresetID),
           let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: Key.localProviderPresetID)
        return id
    }
}
#endif
