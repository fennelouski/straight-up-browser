import CryptoKit
import Foundation

// MARK: - Hard execution budgets

/// Every effectful executor operation must be admitted here before it starts.
/// Provider usage, which is only known after a response, is reconciled through
/// `recordProviderUsage`; a finite unmeasurable budget fails closed before a
/// subsequent operation can run.
nonisolated enum AgentExecutionLimitError: Error, Equatable, Sendable {
    case invalidLimit(String)
    case invalidCharge(String)
    case arithmeticOverflow(AgentBudgetDimension)
    case unknownRun(UUID)
    case duplicateRun(UUID)
    case unknownParent(UUID)
    case limitEscalation(AgentBudgetDimension)
    case invalidRecoverySnapshot
}

nonisolated enum AgentBudgetDimension: String, Codable, CaseIterable, Equatable, Sendable {
    case turns
    case toolCalls
    case elapsedTime
    case providerTokens
    case providerCost
    case openPages
    case modelResultBytes
    case downloads
    case downloadBytes
    case artifacts
    case artifactBytes
}

nonisolated struct AgentExecutionLimits: Codable, Equatable, Sendable {
    static let defaults = try! AgentExecutionLimits()

    let maximumTurns: Int
    let maximumToolCalls: Int
    let maximumElapsedMilliseconds: Int64
    let maximumProviderTokens: Int64?
    let maximumProviderCostMicrounits: Int64?
    let maximumOpenPages: Int
    let maximumModelResultBytes: Int64
    let maximumDownloads: Int
    let maximumDownloadBytes: Int64
    let maximumArtifacts: Int
    let maximumArtifactBytes: Int64

    init(
        maximumTurns: Int = 32,
        maximumToolCalls: Int = 128,
        maximumElapsedMilliseconds: Int64 = 30 * 60 * 1_000,
        maximumProviderTokens: Int64? = nil,
        maximumProviderCostMicrounits: Int64? = nil,
        maximumOpenPages: Int = 8,
        maximumModelResultBytes: Int64 = 16 * 1_024 * 1_024,
        maximumDownloads: Int = 32,
        maximumDownloadBytes: Int64 = 2 * 1_024 * 1_024 * 1_024,
        maximumArtifacts: Int = 128,
        maximumArtifactBytes: Int64 = 1_024 * 1_024 * 1_024
    ) throws {
        guard maximumTurns > 0 else {
            throw AgentExecutionLimitError.invalidLimit("turns")
        }
        guard maximumToolCalls >= 0 else {
            throw AgentExecutionLimitError.invalidLimit("toolCalls")
        }
        guard maximumElapsedMilliseconds > 0 else {
            throw AgentExecutionLimitError.invalidLimit("elapsedTime")
        }
        guard maximumProviderTokens.map({ $0 >= 0 }) ?? true else {
            throw AgentExecutionLimitError.invalidLimit("providerTokens")
        }
        guard maximumProviderCostMicrounits.map({ $0 >= 0 }) ?? true else {
            throw AgentExecutionLimitError.invalidLimit("providerCost")
        }
        guard maximumOpenPages >= 0 else {
            throw AgentExecutionLimitError.invalidLimit("openPages")
        }
        guard maximumModelResultBytes >= 0 else {
            throw AgentExecutionLimitError.invalidLimit("modelResultBytes")
        }
        guard maximumDownloads >= 0 else {
            throw AgentExecutionLimitError.invalidLimit("downloads")
        }
        guard maximumDownloadBytes >= 0 else {
            throw AgentExecutionLimitError.invalidLimit("downloadBytes")
        }
        guard maximumArtifacts >= 0 else {
            throw AgentExecutionLimitError.invalidLimit("artifacts")
        }
        guard maximumArtifactBytes >= 0 else {
            throw AgentExecutionLimitError.invalidLimit("artifactBytes")
        }
        self.maximumTurns = maximumTurns
        self.maximumToolCalls = maximumToolCalls
        self.maximumElapsedMilliseconds = maximumElapsedMilliseconds
        self.maximumProviderTokens = maximumProviderTokens
        self.maximumProviderCostMicrounits = maximumProviderCostMicrounits
        self.maximumOpenPages = maximumOpenPages
        self.maximumModelResultBytes = maximumModelResultBytes
        self.maximumDownloads = maximumDownloads
        self.maximumDownloadBytes = maximumDownloadBytes
        self.maximumArtifacts = maximumArtifacts
        self.maximumArtifactBytes = maximumArtifactBytes
    }

    func validateSubset(of parent: Self) throws {
        for dimension in AgentBudgetDimension.allCases {
            guard isNoGreater(than: parent, dimension: dimension) else {
                throw AgentExecutionLimitError.limitEscalation(dimension)
            }
        }
    }

    func maximum(for dimension: AgentBudgetDimension) -> Int64? {
        switch dimension {
        case .turns: Int64(maximumTurns)
        case .toolCalls: Int64(maximumToolCalls)
        case .elapsedTime: maximumElapsedMilliseconds
        case .providerTokens: maximumProviderTokens
        case .providerCost: maximumProviderCostMicrounits
        case .openPages: Int64(maximumOpenPages)
        case .modelResultBytes: maximumModelResultBytes
        case .downloads: Int64(maximumDownloads)
        case .downloadBytes: maximumDownloadBytes
        case .artifacts: Int64(maximumArtifacts)
        case .artifactBytes: maximumArtifactBytes
        }
    }

    private func isNoGreater(than parent: Self, dimension: AgentBudgetDimension) -> Bool {
        let child = maximum(for: dimension)
        let parent = parent.maximum(for: dimension)
        return switch (child, parent) {
        case (_, nil): true
        case (nil, .some): false
        case let (.some(child), .some(parent)): child <= parent
        }
    }
}

nonisolated struct AgentOperationCharge: Codable, Equatable, Sendable {
    let turns: Int64
    let toolCalls: Int64
    let providerTokens: Int64
    let providerCostMicrounits: Int64
    let pageDelta: Int64
    let modelResultBytes: Int64
    let downloads: Int64
    let downloadBytes: Int64
    let artifacts: Int64
    let artifactBytes: Int64

    init(
        turns: Int = 0,
        toolCalls: Int = 0,
        providerTokens: Int64 = 0,
        providerCostMicrounits: Int64 = 0,
        pageDelta: Int = 0,
        modelResultBytes: Int64 = 0,
        downloads: Int = 0,
        downloadBytes: Int64 = 0,
        artifacts: Int = 0,
        artifactBytes: Int64 = 0
    ) throws {
        guard turns >= 0 else { throw AgentExecutionLimitError.invalidCharge("turns") }
        guard toolCalls >= 0 else { throw AgentExecutionLimitError.invalidCharge("toolCalls") }
        guard providerTokens >= 0 else {
            throw AgentExecutionLimitError.invalidCharge("providerTokens")
        }
        guard providerCostMicrounits >= 0 else {
            throw AgentExecutionLimitError.invalidCharge("providerCost")
        }
        guard modelResultBytes >= 0 else {
            throw AgentExecutionLimitError.invalidCharge("modelResultBytes")
        }
        guard downloads >= 0 else {
            throw AgentExecutionLimitError.invalidCharge("downloads")
        }
        guard downloadBytes >= 0 else {
            throw AgentExecutionLimitError.invalidCharge("downloadBytes")
        }
        guard artifacts >= 0 else {
            throw AgentExecutionLimitError.invalidCharge("artifacts")
        }
        guard artifactBytes >= 0 else {
            throw AgentExecutionLimitError.invalidCharge("artifactBytes")
        }
        self.turns = Int64(turns)
        self.toolCalls = Int64(toolCalls)
        self.providerTokens = providerTokens
        self.providerCostMicrounits = providerCostMicrounits
        self.pageDelta = Int64(pageDelta)
        self.modelResultBytes = modelResultBytes
        self.downloads = Int64(downloads)
        self.downloadBytes = downloadBytes
        self.artifacts = Int64(artifacts)
        self.artifactBytes = artifactBytes
    }
}

nonisolated struct AgentExecutionUsage: Codable, Equatable, Sendable {
    var turns: Int64 = 0
    var toolCalls: Int64 = 0
    var providerTokens: Int64 = 0
    var providerCostMicrounits: Int64 = 0
    var openPages: Int64 = 0
    var peakOpenPages: Int64 = 0
    var modelResultBytes: Int64 = 0
    var downloads: Int64 = 0
    var downloadBytes: Int64 = 0
    var artifacts: Int64 = 0
    var artifactBytes: Int64 = 0
    var providerTokensKnown: Bool = true
    var providerCostKnown: Bool = true

    func value(for dimension: AgentBudgetDimension, elapsedMilliseconds: Int64) -> Int64 {
        switch dimension {
        case .turns: turns
        case .toolCalls: toolCalls
        case .elapsedTime: elapsedMilliseconds
        case .providerTokens: providerTokens
        case .providerCost: providerCostMicrounits
        case .openPages: openPages
        case .modelResultBytes: modelResultBytes
        case .downloads: downloads
        case .downloadBytes: downloadBytes
        case .artifacts: artifacts
        case .artifactBytes: artifactBytes
        }
    }

    fileprivate func adding(_ charge: AgentOperationCharge) throws -> Self {
        var result = self
        result.turns = try Self.add(turns, charge.turns, .turns)
        result.toolCalls = try Self.add(toolCalls, charge.toolCalls, .toolCalls)
        result.providerTokens = try Self.add(providerTokens, charge.providerTokens, .providerTokens)
        result.providerCostMicrounits = try Self.add(
            providerCostMicrounits,
            charge.providerCostMicrounits,
            .providerCost
        )
        result.openPages = try Self.add(openPages, charge.pageDelta, .openPages)
        guard result.openPages >= 0 else {
            throw AgentExecutionLimitError.invalidCharge("pageDelta")
        }
        result.peakOpenPages = max(peakOpenPages, result.openPages)
        result.modelResultBytes = try Self.add(
            modelResultBytes,
            charge.modelResultBytes,
            .modelResultBytes
        )
        result.downloads = try Self.add(downloads, charge.downloads, .downloads)
        result.downloadBytes = try Self.add(downloadBytes, charge.downloadBytes, .downloadBytes)
        result.artifacts = try Self.add(artifacts, charge.artifacts, .artifacts)
        result.artifactBytes = try Self.add(artifactBytes, charge.artifactBytes, .artifactBytes)
        return result
    }

    fileprivate static func add(
        _ lhs: Int64,
        _ rhs: Int64,
        _ dimension: AgentBudgetDimension
    ) throws -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw AgentExecutionLimitError.arithmeticOverflow(dimension) }
        return result
    }
}

