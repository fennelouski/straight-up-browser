import Foundation
import Testing
@testable import Browser

struct AgentLegacyImporterTests {
    @Test func panelConversationSplitsRunsPreservesFoundationDatesAndRedactsToolArguments() throws {
        let data = try fixture("legacy-conversation-multiple-runs.json")
        let importer = LegacyAgentImporter()

        let first = try importer.parseConversation(
            data,
            sourceName: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA.json"
        )
        let second = try importer.parseConversation(
            data,
            sourceName: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA.json"
        )

        #expect(first == second)
        #expect(first.source.logicalID == UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"))
        #expect(first.conversation?.id == first.source.logicalID)
        #expect(first.conversation?.runIDs == first.runs.map(\.run.id))
        #expect(first.runs.count == 2)
        #expect(first.runs.map(\.run.status) == [.succeeded, .cancelled])
        #expect(first.runs[0].run.createdAt == Date(timeIntervalSinceReferenceDate: 725_760_000))
        #expect(first.runs[0].steps.map(\.sequence) == Array(0..<first.runs[0].steps.count))
        #expect(first.runs[0].steps.first(where: { $0.kind == .toolInvocation })?.redactionState == .redacted)
        #expect(first.runs[0].provenance.contains(.toolArgumentsRedacted))
        #expect(first.runs[0].provenance.contains(.toolResultUnavailable))

        let encoded = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        #expect(!encoded.contains("conversation-secret"))
        #expect(encoded.contains("Research cats"))
        #expect(encoded.contains("Cats found."))
    }

