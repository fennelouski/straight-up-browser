import Foundation

// Foundation-only contracts for bounded child Runs. WebKit and provider
// resources plug in through typed leases and cancellation registrations below.

nonisolated enum AgentRunGroupError: Error, Equatable, Sendable {
    case invalidObjective
    case objectiveTooLong(maximum: Int)
    case unknownTool(String)
    case invalidOrigin(String)
    case invalidReturnSchema(String)
    case invalidBudget(String)
    case authorityEscalation(String)
    case budgetEscalation(String)
    case wrongRunGroup(expected: UUID, actual: UUID)
    case unknownParent(UUID)
    case depthExceeded(maximum: Int)
    case invalidChildDepth(expected: Int, actual: Int)
    case fanOutExceeded(parentRunID: UUID, maximum: Int)
    case duplicateWork(existingRunID: UUID)
    case childNotFound(UUID)
    case invalidChildStatus(runID: UUID, expected: AgentRunStatus, actual: AgentRunStatus)
    case invalidHandoff(runID: UUID, validationErrors: [String])
    case approvalNotOwned(expectedRunID: UUID, actualRunID: UUID)
    case invalidMaximumDepth(Int)
    case invalidMaximumFanOut(Int)
    case invalidMaximumTotalChildren(Int)
    case totalChildrenExceeded(maximum: Int)
    case duplicateChildRun(UUID)
    case groupNotActive
    case unsupportedChildSchemaVersion(expected: Int, actual: Int)
    case handoffRequired(UUID)
    case childrenStillRunning([UUID])
    case pageNotAuthorized(runID: UUID, page: PageHandle)
    case duplicateManagedPage(PageHandle)
}

nonisolated struct AgentDelegationAuthority: Codable, Equatable, Sendable {
    var allowedTools: Set<String>
    var allowedPages: Set<PageHandle>
    var allowedOrigins: Set<String>
    var allowedBrowserSessions: Set<AgentBrowserSession>
    var coworkRootIdentities: Set<String>
    var mcpServerIdentities: Set<String>
    var permitsDataEgress: Bool
    var permitsContentRetention: Bool

    init(
        allowedTools: Set<String>,
        allowedPages: Set<PageHandle> = [],
        allowedOrigins: Set<String> = [],
        allowedBrowserSessions: Set<AgentBrowserSession> = [],
        coworkRootIdentities: Set<String> = [],
        mcpServerIdentities: Set<String> = [],
        permitsDataEgress: Bool = false,
        permitsContentRetention: Bool = false
    ) {
        self.allowedTools = allowedTools
        self.allowedPages = allowedPages
        self.allowedOrigins = allowedOrigins
        self.allowedBrowserSessions = allowedBrowserSessions
        self.coworkRootIdentities = coworkRootIdentities
        self.mcpServerIdentities = mcpServerIdentities
        self.permitsDataEgress = permitsDataEgress
        self.permitsContentRetention = permitsContentRetention
    }

    func validate(catalog: AgentToolCatalog = .canonical) throws {
        for tool in allowedTools.sorted() where catalog.descriptor(named: tool) == nil {
            throw AgentRunGroupError.unknownTool(tool)
        }
        for origin in allowedOrigins.sorted() where !Self.isCanonicalOrigin(origin) {
            throw AgentRunGroupError.invalidOrigin(origin)
        }
        if coworkRootIdentities.contains(where: { $0.isEmpty }) {
            throw AgentRunGroupError.authorityEscalation("coworkRootIdentities")
        }
        if mcpServerIdentities.contains(where: { $0.isEmpty }) {
            throw AgentRunGroupError.authorityEscalation("mcpServerIdentities")
        }
    }

    func validateSubset(of parent: Self) throws {
        guard allowedTools.isSubset(of: parent.allowedTools) else {
            throw AgentRunGroupError.authorityEscalation("allowedTools")
        }
        guard allowedPages.isSubset(of: parent.allowedPages) else {
            throw AgentRunGroupError.authorityEscalation("allowedPages")
        }
        guard allowedOrigins.isSubset(of: parent.allowedOrigins) else {
            throw AgentRunGroupError.authorityEscalation("allowedOrigins")
        }
        guard allowedBrowserSessions.isSubset(of: parent.allowedBrowserSessions) else {
            throw AgentRunGroupError.authorityEscalation("allowedBrowserSessions")
        }
        guard coworkRootIdentities.isSubset(of: parent.coworkRootIdentities) else {
            throw AgentRunGroupError.authorityEscalation("coworkRootIdentities")
        }
        guard mcpServerIdentities.isSubset(of: parent.mcpServerIdentities) else {
            throw AgentRunGroupError.authorityEscalation("mcpServerIdentities")
        }
        guard !permitsDataEgress || parent.permitsDataEgress else {
            throw AgentRunGroupError.authorityEscalation("dataEgress")
        }
        guard !permitsContentRetention || parent.permitsContentRetention else {
            throw AgentRunGroupError.authorityEscalation("contentRetention")
        }
    }

    func runScope(
        for session: AgentBrowserSession,
        coworkRootIdentity: String? = nil,
        catalog: AgentToolCatalog = .canonical
    ) throws -> AgentRunScope {
        guard allowedBrowserSessions.contains(session) else {
            throw AgentRunGroupError.authorityEscalation("allowedBrowserSessions")
        }
        if let coworkRootIdentity,
           !coworkRootIdentities.contains(coworkRootIdentity) {
            throw AgentRunGroupError.authorityEscalation("coworkRootIdentities")
        }
        var capabilities = Set<AgentCapability>()
        for tool in allowedTools.sorted() {
            guard let descriptor = catalog.descriptor(named: tool) else {
                throw AgentRunGroupError.unknownTool(tool)
            }
            capabilities.formUnion(descriptor.requiredCapabilities)
        }
        return AgentRunScope(
            capabilities: capabilities,
            pageIDs: Set(allowedPages.map(\.description)),
            origins: allowedOrigins,
            session: session,
            coworkRootIdentity: coworkRootIdentity,
            mcpServerIdentities: mcpServerIdentities
        )
    }

    private static func isCanonicalOrigin(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty else { return false }
        return components.string == value
    }
}

nonisolated struct AgentResourceBudget: Codable, Equatable, Sendable {
    let maximumProviderCostMicrounits: Int64
    let maximumElapsedMilliseconds: Int64
    let maximumSteps: Int
    let maximumToolCalls: Int
    let maximumOutputBytes: Int64
    let maximumChildCreatedPages: Int

    init(
        maximumProviderCostMicrounits: Int64,
        maximumElapsedMilliseconds: Int64,
        maximumSteps: Int,
        maximumToolCalls: Int,
        maximumOutputBytes: Int64,
        maximumChildCreatedPages: Int
    ) throws {
        guard maximumProviderCostMicrounits >= 0 else {
            throw AgentRunGroupError.invalidBudget("providerCost")
        }
        guard maximumElapsedMilliseconds > 0 else {
            throw AgentRunGroupError.invalidBudget("elapsedTime")
        }
        guard maximumSteps > 0 else {
            throw AgentRunGroupError.invalidBudget("steps")
        }
        guard maximumToolCalls >= 0 else {
            throw AgentRunGroupError.invalidBudget("toolCalls")
        }
        guard maximumOutputBytes >= 0 else {
            throw AgentRunGroupError.invalidBudget("outputBytes")
        }
        guard maximumChildCreatedPages >= 0 else {
            throw AgentRunGroupError.invalidBudget("childCreatedPages")
        }
        self.maximumProviderCostMicrounits = maximumProviderCostMicrounits
        self.maximumElapsedMilliseconds = maximumElapsedMilliseconds
        self.maximumSteps = maximumSteps
        self.maximumToolCalls = maximumToolCalls
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumChildCreatedPages = maximumChildCreatedPages
    }

    func validateSubset(of parent: Self) throws {
        guard maximumProviderCostMicrounits <= parent.maximumProviderCostMicrounits else {
            throw AgentRunGroupError.budgetEscalation("providerCost")
        }
        guard maximumElapsedMilliseconds <= parent.maximumElapsedMilliseconds else {
            throw AgentRunGroupError.budgetEscalation("elapsedTime")
        }
        guard maximumSteps <= parent.maximumSteps else {
            throw AgentRunGroupError.budgetEscalation("steps")
        }
        guard maximumToolCalls <= parent.maximumToolCalls else {
            throw AgentRunGroupError.budgetEscalation("toolCalls")
        }
        guard maximumOutputBytes <= parent.maximumOutputBytes else {
            throw AgentRunGroupError.budgetEscalation("outputBytes")
        }
        guard maximumChildCreatedPages <= parent.maximumChildCreatedPages else {
            throw AgentRunGroupError.budgetEscalation("childCreatedPages")
        }
    }
}