nonisolated enum AgentBudgetLimitScope: Codable, Equatable, Hashable, Sendable {
    case run(UUID)
    case taskDefinition(UUID)
    case runGroup(UUID)
}

nonisolated enum AgentLimitReason: String, Codable, Equatable, Sendable {
    case wouldExceed
    case elapsed
    case usageUnknown
    case arithmeticOverflow
}

nonisolated struct AgentLimitResult: Codable, Equatable, Sendable {
    let runID: UUID
    let dimension: AgentBudgetDimension
    let scope: AgentBudgetLimitScope
    let reason: AgentLimitReason
    let current: Int64?
    let attempted: Int64?
    let maximum: Int64?
    let occurredAt: Date

    var summary: String {
        switch reason {
        case .usageUnknown:
            "Stopped: provider \(dimension.rawValue) is unknown under a finite hard limit."
        case .elapsed:
            "Stopped: the \(dimension.rawValue) hard limit elapsed."
        case .arithmeticOverflow:
            "Stopped: \(dimension.rawValue) accounting overflowed safely."
        case .wouldExceed:
            "Stopped before exceeding the \(dimension.rawValue) hard limit."
        }
    }

    func makeStep(sequence: Int, timestamp: Date? = nil) -> AgentStep {
        AgentStep(
            runID: runID,
            sequence: sequence,
            timestamp: timestamp ?? occurredAt,
            kind: .limit,
            summary: summary,
            payload: .object([
                "dimension": .string(dimension.rawValue),
                "scope": .string(scope.safeLabel),
                "reason": .string(reason.rawValue),
                "current": current.map { .number(Double($0)) } ?? .null,
                "attempted": attempted.map { .number(Double($0)) } ?? .null,
                "maximum": maximum.map { .number(Double($0)) } ?? .null,
            ]),
            redactionState: .metadataOnly
        )
    }
}

private nonisolated extension AgentBudgetLimitScope {
    var safeLabel: String {
        switch self {
        case .run: "run"
        case .taskDefinition: "taskDefinition"
        case .runGroup: "runGroup"
        }
    }
}

nonisolated struct AgentBudgetReceipt: Codable, Equatable, Sendable {
    let runID: UUID
    let chargedAt: Date
    let charge: AgentOperationCharge
    let runUsage: AgentExecutionUsage
    let sharedUsage: AgentExecutionUsage
}

nonisolated struct AgentBudgetCancellation: Codable, Equatable, Sendable {
    let runID: UUID
    let reason: String
    let cancelledAt: Date

    func makeStep(sequence: Int) -> AgentStep {
        AgentStep(
            runID: runID,
            sequence: sequence,
            timestamp: cancelledAt,
            kind: .stateTransition,
            summary: "Run cancelled: \(reason)",
            payload: .object(["status": .string(AgentRunStatus.cancelled.rawValue)]),
            redactionState: .metadataOnly
        )
    }
}

nonisolated enum AgentBudgetAdmission: Codable, Equatable, Sendable {
    case admitted(AgentBudgetReceipt)
    case limited(AgentLimitResult)
    case cancelled(AgentBudgetCancellation)
    case interrupted(runID: UUID)

    var isAdmitted: Bool {
        if case .admitted = self { return true }
        return false
    }
}

nonisolated enum AgentBudgetRunState: Codable, Equatable, Sendable {
    case active
    case limited(AgentLimitResult)
    case cancelled(AgentBudgetCancellation)
    case interrupted(at: Date)
}

nonisolated struct AgentBudgetAccountSnapshot: Codable, Equatable, Sendable {
    let runID: UUID
    let parentRunID: UUID?
    let limits: AgentExecutionLimits
    let startedAt: Date
    let usage: AgentExecutionUsage
    let state: AgentBudgetRunState
}

nonisolated struct AgentBudgetLedgerSnapshot: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let rootRunID: UUID
    let sharedScope: AgentBudgetLimitScope
    let sharedLimits: AgentExecutionLimits
    let sharedStartedAt: Date
    let sharedUsage: AgentExecutionUsage
    let accounts: [AgentBudgetAccountSnapshot]
    let capturedAt: Date

    init(
        rootRunID: UUID,
        sharedScope: AgentBudgetLimitScope,
        sharedLimits: AgentExecutionLimits,
        sharedStartedAt: Date,
        sharedUsage: AgentExecutionUsage,
        accounts: [AgentBudgetAccountSnapshot],
        capturedAt: Date
    ) {
        schemaVersion = Self.schemaVersion
        self.rootRunID = rootRunID
        self.sharedScope = sharedScope
        self.sharedLimits = sharedLimits
        self.sharedStartedAt = sharedStartedAt
        self.sharedUsage = sharedUsage
        self.accounts = accounts
        self.capturedAt = capturedAt
    }
}

