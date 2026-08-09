import CryptoKit
import Foundation

nonisolated enum LegacyImportSourceKind: String, Codable, Sendable {
    case conversation
    case scheduler
    case audit
}

nonisolated enum LegacyProvenanceCode: String, Codable, CaseIterable, Hashable, Sendable {
    case providerUnknown
    case policyUnknown
    case browserSessionAndIncognitoUnknown
    case runBoundaryInferred
    case statusInferred
    case toolArgumentsRedacted
    case toolResultsRedacted
    case toolResultUnavailable
    case legacyErrorRedacted
    case schedulePromptVersionUnknown
    case malformedSchedulerElement
    case malformedSchedulerRun
    case invalidUTF8Line
    case malformedJSONLine
    case oversizedJSONLine
    case truncatedTail
    case missingSessionEnd
    case timestampMissing
    case frameMissing
    case framePathRejected
    case frameInvalid
    case sessionIDMismatch
    case uuidCollision
}

nonisolated struct LegacyProvenanceIssue: Codable, Equatable, Sendable {
    let code: LegacyProvenanceCode
    let recordIndex: Int?

    init(_ code: LegacyProvenanceCode, recordIndex: Int? = nil) {
        self.code = code
        self.recordIndex = recordIndex
    }
}

nonisolated struct LegacyImportSource: Codable, Equatable, Sendable {
    static let importerVersion = 1

    let kind: LegacyImportSourceKind
    let relativeName: String
    let logicalID: UUID
    let contentSHA256: String
    let byteCount: Int
    let importerVersion: Int

    var receiptKey: String {
        "\(importerVersion):\(kind.rawValue):\(relativeName):\(contentSHA256)"
    }
}

/// Artifact bytes are carried in-memory so a later store transaction never
/// needs to follow an untrusted path from a legacy JSON event.
nonisolated struct LegacyImportArtifact: Codable, Equatable, Sendable {
    let id: UUID
    let runID: UUID
    let sourceStepID: UUID
    let contentType: String
    let relativePath: String
    let sha256: String
    let data: Data
    let redactionState: AgentRedactionState
    let createdAt: Date
}

nonisolated struct LegacyImportedRun: Codable, Equatable, Sendable {
    var run: AgentRun
    var steps: [AgentStep]
    var artifacts: [LegacyImportArtifact]
    var provenance: [LegacyProvenanceCode]
}

nonisolated struct LegacyImportBundle: Codable, Equatable, Sendable {
    let source: LegacyImportSource
    var conversation: AgentConversation?
    var runs: [LegacyImportedRun]
    var issues: [LegacyProvenanceIssue]

    init(
        source: LegacyImportSource,
        conversation: AgentConversation?,
        runs: [LegacyImportedRun],
        issues: [LegacyProvenanceIssue]
    ) throws {
        let runIDs = runs.map(\.run.id)
        guard Set(runIDs).count == runIDs.count else {
            throw LegacyAgentImporterError.invalidBundle("duplicate run IDs")
        }
        if let conversation, conversation.runIDs != runIDs {
            throw LegacyAgentImporterError.invalidBundle("conversation run order does not match bundle")
        }
        for imported in runs {
            guard imported.run.nextSequence == imported.steps.count,
                  imported.steps.enumerated().allSatisfy({ index, step in
                      step.runID == imported.run.id && step.sequence == index
                  }),
                  Set(imported.steps.map(\.id)).count == imported.steps.count else {
                throw LegacyAgentImporterError.invalidBundle("run contains non-dense or mismatched steps")
            }
            let stepIDs = Set(imported.steps.map(\.id))
            guard imported.artifacts.allSatisfy({ artifact in
                artifact.runID == imported.run.id
                    && stepIDs.contains(artifact.sourceStepID)
                    && !artifact.relativePath.hasPrefix("/")
                    && !artifact.relativePath.split(separator: "/").contains("..")
            }) else {
                throw LegacyAgentImporterError.invalidBundle("run contains an unsafe artifact")
            }
        }
        self.source = source
        self.conversation = conversation
        self.runs = runs
        self.issues = issues
    }
}

nonisolated enum LegacyAgentImporterError: Error, Equatable, Sendable {
    case invalidSourceName(String)
    case sourceTooLarge(limit: Int)
    case malformedSource(LegacyImportSourceKind)
    case invalidBundle(String)
}