nonisolated struct AgentChildRunContract: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1
    static let maximumObjectiveLength = 4_096

    var schemaVersion: Int
    let childRunID: UUID
    let parentRunID: UUID
    let runGroupID: UUID
    let depth: Int
    let objective: String
    let authority: AgentDelegationAuthority
    let budget: AgentResourceBudget
    let returnSchema: AgentJSONSchema

    var id: UUID { childRunID }

    init(
        childRunID: UUID = UUID(),
        parentRunID: UUID,
        runGroupID: UUID,
        depth: Int,
        objective: String,
        authority: AgentDelegationAuthority,
        budget: AgentResourceBudget,
        returnSchema: AgentJSONSchema,
        validatingAgainst parentAuthority: AgentDelegationAuthority,
        parentBudget: AgentResourceBudget,
        catalog: AgentToolCatalog = .canonical
    ) throws {
        let normalizedObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedObjective.isEmpty else { throw AgentRunGroupError.invalidObjective }
        guard normalizedObjective.count <= Self.maximumObjectiveLength else {
            throw AgentRunGroupError.objectiveTooLong(maximum: Self.maximumObjectiveLength)
        }
        guard depth > 0 else { throw AgentRunGroupError.invalidChildDepth(expected: 1, actual: depth) }
        try authority.validate(catalog: catalog)
        try authority.validateSubset(of: parentAuthority)
        try budget.validateSubset(of: parentBudget)
        if let keyword = returnSchema.unsupportedKeyword {
            throw AgentRunGroupError.invalidReturnSchema(keyword)
        }
        schemaVersion = Self.schemaVersion
        self.childRunID = childRunID
        self.parentRunID = parentRunID
        self.runGroupID = runGroupID
        self.depth = depth
        self.objective = normalizedObjective
        self.authority = authority
        self.budget = budget
        self.returnSchema = returnSchema
    }

    func validateExecutionPermit(_ permit: AgentExecutionPermit) throws {
        guard permit.runID == childRunID else {
            throw AgentRunGroupError.approvalNotOwned(
                expectedRunID: childRunID,
                actualRunID: permit.runID
            )
        }
    }

    func validateHandoff(_ value: JSONValue) throws {
        let errors = returnSchema.validationErrors(for: value)
        guard errors.isEmpty else {
            throw AgentRunGroupError.invalidHandoff(
                runID: childRunID,
                validationErrors: errors
            )
        }
    }
}

nonisolated enum AgentRunGroupFailurePolicy: String, Codable, Equatable, Sendable {
    /// A failed child is recorded and independent siblings may finish. The
    /// parent receives both successful handoffs and structured failures.
    case continueIndependent
    /// The first failed child cancels every nonterminal sibling.
    case cancelRemaining
}

nonisolated enum AgentRunGroupCleanupPolicy: String, Codable, Equatable, Sendable {
    /// Close every hidden Page created for child work when the group reaches a
    /// terminal state. User-owned Pages are never closed by this policy.
    case secureDefault
    /// Retain child-created Pages until the user or browser closes them.
    case retainChildCreatedPages
}

nonisolated struct AgentRunGroup: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1
    static let maximumSupportedDepth = 8
    static let maximumSupportedFanOut = 32
    static let maximumSupportedTotalChildren = 256

    var schemaVersion: Int
    let id: UUID
    let rootRunID: UUID
    let objective: String
    let authority: AgentDelegationAuthority
    let budget: AgentResourceBudget
    let maximumDepth: Int
    let maximumFanOut: Int
    let maximumTotalChildren: Int
    let failurePolicy: AgentRunGroupFailurePolicy
    let cleanupPolicy: AgentRunGroupCleanupPolicy
    let createdAt: Date

    init(
        id: UUID = UUID(),
        rootRunID: UUID,
        objective: String,
        authority: AgentDelegationAuthority,
        budget: AgentResourceBudget,
        maximumDepth: Int,
        maximumFanOut: Int,
        maximumTotalChildren: Int = 64,
        failurePolicy: AgentRunGroupFailurePolicy,
        cleanupPolicy: AgentRunGroupCleanupPolicy,
        createdAt: Date = Date(),
        catalog: AgentToolCatalog = .canonical
    ) throws {
        let normalizedObjective = objective.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedObjective.isEmpty else {
            throw AgentRunGroupError.invalidObjective
        }
        guard normalizedObjective.count <= AgentChildRunContract.maximumObjectiveLength
        else {
            throw AgentRunGroupError.objectiveTooLong(
                maximum: AgentChildRunContract.maximumObjectiveLength
            )
        }
        guard (1...Self.maximumSupportedDepth).contains(maximumDepth) else {
            throw AgentRunGroupError.invalidMaximumDepth(maximumDepth)
        }
        guard (1...Self.maximumSupportedFanOut).contains(maximumFanOut) else {
            throw AgentRunGroupError.invalidMaximumFanOut(maximumFanOut)
        }
        guard (1...Self.maximumSupportedTotalChildren).contains(
            maximumTotalChildren
        ) else {
            throw AgentRunGroupError.invalidMaximumTotalChildren(
                maximumTotalChildren
            )
        }
        try authority.validate(catalog: catalog)
        schemaVersion = Self.schemaVersion
        self.id = id
        self.rootRunID = rootRunID
        self.objective = normalizedObjective
        self.authority = authority
        self.budget = budget
        self.maximumDepth = maximumDepth
        self.maximumFanOut = maximumFanOut
        self.maximumTotalChildren = maximumTotalChildren
        self.failurePolicy = failurePolicy
        self.cleanupPolicy = cleanupPolicy
        self.createdAt = createdAt
    }
}

nonisolated enum AgentRunGroupLifecycleState: Codable, Equatable, Sendable {
    case active
    case synthesizing
    case succeeded
    case failed
    case cancelled
    case budgetExhausted(AgentBudgetResource)

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .budgetExhausted: true
        case .active, .synthesizing: false
        }
    }
}

nonisolated struct AgentChildRunHandoff: Codable, Equatable, Sendable {
    let childRunID: UUID
    let parentRunID: UUID
    let value: JSONValue
    let completedAt: Date
}

nonisolated struct AgentChildRunSnapshot: Codable, Equatable, Identifiable, Sendable {
    let contract: AgentChildRunContract
    let status: AgentRunStatus
    let registeredAt: Date
    let startedAt: Date?
    let finishedAt: Date?
    let handoff: AgentChildRunHandoff?
    let failureReason: String?

    var id: UUID { contract.childRunID }
}

nonisolated struct AgentRunGroupSnapshot: Codable, Equatable, Sendable {
    let group: AgentRunGroup
    let state: AgentRunGroupLifecycleState
    let children: [AgentChildRunSnapshot]
    let budget: AgentSharedBudgetSnapshot
    let terminationReason: String?
    let updatedAt: Date
}

