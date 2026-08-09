import Foundation

// AI-007 keeps schedule definitions and planning independent of SwiftUI,
// WebKit, Keychain, and provider wire formats. Integration persists the
// snapshots produced here before starting the corresponding AgentRun.

nonisolated enum AgentTaskSchedule: Codable, Equatable, Sendable {
    case interval(everySeconds: Int, anchor: Date)
    case daily(hour: Int, minute: Int)
}

nonisolated enum AgentTaskNonexistentTimePolicy: String, Codable, Equatable, Sendable {
    case skipOccurrence
    case nextValidTime
}

nonisolated enum AgentTaskRepeatedTimePolicy: String, Codable, Equatable, Sendable {
    case firstOccurrence
    case lastOccurrence
}

nonisolated struct AgentTaskDaylightSavingPolicy: Codable, Equatable, Sendable {
    var nonexistentTime: AgentTaskNonexistentTimePolicy
    var repeatedTime: AgentTaskRepeatedTimePolicy

    init(
        nonexistentTime: AgentTaskNonexistentTimePolicy,
        repeatedTime: AgentTaskRepeatedTimePolicy
    ) {
        self.nonexistentTime = nonexistentTime
        self.repeatedTime = repeatedTime
    }
}

nonisolated struct AgentTaskBrowserScope: Codable, Equatable, Sendable {
    var pageIDs: Set<String>
    var origins: Set<String>
    var session: AgentBrowserSession

    init(
        pageIDs: Set<String> = [],
        origins: Set<String> = [],
        session: AgentBrowserSession = .normal
    ) {
        self.pageIDs = pageIDs
        self.origins = origins
        self.session = session
    }
}

/// Persistable execution authority. Secrets and security-scoped bookmark data
/// are intentionally unrepresentable: integrations resolve opaque IDs at run
/// time and keep credentials in Keychain.
nonisolated struct AgentTaskExecutionSnapshot: Codable, Equatable, Sendable {
    var provider: AgentProviderSnapshot
    var browserScope: AgentTaskBrowserScope
    var capabilities: Set<AgentCapability>
    var mcpConnectionIDs: Set<UUID>
    var coworkRootID: UUID?

    init(
        provider: AgentProviderSnapshot,
        browserScope: AgentTaskBrowserScope,
        capabilities: Set<AgentCapability>,
        mcpConnectionIDs: Set<UUID> = [],
        coworkRootID: UUID? = nil
    ) {
        self.provider = provider
        self.browserScope = browserScope
        self.capabilities = capabilities
        self.mcpConnectionIDs = mcpConnectionIDs
        self.coworkRootID = coworkRootID
    }

    func runConfiguration(
        toolCatalogVersion: Int,
        resolvedMCPServerIdentities: Set<String> = []
    ) -> (configuration: AgentConfigurationSnapshot, scope: AgentRunScope) {
        let connectionIDs: [JSONValue] = mcpConnectionIDs
            .map { $0.uuidString.lowercased() }
            .sorted()
            .map(JSONValue.string)
        let coworkRoot: JSONValue
        if let coworkRootID {
            coworkRoot = .string(coworkRootID.uuidString.lowercased())
        } else {
            coworkRoot = .null
        }
        return (
            AgentConfigurationSnapshot(
                toolCatalogVersion: toolCatalogVersion,
                provider: provider,
                enabledCapabilities: capabilities,
                settings: [
                    "scheduledTaskConfiguration": .boolean(true),
                    "mcpConnectionIDs": .array(connectionIDs),
                    "coworkRootID": coworkRoot,
                ]
            ),
            AgentRunScope(
                capabilities: capabilities,
                pageIDs: browserScope.pageIDs,
                origins: browserScope.origins,
                session: browserScope.session,
                coworkRootIdentity: coworkRootID?.uuidString.lowercased(),
                mcpServerIdentities: resolvedMCPServerIdentities
            )
        )
    }
}

nonisolated struct AgentTaskBudgets: Codable, Equatable, Sendable {
    var maximumModelTurns: Int
    var maximumToolCalls: Int
    var maximumOutputBytes: Int
    var maximumOpenBackgroundPages: Int
    var maximumArtifactBytes: Int
    /// Integer millionths of the configured currency, avoiding floating-point
    /// persistence drift. Nil means cost is not available, never unbounded.
    var maximumProviderCostMicrounits: Int?

    init(
        maximumModelTurns: Int,
        maximumToolCalls: Int,
        maximumOutputBytes: Int,
        maximumOpenBackgroundPages: Int,
        maximumArtifactBytes: Int,
        maximumProviderCostMicrounits: Int? = nil
    ) {
        self.maximumModelTurns = maximumModelTurns
        self.maximumToolCalls = maximumToolCalls
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumOpenBackgroundPages = maximumOpenBackgroundPages
        self.maximumArtifactBytes = maximumArtifactBytes
        self.maximumProviderCostMicrounits = maximumProviderCostMicrounits
    }
}

nonisolated enum AgentTaskConcurrencyPolicy: Codable, Equatable, Sendable {
    /// Every due occurrence waits its turn. Timeout bounds the backlog created
    /// by a healthy executor; launch catch-up remains separately bounded.
    case serialize
    /// An occurrence arriving while another is active is recorded as skipped.
    case skipOverlap
    /// Preserve a bounded FIFO; overflow is recorded as skipped.
    case queue(maxPendingOccurrences: Int)
}

nonisolated enum AgentTaskRetentionPolicy: String, Codable, Equatable, Sendable {
    case neverStore
    case hours24
    case days7
    case days30
    case untilManuallyDeleted

    func expirationDate(after completionDate: Date) -> Date? {
        switch self {
        case .neverStore: completionDate
        case .hours24: completionDate.addingTimeInterval(24 * 60 * 60)
        case .days7: completionDate.addingTimeInterval(7 * 24 * 60 * 60)
        case .days30: completionDate.addingTimeInterval(30 * 24 * 60 * 60)
        case .untilManuallyDeleted: nil
        }
    }
}

nonisolated enum AgentTaskCatchUpPolicy: Codable, Equatable, Sendable {
    case skip
    case runLatest
    case runAll(maximumOccurrences: Int)
}

nonisolated enum AgentTaskRepeatedFailureNotificationPolicy: Codable, Equatable, Sendable {
    case never
    case once(threshold: Int)
    case recurring(threshold: Int, repeatEvery: Int)
}

nonisolated struct AgentTaskNotificationPolicy: Codable, Equatable, Sendable {
    var notifyWhenWaitingForHuman: Bool
    var notifyOnEveryFailure: Bool
    var repeatedFailures: AgentTaskRepeatedFailureNotificationPolicy
    var notifyOnSuccess: Bool

    init(
        notifyWhenWaitingForHuman: Bool = true,
        notifyOnEveryFailure: Bool = true,
        repeatedFailures: AgentTaskRepeatedFailureNotificationPolicy = .once(threshold: 3),
        notifyOnSuccess: Bool = false
    ) {
        self.notifyWhenWaitingForHuman = notifyWhenWaitingForHuman
        self.notifyOnEveryFailure = notifyOnEveryFailure
        self.repeatedFailures = repeatedFailures
        self.notifyOnSuccess = notifyOnSuccess
    }
}

nonisolated enum AgentTaskValidationCode: String, Codable, Equatable, Sendable {
    case unsupportedSchemaVersion
    case invalidRevision
    case emptyName
    case emptyPrompt
    case invalidTimeZone
    case invalidSchedule
    case invalidProvider
    case invalidEndpointIdentity
    case unsafeEndpointIdentity
    case invalidBrowserScope
    case incognitoSessionUnsupported
    case invalidBudgets
    case invalidTimeout
    case invalidConcurrencyPolicy
    case invalidCatchUpPolicy
    case invalidNotificationPolicy
}

