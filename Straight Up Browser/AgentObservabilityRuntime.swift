import Combine
import Foundation

nonisolated enum AgentObservabilitySettings {
    enum Key {
        static let maximumTurns = "agent.budget.maximumTurns"
        static let maximumToolCalls = "agent.budget.maximumToolCalls"
        static let maximumWallMinutes = "agent.budget.maximumWallMinutes"
        static let maximumProviderTokens = "agent.budget.maximumProviderTokens"
        static let maximumProviderCostMicrounits = "agent.budget.maximumProviderCostMicrounits"
        static let maximumOpenPages = "agent.budget.maximumOpenPages"
        static let maximumModelResultMiB = "agent.budget.maximumModelResultMiB"
        static let maximumDownloads = "agent.budget.maximumDownloads"
        static let maximumDownloadMiB = "agent.budget.maximumDownloadMiB"
        static let maximumArtifacts = "agent.budget.maximumArtifacts"
        static let maximumArtifactMiB = "agent.budget.maximumArtifactMiB"
        static let localMetricsEnabled = "agent.observability.localMetricsEnabled"
        static let metricRetentionDays = "agent.observability.metricRetentionDays"
    }

    static func executionLimits(
        defaults: UserDefaults = .standard
    ) -> AgentExecutionLimits {
        let baseline = AgentExecutionLimits.defaults
        func integer(_ key: String, default fallback: Int, range: ClosedRange<Int>) -> Int {
            guard defaults.object(forKey: key) != nil else { return fallback }
            return min(max(defaults.integer(forKey: key), range.lowerBound), range.upperBound)
        }
        func optionalInt64(_ key: String) -> Int64? {
            guard defaults.object(forKey: key) != nil else { return nil }
            guard let number = defaults.object(forKey: key) as? NSNumber else { return nil }
            let value = number.int64Value
            return value > 0 ? value : nil
        }
        return (try? AgentExecutionLimits(
            maximumTurns: integer(
                Key.maximumTurns,
                default: baseline.maximumTurns,
                range: 1...256
            ),
            maximumToolCalls: integer(
                Key.maximumToolCalls,
                default: baseline.maximumToolCalls,
                range: 0...2_048
            ),
            maximumElapsedMilliseconds: Int64(integer(
                Key.maximumWallMinutes,
                default: Int(baseline.maximumElapsedMilliseconds / 60_000),
                range: 1...1_440
            )) * 60_000,
            maximumProviderTokens: optionalInt64(Key.maximumProviderTokens),
            maximumProviderCostMicrounits: optionalInt64(Key.maximumProviderCostMicrounits),
            maximumOpenPages: integer(
                Key.maximumOpenPages,
                default: baseline.maximumOpenPages,
                range: 0...64
            ),
            maximumModelResultBytes: Int64(integer(
                Key.maximumModelResultMiB,
                default: Int(baseline.maximumModelResultBytes / 1_048_576),
                range: 1...256
            )) * 1_048_576,
            maximumDownloads: integer(
                Key.maximumDownloads,
                default: baseline.maximumDownloads,
                range: 0...512
            ),
            maximumDownloadBytes: Int64(integer(
                Key.maximumDownloadMiB,
                default: Int(baseline.maximumDownloadBytes / 1_048_576),
                range: 0...16_384
            )) * 1_048_576,
            maximumArtifacts: integer(
                Key.maximumArtifacts,
                default: baseline.maximumArtifacts,
                range: 0...2_048
            ),
            maximumArtifactBytes: Int64(integer(
                Key.maximumArtifactMiB,
                default: Int(baseline.maximumArtifactBytes / 1_048_576),
                range: 0...16_384
            )) * 1_048_576
        )) ?? baseline
    }

    static func localMetricsEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.localMetricsEnabled) == nil
            ? true : defaults.bool(forKey: Key.localMetricsEnabled)
    }

    static func metricRetention(
        defaults: UserDefaults = .standard
    ) -> AgentMetricRetentionPolicy {
        let days = defaults.object(forKey: Key.metricRetentionDays) == nil
            ? 30 : min(max(defaults.integer(forKey: Key.metricRetentionDays), 1), 365)
        return (try? AgentMetricRetentionPolicy(maximumAge: Double(days) * 86_400))
            ?? (try! AgentMetricRetentionPolicy())
    }
}

