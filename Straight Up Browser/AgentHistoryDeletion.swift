import Foundation

#if os(macOS)
import Combine
#endif

extension Notification.Name {
    /// Posted only after a durable history deletion/retention pass verifies its
    /// result. Open conversation and timeline surfaces use it to reload.
    static let agentHistoryDidChange = Notification.Name(
        "agentHistoryDidChange"
    )
}

nonisolated struct AgentCompleteHistoryDeletionReport: Equatable, Sendable {
    let deletedRuns: Int
    let deletedConversations: Int
    let deletedOrphanEntries: Int
    let deletedScheduledOccurrenceRecords: Int
    let deletedCoworkWorkspaces: Int
    let retiredLegacySources: Int
}

nonisolated enum AgentCompleteHistoryDeletionError: LocalizedError, Equatable {
    case activeRuns(Int)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .activeRuns(let count):
            "Cannot delete agent history while \(count) Run(s) are active. Stop them and try again."
        case .verificationFailed:
            "Agent history deletion could not be verified. No success was reported."
        }
    }
}

/// Coordinates the independent history owners while deliberately excluding
/// schedule definitions, provider/Keychain settings, MCP connections, scoped
/// memory, local metrics, and committed Cowork destination files.
@MainActor
enum AgentCompleteHistoryDeletionCoordinator {
    static func deleteAll(
        store: AgentRunStore,
        baseDirectory: URL,
        clearScheduledHistory: () async throws -> Int,
        clearCoworkPrivateWorkspaces: () throws -> Int
    ) async throws -> AgentCompleteHistoryDeletionReport {
        let activeRunCount = await store.listRuns().count {
            !$0.status.isTerminal
        }
        guard activeRunCount == 0 else {
            throw AgentCompleteHistoryDeletionError.activeRuns(activeRunCount)
        }

        // Persist a definitions-only scheduler snapshot before deleting its
        // referenced Runs and retiring the old scheduler source file.
        let deletedScheduledRecords = try await clearScheduledHistory()
        let deletedCoworkWorkspaces = try clearCoworkPrivateWorkspaces()
        // Private staged/rollback bytes must disappear before their durable
        // Run identities do. A cleanup failure therefore leaves the Run store
        // intact as deterministic evidence for a safe retry.
        let storeResult = try await store.deleteAllHistory()
        let supportDirectory = baseDirectory
        let legacyReport = try await Task.detached(priority: .utility) {
            try AgentLegacyMigrationCoordinator.retireSources(
                baseDirectory: supportDirectory
            )
        }.value

        guard await store.listRuns().isEmpty,
              (try await store.listConversations()).isEmpty else {
            throw AgentCompleteHistoryDeletionError.verificationFailed
        }
        return AgentCompleteHistoryDeletionReport(
            deletedRuns: storeResult.deletedRuns,
            deletedConversations: storeResult.deletedConversations,
            deletedOrphanEntries: storeResult.deletedOrphanEntries,
            deletedScheduledOccurrenceRecords: deletedScheduledRecords,
            deletedCoworkWorkspaces: deletedCoworkWorkspaces,
            retiredLegacySources: legacyReport.deletedSourceCount
        )
    }
}

#if os(macOS)
@MainActor
final class AgentHistoryDeletionController: ObservableObject {
    enum Outcome: Equatable {
        case success(String)
        case failure(String)

        var message: String {
            switch self {
            case .success(let message), .failure(let message): message
            }
        }

        var isFailure: Bool {
            if case .failure = self { true } else { false }
        }
    }

    static let shared = AgentHistoryDeletionController()

    @Published private(set) var isWorking = false
    @Published private(set) var outcome: Outcome?

    private init() {}

    func deleteAll() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let store = try AgentRunStoreRegistry.store(
                baseDirectory: BrowserCLI.supportDirectory
            )
            try await AgentRunStoreRegistry.recoverIfNeeded(
                store,
                baseDirectory: BrowserCLI.supportDirectory
            )
            let report = try await AgentCompleteHistoryDeletionCoordinator
                .deleteAll(
                    store: store,
                    baseDirectory: BrowserCLI.supportDirectory,
                    clearScheduledHistory: {
                        try await BrowserAgentScheduler.shared
                            .clearHistoryPreservingDefinitions()
                    },
                    clearCoworkPrivateWorkspaces: {
                        try BrowserAgentWorkspace.shared
                            .removeAllTransactionWorkspaces()
                    }
                )
            outcome = .success(Self.successMessage(report))
            NotificationCenter.default.post(name: .agentHistoryDidChange, object: nil)
        } catch {
            outcome = Self.failureOutcome(for: error)
        }
    }

    func retentionPolicyChanged() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let store = try AgentRunStoreRegistry.store(
                baseDirectory: BrowserCLI.supportDirectory
            )
            try await AgentRunStoreRegistry.recoverIfNeeded(
                store,
                baseDirectory: BrowserCLI.supportDirectory
            )
            let report = try await AgentRunStoreRegistry.enforceRetention(
                store,
                baseDirectory: BrowserCLI.supportDirectory
            )
            if !report.deletedRunIDs.isEmpty
                || !report.deletedTemporaryRelativePaths.isEmpty {
                outcome = .success(
                    "Applied run-history retention and removed \(report.deletedRunIDs.count) expired Run(s)."
                )
                NotificationCenter.default.post(
                    name: .agentHistoryDidChange,
                    object: nil
                )
            }
        } catch {
            outcome = .failure(
                "Run-history retention could not be applied: \(error.localizedDescription)"
            )
        }
    }

    private static func successMessage(
        _ report: AgentCompleteHistoryDeletionReport
    ) -> String {
        "Deleted \(report.deletedRuns) Run(s), \(report.deletedConversations) conversation(s), and \(report.deletedScheduledOccurrenceRecords) scheduled occurrence record(s), including retained artifacts and replay data. Schedules, scoped memory, local metrics, provider credentials, and app integrations were preserved."
    }

    static func failureOutcome(for error: Error) -> Outcome {
        if case AgentCompleteHistoryDeletionError.activeRuns = error {
            return .failure(
                "Agent history was unchanged: \(error.localizedDescription)"
            )
        }
        return .failure(
            "Agent history deletion was partially completed and stopped safely. Some scheduler occurrence history may already be cleared; resolve the reported issue and retry: \(error.localizedDescription)"
        )
    }
}
#endif
