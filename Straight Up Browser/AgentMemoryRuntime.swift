import Combine
import Foundation

enum AgentMemorySettings {
    enum Key {
        static let enabled = "agent.memory.enabled"
        static let allowSensitiveProposals = "agent.memory.allowSensitiveProposals"
        static let maximumRetrievedEntries = "agent.memory.maximumRetrievedEntries"
        static let maximumRetrievedTokens = "agent.memory.maximumRetrievedTokens"
        static let retention = "agent.memory.retention"
    }

    static func enabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Key.enabled)
    }

    static func allowSensitiveProposals(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Key.allowSensitiveProposals)
    }

    static func retrievalLimits(
        in defaults: UserDefaults = .standard
    ) -> AgentMemoryRetrievalLimits {
        let entries = defaults.object(forKey: Key.maximumRetrievedEntries) == nil
            ? 4 : defaults.integer(forKey: Key.maximumRetrievedEntries)
        let tokens = defaults.object(forKey: Key.maximumRetrievedTokens) == nil
            ? 1_024 : defaults.integer(forKey: Key.maximumRetrievedTokens)
        return AgentMemoryRetrievalLimits(
            maximumEntries: min(max(entries, 1), 8),
            maximumEstimatedTokens: min(max(tokens, 128), 2_048),
            maximumUTF8Bytes: min(max(tokens * 8, 1_024), 16_384)
        )
    }

    static func retention(in defaults: UserDefaults = .standard) -> AgentMemoryRetentionPolicy {
        guard let raw = defaults.string(forKey: Key.retention),
              let value = AgentMemoryRetentionPolicy(rawValue: raw)
        else { return .untilManuallyDeleted }
        return value
    }

    static func configuration(
        in defaults: UserDefaults = .standard
    ) -> AgentMemoryConfiguration {
        AgentMemoryConfiguration(
            retrievalLimits: retrievalLimits(in: defaults),
            defaultRetention: retention(in: defaults)
        )
    }
}

@MainActor
final class AgentMemoryController: ObservableObject {
    static let shared = AgentMemoryController()

    @Published private(set) var entries: [AgentMemoryEntry] = []
    @Published private(set) var storageSummary: AgentMemoryStorageSummary?
    @Published private(set) var lastError: String?

    private let directoryURL: URL
    private let defaults: UserDefaults
    private var store: AgentMemoryStore?

    init(
        baseDirectory: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Straight Up Browser", isDirectory: true),
        defaults: UserDefaults = .standard
    ) {
        directoryURL = baseDirectory
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        self.defaults = defaults
        reopenStore()
    }

    func reopenStore() {
        do {
            store = try AgentMemoryStore(
                directoryURL: directoryURL,
                configuration: AgentMemorySettings.configuration(in: defaults)
            )
            lastError = nil
            Task { await refresh() }
        } catch {
            store = nil
            lastError = safeError(error)
        }
    }

    func refresh(searchText: String? = nil) async {
        guard let store else { return }
        entries = await store.review(AgentMemoryQuery(text: searchText))
        do {
            storageSummary = try await store.storageSummary()
            lastError = nil
        } catch {
            lastError = safeError(error)
        }
    }

    func retrieve(
        runID: UUID,
        stepID: UUID?,
        conversationID: UUID?,
        taskID: UUID?,
        pageURL: String,
        browserSession: AgentBrowserSession,
        query: String
    ) async -> AgentMemoryRetrievalResult? {
        guard AgentMemorySettings.enabled(in: defaults), let store else { return nil }
        do {
            let origin = URL(string: pageURL).flatMap { try? AgentMemoryOrigin(pageURL: $0) }
            return try await store.retrieve(AgentMemoryRetrievalRequest(
                runID: runID,
                stepID: stepID,
                conversationID: conversationID,
                taskID: taskID,
                origin: origin,
                session: memorySession(browserSession, runID: runID),
                query: query,
                limits: AgentMemorySettings.retrievalLimits(in: defaults)
            ))
        } catch {
            lastError = safeError(error)
            return nil
        }
    }

