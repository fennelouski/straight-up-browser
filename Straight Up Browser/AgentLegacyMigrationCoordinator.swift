import Foundation

nonisolated struct AgentLegacyMigrationSummary: Equatable, Sendable {
    var inserted = 0
    var alreadyImported = 0
    var repaired = 0
    var failed = 0
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
}
