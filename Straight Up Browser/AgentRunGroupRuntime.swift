import Foundation

/// Runtime-only parsing for the canonical child-delegation tool. Keeping this
/// at the built-in tool boundary prevents provider dictionaries from leaking
/// into the run-group coordinator.
nonisolated enum AgentDelegationRuntimeError: Error, Equatable, Sendable {
    case missingArgument(String)
    case invalidArgument(String)
    case invalidReturnSchema(String)
}

extension AgentDelegationRuntimeError: LocalizedError {
    nonisolated var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            "delegate_child_run requires \(name)."
        case .invalidArgument(let name):
            "delegate_child_run received an invalid \(name)."
        case .invalidReturnSchema(let detail):
            "delegate_child_run returnSchema is invalid: \(detail)."
        }
    }
}

nonisolated enum AgentDelegationRequestParser {
    private static let maximumSchemaDepth = 8
    private static let maximumSchemaProperties = 64

    static func contract(
        arguments: [String: Any],
        childRunID: UUID = UUID(),
        parentRunID: UUID,
        runGroupID: UUID,
        depth: Int,
        parentAuthority: AgentDelegationAuthority,
        parentBudget: AgentResourceBudget,
        catalog: AgentToolCatalog = .canonical
    ) throws -> AgentChildRunContract {
        let objective = try string("objective", in: arguments)
        let tools = Set(try strings("allowedTools", in: arguments))
        let pages = try Set(strings("allowedPages", in: arguments).map { raw in
            do { return try PageHandle(parsing: raw) }
            catch { throw AgentDelegationRuntimeError.invalidArgument("allowedPages") }
        })
        let origins = Set(try strings("allowedOrigins", in: arguments))
        let session = try browserSession(arguments)
        guard let rawBudget = arguments["budget"] as? [String: Any] else {
            throw AgentDelegationRuntimeError.missingArgument("budget")
        }
        let budget = try AgentResourceBudget(
            maximumProviderCostMicrounits: integer64(
                "maximumProviderCostMicrounits",
                in: rawBudget
            ),
            maximumElapsedMilliseconds: integer64(
                "maximumElapsedMilliseconds",
                in: rawBudget
            ),
            maximumSteps: integer("maximumSteps", in: rawBudget),
            maximumToolCalls: integer("maximumToolCalls", in: rawBudget),
            maximumOutputBytes: integer64("maximumOutputBytes", in: rawBudget),
            maximumChildCreatedPages: integer(
                "maximumChildCreatedPages",
                in: rawBudget
            )
        )
        guard let rawReturnSchema = arguments["returnSchema"] else {
            throw AgentDelegationRuntimeError.missingArgument("returnSchema")
        }
        let returnValue: JSONValue
        do { returnValue = try JSONValue(foundationValue: rawReturnSchema) }
        catch { throw AgentDelegationRuntimeError.invalidReturnSchema("not JSON") }
        let returnSchema = try schema(from: returnValue, depth: 0)
        guard case .object = returnSchema else {
            throw AgentDelegationRuntimeError.invalidReturnSchema("root must be an object")
        }

        let needsCowork = tools.contains { name in
            catalog.descriptor(named: name)?.origin == .cowork
        }
        let needsMCP = tools.contains { name in
            catalog.descriptor(named: name)?.requiredCapabilities.contains(.externalMCP) == true
        }
        let authority = AgentDelegationAuthority(
            allowedTools: tools,
            allowedPages: pages,
            allowedOrigins: origins,
            allowedBrowserSessions: [session],
            coworkRootIdentities: needsCowork ? parentAuthority.coworkRootIdentities : [],
            mcpServerIdentities: needsMCP ? parentAuthority.mcpServerIdentities : [],
            permitsDataEgress: needsMCP && parentAuthority.permitsDataEgress,
            permitsContentRetention: parentAuthority.permitsContentRetention
        )
        return try AgentChildRunContract(
            childRunID: childRunID,
            parentRunID: parentRunID,
            runGroupID: runGroupID,
            depth: depth,
            objective: objective,
            authority: authority,
            budget: budget,
            returnSchema: returnSchema,
            validatingAgainst: parentAuthority,
            parentBudget: parentBudget,
            catalog: catalog
        )
    }

    private static func browserSession(_ arguments: [String: Any]) throws -> AgentBrowserSession {
        switch try string("browserSession", in: arguments) {
        case "normal": return .normal
        case "incognito": return .incognito
        case "container":
            guard let id = UUID(uuidString: try string("containerID", in: arguments)) else {
                throw AgentDelegationRuntimeError.invalidArgument("containerID")
            }
            return .container(id)
        default:
            throw AgentDelegationRuntimeError.invalidArgument("browserSession")
        }
    }

    private static func string(_ name: String, in values: [String: Any]) throws -> String {
        guard let value = values[name] as? String else {
            throw AgentDelegationRuntimeError.missingArgument(name)
        }
        return value
    }

    private static func strings(_ name: String, in values: [String: Any]) throws -> [String] {
        guard let raw = values[name] as? [Any] else {
            throw AgentDelegationRuntimeError.missingArgument(name)
        }
        let strings = raw.compactMap { $0 as? String }
        guard strings.count == raw.count else {
            throw AgentDelegationRuntimeError.invalidArgument(name)
        }
        return strings
    }

    private static func integer(_ name: String, in values: [String: Any]) throws -> Int {
        let value = try integer64(name, in: values)
        guard let integer = Int(exactly: value) else {
            throw AgentDelegationRuntimeError.invalidArgument(name)
        }
        return integer
    }

    private static func integer64(_ name: String, in values: [String: Any]) throws -> Int64 {
        guard let number = values[name] as? NSNumber else {
            throw AgentDelegationRuntimeError.missingArgument(name)
        }
        let value = number.doubleValue
        guard value.isFinite, value.rounded() == value,
              value >= Double(Int64.min), value < Double(Int64.max) else {
            throw AgentDelegationRuntimeError.invalidArgument(name)
        }
        return Int64(value)
    }

    private static func schema(from value: JSONValue, depth: Int) throws -> AgentJSONSchema {
        guard depth < maximumSchemaDepth else {
            throw AgentDelegationRuntimeError.invalidReturnSchema("maximum depth exceeded")
        }
        guard case .object(let object) = value,
              case .string(let type)? = object["type"] else {
            throw AgentDelegationRuntimeError.invalidReturnSchema("every node needs a type")
        }
        let allowedKeys: Set<String>
        switch type {
        case "string": allowedKeys = ["type", "description", "enum"]
        case "boolean": allowedKeys = ["type", "description"]
        case "integer", "number":
            allowedKeys = ["type", "description", "minimum", "maximum"]
        case "array": allowedKeys = ["type", "description", "items"]
        case "object":
            allowedKeys = [
                "type", "description", "properties", "required",
                "additionalProperties",
            ]
        default:
            throw AgentDelegationRuntimeError.invalidReturnSchema("unsupported type \(type)")
        }
        if let unsupported = object.keys.sorted().first(where: { !allowedKeys.contains($0) }) {
            throw AgentDelegationRuntimeError.invalidReturnSchema(
                "unsupported keyword \(unsupported)"
            )
        }
        let description: String? = if case .string(let text)? = object["description"] {
            text
        } else {
            nil
        }

        switch type {
        case "string":
            let allowed: [String]?
            if case .array(let values)? = object["enum"] {
                allowed = try values.map {
                    guard case .string(let value) = $0 else {
                        throw AgentDelegationRuntimeError.invalidReturnSchema(
                            "string enum contains a non-string value"
                        )
                    }
                    return value
                }
            } else {
                allowed = nil
            }
            return .string(description: description, allowedValues: allowed)
        case "boolean":
            return .boolean(description: description)
        case "integer":
            return .integer(
                description: description,
                minimum: try optionalInteger("minimum", in: object),
                maximum: try optionalInteger("maximum", in: object)
            )
        case "number":
            return .number(
                description: description,
                minimum: try optionalNumber("minimum", in: object),
                maximum: try optionalNumber("maximum", in: object)
            )
        case "array":
            guard let items = object["items"] else {
                throw AgentDelegationRuntimeError.invalidReturnSchema("array needs items")
            }
            return .array(
                description: description,
                items: try schema(from: items, depth: depth + 1)
            )
        case "object":
            let propertyValues: [String: JSONValue]
            if case .object(let values)? = object["properties"] {
                propertyValues = values
            } else if object["properties"] == nil {
                propertyValues = [:]
            } else {
                throw AgentDelegationRuntimeError.invalidReturnSchema(
                    "properties must be an object"
                )
            }
            guard propertyValues.count <= maximumSchemaProperties else {
                throw AgentDelegationRuntimeError.invalidReturnSchema(
                    "too many properties"
                )
            }
            let required: Set<String>
            if case .array(let values)? = object["required"] {
                required = try Set(values.map {
                    guard case .string(let value) = $0 else {
                        throw AgentDelegationRuntimeError.invalidReturnSchema(
                            "required contains a non-string value"
                        )
                    }
                    return value
                })
            } else {
                required = []
            }
            guard required.isSubset(of: propertyValues.keys) else {
                throw AgentDelegationRuntimeError.invalidReturnSchema(
                    "required names an unknown property"
                )
            }
            let additional: Bool
            if case .boolean(let value)? = object["additionalProperties"] {
                additional = value
            } else {
                additional = false
            }
            var properties: [String: AgentJSONSchema] = [:]
            for key in propertyValues.keys.sorted() {
                properties[key] = try schema(
                    from: propertyValues[key]!,
                    depth: depth + 1
                )
            }
            return .object(
                description: description,
                properties: properties,
                required: required,
                additionalProperties: additional
            )
        default:
            throw AgentDelegationRuntimeError.invalidReturnSchema("unsupported type \(type)")
        }
    }

    private static func optionalInteger(
        _ key: String,
        in object: [String: JSONValue]
    ) throws -> Int? {
        guard let value = try optionalNumber(key, in: object) else { return nil }
        guard value.rounded() == value,
              value >= Double(Int.min), value <= Double(Int.max) else {
            throw AgentDelegationRuntimeError.invalidReturnSchema("\(key) is not an integer")
        }
        return Int(value)
    }

    private static func optionalNumber(
        _ key: String,
        in object: [String: JSONValue]
    ) throws -> Double? {
        guard let raw = object[key] else { return nil }
        guard case .number(let value) = raw, value.isFinite else {
            throw AgentDelegationRuntimeError.invalidReturnSchema("\(key) is not a number")
        }
        return value
    }
}