nonisolated struct LegacyAgentImporter: Sendable {
    struct Limits: Equatable, Sendable {
        var maximumSourceBytes = 64 * 1_024 * 1_024
        var maximumJSONLineBytes = 4 * 1_024 * 1_024
        var maximumFrameBytes = 25 * 1_024 * 1_024
    }

    let limits: Limits

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    func parseConversation(_ data: Data, sourceName: String) throws -> LegacyImportBundle {
        try validate(data: data, sourceName: sourceName)
        let source = makeSource(
            kind: .conversation,
            name: sourceName,
            data: data,
            preferredID: UUID(uuidString: URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent)
        )
        guard let messages = try? JSONDecoder().decode([LegacyConversationMessage].self, from: data) else {
            throw LegacyAgentImporterError.malformedSource(.conversation)
        }

        let segments = splitConversation(messages)
        var importedRuns: [LegacyImportedRun] = []
        var usedRunIDs: Set<UUID> = []
        for (index, segment) in segments.enumerated() {
            guard let first = segment.first else { continue }
            var runID = deterministicID("conversation-run:\(source.logicalID.uuidString):\(first.id.uuidString)")
            var extraProvenance: [LegacyProvenanceCode] = []
            if !usedRunIDs.insert(runID).inserted {
                runID = deterministicID("conversation-run-collision:\(source.relativeName):\(index)")
                extraProvenance.append(.uuidCollision)
                usedRunIDs.insert(runID)
            }
            importedRuns.append(mapConversationSegment(
                segment,
                runID: runID,
                conversationID: source.logicalID,
                source: source,
                extraProvenance: extraProvenance
            ))
        }

        let createdAt = messages.first?.createdAt ?? Date(timeIntervalSinceReferenceDate: 0)
        var conversation = AgentConversation(
            id: source.logicalID,
            title: conversationTitle(messages),
            createdAt: createdAt,
            runIDs: importedRuns.map(\.run.id),
            importedFromLegacy: true
        )
        conversation.updatedAt = messages.last?.createdAt ?? createdAt
        return try LegacyImportBundle(
            source: source,
            conversation: conversation,
            runs: importedRuns,
            issues: []
        )
    }

    func parseScheduler(
        _ data: Data,
        sourceName: String = "agent-tasks.json"
    ) throws -> LegacyImportBundle {
        try validate(data: data, sourceName: sourceName)
        let source = makeSource(kind: .scheduler, name: sourceName, data: data)
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let taskValues) = root else {
            throw LegacyAgentImporterError.malformedSource(.scheduler)
        }

        var importedRuns: [LegacyImportedRun] = []
        var issues: [LegacyProvenanceIssue] = []
        var usedRunIDs: Set<UUID> = []
        for (taskIndex, taskValue) in taskValues.enumerated() {
            guard let task = decodeJSONValue(LegacySchedulerTask.self, from: taskValue) else {
                issues.append(LegacyProvenanceIssue(
                    .malformedSchedulerElement,
                    recordIndex: taskIndex + 1
                ))
                continue
            }
            for (runIndex, runValue) in task.runs.enumerated() {
                guard let legacyRun = decodeJSONValue(LegacySchedulerRun.self, from: runValue) else {
                    issues.append(LegacyProvenanceIssue(
                        .malformedSchedulerRun,
                        recordIndex: runIndex + 1
                    ))
                    continue
                }
                var runID = legacyRun.id
                var extraProvenance: [LegacyProvenanceCode] = []
                if !usedRunIDs.insert(runID).inserted {
                    runID = deterministicID(
                        "scheduler-run-collision:\(task.id.uuidString):\(runIndex):\(runID.uuidString)"
                    )
                    usedRunIDs.insert(runID)
                    extraProvenance.append(.uuidCollision)
                    issues.append(LegacyProvenanceIssue(
                        .uuidCollision,
                        recordIndex: runIndex + 1
                    ))
                }
                importedRuns.append(mapSchedulerRun(
                    legacyRun,
                    runID: runID,
                    taskID: task.id,
                    source: source,
                    extraProvenance: extraProvenance
                ))
            }
        }

        return try LegacyImportBundle(
            source: source,
            conversation: nil,
            runs: importedRuns,
            issues: issues
        )
    }

    func parseAudit(
        _ data: Data,
        sourceName: String,
        auditDirectory: URL?,
        sourceDate: Date
    ) throws -> LegacyImportBundle {
        try validate(data: data, sourceName: sourceName)
        var records: [LegacyAuditRecord] = []
        var issues: [LegacyProvenanceIssue] = []
        var provenance: Set<LegacyProvenanceCode> = [
            .providerUnknown,
            .policyUnknown,
            .browserSessionAndIncognitoUnknown,
            .runBoundaryInferred,
            .statusInferred,
        ]
        var transportID: UUID?
        var endedNormally = false

        let hasTerminalNewline = data.last == 0x0A
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        for (lineIndex, lineBytes) in lines.enumerated() {
            let lineNumber = lineIndex + 1
            if lineBytes.isEmpty { continue }
            if lineIndex == lines.count - 1, !hasTerminalNewline {
                issues.append(LegacyProvenanceIssue(.truncatedTail, recordIndex: lineNumber))
                provenance.insert(.truncatedTail)
                records.append(LegacyAuditRecord(
                    lineNumber: lineNumber,
                    timestamp: fallbackTimestamp(sourceDate, lineNumber: lineNumber),
                    kind: .warning(.truncatedTail)
                ))
                continue
            }
            guard lineBytes.count <= limits.maximumJSONLineBytes else {
                issues.append(LegacyProvenanceIssue(.oversizedJSONLine, recordIndex: lineNumber))
                provenance.insert(.oversizedJSONLine)
                records.append(LegacyAuditRecord(
                    lineNumber: lineNumber,
                    timestamp: fallbackTimestamp(sourceDate, lineNumber: lineNumber),
                    kind: .warning(.oversizedJSONLine)
                ))
                continue
            }

            let lineData = Data(lineBytes)
            guard String(data: lineData, encoding: .utf8) != nil else {
                issues.append(LegacyProvenanceIssue(.invalidUTF8Line, recordIndex: lineNumber))
                provenance.insert(.invalidUTF8Line)
                records.append(LegacyAuditRecord(
                    lineNumber: lineNumber,
                    timestamp: fallbackTimestamp(sourceDate, lineNumber: lineNumber),
                    kind: .warning(.invalidUTF8Line)
                ))
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                issues.append(LegacyProvenanceIssue(.malformedJSONLine, recordIndex: lineNumber))
                provenance.insert(.malformedJSONLine)
                records.append(LegacyAuditRecord(
                    lineNumber: lineNumber,
                    timestamp: fallbackTimestamp(sourceDate, lineNumber: lineNumber),
                    kind: .warning(.malformedJSONLine)
                ))
                continue
            }

            let timestamp: Date
            if let rawTimestamp = object["timestamp"] as? String,
               let parsedTimestamp = parseISO8601(rawTimestamp) {
                timestamp = parsedTimestamp
            } else {
                timestamp = fallbackTimestamp(sourceDate, lineNumber: lineNumber)
                issues.append(LegacyProvenanceIssue(.timestampMissing, recordIndex: lineNumber))
                provenance.insert(.timestampMissing)
            }

            let event = object["event"] as? String ?? ""
            let recordKind: LegacyAuditRecord.Kind
            switch event {
            case "session_started":
                let sessionID = (object["sessionId"] as? String).flatMap(UUID.init(uuidString:))
                if transportID == nil { transportID = sessionID }
                recordKind = .transportStarted(sessionID)
            case "client_initialized":
                let client = object["client"] as? [String: Any]
                recordKind = .clientInitialized(
                    sanitizedMetadata(client?["name"] as? String),
                    sanitizedMetadata(client?["version"] as? String)
                )
            case "tool_started":
                provenance.insert(.toolArgumentsRedacted)
                recordKind = .toolStarted(sanitizedToolName(object["tool"] as? String))
            case "tool_finished":
                provenance.insert(.toolResultsRedacted)
                let result = object["result"] as? [String: Any]
                let hasError = result?["error"] != nil
                if hasError { provenance.insert(.legacyErrorRedacted) }
                let duration = boundedDuration(object["durationMs"])
                recordKind = .toolFinished(
                    sanitizedToolName(object["tool"] as? String),
                    duration,
                    hasError
                )
            case "frame_captured":
                recordKind = .frameCaptured(
                    sanitizedToolName(object["tool"] as? String),
                    integer(object["index"]),
                    object["frame"] as? String
                )
            case "frame_failed":
                provenance.insert(.legacyErrorRedacted)
                recordKind = .frameFailed(sanitizedToolName(object["tool"] as? String))
            case "session_ended":
                endedNormally = true
                recordKind = .transportEnded
            default:
                recordKind = .unknown(sanitizedEventName(event))
            }
            records.append(LegacyAuditRecord(
                lineNumber: lineNumber,
                timestamp: timestamp,
                kind: recordKind
            ))
        }

        let filenameID = UUID(
            uuidString: URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
        )
        if let filenameID, let transportID, filenameID != transportID {
            issues.append(LegacyProvenanceIssue(.sessionIDMismatch))
            provenance.insert(.sessionIDMismatch)
        }
        let runID = filenameID
            ?? transportID
            ?? deterministicID("legacy-audit-run:\(sourceName)")
        let source = makeSource(
            kind: .audit,
            name: sourceName,
            data: data,
            preferredID: runID
        )

        if !endedNormally {
            issues.append(LegacyProvenanceIssue(.missingSessionEnd))
            provenance.insert(.missingSessionEnd)
            let lineNumber = max(1, lines.count + (hasTerminalNewline ? 0 : 1))
            records.append(LegacyAuditRecord(
                lineNumber: lineNumber,
                timestamp: records.last?.timestamp ?? sourceDate,
                kind: .warning(.missingSessionEnd)
            ))
        }

        let imported = mapAuditRecords(
            records,
            runID: runID,
            source: source,
            sourceName: sourceName,
            auditDirectory: auditDirectory,
            endedNormally: endedNormally,
            provenance: &provenance,
            issues: &issues,
            sourceDate: sourceDate
        )
        return try LegacyImportBundle(
            source: source,
            conversation: nil,
            runs: [imported],
            issues: issues
        )
    }

    private func mapAuditRecords(
        _ records: [LegacyAuditRecord],
        runID: UUID,
        source: LegacyImportSource,
        sourceName: String,
        auditDirectory: URL?,
        endedNormally: Bool,
        provenance: inout Set<LegacyProvenanceCode>,
        issues: inout [LegacyProvenanceIssue],
        sourceDate: Date
    ) -> LegacyImportedRun {
        let createdAt = records.first?.timestamp ?? sourceDate
        var steps: [AgentStep] = [AgentStep(
            id: deterministicID("audit:\(runID.uuidString):start"),
            runID: runID,
            sequence: 0,
            timestamp: createdAt,
            kind: .stateTransition,
            summary: "Imported legacy MCP run started",
            payload: .object(["from": .string("queued"), "to": .string("running")])
        )]
        var artifacts: [LegacyImportArtifact] = []

        for record in records {
            let stepID = deterministicID(
                "audit:\(runID.uuidString):line:\(record.lineNumber):\(record.kind.identity)"
            )
            switch record.kind {
            case .transportStarted:
                steps.append(AgentStep(
                    id: stepID,
                    runID: runID,
                    sequence: steps.count,
                    timestamp: record.timestamp,
                    kind: .system,
                    summary: "Legacy MCP transport started"
                ))
            case .clientInitialized(let name, let version):
                var metadata: [String: JSONValue] = [:]
                if let name { metadata["name"] = .string(name) }
                if let version { metadata["version"] = .string(version) }
                steps.append(AgentStep(
                    id: stepID,
                    runID: runID,
                    sequence: steps.count,
                    timestamp: record.timestamp,
                    kind: .system,
                    summary: "Legacy MCP client initialized",
                    payload: metadata.isEmpty ? nil : .object(metadata),
                    redactionState: .metadataOnly
                ))
            case .toolStarted(let tool):
                steps.append(AgentStep(
                    id: stepID,
                    runID: runID,
                    sequence: steps.count,
                    timestamp: record.timestamp,
                    kind: .toolInvocation,
                    summary: "Imported \(tool) invocation; arguments redacted",
                    payload: safeLinePayload(
                        line: record.lineNumber,
                        extras: ["legacyArgumentsRedacted": .boolean(true)]
                    ),
                    redactionState: .redacted
                ))
            case .toolFinished(let tool, let duration, let hasError):
                var extras: [String: JSONValue] = [
                    "legacyResultRedacted": .boolean(true),
                    "hasError": .boolean(hasError),
                ]
                if let duration { extras["durationMs"] = .number(Double(duration)) }
                steps.append(AgentStep(
                    id: stepID,
                    runID: runID,
                    sequence: steps.count,
                    timestamp: record.timestamp,
                    kind: .toolResult,
                    summary: hasError
                        ? "Imported \(tool) failure; result redacted"
                        : "Imported \(tool) result; details redacted",
                    payload: safeLinePayload(line: record.lineNumber, extras: extras),
                    redactionState: .redacted
                ))
            case .frameCaptured(let tool, let index, let rawPath):
                let frame = validateFrame(
                    sourceName: sourceName,
                    auditDirectory: auditDirectory,
                    index: index,
                    rawPath: rawPath
                )
                switch frame {
                case .accepted(let filename, let data, let digest):
                    let artifactID = deterministicID("audit:\(runID.uuidString):frame:\(record.lineNumber)")
                    steps.append(AgentStep(
                        id: stepID,
                        runID: runID,
                        sequence: steps.count,
                        timestamp: record.timestamp,
                        kind: .artifact,
                        summary: "Imported replay frame after \(tool)",
                        payload: .object(["sourceLine": .number(Double(record.lineNumber))]),
                        artifactID: artifactID,
                        redactionState: .retained
                    ))
                    artifacts.append(LegacyImportArtifact(
                        id: artifactID,
                        runID: runID,
                        sourceStepID: stepID,
                        contentType: "image/png",
                        relativePath: "frames/\(filename)",
                        sha256: digest,
                        data: data,
                        redactionState: .retained,
                        createdAt: record.timestamp
                    ))
                case .rejected(let code):
                    provenance.insert(code)
                    issues.append(LegacyProvenanceIssue(code, recordIndex: record.lineNumber))
                    steps.append(warningStep(
                        id: stepID,
                        runID: runID,
                        sequence: steps.count,
                        timestamp: record.timestamp,
                        code: code,
                        line: record.lineNumber
                    ))
                }
            case .frameFailed(let tool):
                steps.append(AgentStep(
                    id: stepID,
                    runID: runID,
                    sequence: steps.count,
                    timestamp: record.timestamp,
                    kind: .warning,
                    summary: "Legacy replay frame capture failed after \(tool); details redacted",
                    payload: safeLinePayload(
                        line: record.lineNumber,
                        extras: ["legacyErrorRedacted": .boolean(true)]
                    ),
                    redactionState: .redacted
                ))
            case .transportEnded:
                steps.append(AgentStep(
                    id: stepID,
                    runID: runID,
                    sequence: steps.count,
                    timestamp: record.timestamp,
                    kind: .system,
                    summary: "Legacy MCP transport ended normally"
                ))
            case .unknown(let event):
                steps.append(AgentStep(
                    id: stepID,
                    runID: runID,
                    sequence: steps.count,
                    timestamp: record.timestamp,
                    kind: .system,
                    summary: event.isEmpty ? "Unknown legacy MCP event" : "Unknown legacy MCP event: \(event)",
                    payload: .object(["sourceLine": .number(Double(record.lineNumber))])
                ))
            case .warning(let code):
                steps.append(warningStep(
                    id: stepID,
                    runID: runID,
                    sequence: steps.count,
                    timestamp: record.timestamp,
                    code: code,
                    line: code == .missingSessionEnd ? nil : record.lineNumber
                ))
            }
        }

        let status: AgentRunStatus = endedNormally ? .succeeded : .interrupted
        let lastDate = records.last?.timestamp ?? createdAt
        steps.append(AgentStep(
            id: deterministicID("audit:\(runID.uuidString):finish"),
            runID: runID,
            sequence: steps.count,
            timestamp: lastDate,
            kind: .stateTransition,
            summary: endedNormally
                ? "Legacy MCP transport closed normally"
                : "Legacy MCP transport ended without a closing event",
            payload: .object(["from": .string("running"), "to": .string(status.rawValue)])
        ))

        let orderedProvenance = provenance.sorted { $0.rawValue < $1.rawValue }
        var run = AgentRun(
            id: runID,
            conversationID: nil,
            entryPoint: .localMCP,
            status: status,
            createdAt: createdAt,
            configuration: legacyConfiguration(source: source, provenance: orderedProvenance),
            importedFromLegacy: true
        )
        run.startedAt = createdAt
        run.finishedAt = status.isTerminal ? lastDate : nil
        run.lastUpdatedAt = lastDate
        run.nextSequence = steps.count
        return LegacyImportedRun(
            run: run,
            steps: steps,
            artifacts: artifacts,
            provenance: orderedProvenance
        )
    }

    private func warningStep(
        id: UUID,
        runID: UUID,
        sequence: Int,
        timestamp: Date,
        code: LegacyProvenanceCode,
        line: Int?
    ) -> AgentStep {
        var payload: [String: JSONValue] = ["code": .string(code.rawValue)]
        if let line { payload["sourceLine"] = .number(Double(line)) }
        return AgentStep(
            id: id,
            runID: runID,
            sequence: sequence,
            timestamp: timestamp,
            kind: .warning,
            summary: "Legacy import gap: \(code.rawValue)",
            payload: .object(payload),
            redactionState: .metadataOnly
        )
    }

    private func safeLinePayload(
        line: Int,
        extras: [String: JSONValue]
    ) -> JSONValue {
        var payload = extras
        payload["sourceLine"] = .number(Double(line))
        return .object(payload)
    }

    private func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    private func fallbackTimestamp(_ sourceDate: Date, lineNumber: Int) -> Date {
        sourceDate.addingTimeInterval(Double(lineNumber) / 1_000_000)
    }

    private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded() == double,
              double >= Double(Int.min),
              double <= Double(Int.max) else { return nil }
        return Int(double)
    }

    private func boundedDuration(_ value: Any?) -> Int? {
        guard let value = integer(value), value >= 0 else { return nil }
        return min(value, 86_400_000)
    }

    private func sanitizedMetadata(_ value: String?) -> String? {
        guard let value else { return nil }
        let scalarView = value.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .prefix(120)
        let result = String(String.UnicodeScalarView(scalarView))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private func sanitizedEventName(_ value: String) -> String {
        let allowed = CharacterSet.lowercaseLetters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "_-"))
        return value.unicodeScalars
            .prefix(64)
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
    }

    private func validateFrame(
        sourceName: String,
        auditDirectory: URL?,
        index: Int?,
        rawPath: String?
    ) -> LegacyFrameValidation {
        guard let index, index > 0,
              let rawPath, rawPath.hasPrefix("/") else {
            return .rejected(.framePathRejected)
        }
        let filename = String(format: "%04d.png", index)
        guard URL(fileURLWithPath: rawPath).lastPathComponent == filename else {
            return .rejected(.framePathRejected)
        }
        guard let auditDirectory else { return .rejected(.frameMissing) }

        let stem = URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
        let framesDirectory = auditDirectory.appendingPathComponent(stem, isDirectory: true)
        let candidate = framesDirectory.appendingPathComponent(filename, isDirectory: false)
        guard !isSymbolicLink(framesDirectory), !isSymbolicLink(candidate) else {
            return .rejected(.framePathRejected)
        }

        let canonicalAudit = auditDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalFrames = framesDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard isContained(canonicalFrames, by: canonicalAudit),
              canonicalCandidate.deletingLastPathComponent().path == canonicalFrames.path else {
            return .rejected(.framePathRejected)
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let byteCount = (attributes[.size] as? NSNumber)?.intValue else {
            return .rejected(.frameMissing)
        }
        guard byteCount <= limits.maximumFrameBytes,
              let data = try? Data(contentsOf: candidate, options: .mappedIfSafe),
              data.count == byteCount,
              data.count <= limits.maximumFrameBytes,
              data.starts(with: Self.pngSignature) else {
            return .rejected(.frameInvalid)
        }
        return .accepted(filename: filename, data: data, digest: sha256(data))
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func isContained(_ candidate: URL, by directory: URL) -> Bool {
        candidate.path == directory.path || candidate.path.hasPrefix(directory.path + "/")
    }

    private func mapSchedulerRun(
        _ legacy: LegacySchedulerRun,
        runID: UUID,
        taskID: UUID,
        source: LegacyImportSource,
        extraProvenance: [LegacyProvenanceCode]
    ) -> LegacyImportedRun {
        let status = legacy.status.agentStatus
        var provenance: Set<LegacyProvenanceCode> = [
            .providerUnknown,
            .policyUnknown,
            .browserSessionAndIncognitoUnknown,
            .schedulePromptVersionUnknown,
        ]
        provenance.formUnion(extraProvenance)
        if status == .failed { provenance.insert(.legacyErrorRedacted) }
        let orderedProvenance = provenance.sorted { $0.rawValue < $1.rawValue }

        var steps: [AgentStep] = [AgentStep(
            id: deterministicID("scheduler:\(runID.uuidString):start"),
            runID: runID,
            sequence: 0,
            timestamp: legacy.startedAt,
            kind: .stateTransition,
            summary: "Imported scheduled run started",
            payload: .object(["from": .string("queued"), "to": .string("running")])
        )]
        if status == .failed {
            steps.append(AgentStep(
                id: deterministicID("scheduler:\(runID.uuidString):output"),
                runID: runID,
                sequence: steps.count,
                timestamp: legacy.finishedAt,
                kind: .error,
                summary: "Imported scheduled error; details redacted",
                payload: .object(["legacyErrorRedacted": .boolean(true)]),
                redactionState: .redacted
            ))
        } else {
            steps.append(AgentStep(
                id: deterministicID("scheduler:\(runID.uuidString):output"),
                runID: runID,
                sequence: steps.count,
                timestamp: legacy.finishedAt,
                kind: .modelText,
                summary: status == .cancelled
                    ? "Imported partial scheduled output"
                    : "Imported scheduled output",
                payload: .object(["text": .string(legacy.output)]),
                redactionState: .retained
            ))
        }
        steps.append(AgentStep(
            id: deterministicID("scheduler:\(runID.uuidString):finish"),
            runID: runID,
            sequence: steps.count,
            timestamp: legacy.finishedAt,
            kind: .stateTransition,
            summary: "Imported scheduled run ended",
            payload: .object(["from": .string("running"), "to": .string(status.rawValue)])
        ))

        var run = AgentRun(
            id: runID,
            conversationID: nil,
            taskDefinitionID: taskID,
            entryPoint: .scheduled,
            status: status,
            createdAt: legacy.startedAt,
            configuration: legacyConfiguration(source: source, provenance: orderedProvenance),
            importedFromLegacy: true
        )
        run.startedAt = legacy.startedAt
        run.finishedAt = legacy.finishedAt
        run.lastUpdatedAt = legacy.finishedAt
        run.nextSequence = steps.count
        if status == .failed { run.failureCategory = "legacyScheduledError" }
        return LegacyImportedRun(run: run, steps: steps, artifacts: [], provenance: orderedProvenance)
    }

    private func mapConversationSegment(
        _ messages: [LegacyConversationMessage],
        runID: UUID,
        conversationID: UUID,
        source: LegacyImportSource,
        extraProvenance: [LegacyProvenanceCode]
    ) -> LegacyImportedRun {
        let createdAt = messages.first?.createdAt ?? Date(timeIntervalSinceReferenceDate: 0)
        let lastDate = messages.last?.createdAt ?? createdAt
        let status = conversationStatus(messages.last)
        var provenance: Set<LegacyProvenanceCode> = [
            .providerUnknown,
            .policyUnknown,
            .browserSessionAndIncognitoUnknown,
            .runBoundaryInferred,
            .statusInferred,
        ]
        provenance.formUnion(extraProvenance)
        if messages.contains(where: { $0.role == .tool }) {
            provenance.formUnion([.toolArgumentsRedacted, .toolResultUnavailable])
        }
        if messages.contains(where: { $0.role == .error }) {
            provenance.insert(.legacyErrorRedacted)
        }

        var steps: [AgentStep] = []
        steps.append(AgentStep(
            id: deterministicID("\(source.logicalID.uuidString):\(runID.uuidString):start"),
            runID: runID,
            sequence: 0,
            timestamp: createdAt,
            kind: .stateTransition,
            summary: "Imported legacy run started",
            payload: .object(["from": .string("queued"), "to": .string("running")])
        ))

        var usedStepIDs: Set<UUID> = [steps[0].id]
        for (messageIndex, message) in messages.enumerated() {
            var stepID = message.id
            if !usedStepIDs.insert(stepID).inserted {
                stepID = deterministicID("\(runID.uuidString):message-collision:\(messageIndex)")
                provenance.insert(.uuidCollision)
                usedStepIDs.insert(stepID)
            }
            let mapped = mapConversationMessage(
                message,
                id: stepID,
                runID: runID,
                sequence: steps.count
            )
            steps.append(mapped)
        }

        var finishID = deterministicID("\(source.logicalID.uuidString):\(runID.uuidString):finish")
        if usedStepIDs.contains(finishID) {
            finishID = deterministicID("\(source.logicalID.uuidString):\(runID.uuidString):finish-collision")
            provenance.insert(.uuidCollision)
        }
        steps.append(AgentStep(
            id: finishID,
            runID: runID,
            sequence: steps.count,
            timestamp: lastDate,
            kind: .stateTransition,
            summary: status == .interrupted ? "Legacy run ended without an outcome" : "Imported legacy run ended",
            payload: .object(["from": .string("running"), "to": .string(status.rawValue)])
        ))

        let orderedProvenance = provenance.sorted { $0.rawValue < $1.rawValue }
        var run = AgentRun(
            id: runID,
            conversationID: conversationID,
            entryPoint: .attended,
            status: status,
            createdAt: createdAt,
            configuration: legacyConfiguration(source: source, provenance: orderedProvenance),
            importedFromLegacy: true
        )
        run.startedAt = createdAt
        run.finishedAt = status.isTerminal ? lastDate : nil
        run.lastUpdatedAt = lastDate
        run.nextSequence = steps.count
        if status == .failed { run.failureCategory = "legacyError" }
        return LegacyImportedRun(run: run, steps: steps, artifacts: [], provenance: orderedProvenance)
    }

    private func mapConversationMessage(
        _ message: LegacyConversationMessage,
        id: UUID,
        runID: UUID,
        sequence: Int
    ) -> AgentStep {
        switch message.role {
        case .user:
            AgentStep(
                id: id,
                runID: runID,
                sequence: sequence,
                timestamp: message.createdAt,
                kind: .userMessage,
                summary: "Imported user message",
                payload: .object(["text": .string(message.text)]),
                redactionState: .retained
            )
        case .assistant:
            AgentStep(
                id: id,
                runID: runID,
                sequence: sequence,
                timestamp: message.createdAt,
                kind: .modelText,
                summary: "Imported model response",
                payload: .object(["text": .string(message.text)]),
                redactionState: .retained
            )
        case .tool:
            AgentStep(
                id: id,
                runID: runID,
                sequence: sequence,
                timestamp: message.createdAt,
                kind: .toolInvocation,
                summary: "Imported \(sanitizedToolName(message.toolName)) invocation; arguments redacted",
                payload: .object(["legacyArgumentsRedacted": .boolean(true)]),
                redactionState: .redacted
            )
        case .error:
            AgentStep(
                id: id,
                runID: runID,
                sequence: sequence,
                timestamp: message.createdAt,
                kind: .error,
                summary: "Imported legacy agent error; details redacted",
                payload: .object(["legacyErrorRedacted": .boolean(true)]),
                redactionState: .redacted
            )
        }
    }

    private func conversationStatus(_ finalMessage: LegacyConversationMessage?) -> AgentRunStatus {
        guard let finalMessage else { return .interrupted }
        switch finalMessage.role {
        case .assistant: return .succeeded
        case .error: return finalMessage.text == "Stopped." ? .cancelled : .failed
        case .user, .tool: return .interrupted
        }
    }

    private func splitConversation(_ messages: [LegacyConversationMessage]) -> [[LegacyConversationMessage]] {
        var segments: [[LegacyConversationMessage]] = []
        for message in messages {
            if message.role == .user, let last = segments.last, !last.isEmpty {
                segments.append([message])
            } else if segments.isEmpty {
                segments.append([message])
            } else {
                segments[segments.count - 1].append(message)
            }
        }
        return segments
    }

    private func conversationTitle(_ messages: [LegacyConversationMessage]) -> String {
        guard let text = messages.first(where: { $0.role == .user })?.text else {
            return "Imported conversation"
        }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? "Imported conversation" : String(collapsed.prefix(80))
    }

    private func legacyConfiguration(
        source: LegacyImportSource,
        provenance: [LegacyProvenanceCode]
    ) -> AgentConfigurationSnapshot {
        AgentConfigurationSnapshot(settings: [
            "legacy": .object([
                "sourceKind": .string(source.kind.rawValue),
                "sourceName": .string(source.relativeName),
                "provenance": .array(provenance.map { .string($0.rawValue) }),
            ]),
        ])
    }

    private func validate(data: Data, sourceName: String) throws {
        guard !sourceName.isEmpty,
              sourceName != ".",
              sourceName != "..",
              !sourceName.hasPrefix("/"),
              !sourceName.contains("/"),
              !sourceName.contains("\\") else {
            throw LegacyAgentImporterError.invalidSourceName(sourceName)
        }
        guard data.count <= limits.maximumSourceBytes else {
            throw LegacyAgentImporterError.sourceTooLarge(limit: limits.maximumSourceBytes)
        }
    }

    private func makeSource(
        kind: LegacyImportSourceKind,
        name: String,
        data: Data,
        preferredID: UUID? = nil
    ) -> LegacyImportSource {
        LegacyImportSource(
            kind: kind,
            relativeName: name,
            logicalID: preferredID ?? deterministicID("legacy-source:\(kind.rawValue):\(name)"),
            contentSHA256: sha256(data),
            byteCount: data.count,
            importerVersion: LegacyImportSource.importerVersion
        )
    }

    private func decodeJSONValue<T: Decodable>(_ type: T.Type, from value: JSONValue) -> T? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func sanitizedToolName(_ value: String?) -> String {
        guard let value else { return "legacy tool" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.:-"))
        let sanitized = value.unicodeScalars
            .prefix(80)
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
        return sanitized.isEmpty ? "legacy tool" : sanitized
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func deterministicID(_ value: String) -> UUID {
        var namespace = Self.deterministicNamespace.uuid
        var bytes = withUnsafeBytes(of: &namespace) { Array($0) }
        bytes.append(contentsOf: value.utf8)
        var digest = Array(Insecure.SHA1.hash(data: Data(bytes)).prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }

    private static let deterministicNamespace = UUID(
        uuidString: "9D1FA9D9-846A-5AB5-BD34-95566206B14B"
    )!

    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
}

private nonisolated struct LegacyConversationMessage: Decodable, Sendable {
    enum Role: String, Decodable, Sendable {
        case user
        case assistant
        case tool
        case error
    }

    let id: UUID
    let role: Role
    let text: String
    let toolName: String?
    let createdAt: Date
}

private nonisolated struct LegacySchedulerTask: Decodable, Sendable {
    let id: UUID
    let name: String
    let prompt: String
    let enabled: Bool
    let scheduleKind: String
    let interval: Int
    let dailyHour: Int
    let dailyMinute: Int
    let nextRunAt: Date
    let runs: [JSONValue]
}

private nonisolated struct LegacySchedulerRun: Decodable, Sendable {
    enum Status: String, Decodable, Sendable {
        case succeeded
        case failed
        case cancelled

        var agentStatus: AgentRunStatus {
            switch self {
            case .succeeded: .succeeded
            case .failed: .failed
            case .cancelled: .cancelled
            }
        }
    }

    let id: UUID
    let startedAt: Date
    let finishedAt: Date
    let status: Status
    let output: String
}

private nonisolated struct LegacyAuditRecord: Sendable {
    enum Kind: Sendable {
        case transportStarted(UUID?)
        case clientInitialized(String?, String?)
        case toolStarted(String)
        case toolFinished(String, Int?, Bool)
        case frameCaptured(String, Int?, String?)
        case frameFailed(String)
        case transportEnded
        case unknown(String)
        case warning(LegacyProvenanceCode)

        var identity: String {
            switch self {
            case .transportStarted: "transportStarted"
            case .clientInitialized: "clientInitialized"
            case .toolStarted: "toolStarted"
            case .toolFinished: "toolFinished"
            case .frameCaptured: "frameCaptured"
            case .frameFailed: "frameFailed"
            case .transportEnded: "transportEnded"
            case .unknown: "unknown"
            case .warning(let code): "warning-\(code.rawValue)"
            }
        }
    }

    let lineNumber: Int
    let timestamp: Date
    let kind: Kind
}

private nonisolated enum LegacyFrameValidation: Sendable {
    case accepted(filename: String, data: Data, digest: String)
    case rejected(LegacyProvenanceCode)
}
