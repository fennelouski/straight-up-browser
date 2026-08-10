import CryptoKit
import Foundation

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Public contracts

nonisolated struct CoworkRootIdentity: Codable, Equatable, Hashable, Sendable {
    let deviceID: UInt64
    let inode: UInt64
    let canonicalPathSHA256: String

    static func capture(_ rootURL: URL) throws -> Self {
        let canonical = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let status = try CoworkFileSystem.status(at: canonical, followSymbolicLinks: false)
        guard status.kind == .directory else {
            throw CoworkArtifactTransactionError.rootIsNotDirectory
        }
        return Self(
            deviceID: status.deviceID,
            inode: status.inode,
            canonicalPathSHA256: coworkSHA256(Data(canonical.path.utf8))
        )
    }
}

nonisolated enum CoworkArtifactOperation: Equatable, Sendable {
    case create(relativePath: String, content: Data, contentType: String)
    case replace(relativePath: String, content: Data, contentType: String)
    case append(relativePath: String, content: Data, contentType: String)
    case move(sourceRelativePath: String, destinationRelativePath: String)
    case recoverableDelete(relativePath: String)

    static func delete(relativePath: String) -> Self {
        .recoverableDelete(relativePath: relativePath)
    }
}

nonisolated enum CoworkArtifactOperationKind: String, Codable, CaseIterable, Sendable {
    case create
    case replace
    case append
    case move
    case recoverableDelete
}

nonisolated enum CoworkArtifactCommitState: String, Codable, Sendable {
    case staged
    case committing
    case committed
    case rolledBack
    case failed
}

nonisolated enum CoworkArtifactRisk: String, Codable, Sendable {
    case newFile
    case overwrite
    case append
    case move
    case delete
}

nonisolated struct CoworkArtifactInvocation: Codable, Equatable, Sendable {
    let toolName: String
    let invocationDigest: String

    init(toolName: String, invocationDigest: String) {
        self.toolName = toolName
        self.invocationDigest = invocationDigest
    }
}

nonisolated struct CoworkArtifactTextDiff: Codable, Equatable, Sendable {
    let unifiedText: String
    let addedLineCount: Int
    let removedLineCount: Int
    let isTruncated: Bool
}

nonisolated struct CoworkArtifactMetadataPreview: Codable, Equatable, Sendable {
    let existedBefore: Bool
    let existsAfterCommit: Bool
    let priorByteCount: Int?
    let proposedByteCount: Int
    let byteDelta: Int
    let priorSHA256: String?
    let proposedSHA256: String
    let sourceRelativePath: String?
    let destinationRelativePath: String
}

nonisolated struct CoworkArtifactPreview: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    let id: UUID
    let transactionID: UUID
    let artifactID: UUID
    let runID: UUID
    let operationKind: CoworkArtifactOperationKind
    let risk: CoworkArtifactRisk
    let commitState: CoworkArtifactCommitState
    let requiresApproval: Bool
    let contentType: String
    let sourceStepIDs: [UUID]
    let finalRelativePath: String
    let invocation: CoworkArtifactInvocation
    let metadata: CoworkArtifactMetadataPreview
    let textDiff: CoworkArtifactTextDiff?
    let previewDigest: String
    let stagedAt: Date

    fileprivate init(
        transactionID: UUID,
        artifactID: UUID,
        runID: UUID,
        operationKind: CoworkArtifactOperationKind,
        risk: CoworkArtifactRisk,
        requiresApproval: Bool,
        contentType: String,
        sourceStepIDs: [UUID],
        finalRelativePath: String,
        invocation: CoworkArtifactInvocation,
        metadata: CoworkArtifactMetadataPreview,
        textDiff: CoworkArtifactTextDiff?,
        previewDigest: String,
        stagedAt: Date
    ) {
        schemaVersion = Self.schemaVersion
        id = transactionID
        self.transactionID = transactionID
        self.artifactID = artifactID
        self.runID = runID
        self.operationKind = operationKind
        self.risk = risk
        commitState = .staged
        self.requiresApproval = requiresApproval
        self.contentType = contentType
        self.sourceStepIDs = sourceStepIDs
        self.finalRelativePath = finalRelativePath
        self.invocation = invocation
        self.metadata = metadata
        self.textDiff = textDiff
        self.previewDigest = previewDigest
        self.stagedAt = stagedAt
    }
}

nonisolated struct CoworkArtifactCommitAuthorization: Codable, Equatable, Sendable {
    let transactionID: UUID
    let runID: UUID
    let previewDigest: String
    let invocationDigest: String
    let approvedAt: Date
    let expiresAt: Date

    init(
        preview: CoworkArtifactPreview,
        approvedAt: Date = Date(),
        validFor: TimeInterval = 300
    ) {
        transactionID = preview.transactionID
        runID = preview.runID
        previewDigest = preview.previewDigest
        invocationDigest = preview.invocation.invocationDigest
        self.approvedAt = approvedAt
        expiresAt = approvedAt.addingTimeInterval(max(1, validFor))
    }
}

nonisolated struct CoworkArtifactResult: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    let id: UUID
    let transactionID: UUID
    let artifactID: UUID
    let runID: UUID
    let operationKind: CoworkArtifactOperationKind
    let contentType: String
    let byteCount: Int
    let sha256: String
    let sourceStepIDs: [UUID]
    let finalRelativePath: String
    let sourceRelativePath: String?
    let commitState: CoworkArtifactCommitState
    let existsAfterCommit: Bool
    let committedAt: Date
    let rollbackAvailableUntil: Date?
    let invocation: CoworkArtifactInvocation
    let previewDigest: String

    fileprivate init(
        transactionID: UUID,
        artifactID: UUID,
        runID: UUID,
        operationKind: CoworkArtifactOperationKind,
        contentType: String,
        byteCount: Int,
        sha256: String,
        sourceStepIDs: [UUID],
        finalRelativePath: String,
        sourceRelativePath: String?,
        commitState: CoworkArtifactCommitState,
        existsAfterCommit: Bool,
        committedAt: Date,
        rollbackAvailableUntil: Date?,
        invocation: CoworkArtifactInvocation,
        previewDigest: String
    ) {
        schemaVersion = Self.schemaVersion
        id = artifactID
        self.transactionID = transactionID
        self.artifactID = artifactID
        self.runID = runID
        self.operationKind = operationKind
        self.contentType = contentType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.sourceStepIDs = sourceStepIDs
        self.finalRelativePath = finalRelativePath
        self.sourceRelativePath = sourceRelativePath
        self.commitState = commitState
        self.existsAfterCommit = existsAfterCommit
        self.committedAt = committedAt
        self.rollbackAvailableUntil = rollbackAvailableUntil
        self.invocation = invocation
        self.previewDigest = previewDigest
    }

    var rollbackAvailable: Bool {
        rollbackAvailableUntil.map { $0 > Date() } ?? false
    }

    func boundedModelResult(maximumBytes: Int = 4_096) throws -> Data {
        guard maximumBytes >= 256 else {
            throw CoworkArtifactTransactionError.invalidLimits
        }
        let summary = CoworkArtifactModelResult(
            transactionID: transactionID,
            artifactID: artifactID,
            runID: runID,
            operationKind: operationKind,
            commitState: commitState,
            finalRelativePath: finalRelativePath,
            contentType: contentType,
            byteCount: byteCount,
            sha256: sha256,
            existsAfterCommit: existsAfterCommit
        )
        let data = try CoworkArtifactCoding.encoder().encode(summary)
        guard data.count <= maximumBytes else {
            throw CoworkArtifactTransactionError.modelResultTooLarge(
                maximumBytes: maximumBytes
            )
        }
        return data
    }
}

/// A bounded, digest-verified view of a committed Cowork result suitable for
/// copying into the Run store. Deleted artifacts intentionally have no body.
nonisolated struct CoworkDurableArtifactSnapshot: Equatable, Sendable {
    let result: CoworkArtifactResult
    let data: Data?
}

nonisolated struct CoworkArtifactModelResult: Codable, Equatable, Sendable {
    let transactionID: UUID
    let artifactID: UUID
    let runID: UUID
    let operationKind: CoworkArtifactOperationKind
    let commitState: CoworkArtifactCommitState
    let finalRelativePath: String
    let contentType: String
    let byteCount: Int
    let sha256: String
    let existsAfterCommit: Bool
}

nonisolated struct CoworkArtifactManifest: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    let runID: UUID
    var artifacts: [CoworkArtifactResult]
    var updatedAt: Date

    init(runID: UUID, artifacts: [CoworkArtifactResult] = [], updatedAt: Date = Date()) {
        schemaVersion = Self.schemaVersion
        self.runID = runID
        self.artifacts = artifacts
        self.updatedAt = updatedAt
    }
}

nonisolated enum CoworkArtifactRecoveryDisposition: String, Codable, Sendable {
    case finalizedCommitted
    case readyToRetry
    case failedClosed
}

nonisolated struct CoworkArtifactRecoveryResult: Codable, Equatable, Sendable {
    let transactionID: UUID
    let disposition: CoworkArtifactRecoveryDisposition
    let result: CoworkArtifactResult?
}

nonisolated enum CoworkArtifactCommitCheckpoint: String, Sendable {
    case beforeStagePersistence
    case afterStagePersistence
    case afterCommittingRecord
    case afterPriorVersion
    case beforeAtomicMutation
    case afterAtomicMutation
    case beforeManifestPersistence
}

nonisolated struct CoworkArtifactTransactionHooks: Sendable {
    var checkpoint: @Sendable (CoworkArtifactCommitCheckpoint) throws -> Void

    init(
        checkpoint: @escaping @Sendable (CoworkArtifactCommitCheckpoint) throws -> Void
    ) {
        self.checkpoint = checkpoint
    }

    static let none = Self { _ in }
}

nonisolated struct CoworkArtifactTransactionLimits: Codable, Equatable, Sendable {
    var maximumArtifactBytes: Int
    var maximumPathUTF8Bytes: Int
    var maximumPathDepth: Int
    var maximumSourceSteps: Int
    var maximumPendingTransactions: Int
    var maximumManifestEntries: Int
    var maximumPriorVersionsPerPath: Int
    var priorVersionRetention: TimeInterval
    var maximumDiffUTF8Bytes: Int
    var maximumModelResultBytes: Int
    var minimumFreeDiskBytes: Int64

    init(
        maximumArtifactBytes: Int = 10 * 1_024 * 1_024,
        maximumPathUTF8Bytes: Int = 1_024,
        maximumPathDepth: Int = 32,
        maximumSourceSteps: Int = 32,
        maximumPendingTransactions: Int = 64,
        maximumManifestEntries: Int = 512,
        maximumPriorVersionsPerPath: Int = 3,
        priorVersionRetention: TimeInterval = 30 * 24 * 60 * 60,
        maximumDiffUTF8Bytes: Int = 64 * 1_024,
        maximumModelResultBytes: Int = 4_096,
        minimumFreeDiskBytes: Int64 = 1 * 1_024 * 1_024
    ) {
        self.maximumArtifactBytes = maximumArtifactBytes
        self.maximumPathUTF8Bytes = maximumPathUTF8Bytes
        self.maximumPathDepth = maximumPathDepth
        self.maximumSourceSteps = maximumSourceSteps
        self.maximumPendingTransactions = maximumPendingTransactions
        self.maximumManifestEntries = maximumManifestEntries
        self.maximumPriorVersionsPerPath = maximumPriorVersionsPerPath
        self.priorVersionRetention = priorVersionRetention
        self.maximumDiffUTF8Bytes = maximumDiffUTF8Bytes
        self.maximumModelResultBytes = maximumModelResultBytes
        self.minimumFreeDiskBytes = minimumFreeDiskBytes
    }

    fileprivate func validate() throws {
        guard (1...256 * 1_024 * 1_024).contains(maximumArtifactBytes),
              (1...4_096).contains(maximumPathUTF8Bytes),
              (1...128).contains(maximumPathDepth),
              (1...1_024).contains(maximumSourceSteps),
              (1...10_000).contains(maximumPendingTransactions),
              (1...100_000).contains(maximumManifestEntries),
              (1...1_000).contains(maximumPriorVersionsPerPath),
              priorVersionRetention >= 1,
              priorVersionRetention <= 365 * 24 * 60 * 60,
              (256...1_024 * 1_024).contains(maximumDiffUTF8Bytes),
              (256...64 * 1_024).contains(maximumModelResultBytes),
              minimumFreeDiskBytes >= 0
        else {
            throw CoworkArtifactTransactionError.invalidLimits
        }
    }
}

