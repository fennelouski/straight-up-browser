import CryptoKit
import Foundation

nonisolated enum LegacyImportDisposition: Equatable, Sendable {
    case inserted
    case alreadyImported
    case repairedIndexes
}

private nonisolated struct LegacyMigrationReceipt: Codable, Sendable {
    let schemaVersion: Int
    let receiptKey: String
    let source: LegacyImportSource
    let conversationID: UUID?
    let runIDs: [UUID]
    let issueCodes: [LegacyProvenanceCode]
    let importedAt: Date
}

nonisolated enum AgentRunStoreError: Error, Equatable, Sendable {
    case conversationNotFound(UUID)
    case conversationAlreadyExists(UUID)
    case runNotFound(UUID)
    case runAlreadyExists(UUID)
    case unsupportedSchema(path: String, found: Int, supported: Int)
    case corruptStore(path: String, reason: String)
    case fileOperationFailed(operation: String, path: String, reason: String)
    case artifactRetentionProhibited(UUID)
    case artifactSourceMismatch(artifactID: UUID, sourceStepID: UUID)
    case artifactAlreadyExists(UUID)
    case invalidArtifactMetadata(String)
    case artifactTooLarge(maximumBytes: Int)
    case artifactManifestFull(maximumEntries: Int)
    case activeRunsPreventHistoryDeletion([UUID])
}

extension AgentRunStoreError: LocalizedError {
    nonisolated var errorDescription: String? {
        switch self {
        case .conversationNotFound(let id):
            "Agent conversation \(id) was not found."
        case .conversationAlreadyExists(let id):
            "Agent conversation \(id) already exists."
        case .runNotFound(let id):
            "Agent run \(id) was not found."
        case .runAlreadyExists(let id):
            "Agent run \(id) already exists."
        case .unsupportedSchema(let path, let found, let supported):
            "Unsupported agent store schema \(found) at \(path); this build supports \(supported)."
        case .corruptStore(let path, let reason):
            "The agent store at \(path) is corrupt: \(reason)"
        case .fileOperationFailed(let operation, let path, let reason):
            "Could not \(operation) \(path): \(reason)"
        case .artifactRetentionProhibited(let runID):
            "Run \(runID) does not permit retained artifact bytes."
        case .artifactSourceMismatch(let artifactID, let sourceStepID):
            "Artifact \(artifactID) is not linked from source Step \(sourceStepID)."
        case .artifactAlreadyExists(let id):
            "Artifact \(id) already exists with different metadata or bytes."
        case .invalidArtifactMetadata(let field):
            "Artifact metadata is invalid: \(field)."
        case .artifactTooLarge(let maximumBytes):
            "Artifact exceeds the \(maximumBytes)-byte durable storage limit."
        case .artifactManifestFull(let maximumEntries):
            "Artifact manifest reached its \(maximumEntries)-entry limit."
        case .activeRunsPreventHistoryDeletion(let runIDs):
            "Cannot delete all agent history while \(runIDs.count) Run(s) are active."
        }
    }
}

nonisolated struct AgentHistoryDeletionResult: Equatable, Sendable {
    let deletedRuns: Int
    let deletedConversations: Int
    let deletedOrphanEntries: Int
}

private nonisolated struct AgentConversationIndex: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var conversations: [AgentConversation]

    init(conversations: [AgentConversation]) {
        schemaVersion = Self.currentSchemaVersion
        self.conversations = conversations
    }
}

private nonisolated struct AgentRunIndex: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var runs: [AgentRun]

    init(runs: [AgentRun]) {
        schemaVersion = Self.currentSchemaVersion
        self.runs = runs
    }
}

/// Narrow fault-injection seam used by persistence tests. Production stores
/// leave the injector nil.
nonisolated enum AgentRunStoreFailurePoint: Sendable {
    case beforeReplayFrameManifestWrite
}

private nonisolated struct AgentReplayFrameTransaction: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let artifact: AgentArtifact
    let frame: AgentReplayFrameMetadata

    init(artifact: AgentArtifact, frame: AgentReplayFrameMetadata) {
        schemaVersion = Self.currentSchemaVersion
        self.artifact = artifact
        self.frame = frame
    }
}

