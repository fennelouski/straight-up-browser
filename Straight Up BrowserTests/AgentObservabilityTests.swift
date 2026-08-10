import Foundation
import Testing
@testable import Browser

struct AgentObservabilityTests {
    @Test func hardLimitStopsTheNextOperationAndCreatesAnExplicitLimitStep() async throws {
        let runID = UUID()
        let limits = try AgentExecutionLimits(maximumTurns: 1)
        let ledger = AgentBudgetLedger(
            rootRunID: runID,
            sharedScope: .run(runID),
            sharedLimits: limits,
            startedAt: Date(timeIntervalSince1970: 10)
        )

        let first = await ledger.admit(
            runID: runID,
            charge: try AgentOperationCharge(turns: 1),
            at: Date(timeIntervalSince1970: 11)
        )
        #expect(first.isAdmitted)

        let second = await ledger.admit(
            runID: runID,
            charge: try AgentOperationCharge(turns: 1),
            at: Date(timeIntervalSince1970: 12)
        )
        guard case .limited(let limit) = second else {
            Issue.record("Expected the second turn to be rejected")
            return
        }
        #expect(limit.dimension == .turns)
        #expect(limit.scope == .run(runID))
        #expect(limit.reason == .wouldExceed)
        #expect(limit.current == 1)
        #expect(limit.maximum == 1)

        let step = limit.makeStep(sequence: 4)
        #expect(step.kind == .limit)
        #expect(step.runID == runID)
        #expect(step.redactionState == .metadataOnly)
    }

    @Test func childRunsConsumeTheSharedBudgetAtomically() async throws {
        let root = UUID()
        let firstChild = UUID()
        let secondChild = UUID()
        let groupID = UUID()
        let limits = try AgentExecutionLimits(maximumToolCalls: 1)
        let ledger = AgentBudgetLedger(
            rootRunID: root,
            sharedScope: .runGroup(groupID),
            sharedLimits: limits
        )
        try await ledger.registerRun(runID: firstChild, parentRunID: root, limits: limits)
        try await ledger.registerRun(runID: secondChild, parentRunID: root, limits: limits)
        let charge = try AgentOperationCharge(toolCalls: 1)

        async let first = ledger.admit(runID: firstChild, charge: charge)
        async let second = ledger.admit(runID: secondChild, charge: charge)
        let results = await [first, second]
        #expect(results.filter(\.isAdmitted).count == 1)
        guard let limit = results.compactMap({ result -> AgentLimitResult? in
            if case .limited(let limit) = result { return limit }
            return nil
        }).first else {
            Issue.record("Expected one atomic shared-budget rejection")
            return
        }
        #expect(limit.scope == .runGroup(groupID))
        #expect(limit.dimension == .toolCalls)

        let snapshot = await ledger.snapshot()
        #expect(snapshot.sharedUsage.toolCalls == 1)
        let rootAdmission = await ledger.admit(
            runID: root,
            charge: try AgentOperationCharge(modelResultBytes: 1)
        )
        #expect(!rootAdmission.isAdmitted)
    }

    @Test func elapsedAndEachCountedResourceAreHardCaps() async throws {
        let cases: [(AgentBudgetDimension, AgentExecutionLimits, AgentOperationCharge)] = [
            (.toolCalls, try AgentExecutionLimits(maximumToolCalls: 0), try AgentOperationCharge(toolCalls: 1)),
            (.openPages, try AgentExecutionLimits(maximumOpenPages: 0), try AgentOperationCharge(pageDelta: 1)),
            (.modelResultBytes, try AgentExecutionLimits(maximumModelResultBytes: 0), try AgentOperationCharge(modelResultBytes: 1)),
            (.downloads, try AgentExecutionLimits(maximumDownloads: 0), try AgentOperationCharge(downloads: 1)),
            (.downloadBytes, try AgentExecutionLimits(maximumDownloadBytes: 0), try AgentOperationCharge(downloadBytes: 1)),
            (.artifacts, try AgentExecutionLimits(maximumArtifacts: 0), try AgentOperationCharge(artifacts: 1)),
            (.artifactBytes, try AgentExecutionLimits(maximumArtifactBytes: 0), try AgentOperationCharge(artifactBytes: 1)),
        ]
        for (dimension, limits, charge) in cases {
            let runID = UUID()
            let ledger = AgentBudgetLedger(
                rootRunID: runID,
                sharedScope: .run(runID),
                sharedLimits: limits
            )
            guard case .limited(let limit) = await ledger.admit(runID: runID, charge: charge) else {
                Issue.record("Expected a \(dimension.rawValue) limit")
                continue
            }
            #expect(limit.dimension == dimension)
        }

        let runID = UUID()
        let timed = AgentBudgetLedger(
            rootRunID: runID,
            sharedScope: .run(runID),
            sharedLimits: try AgentExecutionLimits(maximumElapsedMilliseconds: 1_000),
            startedAt: Date(timeIntervalSince1970: 20)
        )
        let result = await timed.admit(
            runID: runID,
            charge: try AgentOperationCharge(),
            at: Date(timeIntervalSince1970: 21)
        )
        guard case .limited(let elapsed) = result else {
            Issue.record("Expected elapsed-time admission to fail")
            return
        }
        #expect(elapsed.dimension == .elapsedTime)
        #expect(elapsed.reason == .elapsed)
    }