nonisolated enum CoworkArtifactTransactionError: Error, Equatable, Sendable {
    case invalidLimits
    case rootIsNotDirectory
    case rootIdentityChanged
    case invalidRelativePath
    case pathTooLong(maximumBytes: Int)
    case pathTooDeep(maximumDepth: Int)
    case reservedPath
    case pathEscapesRoot
    case symbolicLinkRejected(String)
    case aliasRejected(String)
    case crossVolumeRejected(String)
    case hardLinkRejected(String)
    case fileNotFound(String)
    case targetAlreadyExists(String)
    case filenameCollision(String)
    case directoryOperationRejected(String)
    case binaryRewriteRequiresDedicatedHandler
    case artifactTooLarge(maximumBytes: Int)
    case insufficientDiskSpace
    case tooManySourceSteps(maximum: Int)
    case noSourceSteps
    case tooManyPendingTransactions(maximum: Int)
    case invalidInvocation
    case unknownTransaction(UUID)
    case transactionNotStaged(UUID)
    case recoveryRequired(UUID)
    case approvalRequired(UUID)
    case invalidApproval
    case expiredApproval
    case targetChanged(String)
    case rollbackUnavailable(UUID)
    case rollbackCollision(String)
    case manifestLimitExceeded(maximum: Int)
    case modelResultTooLarge(maximumBytes: Int)
    case corruptWorkspace
    case persistenceFailure
}

// MARK: - Persisted transaction evidence

private nonisolated struct CoworkArtifactFileSnapshot: Codable, Equatable, Sendable {
    let deviceID: UInt64
    let inode: UInt64
    let byteCount: Int
    let sha256: String
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
}

private nonisolated struct CoworkArtifactDirectoryAnchor: Codable, Equatable, Sendable {
    let relativePath: String
    let deviceID: UInt64
    let inode: UInt64
}

private nonisolated struct CoworkArtifactOperationDescriptor: Codable, Equatable, Sendable {
    let kind: CoworkArtifactOperationKind
    let sourceRelativePath: String?
    let destinationRelativePath: String
    let contentType: String
    let stagedFilename: String?
    let priorFilename: String
}

private nonisolated struct CoworkArtifactTransactionRecord: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    let transactionID: UUID
    let artifactID: UUID
    let runID: UUID
    let preview: CoworkArtifactPreview
    let descriptor: CoworkArtifactOperationDescriptor
    let sourceSnapshot: CoworkArtifactFileSnapshot?
    let destinationSnapshot: CoworkArtifactFileSnapshot?
    let destinationAnchor: CoworkArtifactDirectoryAnchor
    var state: CoworkArtifactCommitState
    var result: CoworkArtifactResult?
    var failureCode: String?

    init(
        transactionID: UUID,
        artifactID: UUID,
        runID: UUID,
        preview: CoworkArtifactPreview,
        descriptor: CoworkArtifactOperationDescriptor,
        sourceSnapshot: CoworkArtifactFileSnapshot?,
        destinationSnapshot: CoworkArtifactFileSnapshot?,
        destinationAnchor: CoworkArtifactDirectoryAnchor
    ) {
        schemaVersion = Self.schemaVersion
        self.transactionID = transactionID
        self.artifactID = artifactID
        self.runID = runID
        self.preview = preview
        self.descriptor = descriptor
        self.sourceSnapshot = sourceSnapshot
        self.destinationSnapshot = destinationSnapshot
        self.destinationAnchor = destinationAnchor
        state = .staged
        result = nil
        failureCode = nil
    }
}

private nonisolated struct CoworkArtifactPreviewDigestInput: Codable, Sendable {
    let transactionID: UUID
    let artifactID: UUID
    let runID: UUID
    let operationKind: CoworkArtifactOperationKind
    let risk: CoworkArtifactRisk
    let contentType: String
    let sourceStepIDs: [UUID]
    let finalRelativePath: String
    let invocation: CoworkArtifactInvocation
    let metadata: CoworkArtifactMetadataPreview
    let textDiff: CoworkArtifactTextDiff?
    let stagedAt: Date
}

private nonisolated struct CoworkResolvedPath: Sendable {
    let relativePath: String
    let url: URL
    let snapshot: CoworkArtifactFileSnapshot?
    let data: Data?
    let anchor: CoworkArtifactDirectoryAnchor
}

// MARK: - Per-Run transaction workspace

actor CoworkArtifactTransactionWorkspace {
    nonisolated let runID: UUID
    nonisolated let workspaceURL: URL

    private let rootURL: URL
    private let expectedRootIdentity: CoworkRootIdentity
    private let limits: CoworkArtifactTransactionLimits
    private let hooks: CoworkArtifactTransactionHooks
    private let transactionsURL: URL
    private let stagedURL: URL
    private let priorURL: URL
    private let manifestURL: URL
    private var records: [UUID: CoworkArtifactTransactionRecord]
    private var currentManifest: CoworkArtifactManifest

    init(
        rootURL: URL,
        expectedRootIdentity: CoworkRootIdentity,
        runID: UUID,
        limits: CoworkArtifactTransactionLimits = CoworkArtifactTransactionLimits(),
        workspaceStoreURL: URL? = nil,
        hooks: CoworkArtifactTransactionHooks = .none
    ) throws {
        try limits.validate()
        let canonicalRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard try CoworkRootIdentity.capture(canonicalRoot) == expectedRootIdentity else {
            throw CoworkArtifactTransactionError.rootIdentityChanged
        }

        self.runID = runID
        self.rootURL = canonicalRoot
        self.expectedRootIdentity = expectedRootIdentity
        self.limits = limits
        self.hooks = hooks

        let base = workspaceStoreURL?.standardizedFileURL
            ?? canonicalRoot
                .appendingPathComponent(".straight-up-browser", isDirectory: true)
                .appendingPathComponent("cowork-transactions", isDirectory: true)
        let runWorkspace = base.appendingPathComponent(runID.uuidString, isDirectory: true)
        workspaceURL = runWorkspace
        transactionsURL = runWorkspace.appendingPathComponent("transactions", isDirectory: true)
        stagedURL = runWorkspace.appendingPathComponent("staged", isDirectory: true)
        priorURL = runWorkspace.appendingPathComponent("prior", isDirectory: true)
        manifestURL = runWorkspace.appendingPathComponent("manifest.json")

        try CoworkFileSystem.createPrivateDirectoryTree(
            runWorkspace,
            protectedRoot: workspaceStoreURL == nil ? canonicalRoot : nil
        )
        try CoworkFileSystem.createPrivateDirectoryTree(
            transactionsURL,
            protectedRoot: workspaceStoreURL == nil ? canonicalRoot : nil
        )
        try CoworkFileSystem.createPrivateDirectoryTree(
            stagedURL,
            protectedRoot: workspaceStoreURL == nil ? canonicalRoot : nil
        )
        try CoworkFileSystem.createPrivateDirectoryTree(
            priorURL,
            protectedRoot: workspaceStoreURL == nil ? canonicalRoot : nil
        )
        let workspaceStatus = try CoworkFileSystem.status(
            at: runWorkspace.standardizedFileURL.resolvingSymlinksInPath(),
            followSymbolicLinks: false
        )
        guard workspaceStatus.deviceID == expectedRootIdentity.deviceID else {
            throw CoworkArtifactTransactionError.crossVolumeRejected(
                "transaction workspace"
            )
        }

        let loaded = try Self.loadWorkspace(
            transactionsURL: transactionsURL,
            manifestURL: manifestURL,
            expectedRunID: runID,
            limits: limits
        )
        records = loaded.records
        currentManifest = loaded.manifest
        if !FileManager.default.fileExists(atPath: manifestURL.path) {
            try Self.persistManifest(currentManifest, to: manifestURL)
        }
    }

    func stage(
        _ operation: CoworkArtifactOperation,
        sourceStepIDs: [UUID],
        invocation: CoworkArtifactInvocation,
        at date: Date = Date()
    ) async throws -> CoworkArtifactPreview {
        try Task.checkCancellation()
        try validateRootIdentity()
        try validate(sourceStepIDs: sourceStepIDs)
        try Self.validate(invocation: invocation)
        let pendingCount = records.values.filter {
            $0.state == .staged || $0.state == .committing
        }.count
        guard pendingCount < limits.maximumPendingTransactions else {
            throw CoworkArtifactTransactionError.tooManyPendingTransactions(
                maximum: limits.maximumPendingTransactions
            )
        }

        let transactionID = UUID()
        let artifactID = UUID()
        let stagedFilename = "\(transactionID.uuidString).data"
        let priorFilename = "\(transactionID.uuidString).prior"

        let prepared = try prepare(
            operation,
            transactionID: transactionID,
            artifactID: artifactID,
            sourceStepIDs: sourceStepIDs,
            invocation: invocation,
            stagedFilename: stagedFilename,
            priorFilename: priorFilename,
            at: date
        )
        try Task.checkCancellation()
        try hooks.checkpoint(.beforeStagePersistence)

        if let stagedData = prepared.stagedData {
            try ensureDiskCapacity(forAdditionalBytes: stagedData.count)
            try CoworkFileSystem.atomicWrite(
                stagedData,
                to: stagedURL.appendingPathComponent(stagedFilename),
                replaceExisting: false
            )
        }
        do {
            try Self.persistRecord(prepared.record, in: transactionsURL)
        } catch {
            try? FileManager.default.removeItem(
                at: stagedURL.appendingPathComponent(stagedFilename)
            )
            throw error
        }
        records[transactionID] = prepared.record
        try hooks.checkpoint(.afterStagePersistence)
        return prepared.record.preview
    }

    func preview(transactionID: UUID) throws -> CoworkArtifactPreview {
        guard let record = records[transactionID] else {
            throw CoworkArtifactTransactionError.unknownTransaction(transactionID)
        }
        return record.preview
    }

    func manifest() -> CoworkArtifactManifest {
        currentManifest
    }

    func pendingPreviews() -> [CoworkArtifactPreview] {
        records.values.filter { $0.state == .staged }
            .map(\.preview)
            .sorted { $0.stagedAt < $1.stagedAt }
    }

    /// Removes only this Run's private transaction workspace after the
    /// selected root has been revalidated. Committed destination files live
    /// outside this directory and are deliberately preserved.
    @discardableResult
    func removePrivateWorkspace() throws -> Bool {
        try CoworkArtifactWorkspaceRetention.remove(
            runID: runID,
            rootURL: rootURL,
            expectedRootIdentity: expectedRootIdentity
        )
    }

    func durableArtifactSnapshot(
        transactionID: UUID
    ) throws -> CoworkDurableArtifactSnapshot {
        try validateRootIdentity()
        guard let record = records[transactionID] else {
            throw CoworkArtifactTransactionError.unknownTransaction(transactionID)
        }
        guard (record.state == .committed || record.state == .rolledBack),
              let result = record.result else {
            throw CoworkArtifactTransactionError.transactionNotStaged(transactionID)
        }
        guard result.runID == runID,
              result.transactionID == transactionID,
              result.artifactID == record.artifactID else {
            throw CoworkArtifactTransactionError.corruptWorkspace
        }
        guard result.existsAfterCommit else {
            return CoworkDurableArtifactSnapshot(result: result, data: nil)
        }
        let resolved = try resolve(
            result.finalRelativePath,
            requirement: .mustExist,
            loadData: true
        )
        guard let data = resolved.data,
              data.count == result.byteCount,
              coworkSHA256(data) == result.sha256 else {
            throw CoworkArtifactTransactionError.targetChanged(
                result.finalRelativePath
            )
        }
        return CoworkDurableArtifactSnapshot(result: result, data: data)
    }

    // Remaining commit, rollback, and recovery methods follow below.
}

