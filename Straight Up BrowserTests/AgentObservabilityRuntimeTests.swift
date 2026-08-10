import Foundation
import Testing
@testable import Browser

@Suite("Agent observability runtime")
struct AgentObservabilityRuntimeTests {
    @Test("Configured hard limits stop the next operation and persist a local limit metric")
    func hardLimitAndMetricPersistence() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(1, forKey: AgentObservabilitySettings.Key.maximumTurns)
        fixture.defaults.set(true, forKey: AgentObservabilitySettings.Key.localMetricsEnabled)
        let runtime = AgentObservabilityRuntime(
            baseDirectory: fixture.baseURL,
            defaultsSuiteName: fixture.suiteName
        )
        let meter = AgentRunMeter(
            runID: UUID(),
            taskDefinitionID: nil,
            incognito: false,
            limits: AgentObservabilitySettings.executionLimits(defaults: fixture.defaults),
            observability: runtime
        )

        #expect(await meter.admitTurn().isAdmitted)
        let second = await meter.admitTurn()
        guard case .limited(let limit) = second else {
            Issue.record("Expected the second turn to be limited")
            return
        }
        #expect(limit.dimension == .turns)
        #expect(limit.reason == .wouldExceed)
        #expect(await runtime.events().contains { event in
            if case .limit(let dimension, let reason) = event.payload {
                return dimension == .turns && reason == .wouldExceed
            }
            return false
        })

        let file = fixture.baseURL.appendingPathComponent(
            "agent/observability/metrics-v1.json"
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("Restoring legacy metrics purges Incognito events from memory and disk")
    func legacyIncognitoMetricsArePurgedOnRestore() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let capturedAt = Date(
            timeIntervalSince1970: floor(Date().timeIntervalSince1970)
        )
        let retained = AgentMetricEvent(
            runID: UUID(),
            timestamp: capturedAt,
            incognito: false,
            payload: .approval(outcome: .approved, waitMilliseconds: 1)
        )
        let incognito = AgentMetricEvent(
            runID: UUID(),
            timestamp: capturedAt,
            incognito: true,
            payload: .toolLatency(
                milliseconds: 2,
                toolName: "take_snapshot",
                outcome: .succeeded
            )
        )
        let snapshot = AgentLocalMetricSnapshot(
            retention: try AgentMetricRetentionPolicy(),
            remoteDiagnosticsSettings: .disabled,
            events: [retained, incognito],
            capturedAt: capturedAt
        )
        let file = fixture.baseURL.appendingPathComponent(
            "agent/observability/metrics-v1.json"
        )
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: file, options: .atomic)

        let runtime = AgentObservabilityRuntime(
            baseDirectory: fixture.baseURL,
            defaultsSuiteName: fixture.suiteName
        )
        #expect(await runtime.events() == [retained])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var persisted: AgentLocalMetricSnapshot? = nil
        for _ in 0..<100 {
            persisted = try? decoder.decode(
                AgentLocalMetricSnapshot.self,
                from: Data(contentsOf: file)
            )
            if persisted?.events == [retained] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(persisted?.events == [retained])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("A finite provider-token budget fails closed when usage is unknown")
    func unknownProviderUsageFailsClosed() async throws {
        let limits = try AgentExecutionLimits(maximumProviderTokens: 10)
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runtime = AgentObservabilityRuntime(
            baseDirectory: fixture.baseURL,
            defaultsSuiteName: fixture.suiteName
        )
        let meter = AgentRunMeter(
            runID: UUID(),
            taskDefinitionID: nil,
            incognito: false,
            limits: limits,
            observability: runtime
        )
        let accounting = await meter.recordProviderUsage(
            providerID: "fixture",
            model: "model",
            requestID: "request",
            usageStepID: nil,
            usage: .unknown
        )
        guard case .limited(let limit) = accounting.admission else {
            Issue.record("Expected unknown finite usage to fail closed")
            return
        }
        #expect(limit.dimension == .providerTokens)
        #expect(limit.reason == .usageUnknown)
    }

    @Test("Changing metric retention prunes local history immediately")
    func retentionChangesApplyWithoutRelaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: AgentObservabilitySettings.Key.localMetricsEnabled)
        fixture.defaults.set(30, forKey: AgentObservabilitySettings.Key.metricRetentionDays)
        let runtime = AgentObservabilityRuntime(
            baseDirectory: fixture.baseURL,
            defaultsSuiteName: fixture.suiteName
        )
        await runtime.record(.providerLatency(
            runID: UUID(),
            milliseconds: 10,
            providerID: "fixture",
            at: Date().addingTimeInterval(-2 * 86_400)
        ))
        let before = await runtime.events()
        #expect(before.count == 1)

        fixture.defaults.set(1, forKey: AgentObservabilitySettings.Key.metricRetentionDays)
        await runtime.settingsChanged()

        let after = await runtime.events()
        #expect(after.isEmpty)
    }

    @Test("Every editable budget setting maps to the runtime limit snapshot")
    func settingsMapToExecutionLimits() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(7, forKey: AgentObservabilitySettings.Key.maximumTurns)
        fixture.defaults.set(9, forKey: AgentObservabilitySettings.Key.maximumToolCalls)
        fixture.defaults.set(11, forKey: AgentObservabilitySettings.Key.maximumWallMinutes)
        fixture.defaults.set(12_345, forKey: AgentObservabilitySettings.Key.maximumProviderTokens)
        fixture.defaults.set(
            2_500_000,
            forKey: AgentObservabilitySettings.Key.maximumProviderCostMicrounits
        )
        fixture.defaults.set(3, forKey: AgentObservabilitySettings.Key.maximumOpenPages)
        fixture.defaults.set(4, forKey: AgentObservabilitySettings.Key.maximumModelResultMiB)
        fixture.defaults.set(5, forKey: AgentObservabilitySettings.Key.maximumDownloads)
        fixture.defaults.set(64, forKey: AgentObservabilitySettings.Key.maximumDownloadMiB)
        fixture.defaults.set(6, forKey: AgentObservabilitySettings.Key.maximumArtifacts)
        fixture.defaults.set(32, forKey: AgentObservabilitySettings.Key.maximumArtifactMiB)

        let limits = AgentObservabilitySettings.executionLimits(defaults: fixture.defaults)
        #expect(limits.maximumTurns == 7)
        #expect(limits.maximumToolCalls == 9)
        #expect(limits.maximumElapsedMilliseconds == 11 * 60_000)
        #expect(limits.maximumProviderTokens == 12_345)
        #expect(limits.maximumProviderCostMicrounits == 2_500_000)
        #expect(limits.maximumOpenPages == 3)
        #expect(limits.maximumModelResultBytes == 4 * 1_048_576)
        #expect(limits.maximumDownloads == 5)
        #expect(limits.maximumDownloadBytes == 64 * 1_048_576)
        #expect(limits.maximumArtifacts == 6)
        #expect(limits.maximumArtifactBytes == 32 * 1_048_576)
    }

    @Test("Completed tool arguments cannot bypass the model-result byte cap")
    func completedToolArgumentsAreMeteredBeforeEffect() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runtime = AgentObservabilityRuntime(
            baseDirectory: fixture.baseURL,
            defaultsSuiteName: fixture.suiteName
        )
        let meter = AgentRunMeter(
            runID: UUID(),
            taskDefinitionID: nil,
            incognito: false,
            limits: try AgentExecutionLimits(maximumModelResultBytes: 8),
            observability: runtime
        )
        let call = AgentToolCall(id: "large-arguments", index: 0, name: "write_file")
        var tracker = AgentModelResultByteTracker()
        let bytes = tracker.bytesToCharge(for: .toolCallCompleted(
            call: call,
            arguments: .valid(.object(["content": .string(String(repeating: "x", count: 64))]))
        ))
        let admission = await meter.admitModelResult(bytes: bytes)
        var effectRan = false
        if admission.isAdmitted { effectRan = true }

        guard case .limited(let limit) = admission else {
            Issue.record("Expected completed tool arguments to hit the byte cap")
            return
        }
        #expect(bytes > 8)
        #expect(limit.dimension == .modelResultBytes)
        #expect(!effectRan)

        var streamedTracker = AgentModelResultByteTracker()
        #expect(streamedTracker.bytesToCharge(for: .toolCallArgumentsDelta(
            id: call.id,
            delta: #"{"content":"xxxxxxxx"}"#
        )) > 0)
        #expect(streamedTracker.bytesToCharge(for: .toolCallCompleted(
            call: call,
            arguments: .valid(.object(["content": .string("xxxxxxxx")]))
        )) == 0)
    }

    @Test("Artifact count and byte reservations stop before a second effect")
    func artifactReservationsStopBeforeEffect() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runtime = AgentObservabilityRuntime(
            baseDirectory: fixture.baseURL,
            defaultsSuiteName: fixture.suiteName
        )
        let meter = AgentRunMeter(
            runID: UUID(),
            taskDefinitionID: nil,
            incognito: false,
            limits: try AgentExecutionLimits(
                maximumArtifacts: 1,
                maximumArtifactBytes: 5
            ),
            observability: runtime
        )

        #expect(await meter.admitArtifact(bytes: 5).isAdmitted)
        let second = await meter.admitArtifact(bytes: 1)
        var secondEffectRan = false
        if second.isAdmitted { secondEffectRan = true }
        guard case .limited(let limit) = second else {
            Issue.record("Expected the second artifact reservation to be limited")
            return
        }
        #expect(limit.dimension == .artifacts)
        #expect(!secondEffectRan)
    }

    @Test("Unknown download size reserves the full cap and zero cap rejects")
    func downloadReservationsFailClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runtime = AgentObservabilityRuntime(
            baseDirectory: fixture.baseURL,
            defaultsSuiteName: fixture.suiteName
        )
        let meter = AgentRunMeter(
            runID: UUID(),
            taskDefinitionID: nil,
            incognito: false,
            limits: try AgentExecutionLimits(
                maximumDownloads: 2,
                maximumDownloadBytes: 100
            ),
            observability: runtime
        )
        #expect(await meter.admitDownload(runID: meter.runID, reservedBytes: 100).isAdmitted)
        let second = await meter.admitDownload(runID: meter.runID, reservedBytes: 100)
        guard case .limited(let byteLimit) = second else {
            Issue.record("Expected a second unknown-size download to exceed reserved bytes")
            return
        }
        #expect(byteLimit.dimension == .downloadBytes)

        let zeroMeter = AgentRunMeter(
            runID: UUID(),
            taskDefinitionID: nil,
            incognito: false,
            limits: try AgentExecutionLimits(
                maximumDownloads: 1,
                maximumDownloadBytes: 0
            ),
            observability: runtime
        )
        let zero = await zeroMeter.admitDownload(
            runID: zeroMeter.runID,
            reservedBytes: 1
        )
        guard case .limited(let zeroLimit) = zero else {
            Issue.record("Expected a zero-byte ceiling to reject before download")
            return
        }
        #expect(zeroLimit.dimension == .downloadBytes)
    }

    private struct Fixture {
        let baseURL: URL
        let defaults: UserDefaults
        let suiteName: String

        init() throws {
            baseURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("agent-observability-runtime-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
            suiteName = "AgentObservabilityRuntimeTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: baseURL)
        }
    }
}