    func call(
        _ tool: String,
        arguments: [String: Any],
        permit: AgentExecutionPermit,
        conversationID: UUID?,
        taskID: UUID?,
        pageURL: String,
        browserSession: AgentBrowserSession,
        sourceStepID: UUID
    ) async -> String {
        guard permit.toolName == tool else {
            return json(["error": "The memory execution permit does not match this tool."])
        }
        guard AgentMemorySettings.enabled(in: defaults) else {
            return json(["error": "Agent memory is disabled in Settings."])
        }
        guard let store else {
            return json(["error": lastError ?? "The Agent memory store is unavailable."])
        }

        do {
            switch tool {
            case "propose_agent_memory":
                let proposal = try proposal(
                    arguments: arguments,
                    permit: permit,
                    conversationID: conversationID,
                    taskID: taskID,
                    pageURL: pageURL,
                    browserSession: browserSession,
                    sourceStepID: sourceStepID
                )
                if proposal.sensitivity == .sensitive,
                   !AgentMemorySettings.allowSensitiveProposals(in: defaults) {
                    return json([
                        "stored": false,
                        "reason": "Sensitive memory proposals are disabled in Settings.",
                    ])
                }
                let context = AgentMemoryWriteContext(
                    session: memorySession(browserSession, runID: permit.runID),
                    attended: true
                )
                let decision = try AgentMemoryPolicy.evaluate(
                    proposal: proposal,
                    context: context
                )
                let supplied: AgentMemoryPolicyDecision
                switch decision {
                case .requireApproval(let request):
                    // The executor is reached only with a persisted permit for
                    // these exact proposal arguments. Bind that approval to the
                    // memory proposal's own digest before storing it.
                    supplied = .approved(AgentMemoryApprovalGrant(request: request))
                case .allow(let reason):
                    supplied = .allow(reason: reason)
                case .deny(let reason):
                    supplied = .deny(reason: reason)
                case .approved:
                    supplied = decision
                }
                let outcome = try await store.apply(
                    proposal: proposal,
                    decision: supplied,
                    context: context
                )
                await refresh()
                switch outcome {
                case .stored(let entry):
                    return json([
                        "stored": true,
                        "memoryId": entry.id.uuidString,
                        "scope": scopeLabel(entry.scope),
                        "sensitivity": entry.sensitivity.rawValue,
                        "expiresAt": entry.expiresAt
                            .map { ISO8601DateFormatter().string(from: $0) as Any }
                            ?? NSNull(),
                    ])
                case .denied(let reason), .suppressed(let reason):
                    return json(["stored": false, "reason": reason])
                case .requiresApproval:
                    return json(["stored": false, "reason": "A separate memory approval is required."])
                }

            case "search_agent_memory":
                let configuredLimits = AgentMemorySettings.retrievalLimits(in: defaults)
                let limit = min(
                    max(arguments["limit"] as? Int ?? configuredLimits.maximumEntries, 1),
                    configuredLimits.maximumEntries
                )
                let query = arguments["query"] as? String
                let origin = URL(string: pageURL).flatMap {
                    try? AgentMemoryOrigin(pageURL: $0)
                }
                let retrieved = try await store.retrieve(AgentMemoryRetrievalRequest(
                    runID: permit.runID,
                    stepID: sourceStepID,
                    conversationID: conversationID,
                    taskID: taskID,
                    origin: origin,
                    session: memorySession(browserSession, runID: permit.runID),
                    query: query,
                    limits: AgentMemoryRetrievalLimits(
                        maximumEntries: limit,
                        maximumEstimatedTokens: configuredLimits.maximumEstimatedTokens,
                        maximumUTF8Bytes: configuredLimits.maximumUTF8Bytes
                    )
                ))
                var values: [[String: Any]] = []
                for part in retrieved.entries {
                    let entry = try await store.entry(id: part.id)
                    values.append([
                        "memoryId": entry.id.uuidString,
                        "text": String(entry.text.prefix(2_000)),
                        "scope": scopeLabel(entry.scope),
                        "sensitivity": entry.sensitivity.rawValue,
                        "enabled": entry.isEnabled,
                        "why": entry.whyItExists,
                    ])
                }
                await refresh()
                return json([
                    "entries": values,
                    "count": values.count,
                    "candidateCount": retrieved.candidateCount,
                    "truncated": retrieved.candidateCount > values.count,
                    "suppressionReason": retrieved.suppressionReason
                        .map { $0 as Any } ?? NSNull(),
                ])

            case "forget_agent_memory":
                guard let rawID = arguments["memoryId"] as? String,
                      let id = UUID(uuidString: rawID)
                else { throw RuntimeError.message("A valid memoryId is required.") }
                guard let entry = try? await store.entry(id: id),
                      isModelAccessible(
                        entry,
                        conversationID: conversationID,
                        taskID: taskID,
                        pageURL: pageURL,
                        browserSession: browserSession
                      )
                else {
                    return json([
                        "deleted": [],
                        "reason": "No memory in this Run's exact scope matched that memoryId.",
                    ])
                }
                let receipt = try await store.delete(id: id)
                await refresh()
                return json([
                    "deleted": receipt.deletedEntryIDs.map(\.uuidString),
                    "historyUnaffected": receipt.unaffectedStores.contains(.browsingHistory),
                    "conversationsUnaffected": receipt.unaffectedStores.contains(.conversations),
                    "runsUnaffected": receipt.unaffectedStores.contains(.runs),
                ])

            default:
                throw RuntimeError.message("Unknown Agent memory tool: \(tool)")
            }
        } catch {
            lastError = safeError(error)
            return json(["error": safeError(error)])
        }
    }