/// Deletes only the exact private transaction directory for a retained Run.
/// The selected Cowork root and the hidden parents are revalidated without
/// following symlinks before recursive removal.
nonisolated enum CoworkArtifactWorkspaceRetention {
    /// Removes every private Run workspace under an exact, revalidated Cowork
    /// root. Committed destination files live outside the private workspace
    /// and are preserved. Any staged bytes and rollback copies are deleted,
    /// so transactions from the disconnected root cannot later be committed
    /// or rolled back.
    @discardableResult
    static func removeAll(
        rootURL: URL,
        expectedRootIdentity: CoworkRootIdentity
    ) throws -> Int {
        let canonicalRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard try CoworkRootIdentity.capture(canonicalRoot) == expectedRootIdentity else {
            throw CoworkArtifactTransactionError.rootIdentityChanged
        }
        let hidden = canonicalRoot.appendingPathComponent(
            ".straight-up-browser",
            isDirectory: true
        )
        let base = hidden.appendingPathComponent(
            "cowork-transactions",
            isDirectory: true
        )
        guard let hiddenStatus = try CoworkFileSystem.optionalStatus(
            at: hidden,
            followSymbolicLinks: false
        ) else { return 0 }
        guard hiddenStatus.kind == .directory,
              hiddenStatus.deviceID == expectedRootIdentity.deviceID else {
            throw CoworkArtifactTransactionError.corruptWorkspace
        }
        guard let baseStatus = try CoworkFileSystem.optionalStatus(
            at: base,
            followSymbolicLinks: false
        ) else { return 0 }
        guard baseStatus.kind == .directory,
              baseStatus.deviceID == expectedRootIdentity.deviceID,
              base.deletingLastPathComponent().standardizedFileURL == hidden.standardizedFileURL
        else {
            throw CoworkArtifactTransactionError.corruptWorkspace
        }

        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw CoworkArtifactTransactionError.persistenceFailure
        }
        let runIDs = try entries.map { entry -> UUID in
            let name = entry.lastPathComponent
            guard let runID = UUID(uuidString: name),
                  runID.uuidString == name,
                  entry.deletingLastPathComponent().standardizedFileURL == base.standardizedFileURL
            else {
                throw CoworkArtifactTransactionError.corruptWorkspace
            }
            return runID
        }.sorted { $0.uuidString < $1.uuidString }

        var removedCount = 0
        for runID in runIDs {
            if try remove(
                runID: runID,
                rootURL: canonicalRoot,
                expectedRootIdentity: expectedRootIdentity
            ) {
                removedCount += 1
            }
        }
        return removedCount
    }

    @discardableResult
    static func remove(
        runID: UUID,
        rootURL: URL,
        expectedRootIdentity: CoworkRootIdentity
    ) throws -> Bool {
        let canonicalRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard try CoworkRootIdentity.capture(canonicalRoot) == expectedRootIdentity else {
            throw CoworkArtifactTransactionError.rootIdentityChanged
        }
        let hidden = canonicalRoot.appendingPathComponent(
            ".straight-up-browser",
            isDirectory: true
        )
        let base = hidden.appendingPathComponent(
            "cowork-transactions",
            isDirectory: true
        )
        let workspace = base.appendingPathComponent(
            runID.uuidString,
            isDirectory: true
        )
        guard let hiddenStatus = try CoworkFileSystem.optionalStatus(
            at: hidden,
            followSymbolicLinks: false
        ) else { return false }
        guard hiddenStatus.kind == .directory,
              hiddenStatus.deviceID == expectedRootIdentity.deviceID else {
            throw CoworkArtifactTransactionError.corruptWorkspace
        }
        guard let baseStatus = try CoworkFileSystem.optionalStatus(
            at: base,
            followSymbolicLinks: false
        ) else { return false }
        guard baseStatus.kind == .directory,
              baseStatus.deviceID == expectedRootIdentity.deviceID else {
            throw CoworkArtifactTransactionError.corruptWorkspace
        }
        guard let workspaceStatus = try CoworkFileSystem.optionalStatus(
            at: workspace,
            followSymbolicLinks: false
        ) else { return false }
        guard workspaceStatus.kind == .directory,
              workspaceStatus.deviceID == expectedRootIdentity.deviceID,
              workspace.deletingLastPathComponent().standardizedFileURL == base.standardizedFileURL
        else {
            throw CoworkArtifactTransactionError.corruptWorkspace
        }
        do {
            try FileManager.default.removeItem(at: workspace)
            return true
        } catch {
            throw CoworkArtifactTransactionError.persistenceFailure
        }
    }
}

private nonisolated struct CoworkPreparedTransaction: Sendable {
    let record: CoworkArtifactTransactionRecord
    let stagedData: Data?
}

private nonisolated enum CoworkPathRequirement: Sendable {
    case mustExist
    case mustNotExist
}

private extension CoworkArtifactTransactionWorkspace {
    func prepare(
        _ operation: CoworkArtifactOperation,
        transactionID: UUID,
        artifactID: UUID,
        sourceStepIDs: [UUID],
        invocation: CoworkArtifactInvocation,
        stagedFilename: String,
        priorFilename: String,
        at date: Date
    ) throws -> CoworkPreparedTransaction {
        let kind: CoworkArtifactOperationKind
        let risk: CoworkArtifactRisk
        let contentType: String
        let finalPath: CoworkResolvedPath
        let sourcePath: CoworkResolvedPath?
        let stagedData: Data?
        let priorData: Data?
        let requiresApproval: Bool

        switch operation {
        case .create(let path, let content, let proposedContentType):
            try validateContent(content)
            try Self.validate(contentType: proposedContentType)
            kind = .create
            risk = .newFile
            contentType = proposedContentType
            finalPath = try resolve(
                path,
                requirement: .mustNotExist,
                loadData: false
            )
            sourcePath = nil
            stagedData = content
            priorData = nil
            requiresApproval = false

        case .replace(let path, let content, let proposedContentType):
            try validateContent(content)
            try Self.validate(contentType: proposedContentType)
            guard Self.isTextContentType(proposedContentType),
                  String(data: content, encoding: .utf8) != nil
            else {
                throw CoworkArtifactTransactionError.binaryRewriteRequiresDedicatedHandler
            }
            kind = .replace
            risk = .overwrite
            contentType = proposedContentType
            finalPath = try resolve(path, requirement: .mustExist, loadData: true)
            guard let existing = finalPath.data,
                  String(data: existing, encoding: .utf8) != nil
            else {
                throw CoworkArtifactTransactionError.binaryRewriteRequiresDedicatedHandler
            }
            sourcePath = nil
            stagedData = content
            priorData = existing
            requiresApproval = true

        case .append(let path, let content, let proposedContentType):
            try validateContent(content)
            try Self.validate(contentType: proposedContentType)
            guard Self.isTextContentType(proposedContentType),
                  String(data: content, encoding: .utf8) != nil
            else {
                throw CoworkArtifactTransactionError.binaryRewriteRequiresDedicatedHandler
            }
            kind = .append
            risk = .append
            contentType = proposedContentType
            finalPath = try resolve(path, requirement: .mustExist, loadData: true)
            guard let existing = finalPath.data,
                  String(data: existing, encoding: .utf8) != nil
            else {
                throw CoworkArtifactTransactionError.binaryRewriteRequiresDedicatedHandler
            }
            guard existing.count <= limits.maximumArtifactBytes - content.count else {
                throw CoworkArtifactTransactionError.artifactTooLarge(
                    maximumBytes: limits.maximumArtifactBytes
                )
            }
            sourcePath = nil
            stagedData = existing + content
            priorData = existing
            requiresApproval = true

        case .move(let source, let destination):
            kind = .move
            risk = .move
            let resolvedSource = try resolve(
                source,
                requirement: .mustExist,
                loadData: true
            )
            let resolvedDestination = try resolve(
                destination,
                requirement: .mustNotExist,
                loadData: false
            )
            guard resolvedSource.relativePath != resolvedDestination.relativePath else {
                throw CoworkArtifactTransactionError.filenameCollision(destination)
            }
            sourcePath = resolvedSource
            finalPath = resolvedDestination
            let bytes = try Self.requireData(resolvedSource)
            contentType = Self.inferredContentType(
                relativePath: resolvedSource.relativePath,
                data: bytes
            )
            stagedData = nil
            priorData = bytes
            requiresApproval = true

        case .recoverableDelete(let path):
            kind = .recoverableDelete
            risk = .delete
            let resolved = try resolve(path, requirement: .mustExist, loadData: true)
            sourcePath = resolved
            finalPath = resolved
            let bytes = try Self.requireData(resolved)
            contentType = Self.inferredContentType(
                relativePath: resolved.relativePath,
                data: bytes
            )
            stagedData = nil
            priorData = bytes
            requiresApproval = true
        }

        let priorBytes = priorData?.count
        let proposedBytes: Int
        let proposedDigest: String
        let existsAfter: Bool
        switch kind {
        case .recoverableDelete:
            proposedBytes = 0
            proposedDigest = coworkSHA256(Data())
            existsAfter = false
        case .move:
            proposedBytes = priorData?.count ?? 0
            proposedDigest = sourcePath?.snapshot?.sha256 ?? coworkSHA256(Data())
            existsAfter = true
        case .create, .replace, .append:
            proposedBytes = stagedData?.count ?? 0
            proposedDigest = coworkSHA256(stagedData ?? Data())
            existsAfter = true
        }
        let priorDigest = sourcePath?.snapshot?.sha256
            ?? finalPath.snapshot?.sha256
        let metadata = CoworkArtifactMetadataPreview(
            existedBefore: finalPath.snapshot != nil || sourcePath?.snapshot != nil,
            existsAfterCommit: existsAfter,
            priorByteCount: priorBytes,
            proposedByteCount: proposedBytes,
            byteDelta: proposedBytes - (priorBytes ?? 0),
            priorSHA256: priorDigest,
            proposedSHA256: proposedDigest,
            sourceRelativePath: kind == .move ? sourcePath?.relativePath : nil,
            destinationRelativePath: finalPath.relativePath
        )
        let diff: CoworkArtifactTextDiff?
        switch kind {
        case .create:
            diff = Self.textDiff(
                before: Data(),
                after: stagedData ?? Data(),
                maximumBytes: limits.maximumDiffUTF8Bytes
            )
        case .replace, .append:
            diff = Self.textDiff(
                before: priorData ?? Data(),
                after: stagedData ?? Data(),
                maximumBytes: limits.maximumDiffUTF8Bytes
            )
        case .recoverableDelete:
            diff = Self.textDiff(
                before: priorData ?? Data(),
                after: Data(),
                maximumBytes: limits.maximumDiffUTF8Bytes
            )
        case .move:
            diff = nil
        }

        let digestInput = CoworkArtifactPreviewDigestInput(
            transactionID: transactionID,
            artifactID: artifactID,
            runID: runID,
            operationKind: kind,
            risk: risk,
            contentType: contentType,
            sourceStepIDs: sourceStepIDs,
            finalRelativePath: finalPath.relativePath,
            invocation: invocation,
            metadata: metadata,
            textDiff: diff,
            stagedAt: date
        )
        let previewDigest = coworkSHA256(
            try CoworkArtifactCoding.encoder().encode(digestInput)
        )
        let preview = CoworkArtifactPreview(
            transactionID: transactionID,
            artifactID: artifactID,
            runID: runID,
            operationKind: kind,
            risk: risk,
            requiresApproval: requiresApproval,
            contentType: contentType,
            sourceStepIDs: sourceStepIDs,
            finalRelativePath: finalPath.relativePath,
            invocation: invocation,
            metadata: metadata,
            textDiff: diff,
            previewDigest: previewDigest,
            stagedAt: date
        )
        let descriptor = CoworkArtifactOperationDescriptor(
            kind: kind,
            sourceRelativePath: kind == .move ? sourcePath?.relativePath : nil,
            destinationRelativePath: finalPath.relativePath,
            contentType: contentType,
            stagedFilename: stagedData == nil ? nil : stagedFilename,
            priorFilename: priorFilename
        )
        let record = CoworkArtifactTransactionRecord(
            transactionID: transactionID,
            artifactID: artifactID,
            runID: runID,
            preview: preview,
            descriptor: descriptor,
            sourceSnapshot: sourcePath?.snapshot,
            destinationSnapshot: finalPath.snapshot,
            destinationAnchor: finalPath.anchor
        )
        return CoworkPreparedTransaction(record: record, stagedData: stagedData)
    }

