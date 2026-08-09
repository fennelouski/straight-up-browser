import Foundation
import Testing
@testable import Browser

struct AgentScheduledTaskEngineTests {
    @Test func definitionRoundTripsTheSavedExecutionConfigurationWithoutSecretFields() throws {
        let definition = try makeDefinition()

        let data = try JSONEncoder().encode(definition)
        let decoded = try JSONDecoder().decode(AgentTaskDefinition.self, from: data)

        #expect(decoded == definition)
        #expect(decoded.execution.provider.model == "saved-model")
        #expect(decoded.execution.provider.endpointIdentity == "https://models.example/v1")
        #expect(decoded.execution.browserScope.session == .container(
            UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        ))
        #expect(decoded.execution.mcpConnectionIDs == [
            UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!,
        ])
        #expect(decoded.execution.coworkRootID ==
            UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!)

        let encoded = String(decoding: data, as: UTF8.self).lowercased()
        #expect(!encoded.contains("apikey"))
        #expect(!encoded.contains("bookmarkdata"))
        #expect(!encoded.contains("bearertoken"))
    }

    @Test func launchRecoveryHonorsEveryCatchUpPolicyAndStableOccurrenceIDs() throws {
        let anchor = try date("2026-01-01T00:00:00Z")
        let lastEvaluation = try date("2026-01-01T00:30:00Z")
        let launch = try date("2026-01-01T04:30:00Z")
        let third = try date("2026-01-01T03:00:00Z")
        let fourth = try date("2026-01-01T04:00:00Z")
        let fifth = try date("2026-01-01T05:00:00Z")
        let task = try makeDefinition(
            schedule: .interval(everySeconds: 3_600, anchor: anchor),
            catchUpPolicy: .runAll(maximumOccurrences: 2)
        )

        let allPlan = try AgentTaskSchedulePlanner.recoveryPlan(
            for: task,
            after: lastEvaluation,
            through: launch
        )
        #expect(allPlan.runnable.map(\.scheduledAt) == [third, fourth])
        #expect(allPlan.skippedCount == 2)
        #expect(allPlan.nextScheduledAt == fifth)

        let repeatedPlan = try AgentTaskSchedulePlanner.recoveryPlan(
            for: task,
            after: lastEvaluation,
            through: launch
        )
        #expect(repeatedPlan.runnable.map(\.id) == allPlan.runnable.map(\.id))

        var latestTask = task
        latestTask.catchUpPolicy = .runLatest
        let latest = try AgentTaskSchedulePlanner.recoveryPlan(
            for: latestTask,
            after: lastEvaluation,
            through: launch
        )
        #expect(latest.runnable.map(\.scheduledAt) == [fourth])
        #expect(latest.skippedCount == 3)

        var skipTask = task
        skipTask.catchUpPolicy = .skip
        let skipped = try AgentTaskSchedulePlanner.recoveryPlan(
            for: skipTask,
            after: lastEvaluation,
            through: launch
        )
        #expect(skipped.runnable.isEmpty)
        #expect(skipped.skippedCount == 4)

        let alreadyRecorded = Set(latest.runnable.map(\.id))
        let deduplicated = try AgentTaskSchedulePlanner.recoveryPlan(
            for: latestTask,
            after: lastEvaluation,
            through: launch,
            existingOccurrenceIDs: alreadyRecorded
        )
        #expect(deduplicated.runnable.isEmpty)
        #expect(deduplicated.alreadyRecordedCount == 1)
    }

    @Test func dailyScheduleMakesDSTGapAndOverlapBehaviorExplicit() throws {
        let afterSpringOccurrence = try date("2026-03-28T02:00:00Z")
        var skipGap = try makeDefinition()
        skipGap.schedule = .daily(hour: 2, minute: 30)
        skipGap.daylightSavingPolicy = AgentTaskDaylightSavingPolicy(
            nonexistentTime: .skipOccurrence,
            repeatedTime: .firstOccurrence
        )
        let afterGap = try AgentTaskSchedulePlanner.nextOccurrence(
            after: afterSpringOccurrence,
            definition: skipGap
        )
        #expect(afterGap == tryDate("2026-03-30T00:30:00Z"))

        var advanceGap = skipGap
        advanceGap.daylightSavingPolicy.nonexistentTime = .nextValidTime
        let advanced = try AgentTaskSchedulePlanner.nextOccurrence(
            after: afterSpringOccurrence,
            definition: advanceGap
        )
        #expect(advanced == tryDate("2026-03-29T01:00:00Z"))

        let beforeRepeatedTime = try date("2026-10-24T23:00:00Z")
        var firstRepeated = skipGap
        firstRepeated.daylightSavingPolicy.repeatedTime = .firstOccurrence
        let first = try AgentTaskSchedulePlanner.nextOccurrence(
            after: beforeRepeatedTime,
            definition: firstRepeated
        )
        #expect(first == tryDate("2026-10-25T00:30:00Z"))

        var lastRepeated = firstRepeated
        lastRepeated.daylightSavingPolicy.repeatedTime = .lastOccurrence
        let last = try AgentTaskSchedulePlanner.nextOccurrence(
            after: beforeRepeatedTime,
            definition: lastRepeated
        )
        #expect(last == tryDate("2026-10-25T01:30:00Z"))
        #expect(last.timeIntervalSince(first) == 3_600)
    }

    @Test func definitionValidationRejectsUnboundedOrUnsafeScheduledAuthority() throws {
        let valid = try makeDefinition()
        let data = try JSONEncoder().encode(valid)
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["timeZoneIdentifier"] = "Not/A_TimeZone"
        let invalidTimeZoneData = try JSONSerialization.data(withJSONObject: object)
        let invalidTimeZone = try JSONDecoder().decode(
            AgentTaskDefinition.self,
            from: invalidTimeZoneData
        )
        #expect(invalidTimeZone.validationIssues().contains {
            $0.code == .invalidTimeZone
        })

        var incognito = valid
        incognito.execution.browserScope.session = .incognito
        #expect(incognito.validationIssues().contains {
            $0.code == .incognitoSessionUnsupported
        })

        var unsafeEndpoint = valid
        unsafeEndpoint.execution.provider.endpointIdentity =
            "https://token:secret@models.example/v1?api_key=secret"
        #expect(unsafeEndpoint.validationIssues().contains {
            $0.code == .unsafeEndpointIdentity
        })

        var invalidBudgets = valid
        invalidBudgets.budgets.maximumToolCalls = 0
        #expect(invalidBudgets.validationIssues().contains {
            $0.code == .invalidBudgets
        })
    }

    @Test func serializeQueuesExactlyOnceAndPromotesAfterCompletion() async throws {
        let issuedAt = try date("2026-01-01T01:00:00Z")
        var definition = try makeDefinition(
            schedule: .interval(
                everySeconds: 3_600,
                anchor: try date("2026-01-01T00:00:00Z")
            )
        )
        definition.concurrencyPolicy = .serialize
        let firstOccurrence = AgentTaskOccurrence(
            definition: definition,
            scheduledAt: issuedAt,
            source: .timer
        )
        let secondOccurrence = AgentTaskOccurrence(
            definition: definition,
            scheduledAt: try date("2026-01-01T02:00:00Z"),
            source: .timer
        )
        let engine = try AgentScheduledTaskEngine()
        try await engine.register(definition)

        let first = await engine.admit(
            firstOccurrence,
            browserAvailability: .sanctionedHiddenWindow,
            at: issuedAt
        )
        guard case .start(let firstDirective) = first else {
            Issue.record("The first occurrence should start")
            return
        }
        #expect(firstDirective.providerSnapshot.model == "saved-model")
        #expect(firstDirective.kind == .execute(window: .hidden))
        #expect(firstDirective.deadline.timeIntervalSince(issuedAt) == 300)

        let queued = await engine.admit(
            secondOccurrence,
            browserAvailability: .sanctionedHiddenWindow,
            at: try date("2026-01-01T02:00:00Z")
        )
        #expect(queued == .queued(occurrenceID: secondOccurrence.id, position: 1))

        let duplicate = await engine.admit(
            firstOccurrence,
            browserAvailability: .sanctionedHiddenWindow,
            at: issuedAt
        )
        guard case .duplicate(let duplicateRecord) = duplicate else {
            Issue.record("The same occurrence ID must never receive a second run")
            return
        }
        #expect(duplicateRecord.state.runID == firstDirective.runID)

        let completion = try await engine.complete(
            taskID: definition.id,
            occurrenceID: firstOccurrence.id,
            runID: firstDirective.runID,
            outcome: .succeeded,
            browserAvailability: .sanctionedHiddenWindow,
            at: try date("2026-01-01T02:05:00Z")
        )
        guard case .start(let promoted) = completion.followUpAdmissions.first else {
            Issue.record("The serialized occurrence should start after completion")
            return
        }
        #expect(promoted.occurrence.id == secondOccurrence.id)
        #expect(promoted.definitionSnapshot.execution.provider.model == "saved-model")
    }

    @Test func skipAndBoundedQueueOverlapPoliciesRecordHonestOutcomes() async throws {
        let firstDate = try date("2026-01-01T01:00:00Z")
        let secondDate = try date("2026-01-01T02:00:00Z")
        let thirdDate = try date("2026-01-01T03:00:00Z")

        var skipDefinition = try makeDefinition()
        skipDefinition.concurrencyPolicy = .skipOverlap
        let skipEngine = try AgentScheduledTaskEngine()
        try await skipEngine.register(skipDefinition)
        let skipFirst = AgentTaskOccurrence(
            definition: skipDefinition,
            scheduledAt: firstDate,
            source: .timer
        )
        let skipSecond = AgentTaskOccurrence(
            definition: skipDefinition,
            scheduledAt: secondDate,
            source: .timer
        )
        guard case .start = await skipEngine.admit(
            skipFirst,
            browserAvailability: .visibleWindow,
            at: firstDate
        ) else {
            Issue.record("First skip-policy occurrence should start")
            return
        }
        guard case .skipped(let skippedRecord) = await skipEngine.admit(
            skipSecond,
            browserAvailability: .visibleWindow,
            at: secondDate
        ) else {
            Issue.record("Overlapping skip-policy occurrence should be recorded")
            return
        }
        #expect(skippedRecord.state == .skipped(reason: .overlapPolicy, at: secondDate))

        var queueDefinition = try makeDefinition()
        queueDefinition.concurrencyPolicy = .queue(maxPendingOccurrences: 1)
        let queueEngine = try AgentScheduledTaskEngine()
        try await queueEngine.register(queueDefinition)
        let occurrences = [firstDate, secondDate, thirdDate].map {
            AgentTaskOccurrence(
                definition: queueDefinition,
                scheduledAt: $0,
                source: .timer
            )
        }
        guard case .start = await queueEngine.admit(
            occurrences[0],
            browserAvailability: .visibleWindow,
            at: firstDate
        ) else {
            Issue.record("First queued-policy occurrence should start")
            return
        }
        #expect(await queueEngine.admit(
            occurrences[1],
            browserAvailability: .visibleWindow,
            at: secondDate
        ) == .queued(occurrenceID: occurrences[1].id, position: 1))
        guard case .skipped(let overflow) = await queueEngine.admit(
            occurrences[2],
            browserAvailability: .visibleWindow,
            at: thirdDate
        ) else {
            Issue.record("Queue overflow should be recorded as skipped")
            return
        }
        #expect(overflow.state == .skipped(reason: .queueCapacityReached, at: thirdDate))
    }

    @Test func unavailableBrowserProducesDurableBlockedRunInsteadOfFallback() async throws {
        let now = try date("2026-01-01T01:00:00Z")
        let definition = try makeDefinition()
        let occurrence = AgentTaskOccurrence(
            definition: definition,
            scheduledAt: now,
            source: .timer
        )
        let engine = try AgentScheduledTaskEngine()
        try await engine.register(definition)

        let admission = await engine.admit(
            occurrence,
            browserAvailability: .unavailable,
            at: now
        )
        guard case .blocked(let directive) = admission else {
            Issue.record("No browser window must produce a blocked directive")
            return
        }
        #expect(directive.kind == .recordBlocked(reason: .noBrowserWindow))
        let materialized = directive.makeRun(toolCatalogVersion: 1)
        #expect(materialized.run.status == .failed)
        #expect(materialized.run.entryPoint == .scheduled)
        #expect(materialized.run.failureCategory == "noBrowserWindow")
        #expect(materialized.run.configuration.provider?.model == "saved-model")

        let state = try #require(await engine.runtimeState(taskID: definition.id))
        #expect(state.occurrenceRecords.first?.state == .blocked(
            runID: directive.runID,
            reason: .noBrowserWindow,
            at: now
        ))
        #expect(await engine.pendingNotifications().contains {
            if case .failure(.noBrowserWindow) = $0.kind { return true }
            return false
        })
    }

    @Test func unattendedApprovalBecomesPersistedHandoffNotification() async throws {
        let now = try date("2026-01-01T01:00:00Z")
        let definition = try makeDefinition()
        let occurrence = AgentTaskOccurrence(
            definition: definition,
            scheduledAt: now,
            source: .timer
        )
        let engine = try AgentScheduledTaskEngine()
        try await engine.register(definition)
        guard case .start(let directive) = await engine.admit(
            occurrence,
            browserAvailability: .sanctionedHiddenWindow,
            at: now
        ) else {
            Issue.record("Occurrence should start")
            return
        }
        let requestID = UUID(uuidString: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")!
        let expiry = now.addingTimeInterval(600)

        let notification = try await engine.recordWaitingForHuman(
            taskID: definition.id,
            occurrenceID: occurrence.id,
            runID: directive.runID,
            approvalRequestID: requestID,
            approvalExpiresAt: expiry,
            at: now.addingTimeInterval(5)
        )
        #expect(notification?.kind == .waitingForHuman(approvalRequestID: requestID))
        #expect(notification?.delivery == .pending)
        let encoded = try JSONEncoder().encode(await engine.snapshot())
        let restored = try AgentScheduledTaskEngine(
            snapshot: JSONDecoder().decode(AgentTaskSchedulerSnapshot.self, from: encoded)
        )
        let restoredState = try #require(await restored.runtimeState(taskID: definition.id))
        #expect(restoredState.occurrenceRecords.first?.state == .waitingForHuman(
            runID: directive.runID,
            startedAt: now,
            deadline: now.addingTimeInterval(300),
            approvalRequestID: requestID,
            approvalExpiresAt: expiry
        ))
        #expect(await restored.pendingNotifications().map(\.id) == [notification?.id].compactMap { $0 })

        try await restored.resumeAfterHumanHandoff(
            taskID: definition.id,
            occurrenceID: occurrence.id,
            runID: directive.runID
        )
        let resumed = try #require(await restored.runtimeState(taskID: definition.id))
        guard case .running(let runID, _, _) = resumed.occurrenceRecords.first?.state else {
            Issue.record("Attended resume should return the occurrence to running")
            return
        }
        #expect(runID == directive.runID)
    }

    @Test func repeatedFailureNotificationsFollowSavedCadenceAndSuccessResetsIt() async throws {
        var definition = try makeDefinition()
        definition.notificationPolicy = AgentTaskNotificationPolicy(
            notifyWhenWaitingForHuman: true,
            notifyOnEveryFailure: false,
            repeatedFailures: .recurring(threshold: 3, repeatEvery: 2),
            notifyOnSuccess: false
        )
        let engine = try AgentScheduledTaskEngine()
        try await engine.register(definition)

        for index in 1...5 {
            let at = try date("2026-01-01T0\(index):00:00Z")
            let occurrence = AgentTaskOccurrence(
                definition: definition,
                scheduledAt: at,
                source: .timer
            )
            guard case .start(let directive) = await engine.admit(
                occurrence,
                browserAvailability: .sanctionedHiddenWindow,
                at: at
            ) else {
                Issue.record("Failure fixture occurrence should start")
                return
            }
            _ = try await engine.complete(
                taskID: definition.id,
                occurrenceID: occurrence.id,
                runID: directive.runID,
                outcome: .failed(.provider),
                browserAvailability: .sanctionedHiddenWindow,
                at: at.addingTimeInterval(1)
            )
        }
        let repeatedCounts = await engine.pendingNotifications().compactMap { notification in
            if case .repeatedFailure(let count) = notification.kind { return count }
            return nil
        }
        #expect(repeatedCounts == [3, 5])

        let successAt = try date("2026-01-01T06:00:00Z")
        let success = AgentTaskOccurrence(
            definition: definition,
            scheduledAt: successAt,
            source: .timer
        )
        guard case .start(let directive) = await engine.admit(
            success,
            browserAvailability: .sanctionedHiddenWindow,
            at: successAt
        ) else {
            Issue.record("Success fixture occurrence should start")
            return
        }
        _ = try await engine.complete(
            taskID: definition.id,
            occurrenceID: success.id,
            runID: directive.runID,
            outcome: .succeeded,
            browserAvailability: .sanctionedHiddenWindow,
            at: successAt.addingTimeInterval(1)
        )
        #expect(await engine.runtimeState(taskID: definition.id)?.consecutiveFailures == 0)
    }

    @Test func disableAndDeletePreventFutureOccurrencesWithoutErasingLedger() async throws {
        let firstDate = try date("2026-01-01T01:00:00Z")
        let secondDate = try date("2026-01-01T02:00:00Z")
        var definition = try makeDefinition()
        definition.concurrencyPolicy = .serialize
        let engine = try AgentScheduledTaskEngine()
        try await engine.register(definition)
        let first = AgentTaskOccurrence(
            definition: definition,
            scheduledAt: firstDate,
            source: .timer
        )
        let second = AgentTaskOccurrence(
            definition: definition,
            scheduledAt: secondDate,
            source: .timer
        )
        guard case .start = await engine.admit(
            first,
            browserAvailability: .visibleWindow,
            at: firstDate
        ) else {
            Issue.record("First occurrence should start")
            return
        }
        guard case .queued = await engine.admit(
            second,
            browserAvailability: .visibleWindow,
            at: secondDate
        ) else {
            Issue.record("Second occurrence should queue")
            return
        }

        let disabled = try await engine.setEnabled(
            definition.id,
            false,
            at: secondDate.addingTimeInterval(1)
        )
        let afterDisable = AgentTaskOccurrence(
            definition: disabled,
            scheduledAt: try date("2026-01-01T03:00:00Z"),
            source: .timer
        )
        guard case .skipped(let disabledRecord) = await engine.admit(
            afterDisable,
            browserAvailability: .visibleWindow,
            at: afterDisable.scheduledAt
        ) else {
            Issue.record("Disabled task must record future occurrences as skipped")
            return
        }
        #expect(disabledRecord.state == .skipped(
            reason: .taskDisabled,
            at: afterDisable.scheduledAt
        ))
        let beforeDeleteCount = await engine.runtimeState(
            taskID: definition.id
        )?.occurrenceRecords.count

        try await engine.deleteTask(definition.id, at: afterDisable.scheduledAt)
        let rejected = await engine.admit(
            AgentTaskOccurrence(
                definition: disabled,
                scheduledAt: try date("2026-01-01T04:00:00Z"),
                source: .timer
            ),
            browserAvailability: .visibleWindow,
            at: try date("2026-01-01T04:00:00Z")
        )
        #expect(rejected == .rejected(.taskDeleted))
        #expect(await engine.definition(id: definition.id) == nil)
        #expect(await engine.runtimeState(
            taskID: definition.id
        )?.occurrenceRecords.count == beforeDeleteCount)
        #expect(await engine.snapshot().deletionTombstones.map(\.taskDefinitionID) == [definition.id])
    }

    @Test func relaunchInterruptsActiveRunAndDoesNotDuplicateItsOccurrence() async throws {
        let created = try date("2026-01-01T00:30:00Z")
        var definition = try makeDefinition(
            schedule: .interval(
                everySeconds: 3_600,
                anchor: try date("2026-01-01T00:00:00Z")
            ),
            catchUpPolicy: .runLatest
        )
        definition = try replacingDates(in: definition, createdAt: created)
        let engine = try AgentScheduledTaskEngine()
        try await engine.register(definition)

        let firstLaunch = try await engine.recoverOnLaunch(
            at: try date("2026-01-01T04:30:00Z"),
            browserAvailability: .sanctionedHiddenWindow
        )
        guard case .start(let firstDirective) = firstLaunch.admissions.first else {
            Issue.record("Latest missed occurrence should start on launch")
            return
        }
        #expect(firstDirective.occurrence.scheduledAt == tryDate("2026-01-01T04:00:00Z"))

        let restored = try AgentScheduledTaskEngine(snapshot: await engine.snapshot())
        let repeatedLaunch = try await restored.recoverOnLaunch(
            at: try date("2026-01-01T04:30:00Z"),
            browserAvailability: .sanctionedHiddenWindow
        )
        #expect(repeatedLaunch.interruptedRunIDs == [firstDirective.runID])
        #expect(repeatedLaunch.admissions.isEmpty)
        #expect(repeatedLaunch.plans.first?.alreadyRecordedCount == 0)

        let laterLaunch = try await restored.recoverOnLaunch(
            at: try date("2026-01-01T05:30:00Z"),
            browserAvailability: .sanctionedHiddenWindow
        )
        let startedLater = laterLaunch.admissions.compactMap { admission -> AgentTaskRunDirective? in
            if case .start(let directive) = admission { return directive }
            return nil
        }
        #expect(startedLater.map(\.occurrence.scheduledAt) == [tryDate("2026-01-01T05:00:00Z")])
        let records = try #require(await restored.runtimeState(taskID: definition.id))
        #expect(Set(records.occurrenceRecords.map(\.id)).count == records.occurrenceRecords.count)
    }

    @Test func timeoutBudgetAndCancellationAreNeverReportedAsSuccess() async throws {
        let outcomes: [AgentTaskRunOutcome] = [
            .timedOut,
            .budgetExceeded(.toolCalls),
            .cancelled,
        ]
        let definition = try makeDefinition()
        let engine = try AgentScheduledTaskEngine()
        try await engine.register(definition)
        for (index, outcome) in outcomes.enumerated() {
            let at = try date("2026-01-01T0\(index + 1):00:00Z")
            let occurrence = AgentTaskOccurrence(
                definition: definition,
                scheduledAt: at,
                source: .timer
            )
            guard case .start(let directive) = await engine.admit(
                occurrence,
                browserAvailability: .sanctionedHiddenWindow,
                at: at
            ) else {
                Issue.record("Limit/cancellation fixture should start")
                return
            }
            let update = try await engine.complete(
                taskID: definition.id,
                occurrenceID: occurrence.id,
                runID: directive.runID,
                outcome: outcome,
                browserAvailability: .sanctionedHiddenWindow,
                at: at.addingTimeInterval(10)
            )
            #expect(update.completedRecord.state == .finished(
                runID: directive.runID,
                outcome: outcome,
                finishedAt: at.addingTimeInterval(10)
            ))
            #expect(update.completedRecord.state != .finished(
                runID: directive.runID,
                outcome: .succeeded,
                finishedAt: at.addingTimeInterval(10)
            ))
        }
        #expect(await engine.runtimeState(taskID: definition.id)?.consecutiveFailures == 2)
    }

    @Test func retentionIsTwoPhaseAndNeverDeletesRunEvidenceBeforeAcknowledgement() async throws {
        let startedAt = try date("2026-01-01T01:00:00Z")
        let finishedAt = startedAt.addingTimeInterval(60)
        var definition = try makeDefinition()
        definition.retentionPolicy = .hours24
        let occurrence = AgentTaskOccurrence(
            definition: definition,
            scheduledAt: startedAt,
            source: .timer
        )
        let engine = try AgentScheduledTaskEngine()
        try await engine.register(definition)
        guard case .start(let directive) = await engine.admit(
            occurrence,
            browserAvailability: .sanctionedHiddenWindow,
            at: startedAt
        ) else {
            Issue.record("Retention fixture should start")
            return
        }
        _ = try await engine.complete(
            taskID: definition.id,
            occurrenceID: occurrence.id,
            runID: directive.runID,
            outcome: .succeeded,
            browserAvailability: .sanctionedHiddenWindow,
            at: finishedAt
        )

        #expect(await engine.retentionDirectives(
            at: finishedAt.addingTimeInterval(24 * 60 * 60 - 1)
        ).isEmpty)
        let due = await engine.retentionDirectives(
            at: finishedAt.addingTimeInterval(24 * 60 * 60)
        )
        #expect(due == [AgentTaskRetentionDirective(
            taskDefinitionID: definition.id,
            occurrenceID: occurrence.id,
            runID: directive.runID,
            removeAt: finishedAt.addingTimeInterval(24 * 60 * 60)
        )])
        #expect(await engine.runtimeState(
            taskID: definition.id
        )?.occurrenceRecords.count == 1)

        try await engine.acknowledgeRetention(try #require(due.first))
        #expect(await engine.runtimeState(
            taskID: definition.id
        )?.occurrenceRecords.isEmpty == true)
    }

    private func makeDefinition(
        schedule: AgentTaskSchedule = .daily(hour: 9, minute: 15),
        catchUpPolicy: AgentTaskCatchUpPolicy = .runLatest
    ) throws -> AgentTaskDefinition {
        try AgentTaskDefinition(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            revision: 4,
            name: "Morning research",
            prompt: "Summarize the scoped dashboard.",
            enabled: true,
            schedule: schedule,
            timeZoneIdentifier: "Europe/Amsterdam",
            daylightSavingPolicy: AgentTaskDaylightSavingPolicy(
                nonexistentTime: .skipOccurrence,
                repeatedTime: .firstOccurrence
            ),
            execution: AgentTaskExecutionSnapshot(
                provider: AgentProviderSnapshot(
                    providerID: "compatible",
                    model: "saved-model",
                    endpointIdentity: "https://models.example/v1",
                    reportsUsage: true,
                    supportsStreaming: true
                ),
                browserScope: AgentTaskBrowserScope(
                    pageIDs: ["window:page"],
                    origins: ["https://dashboard.example"],
                    session: .container(UUID(
                        uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
                    )!)
                ),
                capabilities: [.pageRead],
                mcpConnectionIDs: [
                    UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!,
                ],
                coworkRootID: UUID(
                    uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
                )!
            ),
            budgets: AgentTaskBudgets(
                maximumModelTurns: 8,
                maximumToolCalls: 24,
                maximumOutputBytes: 1_000_000,
                maximumOpenBackgroundPages: 2,
                maximumArtifactBytes: 4_000_000,
                maximumProviderCostMicrounits: 50_000
            ),
            timeoutSeconds: 300,
            concurrencyPolicy: .serialize,
            retentionPolicy: .days7,
            catchUpPolicy: catchUpPolicy,
            notificationPolicy: AgentTaskNotificationPolicy()
        )
    }

    private func replacingDates(
        in definition: AgentTaskDefinition,
        createdAt: Date
    ) throws -> AgentTaskDefinition {
        try AgentTaskDefinition(
            id: definition.id,
            revision: definition.revision,
            name: definition.name,
            prompt: definition.prompt,
            enabled: definition.enabled,
            schedule: definition.schedule,
            timeZoneIdentifier: definition.timeZoneIdentifier,
            daylightSavingPolicy: definition.daylightSavingPolicy,
            execution: definition.execution,
            budgets: definition.budgets,
            timeoutSeconds: definition.timeoutSeconds,
            concurrencyPolicy: definition.concurrencyPolicy,
            retentionPolicy: definition.retentionPolicy,
            catchUpPolicy: definition.catchUpPolicy,
            notificationPolicy: definition.notificationPolicy,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    private func date(_ string: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: string))
    }

    private func tryDate(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }
}