nonisolated enum AgentRunCancellationComponent: String, Codable, CaseIterable, Sendable {
    case providerStream
    case wait
    case toolInvocation
    case page
    case other
}

nonisolated struct AgentRunCancellationRegistration: Hashable, Sendable {
    let id: UUID
    let runID: UUID
    let component: AgentRunCancellationComponent
}

nonisolated struct AgentRunGroupTerminationReport: Equatable, Sendable {
    let state: AgentRunGroupLifecycleState
    let cancelledRunIDs: [UUID]
    let childCreatedPagesToClose: [PageHandle]
    let reason: String?
}

nonisolated enum AgentBudgetResource: String, Codable, Equatable, Sendable {
    case providerCost
    case elapsedTime
    case steps
    case toolCalls
    case outputBytes
    case childCreatedPages
}

nonisolated struct AgentBudgetCharge: Codable, Equatable, Sendable {
    let providerCostMicrounits: Int64
    let steps: Int
    let toolCalls: Int
    let outputBytes: Int64
    let childCreatedPages: Int

    init(
        providerCostMicrounits: Int64 = 0,
        steps: Int = 0,
        toolCalls: Int = 0,
        outputBytes: Int64 = 0,
        childCreatedPages: Int = 0
    ) throws {
        guard providerCostMicrounits >= 0 else {
            throw AgentRunGroupError.invalidBudget("providerCostCharge")
        }
        guard steps >= 0 else { throw AgentRunGroupError.invalidBudget("stepCharge") }
        guard toolCalls >= 0 else { throw AgentRunGroupError.invalidBudget("toolCallCharge") }
        guard outputBytes >= 0 else { throw AgentRunGroupError.invalidBudget("outputByteCharge") }
        guard childCreatedPages >= 0 else {
            throw AgentRunGroupError.invalidBudget("childCreatedPageCharge")
        }
        self.providerCostMicrounits = providerCostMicrounits
        self.steps = steps
        self.toolCalls = toolCalls
        self.outputBytes = outputBytes
        self.childCreatedPages = childCreatedPages
    }
}

nonisolated struct AgentBudgetUsage: Codable, Equatable, Sendable {
    var providerCostMicrounits: Int64 = 0
    var steps: Int = 0
    var toolCalls: Int = 0
    var outputBytes: Int64 = 0
    var childCreatedPages: Int = 0

    fileprivate func adding(_ charge: AgentBudgetCharge) throws -> Self {
        func add(_ lhs: Int64, _ rhs: Int64, resource: AgentBudgetResource) throws -> Int64 {
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            guard !overflow else { throw AgentSharedBudgetError.limitExceeded(resource) }
            return value
        }
        func add(_ lhs: Int, _ rhs: Int, resource: AgentBudgetResource) throws -> Int {
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            guard !overflow else { throw AgentSharedBudgetError.limitExceeded(resource) }
            return value
        }
        return Self(
            providerCostMicrounits: try add(
                providerCostMicrounits,
                charge.providerCostMicrounits,
                resource: .providerCost
            ),
            steps: try add(steps, charge.steps, resource: .steps),
            toolCalls: try add(toolCalls, charge.toolCalls, resource: .toolCalls),
            outputBytes: try add(outputBytes, charge.outputBytes, resource: .outputBytes),
            childCreatedPages: try add(
                childCreatedPages,
                charge.childCreatedPages,
                resource: .childCreatedPages
            )
        )
    }

    fileprivate func firstExceededResource(for limits: AgentResourceBudget) -> AgentBudgetResource? {
        if providerCostMicrounits > limits.maximumProviderCostMicrounits { return .providerCost }
        if steps > limits.maximumSteps { return .steps }
        if toolCalls > limits.maximumToolCalls { return .toolCalls }
        if outputBytes > limits.maximumOutputBytes { return .outputBytes }
        if childCreatedPages > limits.maximumChildCreatedPages { return .childCreatedPages }
        return nil
    }
}

nonisolated enum AgentSharedBudgetState: Codable, Equatable, Sendable {
    case active
    case exhausted(AgentBudgetResource)
    case cancelled
}

nonisolated enum AgentSharedBudgetError: Error, Equatable, Sendable {
    case unknownRun(UUID)
    case duplicateRun(UUID)
    case limitExceeded(AgentBudgetResource)
    case unavailable(AgentSharedBudgetState)
}

nonisolated struct AgentSharedBudgetSnapshot: Codable, Equatable, Sendable {
    let rootRunID: UUID
    let limits: AgentResourceBudget
    let totalUsage: AgentBudgetUsage
    let usageByRun: [UUID: AgentBudgetUsage]
    let state: AgentSharedBudgetState
    let elapsedMilliseconds: Int64
}

actor AgentSharedRunGroupBudget {
    private struct Account: Sendable {
        let limits: AgentResourceBudget
        let startedAt: Date
        var usage: AgentBudgetUsage
    }

    let rootRunID: UUID
    let limits: AgentResourceBudget
    let startedAt: Date
    private var totalUsage = AgentBudgetUsage()
    private var accounts: [UUID: Account]
    private var state: AgentSharedBudgetState = .active

    init(rootRunID: UUID, limits: AgentResourceBudget, startedAt: Date = Date()) {
        self.rootRunID = rootRunID
        self.limits = limits
        self.startedAt = startedAt
        accounts = [
            rootRunID: Account(limits: limits, startedAt: startedAt, usage: AgentBudgetUsage()),
        ]
    }

    func registerChild(
        runID: UUID,
        limits childLimits: AgentResourceBudget,
        at date: Date = Date()
    ) throws {
        guard case .active = state else { throw AgentSharedBudgetError.unavailable(state) }
        if elapsedMilliseconds(from: startedAt, to: date)
            > limits.maximumElapsedMilliseconds {
            _ = try exhaust(.elapsedTime)
        }
        guard accounts[runID] == nil else { throw AgentSharedBudgetError.duplicateRun(runID) }
        try childLimits.validateSubset(of: limits)
        accounts[runID] = Account(
            limits: childLimits,
            startedAt: max(date, startedAt),
            usage: AgentBudgetUsage()
        )
    }

    @discardableResult
    func consume(
        runID: UUID,
        charge: AgentBudgetCharge,
        at date: Date = Date()
    ) throws -> AgentSharedBudgetSnapshot {
        guard case .active = state else { throw AgentSharedBudgetError.unavailable(state) }
        guard var account = accounts[runID] else { throw AgentSharedBudgetError.unknownRun(runID) }

        if elapsedMilliseconds(from: startedAt, to: date) > limits.maximumElapsedMilliseconds
            || elapsedMilliseconds(from: account.startedAt, to: date) > account.limits.maximumElapsedMilliseconds {
            return try exhaust(.elapsedTime)
        }

        let projectedAccount: AgentBudgetUsage
        let projectedTotal: AgentBudgetUsage
        do {
            projectedAccount = try account.usage.adding(charge)
            projectedTotal = try totalUsage.adding(charge)
        } catch let error as AgentSharedBudgetError {
            if case .limitExceeded(let resource) = error { return try exhaust(resource) }
            throw error
        }
        if let resource = projectedAccount.firstExceededResource(for: account.limits)
            ?? projectedTotal.firstExceededResource(for: limits) {
            return try exhaust(resource)
        }

        account.usage = projectedAccount
        accounts[runID] = account
        totalUsage = projectedTotal
        return makeSnapshot(at: date)
    }

    func cancel() {
        guard case .active = state else { return }
        state = .cancelled
    }

    func snapshot(at date: Date = Date()) -> AgentSharedBudgetSnapshot {
        if case .active = state,
           elapsedMilliseconds(from: startedAt, to: date) > limits.maximumElapsedMilliseconds {
            state = .exhausted(.elapsedTime)
        }
        return makeSnapshot(at: date)
    }

    private func exhaust(_ resource: AgentBudgetResource) throws -> AgentSharedBudgetSnapshot {
        state = .exhausted(resource)
        throw AgentSharedBudgetError.limitExceeded(resource)
    }

    private func makeSnapshot(at date: Date) -> AgentSharedBudgetSnapshot {
        AgentSharedBudgetSnapshot(
            rootRunID: rootRunID,
            limits: limits,
            totalUsage: totalUsage,
            usageByRun: accounts.mapValues(\.usage),
            state: state,
            elapsedMilliseconds: elapsedMilliseconds(from: startedAt, to: date)
        )
    }

    private func elapsedMilliseconds(from start: Date, to end: Date) -> Int64 {
        let interval = max(0, end.timeIntervalSince(start))
        let milliseconds = interval * 1_000
        guard milliseconds < Double(Int64.max) else { return Int64.max }
        return Int64(milliseconds.rounded(.down))
    }
}