    func resolve(
        _ relativePath: String,
        requirement: CoworkPathRequirement,
        loadData: Bool
    ) throws -> CoworkResolvedPath {
        let normalized = try CoworkFileSystem.validateRelativePath(
            relativePath,
            maximumBytes: limits.maximumPathUTF8Bytes,
            maximumDepth: limits.maximumPathDepth
        )
        return try CoworkFileSystem.resolve(
            normalized,
            beneath: rootURL,
            rootIdentity: expectedRootIdentity,
            requirement: requirement,
            loadData: loadData,
            maximumBytes: limits.maximumArtifactBytes
        )
    }

    func validateRootIdentity() throws {
        guard try CoworkRootIdentity.capture(rootURL) == expectedRootIdentity else {
            throw CoworkArtifactTransactionError.rootIdentityChanged
        }
    }

    func validate(sourceStepIDs: [UUID]) throws {
        guard !sourceStepIDs.isEmpty else {
            throw CoworkArtifactTransactionError.noSourceSteps
        }
        guard sourceStepIDs.count <= limits.maximumSourceSteps else {
            throw CoworkArtifactTransactionError.tooManySourceSteps(
                maximum: limits.maximumSourceSteps
            )
        }
        guard Set(sourceStepIDs).count == sourceStepIDs.count else {
            throw CoworkArtifactTransactionError.invalidInvocation
        }
    }

    func validateContent(_ content: Data) throws {
        guard content.count <= limits.maximumArtifactBytes else {
            throw CoworkArtifactTransactionError.artifactTooLarge(
                maximumBytes: limits.maximumArtifactBytes
            )
        }
    }

    func ensureDiskCapacity(forAdditionalBytes byteCount: Int) throws {
        guard byteCount >= 0 else {
            throw CoworkArtifactTransactionError.insufficientDiskSpace
        }
        let values = try? workspaceURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        if let capacity = values?.volumeAvailableCapacityForImportantUsage,
           capacity > 0,
           capacity < Int64(byteCount) + limits.minimumFreeDiskBytes {
            throw CoworkArtifactTransactionError.insufficientDiskSpace
        }
    }

    nonisolated static func validate(invocation: CoworkArtifactInvocation) throws {
        guard !invocation.toolName.isEmpty,
              invocation.toolName.lengthOfBytes(using: .utf8) <= 128,
              !invocation.invocationDigest.isEmpty,
              invocation.invocationDigest.lengthOfBytes(using: .utf8) <= 512,
              !invocation.toolName.unicodeScalars.contains(where: { $0.value < 0x20 }),
              !invocation.invocationDigest.unicodeScalars.contains(where: { $0.value < 0x20 })
        else {
            throw CoworkArtifactTransactionError.invalidInvocation
        }
    }

    nonisolated static func validate(contentType: String) throws {
        guard !contentType.isEmpty,
              contentType.lengthOfBytes(using: .utf8) <= 256,
              !contentType.unicodeScalars.contains(where: { $0.value < 0x20 })
        else {
            throw CoworkArtifactTransactionError.invalidInvocation
        }
    }

    nonisolated static func requireData(_ path: CoworkResolvedPath) throws -> Data {
        guard let data = path.data else {
            throw CoworkArtifactTransactionError.corruptWorkspace
        }
        return data
    }

    nonisolated static func isTextContentType(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("text/")
            || lower == "application/json"
            || lower == "application/xml"
            || lower == "application/javascript"
            || lower.hasSuffix("+json")
            || lower.hasSuffix("+xml")
    }

    nonisolated static func inferredContentType(
        relativePath: String,
        data: Data
    ) -> String {
        if String(data: data, encoding: .utf8) != nil {
            switch URL(fileURLWithPath: relativePath).pathExtension.lowercased() {
            case "json": return "application/json"
            case "html", "htm": return "text/html"
            case "md", "markdown": return "text/markdown"
            case "csv": return "text/csv"
            default: return "text/plain"
            }
        }
        return "application/octet-stream"
    }

    nonisolated static func textDiff(
        before: Data,
        after: Data,
        maximumBytes: Int
    ) -> CoworkArtifactTextDiff? {
        guard let beforeText = String(data: before, encoding: .utf8),
              let afterText = String(data: after, encoding: .utf8)
        else { return nil }
        let beforeLines = beforeText.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        let afterLines = afterText.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        let unchangedPrefix = zip(beforeLines, afterLines).prefix {
            $0.0 == $0.1
        }.count
        let remainingBefore = Array(beforeLines.dropFirst(unchangedPrefix))
        let remainingAfter = Array(afterLines.dropFirst(unchangedPrefix))
        let unchangedSuffix = zip(remainingBefore.reversed(), remainingAfter.reversed())
            .prefix { $0.0 == $0.1 }.count
        let removed = remainingBefore.dropLast(unchangedSuffix)
        let added = remainingAfter.dropLast(unchangedSuffix)

        var output = "--- before\n+++ after\n"
        if unchangedPrefix > 0 {
            output += beforeLines.prefix(unchangedPrefix).suffix(2)
                .map { " \($0)" }.joined(separator: "\n") + "\n"
        }
        output += removed.map { "-\($0)" }.joined(separator: "\n")
        if !removed.isEmpty { output += "\n" }
        output += added.map { "+\($0)" }.joined(separator: "\n")
        if !added.isEmpty { output += "\n" }
        if unchangedSuffix > 0 {
            output += remainingAfter.suffix(unchangedSuffix).prefix(2)
                .map { " \($0)" }.joined(separator: "\n") + "\n"
        }

        let bytes = Data(output.utf8)
        let truncated: Bool
        let bounded: String
        if bytes.count > maximumBytes {
            truncated = true
            let prefix = bytes.prefix(max(0, maximumBytes - 32))
            bounded = String(decoding: prefix, as: UTF8.self)
                + "\n… diff truncated …\n"
        } else {
            truncated = false
            bounded = output
        }
        return CoworkArtifactTextDiff(
            unifiedText: bounded,
            addedLineCount: added.count,
            removedLineCount: removed.count,
            isTruncated: truncated
        )
    }
}

// MARK: - Contained filesystem primitives

private nonisolated enum CoworkFileKind: Sendable {
    case regular
    case directory
    case symbolicLink
    case other
}

private nonisolated struct CoworkFileStatus: Sendable {
    let kind: CoworkFileKind
    let deviceID: UInt64
    let inode: UInt64
    let linkCount: UInt64
    let byteCount: Int
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
}