actor AgentBudgetLedger {
    private struct Account: Sendable {
        let runID: UUID
        let parentRunID: UUID?
        let limits: AgentExecutionLimits
        let startedAt: Date
        var usage: AgentExecutionUsage
        var state: AgentBudgetRunState

        init(snapshot: AgentBudgetAccountSnapshot) {
            runID = snapshot.runID
            parentRunID = snapshot.parentRunID
            limits = snapshot.limits
            startedAt = snapshot.startedAt
            usage = snapshot.usage
            state = snapshot.state
        }

        var snapshot: AgentBudgetAccountSnapshot {
            AgentBudgetAccountSnapshot(
                runID: runID,
                parentRunID: parentRunID,
                limits: limits,
                startedAt: startedAt,
                usage: usage,
                state: state
            )
        }
    }

    let rootRunID: UUID
    let sharedScope: AgentBudgetLimitScope
    let sharedLimits: AgentExecutionLimits
    let sharedStartedAt: Date
    private var sharedUsage: AgentExecutionUsage
    private var accounts: [UUID: Account]

    init(
        rootRunID: UUID,
        sharedScope: AgentBudgetLimitScope,
        sharedLimits: AgentExecutionLimits,
        rootRunLimits: AgentExecutionLimits? = nil,
        startedAt: Date = Date()
    ) {
        self.rootRunID = rootRunID
        self.sharedScope = sharedScope
        self.sharedLimits = sharedLimits
        sharedStartedAt = startedAt
        sharedUsage = AgentExecutionUsage()
        let root = Account(snapshot: AgentBudgetAccountSnapshot(
            runID: rootRunID,
            parentRunID: nil,
            limits: rootRunLimits ?? sharedLimits,
            startedAt: startedAt,
            usage: AgentExecutionUsage(),
            state: .active
        ))
        accounts = [rootRunID: root]
    }

    init(restoring snapshot: AgentBudgetLedgerSnapshot) throws {
        guard snapshot.schemaVersion == AgentBudgetLedgerSnapshot.schemaVersion,
              snapshot.accounts.contains(where: { $0.runID == snapshot.rootRunID }),
              Set(snapshot.accounts.map(\.runID)).count == snapshot.accounts.count else {
            throw AgentExecutionLimitError.invalidRecoverySnapshot
        }
        rootRunID = snapshot.rootRunID
        sharedScope = snapshot.sharedScope
        sharedLimits = snapshot.sharedLimits
        sharedStartedAt = snapshot.sharedStartedAt
        sharedUsage = snapshot.sharedUsage
        accounts = Dictionary(uniqueKeysWithValues: snapshot.accounts.map {
            ($0.runID, Account(snapshot: $0))
        })
    }

    func registerRun(
        runID: UUID,
        parentRunID: UUID,
        limits: AgentExecutionLimits,
        startedAt: Date = Date()
    ) throws {
        guard accounts[runID] == nil else { throw AgentExecutionLimitError.duplicateRun(runID) }
        guard let parent = accounts[parentRunID] else {
            throw AgentExecutionLimitError.unknownParent(parentRunID)
        }
        try limits.validateSubset(of: parent.limits)
        try limits.validateSubset(of: sharedLimits)
        accounts[runID] = Account(snapshot: AgentBudgetAccountSnapshot(
            runID: runID,
            parentRunID: parentRunID,
            limits: limits,
            startedAt: max(startedAt, sharedStartedAt),
            usage: AgentExecutionUsage(),
            state: .active
        ))
    }

    func admit(
        runID: UUID,
        charge: AgentOperationCharge,
        at date: Date = Date()
    ) -> AgentBudgetAdmission {
        guard var account = accounts[runID] else {
            return .limited(unknownRunLimit(runID: runID, at: date))
        }
        switch account.state {
        case .limited(let limit): return .limited(limit)
        case .cancelled(let cancellation): return .cancelled(cancellation)
        case .interrupted: return .interrupted(runID: runID)
        case .active: break
        }

        if let elapsedLimit = elapsedLimit(for: account, at: date) {
            apply(limit: elapsedLimit, to: runID, shared: elapsedLimit.scope == sharedScope)
            return .limited(elapsedLimit)
        }

        let projectedRun: AgentExecutionUsage
        let projectedShared: AgentExecutionUsage
        do {
            projectedRun = try account.usage.adding(charge)
            projectedShared = try sharedUsage.adding(charge)
        } catch let error as AgentExecutionLimitError {
            let dimension: AgentBudgetDimension
            if case .arithmeticOverflow(let overflowed) = error {
                dimension = overflowed
            } else {
                dimension = .openPages
            }
            let limit = AgentLimitResult(
                runID: runID,
                dimension: dimension,
                scope: .run(runID),
                reason: .arithmeticOverflow,
                current: account.usage.value(for: dimension, elapsedMilliseconds: 0),
                attempted: nil,
                maximum: account.limits.maximum(for: dimension),
                occurredAt: date
            )
            apply(limit: limit, to: runID, shared: false)
            return .limited(limit)
        } catch {
            let limit = AgentLimitResult(
                runID: runID,
                dimension: .openPages,
                scope: .run(runID),
                reason: .arithmeticOverflow,
                current: account.usage.openPages,
                attempted: charge.pageDelta,
                maximum: Int64(account.limits.maximumOpenPages),
                occurredAt: date
            )
            apply(limit: limit, to: runID, shared: false)
            return .limited(limit)
        }

        if let limit = firstExceeded(
            runID: runID,
            current: account.usage,
            projected: projectedRun,
            limits: account.limits,
            scope: .run(runID),
            at: date
        ) {
            apply(limit: limit, to: runID, shared: false)
            return .limited(limit)
        }
        if let limit = firstExceeded(
            runID: runID,
            current: sharedUsage,
            projected: projectedShared,
            limits: sharedLimits,
            scope: sharedScope,
            at: date
        ) {
            apply(limit: limit, to: runID, shared: true)
            return .limited(limit)
        }

        account.usage = projectedRun
        accounts[runID] = account
        sharedUsage = projectedShared
        return .admitted(AgentBudgetReceipt(
            runID: runID,
            chargedAt: date,
            charge: charge,
            runUsage: projectedRun,
            sharedUsage: projectedShared
        ))
    }

    func cancel(
        runID: UUID,
        reason: String = "user requested stop",
        at date: Date = Date(),
        propagateToDescendants: Bool = true
    ) throws -> [AgentBudgetCancellation] {
        guard accounts[runID] != nil else { throw AgentExecutionLimitError.unknownRun(runID) }
        let affected = accounts.keys.filter { candidate in
            candidate == runID || (propagateToDescendants && isDescendant(candidate, of: runID))
        }.sorted { $0.uuidString < $1.uuidString }
        return affected.compactMap { candidate in
            guard var account = accounts[candidate] else { return nil }
            if case .cancelled(let cancellation) = account.state { return cancellation }
            let cancellation = AgentBudgetCancellation(
                runID: candidate,
                reason: reason,
                cancelledAt: date
            )
            account.state = .cancelled(cancellation)
            accounts[candidate] = account
            return cancellation
        }
    }

    func markInterrupted(at date: Date = Date()) -> [UUID] {
        let interrupted = accounts.values.filter {
            if case .active = $0.state { return true }
            return false
        }.map(\.runID).sorted { $0.uuidString < $1.uuidString }
        for runID in interrupted {
            accounts[runID]?.state = .interrupted(at: date)
        }
        return interrupted
    }

    func resume(runID: UUID) throws {
        guard var account = accounts[runID] else {
            throw AgentExecutionLimitError.unknownRun(runID)
        }
        guard case .interrupted = account.state else { return }
        account.state = .active
        accounts[runID] = account
    }

    func snapshot(at date: Date = Date()) -> AgentBudgetLedgerSnapshot {
        AgentBudgetLedgerSnapshot(
            rootRunID: rootRunID,
            sharedScope: sharedScope,
            sharedLimits: sharedLimits,
            sharedStartedAt: sharedStartedAt,
            sharedUsage: sharedUsage,
            accounts: accounts.values.map(\.snapshot).sorted {
                $0.runID.uuidString < $1.runID.uuidString
            },
            capturedAt: date
        )
    }

    private func elapsedLimit(for account: Account, at date: Date) -> AgentLimitResult? {
        let runElapsed = Self.elapsed(from: account.startedAt, to: date)
        if runElapsed >= account.limits.maximumElapsedMilliseconds {
            return AgentLimitResult(
                runID: account.runID,
                dimension: .elapsedTime,
                scope: .run(account.runID),
                reason: .elapsed,
                current: runElapsed,
                attempted: nil,
                maximum: account.limits.maximumElapsedMilliseconds,
                occurredAt: date
            )
        }
        let sharedElapsed = Self.elapsed(from: sharedStartedAt, to: date)
        if sharedElapsed >= sharedLimits.maximumElapsedMilliseconds {
            return AgentLimitResult(
                runID: account.runID,
                dimension: .elapsedTime,
                scope: sharedScope,
                reason: .elapsed,
                current: sharedElapsed,
                attempted: nil,
                maximum: sharedLimits.maximumElapsedMilliseconds,
                occurredAt: date
            )
        }
        return nil
    }

    private func firstExceeded(
        runID: UUID,
        current: AgentExecutionUsage,
        projected: AgentExecutionUsage,
        limits: AgentExecutionLimits,
        scope: AgentBudgetLimitScope,
        at date: Date
    ) -> AgentLimitResult? {
        let ordered: [AgentBudgetDimension] = [
            .turns, .toolCalls, .providerTokens, .providerCost, .openPages,
            .modelResultBytes, .downloads, .downloadBytes, .artifacts, .artifactBytes,
        ]
        for dimension in ordered {
            guard let maximum = limits.maximum(for: dimension) else { continue }
            let projectedValue = projected.value(for: dimension, elapsedMilliseconds: 0)
            guard projectedValue > maximum else { continue }
            return AgentLimitResult(
                runID: runID,
                dimension: dimension,
                scope: scope,
                reason: .wouldExceed,
                current: current.value(for: dimension, elapsedMilliseconds: 0),
                attempted: projectedValue,
                maximum: maximum,
                occurredAt: date
            )
        }
        return nil
    }

    private func apply(limit: AgentLimitResult, to runID: UUID, shared: Bool) {
        if shared {
            for id in accounts.keys {
                guard var account = accounts[id] else { continue }
                if case .active = account.state {
                    account.state = .limited(AgentLimitResult(
                        runID: id,
                        dimension: limit.dimension,
                        scope: limit.scope,
                        reason: limit.reason,
                        current: limit.current,
                        attempted: limit.attempted,
                        maximum: limit.maximum,
                        occurredAt: limit.occurredAt
                    ))
                    accounts[id] = account
                }
            }
        } else if var account = accounts[runID] {
            account.state = .limited(limit)
            accounts[runID] = account
        }
    }

    private func isDescendant(_ candidate: UUID, of ancestor: UUID) -> Bool {
        var current = accounts[candidate]?.parentRunID
        var visited = Set<UUID>()
        while let runID = current, visited.insert(runID).inserted {
            if runID == ancestor { return true }
            current = accounts[runID]?.parentRunID
        }
        return false
    }

    private func unknownRunLimit(runID: UUID, at date: Date) -> AgentLimitResult {
        AgentLimitResult(
            runID: runID,
            dimension: .turns,
            scope: .run(runID),
            reason: .wouldExceed,
            current: nil,
            attempted: nil,
            maximum: nil,
            occurredAt: date
        )
    }

    private static func elapsed(from start: Date, to end: Date) -> Int64 {
        let milliseconds = max(0, end.timeIntervalSince(start)) * 1_000
        guard milliseconds < Double(Int64.max) else { return Int64.max }
        return Int64(milliseconds.rounded(.down))
    }
}

// MARK: - Provider usage and cost provenance

nonisolated enum AgentUsageUnknownReason: String, Codable, Equatable, Sendable {
    case providerDidNotReport
    case invalidProviderReport
}

nonisolated enum AgentMeasuredTokenCount: Codable, Equatable, Sendable {
    case known(Int64)
    case unknown(AgentUsageUnknownReason)

    var knownValue: Int64? {
        if case .known(let value) = self { return value }
        return nil
    }
}

nonisolated struct AgentNormalizedProviderUsage: Codable, Equatable, Sendable {
    let inputTokens: AgentMeasuredTokenCount
    let outputTokens: AgentMeasuredTokenCount
    let totalTokens: AgentMeasuredTokenCount
    let cachedInputTokens: AgentMeasuredTokenCount

    init(_ usage: AgentModelUsage) {
        switch usage {
        case .unknown:
            let unknown = AgentMeasuredTokenCount.unknown(.providerDidNotReport)
            inputTokens = unknown
            outputTokens = unknown
            totalTokens = unknown
            cachedInputTokens = unknown
        case let .reported(input, output, total, cached):
            let values = [input, output, total, cached].compactMap { $0 }
            guard values.allSatisfy({ $0 >= 0 }) else {
                let unknown = AgentMeasuredTokenCount.unknown(.invalidProviderReport)
                inputTokens = unknown
                outputTokens = unknown
                totalTokens = unknown
                cachedInputTokens = unknown
                return
            }
            inputTokens = Self.measure(input)
            outputTokens = Self.measure(output)
            cachedInputTokens = Self.measure(cached)
            if let total {
                totalTokens = .known(Int64(total))
            } else if let input, let output {
                let (sum, overflow) = Int64(input).addingReportingOverflow(Int64(output))
                totalTokens = overflow ? .unknown(.invalidProviderReport) : .known(sum)
            } else {
                totalTokens = .unknown(.providerDidNotReport)
            }
        }
    }

    private static func measure(_ value: Int?) -> AgentMeasuredTokenCount {
        value.map { .known(Int64($0)) } ?? .unknown(.providerDidNotReport)
    }
}

nonisolated enum AgentPricingMetadataSource: String, Codable, Equatable, Sendable {
    case userConfigured
    case providerPublished
}

nonisolated struct AgentProviderPricingMetadata: Codable, Equatable, Sendable {
    let source: AgentPricingMetadataSource
    let currencyCode: String
    let inputMicrounitsPerMillionTokens: Int64?
    let cachedInputMicrounitsPerMillionTokens: Int64?
    let outputMicrounitsPerMillionTokens: Int64?
    let estimatedBlendedMicrounitsPerMillionTokens: Int64?

    init(
        source: AgentPricingMetadataSource,
        currencyCode: String,
        inputMicrounitsPerMillionTokens: Int64? = nil,
        cachedInputMicrounitsPerMillionTokens: Int64? = nil,
        outputMicrounitsPerMillionTokens: Int64? = nil,
        estimatedBlendedMicrounitsPerMillionTokens: Int64? = nil
    ) throws {
        let currency = currencyCode.uppercased()
        guard currency.count == 3,
              currency.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) }) else {
            throw AgentExecutionLimitError.invalidLimit("pricingCurrency")
        }
        let rates = [
            inputMicrounitsPerMillionTokens,
            cachedInputMicrounitsPerMillionTokens,
            outputMicrounitsPerMillionTokens,
            estimatedBlendedMicrounitsPerMillionTokens,
        ].compactMap { $0 }
        guard !rates.isEmpty, rates.allSatisfy({ $0 >= 0 }) else {
            throw AgentExecutionLimitError.invalidLimit("pricingRate")
        }
        self.source = source
        self.currencyCode = currency
        self.inputMicrounitsPerMillionTokens = inputMicrounitsPerMillionTokens
        self.cachedInputMicrounitsPerMillionTokens = cachedInputMicrounitsPerMillionTokens
        self.outputMicrounitsPerMillionTokens = outputMicrounitsPerMillionTokens
        self.estimatedBlendedMicrounitsPerMillionTokens = estimatedBlendedMicrounitsPerMillionTokens
    }
}

nonisolated enum AgentCostConfidence: String, Codable, Equatable, Sendable {
    case calculated
    case estimated
}

nonisolated struct AgentProviderCost: Codable, Equatable, Sendable {
    let amountMicrounits: Int64
    let currencyCode: String
    let confidence: AgentCostConfidence
    let pricingSource: AgentPricingMetadataSource
}

