import CryptoKit
import Foundation

nonisolated enum AgentTimelineCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case model
    case tool
    case approval
    case handoff
    case state
    case artifact
    case usage
    case error
}

nonisolated struct AgentTimelineRunSummary: Equatable, Identifiable, Sendable {
    let id: UUID
    let conversationID: UUID?
    let taskDefinitionID: UUID?
    let parentRunID: UUID?
    let entryPoint: AgentRunEntryPoint
    let status: AgentRunStatus
    let createdAt: Date
    let lastUpdatedAt: Date
    let incognito: Bool
}

nonisolated struct AgentTimelineItem: Equatable, Identifiable, Sendable {
    let id: UUID
    let runID: UUID
    let entryPoint: AgentRunEntryPoint
    let sequence: Int
    let timestamp: Date
    let category: AgentTimelineCategory
    let kind: AgentStepKind
    let summary: String
    let redactionState: AgentRedactionState
    let artifactID: UUID?
    let policyDecisionStepID: UUID?

    var accessibilityDescription: String {
        let privacy = switch redactionState {
        case .metadataOnly: "metadata only"
        case .redacted: "redacted"
        case .retained: "retained"
        case .expired: "expired"
        }
        return "\(entryPoint.displayName) run, \(kind.displayName), \(summary), \(privacy)"
    }
}

nonisolated struct AgentTimelineProjection: Equatable, Sendable {
    let runs: [AgentTimelineRunSummary]
    let items: [AgentTimelineItem]
    let artifacts: [AgentTimelineArtifactSummary]
    let validationIssues: [AgentTimelineValidationIssue]

    func sourceStep(for artifactID: UUID) -> AgentTimelineItem? {
        guard let sourceID = artifacts.first(where: { $0.id == artifactID })?.sourceStepID else {
            return nil
        }
        return items.first { $0.id == sourceID }
    }

    func policyDecision(for itemID: UUID) -> AgentTimelineItem? {
        guard let decisionID = items.first(where: { $0.id == itemID })?.policyDecisionStepID else {
            return nil
        }
        return items.first { $0.id == decisionID && $0.kind == .policyDecision }
    }
}

nonisolated struct AgentTimelineProjector: Sendable {
    func project(
        runs: [AgentRun],
        stepsByRun: [UUID: [AgentStep]],
        artifacts: [AgentTimelineArtifactInput],
        incognitoArtifactOptInRunIDs: Set<UUID> = []
    ) -> AgentTimelineProjection {
        let orderedRuns = runs.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let runByID = Dictionary(grouping: orderedRuns, by: \.id).compactMapValues(\.first)
        var itemsByRun: [UUID: [AgentTimelineItem]] = [:]
        for run in orderedRuns where itemsByRun[run.id] == nil {
            let items = stepsByRun[run.id, default: []].map { step in
                AgentTimelineItem(
                    id: step.id,
                    runID: run.id,
                    entryPoint: run.entryPoint,
                    sequence: step.sequence,
                    timestamp: step.timestamp,
                    category: Self.category(for: step.kind),
                    kind: step.kind,
                    summary: step.summary,
                    redactionState: step.redactionState,
                    artifactID: step.artifactID,
                    policyDecisionStepID: step.policyDecisionStepID
                )
            }.sorted {
                if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
                return $0.id.uuidString < $1.id.uuidString
            }
            itemsByRun[run.id] = items
        }
        let items = Self.mergeByTimePreservingRunSequence(itemsByRun)

        let artifactSummaries = artifacts.map { input in
            AgentTimelineArtifactSummary(
                input: input,
                run: runByID[input.artifact.runID],
                optedIn: incognitoArtifactOptInRunIDs.contains(input.artifact.runID)
            )
        }

        return AgentTimelineProjection(
            runs: orderedRuns.map(AgentTimelineRunSummary.init),
            items: items,
            artifacts: artifactSummaries,
            validationIssues: AgentTimelineValidator().validate(
                runs: orderedRuns,
                stepsByRun: stepsByRun,
                artifacts: artifacts
            )
        )
    }

    private static func category(for kind: AgentStepKind) -> AgentTimelineCategory {
        switch kind {
        case .userMessage, .modelText, .modelToolCall: .model
        case .toolInvocation, .toolResult: .tool
        case .policyDecision, .approvalRequest, .approvalResponse: .approval
        case .handoff: .handoff
        case .stateTransition, .system: .state
        case .artifact: .artifact
        case .usage: .usage
        case .limit, .warning, .error: .error
        }
    }

    private static func mergeByTimePreservingRunSequence(
        _ itemsByRun: [UUID: [AgentTimelineItem]]
    ) -> [AgentTimelineItem] {
        var cursors = Dictionary(uniqueKeysWithValues: itemsByRun.keys.map { ($0, 0) })
        var result: [AgentTimelineItem] = []
        result.reserveCapacity(itemsByRun.values.reduce(0) { $0 + $1.count })
        while true {
            let next = itemsByRun.compactMap { runID, items -> AgentTimelineItem? in
                guard let cursor = cursors[runID], items.indices.contains(cursor) else { return nil }
                return items[cursor]
            }.min {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                return $0.runID.uuidString < $1.runID.uuidString
            }
            guard let next else { return result }
            result.append(next)
            cursors[next.runID, default: 0] += 1
        }
    }
}

/// The single read path for attended, scheduled, local MCP, command-line, and
/// child Runs. Artifact inventory is supplied separately so opening history
/// never causes content bodies or replay frames to be read.
nonisolated struct AgentTimelineService: Sendable {
    let store: AgentRunStore

    init(store: AgentRunStore) {
        self.store = store
    }

    func load(
        query: AgentRunQuery = AgentRunQuery(),
        artifacts: [AgentTimelineArtifactInput] = [],
        incognitoArtifactOptInRunIDs: Set<UUID> = []
    ) async throws -> AgentTimelineProjection {
        let runs = await store.listRuns(matching: query)
        var stepsByRun: [UUID: [AgentStep]] = [:]
        for run in runs {
            stepsByRun[run.id] = try await store.steps(runID: run.id)
        }
        return AgentTimelineProjector().project(
            runs: runs,
            stepsByRun: stepsByRun,
            artifacts: artifacts,
            incognitoArtifactOptInRunIDs: incognitoArtifactOptInRunIDs
        )
    }
}

