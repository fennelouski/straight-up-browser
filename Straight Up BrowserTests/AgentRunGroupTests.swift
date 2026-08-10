import Foundation
import Testing
@testable import Browser

struct AgentRunGroupTests {
    @Test func childContractCannotBroadenParentAuthorityOrBudget() throws {
        let rootRunID = UUID()
        let childRunID = UUID()
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let parentAuthority = AgentDelegationAuthority(
            allowedTools: ["take_snapshot"],
            allowedPages: [page],
            allowedOrigins: ["https://example.test"],
            allowedBrowserSessions: [.normal],
            coworkRootIdentities: [],
            mcpServerIdentities: [],
            permitsDataEgress: false,
            permitsContentRetention: false
        )
        let parentBudget = try AgentResourceBudget(
            maximumProviderCostMicrounits: 1_000,
            maximumElapsedMilliseconds: 60_000,
            maximumSteps: 20,
            maximumToolCalls: 5,
            maximumOutputBytes: 10_000,
            maximumChildCreatedPages: 1
        )

        #expect(throws: AgentRunGroupError.authorityEscalation("allowedTools")) {
            try AgentChildRunContract(
                childRunID: childRunID,
                parentRunID: rootRunID,
                runGroupID: UUID(),
                depth: 1,
                objective: "Read the page and summarize it",
                authority: AgentDelegationAuthority(
                    allowedTools: ["take_snapshot", "click"],
                    allowedPages: [page],
                    allowedOrigins: ["https://example.test"],
                    allowedBrowserSessions: [.normal]
                ),
                budget: parentBudget,
                returnSchema: .object(["summary": .string()], required: ["summary"]),
                validatingAgainst: parentAuthority,
                parentBudget: parentBudget
            )
        }