nonisolated struct AgentTaskValidationIssue: Codable, Error, Equatable, Sendable {
    let code: AgentTaskValidationCode
    let field: String
    let message: String
}

nonisolated struct AgentTaskDefinition: Codable, Equatable, Identifiable, Sendable {
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
    var execution: AgentTaskExecutionSnapshot
    var budgets: AgentTaskBudgets
    var timeoutSeconds: Int
    var concurrencyPolicy: AgentTaskConcurrencyPolicy
    var retentionPolicy: AgentTaskRetentionPolicy
    var catchUpPolicy: AgentTaskCatchUpPolicy
    var notificationPolicy: AgentTaskNotificationPolicy
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        revision: Int = 1,
        name: String,
        prompt: String,
        enabled: Bool = true,
        schedule: AgentTaskSchedule,
        timeZoneIdentifier: String,
        daylightSavingPolicy: AgentTaskDaylightSavingPolicy,
        execution: AgentTaskExecutionSnapshot,
        budgets: AgentTaskBudgets,
        timeoutSeconds: Int,
        concurrencyPolicy: AgentTaskConcurrencyPolicy,
        retentionPolicy: AgentTaskRetentionPolicy,
        catchUpPolicy: AgentTaskCatchUpPolicy,
        notificationPolicy: AgentTaskNotificationPolicy,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.revision = revision
        self.name = name
        self.prompt = prompt
        self.enabled = enabled
        self.schedule = schedule
        self.timeZoneIdentifier = timeZoneIdentifier
        self.daylightSavingPolicy = daylightSavingPolicy
        self.execution = execution
        self.budgets = budgets
        self.timeoutSeconds = timeoutSeconds
        self.concurrencyPolicy = concurrencyPolicy
        self.retentionPolicy = retentionPolicy
        self.catchUpPolicy = catchUpPolicy
        self.notificationPolicy = notificationPolicy
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        if let issue = validationIssues().first { throw issue }
    }

    func validationIssues() -> [AgentTaskValidationIssue] {
        var issues: [AgentTaskValidationIssue] = []
        func append(_ code: AgentTaskValidationCode, _ field: String, _ message: String) {
            issues.append(AgentTaskValidationIssue(code: code, field: field, message: message))
        }

        if schemaVersion != Self.currentSchemaVersion {
            append(.unsupportedSchemaVersion, "schemaVersion", "Unsupported task definition schema.")
        }
        if revision < 1 { append(.invalidRevision, "revision", "Revision must be positive.") }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            append(.emptyName, "name", "Task name is required.")
        }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            append(.emptyPrompt, "prompt", "Task prompt is required.")
        }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            append(.invalidTimeZone, "timeZoneIdentifier", "Unknown IANA time-zone identifier.")
            return issues
        }
        switch schedule {
        case .interval(let seconds, _):
            if seconds < 60 || seconds > 365 * 24 * 60 * 60 {
                append(.invalidSchedule, "schedule", "Interval must be between one minute and one year.")
            }
        case .daily(let hour, let minute):
            if !(0...23).contains(hour) || !(0...59).contains(minute) {
                append(.invalidSchedule, "schedule", "Daily time is outside the clock range.")
            }
        }
        if execution.provider.providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            execution.provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            append(.invalidProvider, "execution.provider", "Provider and model identities are required.")
        }
        validateEndpoint(into: &issues)
        if execution.browserScope.pageIDs.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) || execution.browserScope.origins.contains(where: { !Self.isValidOrigin($0) }) {
            append(.invalidBrowserScope, "execution.browserScope", "Page IDs and origins must be concrete.")
        }
        if execution.browserScope.session == .incognito {
            append(
                .incognitoSessionUnsupported,
                "execution.browserScope.session",
                "Persistent scheduled tasks cannot bind to an ephemeral incognito Browser Session."
            )
        }
        let numericBudgets = [
            budgets.maximumModelTurns,
            budgets.maximumToolCalls,
            budgets.maximumOutputBytes,
            budgets.maximumOpenBackgroundPages,
            budgets.maximumArtifactBytes,
        ]
        if numericBudgets.contains(where: { $0 <= 0 }) ||
            budgets.maximumProviderCostMicrounits.map({ $0 <= 0 }) == true {
            append(.invalidBudgets, "budgets", "Every configured hard budget must be positive.")
        }
        if timeoutSeconds <= 0 || timeoutSeconds > 7 * 24 * 60 * 60 {
            append(.invalidTimeout, "timeoutSeconds", "Timeout must be between one second and seven days.")
        }
        if case .queue(let maximum) = concurrencyPolicy,
           !(1...1_000).contains(maximum) {
            append(.invalidConcurrencyPolicy, "concurrencyPolicy", "Queue bound must be between 1 and 1,000.")
        }
        if case .runAll(let maximum) = catchUpPolicy,
           !(1...100).contains(maximum) {
            append(.invalidCatchUpPolicy, "catchUpPolicy", "Catch-up bound must be between 1 and 100.")
        }
        switch notificationPolicy.repeatedFailures {
        case .never:
            break
        case .once(let threshold):
            if threshold < 2 {
                append(.invalidNotificationPolicy, "notificationPolicy", "Repeated failure threshold must be at least two.")
            }
        case .recurring(let threshold, let repeatEvery):
            if threshold < 2 || repeatEvery < 1 {
                append(.invalidNotificationPolicy, "notificationPolicy", "Repeated failure cadence is invalid.")
            }
        }
        return issues
    }

    private func validateEndpoint(into issues: inout [AgentTaskValidationIssue]) {
        let identity = execution.provider.endpointIdentity
        guard let components = URLComponents(string: identity),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            issues.append(AgentTaskValidationIssue(
                code: .invalidEndpointIdentity,
                field: "execution.provider.endpointIdentity",
                message: "Provider endpoint identity must be an absolute URL."
            ))
            return
        }
        let loopback = host == "localhost" || host == "127.0.0.1" ||
            host == "::1" || host == "[::1]"
        let schemeAllowed = scheme == "https" || (scheme == "http" && loopback)
        if !schemeAllowed || components.user != nil || components.password != nil ||
            components.query != nil || components.fragment != nil {
            issues.append(AgentTaskValidationIssue(
                code: .unsafeEndpointIdentity,
                field: "execution.provider.endpointIdentity",
                message: "Endpoint identity must be HTTPS (or loopback HTTP) and contain no credentials, query, or fragment."
            ))
        }
    }

    private static func isValidOrigin(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty,
              (scheme == "https" || scheme == "http") else { return false }
        return components.path.isEmpty && components.query == nil && components.fragment == nil &&
            components.user == nil && components.password == nil
    }
}

nonisolated struct AgentTaskOccurrenceID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(taskID: UUID, definitionRevision: Int, scheduledAt: Date) {
        let milliseconds = Int64((scheduledAt.timeIntervalSince1970 * 1_000).rounded())
        rawValue = "\(taskID.uuidString.lowercased())/r\(definitionRevision)/\(milliseconds)"
    }
}

nonisolated enum AgentTaskOccurrenceSource: String, Codable, Equatable, Sendable {
    case timer
    case launchRecovery
    case manual
}

nonisolated struct AgentTaskOccurrence: Codable, Equatable, Identifiable, Sendable {
    let id: AgentTaskOccurrenceID
    let taskDefinitionID: UUID
    let definitionRevision: Int
    let scheduledAt: Date
    let source: AgentTaskOccurrenceSource

    init(
        definition: AgentTaskDefinition,
        scheduledAt: Date,
        source: AgentTaskOccurrenceSource
    ) {
        id = AgentTaskOccurrenceID(
            taskID: definition.id,
            definitionRevision: definition.revision,
            scheduledAt: scheduledAt
        )
        taskDefinitionID = definition.id
        definitionRevision = definition.revision
        self.scheduledAt = scheduledAt
        self.source = source
    }
}