private nonisolated extension AgentTimelineRunSummary {
    init(_ run: AgentRun) {
        id = run.id
        conversationID = run.conversationID
        taskDefinitionID = run.taskDefinitionID
        parentRunID = run.parentRunID
        entryPoint = run.entryPoint
        status = run.status
        createdAt = run.createdAt
        lastUpdatedAt = run.lastUpdatedAt
        incognito = run.incognito
    }
}

private nonisolated extension AgentRunEntryPoint {
    var displayName: String {
        switch self {
        case .attended: "Attended"
        case .scheduled: "Scheduled"
        case .localMCP: "Local MCP"
        case .commandLine: "Command line"
        case .childRun: "Child"
        }
    }
}

private nonisolated extension AgentStepKind {
    var displayName: String {
        rawValue.reduce(into: "") { result, character in
            if character.isUppercase { result.append(" ") }
            result.append(character.lowercased())
        }
    }
}

// Keeping artifact presence separate from its metadata lets all entry points
// project the same timeline without reaching into persistence details.
nonisolated struct AgentTimelineArtifactInput: Equatable, Sendable {
    let artifact: AgentArtifact
    let storageObservation: AgentArtifactStorageObservation
    let frame: AgentReplayFrameMetadata?

    init(
        artifact: AgentArtifact,
        storageObservation: AgentArtifactStorageObservation,
        frame: AgentReplayFrameMetadata? = nil
    ) {
        self.artifact = artifact
        self.storageObservation = storageObservation
        self.frame = frame
    }
}

nonisolated enum AgentArtifactStorageObservation: Equatable, Sendable {
    case present
    case missing
}

nonisolated struct AgentReplayViewport: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let scale: Double
}

nonisolated enum AgentReplayCapturePosition: String, Codable, Equatable, Hashable, Sendable {
    case beforeMutation
    case afterMutation
}

nonisolated struct AgentReplayCapturePolicy: Sendable {
    func positions(
        for run: AgentRun,
        descriptor: AgentToolDescriptor,
        page: AgentPageTarget,
        incognitoOptIn: Bool = false
    ) -> Set<AgentReplayCapturePosition> {
        guard !run.incognito || incognitoOptIn,
              page.session != .incognito || incognitoOptIn else {
            return []
        }
        switch descriptor.risk {
        case .observe:
            return []
        case .navigate:
            return [.afterMutation]
        case .mutateLocal, .externalEffect, .destructive:
            return [.beforeMutation, .afterMutation]
        }
    }

    func positions(
        for run: AgentRun,
        descriptor: AgentToolDescriptor,
        context: AgentInvocationContext,
        incognitoOptIn: Bool = false
    ) -> Set<AgentReplayCapturePosition> {
        guard run.id == context.runID,
              case .page(let page) = context.target else {
            return []
        }
        return positions(
            for: run,
            descriptor: descriptor,
            page: page,
            incognitoOptIn: incognitoOptIn
        )
    }
}

nonisolated struct AgentReplayFrameMetadata: Codable, Equatable, Sendable {
    let artifactID: UUID
    let pageHandle: PageHandle
    let urlOrigin: String
    let viewport: AgentReplayViewport
    let capturePosition: AgentReplayCapturePosition
}

nonisolated enum AgentTimelineArtifactAvailability: String, Codable, Equatable, Sendable {
    case available
    case missing
    case expired
    case redacted
    case notRetained
}

/// An opaque, metadata-only token. Artifact bytes are loaded only when the
/// user explicitly opens a replay item through `AgentArtifactReader`.
nonisolated struct AgentArtifactLocator: Codable, Equatable, Sendable {
    let runID: UUID
    let artifactID: UUID
    let relativePath: String
    let expectedByteCount: Int
    let sha256: String
}

nonisolated struct AgentTimelineArtifactSummary: Equatable, Identifiable, Sendable {
    let id: UUID
    let runID: UUID
    let sourceStepID: UUID
    let contentType: String
    let byteCount: Int
    let redactionState: AgentRedactionState
    let availability: AgentTimelineArtifactAvailability
    let frame: AgentReplayFrameMetadata?
    let locator: AgentArtifactLocator?

    var accessibilityDescription: String {
        var parts = [
            frame == nil ? "Artifact" : "Replay frame",
            availability.displayName,
            contentType,
            "\(byteCount) bytes",
            "linked to step \(sourceStepID.uuidString)",
        ]
        if let frame {
            parts.append("Page \(frame.pageHandle.description)")
            parts.append(Self.safeOriginLabel(frame.urlOrigin))
            parts.append(frame.capturePosition == .beforeMutation ? "before mutation" : "after mutation")
        }
        return parts.joined(separator: ", ")
    }

    init(input: AgentTimelineArtifactInput, run: AgentRun?, optedIn: Bool) {
        let artifact = input.artifact
        id = artifact.id
        runID = artifact.runID
        sourceStepID = artifact.sourceStepID
        contentType = artifact.contentType
        byteCount = artifact.byteCount
        redactionState = artifact.redactionState

        let incognitoIsNonretaining = run?.incognito == true && !optedIn
        frame = incognitoIsNonretaining ? nil : input.frame
        availability = if incognitoIsNonretaining {
            .notRetained
        } else {
            switch artifact.redactionState {
            case .metadataOnly: .notRetained
            case .redacted: .redacted
            case .expired: .expired
            case .retained:
                input.storageObservation == .present ? .available : .missing
            }
        }

        if availability == .available,
           Self.isSafeRelativePath(artifact.relativePath) {
            locator = AgentArtifactLocator(
                runID: artifact.runID,
                artifactID: artifact.id,
                relativePath: artifact.relativePath,
                expectedByteCount: artifact.byteCount,
                sha256: artifact.sha256
            )
        } else {
            locator = nil
        }
    }

    fileprivate static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    private static func safeOriginLabel(_ value: String) -> String {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme else { return "invalid origin" }
        if let host = components.host {
            var origin = "\(scheme.lowercased())://\(host.lowercased())"
            if let port = components.port { origin += ":\(port)" }
            return origin
        }
        return scheme.lowercased()
    }
}