nonisolated struct AgentRunGroupTreeRow: Equatable, Identifiable, Sendable {
    let id: UUID
    let parentRunID: UUID?
    let depth: Int
    let objective: String
    let status: AgentRunStatus
    let failureReason: String?
    let hasHandoff: Bool
    let isRoot: Bool
}

nonisolated enum AgentRunGroupTreeProjector {
    static func rows(from snapshot: AgentRunGroupSnapshot) -> [AgentRunGroupTreeRow] {
        var childrenByParent = Dictionary(
            grouping: snapshot.children,
            by: { $0.contract.parentRunID }
        )
        for key in childrenByParent.keys {
            childrenByParent[key]?.sort {
                $0.contract.childRunID.uuidString < $1.contract.childRunID.uuidString
            }
        }
        var rows = [AgentRunGroupTreeRow(
            id: snapshot.group.rootRunID,
            parentRunID: nil,
            depth: 0,
            objective: snapshot.group.objective,
            status: rootStatus(snapshot.state),
            failureReason: snapshot.terminationReason,
            hasHandoff: false,
            isRoot: true
        )]
        var visited: Set<UUID> = [snapshot.group.rootRunID]

        func appendChildren(of parentRunID: UUID, depth: Int) {
            for child in childrenByParent[parentRunID, default: []] {
                guard visited.insert(child.id).inserted else { continue }
                rows.append(AgentRunGroupTreeRow(
                    id: child.id,
                    parentRunID: parentRunID,
                    depth: depth,
                    objective: child.contract.objective,
                    status: child.status,
                    failureReason: child.failureReason,
                    hasHandoff: child.handoff != nil,
                    isRoot: false
                ))
                appendChildren(of: child.id, depth: depth + 1)
            }
        }
        appendChildren(of: snapshot.group.rootRunID, depth: 1)
        for orphan in snapshot.children
            .filter({ !visited.contains($0.id) })
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            rows.append(AgentRunGroupTreeRow(
                id: orphan.id,
                parentRunID: orphan.contract.parentRunID,
                depth: max(1, orphan.contract.depth),
                objective: orphan.contract.objective,
                status: orphan.status,
                failureReason: orphan.failureReason,
                hasHandoff: orphan.handoff != nil,
                isRoot: false
            ))
        }
        return rows
    }

    private static func rootStatus(_ state: AgentRunGroupLifecycleState) -> AgentRunStatus {
        switch state {
        case .active, .synthesizing: .running
        case .succeeded: .succeeded
        case .cancelled: .cancelled
        case .failed, .budgetExhausted: .failed
        }
    }
}