nonisolated struct AgentTaskRecoveryPlan: Codable, Equatable, Sendable {
    let taskDefinitionID: UUID
    let evaluatedAfter: Date
    let evaluatedThrough: Date
    let runnable: [AgentTaskOccurrence]
    let skippedCount: Int
    let alreadyRecordedCount: Int
    let nextScheduledAt: Date?
}

nonisolated enum AgentTaskSchedulePlanningError: Error, Equatable, Sendable {
    case invalidDefinition(AgentTaskValidationIssue)
    case invalidEvaluationWindow
    case occurrenceScanLimitExceeded
    case calendarCouldNotResolveNextOccurrence
}

nonisolated enum AgentTaskSchedulePlanner {
    private static let maximumCalendarOccurrenceScan = 100_000

    static func recoveryPlan(
        for definition: AgentTaskDefinition,
        after lastEvaluation: Date,
        through launchDate: Date,
        existingOccurrenceIDs: Set<AgentTaskOccurrenceID> = [],
        source: AgentTaskOccurrenceSource = .launchRecovery
    ) throws -> AgentTaskRecoveryPlan {
        if let issue = definition.validationIssues().first {
            throw AgentTaskSchedulePlanningError.invalidDefinition(issue)
        }
        guard lastEvaluation <= launchDate else {
            throw AgentTaskSchedulePlanningError.invalidEvaluationWindow
        }
        guard definition.enabled else {
            return AgentTaskRecoveryPlan(
                taskDefinitionID: definition.id,
                evaluatedAfter: lastEvaluation,
                evaluatedThrough: launchDate,
                runnable: [],
                skippedCount: 0,
                alreadyRecordedCount: 0,
                nextScheduledAt: nil
            )
        }

        let maximumSelected: Int
        switch definition.catchUpPolicy {
        case .skip: maximumSelected = 0
        case .runLatest: maximumSelected = 1
        case .runAll(let maximum): maximumSelected = maximum
        }
        let summary = try dueOccurrenceSummary(
            definition: definition,
            after: lastEvaluation,
            through: launchDate,
            retainingLatest: maximumSelected
        )
        let selectedDates: [Date]
        switch definition.catchUpPolicy {
        case .skip:
            selectedDates = []
        case .runLatest:
            selectedDates = Array(summary.latestDates.suffix(1))
        case .runAll(let maximum):
            selectedDates = Array(summary.latestDates.suffix(maximum))
        }

        let selected = selectedDates.map {
            AgentTaskOccurrence(
                definition: definition,
                scheduledAt: $0,
                source: source
            )
        }
        let runnable = selected.filter { !existingOccurrenceIDs.contains($0.id) }
        let alreadyRecordedCount = selected.count - runnable.count
        return AgentTaskRecoveryPlan(
            taskDefinitionID: definition.id,
            evaluatedAfter: lastEvaluation,
            evaluatedThrough: launchDate,
            runnable: runnable,
            skippedCount: max(0, summary.totalCount - selected.count),
            alreadyRecordedCount: alreadyRecordedCount,
            nextScheduledAt: try nextOccurrence(after: launchDate, definition: definition)
        )
    }

    static func nextOccurrence(
        after date: Date,
        definition: AgentTaskDefinition
    ) throws -> Date {
        if let issue = definition.validationIssues().first {
            throw AgentTaskSchedulePlanningError.invalidDefinition(issue)
        }
        switch definition.schedule {
        case .interval(let everySeconds, let anchor):
            let interval = Double(everySeconds)
            guard date >= anchor else { return anchor }
            let elapsed = date.timeIntervalSince(anchor)
            let index = floor(elapsed / interval) + 1
            return anchor.addingTimeInterval(index * interval)
        case .daily(let hour, let minute):
            var calendar = Calendar(identifier: .gregorian)
            guard let timeZone = TimeZone(identifier: definition.timeZoneIdentifier) else {
                throw AgentTaskSchedulePlanningError.invalidDefinition(
                    AgentTaskValidationIssue(
                        code: .invalidTimeZone,
                        field: "timeZoneIdentifier",
                        message: "Unknown IANA time-zone identifier."
                    )
                )
            }
            calendar.timeZone = timeZone
            let matchingPolicy: Calendar.MatchingPolicy =
                definition.daylightSavingPolicy.nonexistentTime == .skipOccurrence
                ? .strict : .nextTime
            let repeatedPolicy: Calendar.RepeatedTimePolicy =
                definition.daylightSavingPolicy.repeatedTime == .firstOccurrence
                ? .first : .last
            guard let next = calendar.nextDate(
                after: date,
                matching: DateComponents(hour: hour, minute: minute, second: 0),
                matchingPolicy: matchingPolicy,
                repeatedTimePolicy: repeatedPolicy,
                direction: .forward
            ), next > date else {
                throw AgentTaskSchedulePlanningError.calendarCouldNotResolveNextOccurrence
            }
            return next
        }
    }

    private struct DueSummary {
        let totalCount: Int
        let latestDates: [Date]
    }

    private static func dueOccurrenceSummary(
        definition: AgentTaskDefinition,
        after lowerBound: Date,
        through upperBound: Date,
        retainingLatest limit: Int
    ) throws -> DueSummary {
        switch definition.schedule {
        case .interval(let everySeconds, let anchor):
            let interval = Double(everySeconds)
            let firstIndex: Int64
            if lowerBound < anchor {
                firstIndex = 0
            } else {
                firstIndex = Int64(floor(lowerBound.timeIntervalSince(anchor) / interval)) + 1
            }
            let lastIndex = Int64(floor(upperBound.timeIntervalSince(anchor) / interval))
            guard lastIndex >= firstIndex, lastIndex >= 0 else {
                return DueSummary(totalCount: 0, latestDates: [])
            }
            let distance = lastIndex - firstIndex + 1
            guard distance <= Int64(Int.max) else {
                throw AgentTaskSchedulePlanningError.occurrenceScanLimitExceeded
            }
            let total = Int(distance)
            let retained = min(limit, total)
            let retainedStart = lastIndex - Int64(retained) + 1
            let dates = retained == 0 ? [] : (retainedStart...lastIndex).map {
                anchor.addingTimeInterval(Double($0) * interval)
            }
            return DueSummary(totalCount: total, latestDates: dates)
        case .daily:
            var cursor = lowerBound
            var count = 0
            var latest: [Date] = []
            while true {
                let next = try nextOccurrence(after: cursor, definition: definition)
                guard next <= upperBound else { break }
                count += 1
                guard count <= maximumCalendarOccurrenceScan else {
                    throw AgentTaskSchedulePlanningError.occurrenceScanLimitExceeded
                }
                if limit > 0 {
                    latest.append(next)
                    if latest.count > limit { latest.removeFirst() }
                }
                cursor = next
            }
            return DueSummary(totalCount: count, latestDates: latest)
        }
    }
}

nonisolated enum AgentTaskBrowserAvailability: String, Codable, Equatable, Sendable {
    case visibleWindow
    case sanctionedHiddenWindow
    case unavailable
}

nonisolated enum AgentTaskExecutionWindow: String, Codable, Equatable, Sendable {
    case visible
    case hidden
}

nonisolated enum AgentTaskSkipReason: String, Codable, Equatable, Sendable {
    case overlapPolicy
    case queueCapacityReached
    case taskDisabled
    case staleDefinition
}

nonisolated enum AgentTaskBlockedReason: String, Codable, Equatable, Sendable {
    case noBrowserWindow
}