private nonisolated extension AgentTimelineArtifactAvailability {
    var displayName: String {
        switch self {
        case .available: "available"
        case .missing: "missing"
        case .expired: "expired"
        case .redacted: "redacted"
        case .notRetained: "not retained"
        }
    }
}

nonisolated enum AgentTimelineValidationCode: String, Codable, Equatable, Sendable {
    case duplicateRun
    case stepsForUnknownRun
    case mismatchedStepRun
    case duplicateStep
    case nonMonotonicSequence
    case duplicateArtifact
    case artifactRunMissing
    case artifactSourceNotUnique
    case artifactBacklinkMismatch
    case unsafeArtifactPath
    case frameArtifactMismatch
    case invalidFrameOrigin
    case invalidFrameViewport
    case mutationMissingPolicyDecision
    case invalidPolicyDecisionLink
}

nonisolated struct AgentTimelineValidationIssue: Equatable, Identifiable, Sendable {
    let id: String
    let code: AgentTimelineValidationCode
    let runID: UUID?
    let stepID: UUID?
    let artifactID: UUID?
    let detail: String

    init(
        code: AgentTimelineValidationCode,
        runID: UUID? = nil,
        stepID: UUID? = nil,
        artifactID: UUID? = nil,
        detail: String
    ) {
        self.code = code
        self.runID = runID
        self.stepID = stepID
        self.artifactID = artifactID
        self.detail = detail
        id = [
            code.rawValue,
            runID?.uuidString ?? "-",
            stepID?.uuidString ?? "-",
            artifactID?.uuidString ?? "-",
            detail,
        ].joined(separator: ":")
    }
}

nonisolated struct AgentTimelineValidator: Sendable {
    func validate(
        runs: [AgentRun],
        stepsByRun: [UUID: [AgentStep]],
        artifacts: [AgentTimelineArtifactInput]
    ) -> [AgentTimelineValidationIssue] {
        var issues: [AgentTimelineValidationIssue] = []
        let groupedRuns = Dictionary(grouping: runs, by: \.id)
        let runIDs = Set(groupedRuns.keys)
        for (runID, duplicates) in groupedRuns where duplicates.count != 1 {
            issues.append(.init(
                code: .duplicateRun,
                runID: runID,
                detail: "Run appears \(duplicates.count) times."
            ))
        }

        var allSteps: [AgentStep] = []
        for (indexedRunID, steps) in stepsByRun {
            if !runIDs.contains(indexedRunID) {
                issues.append(.init(
                    code: .stepsForUnknownRun,
                    runID: indexedRunID,
                    detail: "Step collection has no matching run."
                ))
            }
            let ordered = steps.sorted { $0.sequence < $1.sequence }
            for (offset, step) in ordered.enumerated() {
                allSteps.append(step)
                if step.runID != indexedRunID {
                    issues.append(.init(
                        code: .mismatchedStepRun,
                        runID: indexedRunID,
                        stepID: step.id,
                        detail: "Step identifies a different run."
                    ))
                }
                if step.sequence != offset {
                    issues.append(.init(
                        code: .nonMonotonicSequence,
                        runID: indexedRunID,
                        stepID: step.id,
                        detail: "Expected sequence \(offset), found \(step.sequence)."
                    ))
                }
            }
        }

        let stepsByID = Dictionary(grouping: allSteps, by: \.id)
        for (stepID, duplicates) in stepsByID where duplicates.count != 1 {
            issues.append(.init(
                code: .duplicateStep,
                runID: duplicates.first?.runID,
                stepID: stepID,
                detail: "Step identifier appears \(duplicates.count) times."
            ))
        }

        for step in allSteps where isMutation(step) {
            guard let decisionID = step.policyDecisionStepID else {
                issues.append(.init(
                    code: .mutationMissingPolicyDecision,
                    runID: step.runID,
                    stepID: step.id,
                    detail: "Mutation has no recorded policy-decision link."
                ))
                continue
            }
            guard stepsByID[decisionID]?.count == 1,
                  let decision = stepsByID[decisionID]?.first,
                  decision.runID == step.runID,
                  decision.kind == .policyDecision,
                  decision.sequence < step.sequence else {
                issues.append(.init(
                    code: .invalidPolicyDecisionLink,
                    runID: step.runID,
                    stepID: step.id,
                    detail: "Mutation policy decision is absent, ambiguous, later, or from another run."
                ))
                continue
            }
        }

        let groupedArtifacts = Dictionary(grouping: artifacts, by: { $0.artifact.id })
        for (artifactID, duplicates) in groupedArtifacts where duplicates.count != 1 {
            issues.append(.init(
                code: .duplicateArtifact,
                runID: duplicates.first?.artifact.runID,
                artifactID: artifactID,
                detail: "Artifact identifier appears \(duplicates.count) times."
            ))
        }
        for input in artifacts {
            let artifact = input.artifact
            if !runIDs.contains(artifact.runID) {
                issues.append(.init(
                    code: .artifactRunMissing,
                    runID: artifact.runID,
                    artifactID: artifact.id,
                    detail: "Artifact has no matching run."
                ))
            }
            let sources = stepsByID[artifact.sourceStepID, default: []].filter {
                $0.runID == artifact.runID
            }
            if sources.count != 1 {
                issues.append(.init(
                    code: .artifactSourceNotUnique,
                    runID: artifact.runID,
                    stepID: artifact.sourceStepID,
                    artifactID: artifact.id,
                    detail: "Artifact must resolve to exactly one source step."
                ))
            } else if input.frame == nil, sources[0].artifactID != artifact.id {
                issues.append(.init(
                    code: .artifactBacklinkMismatch,
                    runID: artifact.runID,
                    stepID: artifact.sourceStepID,
                    artifactID: artifact.id,
                    detail: "Source step does not link back to this artifact."
                ))
            } else if input.frame != nil {
                let source = sources[0]
                let productionBacklinkIsValid = source.kind == .toolInvocation
                    && source.policyDecisionStepID != nil
                let importedLegacyBacklinkIsValid = source.kind == .artifact
                    && source.artifactID == artifact.id
                if !productionBacklinkIsValid && !importedLegacyBacklinkIsValid {
                    issues.append(.init(
                        code: .artifactBacklinkMismatch,
                        runID: artifact.runID,
                        stepID: artifact.sourceStepID,
                        artifactID: artifact.id,
                        detail: "Replay frame source must be an authorized tool invocation."
                    ))
                }
            }
            if !AgentTimelineArtifactSummary.isSafeRelativePath(artifact.relativePath) {
                issues.append(.init(
                    code: .unsafeArtifactPath,
                    runID: artifact.runID,
                    artifactID: artifact.id,
                    detail: "Artifact path is not a safe run-relative path."
                ))
            }
            if let frame = input.frame {
                if frame.artifactID != artifact.id {
                    issues.append(.init(
                        code: .frameArtifactMismatch,
                        runID: artifact.runID,
                        stepID: artifact.sourceStepID,
                        artifactID: artifact.id,
                        detail: "Frame metadata identifies a different artifact."
                    ))
                }
                if !isOriginOnly(frame.urlOrigin) {
                    issues.append(.init(
                        code: .invalidFrameOrigin,
                        runID: artifact.runID,
                        stepID: artifact.sourceStepID,
                        artifactID: artifact.id,
                        detail: "Frame URL must contain an origin without path, query, user info, or fragment."
                    ))
                }
                if frame.viewport.width <= 0
                    || frame.viewport.height <= 0
                    || !frame.viewport.scale.isFinite
                    || frame.viewport.scale <= 0 {
                    issues.append(.init(
                        code: .invalidFrameViewport,
                        runID: artifact.runID,
                        stepID: artifact.sourceStepID,
                        artifactID: artifact.id,
                        detail: "Frame viewport dimensions and scale must be positive and finite."
                    ))
                }
            }
        }

        return issues.sorted { $0.id < $1.id }
    }

    private func isMutation(_ step: AgentStep) -> Bool {
        guard step.kind == .toolInvocation else { return false }
        var toolName = step.summary
        if case .object(let payload) = step.payload,
           case .string(let explicitName) = payload["tool"] {
            toolName = explicitName
        }
        if let descriptor = AgentToolCatalog.canonical.descriptor(named: toolName) {
            return descriptor.risk != .observe
        }
        guard case .object(let payload) = step.payload else { return false }
        if case .boolean(true) = payload["mutation"] { return true }
        if case .string(let risk) = payload["risk"] { return risk != AgentToolRisk.observe.rawValue }
        return false
    }

    private func isOriginOnly(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return false
        }
        if scheme == "http" || scheme == "https" { return components.host != nil }
        return !value.isEmpty
    }
}