actor AgentRunStore {
    private static let maximumArtifactBytes = 64 * 1_024 * 1_024
    private static let maximumArtifactManifestEntries = 10_000
    /// Shared by capture and persistence so an oversized frame is rejected
    /// before artifact-budget admission rather than charged and then dropped.
    nonisolated static let maximumReplayFrameBytes = 8 * 1_024 * 1_024
    private static let maximumReplayFrameCount = 256
    private static let maximumReplayFrameBytesPerRun = 128 * 1_024 * 1_024
    private let rootDirectory: URL
    private let conversationsDirectory: URL
    private let conversationIndexURL: URL
    private let runsDirectory: URL
    private let runIndexURL: URL
    private let failureInjector: (@Sendable (AgentRunStoreFailurePoint) throws -> Void)?

    private var conversations: [UUID: AgentConversation]
    private var runs: [UUID: AgentRun]

    init(
        baseDirectory: URL,
        failureInjector: (@Sendable (AgentRunStoreFailurePoint) throws -> Void)? = nil
    ) throws {
        let rootDirectory = baseDirectory.appendingPathComponent("agent", isDirectory: true)
        let conversationsDirectory = rootDirectory.appendingPathComponent("conversations", isDirectory: true)
        let runsDirectory = rootDirectory.appendingPathComponent("runs", isDirectory: true)
        let conversationIndexURL = conversationsDirectory.appendingPathComponent("index.json")
        let runIndexURL = runsDirectory.appendingPathComponent("index.json")

        try Self.ensureDirectory(rootDirectory)
        try Self.ensureDirectory(conversationsDirectory)
        try Self.ensureDirectory(runsDirectory)

        let conversationIndex: AgentConversationIndex
        if FileManager.default.fileExists(atPath: conversationIndexURL.path) {
            conversationIndex = try Self.decode(AgentConversationIndex.self, from: conversationIndexURL)
            guard conversationIndex.schemaVersion == AgentConversationIndex.currentSchemaVersion else {
                throw AgentRunStoreError.unsupportedSchema(
                    path: conversationIndexURL.path,
                    found: conversationIndex.schemaVersion,
                    supported: AgentConversationIndex.currentSchemaVersion
                )
            }
        } else {
            conversationIndex = AgentConversationIndex(conversations: [])
            try Self.write(conversationIndex, to: conversationIndexURL)
        }

        let runIndex: AgentRunIndex
        if FileManager.default.fileExists(atPath: runIndexURL.path) {
            runIndex = try Self.decode(AgentRunIndex.self, from: runIndexURL)
            guard runIndex.schemaVersion == AgentRunIndex.currentSchemaVersion else {
                throw AgentRunStoreError.unsupportedSchema(
                    path: runIndexURL.path,
                    found: runIndex.schemaVersion,
                    supported: AgentRunIndex.currentSchemaVersion
                )
            }
        } else {
            runIndex = AgentRunIndex(runs: [])
            try Self.write(runIndex, to: runIndexURL)
        }

        var loadedConversations: [UUID: AgentConversation] = [:]
        for conversation in conversationIndex.conversations {
            guard loadedConversations.updateValue(conversation, forKey: conversation.id) == nil else {
                throw AgentRunStoreError.corruptStore(
                    path: conversationIndexURL.path,
                    reason: "duplicate conversation ID \(conversation.id)"
                )
            }
        }

        var loadedRuns: [UUID: AgentRun] = [:]
        for indexedRun in runIndex.runs {
            let metadataURL = runsDirectory
                .appendingPathComponent(indexedRun.id.uuidString, isDirectory: true)
                .appendingPathComponent("metadata.json")
            let run = try Self.decode(AgentRun.self, from: metadataURL)
            guard run.id == indexedRun.id else {
                throw AgentRunStoreError.corruptStore(
                    path: metadataURL.path,
                    reason: "metadata ID \(run.id) does not match indexed ID \(indexedRun.id)"
                )
            }
            guard loadedRuns.updateValue(run, forKey: run.id) == nil else {
                throw AgentRunStoreError.corruptStore(
                    path: runIndexURL.path,
                    reason: "duplicate run ID \(run.id)"
                )
            }
        }

        for runID in loadedRuns.keys {
            try Self.recoverReplayFrameTransactions(
                in: runsDirectory.appendingPathComponent(
                    runID.uuidString,
                    isDirectory: true
                )
            )
        }

        self.rootDirectory = rootDirectory
        self.conversationsDirectory = conversationsDirectory
        self.conversationIndexURL = conversationIndexURL
        self.runsDirectory = runsDirectory
        self.runIndexURL = runIndexURL
        self.failureInjector = failureInjector
        conversations = loadedConversations
        runs = loadedRuns
    }

    func createConversation(title: String, at date: Date = Date()) throws -> AgentConversation {
        let conversation = AgentConversation(title: title, createdAt: date)
        conversations[conversation.id] = conversation
        do {
            try persistConversationIndex()
        } catch {
            conversations.removeValue(forKey: conversation.id)
            throw error
        }
        return conversation
    }

    func createRun(
        id: UUID = UUID(),
        conversationID: UUID?,
        taskDefinitionID: UUID? = nil,
        parentRunID: UUID? = nil,
        runGroupID: UUID? = nil,
        entryPoint: AgentRunEntryPoint,
        configuration: AgentConfigurationSnapshot = AgentConfigurationSnapshot(),
        incognito: Bool = false,
        importedFromLegacy: Bool = false,
        at date: Date = Date()
    ) throws -> AgentRun {
        if let conversationID, conversations[conversationID] == nil {
            throw AgentRunStoreError.conversationNotFound(conversationID)
        }
        guard runs[id] == nil, !FileManager.default.fileExists(atPath: runDirectory(for: id).path) else {
            throw AgentRunStoreError.runAlreadyExists(id)
        }

        let run = AgentRun(
            id: id,
            conversationID: conversationID,
            taskDefinitionID: taskDefinitionID,
            parentRunID: parentRunID,
            runGroupID: runGroupID,
            entryPoint: entryPoint,
            createdAt: date,
            configuration: configuration,
            incognito: incognito,
            importedFromLegacy: importedFromLegacy
        )
        let directory = runDirectory(for: run.id)
        try Self.ensureDirectory(directory)
        try Self.write(run, to: metadataURL(for: run.id))
        try Self.createEmptyFile(at: stepsURL(for: run.id))

        runs[run.id] = run
        var previousConversation: AgentConversation?
        if let conversationID, var conversation = conversations[conversationID] {
            previousConversation = conversation
            conversation.runIDs.append(run.id)
            conversation.updatedAt = date
            conversations[conversationID] = conversation
        }

        do {
            try persistRunIndex()
            try persistConversationIndex()
        } catch {
            runs.removeValue(forKey: run.id)
            if let conversationID, let previousConversation {
                conversations[conversationID] = previousConversation
            }
            throw error
        }
        return run
    }

    func transitionRun(
        _ id: UUID,
        to status: AgentRunStatus,
        reason: String,
        at date: Date = Date()
    ) throws -> AgentStep {
        guard var run = runs[id] else { throw AgentRunStoreError.runNotFound(id) }
        try AgentRunStateMachine.validateTransition(from: run.status, to: status)

        let previousStatus = run.status
        let step = AgentStep(
            runID: id,
            sequence: run.nextSequence,
            timestamp: date,
            kind: .stateTransition,
            summary: reason,
            payload: .object([
                "from": .string(previousStatus.rawValue),
                "to": .string(status.rawValue),
                "reason": .string(reason),
            ])
        )

        run.status = status
        if status == .running, run.startedAt == nil { run.startedAt = date }
        if status.isTerminal { run.finishedAt = date }
        run.lastUpdatedAt = date
        run.nextSequence += 1

        try Self.append(step, to: stepsURL(for: id))
        runs[id] = run
        try Self.write(run, to: metadataURL(for: id))
        try persistRunIndex()
        return step
    }

    @discardableResult
    func recoverInterruptedRuns(at date: Date = Date()) throws -> [AgentStep] {
        let recoverableIDs = runs.values
            .filter {
                switch $0.status {
                case .queued, .running, .waitingForApproval, .waitingForHuman:
                    true
                case .succeeded, .failed, .cancelled, .interrupted:
                    false
                }
            }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            .map(\.id)

        return try recoverableIDs.map {
            try transitionRun(
                $0,
                to: .interrupted,
                reason: "Application exited before the run completed",
                at: date
            )
        }
    }

    func appendStep(
        runID: UUID,
        kind: AgentStepKind,
        summary: String,
        payload: JSONValue? = nil,
        artifactID: UUID? = nil,
        policyDecisionStepID: UUID? = nil,
        redactionState: AgentRedactionState = .metadataOnly,
        at date: Date = Date()
    ) throws -> AgentStep {
        guard var run = runs[runID] else { throw AgentRunStoreError.runNotFound(runID) }
        let step = AgentStep(
            runID: runID,
            sequence: run.nextSequence,
            timestamp: date,
            kind: kind,
            summary: summary,
            payload: payload,
            artifactID: artifactID,
            policyDecisionStepID: policyDecisionStepID,
            redactionState: redactionState
        )

        run.nextSequence += 1
        run.lastUpdatedAt = date
        try Self.append(step, to: stepsURL(for: runID))
        runs[runID] = run
        try Self.write(run, to: metadataURL(for: runID))
        try persistRunIndex()
        return step
    }

    func run(id: UUID) -> AgentRun? {
        runs[id]
    }

    func listRuns(matching query: AgentRunQuery = AgentRunQuery()) -> [AgentRun] {
        runs.values
            .filter { run in
                if let conversationID = query.conversationID,
                   run.conversationID != conversationID { return false }
                if let taskDefinitionID = query.taskDefinitionID,
                   run.taskDefinitionID != taskDefinitionID { return false }
                if let status = query.status, run.status != status { return false }
                if let providerID = query.providerID,
                   run.configuration.provider?.providerID != providerID { return false }
                if let interval = query.createdAtInterval,
                   !interval.contains(run.createdAt) { return false }
                if let parentRunID = query.parentRunID,
                   run.parentRunID != parentRunID { return false }
                return true
            }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    func steps(runID: UUID) throws -> [AgentStep] {
        guard runs[runID] != nil else { throw AgentRunStoreError.runNotFound(runID) }
        return try Self.readSteps(from: stepsURL(for: runID), runID: runID)
    }

    /// Persists an explicitly retained artifact beneath its Run and updates the
    /// metadata-only inventory consumed by the unified timeline. The caller
    /// must first append the exact `.artifact` Step carrying `id`; this keeps
    /// every retained body cryptographically linked to one durable source Step.
    @discardableResult
    func persistArtifact(
        id: UUID,
        runID: UUID,
        sourceStepID: UUID,
        contentType: String,
        data: Data,
        at date: Date = Date()
    ) throws -> AgentArtifact {
        try persistArtifact(
            id: id,
            runID: runID,
            sourceStepID: sourceStepID,
            contentType: contentType,
            data: data,
            sourceRequirement: .artifactStepBacklink,
            at: date
        )
    }

    /// Persists one bounded replay image and its metadata. Unlike a general
    /// artifact, a frame points directly at the exact authorized
    /// `.toolInvocation` Step. Multiple before/after frames can therefore share
    /// that one source Step without overloading its single legacy `artifactID`
    /// field.
    @discardableResult
    func persistReplayFrame(
        id: UUID,
        runID: UUID,
        sourceStepID: UUID,
        contentType: String,
        data: Data,
        metadata: AgentReplayFrameMetadata,
        at date: Date = Date()
    ) throws -> AgentArtifact {
        guard let run = runs[runID] else {
            throw AgentRunStoreError.runNotFound(runID)
        }
        guard !run.incognito else {
            throw AgentRunStoreError.artifactRetentionProhibited(runID)
        }
        guard metadata.artifactID == id else {
            throw AgentRunStoreError.invalidArtifactMetadata("frame.artifactID")
        }
        guard contentType == "image/png" || contentType == "image/jpeg" else {
            throw AgentRunStoreError.invalidArtifactMetadata("frame.contentType")
        }
        guard data.count <= Self.maximumReplayFrameBytes else {
            throw AgentRunStoreError.artifactTooLarge(
                maximumBytes: Self.maximumReplayFrameBytes
            )
        }
        guard metadata.viewport.width > 0,
              metadata.viewport.height > 0,
              metadata.viewport.width <= 100_000,
              metadata.viewport.height <= 100_000,
              metadata.viewport.scale.isFinite,
              metadata.viewport.scale > 0,
              metadata.viewport.scale <= 16 else {
            throw AgentRunStoreError.invalidArtifactMetadata("frame.viewport")
        }
        guard Self.isOriginOnly(metadata.urlOrigin) else {
            throw AgentRunStoreError.invalidArtifactMetadata("frame.urlOrigin")
        }

        let runDirectory = runDirectory(for: runID)
        // A process may have stopped after committing one side of the
        // two-manifest transaction. Reconcile durable journals before making
        // a new admission decision so retries are idempotent in either state.
        try Self.recoverReplayFrameTransactions(in: runDirectory)

        let framesDirectory = runDirectory
            .appendingPathComponent("frames", isDirectory: true)
        let frameManifestURL = framesDirectory.appendingPathComponent("index.json")
        var frames: [AgentReplayFrameMetadata] = if FileManager.default.fileExists(
            atPath: frameManifestURL.path
        ) {
            try Self.decode([AgentReplayFrameMetadata].self, from: frameManifestURL)
        } else {
            []
        }
        guard frames.count <= Self.maximumReplayFrameCount,
              Set(frames.map(\.artifactID)).count == frames.count else {
            throw AgentRunStoreError.corruptStore(
                path: frameManifestURL.path,
                reason: "replay frame manifest is oversized or contains duplicates"
            )
        }
        if let existing = frames.first(where: { $0.artifactID == id }),
           existing != metadata {
            throw AgentRunStoreError.artifactAlreadyExists(id)
        }
        let existingFrame = frames.first(where: { $0.artifactID == id })
        let artifactsDirectory = runDirectory
            .appendingPathComponent("artifacts", isDirectory: true)
        let artifactManifestURL = artifactsDirectory.appendingPathComponent("index.json")
        let originalArtifacts: [AgentArtifact] = if FileManager.default.fileExists(
            atPath: artifactManifestURL.path
        ) {
            try Self.decode([AgentArtifact].self, from: artifactManifestURL)
        } else {
            []
        }
        guard originalArtifacts.count <= Self.maximumArtifactManifestEntries,
              Set(originalArtifacts.map(\.id)).count == originalArtifacts.count else {
            throw AgentRunStoreError.corruptStore(
                path: artifactManifestURL.path,
                reason: "artifact manifest is oversized or contains duplicates"
            )
        }
        let existingArtifact = originalArtifacts.first(where: { $0.id == id })

        // Repairing either half of an interrupted transaction must still fit
        // the retained-byte bound. Existing complete frames are not charged a
        // second time on an idempotent retry.
        if existingFrame == nil || existingArtifact == nil {
            if existingFrame == nil {
                guard frames.count < Self.maximumReplayFrameCount else {
                    throw AgentRunStoreError.artifactManifestFull(
                        maximumEntries: Self.maximumReplayFrameCount
                    )
                }
            }
            let retainedBytes = try Self.replayFrameByteCount(
                artifacts: originalArtifacts,
                frames: frames
            )
            let artifactAlreadyCounted = existingArtifact.map { artifact in
                frames.contains { $0.artifactID == artifact.id }
            } ?? false
            let additionalBytes = artifactAlreadyCounted ? 0 : Int64(data.count)
            let (projectedBytes, overflow) = retainedBytes.addingReportingOverflow(
                additionalBytes
            )
            guard !overflow,
                  projectedBytes <= Int64(Self.maximumReplayFrameBytesPerRun) else {
                throw AgentRunStoreError.artifactTooLarge(
                    maximumBytes: Self.maximumReplayFrameBytesPerRun
                )
            }
        }

        let artifact = existingArtifact ?? Self.makeArtifact(
            id: id,
            runID: runID,
            sourceStepID: sourceStepID,
            contentType: contentType,
            data: data,
            at: date
        )

        // If the frame half already exists, persistArtifact repairs a missing
        // artifact half and otherwise verifies the retry byte-for-byte.
        if existingFrame != nil {
            return try persistArtifact(
                id: id,
                runID: runID,
                sourceStepID: sourceStepID,
                contentType: contentType,
                data: data,
                sourceRequirement: .authorizedToolInvocation,
                at: date
            )
        }

        try Self.ensureDirectory(framesDirectory)
        let pendingDirectory = framesDirectory.appendingPathComponent(
            "pending",
            isDirectory: true
        )
        try Self.ensureDirectory(pendingDirectory)
        let journalURL = pendingDirectory.appendingPathComponent(
            "\(id.uuidString).json"
        )
        guard !FileManager.default.fileExists(atPath: journalURL.path) else {
            throw AgentRunStoreError.corruptStore(
                path: journalURL.path,
                reason: "unrecovered replay transaction"
            )
        }
        try Self.write(
            AgentReplayFrameTransaction(artifact: artifact, frame: metadata),
            to: journalURL
        )

        let artifactExistedBefore = existingArtifact != nil
        do {
            let persisted = try persistArtifact(
                id: id,
                runID: runID,
                sourceStepID: sourceStepID,
                contentType: contentType,
                data: data,
                sourceRequirement: .authorizedToolInvocation,
                at: date
            )
            try failureInjector?(.beforeReplayFrameManifestWrite)
            guard frames.count < Self.maximumReplayFrameCount else {
                throw AgentRunStoreError.artifactManifestFull(
                    maximumEntries: Self.maximumReplayFrameCount
                )
            }
            frames.append(metadata)
            frames.sort { $0.artifactID.uuidString < $1.artifactID.uuidString }
            try Self.write(frames, to: frameManifestURL)
            try FileManager.default.removeItem(at: journalURL)
            return persisted
        } catch {
            // Ordinary write failures are rolled back immediately. If the
            // process dies during rollback, the still-durable journal lets
            // initialization or the next retry finish reconciliation.
            do {
                if !artifactExistedBefore {
                    try Self.write(originalArtifacts, to: artifactManifestURL)
                    let bodyURL = runDirectory.appendingPathComponent(
                        artifact.relativePath
                    )
                    if FileManager.default.fileExists(atPath: bodyURL.path) {
                        try FileManager.default.removeItem(at: bodyURL)
                    }
                }
                try Self.write(frames, to: frameManifestURL)
                if FileManager.default.fileExists(atPath: journalURL.path) {
                    try FileManager.default.removeItem(at: journalURL)
                }
            } catch {
                // Preserve the original error and the journal. Recovery will
                // deterministically complete or remove the partial state.
            }
            throw error
        }
    }

    private enum ArtifactSourceRequirement {
        case artifactStepBacklink
        case authorizedToolInvocation

        func accepts(_ step: AgentStep, artifactID: UUID) -> Bool {
            switch self {
            case .artifactStepBacklink:
                step.kind == .artifact && step.artifactID == artifactID
            case .authorizedToolInvocation:
                step.kind == .toolInvocation && step.policyDecisionStepID != nil
            }
        }
    }

    private func persistArtifact(
        id: UUID,
        runID: UUID,
        sourceStepID: UUID,
        contentType: String,
        data: Data,
        sourceRequirement: ArtifactSourceRequirement,
        at date: Date
    ) throws -> AgentArtifact {
        guard let run = runs[runID] else { throw AgentRunStoreError.runNotFound(runID) }
        guard !run.incognito else {
            throw AgentRunStoreError.artifactRetentionProhibited(runID)
        }
        guard data.count <= Self.maximumArtifactBytes else {
            throw AgentRunStoreError.artifactTooLarge(
                maximumBytes: Self.maximumArtifactBytes
            )
        }
        let normalizedContentType = contentType.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedContentType.isEmpty,
              normalizedContentType == contentType,
              normalizedContentType.utf8.count <= 256,
              !normalizedContentType.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw AgentRunStoreError.invalidArtifactMetadata("contentType")
        }

        let runSteps = try Self.readSteps(
            from: stepsURL(for: runID),
            runID: runID
        )
        let matchingSteps = runSteps.filter { step in
            step.id == sourceStepID
                && sourceRequirement.accepts(step, artifactID: id)
        }
        guard matchingSteps.count == 1 else {
            throw AgentRunStoreError.artifactSourceMismatch(
                artifactID: id,
                sourceStepID: sourceStepID
            )
        }

        let artifactsDirectory = runDirectory(for: runID)
            .appendingPathComponent("artifacts", isDirectory: true)
        try Self.ensureDirectory(artifactsDirectory)
        let manifestURL = artifactsDirectory.appendingPathComponent("index.json")
        var manifest: [AgentArtifact] = if FileManager.default.fileExists(
            atPath: manifestURL.path
        ) {
            try Self.decode([AgentArtifact].self, from: manifestURL)
        } else {
            []
        }
        guard manifest.count <= Self.maximumArtifactManifestEntries else {
            throw AgentRunStoreError.corruptStore(
                path: manifestURL.path,
                reason: "artifact manifest exceeds the entry limit"
            )
        }

        let relativePath = "artifacts/\(id.uuidString).data"
        let digest = Self.sha256(data)
        let artifact = AgentArtifact(
            id: id,
            runID: runID,
            sourceStepID: sourceStepID,
            contentType: normalizedContentType,
            byteCount: data.count,
            sha256: digest,
            relativePath: relativePath,
            redactionState: .retained,
            createdAt: date
        )
        if let existing = manifest.first(where: { $0.id == id }) {
            let destination = runDirectory(for: runID)
                .appendingPathComponent(existing.relativePath)
            let destinationValues = try? destination.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            let retainedBacklinkIsValid = runSteps.contains { step in
                step.id == existing.sourceStepID
                    && sourceRequirement.accepts(step, artifactID: existing.id)
            }
            guard existing.runID == artifact.runID,
                  existing.contentType == artifact.contentType,
                  existing.byteCount == artifact.byteCount,
                  existing.sha256 == artifact.sha256,
                  existing.relativePath == artifact.relativePath,
                  existing.redactionState == artifact.redactionState,
                  retainedBacklinkIsValid,
                  destinationValues?.isRegularFile == true,
                  destinationValues?.isSymbolicLink != true,
                  destinationValues?.fileSize == data.count,
                  let existingData = try? Data(
                      contentsOf: destination,
                      options: .mappedIfSafe
                  ),
                  existingData.count == data.count,
                  Self.sha256(existingData) == digest else {
                throw AgentRunStoreError.artifactAlreadyExists(id)
            }
            return existing
        }
        guard manifest.count < Self.maximumArtifactManifestEntries else {
            throw AgentRunStoreError.artifactManifestFull(
                maximumEntries: Self.maximumArtifactManifestEntries
            )
        }

        let destination = artifactsDirectory.appendingPathComponent(
            "\(id.uuidString).data"
        )
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw AgentRunStoreError.artifactAlreadyExists(id)
        }
        try Self.writeData(data, to: destination)
        manifest.append(artifact)
        manifest.sort {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        do {
            try Self.write(manifest, to: manifestURL)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return artifact
    }

    private static func makeArtifact(
        id: UUID,
        runID: UUID,
        sourceStepID: UUID,
        contentType: String,
        data: Data,
        at date: Date
    ) -> AgentArtifact {
        AgentArtifact(
            id: id,
            runID: runID,
            sourceStepID: sourceStepID,
            contentType: contentType,
            byteCount: data.count,
            sha256: sha256(data),
            relativePath: "artifacts/\(id.uuidString).data",
            redactionState: .retained,
            createdAt: date
        )
    }

    private static func replayFrameByteCount(
        artifacts: [AgentArtifact],
        frames: [AgentReplayFrameMetadata]
    ) throws -> Int64 {
        let frameIDs = Set(frames.map(\.artifactID))
        var total: Int64 = 0
        for artifact in artifacts where frameIDs.contains(artifact.id) {
            guard artifact.byteCount >= 0 else {
                throw AgentRunStoreError.corruptStore(
                    path: "artifacts/index.json",
                    reason: "artifact byte count is negative"
                )
            }
            let (next, overflow) = total.addingReportingOverflow(
                Int64(artifact.byteCount)
            )
            guard !overflow else {
                throw AgentRunStoreError.corruptStore(
                    path: "artifacts/index.json",
                    reason: "replay frame byte accounting overflowed"
                )
            }
            total = next
        }
        return total
    }

    /// Reconciles durable replay journals left by a process exit. The artifact
    /// manifest and body are written first; once both verify byte-for-byte, the
    /// frame manifest can be completed safely. Earlier partial states are
    /// rolled back. A conflicting ID is corruption and is never overwritten.
    private static func recoverReplayFrameTransactions(in runDirectory: URL) throws {
        let framesDirectory = runDirectory.appendingPathComponent(
            "frames",
            isDirectory: true
        )
        let pendingDirectory = framesDirectory.appendingPathComponent(
            "pending",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: pendingDirectory.path) else {
            return
        }
        let journals = try FileManager.default.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }

        let artifactManifestURL = runDirectory.appendingPathComponent(
            "artifacts/index.json"
        )
        let frameManifestURL = framesDirectory.appendingPathComponent("index.json")
        for journalURL in journals {
            let values = try journalURL.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw AgentRunStoreError.corruptStore(
                    path: journalURL.path,
                    reason: "replay transaction journal is not a regular file"
                )
            }
            let transaction = try decode(
                AgentReplayFrameTransaction.self,
                from: journalURL
            )
            guard transaction.schemaVersion
                    == AgentReplayFrameTransaction.currentSchemaVersion,
                  transaction.artifact.id == transaction.frame.artifactID,
                  journalURL.deletingPathExtension().lastPathComponent
                    == transaction.artifact.id.uuidString,
                  runDirectory.lastPathComponent
                    == transaction.artifact.runID.uuidString else {
                throw AgentRunStoreError.corruptStore(
                    path: journalURL.path,
                    reason: "replay transaction identity mismatch"
                )
            }
            guard transaction.artifact.contentType == "image/png"
                    || transaction.artifact.contentType == "image/jpeg",
                  transaction.artifact.byteCount >= 0,
                  transaction.artifact.byteCount <= maximumReplayFrameBytes,
                  transaction.artifact.relativePath
                    == "artifacts/\(transaction.artifact.id.uuidString).data",
                  transaction.artifact.redactionState == .retained,
                  transaction.artifact.sha256.count == 64,
                  transaction.artifact.sha256.allSatisfy({ $0.isHexDigit }),
                  transaction.frame.viewport.width > 0,
                  transaction.frame.viewport.height > 0,
                  transaction.frame.viewport.width <= 100_000,
                  transaction.frame.viewport.height <= 100_000,
                  transaction.frame.viewport.scale.isFinite,
                  transaction.frame.viewport.scale > 0,
                  transaction.frame.viewport.scale <= 16,
                  isOriginOnly(transaction.frame.urlOrigin) else {
                throw AgentRunStoreError.corruptStore(
                    path: journalURL.path,
                    reason: "replay transaction metadata is invalid"
                )
            }
            let sourceSteps = try readSteps(
                from: runDirectory.appendingPathComponent("steps.jsonl"),
                runID: transaction.artifact.runID
            ).filter {
                $0.id == transaction.artifact.sourceStepID
                    && $0.kind == .toolInvocation
                    && $0.policyDecisionStepID != nil
            }
            guard sourceSteps.count == 1 else {
                throw AgentRunStoreError.corruptStore(
                    path: journalURL.path,
                    reason: "replay transaction source Step is not an authorized invocation"
                )
            }

            var artifacts: [AgentArtifact] = if FileManager.default.fileExists(
                atPath: artifactManifestURL.path
            ) {
                try decode([AgentArtifact].self, from: artifactManifestURL)
            } else {
                []
            }
            var frames: [AgentReplayFrameMetadata] = if FileManager.default.fileExists(
                atPath: frameManifestURL.path
            ) {
                try decode([AgentReplayFrameMetadata].self, from: frameManifestURL)
            } else {
                []
            }
            guard artifacts.count <= maximumArtifactManifestEntries,
                  Set(artifacts.map(\.id)).count == artifacts.count,
                  frames.count <= maximumReplayFrameCount,
                  Set(frames.map(\.artifactID)).count == frames.count else {
                throw AgentRunStoreError.corruptStore(
                    path: journalURL.path,
                    reason: "manifest bounds or uniqueness check failed during replay recovery"
                )
            }

            let artifactIndex = artifacts.firstIndex {
                $0.id == transaction.artifact.id
            }
            let frameIndex = frames.firstIndex {
                $0.artifactID == transaction.frame.artifactID
            }
            if let artifactIndex,
               artifacts[artifactIndex] != transaction.artifact {
                throw AgentRunStoreError.corruptStore(
                    path: artifactManifestURL.path,
                    reason: "replay transaction conflicts with retained artifact"
                )
            }
            if let frameIndex, frames[frameIndex] != transaction.frame {
                throw AgentRunStoreError.corruptStore(
                    path: frameManifestURL.path,
                    reason: "replay transaction conflicts with retained frame"
                )
            }

            let bodyURL = runDirectory.appendingPathComponent(
                transaction.artifact.relativePath
            )
            let bodyIsValid: Bool
            let bodyValues = try? bodyURL.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            if bodyValues?.isRegularFile == true,
               bodyValues?.isSymbolicLink != true,
               bodyValues?.fileSize == transaction.artifact.byteCount,
               let body = try? Data(contentsOf: bodyURL, options: .mappedIfSafe) {
                bodyIsValid = body.count == transaction.artifact.byteCount
                    && sha256(body) == transaction.artifact.sha256
            } else {
                bodyIsValid = false
            }

            if artifactIndex != nil, bodyIsValid {
                if frameIndex == nil {
                    guard frames.count < maximumReplayFrameCount else {
                        throw AgentRunStoreError.artifactManifestFull(
                            maximumEntries: maximumReplayFrameCount
                        )
                    }
                    let retained = try replayFrameByteCount(
                        artifacts: artifacts,
                        frames: frames
                    )
                    let (projected, overflow) = retained.addingReportingOverflow(
                        Int64(transaction.artifact.byteCount)
                    )
                    guard !overflow,
                          projected <= Int64(maximumReplayFrameBytesPerRun) else {
                        throw AgentRunStoreError.artifactTooLarge(
                            maximumBytes: maximumReplayFrameBytesPerRun
                        )
                    }
                    frames.append(transaction.frame)
                    frames.sort {
                        $0.artifactID.uuidString < $1.artifactID.uuidString
                    }
                    try ensureDirectory(framesDirectory)
                    try write(frames, to: frameManifestURL)
                }
            } else {
                // There are not enough durable bytes to finish the transaction.
                // Remove only entries with the journal's exact identity.
                if let artifactIndex {
                    artifacts.remove(at: artifactIndex)
                    try write(artifacts, to: artifactManifestURL)
                }
                if let frameIndex {
                    frames.remove(at: frameIndex)
                    try write(frames, to: frameManifestURL)
                }
                if FileManager.default.fileExists(atPath: bodyURL.path) {
                    try FileManager.default.removeItem(at: bodyURL)
                }
            }
            try FileManager.default.removeItem(at: journalURL)
        }
    }

    private static func isOriginOnly(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return false
        }
        if scheme == "http" || scheme == "https" {
            return components.host?.isEmpty == false
        }
        return false
    }

    func listConversations() throws -> [AgentConversation] {
        conversations.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Removes only conversation metadata that has no Run backlinks on either
    /// side of the relationship. The second check protects a conversation if
    /// its cached `runIDs` array is stale while an indexed Run still owns it.
    /// This is intentionally separate from `deleteRun`: manual history policy
    /// keeps empty conversation records until the user explicitly deletes them.
    func deleteUnreferencedEmptyConversations() throws -> Set<UUID> {
        let referencedConversationIDs = Set(runs.values.compactMap(\.conversationID))
        let deletedIDs: Set<UUID> = Set(
            conversations.values.compactMap { conversation -> UUID? in
            guard conversation.runIDs.isEmpty,
                  !referencedConversationIDs.contains(conversation.id) else {
                return nil
            }
            return conversation.id
            }
        )
        guard !deletedIDs.isEmpty else { return [] }

        let removed = conversations.filter { deletedIDs.contains($0.key) }
        for id in deletedIDs {
            conversations.removeValue(forKey: id)
        }
        do {
            try persistConversationIndex()
        } catch {
            for (id, conversation) in removed {
                conversations[id] = conversation
            }
            throw error
        }
        return deletedIDs
    }

    func deleteRun(id: UUID, at date: Date = Date()) throws {
        guard let run = runs[id] else { throw AgentRunStoreError.runNotFound(id) }
        try removeRunDirectory(id: id)

        runs.removeValue(forKey: id)
        if let conversationID = run.conversationID,
           var conversation = conversations[conversationID] {
            conversation.runIDs.removeAll { $0 == id }
            conversation.updatedAt = date
            conversations[conversationID] = conversation
        }
        try persistRunIndex()
        try persistConversationIndex()
    }

    func deleteConversation(id: UUID) throws {
        guard let conversation = conversations[id] else {
            throw AgentRunStoreError.conversationNotFound(id)
        }
        let runIDs = Set(conversation.runIDs).union(
            runs.values.lazy.filter { $0.conversationID == id }.map(\.id)
        )
        for runID in runIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            try removeRunDirectory(id: runID)
        }
        for runID in runIDs {
            runs.removeValue(forKey: runID)
        }
        conversations.removeValue(forKey: id)
        try persistRunIndex()
        try persistConversationIndex()
    }

    /// Removes every durable Run/conversation plus unindexed storage entries.
    /// Active or recoverable Runs make the operation fail closed; callers must
    /// first cancel or explicitly resolve them. Each indexed Run is removed
    /// through the normal path so frame/artifact manifests, replay journals,
    /// retained bodies, and both indexes stay in sync.
    func deleteAllHistory() throws -> AgentHistoryDeletionResult {
        let nonterminalRunIDs = runs.values.filter {
            !$0.status.isTerminal
        }.map(\.id).sorted { $0.uuidString < $1.uuidString }
        guard nonterminalRunIDs.isEmpty else {
            throw AgentRunStoreError.activeRunsPreventHistoryDeletion(
                nonterminalRunIDs
            )
        }

        let runIDs = runs.keys.sorted { $0.uuidString < $1.uuidString }
        let conversationIDs = conversations.keys.sorted {
            $0.uuidString < $1.uuidString
        }
        for runID in runIDs {
            try deleteRun(id: runID)
        }
        for conversationID in conversationIDs {
            try deleteConversation(id: conversationID)
        }

        var orphanCount = 0
        for (directory, preservedName) in [
            (runsDirectory, "index.json"),
            (conversationsDirectory, "index.json"),
        ] {
            let entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey,
                ],
                options: []
            )
            for entry in entries {
                if entry.lastPathComponent == preservedName {
                    let values = try entry.resourceValues(forKeys: [
                        .isRegularFileKey, .isSymbolicLinkKey,
                    ])
                    guard values.isRegularFile == true,
                          values.isSymbolicLink != true else {
                        throw AgentRunStoreError.corruptStore(
                            path: entry.path,
                            reason: "history index is not a regular file"
                        )
                    }
                    continue
                }
                guard entry.deletingLastPathComponent().standardizedFileURL
                        == directory.standardizedFileURL else {
                    throw AgentRunStoreError.corruptStore(
                        path: entry.path,
                        reason: "history entry escaped its storage directory"
                    )
                }
                try FileManager.default.removeItem(at: entry)
                orphanCount += 1
            }
        }
        let migrationsDirectory = rootDirectory.appendingPathComponent(
            "migrations",
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: migrationsDirectory.path) {
            for entry in try FileManager.default.contentsOfDirectory(
                at: migrationsDirectory,
                includingPropertiesForKeys: nil,
                options: []
            ) {
                guard entry.deletingLastPathComponent().standardizedFileURL
                        == migrationsDirectory.standardizedFileURL else {
                    throw AgentRunStoreError.corruptStore(
                        path: entry.path,
                        reason: "migration entry escaped its storage directory"
                    )
                }
                try FileManager.default.removeItem(at: entry)
                orphanCount += 1
            }
        }
        try Self.ensureDirectory(runsDirectory)
        try Self.ensureDirectory(conversationsDirectory)
        try persistRunIndex()
        try persistConversationIndex()
        return AgentHistoryDeletionResult(
            deletedRuns: runIDs.count,
            deletedConversations: conversationIDs.count,
            deletedOrphanEntries: orphanCount
        )
    }

    /// Installs a fully validated legacy bundle and writes its receipt last.
    /// Deterministic bundle IDs make a retry repair a crash between evidence
    /// installation and index replacement without duplicating history.
    func importLegacyBundle(
        _ bundle: LegacyImportBundle,
        at date: Date = Date()
    ) throws -> LegacyImportDisposition {
        let migrations = rootDirectory.appendingPathComponent("migrations", isDirectory: true)
        try Self.ensureDirectory(migrations)
        let receiptURL = migrations.appendingPathComponent(
            "\(Self.sha256(Data(bundle.source.receiptKey.utf8))).json"
        )
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            let receipt = try Self.decode(LegacyMigrationReceipt.self, from: receiptURL)
            guard receipt.receiptKey == bundle.source.receiptKey else {
                throw AgentRunStoreError.corruptStore(
                    path: receiptURL.path,
                    reason: "migration receipt identity mismatch"
                )
            }
            return .alreadyImported
        }

        if let incoming = bundle.conversation, let existing = conversations[incoming.id] {
            guard existing.importedFromLegacy else {
                throw AgentRunStoreError.conversationAlreadyExists(incoming.id)
            }
        }
        for imported in bundle.runs {
            if let existing = runs[imported.run.id], !existing.importedFromLegacy {
                throw AgentRunStoreError.runAlreadyExists(imported.run.id)
            }
        }

        let stagingRoot = migrations
            .appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(Self.sha256(Data(bundle.source.receiptKey.utf8)), isDirectory: true)
        if FileManager.default.fileExists(atPath: stagingRoot.path) {
            try FileManager.default.removeItem(at: stagingRoot)
        }
        try Self.ensureDirectory(stagingRoot)

        var repairedExistingEvidence = false
        for imported in bundle.runs {
            let finalDirectory = runDirectory(for: imported.run.id)
            if FileManager.default.fileExists(atPath: finalDirectory.path) {
                let existing = try Self.decode(
                    AgentRun.self,
                    from: finalDirectory.appendingPathComponent("metadata.json")
                )
                guard existing.id == imported.run.id, existing.importedFromLegacy else {
                    throw AgentRunStoreError.runAlreadyExists(imported.run.id)
                }
                let existingSteps = try Self.readSteps(
                    from: finalDirectory.appendingPathComponent("steps.jsonl"),
                    runID: imported.run.id
                )
                guard existingSteps == imported.steps else {
                    throw AgentRunStoreError.corruptStore(
                        path: finalDirectory.path,
                        reason: "legacy retry evidence differs from installed run"
                    )
                }
                repairedExistingEvidence = true
                continue
            }

            let stagedDirectory = stagingRoot.appendingPathComponent(
                imported.run.id.uuidString,
                isDirectory: true
            )
            try Self.ensureDirectory(stagedDirectory)
            try Self.write(
                imported.run,
                to: stagedDirectory.appendingPathComponent("metadata.json")
            )
            try Self.writeSteps(
                imported.steps,
                to: stagedDirectory.appendingPathComponent("steps.jsonl")
            )

            if !imported.artifacts.isEmpty {
                let artifactsDirectory = stagedDirectory.appendingPathComponent("artifacts", isDirectory: true)
                try Self.ensureDirectory(artifactsDirectory)
                var manifest: [AgentArtifact] = []
                for artifact in imported.artifacts {
                    guard Self.sha256(artifact.data) == artifact.sha256 else {
                        throw AgentRunStoreError.corruptStore(
                            path: bundle.source.relativeName,
                            reason: "legacy artifact digest mismatch"
                        )
                    }
                    let relative = "artifacts/\(artifact.relativePath)"
                    let destination = stagedDirectory.appendingPathComponent(relative)
                    try Self.ensureDirectory(destination.deletingLastPathComponent())
                    try Self.writeData(artifact.data, to: destination)
                    manifest.append(AgentArtifact(
                        id: artifact.id,
                        runID: artifact.runID,
                        sourceStepID: artifact.sourceStepID,
                        contentType: artifact.contentType,
                        byteCount: artifact.data.count,
                        sha256: artifact.sha256,
                        relativePath: relative,
                        redactionState: artifact.redactionState,
                        createdAt: artifact.createdAt
                    ))
                }
                try Self.write(
                    manifest,
                    to: artifactsDirectory.appendingPathComponent("index.json")
                )
            }
        }

        for imported in bundle.runs where runs[imported.run.id] == nil {
            let staged = stagingRoot.appendingPathComponent(imported.run.id.uuidString, isDirectory: true)
            let final = runDirectory(for: imported.run.id)
            if !FileManager.default.fileExists(atPath: final.path) {
                do {
                    try FileManager.default.moveItem(at: staged, to: final)
                } catch {
                    throw AgentRunStoreError.fileOperationFailed(
                        operation: "install migrated run",
                        path: final.path,
                        reason: error.localizedDescription
                    )
                }
            }
        }
        try? FileManager.default.removeItem(at: stagingRoot)

        if let conversation = bundle.conversation {
            conversations[conversation.id] = conversation
        }
        for imported in bundle.runs {
            runs[imported.run.id] = imported.run
        }
        try persistRunIndex()
        try persistConversationIndex()
        let receipt = LegacyMigrationReceipt(
            schemaVersion: 1,
            receiptKey: bundle.source.receiptKey,
            source: bundle.source,
            conversationID: bundle.conversation?.id,
            runIDs: bundle.runs.map(\.run.id),
            issueCodes: Array(Set(bundle.issues.map(\.code))).sorted { $0.rawValue < $1.rawValue },
            importedAt: date
        )
        try Self.write(receipt, to: receiptURL)
        return repairedExistingEvidence ? .repairedIndexes : .inserted
    }

    private func runDirectory(for id: UUID) -> URL {
        runsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func metadataURL(for id: UUID) -> URL {
        runDirectory(for: id).appendingPathComponent("metadata.json")
    }

    private func stepsURL(for id: UUID) -> URL {
        runDirectory(for: id).appendingPathComponent("steps.jsonl")
    }

    private func removeRunDirectory(id: UUID) throws {
        let directory = runDirectory(for: id)
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw AgentRunStoreError.fileOperationFailed(
                operation: "delete run directory",
                path: directory.path,
                reason: error.localizedDescription
            )
        }
    }

    private func persistConversationIndex() throws {
        let ordered = conversations.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        try Self.write(AgentConversationIndex(conversations: ordered), to: conversationIndexURL)
    }

    private func persistRunIndex() throws {
        let ordered = runs.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        try Self.write(AgentRunIndex(runs: ordered), to: runIndexURL)
    }

    private static func ensureDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw AgentRunStoreError.fileOperationFailed(
                operation: "create directory",
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    private static func createEmptyFile(at url: URL) throws {
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw AgentRunStoreError.fileOperationFailed(
                operation: "create file",
                path: url.path,
                reason: "Foundation did not create the file"
            )
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw AgentRunStoreError.fileOperationFailed(
                operation: "set file permissions on",
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let error as AgentRunStoreError {
            throw error
        } catch {
            throw AgentRunStoreError.fileOperationFailed(
                operation: "write",
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    private static func writeSteps(_ steps: [AgentStep], to url: URL) throws {
        do {
            let encoder = JSONEncoder()
            var data = Data()
            for step in steps {
                data.append(try encoder.encode(step))
                data.append(0x0A)
            }
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw AgentRunStoreError.fileOperationFailed(
                operation: "write migrated steps",
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    private static func writeData(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw AgentRunStoreError.fileOperationFailed(
                operation: "write migrated artifact",
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AgentRunStoreError.corruptStore(path: url.path, reason: error.localizedDescription)
        }
    }

    private static func append(_ step: AgentStep, to url: URL) throws {
        do {
            var data = try JSONEncoder().encode(step)
            data.append(0x0A)
            let handle = try FileHandle(forUpdating: url)
            do {
                let endOffset = try handle.seekToEnd()
                if endOffset > 0 {
                    try handle.seek(toOffset: endOffset - 1)
                    let finalByte = try handle.read(upToCount: 1)?.first
                    if finalByte != 0x0A {
                        let existing = try Data(contentsOf: url)
                        let completeLength = existing.lastIndex(of: 0x0A).map {
                            existing.distance(from: existing.startIndex, to: existing.index(after: $0))
                        } ?? 0
                        try handle.truncate(atOffset: UInt64(completeLength))
                    }
                }
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw AgentRunStoreError.fileOperationFailed(
                operation: "append and synchronize",
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    private static func readSteps(from url: URL, runID: UUID) throws -> [AgentStep] {
        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { return [] }
            let hasCompleteFinalLine = data.last == 0x0A
            var result: [AgentStep] = []
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                if line.isEmpty {
                    if index == lines.count - 1, hasCompleteFinalLine { continue }
                    throw AgentRunStoreError.corruptStore(
                        path: url.path,
                        reason: "empty step record at line \(index + 1)"
                    )
                }
                do {
                    let step = try JSONDecoder().decode(AgentStep.self, from: Data(line))
                    guard step.runID == runID, step.sequence == result.count else {
                        throw AgentRunStoreError.corruptStore(
                            path: url.path,
                            reason: "non-monotonic or mismatched step at line \(index + 1)"
                        )
                    }
                    result.append(step)
                } catch where index == lines.count - 1 && !hasCompleteFinalLine {
                    break
                }
            }
            return result
        } catch let error as AgentRunStoreError {
            throw error
        } catch {
            throw AgentRunStoreError.corruptStore(path: url.path, reason: error.localizedDescription)
        }
    }
}
