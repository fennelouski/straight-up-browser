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
        }
    }
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

actor AgentRunStore {
    private let rootDirectory: URL
    private let conversationsDirectory: URL
    private let conversationIndexURL: URL
    private let runsDirectory: URL
    private let runIndexURL: URL

    private var conversations: [UUID: AgentConversation]
    private var runs: [UUID: AgentRun]

    init(baseDirectory: URL) throws {
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

        self.rootDirectory = rootDirectory
        self.conversationsDirectory = conversationsDirectory
        self.conversationIndexURL = conversationIndexURL
        self.runsDirectory = runsDirectory
        self.runIndexURL = runIndexURL
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

    func listConversations() throws -> [AgentConversation] {
        conversations.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
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