nonisolated enum AgentRetentionPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case never
    case hours24
    case days7
    case days30
    case manual

    fileprivate var duration: TimeInterval? {
        switch self {
        case .never: 0
        case .hours24: 24 * 60 * 60
        case .days7: 7 * 24 * 60 * 60
        case .days30: 30 * 24 * 60 * 60
        case .manual: nil
        }
    }
}

nonisolated enum AgentHistoryRetentionSettings {
    enum Key {
        static let policy = "agent.history.retention"
    }

    static func policy(in defaults: UserDefaults = .standard) -> AgentRetentionPolicy {
        guard let rawValue = defaults.string(forKey: Key.policy),
              let policy = AgentRetentionPolicy(rawValue: rawValue) else {
            return .days30
        }
        return policy
    }
}

nonisolated struct AgentTemporaryArtifact: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let relativePath: String
    let createdAt: Date
    let owningRunID: UUID?

    init(
        id: UUID = UUID(),
        relativePath: String,
        createdAt: Date,
        owningRunID: UUID? = nil
    ) {
        self.id = id
        self.relativePath = relativePath
        self.createdAt = createdAt
        self.owningRunID = owningRunID
    }
}

nonisolated struct AgentRetentionRequest: Equatable, Sendable {
    var defaultPolicy: AgentRetentionPolicy
    var perRunPolicy: [UUID: AgentRetentionPolicy]
    var explicitlyDeletedRunIDs: Set<UUID>
    var incognitoArtifactOptInRunIDs: Set<UUID>
    var temporaryGracePeriod: TimeInterval

    init(
        defaultPolicy: AgentRetentionPolicy,
        perRunPolicy: [UUID: AgentRetentionPolicy] = [:],
        explicitlyDeletedRunIDs: Set<UUID> = [],
        incognitoArtifactOptInRunIDs: Set<UUID> = [],
        temporaryGracePeriod: TimeInterval = 60 * 60
    ) {
        self.defaultPolicy = defaultPolicy
        self.perRunPolicy = perRunPolicy
        self.explicitlyDeletedRunIDs = explicitlyDeletedRunIDs
        self.incognitoArtifactOptInRunIDs = incognitoArtifactOptInRunIDs
        self.temporaryGracePeriod = max(0, temporaryGracePeriod)
    }
}

nonisolated struct AgentRetentionPlan: Equatable, Sendable {
    let runIDs: Set<UUID>
    let artifactIDs: Set<UUID>
    let artifactRelativePaths: Set<String>
    let orphanTemporaryRelativePaths: Set<String>
    let rejectedUnsafeRelativePaths: Set<String>

    /// Run deletion is performed by `AgentRunStore.deleteRun`, which removes
    /// the run directory and updates both mutable indexes.
    var requiresRunIndexUpdate: Bool { !runIDs.isEmpty }
}

