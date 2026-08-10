import Foundation

#if canImport(Darwin)
import Darwin
#endif

nonisolated struct AgentLegacyMigrationSummary: Equatable, Sendable {
    var inserted = 0
    var alreadyImported = 0
    var repaired = 0
    var failed = 0
}

nonisolated struct AgentLegacySourceRetirementReport: Equatable, Sendable {
    let deletedConversationEntries: Int
    let deletedAuditEntries: Int
    let deletedSchedulerSource: Bool

    var deletedSourceCount: Int {
        deletedConversationEntries
            + deletedAuditEntries
            + (deletedSchedulerSource ? 1 : 0)
    }
}

nonisolated enum AgentLegacySourceRetirementError: LocalizedError, Equatable {
    case unsafeBaseDirectory
    case unsafeSource(String)
    case sourceStillPresent(String)

    var errorDescription: String? {
        switch self {
        case .unsafeBaseDirectory:
            "The browser support directory could not be validated for history deletion."
        case .unsafeSource(let name):
            "The legacy agent-history source \(name) is not safely contained."
        case .sourceStillPresent(let name):
            "The legacy agent-history source \(name) could not be fully deleted."
        }
    }
}

/// Discovers only the three known legacy locations. Source files remain in
/// place until the user chooses a retention/deletion action.
nonisolated enum AgentLegacyMigrationCoordinator {
    static func migrate(
        baseDirectory: URL,
        into store: AgentRunStore,
        importer: LegacyAgentImporter = LegacyAgentImporter()
    ) async -> AgentLegacyMigrationSummary {
        var summary = AgentLegacyMigrationSummary()
        let manager = FileManager.default

        let conversations = baseDirectory.appendingPathComponent(
            "agent-conversations",
            isDirectory: true
        )
        if let files = try? manager.contentsOfDirectory(
            at: conversations,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for file in files.filter({ $0.pathExtension.lowercased() == "json" })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                do {
                    let data = try boundedRegularFile(file)
                    let bundle = try importer.parseConversation(data, sourceName: file.lastPathComponent)
                    record(try await store.importLegacyBundle(bundle), in: &summary)
                } catch {
                    summary.failed += 1
                }
            }
        }

        let tasks = baseDirectory.appendingPathComponent("agent-tasks.json")
        if manager.fileExists(atPath: tasks.path) {
            do {
                let data = try boundedRegularFile(tasks)
                let bundle = try importer.parseScheduler(data, sourceName: tasks.lastPathComponent)
                record(try await store.importLegacyBundle(bundle), in: &summary)
            } catch {
                summary.failed += 1
            }
        }

        let audits = baseDirectory.appendingPathComponent("agent-audit", isDirectory: true)
        if let files = try? manager.contentsOfDirectory(
            at: audits,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        ) {
            for file in files.filter({ $0.pathExtension.lowercased() == "jsonl" })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                do {
                    let values = try file.resourceValues(forKeys: [.contentModificationDateKey])
                    let data = try boundedRegularFile(file)
                    let bundle = try importer.parseAudit(
                        data,
                        sourceName: file.lastPathComponent,
                        auditDirectory: audits,
                        sourceDate: values.contentModificationDate
                            ?? Date(timeIntervalSinceReferenceDate: 0)
                    )
                    record(try await store.importLegacyBundle(bundle), in: &summary)
                } catch {
                    summary.failed += 1
                }
            }
        }
        return summary
    }

    /// Deletes only the three retired, app-owned legacy history locations.
    /// All candidates are recursively validated before the first mutation, so
    /// a symlink, special file, mount point, or escaped path fails closed.
    /// Current scheduler definitions live at `agent/schedules.json` and are
    /// deliberately outside this retirement set.
    static func retireSources(
        baseDirectory: URL
    ) throws -> AgentLegacySourceRetirementReport {
        let root = baseDirectory.standardizedFileURL
        guard let rootMetadata = try metadataIfPresent(at: root),
              rootMetadata.kind == .directory else {
            throw AgentLegacySourceRetirementError.unsafeBaseDirectory
        }

        let conversations = root.appendingPathComponent(
            "agent-conversations",
            isDirectory: true
        )
        let audits = root.appendingPathComponent("agent-audit", isDirectory: true)
        let scheduler = root.appendingPathComponent("agent-tasks.json")
        for source in [conversations, audits, scheduler] {
            guard source.deletingLastPathComponent().standardizedFileURL == root else {
                throw AgentLegacySourceRetirementError.unsafeSource(
                    source.lastPathComponent
                )
            }
        }

        let conversationCount = try validatedTreeEntryCount(
            at: conversations,
            rootDeviceID: rootMetadata.deviceID
        )
        let auditCount = try validatedTreeEntryCount(
            at: audits,
            rootDeviceID: rootMetadata.deviceID
        )
        let schedulerMetadata = try metadataIfPresent(at: scheduler)
        if let schedulerMetadata,
           schedulerMetadata.kind != .regular
            || schedulerMetadata.deviceID != rootMetadata.deviceID {
            throw AgentLegacySourceRetirementError.unsafeSource(
                scheduler.lastPathComponent
            )
        }

        let candidates = [conversations, audits, scheduler]
        for candidate in candidates {
            guard try metadataIfPresent(at: root) == rootMetadata else {
                throw AgentLegacySourceRetirementError.unsafeBaseDirectory
            }
            guard try metadataIfPresent(at: candidate) != nil else { continue }
            if candidate == scheduler {
                guard let metadata = try metadataIfPresent(at: candidate),
                      metadata.kind == .regular,
                      metadata.deviceID == rootMetadata.deviceID else {
                    throw AgentLegacySourceRetirementError.unsafeSource(
                        candidate.lastPathComponent
                    )
                }
            } else {
                _ = try validatedTreeEntryCount(
                    at: candidate,
                    rootDeviceID: rootMetadata.deviceID
                )
            }
            try FileManager.default.removeItem(at: candidate)
        }

        for candidate in candidates where try metadataIfPresent(at: candidate) != nil {
            throw AgentLegacySourceRetirementError.sourceStillPresent(
                candidate.lastPathComponent
            )
        }
        return AgentLegacySourceRetirementReport(
            deletedConversationEntries: conversationCount,
            deletedAuditEntries: auditCount,
            deletedSchedulerSource: schedulerMetadata != nil
        )
    }

    private static func record(
        _ disposition: LegacyImportDisposition,
        in summary: inout AgentLegacyMigrationSummary
    ) {
        switch disposition {
        case .inserted: summary.inserted += 1
        case .alreadyImported: summary.alreadyImported += 1
        case .repairedIndexes: summary.repaired += 1
        }
    }

    private static func boundedRegularFile(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadNoPermission)
        }
        guard let size = values.fileSize, size <= 64 * 1_024 * 1_024 else {
            throw CocoaError(.fileReadTooLarge)
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private enum SourceEntryKind: Equatable {
        case directory
        case regular
    }

    private struct SourceEntryMetadata: Equatable {
        let kind: SourceEntryKind
        let deviceID: UInt64
        let inode: UInt64
    }

    private static func metadataIfPresent(
        at url: URL
    ) throws -> SourceEntryMetadata? {
        #if canImport(Darwin)
        var status = stat()
        let result = url.path.withCString { path in
            lstat(path, &status)
        }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadUnknown)
        }
        let kind: SourceEntryKind
        switch status.st_mode & S_IFMT {
        case S_IFDIR:
            kind = .directory
        case S_IFREG:
            kind = .regular
        default:
            throw AgentLegacySourceRetirementError.unsafeSource(
                url.lastPathComponent
            )
        }
        return SourceEntryMetadata(
            kind: kind,
            deviceID: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
        #else
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        return SourceEntryMetadata(
            kind: isDirectory.boolValue ? .directory : .regular,
            deviceID: 0,
            inode: 0
        )
        #endif
    }

    private static func validatedTreeEntryCount(
        at directory: URL,
        rootDeviceID: UInt64
    ) throws -> Int {
        guard let root = try metadataIfPresent(at: directory) else { return 0 }
        guard root.kind == .directory, root.deviceID == rootDeviceID else {
            throw AgentLegacySourceRetirementError.unsafeSource(
                directory.lastPathComponent
            )
        }
        let prefix = directory.standardizedFileURL.path + "/"
        var traversalError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                traversalError = error
                return false
            }
        ) else {
            throw AgentLegacySourceRetirementError.unsafeSource(
                directory.lastPathComponent
            )
        }
        var count = 0
        while let entry = enumerator.nextObject() as? URL {
            guard entry.standardizedFileURL.path.hasPrefix(prefix),
                  let metadata = try metadataIfPresent(at: entry),
                  metadata.deviceID == rootDeviceID else {
                throw AgentLegacySourceRetirementError.unsafeSource(
                    directory.lastPathComponent
                )
            }
            count += 1
        }
        if traversalError != nil {
            throw AgentLegacySourceRetirementError.unsafeSource(
                directory.lastPathComponent
            )
        }
        return count
    }
}