    @Test func schedulerImportsValidSummariesAndSkipsMalformedTasksAndRuns() throws {
        let data = try fixture("legacy-scheduler-lossy.json")
        let importer = LegacyAgentImporter()

        let bundle = try importer.parseScheduler(data)

        #expect(bundle.source.kind == .scheduler)
        #expect(bundle.source.relativeName == "agent-tasks.json")
        #expect(bundle.runs.map(\.run.id) == [
            UUID(uuidString: "11111111-AAAA-4111-8111-111111111111"),
            UUID(uuidString: "22222222-AAAA-4222-8222-222222222222"),
            UUID(uuidString: "33333333-AAAA-4333-8333-333333333333"),
        ])
        #expect(bundle.runs.map(\.run.taskDefinitionID) == [
            UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"),
            UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"),
            UUID(uuidString: "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF"),
        ])
        #expect(bundle.runs.map(\.run.status) == [.succeeded, .failed, .cancelled])
        #expect(bundle.runs.allSatisfy { $0.steps.map(\.sequence) == Array(0..<$0.steps.count) })
        #expect(bundle.issues.contains(LegacyProvenanceIssue(.malformedSchedulerElement, recordIndex: 2)))
        #expect(bundle.issues.contains(LegacyProvenanceIssue(.malformedSchedulerRun, recordIndex: 2)))

        let encoded = String(decoding: try JSONEncoder().encode(bundle), as: UTF8.self)
        #expect(encoded.contains("Daily summary"))
        #expect(encoded.contains("Partial but useful"))
        #expect(!encoded.contains("scheduler-secret-error"))
        #expect(bundle.runs[1].provenance.contains(.legacyErrorRedacted))
        #expect(bundle.runs.allSatisfy { $0.provenance.contains(.schedulePromptVersionUnknown) })
    }

    @Test func auditRecoversAroundInvalidLinesRedactsPayloadsAndInterruptsWithoutEnd() throws {
        var data = try fixture("legacy-audit-corrupt.jsonl")
        if data.last == 0x0A { data.removeLast() }
        let marker = Data("__INVALID_UTF8__".utf8)
        let markerRange = try #require(data.range(of: marker))
        data.replaceSubrange(markerRange, with: [0xFF, 0xFE])
        let importer = LegacyAgentImporter()

        let bundle = try importer.parseAudit(
            data,
            sourceName: "66666666-6666-4666-8666-666666666666.jsonl",
            auditDirectory: nil,
            sourceDate: Date(timeIntervalSinceReferenceDate: 725_760_000)
        )

        let imported = try #require(bundle.runs.only)
        #expect(imported.run.id == UUID(uuidString: "66666666-6666-4666-8666-666666666666"))
        #expect(imported.run.entryPoint == .localMCP)
        #expect(imported.run.status == .interrupted)
        #expect(imported.steps.map(\.sequence) == Array(0..<imported.steps.count))
        #expect(imported.steps.filter { $0.kind == .warning }.count == 4)
        #expect(bundle.issues.contains(LegacyProvenanceIssue(.invalidUTF8Line, recordIndex: 4)))
        #expect(bundle.issues.contains(LegacyProvenanceIssue(.malformedJSONLine, recordIndex: 5)))
        #expect(bundle.issues.contains(LegacyProvenanceIssue(.truncatedTail, recordIndex: 7)))
        #expect(bundle.issues.contains(LegacyProvenanceIssue(.missingSessionEnd)))
        #expect(imported.provenance.contains(.toolArgumentsRedacted))
        #expect(imported.provenance.contains(.legacyErrorRedacted))

        let encoded = String(decoding: try JSONEncoder().encode(bundle), as: UTF8.self)
        #expect(!encoded.contains("audit-client-secret"))
        #expect(!encoded.contains("audit-argument-secret"))
        #expect(!encoded.contains("audit-result-secret"))
        #expect(!encoded.contains("unfinished"))
        #expect(encoded.contains("Fixture Client"))
    }

    @Test func auditRebasesValidPNGFrameIntoMemoryWithoutRetainingAbsolutePath() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceName = "77777777-7777-4777-8777-777777777777.jsonl"
        let frames = root.appendingPathComponent("77777777-7777-4777-8777-777777777777")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
        try png.write(to: frames.appendingPathComponent("0001.png"))
        let data = Data("""
        {"event":"session_started","sessionId":"77777777-7777-4777-8777-777777777777","timestamp":"2024-01-01T00:00:00Z"}
        {"event":"frame_captured","frame":"/malicious/outside/0001.png","index":1,"timestamp":"2024-01-01T00:00:01Z","tool":"click"}
        {"event":"session_ended","timestamp":"2024-01-01T00:00:02Z"}

        """.utf8)

        let bundle = try LegacyAgentImporter().parseAudit(
            data,
            sourceName: sourceName,
            auditDirectory: root,
            sourceDate: .distantPast
        )

        let imported = try #require(bundle.runs.only)
        let artifact = try #require(imported.artifacts.only)
        #expect(imported.run.status == .succeeded)
        #expect(artifact.data == png)
        #expect(artifact.relativePath == "frames/0001.png")
        #expect(imported.steps.contains { $0.artifactID == artifact.id })
        let encoded = String(decoding: try JSONEncoder().encode(bundle), as: UTF8.self)
        #expect(!encoded.contains("/malicious/outside"))
        #expect(!encoded.contains(root.path))
    }

    @Test func auditRejectsMismatchedAndSymlinkedFrames() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceName = "88888888-8888-4888-8888-888888888888.jsonl"
        let frames = root.appendingPathComponent("88888888-8888-4888-8888-888888888888")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: frames.appendingPathComponent("0002.png"),
            withDestinationURL: outside
        )
        let data = Data("""
        {"event":"session_started","sessionId":"88888888-8888-4888-8888-888888888888","timestamp":"2024-01-01T00:00:00Z"}
        {"event":"frame_captured","frame":"/etc/passwd","index":1,"timestamp":"2024-01-01T00:00:01Z","tool":"click"}
        {"event":"frame_captured","frame":"/old/location/0002.png","index":2,"timestamp":"2024-01-01T00:00:02Z","tool":"fill"}
        {"event":"session_ended","timestamp":"2024-01-01T00:00:03Z"}

        """.utf8)

        let bundle = try LegacyAgentImporter().parseAudit(
            data,
            sourceName: sourceName,
            auditDirectory: root,
            sourceDate: .distantPast
        )

        let imported = try #require(bundle.runs.only)
        #expect(imported.artifacts.isEmpty)
        #expect(bundle.issues.contains(LegacyProvenanceIssue(.framePathRejected, recordIndex: 2)))
        #expect(bundle.issues.contains(LegacyProvenanceIssue(.framePathRejected, recordIndex: 3)))
        #expect(imported.steps.filter { $0.kind == .warning }.count == 2)
    }

    @Test func importerRejectsOversizedSourcesAndConvertsOversizedAuditLinesToWarnings() throws {
        let tinySourceImporter = LegacyAgentImporter(limits: .init(
            maximumSourceBytes: 4,
            maximumJSONLineBytes: 4,
            maximumFrameBytes: 4
        ))
        #expect(throws: LegacyAgentImporterError.sourceTooLarge(limit: 4)) {
            try tinySourceImporter.parseConversation(
                Data("too large".utf8),
                sourceName: "conversation.json"
            )
        }

        let auditImporter = LegacyAgentImporter(limits: .init(
            maximumSourceBytes: 1_024,
            maximumJSONLineBytes: 8,
            maximumFrameBytes: 1_024
        ))
        let bundle = try auditImporter.parseAudit(
            Data("{\"event\":\"session_ended\"}\n".utf8),
            sourceName: "audit.jsonl",
            auditDirectory: nil,
            sourceDate: Date(timeIntervalSinceReferenceDate: 1)
        )
        let imported = try #require(bundle.runs.only)
        #expect(bundle.issues.contains(LegacyProvenanceIssue(.oversizedJSONLine, recordIndex: 1)))
        #expect(bundle.issues.contains(LegacyProvenanceIssue(.missingSessionEnd)))
        #expect(imported.run.status == .interrupted)
        #expect(imported.steps.map(\.sequence) == Array(0..<imported.steps.count))
    }

    @Test func importerRejectsSourceNamesThatCouldEscapeLegacyRoots() {
        let importer = LegacyAgentImporter()
        for sourceName in ["/tmp/conversation.json", "../conversation.json", "nested/audit.jsonl"] {
            #expect(throws: LegacyAgentImporterError.self) {
                try importer.parseConversation(Data("[]".utf8), sourceName: sourceName)
            }
        }
    }

    private func fixture(_ name: String) throws -> Data {
        try TestFixture.data(name)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-agent-importer-\(UUID().uuidString)", isDirectory: true)
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