        let oversizedBudget = try AgentResourceBudget(
            maximumProviderCostMicrounits: 1_001,
            maximumElapsedMilliseconds: 60_000,
            maximumSteps: 20,
            maximumToolCalls: 5,
            maximumOutputBytes: 10_000,
            maximumChildCreatedPages: 1
        )
        #expect(throws: AgentRunGroupError.budgetEscalation("providerCost")) {
            try AgentChildRunContract(
                childRunID: childRunID,
                parentRunID: rootRunID,
                runGroupID: UUID(),
                depth: 1,
                objective: "Read the page and summarize it",
                authority: parentAuthority,
                budget: oversizedBudget,
                returnSchema: .object(),
                validatingAgainst: parentAuthority,
                parentBudget: parentBudget
            )
        }
    }

    @Test func sharedBudgetChargesChildrenAtomicallyAndStopsSiblingsOnExhaustion() async throws {
        let rootRunID = UUID()
        let firstChild = UUID()
        let secondChild = UUID()
        let limits = try AgentResourceBudget(
            maximumProviderCostMicrounits: 100,
            maximumElapsedMilliseconds: 60_000,
            maximumSteps: 10,
            maximumToolCalls: 5,
            maximumOutputBytes: 1_000,
            maximumChildCreatedPages: 1
        )
        let budget = AgentSharedRunGroupBudget(
            rootRunID: rootRunID,
            limits: limits,
            startedAt: Date(timeIntervalSince1970: 0)
        )
        try await budget.registerChild(
            runID: firstChild,
            limits: limits,
            at: Date(timeIntervalSince1970: 1)
        )
        try await budget.registerChild(
            runID: secondChild,
            limits: limits,
            at: Date(timeIntervalSince1970: 1)
        )
        let charge = try AgentBudgetCharge(providerCostMicrounits: 60)

        async let first: Bool = consumes(
            budget: budget,
            runID: firstChild,
            charge: charge
        )
        async let second: Bool = consumes(
            budget: budget,
            runID: secondChild,
            charge: charge
        )
        let successes = await [first, second].filter { $0 }.count
        let snapshot = await budget.snapshot(at: Date(timeIntervalSince1970: 2))

        #expect(successes == 1)
        #expect(snapshot.totalUsage.providerCostMicrounits == 60)
        #expect(snapshot.state == .exhausted(.providerCost))
        await #expect(throws: AgentSharedBudgetError.unavailable(.exhausted(.providerCost))) {
            try await budget.consume(
                runID: firstChild,
                charge: try AgentBudgetCharge(steps: 1),
                at: Date(timeIntervalSince1970: 3)
            )
        }
    }

    @Test func pageLeaseAllowsReadersTogetherAndSerializesWriter() async throws {
        let leases = AgentPageLeaseCoordinator()
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let version = AgentPageLeaseVersion(
            navigation: PageNavigationGeneration(rawValue: 1),
            document: PageDocumentGeneration(rawValue: UUID())
        )
        await leases.register(page: page, ownership: .userOwned, version: version)
        let firstReader = UUID()
        let secondReader = UUID()
        let writerRun = UUID()

        let firstLease = try await leases.acquire([
            AgentPageLeaseRequest(page: page, access: .read, runID: firstReader),
        ])
        let secondLease = try await leases.acquire([
            AgentPageLeaseRequest(page: page, access: .read, runID: secondReader),
        ])
        let writerTask = Task {
            try await leases.acquire([
                AgentPageLeaseRequest(
                    page: page,
                    access: .write,
                    runID: writerRun,
                    permit: executionPermit(runID: writerRun)
                ),
            ])
        }

        await waitForQueuedRequest(in: leases)
        #expect(await leases.queuedRequestCount() == 1)
        await leases.release(firstLease)
        #expect(await leases.queuedRequestCount() == 1)
        await leases.release(secondLease)

        let writerLease = try await writerTask.value
        #expect(writerLease.grants == [
            AgentPageLeaseGrant(page: page, access: .write, version: version),
        ])
        #expect(await leases.queuedRequestCount() == 0)
        await leases.release(writerLease)
    }

    @Test func childCannotInheritParentsApprovalPermit() async throws {
        let leases = AgentPageLeaseCoordinator()
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        await leases.register(
            page: page,
            ownership: .userOwned,
            version: AgentPageLeaseVersion(
                navigation: PageNavigationGeneration(rawValue: 1),
                document: PageDocumentGeneration(rawValue: UUID())
            )
        )
        let parentRunID = UUID()
        let childRunID = UUID()

        await #expect(throws: AgentPageLeaseError.approvalRunMismatch(
            expectedRunID: childRunID,
            actualRunID: parentRunID
        )) {
            try await leases.acquire([
                AgentPageLeaseRequest(
                    page: page,
                    access: .write,
                    runID: childRunID,
                    permit: executionPermit(runID: parentRunID)
                ),
            ])
        }

        let lease = try await leases.acquire([
            AgentPageLeaseRequest(
                page: page,
                access: .write,
                runID: childRunID,
                permit: executionPermit(runID: childRunID)
            ),
        ])
        await leases.release(lease)
    }

    @Test func navigationAndDocumentReplacementInvalidateLeasedObservations() async throws {
        let leases = AgentPageLeaseCoordinator()
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let initial = AgentPageLeaseVersion(
            navigation: PageNavigationGeneration(rawValue: 4),
            document: PageDocumentGeneration(rawValue: UUID())
        )
        await leases.register(page: page, ownership: .userOwned, version: initial)
        let lease = try await leases.acquire([
            AgentPageLeaseRequest(page: page, access: .read, runID: UUID()),
        ])
        try await leases.validateObservation(in: lease, page: page)

        let replacement = PageDocumentGeneration(rawValue: UUID())
        try await leases.didReplaceDocument(page: page, document: replacement)
        await #expect(throws: AgentPageLeaseError.pageVersionChanged(
            page: page,
            expected: initial,
            actual: AgentPageLeaseVersion(
                navigation: initial.navigation,
                document: replacement
            )
        )) {
            try await leases.validateObservation(in: lease, page: page)
        }
        await leases.release(lease)

        let currentLease = try await leases.acquire([
            AgentPageLeaseRequest(page: page, access: .read, runID: UUID()),
        ])
        let navigated = AgentPageLeaseVersion(
            navigation: initial.navigation.advanced(),
            document: PageDocumentGeneration(rawValue: UUID())
        )
        try await leases.didNavigate(
            page: page,
            navigation: navigated.navigation,
            document: navigated.document
        )
        await #expect(throws: AgentPageLeaseError.pageVersionChanged(
            page: page,
            expected: currentLease.grants[0].version,
            actual: navigated
        )) {
            try await leases.validateObservation(in: currentLease, page: page)
        }
        await leases.release(currentLease)
    }

    @Test func coordinatorEnforcesDepthFanOutAndDuplicateWork() async throws {
        let fixture = try RunGroupFixture(maximumDepth: 1, maximumFanOut: 2)
        let coordinator = AgentRunGroupCoordinator(group: fixture.group)
        let first = try fixture.contract(
            childRunID: UUID(),
            objective: "Inspect account totals"
        )
        try await coordinator.registerChild(
            first,
            at: Date(timeIntervalSince1970: 1)
        )

        let duplicate = try fixture.contract(
            childRunID: UUID(),
            objective: "  inspect   ACCOUNT totals  "
        )
        await #expect(throws: AgentRunGroupError.duplicateWork(existingRunID: first.childRunID)) {
            try await coordinator.registerChild(
                duplicate,
                at: Date(timeIntervalSince1970: 1)
            )
        }

        let second = try fixture.contract(childRunID: UUID(), objective: "Inspect invoices")
        try await coordinator.registerChild(
            second,
            at: Date(timeIntervalSince1970: 1)
        )
        let third = try fixture.contract(childRunID: UUID(), objective: "Inspect payments")
        await #expect(throws: AgentRunGroupError.fanOutExceeded(
            parentRunID: fixture.group.rootRunID,
            maximum: 2
        )) {
            try await coordinator.registerChild(
                third,
                at: Date(timeIntervalSince1970: 1)
            )
        }

        let nested = try fixture.contract(
            childRunID: UUID(),
            parentRunID: first.childRunID,
            depth: 2,
            objective: "Inspect a nested detail"
        )
        await #expect(throws: AgentRunGroupError.depthExceeded(maximum: 1)) {
            try await coordinator.registerChild(
                nested,
                at: Date(timeIntervalSince1970: 1)
            )
        }
    }

    @Test func coordinatorProducesSchemaCheckedDeterministicHandoffs() async throws {
        let fixture = try RunGroupFixture()
        let coordinator = AgentRunGroupCoordinator(group: fixture.group)
        let laterID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let earlierID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let later = try fixture.contract(
            childRunID: laterID,
            objective: "Inspect invoices"
        )
        let earlier = try fixture.contract(
            childRunID: earlierID,
            objective: "Inspect payments"
        )
        try await coordinator.registerChild(later, at: Date(timeIntervalSince1970: 1))
        try await coordinator.registerChild(earlier, at: Date(timeIntervalSince1970: 1))
        try await coordinator.startChild(laterID, at: Date(timeIntervalSince1970: 2))
        try await coordinator.startChild(earlierID, at: Date(timeIntervalSince1970: 2))

        await #expect(throws: AgentRunGroupError.invalidHandoff(
            runID: earlierID,
            validationErrors: ["$.summary is required"]
        )) {
            try await coordinator.completeChild(
                earlierID,
                handoff: .object([:]),
                at: Date(timeIntervalSince1970: 3)
            )
        }
        _ = try await coordinator.completeChild(
            laterID,
            handoff: .object(["summary": .string("Invoices match")]),
            at: Date(timeIntervalSince1970: 3)
        )
        _ = try await coordinator.completeChild(
            earlierID,
            handoff: .object(["summary": .string("Payments match")]),
            at: Date(timeIntervalSince1970: 3)
        )

        let snapshot = await coordinator.snapshot(at: Date(timeIntervalSince1970: 4))
        #expect(snapshot.children.map(\.id) == [earlierID, laterID])
        #expect(snapshot.children.allSatisfy { $0.status == .succeeded })
        let handoffs = try await coordinator.beginSynthesis(
            at: Date(timeIntervalSince1970: 5)
        )
        #expect(handoffs.map(\.childRunID) == [earlierID, laterID])
        let report = try await coordinator.completeSynthesis(
            succeeded: true,
            at: Date(timeIntervalSince1970: 6)
        )
        #expect(report.state == .succeeded)
        #expect(await coordinator.lifecycleState() == .succeeded)
    }

    @Test func sharedBudgetExhaustionCancelsEveryRunningSibling() async throws {
        let fixture = try RunGroupFixture()
        let coordinator = AgentRunGroupCoordinator(group: fixture.group)
        let firstID = UUID()
        let secondID = UUID()
        try await coordinator.registerChild(
            fixture.contract(childRunID: firstID, objective: "Inspect invoices"),
            at: Date(timeIntervalSince1970: 1)
        )
        try await coordinator.registerChild(
            fixture.contract(childRunID: secondID, objective: "Inspect payments"),
            at: Date(timeIntervalSince1970: 1)
        )
        try await coordinator.startChild(firstID, at: Date(timeIntervalSince1970: 2))
        try await coordinator.startChild(secondID, at: Date(timeIntervalSince1970: 2))
        let recorder = CancellationRecorder()
        _ = try await coordinator.registerCancellationHandler(
            for: firstID,
            component: .providerStream
        ) { recorder.record("first") }
        _ = try await coordinator.registerCancellationHandler(
            for: secondID,
            component: .providerStream
        ) { recorder.record("second") }

        _ = try await coordinator.consume(
            runID: firstID,
            charge: AgentBudgetCharge(providerCostMicrounits: 400),
            at: Date(timeIntervalSince1970: 3)
        )
        _ = try await coordinator.consume(
            runID: secondID,
            charge: AgentBudgetCharge(providerCostMicrounits: 400),
            at: Date(timeIntervalSince1970: 3)
        )
        await #expect(throws: AgentSharedBudgetError.limitExceeded(.providerCost)) {
            try await coordinator.consume(
                runID: fixture.group.rootRunID,
                charge: AgentBudgetCharge(providerCostMicrounits: 201),
                at: Date(timeIntervalSince1970: 3)
            )
        }

        let snapshot = await coordinator.snapshot(at: Date(timeIntervalSince1970: 4))
        #expect(snapshot.state == .budgetExhausted(.providerCost))
        #expect(snapshot.budget.totalUsage.providerCostMicrounits == 800)
        #expect(snapshot.children.allSatisfy { $0.status == .cancelled })
        #expect(recorder.values == ["first", "second"])
    }

    @Test func parentCancellationStopsWorkReleasesLeasesAndClosesCreatedPages() async throws {
        let fixture = try RunGroupFixture()
        let leases = AgentPageLeaseCoordinator()
        let coordinator = AgentRunGroupCoordinator(
            group: fixture.group,
            pageLeases: leases
        )
        let childID = UUID()
        try await coordinator.registerChild(
            fixture.contract(childRunID: childID, objective: "Inspect invoices"),
            at: Date(timeIntervalSince1970: 1)
        )
        try await coordinator.startChild(childID, at: Date(timeIntervalSince1970: 2))
        let recorder = CancellationRecorder()
        for component in [
            AgentRunCancellationComponent.providerStream,
            .wait,
            .toolInvocation,
        ] {
            _ = try await coordinator.registerCancellationHandler(
                for: childID,
                component: component
            ) { recorder.record(component.rawValue) }
        }
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let version = AgentPageLeaseVersion(
            navigation: PageNavigationGeneration(rawValue: 1),
            document: PageDocumentGeneration(rawValue: UUID())
        )
        try await coordinator.registerChildCreatedPage(
            page,
            ownerRunID: childID,
            version: version,
            closeHandler: { recorder.record("pageCleanup") },
            at: Date(timeIntervalSince1970: 3)
        )
        let lease = try await coordinator.acquirePageLease([
            AgentPageLeaseRequest(page: page, access: .write, runID: childID),
        ])

        let report = await coordinator.cancel(
            reason: "Parent cancelled",
            at: Date(timeIntervalSince1970: 4)
        )

        #expect(report.state == .cancelled)
        #expect(report.cancelledRunIDs.contains(fixture.group.rootRunID))
        #expect(report.cancelledRunIDs.contains(childID))
        #expect(report.childCreatedPagesToClose == [page])
        #expect(Set(recorder.values) == [
            "pageCleanup", "providerStream", "toolInvocation", "wait",
        ])
        #expect(await leases.activeLeaseCount(for: page) == 0)
        #expect(await leases.ownership(of: page) == nil)
        await #expect(throws: AgentPageLeaseError.inactiveLease(lease.id)) {
            try await leases.validateObservation(in: lease, page: page)
        }
    }

    @Test func cancelRemainingFailurePolicyStopsIndependentSiblings() async throws {
        let fixture = try RunGroupFixture(failurePolicy: .cancelRemaining)
        let coordinator = AgentRunGroupCoordinator(group: fixture.group)
        let failedID = UUID()
        let siblingID = UUID()
        try await coordinator.registerChild(
            fixture.contract(childRunID: failedID, objective: "Inspect invoices"),
            at: Date(timeIntervalSince1970: 1)
        )
        try await coordinator.registerChild(
            fixture.contract(childRunID: siblingID, objective: "Inspect payments"),
            at: Date(timeIntervalSince1970: 1)
        )
        try await coordinator.startChild(
            failedID,
            at: Date(timeIntervalSince1970: 2)
        )
        try await coordinator.startChild(
            siblingID,
            at: Date(timeIntervalSince1970: 2)
        )

        try await coordinator.failChild(
            failedID,
            reason: "Provider failed",
            at: Date(timeIntervalSince1970: 3)
        )

        #expect(await coordinator.child(failedID)?.status == .failed)
        #expect(await coordinator.child(siblingID)?.status == .cancelled)
        #expect(await coordinator.lifecycleState() == .failed)
    }

    @Test func coordinatorRevalidatesNestedAuthorityAgainstActualParent() async throws {
        let fixture = try RunGroupFixture(maximumDepth: 2)
        let coordinator = AgentRunGroupCoordinator(group: fixture.group)
        let parentID = UUID()
        let parent = try fixture.contract(
            childRunID: parentID,
            objective: "Inspect invoices",
            authority: AgentDelegationAuthority(
                allowedTools: [],
                allowedBrowserSessions: [.normal]
            )
        )
        try await coordinator.registerChild(
            parent,
            at: Date(timeIntervalSince1970: 1)
        )
        let nested = try fixture.contract(
            childRunID: UUID(),
            parentRunID: parentID,
            depth: 2,
            objective: "Inspect invoice detail"
        )

        await #expect(throws: AgentRunGroupError.authorityEscalation("allowedTools")) {
            try await coordinator.registerChild(
                nested,
                at: Date(timeIntervalSince1970: 2)
            )
        }
    }

    @Test func totalChildCapIsIndependentFromPerParentFanOut() async throws {
        let fixture = try RunGroupFixture(
            maximumFanOut: 3,
            maximumTotalChildren: 1
        )
        let coordinator = AgentRunGroupCoordinator(group: fixture.group)
        try await coordinator.registerChild(
            fixture.contract(childRunID: UUID(), objective: "Inspect invoices"),
            at: Date(timeIntervalSince1970: 1)
        )
        await #expect(throws: AgentRunGroupError.totalChildrenExceeded(maximum: 1)) {
            try await coordinator.registerChild(
                fixture.contract(childRunID: UUID(), objective: "Inspect payments"),
                at: Date(timeIntervalSince1970: 1)
            )
        }
    }

    @Test func closingOnePageRevokesAnAtomicMultiPageLease() async throws {
        let leases = AgentPageLeaseCoordinator()
        let first = PageHandle(windowID: UUID(), tabID: UUID())
        let second = PageHandle(windowID: UUID(), tabID: UUID())
        let version = AgentPageLeaseVersion(
            navigation: PageNavigationGeneration(rawValue: 1),
            document: PageDocumentGeneration(rawValue: UUID())
        )
        await leases.register(page: first, ownership: .userOwned, version: version)
        await leases.register(page: second, ownership: .userOwned, version: version)
        let runID = UUID()
        let lease = try await leases.acquire([
            AgentPageLeaseRequest(page: second, access: .read, runID: runID),
            AgentPageLeaseRequest(page: first, access: .read, runID: runID),
        ])

        await leases.close(page: first)

        #expect(await leases.activeLeaseCount(for: first) == 0)
        #expect(await leases.activeLeaseCount(for: second) == 0)
        await #expect(throws: AgentPageLeaseError.inactiveLease(lease.id)) {
            try await leases.validateObservation(in: lease, page: second)
        }
    }

    @Test func childRegistrationCannotStartAfterSharedElapsedLimit() async throws {
        let limits = try AgentResourceBudget(
            maximumProviderCostMicrounits: 100,
            maximumElapsedMilliseconds: 1_000,
            maximumSteps: 2,
            maximumToolCalls: 1,
            maximumOutputBytes: 100,
            maximumChildCreatedPages: 0
        )
        let budget = AgentSharedRunGroupBudget(
            rootRunID: UUID(),
            limits: limits,
            startedAt: Date(timeIntervalSince1970: 0)
        )

        await #expect(throws: AgentSharedBudgetError.limitExceeded(.elapsedTime)) {
            try await budget.registerChild(
                runID: UUID(),
                limits: limits,
                at: Date(timeIntervalSince1970: 2)
            )
        }
        #expect(
            await budget.snapshot(at: Date(timeIntervalSince1970: 2)).state
                == .exhausted(.elapsedTime)
        )
    }

    @Test func retainedChildPageTransfersToUserOwnershipAtTermination() async throws {
        let fixture = try RunGroupFixture(cleanupPolicy: .retainChildCreatedPages)
        let leases = AgentPageLeaseCoordinator()
        let coordinator = AgentRunGroupCoordinator(
            group: fixture.group,
            pageLeases: leases
        )
        let childID = UUID()
        try await coordinator.registerChild(
            fixture.contract(childRunID: childID, objective: "Inspect invoices"),
            at: Date(timeIntervalSince1970: 1)
        )
        try await coordinator.startChild(childID, at: Date(timeIntervalSince1970: 2))
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        let recorder = CancellationRecorder()
        try await coordinator.registerChildCreatedPage(
            page,
            ownerRunID: childID,
            version: AgentPageLeaseVersion(
                navigation: PageNavigationGeneration(rawValue: 1),
                document: PageDocumentGeneration(rawValue: UUID())
            ),
            closeHandler: { recorder.record("closed") },
            at: Date(timeIntervalSince1970: 3)
        )

        let report = await coordinator.cancel(
            reason: "Stop but retain Pages",
            at: Date(timeIntervalSince1970: 4)
        )

        #expect(report.childCreatedPagesToClose.isEmpty)
        #expect(await leases.ownership(of: page) == .userOwned)
        #expect(recorder.values.isEmpty)
    }

    @Test func rootCreatedUserPageIsRegisteredLeasedAndNotClosedAtCompletion() async throws {
        let fixture = try RunGroupFixture()
        let leases = AgentPageLeaseCoordinator()
        let coordinator = AgentRunGroupCoordinator(
            group: fixture.group,
            pageLeases: leases
        )
        let page = PageHandle(windowID: UUID(), tabID: UUID())
        try await coordinator.registerRootCreatedPage(
            page,
            ownership: .userOwned,
            version: AgentPageLeaseVersion(
                navigation: PageNavigationGeneration(rawValue: 0),
                document: PageDocumentGeneration(rawValue: UUID())
            ),
            at: Date(timeIntervalSince1970: 1)
        )

        let lease = try await coordinator.acquirePageLease([
            AgentPageLeaseRequest(
                page: page,
                access: .read,
                runID: fixture.group.rootRunID
            ),
        ])
        #expect(await leases.activeLeaseCount(for: page) == 1)
        try await leases.validateObservation(in: lease, page: page)
        await coordinator.releasePageLease(lease)

        _ = try await coordinator.beginSynthesis(
            at: Date(timeIntervalSince1970: 2)
        )
        _ = try await coordinator.completeSynthesis(
            succeeded: true,
            at: Date(timeIntervalSince1970: 3)
        )

        #expect(await leases.activeLeaseCount(for: page) == 0)
        #expect(await leases.ownership(of: page) == .userOwned)
    }
}