nonisolated enum AgentTaskBudgetLimit: String, Codable, Equatable, Sendable {
    case modelTurns
    case toolCalls
    case outputBytes
    case openBackgroundPages
    case artifactBytes
    case providerCost
}

nonisolated enum AgentTaskFailureCategory: String, Codable, Equatable, Sendable {
    case provider
    case policyDenied
    case targetUnavailable
    case storeUnavailable
    case noBrowserWindow
    case timeout
    case budgetExceeded
    case unknown
}

nonisolated enum AgentTaskRunOutcome: Codable, Equatable, Sendable {
    case succeeded
    case failed(AgentTaskFailureCategory)
    case cancelled
    case timedOut
    case budgetExceeded(AgentTaskBudgetLimit)
    case interrupted

    var countsAsFailure: Bool {
        switch self {
        case .failed, .timedOut, .budgetExceeded: true
        case .succeeded, .cancelled, .interrupted: false
        }
    }

    var failureCategory: AgentTaskFailureCategory? {
        switch self {
        case .failed(let category): category
        case .timedOut: .timeout
        case .budgetExceeded: .budgetExceeded
        case .succeeded, .cancelled, .interrupted: nil
        }
    }
}

nonisolated enum AgentTaskOccurrenceState: Codable, Equatable, Sendable {
    case queued(enqueuedAt: Date)
    case running(runID: UUID, startedAt: Date, deadline: Date)
    case waitingForHuman(
        runID: UUID,
        startedAt: Date,
        deadline: Date,
        approvalRequestID: UUID,
        approvalExpiresAt: Date
    )
    case finished(runID: UUID, outcome: AgentTaskRunOutcome, finishedAt: Date)
    case skipped(reason: AgentTaskSkipReason, at: Date)
    case blocked(runID: UUID, reason: AgentTaskBlockedReason, at: Date)

    var runID: UUID? {
        switch self {
        case .running(let runID, _, _),
             .waitingForHuman(let runID, _, _, _, _),
             .finished(let runID, _, _),
             .blocked(let runID, _, _): runID
        case .queued, .skipped: nil
        }
    }

    var isActive: Bool {
        switch self {
        case .running, .waitingForHuman: true
        case .queued, .finished, .skipped, .blocked: false
        }
    }

    var isQueued: Bool {
        if case .queued = self { return true }
        return false
    }
}

nonisolated struct AgentTaskOccurrenceRecord: Codable, Equatable, Identifiable, Sendable {
    var id: AgentTaskOccurrenceID { occurrence.id }
    let occurrence: AgentTaskOccurrence
    /// The exact task revision used for this occurrence. A queued occurrence
    /// never picks up later global settings or definition edits.
    let definitionSnapshot: AgentTaskDefinition
    var state: AgentTaskOccurrenceState
}

nonisolated enum AgentTaskNotificationKind: Codable, Equatable, Sendable {
    case waitingForHuman(approvalRequestID: UUID)
    case failure(AgentTaskFailureCategory)
    case repeatedFailure(count: Int)
    case success

    fileprivate var identityComponent: String {
        switch self {
        case .waitingForHuman: "waiting-for-human"
        case .failure: "failure"
        case .repeatedFailure(let count): "repeated-failure-\(count)"
        case .success: "success"
        }
    }
}

nonisolated enum AgentTaskNotificationDelivery: String, Codable, Equatable, Sendable {
    case pending
    case delivered
    case dismissed
}

nonisolated struct AgentTaskNotification: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let taskDefinitionID: UUID
    let occurrenceID: AgentTaskOccurrenceID
    let runID: UUID
    let kind: AgentTaskNotificationKind
    let createdAt: Date
    var delivery: AgentTaskNotificationDelivery

    init(
        taskDefinitionID: UUID,
        occurrenceID: AgentTaskOccurrenceID,
        runID: UUID,
        kind: AgentTaskNotificationKind,
        createdAt: Date
    ) {
        id = "\(occurrenceID.rawValue)/\(kind.identityComponent)"
        self.taskDefinitionID = taskDefinitionID
        self.occurrenceID = occurrenceID
        self.runID = runID
        self.kind = kind
        self.createdAt = createdAt
        delivery = .pending
    }
}

nonisolated struct AgentTaskRuntimeState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    let taskDefinitionID: UUID
    var lastEvaluatedAt: Date
    var occurrenceRecords: [AgentTaskOccurrenceRecord]
    var pendingOccurrenceIDs: [AgentTaskOccurrenceID]
    var consecutiveFailures: Int
    var notifications: [AgentTaskNotification]
    var skippedDuringDowntime: Int

    init(taskDefinitionID: UUID, lastEvaluatedAt: Date) {
        schemaVersion = Self.currentSchemaVersion
        self.taskDefinitionID = taskDefinitionID
        self.lastEvaluatedAt = lastEvaluatedAt
        occurrenceRecords = []
        pendingOccurrenceIDs = []
        consecutiveFailures = 0
        notifications = []
        skippedDuringDowntime = 0
    }
}

nonisolated struct AgentTaskDeletionTombstone: Codable, Equatable, Sendable {
    let taskDefinitionID: UUID
    let deletedAt: Date
}

nonisolated struct AgentTaskSchedulerSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var definitions: [AgentTaskDefinition]
    var runtimeStates: [AgentTaskRuntimeState]
    var deletionTombstones: [AgentTaskDeletionTombstone]

    init(
        definitions: [AgentTaskDefinition] = [],
        runtimeStates: [AgentTaskRuntimeState] = [],
        deletionTombstones: [AgentTaskDeletionTombstone] = []
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.definitions = definitions
        self.runtimeStates = runtimeStates
        self.deletionTombstones = deletionTombstones
    }
}

nonisolated enum AgentTaskRunDirectiveKind: Codable, Equatable, Sendable {
    case execute(window: AgentTaskExecutionWindow)
    case recordBlocked(reason: AgentTaskBlockedReason)
}

nonisolated struct AgentTaskRunDirective: Codable, Equatable, Sendable {
    let occurrence: AgentTaskOccurrence
    let runID: UUID
    let definitionSnapshot: AgentTaskDefinition
    let kind: AgentTaskRunDirectiveKind
    let issuedAt: Date
    let deadline: Date

    var providerSnapshot: AgentProviderSnapshot {
        definitionSnapshot.execution.provider
    }

    func makeRun(
        toolCatalogVersion: Int,
        conversationID: UUID? = nil,
        resolvedMCPServerIdentities: Set<String> = []
    ) -> (run: AgentRun, scope: AgentRunScope) {
        let values = definitionSnapshot.execution.runConfiguration(
            toolCatalogVersion: toolCatalogVersion,
            resolvedMCPServerIdentities: resolvedMCPServerIdentities
        )
        let initialStatus: AgentRunStatus
        switch kind {
        case .execute: initialStatus = .queued
        case .recordBlocked: initialStatus = .failed
        }
        var run = AgentRun(
            id: runID,
            conversationID: conversationID,
            taskDefinitionID: definitionSnapshot.id,
            entryPoint: .scheduled,
            status: initialStatus,
            createdAt: issuedAt,
            configuration: values.configuration,
            incognito: false
        )
        if case .recordBlocked = kind {
            run.failureCategory = AgentTaskFailureCategory.noBrowserWindow.rawValue
        }
        return (run, values.scope)
    }
}

nonisolated enum AgentTaskOccurrenceRejection: String, Codable, Equatable, Sendable {
    case taskNotFound
    case taskDeleted
}

nonisolated enum AgentTaskOccurrenceAdmission: Equatable, Sendable {
    case start(AgentTaskRunDirective)
    case queued(occurrenceID: AgentTaskOccurrenceID, position: Int)
    case skipped(AgentTaskOccurrenceRecord)
    case blocked(AgentTaskRunDirective)
    case duplicate(AgentTaskOccurrenceRecord)
    case rejected(AgentTaskOccurrenceRejection)
}