    func edit(id: UUID, text: String) async {
        guard let store else { return }
        do {
            _ = try await store.edit(id: id, text: text)
            await refresh()
        } catch { lastError = safeError(error) }
    }

    func setEnabled(id: UUID, enabled: Bool) async {
        guard let store else { return }
        do {
            _ = try await store.setEnabled(id: id, enabled)
            await refresh()
        } catch { lastError = safeError(error) }
    }

    func delete(id: UUID) async {
        guard let store else { return }
        do {
            _ = try await store.delete(id: id)
            await refresh()
        } catch { lastError = safeError(error) }
    }

    func deleteAll() async {
        guard let store else { return }
        do {
            _ = try await store.deleteAll()
            await refresh()
        } catch { lastError = safeError(error) }
    }

    func exportData() async throws -> Data {
        guard let store else { throw RuntimeError.message("The Agent memory store is unavailable.") }
        return try await store.exportData()
    }

    /// Applies an allowlisted user-authored sync projection. Model-authored,
    /// observed, authentication, and Incognito memory are unrepresentable at
    /// this boundary. Sensitive entries still require a separate local review.
    func importSyncedUserMemory(
        _ value: AgentSyncedUserMemory,
        sensitiveApproved: Bool = false
    ) async throws {
        guard let store else { throw RuntimeError.message("The Agent memory store is unavailable.") }
        try value.validate()
        guard value.sensitivity != .sensitive || sensitiveApproved else {
            throw RuntimeError.message("Sensitive synced memory requires local review.")
        }
        let proposal = value.proposal
        if (try? await store.entry(id: value.id)) != nil {
            _ = try await store.updateSyncedUserProjection(
                id: value.id,
                text: value.text,
                scope: proposal.scope,
                sessionScope: proposal.sessionScope,
                sensitivity: value.sensitivity,
                expiresAt: value.expiresAt,
                isEnabled: value.isEnabled,
                at: value.updatedAt
            )
        } else {
            let decision = try AgentMemoryPolicy.evaluate(
                proposal: proposal,
                context: .attendedPersistent
            )
            let supplied: AgentMemoryPolicyDecision
            switch decision {
            case .allow(let reason): supplied = .allow(reason: reason)
            case .requireApproval(let request) where sensitiveApproved:
                supplied = .approved(AgentMemoryApprovalGrant(request: request))
            case .requireApproval:
                throw RuntimeError.message("Synced memory requires local review.")
            case .deny(let reason): supplied = .deny(reason: reason)
            case .approved: supplied = decision
            }
            _ = try await store.apply(
                proposal: proposal,
                decision: supplied,
                context: .attendedPersistent
            )
            if !value.isEnabled {
                _ = try await store.setEnabled(id: value.id, false)
            }
        }
        await refresh()
    }

    /// Applies a synced deletion without destroying this device's retained
    /// payload. Disabled entries remain reviewable/exportable but are excluded
    /// from every model-facing retrieval path.
    func deactivateSyncedUserMemory(id: UUID) async throws {
        guard let store else {
            throw RuntimeError.message("The Agent memory store is unavailable.")
        }
        guard (try? await store.entry(id: id)) != nil else { return }
        _ = try await store.setEnabled(id: id, false)
        await refresh()
    }