nonisolated enum AgentCostUnknownReason: String, Codable, Equatable, Sendable {
    case usageUnknown
    case pricingUnavailable
    case incompleteUsageOrPricing
    case invalidUsage
    case arithmeticOverflow
}

nonisolated enum AgentProviderCostResult: Codable, Equatable, Sendable {
    case available(AgentProviderCost)
    case unknown(AgentCostUnknownReason)

    var knownMicrounits: Int64? {
        if case .available(let cost) = self { return cost.amountMicrounits }
        return nil
    }
}

nonisolated enum AgentProviderCostCalculator {
    static func calculate(
        usage: AgentNormalizedProviderUsage,
        pricing: AgentProviderPricingMetadata?
    ) -> AgentProviderCostResult {
        guard case .known(let total) = usage.totalTokens else {
            if usage.totalTokens == .unknown(.invalidProviderReport) {
                return .unknown(.invalidUsage)
            }
            return .unknown(.usageUnknown)
        }
        guard let pricing else { return .unknown(.pricingUnavailable) }

        if case .known(let input) = usage.inputTokens,
           case .known(let output) = usage.outputTokens,
           let inputRate = pricing.inputMicrounitsPerMillionTokens,
           let outputRate = pricing.outputMicrounitsPerMillionTokens {
            let cached = usage.cachedInputTokens.knownValue ?? 0
            guard cached <= input else { return .unknown(.invalidUsage) }
            let cachedRate = pricing.cachedInputMicrounitsPerMillionTokens ?? inputRate
            do {
                let regularCost = try prorated(tokens: input - cached, rate: inputRate)
                let cachedCost = try prorated(tokens: cached, rate: cachedRate)
                let outputCost = try prorated(tokens: output, rate: outputRate)
                let inputTotal = try add(regularCost, cachedCost)
                return .available(AgentProviderCost(
                    amountMicrounits: try add(inputTotal, outputCost),
                    currencyCode: pricing.currencyCode,
                    confidence: .calculated,
                    pricingSource: pricing.source
                ))
            } catch {
                return .unknown(.arithmeticOverflow)
            }
        }

        if let blended = pricing.estimatedBlendedMicrounitsPerMillionTokens {
            do {
                return .available(AgentProviderCost(
                    amountMicrounits: try prorated(tokens: total, rate: blended),
                    currencyCode: pricing.currencyCode,
                    confidence: .estimated,
                    pricingSource: pricing.source
                ))
            } catch {
                return .unknown(.arithmeticOverflow)
            }
        }
        return .unknown(.incompleteUsageOrPricing)
    }

    private static func prorated(tokens: Int64, rate: Int64) throws -> Int64 {
        let whole = tokens / 1_000_000
        let remainder = tokens % 1_000_000
        let (wholeCost, firstOverflow) = whole.multipliedReportingOverflow(by: rate)
        let (remainderProduct, secondOverflow) = remainder.multipliedReportingOverflow(by: rate)
        guard !firstOverflow, !secondOverflow else {
            throw AgentExecutionLimitError.arithmeticOverflow(.providerCost)
        }
        let roundedRemainder: Int64
        if remainderProduct == 0 {
            roundedRemainder = 0
        } else {
            let (adjusted, overflow) = remainderProduct.addingReportingOverflow(999_999)
            guard !overflow else {
                throw AgentExecutionLimitError.arithmeticOverflow(.providerCost)
            }
            roundedRemainder = adjusted / 1_000_000
        }
        return try add(wholeCost, roundedRemainder)
    }

    private static func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw AgentExecutionLimitError.arithmeticOverflow(.providerCost)
        }
        return result
    }
}

nonisolated struct AgentProviderUsageLink: Codable, Equatable, Sendable {
    let runID: UUID
    let providerID: String
    let model: String
    let providerRequestID: String
    let usageStepID: UUID?
    let observedAt: Date
    let usage: AgentNormalizedProviderUsage
    let cost: AgentProviderCostResult
}

nonisolated struct AgentProviderUsageAccounting: Codable, Equatable, Sendable {
    let link: AgentProviderUsageLink
    let usage: AgentNormalizedProviderUsage
    let cost: AgentProviderCostResult
    let admission: AgentBudgetAdmission
}

extension AgentBudgetLedger {
    func recordProviderUsage(
        runID: UUID,
        providerID: String,
        model: String,
        requestID: String,
        usageStepID: UUID?,
        usage: AgentModelUsage,
        pricing: AgentProviderPricingMetadata?,
        at date: Date = Date()
    ) -> AgentProviderUsageAccounting {
        let normalized = AgentNormalizedProviderUsage(usage)
        let cost = AgentProviderCostCalculator.calculate(usage: normalized, pricing: pricing)
        let link = AgentProviderUsageLink(
            runID: runID,
            providerID: providerID,
            model: model,
            providerRequestID: requestID,
            usageStepID: usageStepID,
            observedAt: date,
            usage: normalized,
            cost: cost
        )

        guard var account = accounts[runID] else {
            return AgentProviderUsageAccounting(
                link: link,
                usage: normalized,
                cost: cost,
                admission: .limited(unknownRunLimit(runID: runID, at: date))
            )
        }
        switch account.state {
        case .limited(let limit):
            return AgentProviderUsageAccounting(
                link: link,
                usage: normalized,
                cost: cost,
                admission: .limited(limit)
            )
        case .cancelled(let cancellation):
            return AgentProviderUsageAccounting(
                link: link,
                usage: normalized,
                cost: cost,
                admission: .cancelled(cancellation)
            )
        case .interrupted:
            return AgentProviderUsageAccounting(
                link: link,
                usage: normalized,
                cost: cost,
                admission: .interrupted(runID: runID)
            )
        case .active:
            break
        }

        let tokenCount = normalized.totalTokens.knownValue
        let costMicrounits = cost.knownMicrounits
        let originalRunUsage = account.usage
        let originalSharedUsage = sharedUsage
        let charge: AgentOperationCharge
        do {
            charge = try AgentOperationCharge(
                providerTokens: tokenCount ?? 0,
                providerCostMicrounits: costMicrounits ?? 0
            )
            account.usage = try account.usage.adding(charge)
            sharedUsage = try sharedUsage.adding(charge)
        } catch let error as AgentExecutionLimitError {
            let dimension: AgentBudgetDimension
            if case .arithmeticOverflow(let value) = error {
                dimension = value
            } else {
                dimension = .providerTokens
            }
            let limit = AgentLimitResult(
                runID: runID,
                dimension: dimension,
                scope: .run(runID),
                reason: .arithmeticOverflow,
                current: originalRunUsage.value(for: dimension, elapsedMilliseconds: 0),
                attempted: nil,
                maximum: account.limits.maximum(for: dimension),
                occurredAt: date
            )
            apply(limit: limit, to: runID, shared: false)
            return AgentProviderUsageAccounting(
                link: link,
                usage: normalized,
                cost: cost,
                admission: .limited(limit)
            )
        } catch {
            let limit = AgentLimitResult(
                runID: runID,
                dimension: .providerTokens,
                scope: .run(runID),
                reason: .arithmeticOverflow,
                current: originalRunUsage.providerTokens,
                attempted: nil,
                maximum: account.limits.maximumProviderTokens,
                occurredAt: date
            )
            apply(limit: limit, to: runID, shared: false)
            return AgentProviderUsageAccounting(
                link: link,
                usage: normalized,
                cost: cost,
                admission: .limited(limit)
            )
        }

        if tokenCount == nil {
            account.usage.providerTokensKnown = false
            sharedUsage.providerTokensKnown = false
        }
        if costMicrounits == nil {
            account.usage.providerCostKnown = false
            sharedUsage.providerCostKnown = false
        }
        accounts[runID] = account

        let limit = unknownUsageLimit(
            runID: runID,
            account: account,
            tokenCount: tokenCount,
            costMicrounits: costMicrounits,
            at: date
        ) ?? firstExceeded(
            runID: runID,
            current: originalRunUsage,
            projected: account.usage,
            limits: account.limits,
            scope: .run(runID),
            at: date
        ) ?? firstExceeded(
            runID: runID,
            current: originalSharedUsage,
            projected: sharedUsage,
            limits: sharedLimits,
            scope: sharedScope,
            at: date
        )

        let admission: AgentBudgetAdmission
        if let limit {
            apply(limit: limit, to: runID, shared: limit.scope == sharedScope)
            admission = .limited(limit)
        } else {
            admission = .admitted(AgentBudgetReceipt(
                runID: runID,
                chargedAt: date,
                charge: charge,
                runUsage: account.usage,
                sharedUsage: sharedUsage
            ))
        }
        return AgentProviderUsageAccounting(
            link: link,
            usage: normalized,
            cost: cost,
            admission: admission
        )
    }

    private func unknownUsageLimit(
        runID: UUID,
        account: Account,
        tokenCount: Int64?,
        costMicrounits: Int64?,
        at date: Date
    ) -> AgentLimitResult? {
        let candidates: [(AgentBudgetDimension, Bool)] = [
            (.providerTokens, tokenCount == nil),
            (.providerCost, costMicrounits == nil),
        ]
        for (dimension, unknown) in candidates where unknown {
            if let maximum = account.limits.maximum(for: dimension) {
                return AgentLimitResult(
                    runID: runID,
                    dimension: dimension,
                    scope: .run(runID),
                    reason: .usageUnknown,
                    current: nil,
                    attempted: nil,
                    maximum: maximum,
                    occurredAt: date
                )
            }
            if let maximum = sharedLimits.maximum(for: dimension) {
                return AgentLimitResult(
                    runID: runID,
                    dimension: dimension,
                    scope: sharedScope,
                    reason: .usageUnknown,
                    current: nil,
                    attempted: nil,
                    maximum: maximum,
                    occurredAt: date
                )
            }
        }
        return nil
    }
}

// MARK: - Local-only observability

nonisolated enum AgentMetricStoreError: Error, Equatable, Sendable {
    case invalidRetention(String)
    case invalidMetric(String)
    case invalidSnapshot
}

nonisolated struct AgentMetricRetentionPolicy: Codable, Equatable, Sendable {
    let maximumTotalEvents: Int
    let maximumEventsPerRun: Int
    let maximumAge: TimeInterval

    init(
        maximumTotalEvents: Int = 10_000,
        maximumEventsPerRun: Int = 1_000,
        maximumAge: TimeInterval = 30 * 24 * 60 * 60
    ) throws {
        guard maximumTotalEvents > 0 else {
            throw AgentMetricStoreError.invalidRetention("maximumTotalEvents")
        }
        guard maximumEventsPerRun > 0 else {
            throw AgentMetricStoreError.invalidRetention("maximumEventsPerRun")
        }
        guard maximumAge.isFinite, maximumAge > 0 else {
            throw AgentMetricStoreError.invalidRetention("maximumAge")
        }
        self.maximumTotalEvents = maximumTotalEvents
        self.maximumEventsPerRun = maximumEventsPerRun
        self.maximumAge = maximumAge
    }
}