    @Test func pageBudgetTracksConcurrentPagesRatherThanLifetimeOpenCount() async throws {
        let runID = UUID()
        let ledger = AgentBudgetLedger(
            rootRunID: runID,
            sharedScope: .run(runID),
            sharedLimits: try AgentExecutionLimits(maximumOpenPages: 1)
        )
        #expect(await ledger.admit(
            runID: runID,
            charge: try AgentOperationCharge(pageDelta: 1)
        ).isAdmitted)
        #expect(await ledger.admit(
            runID: runID,
            charge: try AgentOperationCharge(pageDelta: -1)
        ).isAdmitted)
        #expect(await ledger.admit(
            runID: runID,
            charge: try AgentOperationCharge(pageDelta: 1)
        ).isAdmitted)
        let snapshot = await ledger.snapshot()
        #expect(snapshot.sharedUsage.openPages == 1)
        #expect(snapshot.sharedUsage.peakOpenPages == 1)
    }

    @Test func overflowAndChildBudgetEscalationFailClosed() async throws {
        let root = UUID()
        let ledger = AgentBudgetLedger(
            rootRunID: root,
            sharedScope: .runGroup(UUID()),
            sharedLimits: try AgentExecutionLimits(maximumProviderTokens: Int64.max)
        )
        #expect(await ledger.admit(
            runID: root,
            charge: try AgentOperationCharge(providerTokens: Int64.max)
        ).isAdmitted)
        guard case .limited(let overflow) = await ledger.admit(
            runID: root,
            charge: try AgentOperationCharge(providerTokens: 1)
        ) else {
            Issue.record("Expected overflow to fail closed")
            return
        }
        #expect(overflow.dimension == .providerTokens)
        #expect(overflow.reason == .arithmeticOverflow)

        let child = UUID()
        let finiteParent = AgentBudgetLedger(
            rootRunID: root,
            sharedScope: .runGroup(UUID()),
            sharedLimits: try AgentExecutionLimits(maximumProviderTokens: 100)
        )
        await #expect(throws: AgentExecutionLimitError.limitEscalation(.providerTokens)) {
            try await finiteParent.registerRun(
                runID: child,
                parentRunID: root,
                limits: try AgentExecutionLimits(maximumProviderTokens: nil)
            )
        }
    }

    @Test func cancellationPropagatesAndRecoveryRequiresExplicitResume() async throws {
        let root = UUID()
        let child = UUID()
        let limits = try AgentExecutionLimits()
        let ledger = AgentBudgetLedger(
            rootRunID: root,
            sharedScope: .runGroup(UUID()),
            sharedLimits: limits,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        try await ledger.registerRun(
            runID: child,
            parentRunID: root,
            limits: limits,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let cancellations = try await ledger.cancel(
            runID: root,
            reason: "stop button",
            at: Date(timeIntervalSince1970: 101)
        )
        #expect(Set(cancellations.map(\.runID)) == [root, child])
        guard case .cancelled = await ledger.admit(
            runID: child,
            charge: try AgentOperationCharge(toolCalls: 1)
        ) else {
            Issue.record("Cancelled child admitted more work")
            return
        }

        let fresh = AgentBudgetLedger(
            rootRunID: root,
            sharedScope: .run(root),
            sharedLimits: limits,
            startedAt: Date(timeIntervalSince1970: 200)
        )
        #expect(await fresh.markInterrupted(at: Date(timeIntervalSince1970: 201)) == [root])
        let saved = await fresh.snapshot(at: Date(timeIntervalSince1970: 201))
        let restored = try AgentBudgetLedger(restoring: saved)
        guard case .interrupted = await restored.admit(
            runID: root,
            charge: try AgentOperationCharge(turns: 1),
            at: Date(timeIntervalSince1970: 202)
        ) else {
            Issue.record("Recovered Run auto-resumed")
            return
        }
        try await restored.resume(runID: root)
        #expect(await restored.admit(
            runID: root,
            charge: try AgentOperationCharge(turns: 1),
            at: Date(timeIntervalSince1970: 202)
        ).isAdmitted)
    }

    @Test func unknownProviderUsageIsNeverTreatedAsZero() async throws {
        let runID = UUID()
        let ledger = AgentBudgetLedger(
            rootRunID: runID,
            sharedScope: .run(runID),
            sharedLimits: try AgentExecutionLimits(maximumProviderTokens: 1_000)
        )
        let accounting = await ledger.recordProviderUsage(
            runID: runID,
            providerID: "fixture",
            model: "fixture-1",
            requestID: "request-1",
            usageStepID: UUID(),
            usage: .unknown,
            pricing: nil,
            at: Date(timeIntervalSince1970: 300)
        )

        #expect(accounting.usage.totalTokens == .unknown(.providerDidNotReport))
        #expect(accounting.cost == .unknown(.usageUnknown))
        guard case .limited(let limit) = accounting.admission else {
            Issue.record("Unknown usage bypassed a finite token cap")
            return
        }
        #expect(limit.dimension == .providerTokens)
        #expect(limit.reason == .usageUnknown)
        let next = await ledger.admit(
            runID: runID,
            charge: try AgentOperationCharge(turns: 1)
        )
        #expect(!next.isAdmitted)
    }

    @Test func missingPricingKeepsCostUnknownAndFiniteCostCapFailsClosed() async throws {
        let runID = UUID()
        let ledger = AgentBudgetLedger(
            rootRunID: runID,
            sharedScope: .run(runID),
            sharedLimits: try AgentExecutionLimits(maximumProviderCostMicrounits: 500)
        )
        let usage = AgentModelUsage.reported(
            inputTokens: 800,
            outputTokens: 200,
            totalTokens: 1_000,
            cachedInputTokens: nil
        )
        let accounting = await ledger.recordProviderUsage(
            runID: runID,
            providerID: "fixture",
            model: "fixture-1",
            requestID: "request-2",
            usageStepID: nil,
            usage: usage,
            pricing: nil
        )

        #expect(accounting.usage.totalTokens == .known(1_000))
        #expect(accounting.cost == .unknown(.pricingUnavailable))
        guard case .limited(let limit) = accounting.admission else {
            Issue.record("Unknown cost bypassed a finite cap")
            return
        }
        #expect(limit.dimension == .providerCost)
        #expect(limit.reason == .usageUnknown)
    }

    @Test func costRequiresProviderUsageAndPricingAndLabelsEstimates() throws {
        let exactUsage = AgentNormalizedProviderUsage(
            .reported(
                inputTokens: 1_000_000,
                outputTokens: 500_000,
                totalTokens: 1_500_000,
                cachedInputTokens: 200_000
            )
        )
        let exactPricing = try AgentProviderPricingMetadata(
            source: .userConfigured,
            currencyCode: "USD",
            inputMicrounitsPerMillionTokens: 2_000_000,
            cachedInputMicrounitsPerMillionTokens: 1_000_000,
            outputMicrounitsPerMillionTokens: 4_000_000
        )
        let exact = AgentProviderCostCalculator.calculate(
            usage: exactUsage,
            pricing: exactPricing
        )
        #expect(exact == .available(AgentProviderCost(
            amountMicrounits: 3_800_000,
            currencyCode: "USD",
            confidence: .calculated,
            pricingSource: .userConfigured
        )))

        let estimatedUsage = AgentNormalizedProviderUsage(
            .reported(
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: 2_000_000,
                cachedInputTokens: nil
            )
        )
        let blendedPricing = try AgentProviderPricingMetadata(
            source: .providerPublished,
            currencyCode: "USD",
            estimatedBlendedMicrounitsPerMillionTokens: 3_000_000
        )
        let estimate = AgentProviderCostCalculator.calculate(
            usage: estimatedUsage,
            pricing: blendedPricing
        )
        #expect(estimate == .available(AgentProviderCost(
            amountMicrounits: 6_000_000,
            currencyCode: "USD",
            confidence: .estimated,
            pricingSource: .providerPublished
        )))

        #expect(AgentProviderCostCalculator.calculate(
            usage: exactUsage,
            pricing: nil
        ) == .unknown(.pricingUnavailable))
        #expect(AgentProviderCostCalculator.calculate(
            usage: AgentNormalizedProviderUsage(.unknown),
            pricing: exactPricing
        ) == .unknown(.usageUnknown))
    }

    @Test func reportedProviderUsageLinksToItsRunRequestAndTimelineStep() async throws {
        let runID = UUID()
        let usageStepID = UUID()
        let ledger = AgentBudgetLedger(
            rootRunID: runID,
            sharedScope: .run(runID),
            sharedLimits: try AgentExecutionLimits(
                maximumProviderTokens: 10_000,
                maximumProviderCostMicrounits: 10_000
            )
        )
        let pricing = try AgentProviderPricingMetadata(
            source: .userConfigured,
            currencyCode: "USD",
            inputMicrounitsPerMillionTokens: 1_000_000,
            outputMicrounitsPerMillionTokens: 1_000_000
        )
        let accounting = await ledger.recordProviderUsage(
            runID: runID,
            providerID: "provider-id",
            model: "model-id",
            requestID: "safe-request-id",
            usageStepID: usageStepID,
            usage: .reported(
                inputTokens: 900,
                outputTokens: 100,
                totalTokens: 1_000,
                cachedInputTokens: nil
            ),
            pricing: pricing,
            at: Date(timeIntervalSince1970: 400)
        )

        #expect(accounting.admission.isAdmitted)
        #expect(accounting.link.runID == runID)
        #expect(accounting.link.usageStepID == usageStepID)
        #expect(accounting.link.providerRequestID == "safe-request-id")
        #expect(accounting.link.usage.totalTokens == .known(1_000))
        #expect(accounting.link.cost.knownMicrounits == 1_000)
        let snapshot = await ledger.snapshot()
        #expect(snapshot.sharedUsage.providerTokens == 1_000)
        #expect(snapshot.sharedUsage.providerCostMicrounits == 1_000)
    }

    @Test func metricsAreLocalTypedAndBoundedByAgeRunAndTotalCount() async throws {
        let firstRun = UUID()
        let secondRun = UUID()
        let retention = try AgentMetricRetentionPolicy(
            maximumTotalEvents: 3,
            maximumEventsPerRun: 2,
            maximumAge: 10
        )
        let store = AgentLocalMetricStore(retention: retention)
        let base = Date(timeIntervalSince1970: 1_000)

        try await store.record(.providerLatency(
            runID: firstRun,
            milliseconds: 9,
            providerID: "fixture",
            at: base
        ), now: base)
        try await store.record(.timeToFirstToken(
            runID: firstRun,
            milliseconds: 5,
            providerID: "fixture",
            at: base.addingTimeInterval(1)
        ), now: base.addingTimeInterval(1))
        try await store.record(.toolLatency(
            runID: firstRun,
            milliseconds: 3,
            toolName: "take_snapshot",
            outcome: .succeeded,
            at: base.addingTimeInterval(2)
        ), now: base.addingTimeInterval(2))
        try await store.record(.retry(
            runID: secondRun,
            providerID: "fixture",
            category: .transient,
            at: base.addingTimeInterval(3)
        ), now: base.addingTimeInterval(3))

        var events = await store.events(now: base.addingTimeInterval(3))
        #expect(events.count == 3)
        #expect(events.filter { $0.runID == firstRun }.count == 2)
        #expect(!events.contains { event in
            if case .providerLatency = event.payload { return true }
            return false
        })

        events = await store.events(now: base.addingTimeInterval(20))
        #expect(events.isEmpty)
        #expect(await store.remoteDiagnosticsSettings == .disabled)
    }

    @Test func duplicateRecoveredMetricIsIdempotentAndCancellationStopsRecording() async throws {
        let runID = UUID()
        let eventID = UUID()
        let event = AgentMetricEvent(
            id: eventID,
            runID: runID,
            timestamp: Date(timeIntervalSince1970: 2_000),
            incognito: false,
            payload: .approval(outcome: .approved, waitMilliseconds: 10)
        )
        let store = AgentLocalMetricStore(retention: try AgentMetricRetentionPolicy())
        #expect(try await store.record(event, now: event.timestamp))
        #expect(!(try await store.record(event, now: event.timestamp)))

        let snapshot = await store.snapshot(now: event.timestamp)
        let recovered = try AgentLocalMetricStore(restoring: snapshot)
        #expect(await recovered.events(now: event.timestamp) == [event])

        let task = Task {
            try await recovered.record(.retry(
                runID: runID,
                providerID: "fixture",
                category: .rateLimited,
                at: event.timestamp
            ), now: event.timestamp)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await recovered.events(now: event.timestamp) == [event])
    }

    @Test func incognitoMetricsAreRejectedAndPurgedFromLegacySnapshots() async throws {
        let retained = AgentMetricEvent(
            id: UUID(),
            runID: UUID(),
            timestamp: Date(timeIntervalSince1970: 2_100),
            incognito: false,
            payload: .approval(outcome: .approved, waitMilliseconds: 8)
        )
        let incognito = AgentMetricEvent(
            id: UUID(),
            runID: UUID(),
            timestamp: retained.timestamp,
            incognito: true,
            payload: .toolLatency(
                milliseconds: 4,
                toolName: "take_snapshot",
                outcome: .succeeded
            )
        )
        let retention = try AgentMetricRetentionPolicy()
        let store = AgentLocalMetricStore(retention: retention)

        #expect(!(try await store.record(incognito, now: retained.timestamp)))
        #expect(try await store.record(retained, now: retained.timestamp))
        #expect(await store.events(now: retained.timestamp) == [retained])

        let legacySnapshot = AgentLocalMetricSnapshot(
            retention: retention,
            remoteDiagnosticsSettings: .disabled,
            events: [incognito, retained],
            capturedAt: retained.timestamp
        )
        let recovered = try AgentLocalMetricStore(restoring: legacySnapshot)
        #expect(await recovered.events(now: retained.timestamp) == [retained])
        #expect(await recovered.snapshot(now: retained.timestamp).events == [retained])
    }

    @Test func runSummaryAndDashboardPreserveUnknownUsageAndResourcePeaks() async throws {
        let knownRun = UUID()
        let unknownRun = UUID()
        let store = AgentLocalMetricStore(retention: try AgentMetricRetentionPolicy())
        let at = Date(timeIntervalSince1970: 3_000)
        try await store.record(.providerLatency(
            runID: knownRun,
            milliseconds: 20,
            providerID: "provider",
            at: at
        ), now: at)
        try await store.record(.timeToFirstToken(
            runID: knownRun,
            milliseconds: 4,
            providerID: "provider",
            at: at
        ), now: at)
        try await store.record(.resourcePeak(
            runID: knownRun,
            resource: .openPages,
            value: 3,
            at: at
        ), now: at)
        try await store.record(.providerUsage(AgentProviderUsageLink(
            runID: knownRun,
            providerID: "provider",
            model: "model",
            providerRequestID: "request",
            usageStepID: nil,
            observedAt: at,
            usage: AgentNormalizedProviderUsage(.reported(
                inputTokens: 10,
                outputTokens: 5,
                totalTokens: 15,
                cachedInputTokens: nil
            )),
            cost: .available(AgentProviderCost(
                amountMicrounits: 7,
                currencyCode: "USD",
                confidence: .estimated,
                pricingSource: .providerPublished
            ))
        ), incognito: false), now: at)
        try await store.record(.providerUsage(AgentProviderUsageLink(
            runID: unknownRun,
            providerID: "provider",
            model: "model",
            providerRequestID: "request-2",
            usageStepID: nil,
            observedAt: at,
            usage: AgentNormalizedProviderUsage(.unknown),
            cost: .unknown(.usageUnknown)
        ), incognito: false), now: at)

        let dashboard = await store.dashboard(now: at)
        let known = try #require(dashboard.runs.first { $0.runID == knownRun })
        #expect(known.providerLatency.sampleCount == 1)
        #expect(known.providerLatency.averageMilliseconds == 20)
        #expect(known.timeToFirstToken.averageMilliseconds == 4)
        #expect(known.resourcePeaks[.openPages] == 3)
        #expect(known.providerTokens == .known(15))
        #expect(known.providerCost == .known(
            amountMicrounits: 7,
            currencyCode: "USD",
            containsEstimates: true
        ))

        let unknown = try #require(dashboard.runs.first { $0.runID == unknownRun })
        #expect(unknown.providerTokens == .unknown)
        #expect(unknown.providerCost == .unknown)
        #expect(dashboard.aggregate.providerTokens == .unknown)
        #expect(dashboard.aggregate.providerCost == .unknown)
    }

    @Test func metricCollectionCannotCauseANonIdempotentToolRetry() {
        let guardrail = AgentToolRetryGuard()
        #expect(guardrail.decision(
            idempotency: .nonIdempotent,
            reason: .metricSampling,
            sideEffectCommitted: false
        ) == .denied(.metricsNeverJustifyRetry))
        #expect(guardrail.decision(
            idempotency: .nonIdempotent,
            reason: .ambiguousTimeout,
            sideEffectCommitted: false
        ) == .denied(.ambiguousNonIdempotentOutcome))
        #expect(guardrail.decision(
            idempotency: .idempotent,
            reason: .transientFailure,
            sideEffectCommitted: false
        ) == .allowed)
        #expect(guardrail.decision(
            idempotency: .idempotent,
            reason: .transientFailure,
            sideEffectCommitted: true
        ) == .denied(.sideEffectAlreadyCommitted))
    }

    @Test func defaultDiagnosticPreviewOmitsContentFullURLsAndCredentials() throws {
        let runID = UUID()
        let promptID = UUID()
        let pageID = UUID()
        let incognitoID = UUID()
        let secret = "super-private-token"
        let request = diagnosticRequest(
            runID: runID,
            configuration: [
                "provider": .string("fixture"),
                "apiKey": .string(secret),
                "nested": .object(["password": .string("hunter2")]),
            ],
            errors: [
                AgentDiagnosticErrorInput(
                    id: UUID(),
                    runID: runID,
                    category: .transport,
                    code: "HTTP_FAILURE",
                    message: "Authorization: Bearer abc.def.ghi GET https://example.test/path?q=secret#fragment",
                    sourceURL: "https://user:pass@example.test/private?q=secret#fragment",
                    incognito: false
                ),
            ],
            content: [
                AgentDiagnosticContentInput(
                    id: promptID,
                    runID: runID,
                    kind: .prompt,
                    text: "prompt body \(secret)",
                    incognito: false
                ),
                AgentDiagnosticContentInput(
                    id: pageID,
                    runID: runID,
                    kind: .pageBody,
                    text: "private page/file/MCP body",
                    incognito: false
                ),
                AgentDiagnosticContentInput(
                    id: incognitoID,
                    runID: runID,
                    kind: .screenshotDescription,
                    text: "incognito screenshot content",
                    incognito: true
                ),
            ],
            configuredSecrets: [secret, "hunter2"]
        )

        let preview = try AgentObservabilityDiagnosticGenerator().preview(request: request)
        let text = String(decoding: preview.jsonData, as: UTF8.self)
        #expect(preview.manifest.includedContentCount == 0)
        #expect(preview.manifest.omittedContentCount == 3)
        #expect(preview.manifest.incognitoContentIncluded == false)
        #expect(!text.contains("prompt body"))
        #expect(!text.contains("private page/file/MCP body"))
        #expect(!text.contains("incognito screenshot content"))
        #expect(!text.contains(secret))
        #expect(!text.contains("hunter2"))
        #expect(!text.localizedCaseInsensitiveContains("authorization"))
        #expect(!text.localizedCaseInsensitiveContains("bearer"))
        #expect(!text.contains("apiKey"))
        #expect(!text.contains("password"))
        #expect(!text.contains("/private"))
        #expect(!text.contains("q=secret"))
        #expect(!text.contains("#fragment"))
        #expect(text.contains("https://example.test"))
        #expect(preview.safetyFindings.isEmpty)
    }

    @Test func explicitlySelectedNonIncognitoContentIsBoundedAndStillScrubbed() throws {
        let runID = UUID()
        let selected = UUID()
        let incognito = UUID()
        let secret = "configured-secret-value"
        let request = diagnosticRequest(
            runID: runID,
            content: [
                AgentDiagnosticContentInput(
                    id: selected,
                    runID: runID,
                    kind: .fileBody,
                    text: "Chosen text \(secret) from https://example.test/private?q=token",
                    incognito: false
                ),
                AgentDiagnosticContentInput(
                    id: incognito,
                    runID: runID,
                    kind: .mcpBody,
                    text: "Never include incognito MCP content",
                    incognito: true
                ),
            ],
            configuredSecrets: [secret]
        )
        let options = AgentDiagnosticPrivacyOptions(
            explicitContentConsent: true,
            selectedContentIDs: [selected, incognito],
            selectedErrorMessageIDs: []
        )
        let preview = try AgentObservabilityDiagnosticGenerator(
            limits: try AgentDiagnosticBundleLimits(maximumContentTextBytesPerItem: 24)
        ).preview(request: request, options: options)
        let text = String(decoding: preview.jsonData, as: UTF8.self)

        #expect(preview.manifest.includedContentCount == 1)
        #expect(preview.manifest.incognitoContentIncluded == false)
        #expect(text.contains("Chosen text"))
        #expect(text.contains("[truncated]"))
        #expect(!text.contains(secret))
        #expect(!text.contains("/private"))
        #expect(!text.contains("q=token"))
        #expect(!text.contains("Never include incognito"))
    }

    @Test func contentSelectionWithoutExplicitConsentIsRejected() throws {
        let content = AgentDiagnosticContentInput(
            id: UUID(),
            runID: UUID(),
            kind: .prompt,
            text: "private",
            incognito: false
        )
        let request = diagnosticRequest(runID: content.runID, content: [content])
        #expect(throws: AgentDiagnosticBundleError.explicitContentConsentRequired) {
            try AgentObservabilityDiagnosticGenerator().preview(
                request: request,
                options: AgentDiagnosticPrivacyOptions(
                    explicitContentConsent: false,
                    selectedContentIDs: [content.id],
                    selectedErrorMessageIDs: []
                )
            )
        }
    }

    @Test func diagnosticExportReturnsAReceiptOnlyAfterWriterSuccess() throws {
        let preview = try AgentObservabilityDiagnosticGenerator().preview(
            request: diagnosticRequest(runID: UUID())
        )
        let destination = URL(fileURLWithPath: "/diagnostics/bundle.json")

        #expect(throws: InjectedDiagnosticFailure.unavailable) {
            try AgentObservabilityDiagnosticExporter(writer: FailingDiagnosticWriter()).export(
                preview,
                to: destination
            )
        }
        let writer = RecordingDiagnosticWriter()
        let receipt = try AgentObservabilityDiagnosticExporter(writer: writer).export(
            preview,
            to: destination
        )
        #expect(receipt.destination == destination)
        #expect(receipt.byteCount == preview.jsonData.count)
        #expect(receipt.sha256 == preview.sha256)
        #expect(writer.writes == [preview.jsonData])
    }

    private func diagnosticRequest(
        runID: UUID,
        configuration: [String: JSONValue] = ["provider": .string("fixture")],
        errors: [AgentDiagnosticErrorInput] = [],
        content: [AgentDiagnosticContentInput] = [],
        configuredSecrets: [String] = []
    ) -> AgentObservabilityDiagnosticRequest {
        AgentObservabilityDiagnosticRequest(
            versions: AgentDiagnosticVersionInfo(
                appVersion: "2.0.0",
                buildVersion: "200",
                operatingSystem: "macOS",
                architecture: "arm64",
                agentSchemaVersion: 1
            ),
            configuration: configuration,
            timeline: [AgentDiagnosticTimelineInput(
                runID: runID,
                parentRunID: nil,
                entryPoint: .attended,
                status: .failed,
                startedAt: Date(timeIntervalSince1970: 1),
                finishedAt: Date(timeIntervalSince1970: 2),
                targetURL: "https://example.test/private?q=secret#fragment",
                incognito: false
            )],
            metricEvents: [],
            errors: errors,
            content: content,
            configuredSecrets: configuredSecrets,
            generatedAt: Date(timeIntervalSince1970: 4_000)
        )
    }
}

private enum InjectedDiagnosticFailure: Error {
    case unavailable
}

private final class FailingDiagnosticWriter: AgentDiagnosticBundleWriting, @unchecked Sendable {
    func write(_ data: Data, to destination: URL) throws {
        throw InjectedDiagnosticFailure.unavailable
    }
}

private final class RecordingDiagnosticWriter: AgentDiagnosticBundleWriting, @unchecked Sendable {
    private(set) var writes: [Data] = []

    func write(_ data: Data, to destination: URL) throws {
        writes.append(data)
    }
}