nonisolated struct AgentRetentionPlanner: Sendable {
    func plan(
        runs: [AgentRun],
        artifacts: [AgentArtifact],
        temporaryItems: [AgentTemporaryArtifact],
        request: AgentRetentionRequest,
        now: Date = Date()
    ) -> AgentRetentionPlan {
        let runByID = Dictionary(grouping: runs, by: \.id).compactMapValues(\.first)
        var runIDs = request.explicitlyDeletedRunIDs.intersection(runByID.keys)
        for run in runs where run.status.isTerminal {
            let policy = request.perRunPolicy[run.id] ?? request.defaultPolicy
            guard let duration = policy.duration else { continue }
            let retentionAnchor = run.finishedAt ?? run.lastUpdatedAt
            if retentionAnchor.addingTimeInterval(duration) <= now {
                runIDs.insert(run.id)
            }
        }

        var artifactIDs: Set<UUID> = []
        var artifactPaths: Set<String> = []
        var rejectedPaths: Set<String> = []
        for artifact in artifacts {
            let run = runByID[artifact.runID]
            let mustDelete = run == nil
                || runIDs.contains(artifact.runID)
                || artifact.redactionState != .retained
                || (
                    run?.incognito == true
                        && !request.incognitoArtifactOptInRunIDs.contains(artifact.runID)
                )
            guard mustDelete else { continue }
            artifactIDs.insert(artifact.id)
            if AgentTimelineArtifactSummary.isSafeRelativePath(artifact.relativePath) {
                artifactPaths.insert(artifact.relativePath)
            } else {
                rejectedPaths.insert(artifact.relativePath)
            }
        }

        var temporaryPaths: Set<String> = []
        for item in temporaryItems {
            let owner = item.owningRunID.flatMap { runByID[$0] }
            let ownerWillBeDeleted = item.owningRunID.map(runIDs.contains) ?? false
            let ownerIsOrphaned = item.owningRunID != nil && owner == nil
            let ownerIsFinished = owner?.status.isTerminal == true
            let isOldEnough = item.createdAt.addingTimeInterval(request.temporaryGracePeriod) <= now
            let shouldDelete = ownerWillBeDeleted
                || ownerIsOrphaned
                || (isOldEnough && (item.owningRunID == nil || ownerIsFinished))
            guard shouldDelete else { continue }
            if AgentTimelineArtifactSummary.isSafeRelativePath(item.relativePath) {
                temporaryPaths.insert(item.relativePath)
            } else {
                rejectedPaths.insert(item.relativePath)
            }
        }

        return AgentRetentionPlan(
            runIDs: runIDs,
            artifactIDs: artifactIDs,
            artifactRelativePaths: artifactPaths,
            orphanTemporaryRelativePaths: temporaryPaths,
            rejectedUnsafeRelativePaths: rejectedPaths
        )
    }
}

nonisolated struct AgentHistoryRetentionReport: Equatable, Sendable {
    let policy: AgentRetentionPolicy
    let deletedRunIDs: Set<UUID>
    let deletedConversationIDs: Set<UUID>
    let deletedTemporaryRelativePaths: Set<String>
    let rejectedUnsafeRelativePaths: Set<String>
}

/// Applies the generic history policy to the production Run store. Scheduled
/// policies may delete sooner; this global policy is the outer retention cap
/// for attended, scheduled, local-MCP, command-line, and child Runs alike.
/// Run deletion removes the complete directory (steps, frame/artifact
/// manifests, retained bytes, and replay journals) and updates both indexes.
nonisolated enum AgentHistoryRetentionController {
    @MainActor
    static func enforce(
        store: AgentRunStore,
        baseDirectory: URL,
        defaults: UserDefaults = .standard,
        now: Date = Date(),
        cleanupPrivateState: (Set<UUID>) async throws -> Void = { _ in }
    ) async throws -> AgentHistoryRetentionReport {
        let policy = AgentHistoryRetentionSettings.policy(in: defaults)
        let runs = await store.listRuns()
        let runsDirectory = baseDirectory
            .appendingPathComponent("agent/runs", isDirectory: true)
        let inputs = try await AgentArtifactInventoryReader(
            runsDirectory: runsDirectory
        ).inventory(runIDs: Set(runs.map(\.id)))
        let temporaryItems = try discoverTemporaryItems(
            beneath: baseDirectory,
            now: now
        )
        let plan = AgentRetentionPlanner().plan(
            runs: runs,
            artifacts: inputs.map(\.artifact),
            temporaryItems: temporaryItems,
            request: AgentRetentionRequest(defaultPolicy: policy),
            now: now
        )

        if !plan.runIDs.isEmpty {
            // Cowork staged/prior bytes must be gone before durable evidence is
            // forgotten; a cleanup failure therefore leaves the Run indexed
            // so Settings or startup enforcement can retry safely.
            try await cleanupPrivateState(plan.runIDs)
        }
        var deletedRunIDs = Set<UUID>()
        for runID in plan.runIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            do {
                try await store.deleteRun(id: runID)
                deletedRunIDs.insert(runID)
            } catch AgentRunStoreError.runNotFound(_) {
                deletedRunIDs.insert(runID)
            }
        }
        // A timed/zero-retention pass also repairs a prior interruption that
        // stopped after Run deletion but before its prompt-derived title was
        // removed. Manual retention deliberately leaves conversations alone.
        let deletedConversationIDs = if policy == .manual {
            Set<UUID>()
        } else {
            try await store.deleteUnreferencedEmptyConversations()
        }

        var deletedTemporaryPaths = Set<String>()
        for relativePath in plan.orphanTemporaryRelativePaths.sorted() {
            let target = baseDirectory.appendingPathComponent(relativePath)
                .standardizedFileURL
            guard target.path.hasPrefix(
                baseDirectory.standardizedFileURL.path + "/"
            ) else { continue }
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            deletedTemporaryPaths.insert(relativePath)
        }
        return AgentHistoryRetentionReport(
            policy: policy,
            deletedRunIDs: deletedRunIDs,
            deletedConversationIDs: deletedConversationIDs,
            deletedTemporaryRelativePaths: deletedTemporaryPaths,
            rejectedUnsafeRelativePaths: plan.rejectedUnsafeRelativePaths
        )
    }

    /// Browser response files are the only generic agent temporaries outside
    /// a Run directory. Run-local journals and staging bytes disappear with
    /// their owning Run; live response files receive the planner's one-hour
    /// grace period before being considered orphaned.
    private static func discoverTemporaryItems(
        beneath baseDirectory: URL,
        now: Date
    ) throws -> [AgentTemporaryArtifact] {
        let responseDirectory = baseDirectory.appendingPathComponent(
            "responses",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: responseDirectory.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: responseDirectory,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .creationDateKey,
                .contentModificationDateKey,
            ],
            options: []
        ).compactMap { url in
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .creationDateKey,
                .contentModificationDateKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                return nil
            }
            return AgentTemporaryArtifact(
                relativePath: "responses/\(url.lastPathComponent)",
                createdAt: values.contentModificationDate
                    ?? values.creationDate
                    ?? now
            )
        }
    }
}