nonisolated enum AgentRunGroupResultRenderer {
    static func value(
        snapshot: AgentRunGroupSnapshot,
        viewedBy parentRunID: UUID
    ) -> JSONValue {
        let rows = AgentRunGroupTreeProjector.rows(from: snapshot)
        let visibleChildren = rows.filter {
            $0.isRoot || $0.parentRunID == parentRunID || isDescendant(
                $0.id,
                of: parentRunID,
                rows: rows
            )
        }
        let handoffByRun = Dictionary(uniqueKeysWithValues: snapshot.children.compactMap {
            child in child.handoff.map { (child.id, $0.value) }
        })
        return .object([
            "ok": .boolean(true),
            "runGroupID": .string(snapshot.group.id.uuidString),
            "state": .string(stateName(snapshot.state)),
            "children": .array(visibleChildren.filter({ !$0.isRoot }).map { row in
                .object([
                    "runID": .string(row.id.uuidString),
                    "parentRunID": row.parentRunID.map { .string($0.uuidString) } ?? .null,
                    "depth": .number(Double(row.depth)),
                    "objective": .string(row.objective),
                    "status": .string(row.status.rawValue),
                    "failure": row.failureReason.map(JSONValue.string) ?? .null,
                    "handoff": handoffByRun[row.id] ?? .null,
                ])
            }),
            "budget": .object([
                "state": .string(budgetStateName(snapshot.budget.state)),
                "providerCostMicrounits": .number(Double(
                    snapshot.budget.totalUsage.providerCostMicrounits
                )),
                "steps": .number(Double(snapshot.budget.totalUsage.steps)),
                "toolCalls": .number(Double(snapshot.budget.totalUsage.toolCalls)),
                "outputBytes": .number(Double(snapshot.budget.totalUsage.outputBytes)),
                "childCreatedPages": .number(Double(
                    snapshot.budget.totalUsage.childCreatedPages
                )),
            ]),
        ])
    }

    private static func isDescendant(
        _ candidate: UUID,
        of ancestor: UUID,
        rows: [AgentRunGroupTreeRow]
    ) -> Bool {
        let parentByRun = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.parentRunID) })
        var cursor = parentByRun[candidate] ?? nil
        var visited = Set<UUID>()
        while let current = cursor, visited.insert(current).inserted {
            if current == ancestor { return true }
            cursor = parentByRun[current] ?? nil
        }
        return false
    }

    private static func stateName(_ state: AgentRunGroupLifecycleState) -> String {
        switch state {
        case .active: "active"
        case .synthesizing: "synthesizing"
        case .succeeded: "succeeded"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .budgetExhausted(let resource): "budgetExhausted:\(resource.rawValue)"
        }
    }

    private static func budgetStateName(_ state: AgentSharedBudgetState) -> String {
        switch state {
        case .active: "active"
        case .cancelled: "cancelled"
        case .exhausted(let resource): "exhausted:\(resource.rawValue)"
        }
    }
}