    private func proposal(
        arguments: [String: Any],
        permit: AgentExecutionPermit,
        conversationID: UUID?,
        taskID: UUID?,
        pageURL: String,
        browserSession: AgentBrowserSession,
        sourceStepID: UUID
    ) throws -> AgentMemoryProposal {
        guard let rawText = arguments["text"] as? String,
              !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw RuntimeError.message("Memory text is required.") }
        let scope: AgentMemoryScope
        switch arguments["scope"] as? String ?? "origin" {
        case "global":
            scope = .global
        case "origin":
            guard let url = URL(string: pageURL) else {
                throw RuntimeError.message("An HTTP(S) Page origin is required for origin-scoped memory.")
            }
            scope = .origin(try AgentMemoryOrigin(pageURL: url))
        case "task":
            guard let taskID else { throw RuntimeError.message("This run has no task scope.") }
            scope = .task(taskID)
        case "conversation":
            guard let conversationID else {
                throw RuntimeError.message("This run has no conversation scope.")
            }
            scope = .conversation(conversationID)
        default:
            throw RuntimeError.message("Unknown memory scope.")
        }
        guard let sensitivity = AgentMemorySensitivity(
            rawValue: arguments["sensitivity"] as? String ?? "preference"
        ) else { throw RuntimeError.message("Unknown memory sensitivity.") }
        let sessionScope: AgentMemoryPersistentSessionScope
        switch browserSession {
        case .normal, .incognito:
            sessionScope = .normal
        case .container(let id):
            sessionScope = .container(id)
        }
        let expiry = (arguments["expiresAt"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        return AgentMemoryProposal(
            text: rawText,
            scope: scope,
            sessionScope: sessionScope,
            sensitivity: sensitivity,
            provenance: AgentMemorySource(
                kind: .modelProposal,
                reason: "Explicit model proposal approved through propose_agent_memory",
                runID: permit.runID,
                stepID: sourceStepID,
                origin: URL(string: pageURL).flatMap { try? AgentMemoryOrigin(pageURL: $0) }
            ),
            expiresAt: expiry
        )
    }

    private func memorySession(
        _ session: AgentBrowserSession,
        runID: UUID
    ) -> AgentMemoryBrowserSession {
        switch session {
        case .normal: .normal
        case .incognito: .incognito(runID)
        case .container(let id): .container(id)
        }
    }

    /// Model-facing memory operations use the same exact origin, task,
    /// Conversation, and browser Session boundaries as retrieval. The Settings
    /// manager intentionally bypasses this helper so the user can review and
    /// manage the complete, independent memory store.
    private func isModelAccessible(
        _ entry: AgentMemoryEntry,
        conversationID: UUID?,
        taskID: UUID?,
        pageURL: String,
        browserSession: AgentBrowserSession
    ) -> Bool {
        let sessionMatches: Bool
        switch (entry.sessionScope, browserSession) {
        case (.normal, .normal),
             (.allPersistentSessions, .normal),
             (.allPersistentSessions, .container):
            sessionMatches = true
        case (.container(let expected), .container(let actual)):
            sessionMatches = expected == actual
        default:
            sessionMatches = false
        }
        guard sessionMatches else { return false }

        switch entry.scope {
        case .global:
            return true
        case .origin(let expected):
            guard let url = URL(string: pageURL),
                  let actual = try? AgentMemoryOrigin(pageURL: url)
            else { return false }
            return expected == actual
        case .task(let expected):
            return taskID == expected
        case .conversation(let expected):
            return conversationID == expected
        }
    }

    private func scopeLabel(_ scope: AgentMemoryScope) -> String {
        switch scope {
        case .global: "Global"
        case .origin(let origin): "Origin \(origin.description)"
        case .task(let id): "Task \(id.uuidString)"
        case .conversation(let id): "Conversation \(id.uuidString)"
        }
    }

    private func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    private func safeError(_ error: Error) -> String {
        String(String(describing: error).prefix(500))
    }

    private enum RuntimeError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let value) = self { value } else { nil }
        }
    }
}