nonisolated struct AgentRemoteDiagnosticsSettings: Codable, Equatable, Sendable {
    let localMetricsEnabled: Bool
    let remoteDiagnosticsEnabled: Bool
    let remoteErrorReportsEnabled: Bool

    static let disabled = AgentRemoteDiagnosticsSettings(
        localMetricsEnabled: true,
        remoteDiagnosticsEnabled: false,
        remoteErrorReportsEnabled: false
    )

    init(
        localMetricsEnabled: Bool = true,
        remoteDiagnosticsEnabled: Bool = false,
        remoteErrorReportsEnabled: Bool = false
    ) {
        self.localMetricsEnabled = localMetricsEnabled
        self.remoteDiagnosticsEnabled = remoteDiagnosticsEnabled
        self.remoteErrorReportsEnabled = remoteErrorReportsEnabled
    }
}

nonisolated enum AgentToolMetricOutcome: String, Codable, Equatable, Sendable {
    case succeeded
    case denied
    case failed
    case cancelled
    case ambiguousTimeout
}

nonisolated enum AgentMetricRetryCategory: String, Codable, Equatable, Sendable {
    case transient
    case rateLimited
    case connectionLost
}

nonisolated enum AgentMetricApprovalOutcome: String, Codable, Equatable, Sendable {
    case approved
    case denied
    case expired
    case cancelled
    case waitingForHuman
}

nonisolated enum AgentFailureCategory: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case provider
    case transport
    case tool
    case policy
    case targetUnavailable
    case validation
    case persistence
    case budget
    case cancelled
    case unknown
}

nonisolated enum AgentMetricPayload: Codable, Equatable, Sendable {
    case providerLatency(milliseconds: Int64, providerID: String)
    case timeToFirstToken(milliseconds: Int64, providerID: String)
    case toolLatency(milliseconds: Int64, toolName: String, outcome: AgentToolMetricOutcome)
    case retry(providerID: String, category: AgentMetricRetryCategory)
    case approval(outcome: AgentMetricApprovalOutcome, waitMilliseconds: Int64)
    case failure(category: AgentFailureCategory)
    case resourcePeak(resource: AgentBudgetDimension, value: Int64)
    case providerUsage(AgentProviderUsageLink)
    case limit(dimension: AgentBudgetDimension, reason: AgentLimitReason)
    case recovery
}

nonisolated struct AgentMetricEvent: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let runID: UUID
    let timestamp: Date
    let incognito: Bool
    let payload: AgentMetricPayload

    init(
        id: UUID = UUID(),
        runID: UUID,
        timestamp: Date = Date(),
        incognito: Bool,
        payload: AgentMetricPayload
    ) {
        schemaVersion = Self.schemaVersion
        self.id = id
        self.runID = runID
        self.timestamp = timestamp
        self.incognito = incognito
        self.payload = payload
    }

    static func providerLatency(
        runID: UUID,
        milliseconds: Int64,
        providerID: String,
        incognito: Bool = false,
        at date: Date = Date()
    ) -> Self {
        Self(
            runID: runID,
            timestamp: date,
            incognito: incognito,
            payload: .providerLatency(milliseconds: milliseconds, providerID: providerID)
        )
    }

    static func timeToFirstToken(
        runID: UUID,
        milliseconds: Int64,
        providerID: String,
        incognito: Bool = false,
        at date: Date = Date()
    ) -> Self {
        Self(
            runID: runID,
            timestamp: date,
            incognito: incognito,
            payload: .timeToFirstToken(milliseconds: milliseconds, providerID: providerID)
        )
    }

    static func toolLatency(
        runID: UUID,
        milliseconds: Int64,
        toolName: String,
        outcome: AgentToolMetricOutcome,
        incognito: Bool = false,
        at date: Date = Date()
    ) -> Self {
        Self(
            runID: runID,
            timestamp: date,
            incognito: incognito,
            payload: .toolLatency(
                milliseconds: milliseconds,
                toolName: toolName,
                outcome: outcome
            )
        )
    }

    static func retry(
        runID: UUID,
        providerID: String,
        category: AgentMetricRetryCategory,
        incognito: Bool = false,
        at date: Date = Date()
    ) -> Self {
        Self(
            runID: runID,
            timestamp: date,
            incognito: incognito,
            payload: .retry(providerID: providerID, category: category)
        )
    }

    static func resourcePeak(
        runID: UUID,
        resource: AgentBudgetDimension,
        value: Int64,
        incognito: Bool = false,
        at date: Date = Date()
    ) -> Self {
        Self(
            runID: runID,
            timestamp: date,
            incognito: incognito,
            payload: .resourcePeak(resource: resource, value: value)
        )
    }

    static func providerUsage(
        _ link: AgentProviderUsageLink,
        incognito: Bool
    ) -> Self {
        Self(
            runID: link.runID,
            timestamp: link.observedAt,
            incognito: incognito,
            payload: .providerUsage(link)
        )
    }
}

nonisolated struct AgentLocalMetricSnapshot: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let retention: AgentMetricRetentionPolicy
    let remoteDiagnosticsSettings: AgentRemoteDiagnosticsSettings
    let events: [AgentMetricEvent]
    let capturedAt: Date

    init(
        retention: AgentMetricRetentionPolicy,
        remoteDiagnosticsSettings: AgentRemoteDiagnosticsSettings,
        events: [AgentMetricEvent],
        capturedAt: Date
    ) {
        schemaVersion = Self.schemaVersion
        self.retention = retention
        self.remoteDiagnosticsSettings = remoteDiagnosticsSettings
        self.events = events
        self.capturedAt = capturedAt
    }
}

nonisolated struct AgentDurationStatistics: Codable, Equatable, Sendable {
    let sampleCount: Int
    let minimumMilliseconds: Int64?
    let maximumMilliseconds: Int64?
    let totalMilliseconds: Int64?

    var averageMilliseconds: Int64? {
        guard sampleCount > 0, let totalMilliseconds else { return nil }
        return totalMilliseconds / Int64(sampleCount)
    }

    static let unknown = Self(
        sampleCount: 0,
        minimumMilliseconds: nil,
        maximumMilliseconds: nil,
        totalMilliseconds: nil
    )

    fileprivate init(values: [Int64]) {
        guard !values.isEmpty else {
            self = .unknown
            return
        }
        var total: Int64 = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else {
                self = Self(
                    sampleCount: values.count,
                    minimumMilliseconds: values.min(),
                    maximumMilliseconds: values.max(),
                    totalMilliseconds: nil
                )
                return
            }
            total = next
        }
        self = Self(
            sampleCount: values.count,
            minimumMilliseconds: values.min(),
            maximumMilliseconds: values.max(),
            totalMilliseconds: total
        )
    }

    private init(
        sampleCount: Int,
        minimumMilliseconds: Int64?,
        maximumMilliseconds: Int64?,
        totalMilliseconds: Int64?
    ) {
        self.sampleCount = sampleCount
        self.minimumMilliseconds = minimumMilliseconds
        self.maximumMilliseconds = maximumMilliseconds
        self.totalMilliseconds = totalMilliseconds
    }
}

nonisolated enum AgentMetricQuantity: Codable, Equatable, Sendable {
    case known(Int64)
    case unknown
}

nonisolated enum AgentMetricCostSummary: Codable, Equatable, Sendable {
    case known(amountMicrounits: Int64, currencyCode: String, containsEstimates: Bool)
    case unknown
}

nonisolated struct AgentRunObservabilitySummary: Codable, Equatable, Identifiable, Sendable {
    let runID: UUID
    let providerLatency: AgentDurationStatistics
    let timeToFirstToken: AgentDurationStatistics
    let toolLatency: AgentDurationStatistics
    let retries: Int
    let approvals: [AgentMetricApprovalOutcome: Int]
    let failures: [AgentFailureCategory: Int]
    let resourcePeaks: [AgentBudgetDimension: Int64]
    let providerTokens: AgentMetricQuantity
    let providerCost: AgentMetricCostSummary
    let limitEvents: Int
    let recovered: Bool

    var id: UUID { runID }
}

nonisolated struct AgentAggregateObservabilitySummary: Codable, Equatable, Sendable {
    let providerLatency: AgentDurationStatistics
    let timeToFirstToken: AgentDurationStatistics
    let toolLatency: AgentDurationStatistics
    let retries: Int
    let approvals: [AgentMetricApprovalOutcome: Int]
    let failures: [AgentFailureCategory: Int]
    let resourcePeaks: [AgentBudgetDimension: Int64]
    let providerTokens: AgentMetricQuantity
    let providerCost: AgentMetricCostSummary
    let limitEvents: Int
}

nonisolated struct AgentObservabilityDashboard: Codable, Equatable, Sendable {
    let generatedAt: Date
    let retainedEventCount: Int
    let runs: [AgentRunObservabilitySummary]
    let aggregate: AgentAggregateObservabilitySummary
}