nonisolated struct AgentTaskCompletionUpdate: Equatable, Sendable {
    let completedRecord: AgentTaskOccurrenceRecord
    let followUpAdmissions: [AgentTaskOccurrenceAdmission]
    let newNotifications: [AgentTaskNotification]
}

nonisolated struct AgentTaskLaunchRecovery: Equatable, Sendable {
    let plans: [AgentTaskRecoveryPlan]
    let admissions: [AgentTaskOccurrenceAdmission]
    let interruptedRunIDs: [UUID]
    let newNotifications: [AgentTaskNotification]
}

nonisolated struct AgentTaskDueEvaluation: Equatable, Sendable {
    let plans: [AgentTaskRecoveryPlan]
    let admissions: [AgentTaskOccurrenceAdmission]
    let newNotifications: [AgentTaskNotification]
}

nonisolated struct AgentTaskRetentionDirective: Codable, Equatable, Sendable {
    let taskDefinitionID: UUID
    let occurrenceID: AgentTaskOccurrenceID
    let runID: UUID
    let removeAt: Date
}

nonisolated enum AgentTaskSchedulerError: Error, Equatable, Sendable {
    case invalidDefinition(AgentTaskValidationIssue)
    case duplicateTaskDefinition(UUID)
    case staleTaskRevision(current: Int, proposed: Int)
    case taskNotFound(UUID)
    case taskDeleted(UUID)
    case occurrenceNotFound(AgentTaskOccurrenceID)
    case occurrenceNotActive(AgentTaskOccurrenceID)
    case runIdentityMismatch
    case notificationNotFound(String)
    case corruptSnapshot(String)
}