private func consumes(
    budget: AgentSharedRunGroupBudget,
    runID: UUID,
    charge: AgentBudgetCharge
) async -> Bool {
    do {
        _ = try await budget.consume(
            runID: runID,
            charge: charge,
            at: Date(timeIntervalSince1970: 2)
        )
        return true
    } catch {
        return false
    }
}

private func executionPermit(runID: UUID) -> AgentExecutionPermit {
    AgentExecutionPermit(
        runID: runID,
        toolName: "click",
        invocationDigest: "fixture-digest",
        decisionStepID: UUID()
    )
}

private func waitForQueuedRequest(in leases: AgentPageLeaseCoordinator) async {
    for _ in 0..<100 where await leases.queuedRequestCount() == 0 {
        await Task.yield()
    }
}

private struct RunGroupFixture {
    let group: AgentRunGroup
    let childBudget: AgentResourceBudget

    init(
        maximumDepth: Int = 2,
        maximumFanOut: Int = 3,
        maximumTotalChildren: Int = 64,
        failurePolicy: AgentRunGroupFailurePolicy = .continueIndependent,
        cleanupPolicy: AgentRunGroupCleanupPolicy = .secureDefault
    ) throws {
        let authority = AgentDelegationAuthority(
            allowedTools: ["take_snapshot"],
            allowedPages: [],
            allowedOrigins: [],
            allowedBrowserSessions: [.normal]
        )
        let budget = try AgentResourceBudget(
            maximumProviderCostMicrounits: 1_000,
            maximumElapsedMilliseconds: 60_000,
            maximumSteps: 20,
            maximumToolCalls: 5,
            maximumOutputBytes: 10_000,
            maximumChildCreatedPages: 2
        )
        group = try AgentRunGroup(
            rootRunID: UUID(),
            objective: "Reconcile the account",
            authority: authority,
            budget: budget,
            maximumDepth: maximumDepth,
            maximumFanOut: maximumFanOut,
            maximumTotalChildren: maximumTotalChildren,
            failurePolicy: failurePolicy,
            cleanupPolicy: cleanupPolicy,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        childBudget = try AgentResourceBudget(
            maximumProviderCostMicrounits: 400,
            maximumElapsedMilliseconds: 30_000,
            maximumSteps: 10,
            maximumToolCalls: 3,
            maximumOutputBytes: 4_000,
            maximumChildCreatedPages: 1
        )
    }

    func contract(
        childRunID: UUID,
        parentRunID: UUID? = nil,
        depth: Int = 1,
        objective: String,
        authority: AgentDelegationAuthority? = nil
    ) throws -> AgentChildRunContract {
        try AgentChildRunContract(
            childRunID: childRunID,
            parentRunID: parentRunID ?? group.rootRunID,
            runGroupID: group.id,
            depth: depth,
            objective: objective,
            authority: authority ?? group.authority,
            budget: childBudget,
            returnSchema: .object(["summary": .string()], required: ["summary"]),
            validatingAgainst: group.authority,
            parentBudget: group.budget
        )
    }
}

private nonisolated final class CancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage.sorted()
    }

    func record(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