nonisolated enum AgentPageLeaseAccess: String, Codable, Equatable, Sendable {
    case read
    case write
}

nonisolated enum AgentManagedPageOwnership: Codable, Equatable, Sendable {
    case userOwned
    case childCreated(ownerRunID: UUID)
    case runCreated(ownerRunID: UUID)
}

nonisolated struct AgentPageLeaseVersion: Codable, Equatable, Sendable {
    let navigation: PageNavigationGeneration
    let document: PageDocumentGeneration
}

nonisolated struct AgentPageLeaseRequest: Codable, Equatable, Sendable {
    let page: PageHandle
    let access: AgentPageLeaseAccess
    let runID: UUID
    let permit: AgentExecutionPermit?

    init(
        page: PageHandle,
        access: AgentPageLeaseAccess,
        runID: UUID,
        permit: AgentExecutionPermit? = nil
    ) {
        self.page = page
        self.access = access
        self.runID = runID
        self.permit = permit
    }
}

nonisolated struct AgentPageLeaseGrant: Codable, Equatable, Sendable {
    let page: PageHandle
    let access: AgentPageLeaseAccess
    let version: AgentPageLeaseVersion
}

nonisolated struct AgentPageLease: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let runID: UUID
    let grants: [AgentPageLeaseGrant]
}

nonisolated enum AgentPageLeaseError: Error, Equatable, Sendable {
    case emptyRequest
    case mixedRunIDs
    case duplicatePageRequest(PageHandle)
    case pageNotRegistered(PageHandle)
    case pageClosed(PageHandle)
    case writeApprovalRequired(PageHandle)
    case approvalRunMismatch(expectedRunID: UUID, actualRunID: UUID)
    case nestedAcquisitionForbidden(runID: UUID)
    case cancelled(runID: UUID)
    case inactiveLease(UUID)
    case pageVersionChanged(
        page: PageHandle,
        expected: AgentPageLeaseVersion,
        actual: AgentPageLeaseVersion
    )
}