actor AgentObservabilityRuntime {
    static let shared = AgentObservabilityRuntime()

    private let snapshotURL: URL
    private let defaults: UserDefaults
    private var metricStore: AgentLocalMetricStore

    init(
        baseDirectory: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Straight Up Browser", isDirectory: true),
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        snapshotURL = baseDirectory
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("observability", isDirectory: true)
            .appendingPathComponent("metrics-v1.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: snapshotURL),
           let snapshot = try? decoder.decode(AgentLocalMetricSnapshot.self, from: data),
           let restored = try? AgentLocalMetricStore(restoring: snapshot) {
            metricStore = restored
            Self.purgeLegacyIncognitoSnapshotIfNeeded(
                snapshot,
                restoredStore: restored,
                at: snapshotURL
            )
        } else {
            metricStore = AgentLocalMetricStore(
                retention: AgentObservabilitySettings.metricRetention(defaults: defaults),
                remoteDiagnosticsSettings: AgentRemoteDiagnosticsSettings(
                    localMetricsEnabled: AgentObservabilitySettings.localMetricsEnabled(
                        defaults: defaults
                    ),
                    remoteDiagnosticsEnabled: false,
                    remoteErrorReportsEnabled: false
                )
            )
        }
    }

    /// Constructs the defaults object inside the actor initializer so tests do
    /// not transfer a non-Sendable `UserDefaults` reference across isolation.
    init(baseDirectory: URL, defaultsSuiteName: String) {
        let suiteDefaults = UserDefaults(suiteName: defaultsSuiteName) ?? .standard
        defaults = suiteDefaults
        snapshotURL = baseDirectory
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("observability", isDirectory: true)
            .appendingPathComponent("metrics-v1.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: snapshotURL),
           let snapshot = try? decoder.decode(AgentLocalMetricSnapshot.self, from: data),
           let restored = try? AgentLocalMetricStore(restoring: snapshot) {
            metricStore = restored
            Self.purgeLegacyIncognitoSnapshotIfNeeded(
                snapshot,
                restoredStore: restored,
                at: snapshotURL
            )
        } else {
            metricStore = AgentLocalMetricStore(
                retention: AgentObservabilitySettings.metricRetention(defaults: suiteDefaults),
                remoteDiagnosticsSettings: AgentRemoteDiagnosticsSettings(
                    localMetricsEnabled: AgentObservabilitySettings.localMetricsEnabled(
                        defaults: suiteDefaults
                    ),
                    remoteDiagnosticsEnabled: false,
                    remoteErrorReportsEnabled: false
                )
            )
        }
    }

    func record(_ event: AgentMetricEvent) async {
        do {
            _ = try await metricStore.record(event)
            try await persist()
        } catch {
            // Observability must never break the run it observes.
        }
    }

    func dashboard() async -> AgentObservabilityDashboard {
        await metricStore.dashboard()
    }

    func events() async -> [AgentMetricEvent] {
        await metricStore.events()
    }

    func settingsChanged() async {
        await metricStore.updateRetention(
            AgentObservabilitySettings.metricRetention(defaults: defaults)
        )
        await metricStore.updateRemoteDiagnosticsSettings(
            AgentRemoteDiagnosticsSettings(
                localMetricsEnabled: AgentObservabilitySettings.localMetricsEnabled(
                    defaults: defaults
                ),
                remoteDiagnosticsEnabled: false,
                remoteErrorReportsEnabled: false
            )
        )
        try? await persist()
    }

    func clearLocalMetrics() async {
        await metricStore.updateRemoteDiagnosticsSettings(.init(
            localMetricsEnabled: false,
            remoteDiagnosticsEnabled: false,
            remoteErrorReportsEnabled: false
        ))
        await metricStore.updateRemoteDiagnosticsSettings(.init(
            localMetricsEnabled: AgentObservabilitySettings.localMetricsEnabled(
                defaults: defaults
            ),
            remoteDiagnosticsEnabled: false,
            remoteErrorReportsEnabled: false
        ))
        try? await persist()
    }

    private func persist() async throws {
        let snapshot = await metricStore.snapshot()
        try Self.persist(snapshot, at: snapshotURL)
    }

    /// Builds before 2.0 admitted Incognito events and only filtered them from
    /// export. Rewrite that legacy file as soon as it is restored so private
    /// metrics do not linger on disk until another run happens to record data.
    private nonisolated static func purgeLegacyIncognitoSnapshotIfNeeded(
        _ snapshot: AgentLocalMetricSnapshot,
        restoredStore: AgentLocalMetricStore,
        at url: URL
    ) {
        guard snapshot.events.contains(where: \.incognito) else { return }
        Task.detached(priority: .utility) {
            let sanitized = await restoredStore.snapshot(now: snapshot.capturedAt)
            try? Self.persist(sanitized, at: url)
        }
    }

    private nonisolated static func persist(
        _ snapshot: AgentLocalMetricSnapshot,
        at url: URL
    ) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(
            to: url,
            options: [.atomic, .completeFileProtection]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

private nonisolated final class WeakAgentRunMeterReference: @unchecked Sendable {
    weak var value: AgentRunMeter?

    init(_ value: AgentRunMeter) {
        self.value = value
    }
}

/// Replay capture runs at the browser executor boundary, while the owning
/// meter lives with the root/child/local-MCP runtime. This weak registry joins
/// those layers by durable Run ID without extending a Run's lifetime.
actor AgentRunMeterRegistry {
    static let shared = AgentRunMeterRegistry()

    private var references: [UUID: WeakAgentRunMeterReference] = [:]

    func register(_ meter: AgentRunMeter, for runID: UUID) {
        references = references.filter { $0.value.value != nil }
        references[runID] = WeakAgentRunMeterReference(meter)
    }

    func meter(for runID: UUID) -> AgentRunMeter? {
        guard let meter = references[runID]?.value else {
            references.removeValue(forKey: runID)
            return nil
        }
        return meter
    }
}

actor AgentRunMeter {
    nonisolated let runID: UUID
    nonisolated let limits: AgentExecutionLimits
    private let incognito: Bool
    private let ledger: AgentBudgetLedger
    private let observability: AgentObservabilityRuntime

    init(
        runID: UUID,
        taskDefinitionID: UUID?,
        incognito: Bool,
        limits: AgentExecutionLimits = AgentObservabilitySettings.executionLimits(),
        observability: AgentObservabilityRuntime = .shared,
        startedAt: Date = Date()
    ) {
        self.runID = runID
        self.incognito = incognito
        self.limits = limits
        self.observability = observability
        ledger = AgentBudgetLedger(
            rootRunID: runID,
            sharedScope: taskDefinitionID.map(AgentBudgetLimitScope.taskDefinition)
                ?? .run(runID),
            sharedLimits: limits,
            startedAt: startedAt
        )
    }

    func admitTurn(at date: Date = Date()) async -> AgentBudgetAdmission {
        await admitTurn(runID: runID, at: date)
    }

    func admitTurn(
        runID: UUID,
        at date: Date = Date()
    ) async -> AgentBudgetAdmission {
        await admit(runID: runID, try! AgentOperationCharge(turns: 1), at: date)
    }

    func admitToolCall(at date: Date = Date()) async -> AgentBudgetAdmission {
        await admitToolCall(runID: runID, at: date)
    }

    func admitToolCall(
        runID: UUID,
        at date: Date = Date()
    ) async -> AgentBudgetAdmission {
        await admit(runID: runID, try! AgentOperationCharge(toolCalls: 1), at: date)
    }

    func admitModelResult(bytes: Int, at date: Date = Date()) async -> AgentBudgetAdmission {
        await admitModelResult(runID: runID, bytes: bytes, at: date)
    }

    func admitModelResult(
        runID: UUID,
        bytes: Int,
        at date: Date = Date()
    ) async -> AgentBudgetAdmission {
        await admit(
            runID: runID,
            try! AgentOperationCharge(modelResultBytes: Int64(max(0, bytes))),
            at: date
        )
    }

    func admitArtifact(bytes: Int, at date: Date = Date()) async -> AgentBudgetAdmission {
        await admitArtifact(runID: runID, bytes: bytes, at: date)
    }

    func admitArtifact(
        runID: UUID,
        bytes: Int,
        at date: Date = Date()
    ) async -> AgentBudgetAdmission {
        await admit(runID: runID, try! AgentOperationCharge(
            artifacts: 1,
            artifactBytes: Int64(max(0, bytes))
        ), at: date)
    }

    func admitPage(
        runID: UUID,
        at date: Date = Date()
    ) async -> AgentBudgetAdmission {
        await admit(
            runID: runID,
            try! AgentOperationCharge(pageDelta: 1),
            at: date
        )
    }

    func releasePage(
        runID: UUID,
        at date: Date = Date()
    ) async -> AgentBudgetAdmission {
        await admit(
            runID: runID,
            try! AgentOperationCharge(pageDelta: -1),
            at: date
        )
    }

    func admitDownload(
        runID: UUID,
        reservedBytes: Int64,
        at date: Date = Date()
    ) async -> AgentBudgetAdmission {
        await admit(
            runID: runID,
            try! AgentOperationCharge(
                downloads: 1,
                downloadBytes: max(0, reservedBytes)
            ),
            at: date
        )
    }

    func registerChild(
        runID: UUID,
        parentRunID: UUID,
        limits: AgentExecutionLimits,
        startedAt: Date = Date()
    ) async throws {
        try await ledger.registerRun(
            runID: runID,
            parentRunID: parentRunID,
            limits: limits,
            startedAt: startedAt
        )
    }

    func recordProviderUsage(
        runID: UUID? = nil,
        providerID: String,
        model: String,
        requestID: String,
        usageStepID: UUID?,
        usage: AgentModelUsage,
        pricing: AgentProviderPricingMetadata? = nil,
        at date: Date = Date()
    ) async -> AgentProviderUsageAccounting {
        let measuredRunID = runID ?? self.runID
        let accounting = await ledger.recordProviderUsage(
            runID: measuredRunID,
            providerID: providerID,
            model: model,
            requestID: requestID,
            usageStepID: usageStepID,
            usage: usage,
            pricing: pricing,
            at: date
        )
        await observability.record(.providerUsage(accounting.link, incognito: incognito))
        if case .limited(let limit) = accounting.admission {
            await recordLimit(limit)
        }
        return accounting
    }

    func recordProviderLatency(
        runID: UUID? = nil,
        milliseconds: Int64,
        providerID: String,
        timeToFirstTokenMilliseconds: Int64?
    ) async {
        let measuredRunID = runID ?? self.runID
        await observability.record(.providerLatency(
            runID: measuredRunID,
            milliseconds: max(0, milliseconds),
            providerID: providerID,
            incognito: incognito
        ))
        if let timeToFirstTokenMilliseconds {
            await observability.record(.timeToFirstToken(
                runID: measuredRunID,
                milliseconds: max(0, timeToFirstTokenMilliseconds),
                providerID: providerID,
                incognito: incognito
            ))
        }
    }

    func recordToolLatency(
        runID: UUID? = nil,
        milliseconds: Int64,
        toolName: String,
        outcome: AgentToolMetricOutcome
    ) async {
        let measuredRunID = runID ?? self.runID
        await observability.record(.toolLatency(
            runID: measuredRunID,
            milliseconds: max(0, milliseconds),
            toolName: toolName,
            outcome: outcome,
            incognito: incognito
        ))
    }

    func cancel(reason: String = "user requested stop") async {
        _ = try? await ledger.cancel(runID: runID, reason: reason)
    }

    func cancel(
        runID: UUID,
        reason: String = "user requested stop",
        propagateToDescendants: Bool = true
    ) async {
        _ = try? await ledger.cancel(
            runID: runID,
            reason: reason,
            propagateToDescendants: propagateToDescendants
        )
    }

    func snapshot() async -> AgentBudgetLedgerSnapshot {
        await ledger.snapshot()
    }

    private func admit(
        runID: UUID,
        _ charge: AgentOperationCharge,
        at date: Date
    ) async -> AgentBudgetAdmission {
        // Tool admission always precedes executor-side replay capture, so this
        // registers root, child, scheduled, and local-MCP Runs before a frame
        // can reserve artifact count or bytes.
        await AgentRunMeterRegistry.shared.register(self, for: runID)
        let admission = await ledger.admit(runID: runID, charge: charge, at: date)
        if case .limited(let limit) = admission {
            await recordLimit(limit)
        } else if case .admitted(let receipt) = admission {
            let peaks: [(AgentBudgetDimension, Int64)] = [
                (.turns, receipt.sharedUsage.turns),
                (.toolCalls, receipt.sharedUsage.toolCalls),
                (.openPages, receipt.sharedUsage.peakOpenPages),
                (.modelResultBytes, receipt.sharedUsage.modelResultBytes),
                (.downloads, receipt.sharedUsage.downloads),
                (.downloadBytes, receipt.sharedUsage.downloadBytes),
                (.artifacts, receipt.sharedUsage.artifacts),
                (.artifactBytes, receipt.sharedUsage.artifactBytes),
            ]
            for (dimension, value) in peaks where value > 0 {
                await observability.record(.resourcePeak(
                    runID: runID,
                    resource: dimension,
                    value: value,
                    incognito: incognito
                ))
            }
        }
        return admission
    }

    private func recordLimit(_ limit: AgentLimitResult) async {
        await observability.record(AgentMetricEvent(
            runID: limit.runID,
            incognito: incognito,
            payload: .limit(dimension: limit.dimension, reason: limit.reason)
        ))
    }
}

@MainActor
final class AgentObservabilityController: ObservableObject {
    static let shared = AgentObservabilityController()

    @Published private(set) var dashboard: AgentObservabilityDashboard?
    @Published private(set) var eventCount = 0

    private init() {
        Task { await refresh() }
    }

    func refresh() async {
        dashboard = await AgentObservabilityRuntime.shared.dashboard()
        eventCount = await AgentObservabilityRuntime.shared.events().count
    }

    func settingsChanged() async {
        await AgentObservabilityRuntime.shared.settingsChanged()
        await refresh()
    }

    func clear() async {
        await AgentObservabilityRuntime.shared.clearLocalMetrics()
        await refresh()
    }
}