nonisolated enum AgentObservabilityProjector {
    static func dashboard(events: [AgentMetricEvent], at date: Date) -> AgentObservabilityDashboard {
        let grouped = Dictionary(grouping: events, by: \.runID)
        let runs = grouped.keys.sorted { $0.uuidString < $1.uuidString }.map { runID in
            makeRunSummary(runID: runID, events: grouped[runID, default: []])
        }
        let all = makeValues(events: events)
        return AgentObservabilityDashboard(
            generatedAt: date,
            retainedEventCount: events.count,
            runs: runs,
            aggregate: AgentAggregateObservabilitySummary(
                providerLatency: AgentDurationStatistics(values: all.providerLatency),
                timeToFirstToken: AgentDurationStatistics(values: all.firstToken),
                toolLatency: AgentDurationStatistics(values: all.toolLatency),
                retries: all.retries,
                approvals: all.approvals,
                failures: all.failures,
                resourcePeaks: all.resourcePeaks,
                providerTokens: quantity(all.tokenValues),
                providerCost: costSummary(all.costValues),
                limitEvents: all.limitEvents
            )
        )
    }

    private struct Values {
        var providerLatency: [Int64] = []
        var firstToken: [Int64] = []
        var toolLatency: [Int64] = []
        var retries = 0
        var approvals: [AgentMetricApprovalOutcome: Int] = [:]
        var failures: [AgentFailureCategory: Int] = [:]
        var resourcePeaks: [AgentBudgetDimension: Int64] = [:]
        var tokenValues: [AgentMeasuredTokenCount] = []
        var costValues: [AgentProviderCostResult] = []
        var limitEvents = 0
        var recovered = false
    }

    private static func makeRunSummary(
        runID: UUID,
        events: [AgentMetricEvent]
    ) -> AgentRunObservabilitySummary {
        let values = makeValues(events: events)
        return AgentRunObservabilitySummary(
            runID: runID,
            providerLatency: AgentDurationStatistics(values: values.providerLatency),
            timeToFirstToken: AgentDurationStatistics(values: values.firstToken),
            toolLatency: AgentDurationStatistics(values: values.toolLatency),
            retries: values.retries,
            approvals: values.approvals,
            failures: values.failures,
            resourcePeaks: values.resourcePeaks,
            providerTokens: quantity(values.tokenValues),
            providerCost: costSummary(values.costValues),
            limitEvents: values.limitEvents,
            recovered: values.recovered
        )
    }

    private static func makeValues(events: [AgentMetricEvent]) -> Values {
        var values = Values()
        for event in events {
            switch event.payload {
            case .providerLatency(let milliseconds, _):
                values.providerLatency.append(milliseconds)
            case .timeToFirstToken(let milliseconds, _):
                values.firstToken.append(milliseconds)
            case .toolLatency(let milliseconds, _, _):
                values.toolLatency.append(milliseconds)
            case .retry:
                values.retries += 1
            case .approval(let outcome, _):
                values.approvals[outcome, default: 0] += 1
            case .failure(let category):
                values.failures[category, default: 0] += 1
            case .resourcePeak(let resource, let value):
                values.resourcePeaks[resource] = max(values.resourcePeaks[resource] ?? 0, value)
            case .providerUsage(let link):
                values.tokenValues.append(link.usage.totalTokens)
                values.costValues.append(link.cost)
            case .limit:
                values.limitEvents += 1
            case .recovery:
                values.recovered = true
            }
        }
        return values
    }

    private static func quantity(_ values: [AgentMeasuredTokenCount]) -> AgentMetricQuantity {
        guard !values.isEmpty,
              values.allSatisfy({ $0.knownValue != nil }) else { return .unknown }
        var total: Int64 = 0
        for value in values.compactMap(\.knownValue) {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return .unknown }
            total = next
        }
        return .known(total)
    }

    private static func costSummary(_ values: [AgentProviderCostResult]) -> AgentMetricCostSummary {
        guard !values.isEmpty else { return .unknown }
        let costs = values.compactMap { result -> AgentProviderCost? in
            if case .available(let cost) = result { return cost }
            return nil
        }
        guard costs.count == values.count,
              let currency = costs.first?.currencyCode,
              costs.allSatisfy({ $0.currencyCode == currency }) else { return .unknown }
        var total: Int64 = 0
        for cost in costs {
            let (next, overflow) = total.addingReportingOverflow(cost.amountMicrounits)
            guard !overflow else { return .unknown }
            total = next
        }
        return .known(
            amountMicrounits: total,
            currencyCode: currency,
            containsEstimates: costs.contains { $0.confidence == .estimated }
        )
    }
}

actor AgentLocalMetricStore {
    private(set) var retention: AgentMetricRetentionPolicy
    private(set) var remoteDiagnosticsSettings: AgentRemoteDiagnosticsSettings
    private var retainedEvents: [AgentMetricEvent]
    private var eventIDs: Set<UUID>

    init(
        retention: AgentMetricRetentionPolicy,
        remoteDiagnosticsSettings: AgentRemoteDiagnosticsSettings = .disabled
    ) {
        self.retention = retention
        self.remoteDiagnosticsSettings = remoteDiagnosticsSettings
        retainedEvents = []
        eventIDs = []
    }

    init(restoring snapshot: AgentLocalMetricSnapshot) throws {
        guard snapshot.schemaVersion == AgentLocalMetricSnapshot.schemaVersion,
              snapshot.events.allSatisfy({ $0.schemaVersion == AgentMetricEvent.schemaVersion }),
              Set(snapshot.events.map(\.id)).count == snapshot.events.count else {
            throw AgentMetricStoreError.invalidSnapshot
        }
        retention = snapshot.retention
        remoteDiagnosticsSettings = snapshot.remoteDiagnosticsSettings
        retainedEvents = Self.pruned(
            snapshot.events,
            retention: snapshot.retention,
            now: snapshot.capturedAt
        )
        eventIDs = Set(retainedEvents.map(\.id))
    }

    @discardableResult
    func record(_ event: AgentMetricEvent, now: Date = Date()) throws -> Bool {
        try Task.checkCancellation()
        guard remoteDiagnosticsSettings.localMetricsEnabled else { return false }
        // Private-browsing telemetry is non-retaining at the storage boundary,
        // not merely hidden later by dashboards or diagnostic export.
        guard !event.incognito else { return false }
        try Self.validate(event)
        guard eventIDs.insert(event.id).inserted else { return false }
        retainedEvents.append(event)
        prune(now: now)
        return eventIDs.contains(event.id)
    }

    func events(now: Date = Date()) -> [AgentMetricEvent] {
        prune(now: now)
        return retainedEvents
    }

    func dashboard(now: Date = Date()) -> AgentObservabilityDashboard {
        prune(now: now)
        return AgentObservabilityProjector.dashboard(events: retainedEvents, at: now)
    }

    func snapshot(now: Date = Date()) -> AgentLocalMetricSnapshot {
        prune(now: now)
        return AgentLocalMetricSnapshot(
            retention: retention,
            remoteDiagnosticsSettings: remoteDiagnosticsSettings,
            events: retainedEvents,
            capturedAt: now
        )
    }

    func updateRemoteDiagnosticsSettings(_ settings: AgentRemoteDiagnosticsSettings) {
        remoteDiagnosticsSettings = settings
        if !settings.localMetricsEnabled {
            retainedEvents.removeAll(keepingCapacity: false)
            eventIDs.removeAll(keepingCapacity: false)
        }
    }

    func updateRetention(_ policy: AgentMetricRetentionPolicy, now: Date = Date()) {
        retention = policy
        prune(now: now)
    }

    private func prune(now: Date) {
        retainedEvents = Self.pruned(retainedEvents, retention: retention, now: now)
        eventIDs = Set(retainedEvents.map(\.id))
    }

    private static func pruned(
        _ events: [AgentMetricEvent],
        retention: AgentMetricRetentionPolicy,
        now: Date
    ) -> [AgentMetricEvent] {
        let cutoff = now.addingTimeInterval(-retention.maximumAge)
        // Filtering here also purges snapshots written by older builds that
        // admitted Incognito events before the boundary check above existed.
        var retainedEvents = events.filter {
            !$0.incognito && $0.timestamp >= cutoff
        }
        retainedEvents.sort {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id.uuidString < $1.id.uuidString
        }

        var remainingPerRun: [UUID: Int] = [:]
        var keptReversed: [AgentMetricEvent] = []
        for event in retainedEvents.reversed() {
            guard remainingPerRun[event.runID, default: 0] < retention.maximumEventsPerRun else {
                continue
            }
            remainingPerRun[event.runID, default: 0] += 1
            keptReversed.append(event)
        }
        retainedEvents = Array(keptReversed.reversed())
        if retainedEvents.count > retention.maximumTotalEvents {
            retainedEvents.removeFirst(retainedEvents.count - retention.maximumTotalEvents)
        }
        return retainedEvents
    }

    private static func validate(_ event: AgentMetricEvent) throws {
        guard event.schemaVersion == AgentMetricEvent.schemaVersion else {
            throw AgentMetricStoreError.invalidMetric("schemaVersion")
        }
        let value: Int64?
        let identifier: String?
        switch event.payload {
        case .providerLatency(let milliseconds, let providerID),
             .timeToFirstToken(let milliseconds, let providerID):
            value = milliseconds
            identifier = providerID
        case .toolLatency(let milliseconds, let toolName, _):
            value = milliseconds
            identifier = toolName
        case .retry(let providerID, _):
            value = nil
            identifier = providerID
        case .approval(_, let waitMilliseconds):
            value = waitMilliseconds
            identifier = nil
        case .resourcePeak(_, let peak):
            value = peak
            identifier = nil
        case .providerUsage(let link):
            value = nil
            identifier = link.providerID
        case .failure, .limit, .recovery:
            value = nil
            identifier = nil
        }
        if let value, value < 0 { throw AgentMetricStoreError.invalidMetric("negativeValue") }
        if let identifier,
           identifier.isEmpty || identifier.utf8.count > 256 {
            throw AgentMetricStoreError.invalidMetric("identifier")
        }
    }
}

// MARK: - Retry safety

nonisolated enum AgentToolIdempotency: String, Codable, Equatable, Sendable {
    case idempotent
    case nonIdempotent
}

nonisolated enum AgentToolRetryReason: String, Codable, Equatable, Sendable {
    case transientFailure
    case ambiguousTimeout
    case metricSampling
}

nonisolated enum AgentToolRetryDenialReason: String, Codable, Equatable, Sendable {
    case metricsNeverJustifyRetry
    case ambiguousNonIdempotentOutcome
    case sideEffectAlreadyCommitted
}

nonisolated enum AgentToolRetrySafetyDecision: Codable, Equatable, Sendable {
    case allowed
    case denied(AgentToolRetryDenialReason)
}

nonisolated struct AgentToolRetryGuard: Sendable {
    func decision(
        idempotency: AgentToolIdempotency,
        reason: AgentToolRetryReason,
        sideEffectCommitted: Bool
    ) -> AgentToolRetrySafetyDecision {
        if reason == .metricSampling { return .denied(.metricsNeverJustifyRetry) }
        if sideEffectCommitted { return .denied(.sideEffectAlreadyCommitted) }
        if reason == .ambiguousTimeout, idempotency == .nonIdempotent {
            return .denied(.ambiguousNonIdempotentOutcome)
        }
        return .allowed
    }
}

// MARK: - Previewable, privacy-safe diagnostic bundles

nonisolated enum AgentDiagnosticBundleError: Error, Equatable, Sendable {
    case invalidLimit(String)
    case explicitContentConsentRequired
    case bundleTooLarge(maximumBytes: Int)
    case safetyValidationFailed([AgentDiagnosticSafetyFinding])
    case destinationMustBeFileURL
    case destinationExists
    case writeFailed
}