nonisolated enum AgentScheduledExecutionLimits {
    static func resolve(
        definition: AgentTaskDefinition,
        global: AgentExecutionLimits
    ) throws -> AgentExecutionLimits {
        try resolve(
            budgets: definition.budgets,
            timeoutSeconds: definition.timeoutSeconds,
            global: global
        )
    }

    static func resolve(
        budgets task: AgentTaskBudgets,
        timeoutSeconds: Int,
        global: AgentExecutionLimits
    ) throws -> AgentExecutionLimits {
        let taskCost = task.maximumProviderCostMicrounits.map(Int64.init)
        return try AgentExecutionLimits(
            maximumTurns: min(global.maximumTurns, task.maximumModelTurns),
            maximumToolCalls: min(
                global.maximumToolCalls,
                task.maximumToolCalls
            ),
            maximumElapsedMilliseconds: min(
                global.maximumElapsedMilliseconds,
                Int64(timeoutSeconds) * 1_000
            ),
            maximumProviderTokens: minimumOptionalLimit(
                global.maximumProviderTokens,
                task.maximumProviderTokens
            ),
            maximumProviderCostMicrounits: minimumOptionalLimit(
                global.maximumProviderCostMicrounits,
                taskCost
            ),
            maximumOpenPages: min(
                global.maximumOpenPages,
                task.maximumOpenBackgroundPages
            ),
            maximumModelResultBytes: min(
                global.maximumModelResultBytes,
                Int64(task.maximumOutputBytes)
            ),
            maximumDownloads: min(
                global.maximumDownloads,
                task.maximumDownloads
            ),
            maximumDownloadBytes: min(
                global.maximumDownloadBytes,
                task.maximumDownloadBytes
            ),
            maximumArtifacts: min(
                global.maximumArtifacts,
                task.maximumArtifacts
            ),
            maximumArtifactBytes: min(
                global.maximumArtifactBytes,
                Int64(task.maximumArtifactBytes)
            )
        )
    }

    private static func minimumOptionalLimit(
        _ lhs: Int64?,
        _ rhs: Int64?
    ) -> Int64? {
        switch (lhs, rhs) {
        case (nil, nil): nil
        case (.some(let value), nil), (nil, .some(let value)): value
        case (.some(let lhs), .some(let rhs)): min(lhs, rhs)
        }
    }
}

/// Cancellation may arrive before a just-created child Task is installed.
/// This handle closes that race without polling or inheriting actor state.
nonisolated final class AgentChildTaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancellationRequested = false

    func install(_ task: Task<Void, Never>) {
        let mustCancel = lock.withLock {
            self.task = task
            return cancellationRequested
        }
        if mustCancel { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock {
            cancellationRequested = true
            return self.task
        }
        task?.cancel()
    }

    func wait() async {
        let task = lock.withLock { self.task }
        await task?.value
    }
}