nonisolated enum AgentArtifactReadError: Error, Equatable, Sendable {
    case unsafePath
    case unavailable
    case notRegularFile
    case limitExceeded
    case sizeMismatch(expected: Int, actual: Int)
    case digestMismatch
    case fileReadFailed(String)
}

nonisolated enum AgentArtifactInventoryError: Error, Equatable, Sendable {
    case malformedManifest(path: String, reason: String)
    case unsafeManifest(String)
    case manifestTooLarge(path: String, maximumBytes: Int)
    case artifactRunMismatch(artifactID: UUID, expectedRunID: UUID)
    case duplicateFrameMetadata(UUID)
}

/// Reads only the small artifact and frame manifests. File contents are never
/// opened here; existence is reported separately from cryptographic validity,
/// which is checked by `AgentArtifactReader` on explicit access.
actor AgentArtifactInventoryReader {
    private let runsDirectory: URL
    private let maximumManifestBytes: Int

    init(runsDirectory: URL, maximumManifestBytes: Int = 4 * 1_024 * 1_024) {
        self.runsDirectory = runsDirectory.standardizedFileURL
        self.maximumManifestBytes = max(0, maximumManifestBytes)
    }

    func inventory(runIDs: Set<UUID>) throws -> [AgentTimelineArtifactInput] {
        var result: [AgentTimelineArtifactInput] = []
        for runID in runIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            let runDirectory = runsDirectory.appendingPathComponent(
                runID.uuidString,
                isDirectory: true
            )
            let artifactManifest = runDirectory.appendingPathComponent("artifacts/index.json")
            guard FileManager.default.fileExists(atPath: artifactManifest.path) else { continue }
            let artifacts: [AgentArtifact] = try decodeManifest(
                [AgentArtifact].self,
                from: artifactManifest
            )
            let frameManifest = runDirectory.appendingPathComponent("frames/index.json")
            let frames: [AgentReplayFrameMetadata]
            if FileManager.default.fileExists(atPath: frameManifest.path) {
                frames = try decodeManifest([AgentReplayFrameMetadata].self, from: frameManifest)
            } else {
                frames = []
            }
            let groupedFrames = Dictionary(grouping: frames, by: \.artifactID)
            if let duplicate = groupedFrames.first(where: { $0.value.count > 1 })?.key {
                throw AgentArtifactInventoryError.duplicateFrameMetadata(duplicate)
            }
            for artifact in artifacts {
                guard artifact.runID == runID else {
                    throw AgentArtifactInventoryError.artifactRunMismatch(
                        artifactID: artifact.id,
                        expectedRunID: runID
                    )
                }
                result.append(AgentTimelineArtifactInput(
                    artifact: artifact,
                    storageObservation: observation(
                        for: artifact.relativePath,
                        runDirectory: runDirectory
                    ),
                    frame: groupedFrames[artifact.id]?.first
                ))
            }
        }
        return result
    }

    private func decodeManifest<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        do {
            let standardized = url.standardizedFileURL
            guard standardized.resolvingSymlinksInPath().standardizedFileURL == standardized else {
                throw AgentArtifactInventoryError.unsafeManifest(url.path)
            }
            let values = try standardized.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw AgentArtifactInventoryError.unsafeManifest(url.path)
            }
            guard let fileSize = values.fileSize, fileSize <= maximumManifestBytes else {
                throw AgentArtifactInventoryError.manifestTooLarge(
                    path: url.path,
                    maximumBytes: maximumManifestBytes
                )
            }
            let data = try Data(contentsOf: standardized, options: .mappedIfSafe)
            guard data.count <= maximumManifestBytes else {
                throw AgentArtifactInventoryError.manifestTooLarge(
                    path: url.path,
                    maximumBytes: maximumManifestBytes
                )
            }
            return try JSONDecoder().decode(type, from: data)
        } catch let error as AgentArtifactInventoryError {
            throw error
        } catch {
            throw AgentArtifactInventoryError.malformedManifest(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    private func observation(
        for relativePath: String,
        runDirectory: URL
    ) -> AgentArtifactStorageObservation {
        guard AgentTimelineArtifactSummary.isSafeRelativePath(relativePath) else { return .missing }
        let standardizedRun = runDirectory.standardizedFileURL
        let destination = standardizedRun
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        let parentComponents = standardizedRun.pathComponents
        guard destination.pathComponents.count > parentComponents.count,
              destination.pathComponents.prefix(parentComponents.count).elementsEqual(parentComponents),
              destination.resolvingSymlinksInPath().standardizedFileURL == destination,
              let values = try? destination.resourceValues(forKeys: [
                  .isRegularFileKey, .isSymbolicLinkKey,
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            return .missing
        }
        return .present
    }
}

/// Performs the intentionally separate, on-demand half of replay. Timeline
/// projection never calls this actor and therefore cannot eagerly read page or
/// file content while rendering history.
actor AgentArtifactReader {
    private let runsDirectory: URL

    init(runsDirectory: URL) {
        self.runsDirectory = runsDirectory.standardizedFileURL
    }

    func data(for locator: AgentArtifactLocator, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0,
              locator.expectedByteCount >= 0,
              locator.expectedByteCount <= maximumBytes else {
            throw AgentArtifactReadError.limitExceeded
        }
        guard AgentTimelineArtifactSummary.isSafeRelativePath(locator.relativePath) else {
            throw AgentArtifactReadError.unsafePath
        }

        let runDirectory = runsDirectory
            .appendingPathComponent(locator.runID.uuidString, isDirectory: true)
            .standardizedFileURL
        let destination = runDirectory
            .appendingPathComponent(locator.relativePath, isDirectory: false)
            .standardizedFileURL
        guard Self.isContained(destination, by: runDirectory) else {
            throw AgentArtifactReadError.unsafePath
        }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw AgentArtifactReadError.unavailable
        }

        do {
            let resolvedRun = runDirectory.resolvingSymlinksInPath().standardizedFileURL
            let resolvedDestination = destination.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedRun == runDirectory,
                  resolvedDestination == destination,
                  Self.isContained(resolvedDestination, by: resolvedRun) else {
                throw AgentArtifactReadError.unsafePath
            }
            let values = try destination.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isSymbolicLink != true else { throw AgentArtifactReadError.unsafePath }
            guard values.isRegularFile == true else { throw AgentArtifactReadError.notRegularFile }
            let actualSize = values.fileSize ?? -1
            guard actualSize <= maximumBytes else { throw AgentArtifactReadError.limitExceeded }
            guard actualSize == locator.expectedByteCount else {
                throw AgentArtifactReadError.sizeMismatch(
                    expected: locator.expectedByteCount,
                    actual: actualSize
                )
            }
            let data = try Data(contentsOf: destination, options: .mappedIfSafe)
            guard destination.resolvingSymlinksInPath().standardizedFileURL == destination else {
                throw AgentArtifactReadError.unsafePath
            }
            guard data.count == actualSize else {
                throw AgentArtifactReadError.sizeMismatch(
                    expected: actualSize,
                    actual: data.count
                )
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == locator.sha256.lowercased() else {
                throw AgentArtifactReadError.digestMismatch
            }
            return data
        } catch let error as AgentArtifactReadError {
            throw error
        } catch {
            throw AgentArtifactReadError.fileReadFailed(error.localizedDescription)
        }
    }

    private static func isContained(_ child: URL, by parent: URL) -> Bool {
        let parentComponents = parent.pathComponents
        let childComponents = child.pathComponents
        return childComponents.count > parentComponents.count
            && childComponents.prefix(parentComponents.count).elementsEqual(parentComponents)
    }
}

nonisolated struct AgentDiagnosticExportOptions: Equatable, Sendable {
    /// Values obtained from configured providers, MCP connections, or test
    /// fixtures. They are scrubbed in addition to the built-in credential
    /// patterns. Empty values are ignored.
    var configuredSecrets: [String]

    init(configuredSecrets: [String] = []) {
        self.configuredSecrets = configuredSecrets.filter { !$0.isEmpty }
    }
}

private nonisolated struct AgentDiagnosticBundle: Codable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let redaction: String
    let runs: [AgentDiagnosticRun]
    let artifacts: [AgentDiagnosticArtifact]
}

private nonisolated struct AgentDiagnosticRun: Codable, Sendable {
    let id: UUID
    let conversationID: UUID?
    let taskDefinitionID: UUID?
    let parentRunID: UUID?
    let entryPoint: AgentRunEntryPoint
    let status: AgentRunStatus
    let createdAt: Date
    let lastUpdatedAt: Date
    let incognito: Bool
    let toolCatalogVersion: Int
    let providerID: String?
    let model: String?
    let endpointOrigin: String?
    let steps: [AgentDiagnosticStep]
}

private nonisolated struct AgentDiagnosticStep: Codable, Sendable {
    let id: UUID
    let sequence: Int
    let timestamp: Date
    let kind: AgentStepKind
    let summary: String
    let redactionState: AgentRedactionState
    let artifactID: UUID?
    let policyDecisionStepID: UUID?
    let contentBodyOmitted: Bool
}

private nonisolated struct AgentDiagnosticArtifact: Codable, Sendable {
    let id: UUID
    let runID: UUID
    let sourceStepID: UUID
    let contentType: String
    let byteCount: Int
    let redactionState: AgentRedactionState
    let contentBodyOmitted: Bool
}

nonisolated struct AgentDiagnosticExporter: Sendable {
    func export(
        runs: [AgentRun],
        stepsByRun: [UUID: [AgentStep]],
        artifacts: [AgentArtifact],
        options: AgentDiagnosticExportOptions = AgentDiagnosticExportOptions(),
        generatedAt: Date = Date()
    ) throws -> Data {
        let redactor = AgentDiagnosticRedactor(secrets: options.configuredSecrets)
        let diagnosticRuns = runs.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }.map { run in
            let provider = run.configuration.provider
            return AgentDiagnosticRun(
                id: run.id,
                conversationID: run.conversationID,
                taskDefinitionID: run.taskDefinitionID,
                parentRunID: run.parentRunID,
                entryPoint: run.entryPoint,
                status: run.status,
                createdAt: run.createdAt,
                lastUpdatedAt: run.lastUpdatedAt,
                incognito: run.incognito,
                toolCatalogVersion: run.configuration.toolCatalogVersion,
                providerID: provider.map { redactor.redact($0.providerID) },
                model: provider.map { redactor.redact($0.model) },
                endpointOrigin: provider.map { redactor.originOnly($0.endpointIdentity) },
                steps: stepsByRun[run.id, default: []]
                    .sorted { $0.sequence < $1.sequence }
                    .map { step in
                        AgentDiagnosticStep(
                            id: step.id,
                            sequence: step.sequence,
                            timestamp: step.timestamp,
                            kind: step.kind,
                            summary: safeSummary(step, redactor: redactor),
                            redactionState: step.redactionState,
                            artifactID: step.artifactID,
                            policyDecisionStepID: step.policyDecisionStepID,
                            contentBodyOmitted: step.payload != nil || Self.isContentStep(step.kind)
                        )
                    }
            )
        }
        let diagnosticArtifacts = artifacts.sorted {
            if $0.runID != $1.runID { return $0.runID.uuidString < $1.runID.uuidString }
            return $0.id.uuidString < $1.id.uuidString
        }.map { artifact in
            AgentDiagnosticArtifact(
                id: artifact.id,
                runID: artifact.runID,
                sourceStepID: artifact.sourceStepID,
                contentType: redactor.redact(artifact.contentType),
                byteCount: artifact.byteCount,
                redactionState: artifact.redactionState,
                contentBodyOmitted: true
            )
        }
        let bundle = AgentDiagnosticBundle(
            schemaVersion: 1,
            generatedAt: generatedAt,
            redaction: "default-redacted",
            runs: diagnosticRuns,
            artifacts: diagnosticArtifacts
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(bundle)
    }

    private func safeSummary(
        _ step: AgentStep,
        redactor: AgentDiagnosticRedactor
    ) -> String {
        if Self.isContentStep(step.kind) { return "Content omitted" }
        if step.kind == .artifact { return "Artifact metadata" }
        return redactor.redact(step.summary)
    }

    private static func isContentStep(_ kind: AgentStepKind) -> Bool {
        switch kind {
        case .userMessage, .modelText, .toolResult: true
        default: false
        }
    }
}

private nonisolated struct AgentDiagnosticRedactor: Sendable {
    let secrets: [String]

    func originOnly(_ text: String) -> String {
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return "[endpoint omitted]"
        }
        var origin = "\(scheme)://\(host)"
        if let port = components.port { origin += ":\(port)" }
        return replaceSecrets(in: origin)
    }

    func redact(_ text: String) -> String {
        var result = replaceSecrets(in: text)
        result = replacingMatches(
            pattern: #"(?i)https?://[^\s<>\"]+"#,
            in: result
        ) { match in
            originOnly(match)
        }
        result = replacingMatches(
            pattern: #"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#,
            in: result
        ) { _ in "[credential redacted]" }
        result = replacingMatches(
            pattern: #"(?i)\b(?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|"#
                + #"authorization|password|secret|token)\s*[:=]\s*[^\s,;]+"#,
            in: result
        ) { _ in "[credential redacted]" }
        return result
    }

    private func replaceSecrets(in text: String) -> String {
        secrets.reduce(text) { partial, secret in
            partial.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
    }

    private func replacingMatches(
        pattern: String,
        in text: String,
        replacement: (String) -> String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
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

nonisolated enum AgentTimelineKeyboardCommand: String, Codable, Equatable, Sendable {
    case previous
    case next
    case first
    case last
    case toggleAutoplay
}

/// UI-independent playback state used by macOS keyboard commands, iPadOS
/// controls, and accessibility tests. A view can bind to this value without
/// duplicating filtering or replay cursor behavior.
nonisolated struct AgentTimelinePlaybackState: Equatable, Sendable {
    private(set) var selectedItemID: UUID?
    private(set) var isAutoplayEnabled: Bool
    private(set) var enabledCategories: Set<AgentTimelineCategory>

    init(
        items: [AgentTimelineItem],
        enabledCategories: Set<AgentTimelineCategory> = Set(AgentTimelineCategory.allCases),
        autoplay: Bool = false
    ) {
        self.enabledCategories = enabledCategories
        let visible = items.filter { enabledCategories.contains($0.category) }
        selectedItemID = visible.first?.id
        isAutoplayEnabled = autoplay && !visible.isEmpty
    }

    func visibleItems(in items: [AgentTimelineItem]) -> [AgentTimelineItem] {
        items.filter { enabledCategories.contains($0.category) }
    }

    mutating func setFilter(
        _ categories: Set<AgentTimelineCategory>,
        items: [AgentTimelineItem]
    ) {
        enabledCategories = categories
        let visible = visibleItems(in: items)
        if !visible.contains(where: { $0.id == selectedItemID }) {
            selectedItemID = visible.first?.id
        }
        if visible.isEmpty { isAutoplayEnabled = false }
    }

    mutating func reconcile(items: [AgentTimelineItem]) {
        let visible = visibleItems(in: items)
        if !visible.contains(where: { $0.id == selectedItemID }) {
            selectedItemID = visible.first?.id
        }
        if visible.isEmpty { isAutoplayEnabled = false }
    }

    mutating func handle(
        _ command: AgentTimelineKeyboardCommand,
        items: [AgentTimelineItem]
    ) {
        let visible = visibleItems(in: items)
        switch command {
        case .toggleAutoplay:
            isAutoplayEnabled = !visible.isEmpty && !isAutoplayEnabled
        case .first:
            selectedItemID = visible.first?.id
        case .last:
            selectedItemID = visible.last?.id
        case .previous:
            move(by: -1, visible: visible)
        case .next:
            move(by: 1, visible: visible)
        }
    }

    mutating func autoplayTick(items: [AgentTimelineItem]) {
        guard isAutoplayEnabled else { return }
        let visible = visibleItems(in: items)
        guard let selectedIndex = visible.firstIndex(where: { $0.id == selectedItemID }),
              visible.indices.contains(selectedIndex + 1) else {
            isAutoplayEnabled = false
            return
        }
        selectedItemID = visible[selectedIndex + 1].id
    }

    func accessibilityValue(items: [AgentTimelineItem]) -> String {
        let visible = visibleItems(in: items)
        guard let index = visible.firstIndex(where: { $0.id == selectedItemID }) else {
            return "No timeline step selected"
        }
        return "\(index + 1) of \(visible.count), \(visible[index].accessibilityDescription)"
    }

    private mutating func move(by offset: Int, visible: [AgentTimelineItem]) {
        guard !visible.isEmpty else {
            selectedItemID = nil
            isAutoplayEnabled = false
            return
        }
        guard let current = visible.firstIndex(where: { $0.id == selectedItemID }) else {
            selectedItemID = visible.first?.id
            return
        }
        let destination = min(max(visible.startIndex, current + offset), visible.index(before: visible.endIndex))
        selectedItemID = visible[destination].id
    }
}