actor AgentScheduledTaskEngine {
    private static let maximumSerializedPendingOccurrences = 1_000

    private var definitions: [UUID: AgentTaskDefinition]
    private var runtimeStates: [UUID: AgentTaskRuntimeState]
    private var tombstones: [UUID: AgentTaskDeletionTombstone]

    init(snapshot: AgentTaskSchedulerSnapshot = AgentTaskSchedulerSnapshot()) throws {
        guard snapshot.schemaVersion == AgentTaskSchedulerSnapshot.currentSchemaVersion else {
            throw AgentTaskSchedulerError.corruptSnapshot("Unsupported scheduler snapshot schema.")
        }
        definitions = [:]
        runtimeStates = [:]
        tombstones = [:]
        for definition in snapshot.definitions {
            if let issue = definition.validationIssues().first {
                throw AgentTaskSchedulerError.invalidDefinition(issue)
            }
            guard definitions[definition.id] == nil else {
                throw AgentTaskSchedulerError.corruptSnapshot("Duplicate task definition ID.")
            }
            definitions[definition.id] = definition
        }
        for state in snapshot.runtimeStates {
            guard state.schemaVersion == AgentTaskRuntimeState.currentSchemaVersion,
                  runtimeStates[state.taskDefinitionID] == nil else {
                throw AgentTaskSchedulerError.corruptSnapshot("Invalid or duplicate task runtime state.")
            }
            let recordIDs = state.occurrenceRecords.map(\.id)
            guard Set(recordIDs).count == recordIDs.count,
                  Set(state.pendingOccurrenceIDs).count == state.pendingOccurrenceIDs.count,
                  state.occurrenceRecords.filter({ $0.state.isActive }).count <= 1,
                  Set(state.notifications.map(\.id)).count == state.notifications.count,
                  state.pendingOccurrenceIDs.allSatisfy({ pendingID in
                      state.occurrenceRecords.contains {
                          $0.id == pendingID && $0.state.isQueued
                      }
                  }) else {
                throw AgentTaskSchedulerError.corruptSnapshot("Occurrence ledger is inconsistent.")
            }
            runtimeStates[state.taskDefinitionID] = state
        }
        for tombstone in snapshot.deletionTombstones {
            guard tombstones[tombstone.taskDefinitionID] == nil else {
                throw AgentTaskSchedulerError.corruptSnapshot("Duplicate deletion tombstone.")
            }
            tombstones[tombstone.taskDefinitionID] = tombstone
            definitions.removeValue(forKey: tombstone.taskDefinitionID)
        }
        let recognizedTaskIDs = Set(definitions.keys).union(tombstones.keys)
        guard Set(runtimeStates.keys).isSubset(of: recognizedTaskIDs) else {
            throw AgentTaskSchedulerError.corruptSnapshot("Runtime state has no definition or tombstone.")
        }
        for definition in definitions.values where runtimeStates[definition.id] == nil {
            runtimeStates[definition.id] = AgentTaskRuntimeState(
                taskDefinitionID: definition.id,
                lastEvaluatedAt: definition.createdAt
            )
        }
    }

    func register(_ definition: AgentTaskDefinition) throws {
        if let issue = definition.validationIssues().first {
            throw AgentTaskSchedulerError.invalidDefinition(issue)
        }
        guard tombstones[definition.id] == nil else {
            throw AgentTaskSchedulerError.taskDeleted(definition.id)
        }
        guard definitions[definition.id] == nil else {
            throw AgentTaskSchedulerError.duplicateTaskDefinition(definition.id)
        }
        definitions[definition.id] = definition
        if runtimeStates[definition.id] == nil {
            runtimeStates[definition.id] = AgentTaskRuntimeState(
                taskDefinitionID: definition.id,
                lastEvaluatedAt: definition.createdAt
            )
        }
    }

    func update(_ definition: AgentTaskDefinition) throws {
        if let issue = definition.validationIssues().first {
            throw AgentTaskSchedulerError.invalidDefinition(issue)
        }
        guard tombstones[definition.id] == nil else {
            throw AgentTaskSchedulerError.taskDeleted(definition.id)
        }
        guard let current = definitions[definition.id] else {
            throw AgentTaskSchedulerError.taskNotFound(definition.id)
        }
        guard definition.revision > current.revision else {
            throw AgentTaskSchedulerError.staleTaskRevision(
                current: current.revision,
                proposed: definition.revision
            )
        }
        definitions[definition.id] = definition
        if current.enabled && !definition.enabled {
            skipPending(taskID: definition.id, reason: .taskDisabled, at: definition.updatedAt)
        } else if !current.enabled && definition.enabled,
                  var runtime = runtimeStates[definition.id] {
            runtime.lastEvaluatedAt = definition.updatedAt
            runtimeStates[definition.id] = runtime
        }
    }

    func duplicateTask(
        _ taskID: UUID,
        as newID: UUID = UUID(),
        at date: Date = Date()
    ) throws -> AgentTaskDefinition {
        guard var copy = definitions[taskID] else {
            throw AgentTaskSchedulerError.taskNotFound(taskID)
        }
        copy = try AgentTaskDefinition(
            id: newID,
            revision: 1,
            name: "\(copy.name) Copy",
            prompt: copy.prompt,
            enabled: false,
            schedule: copy.schedule,
            timeZoneIdentifier: copy.timeZoneIdentifier,
            daylightSavingPolicy: copy.daylightSavingPolicy,
            execution: copy.execution,
            budgets: copy.budgets,
            timeoutSeconds: copy.timeoutSeconds,
            concurrencyPolicy: copy.concurrencyPolicy,
            retentionPolicy: copy.retentionPolicy,
            catchUpPolicy: copy.catchUpPolicy,
            notificationPolicy: copy.notificationPolicy,
            createdAt: date,
            updatedAt: date
        )
        try register(copy)
        return copy
    }

    @discardableResult
    func setEnabled(_ taskID: UUID, _ enabled: Bool, at date: Date = Date()) throws
        -> AgentTaskDefinition {
        guard var definition = definitions[taskID] else {
            if tombstones[taskID] != nil { throw AgentTaskSchedulerError.taskDeleted(taskID) }
            throw AgentTaskSchedulerError.taskNotFound(taskID)
        }
        definition.enabled = enabled
        definition.revision += 1
        definition.updatedAt = date
        definitions[taskID] = definition
        if !enabled {
            skipPending(taskID: taskID, reason: .taskDisabled, at: date)
        } else if var runtime = runtimeStates[taskID] {
            runtime.lastEvaluatedAt = date
            runtimeStates[taskID] = runtime
        }
        return definition
    }

    func deleteTask(_ taskID: UUID, at date: Date = Date()) throws {
        guard definitions.removeValue(forKey: taskID) != nil else {
            if tombstones[taskID] != nil { return }
            throw AgentTaskSchedulerError.taskNotFound(taskID)
        }
        skipPending(taskID: taskID, reason: .taskDisabled, at: date)
        tombstones[taskID] = AgentTaskDeletionTombstone(
            taskDefinitionID: taskID,
            deletedAt: date
        )
    }

    func definition(id: UUID) -> AgentTaskDefinition? { definitions[id] }

    func runtimeState(taskID: UUID) -> AgentTaskRuntimeState? { runtimeStates[taskID] }

    func snapshot() -> AgentTaskSchedulerSnapshot {
        AgentTaskSchedulerSnapshot(
            definitions: definitions.values.sorted { $0.id.uuidString < $1.id.uuidString },
            runtimeStates: runtimeStates.values.sorted {
                $0.taskDefinitionID.uuidString < $1.taskDefinitionID.uuidString
            },
            deletionTombstones: tombstones.values.sorted {
                $0.taskDefinitionID.uuidString < $1.taskDefinitionID.uuidString
            }
        )
    }

    func admit(
        _ occurrence: AgentTaskOccurrence,
        browserAvailability: AgentTaskBrowserAvailability,
        at date: Date = Date()
    ) -> AgentTaskOccurrenceAdmission {
        admitInternal(occurrence, browserAvailability: browserAvailability, at: date)
    }

    func complete(
        taskID: UUID,
        occurrenceID: AgentTaskOccurrenceID,
        runID: UUID,
        outcome: AgentTaskRunOutcome,
        browserAvailability: AgentTaskBrowserAvailability,
        at date: Date = Date()
    ) throws -> AgentTaskCompletionUpdate {
        guard var runtime = runtimeStates[taskID],
              let index = runtime.occurrenceRecords.firstIndex(where: { $0.id == occurrenceID }) else {
            throw AgentTaskSchedulerError.occurrenceNotFound(occurrenceID)
        }
        guard runtime.occurrenceRecords[index].state.isActive else {
            throw AgentTaskSchedulerError.occurrenceNotActive(occurrenceID)
        }
        guard runtime.occurrenceRecords[index].state.runID == runID else {
            throw AgentTaskSchedulerError.runIdentityMismatch
        }
        let notificationCount = runtime.notifications.count
        runtime.occurrenceRecords[index].state = .finished(
            runID: runID,
            outcome: outcome,
            finishedAt: date
        )
        applyOutcomeNotifications(
            outcome,
            record: runtime.occurrenceRecords[index],
            definition: runtime.occurrenceRecords[index].definitionSnapshot,
            runtime: &runtime,
            at: date
        )
        let completed = runtime.occurrenceRecords[index]
        runtimeStates[taskID] = runtime
        let followUps = drainPending(
            taskID: taskID,
            browserAvailability: browserAvailability,
            at: date
        )
        let notifications = runtimeStates[taskID].map {
            Array($0.notifications.dropFirst(notificationCount))
        } ?? []
        return AgentTaskCompletionUpdate(
            completedRecord: completed,
            followUpAdmissions: followUps,
            newNotifications: notifications
        )
    }

    @discardableResult
    func recordWaitingForHuman(
        taskID: UUID,
        occurrenceID: AgentTaskOccurrenceID,
        runID: UUID,
        approvalRequestID: UUID,
        approvalExpiresAt: Date,
        at date: Date = Date()
    ) throws -> AgentTaskNotification? {
        guard var runtime = runtimeStates[taskID],
              let index = runtime.occurrenceRecords.firstIndex(where: { $0.id == occurrenceID }) else {
            throw AgentTaskSchedulerError.occurrenceNotFound(occurrenceID)
        }
        guard case .running(let recordedRunID, let startedAt, let deadline) =
            runtime.occurrenceRecords[index].state else {
            throw AgentTaskSchedulerError.occurrenceNotActive(occurrenceID)
        }
        guard recordedRunID == runID else { throw AgentTaskSchedulerError.runIdentityMismatch }
        runtime.occurrenceRecords[index].state = .waitingForHuman(
            runID: runID,
            startedAt: startedAt,
            deadline: deadline,
            approvalRequestID: approvalRequestID,
            approvalExpiresAt: approvalExpiresAt
        )
        var notification: AgentTaskNotification?
        let definition = runtime.occurrenceRecords[index].definitionSnapshot
        if definition.notificationPolicy.notifyWhenWaitingForHuman {
            notification = enqueueNotification(
                kind: .waitingForHuman(approvalRequestID: approvalRequestID),
                record: runtime.occurrenceRecords[index],
                runtime: &runtime,
                at: date
            )
        }
        runtimeStates[taskID] = runtime
        return notification
    }

    func resumeAfterHumanHandoff(
        taskID: UUID,
        occurrenceID: AgentTaskOccurrenceID,
        runID: UUID
    ) throws {
        guard var runtime = runtimeStates[taskID],
              let index = runtime.occurrenceRecords.firstIndex(where: { $0.id == occurrenceID }) else {
            throw AgentTaskSchedulerError.occurrenceNotFound(occurrenceID)
        }
        guard case .waitingForHuman(
            let recordedRunID,
            let startedAt,
            let deadline,
            _, _
        ) = runtime.occurrenceRecords[index].state else {
            throw AgentTaskSchedulerError.occurrenceNotActive(occurrenceID)
        }
        guard recordedRunID == runID else { throw AgentTaskSchedulerError.runIdentityMismatch }
        runtime.occurrenceRecords[index].state = .running(
            runID: runID,
            startedAt: startedAt,
            deadline: deadline
        )
        runtimeStates[taskID] = runtime
    }

    func pendingNotifications() -> [AgentTaskNotification] {
        runtimeStates.values
            .flatMap(\.notifications)
            .filter { $0.delivery == .pending }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt { return lhs.id < rhs.id }
                return lhs.createdAt < rhs.createdAt
            }
    }

    func setNotificationDelivery(
        id: String,
        to delivery: AgentTaskNotificationDelivery
    ) throws {
        for taskID in runtimeStates.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard var runtime = runtimeStates[taskID],
                  let index = runtime.notifications.firstIndex(where: { $0.id == id }) else {
                continue
            }
            runtime.notifications[index].delivery = delivery
            runtimeStates[taskID] = runtime
            return
        }
        throw AgentTaskSchedulerError.notificationNotFound(id)
    }

    /// Returns run-store deletions that are due. The scheduler ledger is kept
    /// until integration confirms the run and its artifacts were removed.
    func retentionDirectives(at date: Date = Date()) -> [AgentTaskRetentionDirective] {
        runtimeStates.values.flatMap { runtime in
            runtime.occurrenceRecords.compactMap { record in
                guard let runID = record.state.runID,
                      let completionDate = record.state.retentionCompletionDate,
                      let removeAt = record.definitionSnapshot.retentionPolicy.expirationDate(
                          after: completionDate
                      ),
                      removeAt <= date else { return nil }
                return AgentTaskRetentionDirective(
                    taskDefinitionID: runtime.taskDefinitionID,
                    occurrenceID: record.id,
                    runID: runID,
                    removeAt: removeAt
                )
            }
        }.sorted { lhs, rhs in
            if lhs.removeAt == rhs.removeAt {
                return lhs.occurrenceID.rawValue < rhs.occurrenceID.rawValue
            }
            return lhs.removeAt < rhs.removeAt
        }
    }

    /// Call only after AgentRunStore deletion succeeds. This separation keeps
    /// retention failure-safe and prevents orphaning an undeleted run.
    func acknowledgeRetention(_ directive: AgentTaskRetentionDirective) throws {
        guard var runtime = runtimeStates[directive.taskDefinitionID],
              let index = runtime.occurrenceRecords.firstIndex(where: {
                  $0.id == directive.occurrenceID && $0.state.runID == directive.runID
              }) else {
            throw AgentTaskSchedulerError.occurrenceNotFound(directive.occurrenceID)
        }
        runtime.occurrenceRecords.remove(at: index)
        runtime.pendingOccurrenceIDs.removeAll { $0 == directive.occurrenceID }
        runtime.notifications.removeAll { $0.occurrenceID == directive.occurrenceID }
        runtimeStates[directive.taskDefinitionID] = runtime
    }

    func recoverOnLaunch(
        at launchDate: Date,
        browserAvailability: AgentTaskBrowserAvailability
    ) throws -> AgentTaskLaunchRecovery {
        var interruptedRunIDs: [UUID] = []
        var plans: [AgentTaskRecoveryPlan] = []
        var admissions: [AgentTaskOccurrenceAdmission] = []
        let notificationIDsBefore = Set(
            runtimeStates.values.flatMap(\.notifications).map(\.id)
        )

        // Recovery is ledger-wide, including definitions deleted or disabled
        // while a run was active. AgentRunStore performs the corresponding
        // durable Run transition; these IDs are the integration handoff.
        for taskID in runtimeStates.keys {
            guard var runtime = runtimeStates[taskID] else { continue }
            for index in runtime.occurrenceRecords.indices {
                let state = runtime.occurrenceRecords[index].state
                guard state.isActive, let runID = state.runID else { continue }
                interruptedRunIDs.append(runID)
                runtime.occurrenceRecords[index].state = .finished(
                    runID: runID,
                    outcome: .interrupted,
                    finishedAt: launchDate
                )
            }
            runtimeStates[taskID] = runtime
        }

        for taskID in definitions.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let definition = definitions[taskID] else { continue }
            admissions.append(contentsOf: drainPending(
                taskID: taskID,
                browserAvailability: browserAvailability,
                at: launchDate
            ))

            guard var updatedRuntime = runtimeStates[taskID] else { continue }
            let existing = Set(updatedRuntime.occurrenceRecords.map(\.id))
            let plan = try AgentTaskSchedulePlanner.recoveryPlan(
                for: definition,
                after: updatedRuntime.lastEvaluatedAt,
                through: launchDate,
                existingOccurrenceIDs: existing
            )
            updatedRuntime.lastEvaluatedAt = launchDate
            updatedRuntime.skippedDuringDowntime += plan.skippedCount
            runtimeStates[taskID] = updatedRuntime
            plans.append(plan)
            for occurrence in plan.runnable {
                admissions.append(admitInternal(
                    occurrence,
                    browserAvailability: browserAvailability,
                    at: launchDate
                ))
            }
        }
        let notifications = runtimeStates.values
            .flatMap(\.notifications)
            .filter { !notificationIDsBefore.contains($0.id) }
        return AgentTaskLaunchRecovery(
            plans: plans,
            admissions: admissions,
            interruptedRunIDs: interruptedRunIDs,
            newNotifications: notifications
        )
    }

    /// Normal timer/poll entry point. Uses the same catch-up planner as launch
    /// recovery but never alters an already-active run.
    func evaluateDueTasks(
        at date: Date,
        browserAvailability: AgentTaskBrowserAvailability
    ) throws -> AgentTaskDueEvaluation {
        var plans: [AgentTaskRecoveryPlan] = []
        var admissions: [AgentTaskOccurrenceAdmission] = []
        let notificationIDsBefore = Set(
            runtimeStates.values.flatMap(\.notifications).map(\.id)
        )
        for taskID in definitions.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let definition = definitions[taskID],
                  var runtime = runtimeStates[taskID] else { continue }
            let existing = Set(runtime.occurrenceRecords.map(\.id))
            let plan = try AgentTaskSchedulePlanner.recoveryPlan(
                for: definition,
                after: runtime.lastEvaluatedAt,
                through: date,
                existingOccurrenceIDs: existing,
                source: .timer
            )
            runtime.lastEvaluatedAt = date
            runtime.skippedDuringDowntime += plan.skippedCount
            runtimeStates[taskID] = runtime
            plans.append(plan)
            for occurrence in plan.runnable {
                admissions.append(admitInternal(
                    occurrence,
                    browserAvailability: browserAvailability,
                    at: date
                ))
            }
        }
        let notifications = runtimeStates.values
            .flatMap(\.notifications)
            .filter { !notificationIDsBefore.contains($0.id) }
        return AgentTaskDueEvaluation(
            plans: plans,
            admissions: admissions,
            newNotifications: notifications
        )
    }

    private func admitInternal(
        _ occurrence: AgentTaskOccurrence,
        browserAvailability: AgentTaskBrowserAvailability,
        at date: Date
    ) -> AgentTaskOccurrenceAdmission {
        let taskID = occurrence.taskDefinitionID
        guard tombstones[taskID] == nil else { return .rejected(.taskDeleted) }
        guard let definition = definitions[taskID] else { return .rejected(.taskNotFound) }
        if let existing = runtimeStates[taskID]?.occurrenceRecords.first(where: {
            $0.id == occurrence.id
        }) {
            return .duplicate(existing)
        }
        guard definition.enabled else {
            return recordSkipped(
                occurrence,
                definition: definition,
                reason: .taskDisabled,
                at: date
            )
        }
        guard occurrence.definitionRevision == definition.revision else {
            return recordSkipped(
                occurrence,
                definition: definition,
                reason: .staleDefinition,
                at: date
            )
        }
        let hasActive = runtimeStates[taskID]?.occurrenceRecords.contains {
            $0.state.isActive
        } == true
        if hasActive {
            switch definition.concurrencyPolicy {
            case .skipOverlap:
                return recordSkipped(
                    occurrence,
                    definition: definition,
                    reason: .overlapPolicy,
                    at: date
                )
            case .serialize:
                return enqueue(
                    occurrence,
                    definition: definition,
                    maximumPending: Self.maximumSerializedPendingOccurrences,
                    at: date
                )
            case .queue(let maximum):
                return enqueue(
                    occurrence,
                    definition: definition,
                    maximumPending: maximum,
                    at: date
                )
            }
        }
        return startOrBlock(
            occurrence,
            definition: definition,
            browserAvailability: browserAvailability,
            at: date
        )
    }

    private func startOrBlock(
        _ occurrence: AgentTaskOccurrence,
        definition: AgentTaskDefinition,
        browserAvailability: AgentTaskBrowserAvailability,
        at date: Date
    ) -> AgentTaskOccurrenceAdmission {
        let runID = UUID()
        let deadline = date.addingTimeInterval(TimeInterval(definition.timeoutSeconds))
        let directiveKind: AgentTaskRunDirectiveKind
        let state: AgentTaskOccurrenceState
        switch browserAvailability {
        case .visibleWindow:
            directiveKind = .execute(window: .visible)
            state = .running(runID: runID, startedAt: date, deadline: deadline)
        case .sanctionedHiddenWindow:
            directiveKind = .execute(window: .hidden)
            state = .running(runID: runID, startedAt: date, deadline: deadline)
        case .unavailable:
            directiveKind = .recordBlocked(reason: .noBrowserWindow)
            state = .blocked(runID: runID, reason: .noBrowserWindow, at: date)
        }
        let record = AgentTaskOccurrenceRecord(
            occurrence: occurrence,
            definitionSnapshot: definition,
            state: state
        )
        appendRecord(record, taskID: definition.id)
        let directive = AgentTaskRunDirective(
            occurrence: occurrence,
            runID: runID,
            definitionSnapshot: definition,
            kind: directiveKind,
            issuedAt: date,
            deadline: deadline
        )
        if browserAvailability == .unavailable {
            registerBlockedFailure(record: record, runtimeTaskID: definition.id, at: date)
            return .blocked(directive)
        }
        return .start(directive)
    }

    private func enqueue(
        _ occurrence: AgentTaskOccurrence,
        definition: AgentTaskDefinition,
        maximumPending: Int,
        at date: Date
    ) -> AgentTaskOccurrenceAdmission {
        var runtime = runtimeStates[definition.id] ?? AgentTaskRuntimeState(
            taskDefinitionID: definition.id,
            lastEvaluatedAt: definition.createdAt
        )
        guard runtime.pendingOccurrenceIDs.count < maximumPending else {
            runtimeStates[definition.id] = runtime
            return recordSkipped(
                occurrence,
                definition: definition,
                reason: .queueCapacityReached,
                at: date
            )
        }
        let record = AgentTaskOccurrenceRecord(
            occurrence: occurrence,
            definitionSnapshot: definition,
            state: .queued(enqueuedAt: date)
        )
        runtime.occurrenceRecords.append(record)
        runtime.pendingOccurrenceIDs.append(occurrence.id)
        let position = runtime.pendingOccurrenceIDs.count
        runtimeStates[definition.id] = runtime
        return .queued(occurrenceID: occurrence.id, position: position)
    }

    private func recordSkipped(
        _ occurrence: AgentTaskOccurrence,
        definition: AgentTaskDefinition,
        reason: AgentTaskSkipReason,
        at date: Date
    ) -> AgentTaskOccurrenceAdmission {
        let record = AgentTaskOccurrenceRecord(
            occurrence: occurrence,
            definitionSnapshot: definition,
            state: .skipped(reason: reason, at: date)
        )
        appendRecord(record, taskID: definition.id)
        return .skipped(record)
    }

    private func appendRecord(_ record: AgentTaskOccurrenceRecord, taskID: UUID) {
        guard !recordAlreadyExists(record.id, taskID: taskID) else { return }
        var runtime = runtimeStates[taskID] ?? AgentTaskRuntimeState(
            taskDefinitionID: taskID,
            lastEvaluatedAt: record.definitionSnapshot.createdAt
        )
        runtime.occurrenceRecords.append(record)
        runtimeStates[taskID] = runtime
    }

    private func recordAlreadyExists(_ occurrenceID: AgentTaskOccurrenceID, taskID: UUID) -> Bool {
        runtimeStates[taskID]?.occurrenceRecords.contains { $0.id == occurrenceID } == true
    }

    private func skipPending(taskID: UUID, reason: AgentTaskSkipReason, at date: Date) {
        guard var runtime = runtimeStates[taskID] else { return }
        let pending = Set(runtime.pendingOccurrenceIDs)
        for index in runtime.occurrenceRecords.indices where pending.contains(
            runtime.occurrenceRecords[index].id
        ) {
            runtime.occurrenceRecords[index].state = .skipped(reason: reason, at: date)
        }
        runtime.pendingOccurrenceIDs.removeAll()
        runtimeStates[taskID] = runtime
    }

    private func drainPending(
        taskID: UUID,
        browserAvailability: AgentTaskBrowserAvailability,
        at date: Date
    ) -> [AgentTaskOccurrenceAdmission] {
        guard runtimeStates[taskID]?.occurrenceRecords.contains(where: {
            $0.state.isActive
        }) != true else { return [] }
        var admissions: [AgentTaskOccurrenceAdmission] = []
        while var runtime = runtimeStates[taskID],
              let occurrenceID = runtime.pendingOccurrenceIDs.first {
            runtime.pendingOccurrenceIDs.removeFirst()
            guard let index = runtime.occurrenceRecords.firstIndex(where: {
                $0.id == occurrenceID && $0.state.isQueued
            }) else {
                runtimeStates[taskID] = runtime
                continue
            }
            let record = runtime.occurrenceRecords.remove(at: index)
            runtimeStates[taskID] = runtime
            let admission = startOrBlock(
                record.occurrence,
                definition: record.definitionSnapshot,
                browserAvailability: browserAvailability,
                at: date
            )
            admissions.append(admission)
            if case .start = admission { break }
        }
        return admissions
    }

    private func applyOutcomeNotifications(
        _ outcome: AgentTaskRunOutcome,
        record: AgentTaskOccurrenceRecord,
        definition: AgentTaskDefinition,
        runtime: inout AgentTaskRuntimeState,
        at date: Date
    ) {
        if outcome == .succeeded {
            runtime.consecutiveFailures = 0
            if definition.notificationPolicy.notifyOnSuccess {
                _ = enqueueNotification(
                    kind: .success,
                    record: record,
                    runtime: &runtime,
                    at: date
                )
            }
            return
        }
        guard outcome.countsAsFailure else { return }
        runtime.consecutiveFailures += 1
        if definition.notificationPolicy.notifyOnEveryFailure,
           let category = outcome.failureCategory {
            _ = enqueueNotification(
                kind: .failure(category),
                record: record,
                runtime: &runtime,
                at: date
            )
        }
        if shouldNotifyRepeatedFailure(
            count: runtime.consecutiveFailures,
            policy: definition.notificationPolicy.repeatedFailures
        ) {
            _ = enqueueNotification(
                kind: .repeatedFailure(count: runtime.consecutiveFailures),
                record: record,
                runtime: &runtime,
                at: date
            )
        }
    }

    private func registerBlockedFailure(
        record: AgentTaskOccurrenceRecord,
        runtimeTaskID: UUID,
        at date: Date
    ) {
        guard var runtime = runtimeStates[runtimeTaskID] else { return }
        applyOutcomeNotifications(
            .failed(.noBrowserWindow),
            record: record,
            definition: record.definitionSnapshot,
            runtime: &runtime,
            at: date
        )
        runtimeStates[runtimeTaskID] = runtime
    }

    private func shouldNotifyRepeatedFailure(
        count: Int,
        policy: AgentTaskRepeatedFailureNotificationPolicy
    ) -> Bool {
        switch policy {
        case .never: false
        case .once(let threshold): count == threshold
        case .recurring(let threshold, let repeatEvery):
            count >= threshold && (count - threshold).isMultiple(of: repeatEvery)
        }
    }

    @discardableResult
    private func enqueueNotification(
        kind: AgentTaskNotificationKind,
        record: AgentTaskOccurrenceRecord,
        runtime: inout AgentTaskRuntimeState,
        at date: Date
    ) -> AgentTaskNotification? {
        guard let runID = record.state.runID else { return nil }
        let notification = AgentTaskNotification(
            taskDefinitionID: record.occurrence.taskDefinitionID,
            occurrenceID: record.id,
            runID: runID,
            kind: kind,
            createdAt: date
        )
        guard !runtime.notifications.contains(where: { $0.id == notification.id }) else {
            return nil
        }
        runtime.notifications.append(notification)
        return notification
    }
}

private nonisolated extension AgentTaskOccurrenceState {
    var retentionCompletionDate: Date? {
        switch self {
        case .finished(_, _, let date), .blocked(_, _, let date): date
        case .queued, .running, .waitingForHuman, .skipped: nil
        }
    }
}
