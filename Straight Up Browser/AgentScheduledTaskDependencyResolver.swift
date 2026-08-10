import Foundation

/// Device-local resources that may satisfy a saved scheduled-task snapshot.
/// Credentials, bookmarks, and page content remain outside the persisted task.
nonisolated struct AgentScheduledTaskAvailableDependencies: Equatable, Sendable {
    var providerIDsWithLocalAccess: Set<String>
    var pagesByID: [String: AgentPageTarget]
    var availableBrowserSessionIDs: Set<UUID>
    var trustedMCPServerIdentitiesByConnectionID: [UUID: String]
    var coworkRootIdentitiesByBindingID: [UUID: String]

    init(
        providerIDsWithLocalAccess: Set<String> = [],
        pagesByID: [String: AgentPageTarget] = [:],
        availableBrowserSessionIDs: Set<UUID> = [],
        trustedMCPServerIdentitiesByConnectionID: [UUID: String] = [:],
        coworkRootIdentitiesByBindingID: [UUID: String] = [:]
    ) {
        self.providerIDsWithLocalAccess = providerIDsWithLocalAccess
        self.pagesByID = pagesByID
        self.availableBrowserSessionIDs = availableBrowserSessionIDs
        self.trustedMCPServerIdentitiesByConnectionID =
            trustedMCPServerIdentitiesByConnectionID
        self.coworkRootIdentitiesByBindingID = coworkRootIdentitiesByBindingID
    }
}

/// Secret-free resolution output passed to the run-scope materializer. It can
/// only narrow the authority persisted in `AgentTaskExecutionSnapshot`.
nonisolated struct AgentScheduledTaskResolvedDependencies: Equatable, Sendable {
    let mcpServerIdentities: Set<String>
    let coworkRootIdentity: String?
}

nonisolated enum AgentScheduledTaskDependencyFailure: Error, Equatable, Sendable {
    case providerUnavailable(String)
    case browserSessionUnavailable(UUID)
    case incognitoSessionUnavailable
    case pageUnavailable(String)
    case pageSessionChanged(String)
    case pageOriginOutsideSavedScope(String)
    case mcpConnectionUnavailable(UUID)
    case coworkBindingUnavailable(UUID)
}

extension AgentScheduledTaskDependencyFailure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .providerUnavailable(let providerID):
            "The saved provider \(providerID) is unavailable or has no local credentials."
        case .browserSessionUnavailable(let id):
            "The saved Browser Session \(id.uuidString) is unavailable."
        case .incognitoSessionUnavailable:
            "Persistent scheduled tasks cannot resolve an Incognito Browser Session."
        case .pageUnavailable(let id):
            "The saved Page \(id) is unavailable."
        case .pageSessionChanged(let id):
            "The saved Page \(id) no longer belongs to the task's Browser Session."
        case .pageOriginOutsideSavedScope(let id):
            "The saved Page \(id) is now outside the task's allowed origins."
        case .mcpConnectionUnavailable(let id):
            "The saved MCP connection \(id.uuidString) is missing, revoked, or no longer trusted."
        case .coworkBindingUnavailable(let id):
            "The saved Cowork binding \(id.uuidString) is missing or no longer authorizes the selected folder."
        }
    }
}

nonisolated enum AgentScheduledTaskDependencyResolver {
    static func resolve(
        execution: AgentTaskExecutionSnapshot,
        available: AgentScheduledTaskAvailableDependencies
    ) throws -> AgentScheduledTaskResolvedDependencies {
        let providerID = execution.provider.providerID
        guard available.providerIDsWithLocalAccess.contains(providerID) else {
            throw AgentScheduledTaskDependencyFailure.providerUnavailable(providerID)
        }

        switch execution.browserScope.session {
        case .normal:
            break
        case .incognito:
            throw AgentScheduledTaskDependencyFailure.incognitoSessionUnavailable
        case .container(let id):
            guard available.availableBrowserSessionIDs.contains(id) else {
                throw AgentScheduledTaskDependencyFailure.browserSessionUnavailable(id)
            }
        }

        for pageID in execution.browserScope.pageIDs.sorted() {
            guard let page = available.pagesByID[pageID] else {
                throw AgentScheduledTaskDependencyFailure.pageUnavailable(pageID)
            }
            guard page.session == execution.browserScope.session else {
                throw AgentScheduledTaskDependencyFailure.pageSessionChanged(pageID)
            }
            if !execution.browserScope.origins.isEmpty,
               !execution.browserScope.origins.contains(page.origin) {
                throw AgentScheduledTaskDependencyFailure
                    .pageOriginOutsideSavedScope(pageID)
            }
        }

        var mcpServerIdentities = Set<String>()
        for connectionID in execution.mcpConnectionIDs.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            guard let identity = available
                .trustedMCPServerIdentitiesByConnectionID[connectionID],
                !identity.isEmpty else {
                throw AgentScheduledTaskDependencyFailure
                    .mcpConnectionUnavailable(connectionID)
            }
            mcpServerIdentities.insert(identity)
        }

        let coworkRootIdentity: String?
        if let bindingID = execution.coworkRootID {
            guard let identity = available.coworkRootIdentitiesByBindingID[bindingID],
                  !identity.isEmpty else {
                throw AgentScheduledTaskDependencyFailure
                    .coworkBindingUnavailable(bindingID)
            }
            coworkRootIdentity = identity
        } else {
            coworkRootIdentity = nil
        }

        return AgentScheduledTaskResolvedDependencies(
            mcpServerIdentities: mcpServerIdentities,
            coworkRootIdentity: coworkRootIdentity
        )
    }
}