nonisolated struct AgentDiagnosticBundleLimits: Codable, Equatable, Sendable {
    let maximumTimelineEntries: Int
    let maximumMetricEvents: Int
    let maximumErrors: Int
    let maximumContentItems: Int
    let maximumContentTextBytesPerItem: Int
    let maximumConfigurationDepth: Int
    let maximumBundleBytes: Int

    init(
        maximumTimelineEntries: Int = 2_000,
        maximumMetricEvents: Int = 5_000,
        maximumErrors: Int = 200,
        maximumContentItems: Int = 20,
        maximumContentTextBytesPerItem: Int = 64 * 1_024,
        maximumConfigurationDepth: Int = 8,
        maximumBundleBytes: Int = 2 * 1_024 * 1_024
    ) throws {
        let values = [
            maximumTimelineEntries,
            maximumMetricEvents,
            maximumErrors,
            maximumContentItems,
            maximumContentTextBytesPerItem,
            maximumConfigurationDepth,
            maximumBundleBytes,
        ]
        guard values.allSatisfy({ $0 > 0 }) else {
            throw AgentDiagnosticBundleError.invalidLimit("diagnosticBundle")
        }
        self.maximumTimelineEntries = maximumTimelineEntries
        self.maximumMetricEvents = maximumMetricEvents
        self.maximumErrors = maximumErrors
        self.maximumContentItems = maximumContentItems
        self.maximumContentTextBytesPerItem = maximumContentTextBytesPerItem
        self.maximumConfigurationDepth = maximumConfigurationDepth
        self.maximumBundleBytes = maximumBundleBytes
    }
}

nonisolated struct AgentDiagnosticVersionInfo: Codable, Equatable, Sendable {
    let appVersion: String
    let buildVersion: String
    let operatingSystem: String
    let architecture: String
    let agentSchemaVersion: Int
}

nonisolated struct AgentDiagnosticTimelineInput: Codable, Equatable, Sendable {
    let runID: UUID
    let parentRunID: UUID?
    let entryPoint: AgentRunEntryPoint
    let status: AgentRunStatus
    let startedAt: Date?
    let finishedAt: Date?
    let targetURL: String?
    let incognito: Bool
}

nonisolated struct AgentDiagnosticErrorInput: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let runID: UUID
    let category: AgentFailureCategory
    let code: String
    let message: String?
    let sourceURL: String?
    let incognito: Bool
}

nonisolated enum AgentDiagnosticContentKind: String, Codable, Equatable, Sendable {
    case prompt
    case modelText
    case pageBody
    case fileBody
    case mcpBody
    case screenshotDescription
}

nonisolated struct AgentDiagnosticContentInput: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let runID: UUID
    let kind: AgentDiagnosticContentKind
    let text: String
    let incognito: Bool
}

nonisolated struct AgentDiagnosticPrivacyOptions: Codable, Equatable, Sendable {
    let explicitContentConsent: Bool
    let selectedContentIDs: Set<UUID>
    let selectedErrorMessageIDs: Set<UUID>

    init(
        explicitContentConsent: Bool = false,
        selectedContentIDs: Set<UUID> = [],
        selectedErrorMessageIDs: Set<UUID> = []
    ) {
        self.explicitContentConsent = explicitContentConsent
        self.selectedContentIDs = selectedContentIDs
        self.selectedErrorMessageIDs = selectedErrorMessageIDs
    }
}

nonisolated struct AgentObservabilityDiagnosticRequest: Sendable {
    let versions: AgentDiagnosticVersionInfo
    let configuration: [String: JSONValue]
    let timeline: [AgentDiagnosticTimelineInput]
    let metricEvents: [AgentMetricEvent]
    let errors: [AgentDiagnosticErrorInput]
    let content: [AgentDiagnosticContentInput]
    let configuredSecrets: [String]
    let generatedAt: Date

    init(
        versions: AgentDiagnosticVersionInfo,
        configuration: [String: JSONValue],
        timeline: [AgentDiagnosticTimelineInput],
        metricEvents: [AgentMetricEvent],
        errors: [AgentDiagnosticErrorInput],
        content: [AgentDiagnosticContentInput],
        configuredSecrets: [String],
        generatedAt: Date = Date()
    ) {
        self.versions = versions
        self.configuration = configuration
        self.timeline = timeline
        self.metricEvents = metricEvents
        self.errors = errors
        self.content = content
        self.configuredSecrets = configuredSecrets
        self.generatedAt = generatedAt
    }
}

nonisolated indirect enum AgentDiagnosticConfigurationValueShape: Codable, Equatable, Sendable {
    case null
    case boolean
    case number
    case string
    case array(elementShapes: [AgentDiagnosticConfigurationValueShape])
    case object(fields: [AgentDiagnosticConfigurationField])
    case depthLimit
}

nonisolated struct AgentDiagnosticConfigurationField: Codable, Equatable, Sendable {
    let name: String
    let shape: AgentDiagnosticConfigurationValueShape
}

nonisolated struct AgentDiagnosticConfigurationShape: Codable, Equatable, Sendable {
    let fields: [AgentDiagnosticConfigurationField]
}

nonisolated struct AgentDiagnosticTimelineRecord: Codable, Equatable, Sendable {
    let runID: UUID
    let parentRunID: UUID?
    let entryPoint: AgentRunEntryPoint
    let status: AgentRunStatus
    let startedAt: Date?
    let finishedAt: Date?
    let targetOrigin: String?
    let incognito: Bool
}

nonisolated struct AgentDiagnosticErrorRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let runID: UUID
    let category: AgentFailureCategory
    let code: String
    let message: String?
    let sourceOrigin: String?
    let incognito: Bool
}

nonisolated struct AgentDiagnosticContentRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let runID: UUID
    let kind: AgentDiagnosticContentKind
    let redactedText: String
    let truncated: Bool
}

nonisolated struct AgentDiagnosticBundleManifest: Codable, Equatable, Sendable {
    let redactionPolicy: String
    let remoteUploadPerformed: Bool
    let includedContentCount: Int
    let omittedContentCount: Int
    let omittedIncognitoContentCount: Int
    let incognitoContentIncluded: Bool
    let includedErrorMessageCount: Int
    let omittedTimelineEntryCount: Int
    let omittedMetricEventCount: Int
    let omittedErrorCount: Int
}

nonisolated struct AgentObservabilityDiagnosticBundle: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Date
    let manifest: AgentDiagnosticBundleManifest
    let versions: AgentDiagnosticVersionInfo
    let configurationShape: AgentDiagnosticConfigurationShape
    let timeline: [AgentDiagnosticTimelineRecord]
    let metrics: AgentObservabilityDashboard
    let selectedErrors: [AgentDiagnosticErrorRecord]
    let explicitlyIncludedContent: [AgentDiagnosticContentRecord]
}

nonisolated enum AgentDiagnosticSafetyFinding: String, Codable, Equatable, Sendable {
    case configuredSecret
    case authorizationHeader
    case bearerCredential
    case secretAssignment
    case fullURL
}

nonisolated struct AgentObservabilityDiagnosticPreview: Equatable, Sendable {
    let manifest: AgentDiagnosticBundleManifest
    let jsonData: Data
    let sha256: String
    let safetyFindings: [AgentDiagnosticSafetyFinding]
}