actor AgentPageLeaseCoordinator {
    private struct PageRecord: Sendable {
        var ownership: AgentManagedPageOwnership
        var version: AgentPageLeaseVersion
    }

    private struct Holder: Sendable {
        let leaseID: UUID
        let runID: UUID
        let access: AgentPageLeaseAccess
    }

    private struct Waiter {
        let id: UUID
        let runID: UUID
        let requests: [AgentPageLeaseRequest]
        let continuation: CheckedContinuation<AgentPageLease, any Error>
    }

    private var pages: [PageHandle: PageRecord] = [:]
    private var holders: [PageHandle: [Holder]] = [:]
    private var activeLeases: [UUID: AgentPageLease] = [:]
    private var waiters: [Waiter] = []

    func register(
        page: PageHandle,
        ownership: AgentManagedPageOwnership,
        version: AgentPageLeaseVersion
    ) {
        pages[page] = PageRecord(ownership: ownership, version: version)
    }

    func acquire(_ requests: [AgentPageLeaseRequest]) async throws -> AgentPageLease {
        guard let cancellationRunID = requests.first?.runID else {
            throw AgentPageLeaseError.emptyRequest
        }
        let waiterID = UUID()
        let lease = try await withTaskCancellationHandler {
            guard !Task.isCancelled else {
                throw AgentPageLeaseError.cancelled(runID: cancellationRunID)
            }
            return try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    waiterID: waiterID,
                    requests: requests,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
        guard !Task.isCancelled else {
            release(lease)
            throw AgentPageLeaseError.cancelled(runID: cancellationRunID)
        }
        return lease
    }

    func release(_ lease: AgentPageLease) {
        guard activeLeases[lease.id] != nil else { return }
        revokeLease(lease)
        processWaiters()
    }

    func releaseAll(for runID: UUID) {
        let queued = waiters.filter { $0.runID == runID }
        waiters.removeAll { $0.runID == runID }
        for waiter in queued {
            waiter.continuation.resume(throwing: AgentPageLeaseError.cancelled(runID: runID))
        }

        let leases = activeLeases.values.filter { $0.runID == runID }
        for lease in leases {
            revokeLease(lease)
        }
        processWaiters()
    }

    func didNavigate(
        page: PageHandle,
        navigation: PageNavigationGeneration,
        document: PageDocumentGeneration
    ) throws {
        guard var record = pages[page] else { throw AgentPageLeaseError.pageNotRegistered(page) }
        record.version = AgentPageLeaseVersion(navigation: navigation, document: document)
        pages[page] = record
    }

    func didReplaceDocument(
        page: PageHandle,
        document: PageDocumentGeneration
    ) throws {
        guard var record = pages[page] else { throw AgentPageLeaseError.pageNotRegistered(page) }
        record.version = AgentPageLeaseVersion(
            navigation: record.version.navigation,
            document: document
        )
        pages[page] = record
    }

    func close(page: PageHandle) {
        pages.removeValue(forKey: page)
        let invalidatedLeases = activeLeases.values.filter { lease in
            lease.grants.contains { $0.page == page }
        }
        for lease in invalidatedLeases {
            revokeLease(lease)
        }
        holders.removeValue(forKey: page)
        let failed = waiters.filter { waiter in waiter.requests.contains { $0.page == page } }
        waiters.removeAll { waiter in waiter.requests.contains { $0.page == page } }
        for waiter in failed {
            waiter.continuation.resume(throwing: AgentPageLeaseError.pageClosed(page))
        }
        processWaiters()
    }

    func validateObservation(in lease: AgentPageLease, page: PageHandle) throws {
        guard activeLeases[lease.id] == lease else {
            throw AgentPageLeaseError.inactiveLease(lease.id)
        }
        guard let expected = lease.grants.first(where: { $0.page == page })?.version else {
            throw AgentPageLeaseError.inactiveLease(lease.id)
        }
        guard let actual = pages[page]?.version else { throw AgentPageLeaseError.pageClosed(page) }
        guard expected == actual else {
            throw AgentPageLeaseError.pageVersionChanged(
                page: page,
                expected: expected,
                actual: actual
            )
        }
    }

    func queuedRequestCount() -> Int { waiters.count }

    func activeLeaseCount(for page: PageHandle) -> Int {
        holders[page, default: []].count
    }

    func ownership(of page: PageHandle) -> AgentManagedPageOwnership? {
        pages[page]?.ownership
    }

    func transferToUserOwnership(page: PageHandle) throws {
        guard var record = pages[page] else {
            throw AgentPageLeaseError.pageNotRegistered(page)
        }
        record.ownership = .userOwned
        pages[page] = record
    }

    func registeredPages(createdBy runID: UUID) -> [PageHandle] {
        pages
            .filter {
                $0.value.ownership == .childCreated(ownerRunID: runID)
                    || $0.value.ownership == .runCreated(ownerRunID: runID)
            }
            .map(\.key)
            .sorted { $0.description < $1.description }
    }

    private func enqueue(
        waiterID: UUID,
        requests: [AgentPageLeaseRequest],
        continuation: CheckedContinuation<AgentPageLease, any Error>
    ) {
        do {
            let normalized = try validateAndNormalize(requests)
            let runID = try requiredRunID(normalized)
            guard !activeLeases.values.contains(where: { $0.runID == runID }),
                  !waiters.contains(where: { $0.runID == runID }) else {
                throw AgentPageLeaseError.nestedAcquisitionForbidden(runID: runID)
            }
            if waiters.isEmpty, canGrant(normalized) {
                continuation.resume(returning: grant(normalized, runID: runID))
            } else {
                waiters.append(Waiter(
                    id: waiterID,
                    runID: runID,
                    requests: normalized,
                    continuation: continuation
                ))
            }
        } catch {
            continuation.resume(throwing: error)
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(
            throwing: AgentPageLeaseError.cancelled(runID: waiter.runID)
        )
        processWaiters()
    }

    private func revokeLease(_ lease: AgentPageLease) {
        activeLeases.removeValue(forKey: lease.id)
        for grant in lease.grants {
            holders[grant.page]?.removeAll { $0.leaseID == lease.id }
            if holders[grant.page]?.isEmpty == true {
                holders.removeValue(forKey: grant.page)
            }
        }
    }

    private func validateAndNormalize(
        _ requests: [AgentPageLeaseRequest]
    ) throws -> [AgentPageLeaseRequest] {
        guard !requests.isEmpty else { throw AgentPageLeaseError.emptyRequest }
        let runID = try requiredRunID(requests)
        guard requests.allSatisfy({ $0.runID == runID }) else {
            throw AgentPageLeaseError.mixedRunIDs
        }
        var seen = Set<PageHandle>()
        for request in requests {
            guard seen.insert(request.page).inserted else {
                throw AgentPageLeaseError.duplicatePageRequest(request.page)
            }
            guard let page = pages[request.page] else {
                throw AgentPageLeaseError.pageNotRegistered(request.page)
            }
            guard request.access == .write else { continue }
            let ownsPage: Bool
            switch page.ownership {
            case .userOwned:
                ownsPage = false
            case .childCreated(let ownerRunID), .runCreated(let ownerRunID):
                ownsPage = ownerRunID == request.runID
            }
            if !ownsPage {
                guard let permit = request.permit else {
                    throw AgentPageLeaseError.writeApprovalRequired(request.page)
                }
                guard permit.runID == request.runID else {
                    throw AgentPageLeaseError.approvalRunMismatch(
                        expectedRunID: request.runID,
                        actualRunID: permit.runID
                    )
                }
            } else if let permit = request.permit, permit.runID != request.runID {
                throw AgentPageLeaseError.approvalRunMismatch(
                    expectedRunID: request.runID,
                    actualRunID: permit.runID
                )
            }
        }
        return requests.sorted { $0.page.description < $1.page.description }
    }

    private func requiredRunID(_ requests: [AgentPageLeaseRequest]) throws -> UUID {
        guard let runID = requests.first?.runID else { throw AgentPageLeaseError.emptyRequest }
        return runID
    }

    private func canGrant(_ requests: [AgentPageLeaseRequest]) -> Bool {
        requests.allSatisfy { request in
            let current = holders[request.page, default: []]
            switch request.access {
            case .read:
                return current.allSatisfy { $0.access == .read }
            case .write:
                return current.isEmpty
            }
        }
    }

    private func grant(_ requests: [AgentPageLeaseRequest], runID: UUID) -> AgentPageLease {
        let leaseID = UUID()
        let grants = requests.compactMap { request -> AgentPageLeaseGrant? in
            guard let version = pages[request.page]?.version else { return nil }
            holders[request.page, default: []].append(Holder(
                leaseID: leaseID,
                runID: runID,
                access: request.access
            ))
            return AgentPageLeaseGrant(
                page: request.page,
                access: request.access,
                version: version
            )
        }
        let lease = AgentPageLease(id: leaseID, runID: runID, grants: grants)
        activeLeases[leaseID] = lease
        return lease
    }

    private func processWaiters() {
        while let waiter = waiters.first, canGrant(waiter.requests) {
            waiters.removeFirst()
            waiter.continuation.resume(returning: grant(waiter.requests, runID: waiter.runID))
        }
    }
}

actor AgentRunGroupCoordinator {
    private struct ChildRecord: Sendable {
        let contract: AgentChildRunContract
        let registeredAt: Date
        var status: AgentRunStatus = .queued
        var startedAt: Date?
        var finishedAt: Date?
        var handoff: AgentChildRunHandoff?
        var failureReason: String?

        var snapshot: AgentChildRunSnapshot {
            AgentChildRunSnapshot(
                contract: contract,
                status: status,
                registeredAt: registeredAt,
                startedAt: startedAt,
                finishedAt: finishedAt,
                handoff: handoff,
                failureReason: failureReason
            )
        }
    }

    private struct CancellationHandler: Sendable {
        let registration: AgentRunCancellationRegistration
        let action: @Sendable () -> Void
    }

    let group: AgentRunGroup
    let sharedBudget: AgentSharedRunGroupBudget
    let pageLeases: AgentPageLeaseCoordinator
    private let validationCatalog: AgentToolCatalog

    private var childRecords: [UUID: ChildRecord] = [:]
    private var childIDsByParent: [UUID: Set<UUID>] = [:]
    private var childRunIDByNormalizedObjective: [String: UUID]
    private var cancellationHandlers: [UUID: [UUID: CancellationHandler]] = [:]
    private var managedPageOwnerByPage: [PageHandle: UUID] = [:]
    private var pageCleanupHandlers: [PageHandle: @Sendable () -> Void] = [:]
    private var state: AgentRunGroupLifecycleState = .active
    private var terminationReason: String?
    private var updatedAt: Date

    init(
        group: AgentRunGroup,
        sharedBudget: AgentSharedRunGroupBudget? = nil,
        pageLeases: AgentPageLeaseCoordinator = AgentPageLeaseCoordinator(),
        validationCatalog: AgentToolCatalog = .canonical
    ) {
        self.group = group
        self.sharedBudget = sharedBudget ?? AgentSharedRunGroupBudget(
            rootRunID: group.rootRunID,
            limits: group.budget,
            startedAt: group.createdAt
        )
        self.pageLeases = pageLeases
        self.validationCatalog = validationCatalog
        childRunIDByNormalizedObjective = [
            Self.normalizedObjective(group.objective): group.rootRunID,
        ]
        updatedAt = group.createdAt
    }

    func registerChild(
        _ contract: AgentChildRunContract,
        at date: Date = Date()
    ) async throws {
        guard state == .active else { throw AgentRunGroupError.groupNotActive }
        guard contract.schemaVersion == AgentChildRunContract.schemaVersion else {
            throw AgentRunGroupError.unsupportedChildSchemaVersion(
                expected: AgentChildRunContract.schemaVersion,
                actual: contract.schemaVersion
            )
        }
        guard contract.runGroupID == group.id else {
            throw AgentRunGroupError.wrongRunGroup(
                expected: group.id,
                actual: contract.runGroupID
            )
        }
        guard contract.childRunID != group.rootRunID,
              childRecords[contract.childRunID] == nil else {
            throw AgentRunGroupError.duplicateChildRun(contract.childRunID)
        }
        guard contract.depth <= group.maximumDepth else {
            throw AgentRunGroupError.depthExceeded(maximum: group.maximumDepth)
        }

        let parentAuthority: AgentDelegationAuthority
        let parentBudget: AgentResourceBudget
        let expectedDepth: Int
        if contract.parentRunID == group.rootRunID {
            parentAuthority = group.authority
            parentBudget = group.budget
            expectedDepth = 1
        } else {
            guard let parent = childRecords[contract.parentRunID] else {
                throw AgentRunGroupError.unknownParent(contract.parentRunID)
            }
            parentAuthority = parent.contract.authority
            parentBudget = parent.contract.budget
            expectedDepth = parent.contract.depth + 1
        }
        guard contract.depth == expectedDepth else {
            throw AgentRunGroupError.invalidChildDepth(
                expected: expectedDepth,
                actual: contract.depth
            )
        }
        try contract.authority.validate(catalog: validationCatalog)
        try contract.authority.validateSubset(of: parentAuthority)
        try contract.budget.validateSubset(of: parentBudget)
        if let keyword = contract.returnSchema.unsupportedKeyword {
            throw AgentRunGroupError.invalidReturnSchema(keyword)
        }

        let normalizedObjective = Self.normalizedObjective(contract.objective)
        guard !normalizedObjective.isEmpty else {
            throw AgentRunGroupError.invalidObjective
        }
        if let existingRunID = childRunIDByNormalizedObjective[normalizedObjective] {
            throw AgentRunGroupError.duplicateWork(existingRunID: existingRunID)
        }
        guard childRecords.count < group.maximumTotalChildren else {
            throw AgentRunGroupError.totalChildrenExceeded(
                maximum: group.maximumTotalChildren
            )
        }
        let siblings = childIDsByParent[contract.parentRunID, default: []]
        guard siblings.count < group.maximumFanOut else {
            throw AgentRunGroupError.fanOutExceeded(
                parentRunID: contract.parentRunID,
                maximum: group.maximumFanOut
            )
        }

        // Reserve before crossing the actor boundary so concurrent registrations
        // observe the same caps and duplicate-work index.
        childRecords[contract.childRunID] = ChildRecord(
            contract: contract,
            registeredAt: date
        )
        childIDsByParent[contract.parentRunID, default: []].insert(
            contract.childRunID
        )
        childRunIDByNormalizedObjective[normalizedObjective] = contract.childRunID
        updatedAt = date
        do {
            try await sharedBudget.registerChild(
                runID: contract.childRunID,
                limits: contract.budget,
                at: date
            )
        } catch {
            rollbackRegistration(contract, normalizedObjective: normalizedObjective)
            if let budgetError = error as? AgentSharedBudgetError {
                await propagateBudgetFailureIfNeeded(budgetError, at: date)
            }
            throw error
        }
    }

    func startChild(_ runID: UUID, at date: Date = Date()) throws {
        try updateChildRecord(runID, to: .running, at: date)
    }

    func transitionChild(
        _ runID: UUID,
        to newStatus: AgentRunStatus,
        failureReason: String? = nil,
        at date: Date = Date()
    ) async throws {
        switch newStatus {
        case .succeeded:
            throw AgentRunGroupError.handoffRequired(runID)
        case .failed:
            try await failChild(runID, reason: failureReason ?? "Child run failed", at: date)
        case .cancelled:
            _ = try await cancelChild(runID, reason: failureReason, at: date)
        default:
            try updateChildRecord(runID, to: newStatus, at: date)
        }
    }

    @discardableResult
    func completeChild(
        _ runID: UUID,
        handoff value: JSONValue,
        at date: Date = Date()
    ) async throws -> AgentChildRunHandoff {
        guard !state.isTerminal else { throw AgentRunGroupError.groupNotActive }
        guard var record = childRecords[runID] else {
            throw AgentRunGroupError.childNotFound(runID)
        }
        let unfinishedDescendants = descendantRunIDs(of: runID).filter {
            childRecords[$0]?.status.isTerminal == false
        }
        guard unfinishedDescendants.isEmpty else {
            throw AgentRunGroupError.childrenStillRunning(
                unfinishedDescendants.sorted(by: Self.sortUUID)
            )
        }
        do {
            try AgentRunStateMachine.validateTransition(
                from: record.status,
                to: .succeeded
            )
        } catch {
            throw AgentRunGroupError.invalidChildStatus(
                runID: runID,
                expected: .running,
                actual: record.status
            )
        }
        try record.contract.validateHandoff(value)
        let handoff = AgentChildRunHandoff(
            childRunID: runID,
            parentRunID: record.contract.parentRunID,
            value: value,
            completedAt: date
        )
        record.status = .succeeded
        record.handoff = handoff
        record.finishedAt = date
        childRecords[runID] = record
        updatedAt = date
        discardCancellationHandlers(for: [runID])
        await pageLeases.releaseAll(for: runID)
        _ = await cleanUpChildCreatedPages(for: [runID])
        return handoff
    }

    func failChild(
        _ runID: UUID,
        reason: String,
        at date: Date = Date()
    ) async throws {
        guard !state.isTerminal else { throw AgentRunGroupError.groupNotActive }
        guard var record = childRecords[runID] else {
            throw AgentRunGroupError.childNotFound(runID)
        }
        do {
            try AgentRunStateMachine.validateTransition(from: record.status, to: .failed)
        } catch {
            throw AgentRunGroupError.invalidChildStatus(
                runID: runID,
                expected: .running,
                actual: record.status
            )
        }
        record.status = .failed
        record.finishedAt = date
        record.failureReason = reason
        childRecords[runID] = record
        updatedAt = date

        let descendants = descendantRunIDs(of: runID).filter {
            childRecords[$0]?.status.isTerminal == false
        }
        markCancelled(descendants, reason: "Ancestor run failed", at: date)
        let stoppedRuns = [runID] + descendants
        if group.failurePolicy == .cancelRemaining {
            invokeAndDiscardCancellationHandlers(for: stoppedRuns)
            _ = await terminateGroup(
                as: .failed,
                reason: reason,
                includeRootAsCancelled: false,
                at: date
            )
            return
        }

        invokeAndDiscardCancellationHandlers(for: stoppedRuns)
        for stoppedRunID in stoppedRuns {
            await pageLeases.releaseAll(for: stoppedRunID)
        }
        _ = await cleanUpChildCreatedPages(for: stoppedRuns)
    }

    @discardableResult
    func cancelChild(
        _ runID: UUID,
        reason: String? = nil,
        at date: Date = Date()
    ) async throws -> AgentRunGroupTerminationReport {
        guard !state.isTerminal else { throw AgentRunGroupError.groupNotActive }
        guard childRecords[runID] != nil else {
            throw AgentRunGroupError.childNotFound(runID)
        }
        let subtree = ([runID] + descendantRunIDs(of: runID)).filter {
            childRecords[$0]?.status.isTerminal == false
        }
        markCancelled(subtree, reason: reason, at: date)
        invokeAndDiscardCancellationHandlers(for: subtree)
        for stoppedRunID in subtree {
            await pageLeases.releaseAll(for: stoppedRunID)
        }
        let pages = await cleanUpChildCreatedPages(for: subtree)
        return AgentRunGroupTerminationReport(
            state: state,
            cancelledRunIDs: subtree.sorted(by: Self.sortUUID),
            childCreatedPagesToClose: pages,
            reason: reason
        )
    }

    func beginSynthesis(at date: Date = Date()) throws -> [AgentChildRunHandoff] {
        guard state == .active else { throw AgentRunGroupError.groupNotActive }
        let unfinished = childRecords.values
            .filter { !$0.status.isTerminal }
            .map { $0.contract.childRunID }
            .sorted(by: Self.sortUUID)
        guard unfinished.isEmpty else {
            throw AgentRunGroupError.childrenStillRunning(unfinished)
        }
        state = .synthesizing
        updatedAt = date
        return handoffs(for: group.rootRunID)
    }

    @discardableResult
    func completeSynthesis(
        succeeded: Bool,
        reason: String? = nil,
        at date: Date = Date()
    ) async throws -> AgentRunGroupTerminationReport {
        guard state == .synthesizing else {
            throw AgentRunGroupError.groupNotActive
        }
        return await terminateGroup(
            as: succeeded ? .succeeded : .failed,
            reason: reason,
            includeRootAsCancelled: false,
            at: date
        )
    }

    @discardableResult
    func cancel(
        reason: String? = nil,
        at date: Date = Date()
    ) async -> AgentRunGroupTerminationReport {
        guard !state.isTerminal else {
            return AgentRunGroupTerminationReport(
                state: state,
                cancelledRunIDs: [],
                childCreatedPagesToClose: [],
                reason: terminationReason
            )
        }
        return await terminateGroup(
            as: .cancelled,
            reason: reason,
            includeRootAsCancelled: true,
            at: date
        )
    }

    @discardableResult
    func consume(
        runID: UUID,
        charge: AgentBudgetCharge,
        at date: Date = Date()
    ) async throws -> AgentSharedBudgetSnapshot {
        try validateActiveRun(runID)
        do {
            return try await sharedBudget.consume(
                runID: runID,
                charge: charge,
                at: date
            )
        } catch let error as AgentSharedBudgetError {
            await propagateBudgetFailureIfNeeded(error, at: date)
            throw error
        }
    }

    func registerChildCreatedPage(
        _ page: PageHandle,
        ownerRunID: UUID,
        version: AgentPageLeaseVersion,
        closeHandler: (@Sendable () -> Void)? = nil,
        at date: Date = Date()
    ) async throws {
        try validateActiveRun(ownerRunID)
        guard ownerRunID != group.rootRunID else {
            throw AgentRunGroupError.pageNotAuthorized(
                runID: ownerRunID,
                page: page
            )
        }
        try await registerCreatedPage(
            page,
            ownerRunID: ownerRunID,
            ownership: .childCreated(ownerRunID: ownerRunID),
            version: version,
            closeHandler: closeHandler,
            at: date
        )
    }

    /// Root-created Pages remain inside the same coordinator authority. An
    /// attended Page is registered as user-owned, while a scheduled Page is
    /// registered as run-owned so cleanup policy can distinguish them.
    func registerRootCreatedPage(
        _ page: PageHandle,
        ownership: AgentManagedPageOwnership,
        version: AgentPageLeaseVersion,
        closeHandler: (@Sendable () -> Void)? = nil,
        at date: Date = Date()
    ) async throws {
        try validateActiveRun(group.rootRunID)
        switch ownership {
        case .userOwned:
            break
        case .runCreated(let ownerRunID):
            guard ownerRunID == group.rootRunID else {
                throw AgentRunGroupError.pageNotAuthorized(
                    runID: group.rootRunID,
                    page: page
                )
            }
        case .childCreated:
            throw AgentRunGroupError.pageNotAuthorized(
                runID: group.rootRunID,
                page: page
            )
        }
        try await registerCreatedPage(
            page,
            ownerRunID: group.rootRunID,
            ownership: ownership,
            version: version,
            closeHandler: closeHandler,
            at: date
        )
    }

    private func registerCreatedPage(
        _ page: PageHandle,
        ownerRunID: UUID,
        ownership: AgentManagedPageOwnership,
        version: AgentPageLeaseVersion,
        closeHandler: (@Sendable () -> Void)?,
        at date: Date
    ) async throws {
        guard managedPageOwnerByPage[page] == nil else {
            throw AgentRunGroupError.duplicateManagedPage(page)
        }
        managedPageOwnerByPage[page] = ownerRunID
        if let closeHandler { pageCleanupHandlers[page] = closeHandler }
        do {
            _ = try await consume(
                runID: ownerRunID,
                charge: AgentBudgetCharge(childCreatedPages: 1),
                at: date
            )
        } catch {
            managedPageOwnerByPage.removeValue(forKey: page)
            pageCleanupHandlers.removeValue(forKey: page)
            throw error
        }
        let ownerIsActive = ownerRunID == group.rootRunID
            || childRecords[ownerRunID]?.status.isTerminal == false
        guard !state.isTerminal,
              managedPageOwnerByPage[page] == ownerRunID,
              ownerIsActive else {
            throw AgentRunGroupError.groupNotActive
        }
        await pageLeases.register(
            page: page,
            ownership: ownership,
            version: version
        )
    }

    func acquirePageLease(
        _ requests: [AgentPageLeaseRequest]
    ) async throws -> AgentPageLease {
        guard let runID = requests.first?.runID else {
            throw AgentPageLeaseError.emptyRequest
        }
        try validateActiveRun(runID)
        let authority = try authority(for: runID)
        for request in requests {
            let ownsCreatedPage = managedPageOwnerByPage[request.page] == runID
            guard ownsCreatedPage || authority.allowedPages.contains(request.page) else {
                throw AgentRunGroupError.pageNotAuthorized(
                    runID: runID,
                    page: request.page
                )
            }
            if let permit = request.permit {
                guard permit.runID == runID else {
                    throw AgentRunGroupError.approvalNotOwned(
                        expectedRunID: runID,
                        actualRunID: permit.runID
                    )
                }
            }
        }
        let lease = try await pageLeases.acquire(requests)
        guard !state.isTerminal,
              runID == group.rootRunID
                || childRecords[runID]?.status.isTerminal == false else {
            await pageLeases.release(lease)
            throw AgentRunGroupError.groupNotActive
        }
        return lease
    }

    func releasePageLease(_ lease: AgentPageLease) async {
        await pageLeases.release(lease)
    }

    @discardableResult
    func registerCancellationHandler(
        for runID: UUID,
        component: AgentRunCancellationComponent,
        action: @escaping @Sendable () -> Void
    ) throws -> AgentRunCancellationRegistration {
        try validateActiveRun(runID)
        let registration = AgentRunCancellationRegistration(
            id: UUID(),
            runID: runID,
            component: component
        )
        cancellationHandlers[runID, default: [:]][registration.id] =
            CancellationHandler(registration: registration, action: action)
        return registration
    }

    func removeCancellationHandler(_ registration: AgentRunCancellationRegistration) {
        cancellationHandlers[registration.runID]?.removeValue(forKey: registration.id)
        if cancellationHandlers[registration.runID]?.isEmpty == true {
            cancellationHandlers.removeValue(forKey: registration.runID)
        }
    }

    func handoffs(for parentRunID: UUID) -> [AgentChildRunHandoff] {
        childIDsByParent[parentRunID, default: []]
            .compactMap { childRecords[$0]?.handoff }
            .sorted { Self.sortUUID($0.childRunID, $1.childRunID) }
    }

    func children(of parentRunID: UUID) -> [AgentChildRunSnapshot] {
        childIDsByParent[parentRunID, default: []]
            .compactMap { childRecords[$0]?.snapshot }
            .sorted(by: Self.sortChildSnapshots)
    }

    func child(_ runID: UUID) -> AgentChildRunSnapshot? {
        childRecords[runID]?.snapshot
    }

    func lifecycleState() -> AgentRunGroupLifecycleState { state }

    func snapshot(at date: Date = Date()) async -> AgentRunGroupSnapshot {
        let budgetSnapshot = await sharedBudget.snapshot(at: date)
        if case .exhausted(let resource) = budgetSnapshot.state,
           !state.isTerminal {
            _ = await terminateGroup(
                as: .budgetExhausted(resource),
                reason: "Shared run-group budget exhausted: \(resource.rawValue)",
                includeRootAsCancelled: true,
                at: date
            )
        }
        return AgentRunGroupSnapshot(
            group: group,
            state: state,
            children: childRecords.values
                .map(\.snapshot)
                .sorted(by: Self.sortChildSnapshots),
            budget: budgetSnapshot,
            terminationReason: terminationReason,
            updatedAt: updatedAt
        )
    }

    private func updateChildRecord(
        _ runID: UUID,
        to newStatus: AgentRunStatus,
        at date: Date
    ) throws {
        guard !state.isTerminal else { throw AgentRunGroupError.groupNotActive }
        guard var record = childRecords[runID] else {
            throw AgentRunGroupError.childNotFound(runID)
        }
        try AgentRunStateMachine.validateTransition(from: record.status, to: newStatus)
        record.status = newStatus
        if newStatus == .running, record.startedAt == nil { record.startedAt = date }
        if newStatus.isTerminal { record.finishedAt = date }
        childRecords[runID] = record
        updatedAt = date
    }

    private func validateActiveRun(_ runID: UUID) throws {
        guard !state.isTerminal else { throw AgentRunGroupError.groupNotActive }
        if runID == group.rootRunID { return }
        guard let record = childRecords[runID] else {
            throw AgentRunGroupError.childNotFound(runID)
        }
        guard !record.status.isTerminal else {
            throw AgentRunGroupError.invalidChildStatus(
                runID: runID,
                expected: .running,
                actual: record.status
            )
        }
    }

    private func authority(for runID: UUID) throws -> AgentDelegationAuthority {
        if runID == group.rootRunID { return group.authority }
        guard let record = childRecords[runID] else {
            throw AgentRunGroupError.childNotFound(runID)
        }
        return record.contract.authority
    }

    private func rollbackRegistration(
        _ contract: AgentChildRunContract,
        normalizedObjective: String
    ) {
        childRecords.removeValue(forKey: contract.childRunID)
        childIDsByParent[contract.parentRunID]?.remove(contract.childRunID)
        if childIDsByParent[contract.parentRunID]?.isEmpty == true {
            childIDsByParent.removeValue(forKey: contract.parentRunID)
        }
        if childRunIDByNormalizedObjective[normalizedObjective] == contract.childRunID {
            childRunIDByNormalizedObjective.removeValue(forKey: normalizedObjective)
        }
    }

    private func descendantRunIDs(of runID: UUID) -> [UUID] {
        var result: [UUID] = []
        var pending = childIDsByParent[runID, default: []].sorted(by: Self.sortUUID)
        while !pending.isEmpty {
            let next = pending.removeFirst()
            result.append(next)
            pending.append(contentsOf:
                childIDsByParent[next, default: []].sorted(by: Self.sortUUID)
            )
        }
        return result
    }

    private func markCancelled(_ runIDs: [UUID], reason: String?, at date: Date) {
        for runID in runIDs {
            guard var record = childRecords[runID], !record.status.isTerminal else {
                continue
            }
            record.status = .cancelled
            record.finishedAt = date
            record.failureReason = reason
            childRecords[runID] = record
        }
        if !runIDs.isEmpty { updatedAt = date }
    }

    private func invokeAndDiscardCancellationHandlers(for runIDs: [UUID]) {
        let handlers = takeCancellationHandlers(for: runIDs)
        for handler in handlers { handler.action() }
    }

    private func discardCancellationHandlers(for runIDs: [UUID]) {
        _ = takeCancellationHandlers(for: runIDs)
    }

    private func takeCancellationHandlers(
        for runIDs: [UUID]
    ) -> [CancellationHandler] {
        runIDs
            .sorted(by: Self.sortUUID)
            .flatMap { runID -> [CancellationHandler] in
                let handlers = cancellationHandlers.removeValue(forKey: runID)?.values ??
                    Dictionary<UUID, CancellationHandler>().values
                return handlers.sorted {
                    if $0.registration.component.rawValue != $1.registration.component.rawValue {
                        return $0.registration.component.rawValue < $1.registration.component.rawValue
                    }
                    return Self.sortUUID($0.registration.id, $1.registration.id)
                }
            }
    }

    private func cleanUpChildCreatedPages(for runIDs: [UUID]) async -> [PageHandle] {
        let runIDSet = Set(runIDs)
        let pages = managedPageOwnerByPage
            .filter { runIDSet.contains($0.value) }
            .map(\.key)
            .sorted { $0.description < $1.description }
        guard group.cleanupPolicy == .secureDefault else { return [] }
        let actions = pages.compactMap { pageCleanupHandlers.removeValue(forKey: $0) }
        for page in pages {
            managedPageOwnerByPage.removeValue(forKey: page)
            await pageLeases.close(page: page)
        }
        for action in actions { action() }
        return pages
    }

    private func propagateBudgetFailureIfNeeded(
        _ error: AgentSharedBudgetError,
        at date: Date
    ) async {
        let resource: AgentBudgetResource?
        switch error {
        case .limitExceeded(let exceeded):
            resource = exceeded
        case .unavailable(.exhausted(let exhausted)):
            resource = exhausted
        default:
            resource = nil
        }
        guard let resource, !state.isTerminal else { return }
        _ = await terminateGroup(
            as: .budgetExhausted(resource),
            reason: "Shared run-group budget exhausted: \(resource.rawValue)",
            includeRootAsCancelled: true,
            at: date
        )
    }

    private func terminateGroup(
        as terminalState: AgentRunGroupLifecycleState,
        reason: String?,
        includeRootAsCancelled: Bool,
        at date: Date
    ) async -> AgentRunGroupTerminationReport {
        guard !state.isTerminal else {
            return AgentRunGroupTerminationReport(
                state: state,
                cancelledRunIDs: [],
                childCreatedPagesToClose: [],
                reason: terminationReason
            )
        }
        state = terminalState
        terminationReason = reason
        updatedAt = date

        let activeChildRunIDs = childRecords.values
            .filter { !$0.status.isTerminal }
            .map { $0.contract.childRunID }
            .sorted(by: Self.sortUUID)
        markCancelled(activeChildRunIDs, reason: reason, at: date)
        var workRunIDs = activeChildRunIDs
        if includeRootAsCancelled { workRunIDs.insert(group.rootRunID, at: 0) }
        invokeAndDiscardCancellationHandlers(for: workRunIDs)

        let allRunIDs = [group.rootRunID] + childRecords.keys.sorted(by: Self.sortUUID)
        for runID in allRunIDs {
            await pageLeases.releaseAll(for: runID)
        }
        let pages = await cleanUpChildCreatedPages(for: Array(childRecords.keys))
        if group.cleanupPolicy == .retainChildCreatedPages {
            let retainedPages = managedPageOwnerByPage.keys.sorted {
                $0.description < $1.description
            }
            for page in retainedPages {
                try? await pageLeases.transferToUserOwnership(page: page)
            }
            managedPageOwnerByPage.removeAll()
            pageCleanupHandlers.removeAll()
        }
        if case .budgetExhausted = terminalState {
            // The budget actor already records the exact exhausted resource.
        } else {
            await sharedBudget.cancel()
        }
        discardCancellationHandlers(for: Array(cancellationHandlers.keys))
        return AgentRunGroupTerminationReport(
            state: terminalState,
            cancelledRunIDs: workRunIDs.sorted(by: Self.sortUUID),
            childCreatedPagesToClose: pages,
            reason: reason
        )
    }

    private nonisolated static func normalizedObjective(_ objective: String) -> String {
        objective
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private nonisolated static func sortUUID(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }

    private nonisolated static func sortChildSnapshots(
        _ lhs: AgentChildRunSnapshot,
        _ rhs: AgentChildRunSnapshot
    ) -> Bool {
        if lhs.contract.depth != rhs.contract.depth {
            return lhs.contract.depth < rhs.contract.depth
        }
        if lhs.contract.parentRunID != rhs.contract.parentRunID {
            return sortUUID(lhs.contract.parentRunID, rhs.contract.parentRunID)
        }
        return sortUUID(lhs.contract.childRunID, rhs.contract.childRunID)
    }
}