private nonisolated enum CoworkFileSystem {
    static func status(
        at url: URL,
        followSymbolicLinks: Bool
    ) throws -> CoworkFileStatus {
        guard let value = try optionalStatus(
            at: url,
            followSymbolicLinks: followSymbolicLinks
        ) else {
            throw CoworkArtifactTransactionError.persistenceFailure
        }
        return value
    }

    static func optionalStatus(
        at url: URL,
        followSymbolicLinks: Bool
    ) throws -> CoworkFileStatus? {
        #if canImport(Darwin)
        var raw = Darwin.stat()
        let result = url.path.withCString { pointer in
            Darwin.fstatat(
                AT_FDCWD,
                pointer,
                &raw,
                followSymbolicLinks ? 0 : AT_SYMLINK_NOFOLLOW
            )
        }
        if result != 0 {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw CoworkArtifactTransactionError.persistenceFailure
        }
        let masked = raw.st_mode & mode_t(S_IFMT)
        let kind: CoworkFileKind
        switch masked {
        case mode_t(S_IFREG): kind = .regular
        case mode_t(S_IFDIR): kind = .directory
        case mode_t(S_IFLNK): kind = .symbolicLink
        default: kind = .other
        }
        guard raw.st_size >= 0, raw.st_size <= off_t(Int.max) else {
            throw CoworkArtifactTransactionError.persistenceFailure
        }
        return CoworkFileStatus(
            kind: kind,
            deviceID: UInt64(bitPattern: Int64(raw.st_dev)),
            inode: UInt64(raw.st_ino),
            linkCount: UInt64(raw.st_nlink),
            byteCount: Int(raw.st_size),
            modifiedSeconds: Int64(raw.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(raw.st_mtimespec.tv_nsec)
        )
        #else
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ])
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return nil
        } catch {
            throw CoworkArtifactTransactionError.persistenceFailure
        }
        let kind: CoworkFileKind = values.isSymbolicLink == true ? .symbolicLink
            : values.isDirectory == true ? .directory
            : values.isRegularFile == true ? .regular : .other
        return CoworkFileStatus(
            kind: kind,
            deviceID: 0,
            inode: 0,
            linkCount: 1,
            byteCount: values.fileSize ?? 0,
            modifiedSeconds: Int64(values.contentModificationDate?.timeIntervalSince1970 ?? 0),
            modifiedNanoseconds: 0
        )
        #endif
    }

    static func validateRelativePath(
        _ value: String,
        maximumBytes: Int,
        maximumDepth: Int
    ) throws -> String {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.hasPrefix("~"),
              !(value as NSString).isAbsolutePath,
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: {
                  $0.value == 0 || $0.value < 0x20 || $0.value == 0x7F
              })
        else {
            throw CoworkArtifactTransactionError.invalidRelativePath
        }
        let normalized = value.precomposedStringWithCanonicalMapping
        guard normalized == value else {
            throw CoworkArtifactTransactionError.filenameCollision(value)
        }
        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ component in
                  !component.isEmpty
                      && component != "."
                      && component != ".."
                      && component.lengthOfBytes(using: .utf8) <= 255
              })
        else {
            throw CoworkArtifactTransactionError.invalidRelativePath
        }
        guard value.lengthOfBytes(using: .utf8) <= maximumBytes else {
            throw CoworkArtifactTransactionError.pathTooLong(
                maximumBytes: maximumBytes
            )
        }
        guard components.count <= maximumDepth else {
            throw CoworkArtifactTransactionError.pathTooDeep(
                maximumDepth: maximumDepth
            )
        }
        guard components[0].caseInsensitiveCompare(".straight-up-browser") != .orderedSame
        else {
            throw CoworkArtifactTransactionError.reservedPath
        }
        return value
    }

    static func resolve(
        _ relativePath: String,
        beneath rootURL: URL,
        rootIdentity: CoworkRootIdentity,
        requirement: CoworkPathRequirement,
        loadData: Bool,
        maximumBytes: Int
    ) throws -> CoworkResolvedPath {
        guard try CoworkRootIdentity.capture(rootURL) == rootIdentity else {
            throw CoworkArtifactTransactionError.rootIdentityChanged
        }
        let components = relativePath.split(separator: "/").map(String.init)
        var current = rootURL
        var currentRelativeComponents: [String] = []
        let rootStatus = try status(at: rootURL, followSymbolicLinks: false)
        var currentDirectoryStatus = rootStatus

        for (index, component) in components.enumerated() {
            guard currentDirectoryStatus.kind == .directory else {
                throw CoworkArtifactTransactionError.directoryOperationRejected(
                    currentRelativeComponents.joined(separator: "/")
                )
            }
            try rejectFilenameCollision(in: current, requestedName: component)
            let child = current.appendingPathComponent(component)
            let lexical = child.standardizedFileURL
            guard isContained(lexical, beneath: rootURL) else {
                throw CoworkArtifactTransactionError.pathEscapesRoot
            }
            let existing = try optionalStatus(at: child, followSymbolicLinks: false)
            let isLeaf = index == components.count - 1
            guard let existing else {
                if requirement == .mustExist {
                    throw CoworkArtifactTransactionError.fileNotFound(relativePath)
                }
                let anchor = CoworkArtifactDirectoryAnchor(
                    relativePath: currentRelativeComponents.joined(separator: "/"),
                    deviceID: currentDirectoryStatus.deviceID,
                    inode: currentDirectoryStatus.inode
                )
                return CoworkResolvedPath(
                    relativePath: relativePath,
                    url: rootURL.appendingPathComponent(relativePath),
                    snapshot: nil,
                    data: nil,
                    anchor: anchor
                )
            }
            if existing.kind == .symbolicLink {
                throw CoworkArtifactTransactionError.symbolicLinkRejected(relativePath)
            }
            if try isAliasFile(child) {
                throw CoworkArtifactTransactionError.aliasRejected(relativePath)
            }
            guard existing.deviceID == rootIdentity.deviceID else {
                throw CoworkArtifactTransactionError.crossVolumeRejected(relativePath)
            }
            if !isLeaf {
                guard existing.kind == .directory else {
                    throw CoworkArtifactTransactionError.directoryOperationRejected(
                        currentRelativeComponents.joined(separator: "/")
                    )
                }
                current = child
                currentRelativeComponents.append(component)
                currentDirectoryStatus = existing
                continue
            }

            if requirement == .mustNotExist {
                throw CoworkArtifactTransactionError.targetAlreadyExists(relativePath)
            }
            guard existing.kind == .regular else {
                throw CoworkArtifactTransactionError.directoryOperationRejected(relativePath)
            }
            guard existing.linkCount == 1 else {
                throw CoworkArtifactTransactionError.hardLinkRejected(relativePath)
            }
            guard existing.byteCount <= maximumBytes else {
                throw CoworkArtifactTransactionError.artifactTooLarge(
                    maximumBytes: maximumBytes
                )
            }
            let data = try readBoundedData(at: child, maximumBytes: maximumBytes)
            let afterRead = try status(at: child, followSymbolicLinks: false)
            guard afterRead.deviceID == existing.deviceID,
                  afterRead.inode == existing.inode,
                  afterRead.byteCount == existing.byteCount,
                  afterRead.modifiedSeconds == existing.modifiedSeconds,
                  afterRead.modifiedNanoseconds == existing.modifiedNanoseconds,
                  afterRead.linkCount == 1
            else {
                throw CoworkArtifactTransactionError.targetChanged(relativePath)
            }
            let anchor = CoworkArtifactDirectoryAnchor(
                relativePath: currentRelativeComponents.joined(separator: "/"),
                deviceID: currentDirectoryStatus.deviceID,
                inode: currentDirectoryStatus.inode
            )
            return CoworkResolvedPath(
                relativePath: relativePath,
                url: child,
                snapshot: CoworkArtifactFileSnapshot(
                    deviceID: existing.deviceID,
                    inode: existing.inode,
                    byteCount: data.count,
                    sha256: coworkSHA256(data),
                    modifiedSeconds: existing.modifiedSeconds,
                    modifiedNanoseconds: existing.modifiedNanoseconds
                ),
                data: loadData ? data : nil,
                anchor: anchor
            )
        }
        throw CoworkArtifactTransactionError.invalidRelativePath
    }

    static func validate(
        anchor: CoworkArtifactDirectoryAnchor,
        beneath rootURL: URL,
        rootIdentity: CoworkRootIdentity
    ) throws {
        guard try CoworkRootIdentity.capture(rootURL) == rootIdentity else {
            throw CoworkArtifactTransactionError.rootIdentityChanged
        }
        let url = anchor.relativePath.isEmpty
            ? rootURL
            : rootURL.appendingPathComponent(anchor.relativePath)
        guard isContained(url.standardizedFileURL, beneath: rootURL),
              let status = try optionalStatus(at: url, followSymbolicLinks: false),
              status.kind == .directory,
              status.deviceID == anchor.deviceID,
              status.inode == anchor.inode,
              status.deviceID == rootIdentity.deviceID,
              !(try isAliasFile(url))
        else {
            throw CoworkArtifactTransactionError.targetChanged(anchor.relativePath)
        }
    }

    static func createDestinationParents(
        for relativePath: String,
        beneath rootURL: URL,
        rootIdentity: CoworkRootIdentity,
        maximumDepth: Int
    ) throws {
        guard try CoworkRootIdentity.capture(rootURL) == rootIdentity else {
            throw CoworkArtifactTransactionError.rootIdentityChanged
        }
        let components = relativePath.split(separator: "/").dropLast().map(String.init)
        guard components.count <= maximumDepth else {
            throw CoworkArtifactTransactionError.pathTooDeep(maximumDepth: maximumDepth)
        }
        var current = rootURL
        for component in components {
            try rejectFilenameCollision(in: current, requestedName: component)
            let child = current.appendingPathComponent(component)
            if let existing = try optionalStatus(at: child, followSymbolicLinks: false) {
                guard existing.kind == .directory,
                      existing.deviceID == rootIdentity.deviceID,
                      !(try isAliasFile(child))
                else {
                    if existing.kind == .symbolicLink {
                        throw CoworkArtifactTransactionError.symbolicLinkRejected(relativePath)
                    }
                    throw CoworkArtifactTransactionError.directoryOperationRejected(relativePath)
                }
            } else {
                try createDirectory(child)
                let created = try status(at: child, followSymbolicLinks: false)
                guard created.kind == .directory,
                      created.deviceID == rootIdentity.deviceID
                else {
                    throw CoworkArtifactTransactionError.crossVolumeRejected(relativePath)
                }
            }
            current = child
        }
    }

    static func createPrivateDirectoryTree(
        _ destination: URL,
        protectedRoot: URL?
    ) throws {
        if let protectedRoot {
            guard isContained(destination.standardizedFileURL, beneath: protectedRoot) else {
                throw CoworkArtifactTransactionError.pathEscapesRoot
            }
            let relative = String(
                destination.standardizedFileURL.path
                    .dropFirst(protectedRoot.standardizedFileURL.path.count)
            ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var current = protectedRoot
            let protectedDeviceID = try CoworkRootIdentity.capture(
                protectedRoot
            ).deviceID
            for component in relative.split(separator: "/").map(String.init) {
                let child = current.appendingPathComponent(component)
                if let existing = try optionalStatus(at: child, followSymbolicLinks: false) {
                    guard existing.kind == .directory,
                          existing.deviceID == protectedDeviceID,
                          !(try isAliasFile(child))
                    else {
                        if existing.kind == .symbolicLink {
                            throw CoworkArtifactTransactionError.symbolicLinkRejected(
                                "transaction workspace"
                            )
                        }
                        throw CoworkArtifactTransactionError.corruptWorkspace
                    }
                } else {
                    try createDirectory(child)
                }
                current = child
            }
        } else {
            do {
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw CoworkArtifactTransactionError.persistenceFailure
            }
            guard let status = try optionalStatus(
                at: destination,
                followSymbolicLinks: false
            ), status.kind == .directory, !(try isAliasFile(destination)) else {
                throw CoworkArtifactTransactionError.corruptWorkspace
            }
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: destination.path
            )
        } catch {
            throw CoworkArtifactTransactionError.persistenceFailure
        }
    }

    static func createDirectory(_ url: URL) throws {
        #if canImport(Darwin)
        let result = url.path.withCString { Darwin.mkdir($0, 0o700) }
        if result != 0 && errno != EEXIST {
            if errno == ENOSPC { throw CoworkArtifactTransactionError.insufficientDiskSpace }
            throw CoworkArtifactTransactionError.persistenceFailure
        }
        #else
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw CoworkArtifactTransactionError.persistenceFailure
        }
        #endif
    }

    static func readBoundedData(at url: URL, maximumBytes: Int) throws -> Data {
        guard let status = try optionalStatus(at: url, followSymbolicLinks: false),
              status.kind == .regular,
              status.byteCount <= maximumBytes
        else {
            if let status = try optionalStatus(at: url, followSymbolicLinks: false),
               status.byteCount > maximumBytes {
                throw CoworkArtifactTransactionError.artifactTooLarge(
                    maximumBytes: maximumBytes
                )
            }
            throw CoworkArtifactTransactionError.persistenceFailure
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw CoworkArtifactTransactionError.persistenceFailure
        }
        guard data.count <= maximumBytes else {
            throw CoworkArtifactTransactionError.artifactTooLarge(
                maximumBytes: maximumBytes
            )
        }
        return data
    }

    static func atomicWrite(
        _ data: Data,
        to destination: URL,
        replaceExisting: Bool
    ) throws {
        let parent = destination.deletingLastPathComponent()
        guard let parentStatus = try optionalStatus(
            at: parent,
            followSymbolicLinks: false
        ), parentStatus.kind == .directory else {
            throw CoworkArtifactTransactionError.persistenceFailure
        }
        if !replaceExisting,
           try optionalStatus(at: destination, followSymbolicLinks: false) != nil {
            throw CoworkArtifactTransactionError.targetAlreadyExists(
                destination.lastPathComponent
            )
        }

        let temporary = parent.appendingPathComponent(
            ".straight-up-cowork-\(UUID().uuidString).tmp"
        )
        #if canImport(Darwin)
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else {
            if errno == ENOSPC { throw CoworkArtifactTransactionError.insufficientDiskSpace }
            throw CoworkArtifactTransactionError.persistenceFailure
        }
        var closeRequired = true
        defer {
            if closeRequired { Darwin.close(descriptor) }
            try? FileManager.default.removeItem(at: temporary)
        }
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var written = 0
                while written < rawBuffer.count {
                    let count = Darwin.write(
                        descriptor,
                        base.advanced(by: written),
                        rawBuffer.count - written
                    )
                    if count < 0 {
                        if errno == EINTR { continue }
                        if errno == ENOSPC {
                            throw CoworkArtifactTransactionError.insufficientDiskSpace
                        }
                        throw CoworkArtifactTransactionError.persistenceFailure
                    }
                    written += count
                }
            }
            guard Darwin.fsync(descriptor) == 0 else {
                if errno == ENOSPC {
                    throw CoworkArtifactTransactionError.insufficientDiskSpace
                }
                throw CoworkArtifactTransactionError.persistenceFailure
            }
            guard Darwin.close(descriptor) == 0 else {
                throw CoworkArtifactTransactionError.persistenceFailure
            }
            closeRequired = false
            if !replaceExisting,
               try optionalStatus(at: destination, followSymbolicLinks: false) != nil {
                throw CoworkArtifactTransactionError.targetAlreadyExists(
                    destination.lastPathComponent
                )
            }
            let renameResult = temporary.path.withCString { source in
                destination.path.withCString { target in
                    if replaceExisting {
                        Darwin.rename(source, target)
                    } else {
                        Darwin.renameatx_np(
                            AT_FDCWD,
                            source,
                            AT_FDCWD,
                            target,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
            }
            guard renameResult == 0 else {
                if errno == ENOSPC {
                    throw CoworkArtifactTransactionError.insufficientDiskSpace
                }
                if errno == EXDEV {
                    throw CoworkArtifactTransactionError.crossVolumeRejected(
                        destination.lastPathComponent
                    )
                }
                if errno == EEXIST {
                    throw CoworkArtifactTransactionError.targetAlreadyExists(
                        destination.lastPathComponent
                    )
                }
                throw CoworkArtifactTransactionError.persistenceFailure
            }
            try protectFile(destination)
            try synchronizeDirectory(parent)
        } catch {
            throw error
        }
        #else
        do {
            try data.write(to: temporary, options: [])
            if replaceExisting, FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            try protectFile(destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw CoworkArtifactTransactionError.persistenceFailure
        }
        #endif
    }

    static func atomicRename(
        from source: URL,
        to destination: URL,
        replaceExisting: Bool
    ) throws {
        if !replaceExisting,
           try optionalStatus(at: destination, followSymbolicLinks: false) != nil {
            throw CoworkArtifactTransactionError.filenameCollision(
                destination.lastPathComponent
            )
        }
        #if canImport(Darwin)
        let result = source.path.withCString { sourcePointer in
            destination.path.withCString { destinationPointer in
                if replaceExisting {
                    Darwin.rename(sourcePointer, destinationPointer)
                } else {
                    Darwin.renameatx_np(
                        AT_FDCWD,
                        sourcePointer,
                        AT_FDCWD,
                        destinationPointer,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
        }
        guard result == 0 else {
            if errno == EXDEV {
                throw CoworkArtifactTransactionError.crossVolumeRejected(
                    destination.lastPathComponent
                )
            }
            if errno == ENOSPC { throw CoworkArtifactTransactionError.insufficientDiskSpace }
            if errno == EEXIST {
                throw CoworkArtifactTransactionError.filenameCollision(
                    destination.lastPathComponent
                )
            }
            throw CoworkArtifactTransactionError.persistenceFailure
        }
        try synchronizeDirectory(source.deletingLastPathComponent())
        if source.deletingLastPathComponent() != destination.deletingLastPathComponent() {
            try synchronizeDirectory(destination.deletingLastPathComponent())
        }
        #else
        do {
            if replaceExisting, FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
            } else {
                try FileManager.default.moveItem(at: source, to: destination)
            }
        } catch {
            throw CoworkArtifactTransactionError.persistenceFailure
        }
        #endif
    }

    static func atomicUnlink(_ url: URL) throws {
        #if canImport(Darwin)
        let result = url.path.withCString { Darwin.unlink($0) }
        guard result == 0 else {
            throw CoworkArtifactTransactionError.persistenceFailure
        }
        try synchronizeDirectory(url.deletingLastPathComponent())
        #else
        do { try FileManager.default.removeItem(at: url) }
        catch { throw CoworkArtifactTransactionError.persistenceFailure }
        #endif
    }

    static func protectFile(_ url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        do {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        } catch {
            throw CoworkArtifactTransactionError.persistenceFailure
        }
    }

    static func synchronizeDirectory(_ url: URL) throws {
        #if canImport(Darwin)
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else {
            throw CoworkArtifactTransactionError.persistenceFailure
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw CoworkArtifactTransactionError.persistenceFailure
        }
        #endif
    }

    static func rejectFilenameCollision(
        in directory: URL,
        requestedName: String
    ) throws {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw CoworkArtifactTransactionError.persistenceFailure
        }
        let folded = requestedName.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        if let collision = names.first(where: { existing in
            existing != requestedName
                && existing.precomposedStringWithCanonicalMapping.folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                ) == folded
        }) {
            throw CoworkArtifactTransactionError.filenameCollision(collision)
        }
    }

    static func isAliasFile(_ url: URL) throws -> Bool {
        do {
            return try url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile ?? false
        } catch {
            // lstat succeeded but resource metadata failed: do not weaken the
            // containment decision by assuming an opaque file is safe.
            throw CoworkArtifactTransactionError.persistenceFailure
        }
    }

    static func isContained(_ candidate: URL, beneath root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}

private nonisolated enum CoworkArtifactCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private nonisolated func coworkSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}


private nonisolated struct CoworkLoadedWorkspace: Sendable {
    let records: [UUID: CoworkArtifactTransactionRecord]
    let manifest: CoworkArtifactManifest
}

private extension CoworkArtifactTransactionWorkspace {
    nonisolated static func loadWorkspace(
        transactionsURL: URL,
        manifestURL: URL,
        expectedRunID: UUID,
        limits: CoworkArtifactTransactionLimits
    ) throws -> CoworkLoadedWorkspace {
        let fileManager = FileManager.default
        let recordURLs: [URL]
        do {
            recordURLs = try fileManager.contentsOfDirectory(
                at: transactionsURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
        } catch {
            throw CoworkArtifactTransactionError.persistenceFailure
        }
        guard recordURLs.count <= limits.maximumManifestEntries
                + limits.maximumPendingTransactions
        else {
            throw CoworkArtifactTransactionError.corruptWorkspace
        }

        var records: [UUID: CoworkArtifactTransactionRecord] = [:]
        for url in recordURLs {
            let maximumRecordBytes = limits.maximumDiffUTF8Bytes + 64 * 1_024
            let data = try CoworkFileSystem.readBoundedData(
                at: url,
                maximumBytes: maximumRecordBytes
            )
            let record: CoworkArtifactTransactionRecord
            do {
                record = try CoworkArtifactCoding.decoder().decode(
                    CoworkArtifactTransactionRecord.self,
                    from: data
                )
            } catch {
                throw CoworkArtifactTransactionError.corruptWorkspace
            }
            try validateLoadedRecord(
                record,
                expectedRunID: expectedRunID,
                limits: limits
            )
            guard url.lastPathComponent == "\(record.transactionID.uuidString).json",
                  records.updateValue(record, forKey: record.transactionID) == nil
            else {
                throw CoworkArtifactTransactionError.corruptWorkspace
            }
        }

        let manifest: CoworkArtifactManifest
        if fileManager.fileExists(atPath: manifestURL.path) {
            let data = try CoworkFileSystem.readBoundedData(
                at: manifestURL,
                maximumBytes: max(64 * 1_024, limits.maximumManifestEntries * 2_048)
            )
            do {
                manifest = try CoworkArtifactCoding.decoder().decode(
                    CoworkArtifactManifest.self,
                    from: data
                )
            } catch {
                throw CoworkArtifactTransactionError.corruptWorkspace
            }
            guard manifest.schemaVersion == CoworkArtifactManifest.schemaVersion,
                  manifest.runID == expectedRunID,
                  manifest.artifacts.count <= limits.maximumManifestEntries,
                  Set(manifest.artifacts.map(\.transactionID)).count
                    == manifest.artifacts.count,
                  manifest.artifacts.allSatisfy({ result in
                      result.schemaVersion == CoworkArtifactResult.schemaVersion
                          && result.runID == expectedRunID
                          && result.sha256.count == 64
                  })
            else {
                throw CoworkArtifactTransactionError.corruptWorkspace
            }
        } else {
            manifest = CoworkArtifactManifest(runID: expectedRunID)
        }
        return CoworkLoadedWorkspace(records: records, manifest: manifest)
    }

    nonisolated static func validateLoadedRecord(
        _ record: CoworkArtifactTransactionRecord,
        expectedRunID: UUID,
        limits: CoworkArtifactTransactionLimits
    ) throws {
        guard record.schemaVersion == CoworkArtifactTransactionRecord.schemaVersion,
              record.runID == expectedRunID,
              record.preview.schemaVersion == CoworkArtifactPreview.schemaVersion,
              record.preview.transactionID == record.transactionID,
              record.preview.artifactID == record.artifactID,
              record.preview.runID == record.runID,
              record.preview.commitState == .staged,
              record.preview.sourceStepIDs.count > 0,
              record.preview.sourceStepIDs.count <= limits.maximumSourceSteps,
              Set(record.preview.sourceStepIDs).count
                == record.preview.sourceStepIDs.count,
              record.descriptor.priorFilename
                == "\(record.transactionID.uuidString).prior",
              (record.descriptor.stagedFilename.map {
                  $0 == "\(record.transactionID.uuidString).data"
              } ?? true)
        else {
            throw CoworkArtifactTransactionError.corruptWorkspace
        }
        _ = try CoworkFileSystem.validateRelativePath(
            record.descriptor.destinationRelativePath,
            maximumBytes: limits.maximumPathUTF8Bytes,
            maximumDepth: limits.maximumPathDepth
        )
        if let source = record.descriptor.sourceRelativePath {
            _ = try CoworkFileSystem.validateRelativePath(
                source,
                maximumBytes: limits.maximumPathUTF8Bytes,
                maximumDepth: limits.maximumPathDepth
            )
        }
        let expectedDigest = try previewDigest(record.preview)
        guard expectedDigest == record.preview.previewDigest else {
            throw CoworkArtifactTransactionError.corruptWorkspace
        }
    }

    nonisolated static func previewDigest(
        _ preview: CoworkArtifactPreview
    ) throws -> String {
        let input = CoworkArtifactPreviewDigestInput(
            transactionID: preview.transactionID,
            artifactID: preview.artifactID,
            runID: preview.runID,
            operationKind: preview.operationKind,
            risk: preview.risk,
            contentType: preview.contentType,
            sourceStepIDs: preview.sourceStepIDs,
            finalRelativePath: preview.finalRelativePath,
            invocation: preview.invocation,
            metadata: preview.metadata,
            textDiff: preview.textDiff,
            stagedAt: preview.stagedAt
        )
        return coworkSHA256(try CoworkArtifactCoding.encoder().encode(input))
    }

    nonisolated static func persistRecord(
        _ record: CoworkArtifactTransactionRecord,
        in directory: URL
    ) throws {
        let data: Data
        do {
            data = try CoworkArtifactCoding.encoder().encode(record)
        } catch {
            throw CoworkArtifactTransactionError.persistenceFailure
        }
        guard data.count <= 2 * 1_024 * 1_024 else {
            throw CoworkArtifactTransactionError.persistenceFailure
        }
        try CoworkFileSystem.atomicWrite(
            data,
            to: recordURL(record.transactionID, in: directory),
            replaceExisting: true
        )
    }

    nonisolated static func recordURL(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    nonisolated static func persistManifest(
        _ manifest: CoworkArtifactManifest,
        to url: URL
    ) throws {
        let data: Data
        do {
            data = try CoworkArtifactCoding.encoder().encode(manifest)
        } catch {
            throw CoworkArtifactTransactionError.persistenceFailure
        }
        try CoworkFileSystem.atomicWrite(data, to: url, replaceExisting: true)
    }
}


extension CoworkArtifactTransactionWorkspace {
    func recoverInterruptedTransactions(
        at date: Date = Date()
    ) async throws -> [CoworkArtifactRecoveryResult] {
        try Task.checkCancellation()
        try validateRootIdentity()
        var outcomes: [CoworkArtifactRecoveryResult] = []
        var manifest = currentManifest

        for transactionID in records.keys.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            try Task.checkCancellation()
            guard var record = records[transactionID] else { continue }

            if record.state == .committed || record.state == .rolledBack {
                if let result = record.result,
                   !manifest.artifacts.contains(where: {
                       $0.transactionID == transactionID
                   }) {
                    manifest.artifacts.append(result)
                }
                continue
            }
            guard record.state == .committing else { continue }

            let disposition: CoworkArtifactRecoveryDisposition
            do {
                if try mutationCompleted(record) {
                    let result = makeCommittedResult(for: record, at: date)
                    _ = try result.boundedModelResult(
                        maximumBytes: limits.maximumModelResultBytes
                    )
                    record.state = .committed
                    record.result = result
                    record.failureCode = nil
                    manifest.artifacts.removeAll {
                        $0.transactionID == transactionID
                    }
                    manifest.artifacts.append(result)
                    disposition = .finalizedCommitted
                    outcomes.append(CoworkArtifactRecoveryResult(
                        transactionID: transactionID,
                        disposition: disposition,
                        result: result
                    ))
                } else if try originalStateStillPresent(record) {
                    record.state = .staged
                    record.result = nil
                    record.failureCode = "interrupted-before-atomic-mutation"
                    disposition = .readyToRetry
                    outcomes.append(CoworkArtifactRecoveryResult(
                        transactionID: transactionID,
                        disposition: disposition,
                        result: nil
                    ))
                } else {
                    record.state = .failed
                    record.result = nil
                    record.failureCode = "ambiguous-target-state"
                    disposition = .failedClosed
                    outcomes.append(CoworkArtifactRecoveryResult(
                        transactionID: transactionID,
                        disposition: disposition,
                        result: nil
                    ))
                }
            } catch {
                record.state = .failed
                record.result = nil
                record.failureCode = "unsafe-recovery-target"
                outcomes.append(CoworkArtifactRecoveryResult(
                    transactionID: transactionID,
                    disposition: .failedClosed,
                    result: nil
                ))
            }
            try Self.persistRecord(record, in: transactionsURL)
            records[transactionID] = record
        }

        manifest.artifacts.sort(by: Self.manifestBefore)
        manifest.updatedAt = date
        try Self.persistManifest(manifest, to: manifestURL)
        currentManifest = manifest
        _ = try? prunePriorVersions(at: date)
        return outcomes
    }

    @discardableResult
    func expirePriorVersions(at date: Date = Date()) async throws -> Int {
        try Task.checkCancellation()
        return try prunePriorVersions(at: date)
    }

    func cancel(transactionID: UUID) async throws {
        try Task.checkCancellation()
        guard let record = records[transactionID] else {
            throw CoworkArtifactTransactionError.unknownTransaction(transactionID)
        }
        guard record.state == .staged else {
            throw CoworkArtifactTransactionError.transactionNotStaged(transactionID)
        }
        if let filename = record.descriptor.stagedFilename {
            try? FileManager.default.removeItem(
                at: stagedURL.appendingPathComponent(filename)
            )
        }
        try FileManager.default.removeItem(
            at: Self.recordURL(transactionID, in: transactionsURL)
        )
        records.removeValue(forKey: transactionID)
    }
}

private nonisolated enum CoworkRecoveryProbe: Sendable {
    case missing
    case file(CoworkArtifactFileSnapshot)
}

private extension CoworkArtifactTransactionWorkspace {
    func mutationCompleted(_ record: CoworkArtifactTransactionRecord) throws -> Bool {
        switch record.descriptor.kind {
        case .create, .replace, .append:
            let probe = try probe(record.descriptor.destinationRelativePath)
            guard case .file(let snapshot) = probe else { return false }
            return snapshot.sha256 == record.preview.metadata.proposedSHA256
                && snapshot.byteCount == record.preview.metadata.proposedByteCount

        case .move:
            guard let sourcePath = record.descriptor.sourceRelativePath else {
                throw CoworkArtifactTransactionError.corruptWorkspace
            }
            guard case .missing = try probe(sourcePath),
                  case .file(let destination) = try probe(
                      record.descriptor.destinationRelativePath
                  )
            else { return false }
            return destination.sha256 == record.sourceSnapshot?.sha256
                && destination.byteCount == record.sourceSnapshot?.byteCount

        case .recoverableDelete:
            guard case .missing = try probe(
                record.descriptor.destinationRelativePath
            ) else { return false }
            let prior = priorURL.appendingPathComponent(record.descriptor.priorFilename)
            guard FileManager.default.fileExists(atPath: prior.path) else { return false }
            let bytes = try CoworkFileSystem.readBoundedData(
                at: prior,
                maximumBytes: limits.maximumArtifactBytes
            )
            return coworkSHA256(bytes) == record.sourceSnapshot?.sha256
        }
    }

    func originalStateStillPresent(
        _ record: CoworkArtifactTransactionRecord
    ) throws -> Bool {
        switch record.descriptor.kind {
        case .create:
            if case .missing = try probe(record.descriptor.destinationRelativePath) {
                return true
            }
            return false
        case .replace, .append:
            guard case .file(let snapshot) = try probe(
                record.descriptor.destinationRelativePath
            ) else { return false }
            return snapshot == record.destinationSnapshot
        case .move:
            guard let sourcePath = record.descriptor.sourceRelativePath,
                  case .file(let source) = try probe(sourcePath),
                  case .missing = try probe(record.descriptor.destinationRelativePath)
            else { return false }
            return source == record.sourceSnapshot
        case .recoverableDelete:
            guard case .file(let source) = try probe(
                record.descriptor.destinationRelativePath
            ) else { return false }
            return source == record.sourceSnapshot
        }
    }

    func probe(_ relativePath: String) throws -> CoworkRecoveryProbe {
        let normalized = try CoworkFileSystem.validateRelativePath(
            relativePath,
            maximumBytes: limits.maximumPathUTF8Bytes,
            maximumDepth: limits.maximumPathDepth
        )
        let lexical = rootURL.appendingPathComponent(normalized)
        if !FileManager.default.fileExists(atPath: lexical.path) {
            _ = try resolve(
                normalized,
                requirement: .mustNotExist,
                loadData: false
            )
            return .missing
        }
        let resolved = try resolve(
            normalized,
            requirement: .mustExist,
            loadData: true
        )
        guard let snapshot = resolved.snapshot else {
            throw CoworkArtifactTransactionError.corruptWorkspace
        }
        return .file(snapshot)
    }

    @discardableResult
    func prunePriorVersions(at date: Date) throws -> Int {
        var candidates = records.values.filter {
            $0.state == .committed && $0.result?.rollbackAvailableUntil != nil
        }
        var expireIDs: Set<UUID> = Set(candidates.compactMap { record in
            guard let expiry = record.result?.rollbackAvailableUntil,
                  expiry <= date
            else { return nil }
            return record.transactionID
        })

        let grouped = Dictionary(grouping: candidates) {
            $0.descriptor.destinationRelativePath
        }
        for group in grouped.values {
            let newestFirst = group.sorted {
                let lhs = $0.result?.committedAt ?? .distantPast
                let rhs = $1.result?.committedAt ?? .distantPast
                if lhs != rhs { return lhs > rhs }
                return $0.transactionID.uuidString > $1.transactionID.uuidString
            }
            for record in newestFirst.dropFirst(limits.maximumPriorVersionsPerPath) {
                expireIDs.insert(record.transactionID)
            }
        }

        guard !expireIDs.isEmpty else { return 0 }
        var manifest = currentManifest
        for id in expireIDs {
            guard var record = records[id], let result = record.result else { continue }
            let prior = priorURL.appendingPathComponent(record.descriptor.priorFilename)
            if FileManager.default.fileExists(atPath: prior.path) {
                try FileManager.default.removeItem(at: prior)
            }
            let expired = Self.copy(result, rollbackAvailableUntil: nil)
            record.result = expired
            try Self.persistRecord(record, in: transactionsURL)
            records[id] = record
            if let index = manifest.artifacts.firstIndex(where: {
                $0.transactionID == id
            }) {
                manifest.artifacts[index] = expired
            }
        }
        manifest.updatedAt = date
        try Self.persistManifest(manifest, to: manifestURL)
        currentManifest = manifest
        candidates.removeAll()
        return expireIDs.count
    }

    nonisolated static func copy(
        _ result: CoworkArtifactResult,
        rollbackAvailableUntil: Date?
    ) -> CoworkArtifactResult {
        CoworkArtifactResult(
            transactionID: result.transactionID,
            artifactID: result.artifactID,
            runID: result.runID,
            operationKind: result.operationKind,
            contentType: result.contentType,
            byteCount: result.byteCount,
            sha256: result.sha256,
            sourceStepIDs: result.sourceStepIDs,
            finalRelativePath: result.finalRelativePath,
            sourceRelativePath: result.sourceRelativePath,
            commitState: result.commitState,
            existsAfterCommit: result.existsAfterCommit,
            committedAt: result.committedAt,
            rollbackAvailableUntil: rollbackAvailableUntil,
            invocation: result.invocation,
            previewDigest: result.previewDigest
        )
    }
}


extension CoworkArtifactTransactionWorkspace {
    func commit(
        transactionID: UUID,
        authorization: CoworkArtifactCommitAuthorization? = nil,
        at date: Date = Date()
    ) async throws -> CoworkArtifactResult {
        try Task.checkCancellation()
        try validateRootIdentity()
        guard var record = records[transactionID] else {
            throw CoworkArtifactTransactionError.unknownTransaction(transactionID)
        }
        switch record.state {
        case .staged:
            break
        case .committing:
            throw CoworkArtifactTransactionError.recoveryRequired(transactionID)
        case .committed, .rolledBack, .failed:
            throw CoworkArtifactTransactionError.transactionNotStaged(transactionID)
        }
        if record.preview.requiresApproval {
            guard let authorization else {
                throw CoworkArtifactTransactionError.approvalRequired(transactionID)
            }
            try Self.validate(
                authorization: authorization,
                for: record.preview,
                at: date
            )
        } else if let authorization {
            try Self.validate(
                authorization: authorization,
                for: record.preview,
                at: date
            )
        }
        guard currentManifest.artifacts.count < limits.maximumManifestEntries else {
            throw CoworkArtifactTransactionError.manifestLimitExceeded(
                maximum: limits.maximumManifestEntries
            )
        }

        try validateUnchanged(record)
        let stagedData: Data?
        if let filename = record.descriptor.stagedFilename {
            stagedData = try CoworkFileSystem.readBoundedData(
                at: stagedURL.appendingPathComponent(filename),
                maximumBytes: limits.maximumArtifactBytes
            )
            guard coworkSHA256(stagedData ?? Data())
                    == record.preview.metadata.proposedSHA256
            else {
                throw CoworkArtifactTransactionError.corruptWorkspace
            }
        } else {
            stagedData = nil
        }

        let predicted = makeCommittedResult(for: record, at: date)
        _ = try predicted.boundedModelResult(
            maximumBytes: limits.maximumModelResultBytes
        )
        let requiredBytes = (stagedData?.count ?? 0)
            + (record.preview.metadata.priorByteCount ?? 0)
        try ensureDiskCapacity(forAdditionalBytes: requiredBytes)

        record.state = .committing
        try Self.persistRecord(record, in: transactionsURL)
        records[transactionID] = record
        try hooks.checkpoint(.afterCommittingRecord)

        let prior = priorURL.appendingPathComponent(record.descriptor.priorFilename)
        switch record.descriptor.kind {
        case .replace, .append:
            let destination = try resolve(
                record.descriptor.destinationRelativePath,
                requirement: .mustExist,
                loadData: true
            )
            let bytes = try Self.requireData(destination)
            try CoworkFileSystem.atomicWrite(
                bytes,
                to: prior,
                replaceExisting: true
            )
            try hooks.checkpoint(.afterPriorVersion)
        case .create, .move, .recoverableDelete:
            break
        }

        try Task.checkCancellation()
        try applyMutation(record, stagedData: stagedData, priorURL: prior)
        try hooks.checkpoint(.afterAtomicMutation)

        let result = makeCommittedResult(for: record, at: date)
        try hooks.checkpoint(.beforeManifestPersistence)
        record.state = .committed
        record.result = result
        record.failureCode = nil
        try Self.persistRecord(record, in: transactionsURL)

        var manifest = currentManifest
        manifest.artifacts.removeAll { $0.transactionID == transactionID }
        manifest.artifacts.append(result)
        manifest.artifacts.sort(by: Self.manifestBefore)
        manifest.updatedAt = date
        try Self.persistManifest(manifest, to: manifestURL)
        records[transactionID] = record
        currentManifest = manifest

        if let filename = record.descriptor.stagedFilename {
            try? FileManager.default.removeItem(
                at: stagedURL.appendingPathComponent(filename)
            )
        }
        _ = try? prunePriorVersions(at: date)
        return result
    }

    @discardableResult
    func rollback(
        transactionID: UUID,
        at date: Date = Date()
    ) async throws -> CoworkArtifactResult {
        try Task.checkCancellation()
        try validateRootIdentity()
        guard var record = records[transactionID],
              record.state == .committed,
              let committed = record.result
        else {
            throw CoworkArtifactTransactionError.rollbackUnavailable(transactionID)
        }
        guard let availableUntil = committed.rollbackAvailableUntil,
              availableUntil > date
        else {
            throw CoworkArtifactTransactionError.rollbackUnavailable(transactionID)
        }

        let destinationPath = record.descriptor.destinationRelativePath
        let prior = priorURL.appendingPathComponent(record.descriptor.priorFilename)
        let rolledBackPath: String
        let restoredData: Data
        let existsAfterRollback: Bool

        switch record.descriptor.kind {
        case .create:
            let destination = try resolve(
                destinationPath,
                requirement: .mustExist,
                loadData: true
            )
            try Self.requireCommittedDigest(destination, result: committed)
            try Task.checkCancellation()
            try CoworkFileSystem.atomicUnlink(destination.url)
            rolledBackPath = destinationPath
            restoredData = Data()
            existsAfterRollback = false

        case .replace, .append:
            let destination = try resolve(
                destinationPath,
                requirement: .mustExist,
                loadData: true
            )
            try Self.requireCommittedDigest(destination, result: committed)
            let priorData = try CoworkFileSystem.readBoundedData(
                at: prior,
                maximumBytes: limits.maximumArtifactBytes
            )
            try Task.checkCancellation()
            try CoworkFileSystem.atomicWrite(
                priorData,
                to: destination.url,
                replaceExisting: true
            )
            rolledBackPath = destinationPath
            restoredData = priorData
            existsAfterRollback = true

        case .move:
            guard let sourcePath = record.descriptor.sourceRelativePath else {
                throw CoworkArtifactTransactionError.corruptWorkspace
            }
            let destination = try resolve(
                destinationPath,
                requirement: .mustExist,
                loadData: true
            )
            try Self.requireCommittedDigest(destination, result: committed)
            _ = try resolve(
                sourcePath,
                requirement: .mustNotExist,
                loadData: false
            )
            try CoworkFileSystem.createDestinationParents(
                for: sourcePath,
                beneath: rootURL,
                rootIdentity: expectedRootIdentity,
                maximumDepth: limits.maximumPathDepth
            )
            try Task.checkCancellation()
            try CoworkFileSystem.atomicRename(
                from: destination.url,
                to: rootURL.appendingPathComponent(sourcePath),
                replaceExisting: false
            )
            rolledBackPath = sourcePath
            restoredData = try Self.requireData(destination)
            existsAfterRollback = true

        case .recoverableDelete:
            _ = try resolve(
                destinationPath,
                requirement: .mustNotExist,
                loadData: false
            )
            let priorData = try CoworkFileSystem.readBoundedData(
                at: prior,
                maximumBytes: limits.maximumArtifactBytes
            )
            try CoworkFileSystem.createDestinationParents(
                for: destinationPath,
                beneath: rootURL,
                rootIdentity: expectedRootIdentity,
                maximumDepth: limits.maximumPathDepth
            )
            try Task.checkCancellation()
            try CoworkFileSystem.atomicRename(
                from: prior,
                to: rootURL.appendingPathComponent(destinationPath),
                replaceExisting: false
            )
            rolledBackPath = destinationPath
            restoredData = priorData
            existsAfterRollback = true
        }

        let rolledBack = CoworkArtifactResult(
            transactionID: record.transactionID,
            artifactID: record.artifactID,
            runID: record.runID,
            operationKind: record.descriptor.kind,
            contentType: record.descriptor.contentType,
            byteCount: restoredData.count,
            sha256: coworkSHA256(restoredData),
            sourceStepIDs: record.preview.sourceStepIDs,
            finalRelativePath: rolledBackPath,
            sourceRelativePath: record.descriptor.sourceRelativePath,
            commitState: .rolledBack,
            existsAfterCommit: existsAfterRollback,
            committedAt: date,
            rollbackAvailableUntil: nil,
            invocation: record.preview.invocation,
            previewDigest: record.preview.previewDigest
        )
        record.state = .rolledBack
        record.result = rolledBack
        try Self.persistRecord(record, in: transactionsURL)
        var manifest = currentManifest
        manifest.artifacts.removeAll { $0.transactionID == transactionID }
        manifest.artifacts.append(rolledBack)
        manifest.artifacts.sort(by: Self.manifestBefore)
        manifest.updatedAt = date
        try Self.persistManifest(manifest, to: manifestURL)
        records[transactionID] = record
        currentManifest = manifest

        if FileManager.default.fileExists(atPath: prior.path) {
            try? FileManager.default.removeItem(at: prior)
        }
        return rolledBack
    }
}

private extension CoworkArtifactTransactionWorkspace {
    func applyMutation(
        _ record: CoworkArtifactTransactionRecord,
        stagedData: Data?,
        priorURL: URL
    ) throws {
        let destinationPath = record.descriptor.destinationRelativePath
        switch record.descriptor.kind {
        case .create, .replace, .append:
            guard let stagedData else {
                throw CoworkArtifactTransactionError.corruptWorkspace
            }
            try CoworkFileSystem.createDestinationParents(
                for: destinationPath,
                beneath: rootURL,
                rootIdentity: expectedRootIdentity,
                maximumDepth: limits.maximumPathDepth
            )
            // Resolve again after creating parents; a racing symlink or name
            // collision must fail before the atomic destination rename.
            _ = try resolve(
                destinationPath,
                requirement: record.descriptor.kind == .create
                    ? .mustNotExist
                    : .mustExist,
                loadData: false
            )
            try hooks.checkpoint(.beforeAtomicMutation)
            try CoworkFileSystem.atomicWrite(
                stagedData,
                to: rootURL.appendingPathComponent(destinationPath),
                replaceExisting: record.descriptor.kind != .create
            )

        case .move:
            guard let sourcePath = record.descriptor.sourceRelativePath else {
                throw CoworkArtifactTransactionError.corruptWorkspace
            }
            try CoworkFileSystem.createDestinationParents(
                for: destinationPath,
                beneath: rootURL,
                rootIdentity: expectedRootIdentity,
                maximumDepth: limits.maximumPathDepth
            )
            let source = try resolve(
                sourcePath,
                requirement: .mustExist,
                loadData: false
            )
            _ = try resolve(
                destinationPath,
                requirement: .mustNotExist,
                loadData: false
            )
            try hooks.checkpoint(.beforeAtomicMutation)
            try CoworkFileSystem.atomicRename(
                from: source.url,
                to: rootURL.appendingPathComponent(destinationPath),
                replaceExisting: false
            )

        case .recoverableDelete:
            let source = try resolve(
                destinationPath,
                requirement: .mustExist,
                loadData: false
            )
            guard !FileManager.default.fileExists(atPath: priorURL.path) else {
                throw CoworkArtifactTransactionError.filenameCollision(
                    record.descriptor.priorFilename
                )
            }
            try hooks.checkpoint(.beforeAtomicMutation)
            try CoworkFileSystem.atomicRename(
                from: source.url,
                to: priorURL,
                replaceExisting: false
            )
        }
    }

    func validateUnchanged(_ record: CoworkArtifactTransactionRecord) throws {
        try CoworkFileSystem.validate(
            anchor: record.destinationAnchor,
            beneath: rootURL,
            rootIdentity: expectedRootIdentity
        )
        switch record.descriptor.kind {
        case .create:
            _ = try resolve(
                record.descriptor.destinationRelativePath,
                requirement: .mustNotExist,
                loadData: false
            )
        case .replace, .append:
            let current = try resolve(
                record.descriptor.destinationRelativePath,
                requirement: .mustExist,
                loadData: true
            )
            try Self.requireSnapshot(
                current.snapshot,
                equals: record.destinationSnapshot,
                path: current.relativePath
            )
        case .move:
            guard let sourcePath = record.descriptor.sourceRelativePath else {
                throw CoworkArtifactTransactionError.corruptWorkspace
            }
            let source = try resolve(
                sourcePath,
                requirement: .mustExist,
                loadData: true
            )
            try Self.requireSnapshot(
                source.snapshot,
                equals: record.sourceSnapshot,
                path: source.relativePath
            )
            _ = try resolve(
                record.descriptor.destinationRelativePath,
                requirement: .mustNotExist,
                loadData: false
            )
        case .recoverableDelete:
            let source = try resolve(
                record.descriptor.destinationRelativePath,
                requirement: .mustExist,
                loadData: true
            )
            try Self.requireSnapshot(
                source.snapshot,
                equals: record.sourceSnapshot,
                path: source.relativePath
            )
        }
    }

    func makeCommittedResult(
        for record: CoworkArtifactTransactionRecord,
        at date: Date
    ) -> CoworkArtifactResult {
        let digest: String
        let bytes: Int
        let exists: Bool
        switch record.descriptor.kind {
        case .recoverableDelete:
            digest = record.sourceSnapshot?.sha256
                ?? record.destinationSnapshot?.sha256
                ?? coworkSHA256(Data())
            bytes = record.sourceSnapshot?.byteCount
                ?? record.destinationSnapshot?.byteCount
                ?? 0
            exists = false
        case .move:
            digest = record.sourceSnapshot?.sha256
                ?? record.preview.metadata.proposedSHA256
            bytes = record.sourceSnapshot?.byteCount
                ?? record.preview.metadata.proposedByteCount
            exists = true
        case .create, .replace, .append:
            digest = record.preview.metadata.proposedSHA256
            bytes = record.preview.metadata.proposedByteCount
            exists = true
        }
        return CoworkArtifactResult(
            transactionID: record.transactionID,
            artifactID: record.artifactID,
            runID: record.runID,
            operationKind: record.descriptor.kind,
            contentType: record.descriptor.contentType,
            byteCount: bytes,
            sha256: digest,
            sourceStepIDs: record.preview.sourceStepIDs,
            finalRelativePath: record.descriptor.destinationRelativePath,
            sourceRelativePath: record.descriptor.sourceRelativePath,
            commitState: .committed,
            existsAfterCommit: exists,
            committedAt: date,
            rollbackAvailableUntil: date.addingTimeInterval(
                limits.priorVersionRetention
            ),
            invocation: record.preview.invocation,
            previewDigest: record.preview.previewDigest
        )
    }

    nonisolated static func validate(
        authorization: CoworkArtifactCommitAuthorization,
        for preview: CoworkArtifactPreview,
        at date: Date
    ) throws {
        guard authorization.transactionID == preview.transactionID,
              authorization.runID == preview.runID,
              authorization.previewDigest == preview.previewDigest,
              authorization.invocationDigest == preview.invocation.invocationDigest
        else {
            throw CoworkArtifactTransactionError.invalidApproval
        }
        guard authorization.approvedAt <= date, authorization.expiresAt > date else {
            throw CoworkArtifactTransactionError.expiredApproval
        }
    }

    nonisolated static func requireSnapshot(
        _ actual: CoworkArtifactFileSnapshot?,
        equals expected: CoworkArtifactFileSnapshot?,
        path: String
    ) throws {
        guard actual == expected else {
            throw CoworkArtifactTransactionError.targetChanged(path)
        }
    }

    nonisolated static func requireCommittedDigest(
        _ current: CoworkResolvedPath,
        result: CoworkArtifactResult
    ) throws {
        guard current.snapshot?.sha256 == result.sha256,
              current.snapshot?.byteCount == result.byteCount
        else {
            throw CoworkArtifactTransactionError.targetChanged(
                current.relativePath
            )
        }
    }

    nonisolated static func manifestBefore(
        _ lhs: CoworkArtifactResult,
        _ rhs: CoworkArtifactResult
    ) -> Bool {
        if lhs.committedAt != rhs.committedAt { return lhs.committedAt < rhs.committedAt }
        return lhs.transactionID.uuidString < rhs.transactionID.uuidString
    }
}