nonisolated struct AgentObservabilityDiagnosticGenerator: Sendable {
    let limits: AgentDiagnosticBundleLimits

    init(limits: AgentDiagnosticBundleLimits = try! AgentDiagnosticBundleLimits()) {
        self.limits = limits
    }

    func preview(
        request: AgentObservabilityDiagnosticRequest,
        options: AgentDiagnosticPrivacyOptions = AgentDiagnosticPrivacyOptions()
    ) throws -> AgentObservabilityDiagnosticPreview {
        guard options.explicitContentConsent
                || (options.selectedContentIDs.isEmpty && options.selectedErrorMessageIDs.isEmpty) else {
            throw AgentDiagnosticBundleError.explicitContentConsentRequired
        }
        let redactor = AgentObservabilityDiagnosticRedactor(
            configuredSecrets: request.configuredSecrets
        )
        let timelineInputs = request.timeline.sorted {
            let lhs = $0.startedAt ?? .distantPast
            let rhs = $1.startedAt ?? .distantPast
            if lhs != rhs { return lhs < rhs }
            return $0.runID.uuidString < $1.runID.uuidString
        }
        let selectedTimeline = Array(timelineInputs.prefix(limits.maximumTimelineEntries))
        let timeline = selectedTimeline.map { input in
            AgentDiagnosticTimelineRecord(
                runID: input.runID,
                parentRunID: input.parentRunID,
                entryPoint: input.entryPoint,
                status: input.status,
                startedAt: input.startedAt,
                finishedAt: input.finishedAt,
                targetOrigin: input.incognito ? nil : input.targetURL.map(redactor.originOnly),
                incognito: input.incognito
            )
        }

        let nonIncognitoMetrics = request.metricEvents.filter { !$0.incognito }.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id.uuidString < $1.id.uuidString
        }
        let selectedMetrics = Array(nonIncognitoMetrics.suffix(limits.maximumMetricEvents))
        let dashboard = AgentObservabilityProjector.dashboard(
            events: selectedMetrics,
            at: request.generatedAt
        )

        let sortedErrors = request.errors.sorted {
            if $0.runID != $1.runID { return $0.runID.uuidString < $1.runID.uuidString }
            return $0.id.uuidString < $1.id.uuidString
        }
        let selectedErrorInputs = Array(sortedErrors.prefix(limits.maximumErrors))
        let errors = selectedErrorInputs.map { input in
            let includesMessage = options.explicitContentConsent
                && options.selectedErrorMessageIDs.contains(input.id)
                && !input.incognito
            return AgentDiagnosticErrorRecord(
                id: input.id,
                runID: input.runID,
                category: input.category,
                code: redactor.redactAndBound(input.code, maximumBytes: 256).text,
                message: includesMessage
                    ? input.message.map {
                        redactor.redactAndBound(
                            $0,
                            maximumBytes: limits.maximumContentTextBytesPerItem
                        ).text
                    }
                    : nil,
                sourceOrigin: input.incognito ? nil : input.sourceURL.map(redactor.originOnly),
                incognito: input.incognito
            )
        }

        let requestedContent = request.content.filter {
            options.explicitContentConsent && options.selectedContentIDs.contains($0.id)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let eligibleContent = requestedContent.filter { !$0.incognito }
        let selectedContent = Array(eligibleContent.prefix(limits.maximumContentItems))
        let content = selectedContent.map { input in
            let value = redactor.redactAndBound(
                input.text,
                maximumBytes: limits.maximumContentTextBytesPerItem
            )
            return AgentDiagnosticContentRecord(
                id: input.id,
                runID: input.runID,
                kind: input.kind,
                redactedText: value.text,
                truncated: value.truncated
            )
        }

        let manifest = AgentDiagnosticBundleManifest(
            redactionPolicy: options.explicitContentConsent
                ? "redacted-with-explicit-content-selection"
                : "default-metadata-only",
            remoteUploadPerformed: false,
            includedContentCount: content.count,
            omittedContentCount: request.content.count - content.count,
            omittedIncognitoContentCount: requestedContent.filter(\.incognito).count,
            incognitoContentIncluded: false,
            includedErrorMessageCount: errors.filter { $0.message != nil }.count,
            omittedTimelineEntryCount: max(0, request.timeline.count - timeline.count),
            omittedMetricEventCount: max(0, request.metricEvents.count - selectedMetrics.count),
            omittedErrorCount: max(0, request.errors.count - errors.count)
        )
        let bundle = AgentObservabilityDiagnosticBundle(
            schemaVersion: AgentObservabilityDiagnosticBundle.schemaVersion,
            generatedAt: request.generatedAt,
            manifest: manifest,
            versions: redactor.redactedVersions(request.versions),
            configurationShape: Self.configurationShape(
                request.configuration,
                redactor: redactor,
                maximumDepth: limits.maximumConfigurationDepth
            ),
            timeline: timeline,
            metrics: dashboard,
            selectedErrors: errors,
            explicitlyIncludedContent: content
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(bundle)
        guard data.count <= limits.maximumBundleBytes else {
            throw AgentDiagnosticBundleError.bundleTooLarge(maximumBytes: limits.maximumBundleBytes)
        }
        let findings = redactor.safetyFindings(in: data)
        guard findings.isEmpty else {
            throw AgentDiagnosticBundleError.safetyValidationFailed(findings)
        }
        return AgentObservabilityDiagnosticPreview(
            manifest: manifest,
            jsonData: data,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            safetyFindings: findings
        )
    }

    private static func configurationShape(
        _ configuration: [String: JSONValue],
        redactor: AgentObservabilityDiagnosticRedactor,
        maximumDepth: Int
    ) -> AgentDiagnosticConfigurationShape {
        AgentDiagnosticConfigurationShape(fields: fields(
            configuration,
            redactor: redactor,
            depth: 0,
            maximumDepth: maximumDepth
        ))
    }

    private static func fields(
        _ object: [String: JSONValue],
        redactor: AgentObservabilityDiagnosticRedactor,
        depth: Int,
        maximumDepth: Int
    ) -> [AgentDiagnosticConfigurationField] {
        object.keys.sorted().enumerated().map { index, key in
            AgentDiagnosticConfigurationField(
                name: redactor.safeConfigurationKey(key, ordinal: index),
                shape: shape(
                    object[key] ?? .null,
                    redactor: redactor,
                    depth: depth,
                    maximumDepth: maximumDepth
                )
            )
        }
    }

    private static func shape(
        _ value: JSONValue,
        redactor: AgentObservabilityDiagnosticRedactor,
        depth: Int,
        maximumDepth: Int
    ) -> AgentDiagnosticConfigurationValueShape {
        guard depth < maximumDepth else { return .depthLimit }
        switch value {
        case .null: return .null
        case .boolean: return .boolean
        case .number: return .number
        case .string: return .string
        case .array(let values):
            let unique = values.prefix(16).map {
                shape(
                    $0,
                    redactor: redactor,
                    depth: depth + 1,
                    maximumDepth: maximumDepth
                )
            }.reduce(into: [AgentDiagnosticConfigurationValueShape]()) { result, item in
                if !result.contains(item) { result.append(item) }
            }
            return .array(elementShapes: unique)
        case .object(let object):
            return .object(fields: fields(
                object,
                redactor: redactor,
                depth: depth + 1,
                maximumDepth: maximumDepth
            ))
        }
    }
}

private nonisolated struct AgentObservabilityDiagnosticRedactor: Sendable {
    private let configuredSecrets: [String]

    init(configuredSecrets: [String]) {
        self.configuredSecrets = configuredSecrets
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }

    func redactedVersions(_ versions: AgentDiagnosticVersionInfo) -> AgentDiagnosticVersionInfo {
        AgentDiagnosticVersionInfo(
            appVersion: redactAndBound(versions.appVersion, maximumBytes: 64).text,
            buildVersion: redactAndBound(versions.buildVersion, maximumBytes: 64).text,
            operatingSystem: redactAndBound(versions.operatingSystem, maximumBytes: 128).text,
            architecture: redactAndBound(versions.architecture, maximumBytes: 64).text,
            agentSchemaVersion: versions.agentSchemaVersion
        )
    }

    func safeConfigurationKey(_ key: String, ordinal: Int) -> String {
        if Self.matches(
            #"(?i)(?:api.?key|authorization|bearer|cookie|password|secret|token|credential)"#,
            in: key
        ) {
            return "sensitiveField\(ordinal + 1)"
        }
        return redactAndBound(key, maximumBytes: 128).text
    }

    func originOnly(_ text: String) -> String {
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return "[URL omitted]"
        }
        var origin = "\(scheme)://\(host)"
        if let port = components.port { origin += ":\(port)" }
        return replaceConfiguredSecrets(in: origin)
    }

    func redactAndBound(_ text: String, maximumBytes: Int) -> (text: String, truncated: Bool) {
        let redacted = redact(text)
        let data = Data(redacted.utf8)
        guard data.count > maximumBytes else { return (redacted, false) }
        let marker = " [truncated]"
        let markerBytes = Data(marker.utf8)
        let prefixCount = max(0, maximumBytes - markerBytes.count)
        let prefix = String(decoding: data.prefix(prefixCount), as: UTF8.self)
        return (prefix + marker, true)
    }

    func redact(_ text: String) -> String {
        var result = replaceConfiguredSecrets(in: text)
        result = Self.replacingMatches(
            #"(?i)https?://[^\s<>\"\\]+"#,
            in: result
        ) { candidate in
            originOnly(candidate.trimmingCharacters(in: CharacterSet(charactersIn: ".,);]")))
        }
        result = Self.replacingMatches(
            #"(?i)(?:authorization|proxy-authorization|cookie|set-cookie)\s*:\s*[^\r\n]+"#,
            in: result
        ) { _ in "[credential redacted]" }
        result = Self.replacingMatches(
            #"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#,
            in: result
        ) { _ in "[credential redacted]" }
        result = Self.replacingMatches(
            #"(?i)\b(?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|password|secret|token)\s*[:=]\s*[^\s,;]+"#,
            in: result
        ) { _ in "[credential redacted]" }
        result = Self.replacingMatches(
            #"\bsk-[A-Za-z0-9_-]{8,}\b"#,
            in: result
        ) { _ in "[credential redacted]" }
        return result
    }

    func safetyFindings(in data: Data) -> [AgentDiagnosticSafetyFinding] {
        let text = String(decoding: data, as: UTF8.self)
        var findings: [AgentDiagnosticSafetyFinding] = []
        if configuredSecrets.contains(where: { text.contains($0) }) {
            findings.append(.configuredSecret)
        }
        if Self.matches(#"(?i)(?:authorization|proxy-authorization)\s*:"#, in: text) {
            findings.append(.authorizationHeader)
        }
        if Self.matches(#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#, in: text) {
            findings.append(.bearerCredential)
        }
        if Self.matches(
            #"(?i)\b(?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|password|secret|token)\s*[:=]"#,
            in: text
        ) {
            findings.append(.secretAssignment)
        }
        if Self.containsFullURL(text) { findings.append(.fullURL) }
        return findings
    }

    private func replaceConfiguredSecrets(in text: String) -> String {
        configuredSecrets.reduce(text) { partial, secret in
            partial.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
    }

    private static func containsFullURL(_ text: String) -> Bool {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)https?://[^\s<>\"\\]+"#
        ) else { return true }
        let matches = expression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let candidate = String(text[range]).trimmingCharacters(
                in: CharacterSet(charactersIn: ".,);]" )
            )
            guard let components = URLComponents(string: candidate) else { return true }
            if !components.path.isEmpty && components.path != "/" { return true }
            if components.query != nil || components.fragment != nil
                || components.user != nil || components.password != nil { return true }
        }
        return false
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return true }
        return expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ) != nil
    }

    private static func replacingMatches(
        _ pattern: String,
        in text: String,
        replacement: (String) -> String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return "[redacted]"
        }
        var result = text
        let matches = expression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement(String(result[range])))
        }
        return result
    }
}

nonisolated protocol AgentDiagnosticBundleWriting: Sendable {
    func write(_ data: Data, to destination: URL) throws
}

nonisolated struct AgentAtomicDiagnosticBundleWriter: AgentDiagnosticBundleWriting {
    func write(_ data: Data, to destination: URL) throws {
        guard destination.isFileURL else {
            throw AgentDiagnosticBundleError.destinationMustBeFileURL
        }
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else {
            throw AgentDiagnosticBundleError.destinationExists
        }
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = parent.appendingPathComponent(
            ".agent-diagnostic-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try data.write(to: temporary, options: [.atomic])
            try manager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporary.path
            )
            try manager.moveItem(at: temporary, to: destination)
            try manager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        } catch {
            try? manager.removeItem(at: temporary)
            if manager.fileExists(atPath: destination.path) {
                try? manager.removeItem(at: destination)
            }
            throw AgentDiagnosticBundleError.writeFailed
        }
    }
}

nonisolated struct AgentDiagnosticExportReceipt: Codable, Equatable, Sendable {
    let destination: URL
    let byteCount: Int
    let sha256: String
}

nonisolated struct AgentObservabilityDiagnosticExporter<Writer: AgentDiagnosticBundleWriting>: Sendable {
    let writer: Writer

    init(writer: Writer) {
        self.writer = writer
    }

    func export(
        _ preview: AgentObservabilityDiagnosticPreview,
        to destination: URL
    ) throws -> AgentDiagnosticExportReceipt {
        guard preview.safetyFindings.isEmpty else {
            throw AgentDiagnosticBundleError.safetyValidationFailed(preview.safetyFindings)
        }
        try writer.write(preview.jsonData, to: destination)
        return AgentDiagnosticExportReceipt(
            destination: destination,
            byteCount: preview.jsonData.count,
            sha256: preview.sha256
        )
    }
}
