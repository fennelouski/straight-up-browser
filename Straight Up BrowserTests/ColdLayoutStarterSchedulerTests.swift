import Foundation
import Testing
@testable import Browser

@MainActor
struct ColdLayoutStarterSchedulerTests {
    private let workspace = UUID()

    private func starter(_ index: Int, id: UUID = UUID(), profile: UUID? = nil) -> ColdLayoutStarterScheduler.Starter {
        .init(tabID: id, startingURL: URL(string: "https://example.test/page/\(index)")!, profileID: profile)
    }

    private func reserve(_ scheduler: ColdLayoutStarterScheduler,
                         visible: [UUID], focus: UUID? = nil, revision: UInt64 = 1,
                         gate: Bool = true) -> ColdLayoutStarterScheduler.Permit? {
        scheduler.reserveNext(visibleTabIDs: Set(visible), focusedTabID: focus,
                              workspaceID: workspace, layoutRevision: revision, gateEnabled: gate)
    }

    @Test func registrationIsLazyAndAdmissionIsFocusedFirstWithAtMostTwoReservations() throws {
        let scheduler = ColdLayoutStarterScheduler()
        let starters = (0..<5).map { starter($0) }
        let ids = starters.map(\.tabID)
        let generation = scheduler.register(starters: starters, workspaceID: workspace, layoutRevision: 1, gateEnabled: true)
        #expect(generation != nil)
        #expect(scheduler.inFlightCount == 0)
        #expect(scheduler.pendingTabIDs == ids)
        #expect(scheduler.deferredTabIDs == Set(ids))
        let first = try #require(reserve(scheduler, visible: ids, focus: ids[3]))
        #expect(first.token.tabID == ids[3])
        #expect(first.token.generationID == generation)
        #expect(try #require(reserve(scheduler, visible: ids)).token.tabID == ids[0])
        #expect(reserve(scheduler, visible: ids) == nil)
        #expect(scheduler.inFlightCount == 2)
        #expect(!scheduler.isDeferred(ids[3]))
    }

    @Test func stagedDownloadPolicyBindsReturnedNavigationBeforeAsynchronousConversion() throws {
        let scheduler = ColdLayoutStarterScheduler(), starters = (0..<3).map { starter($0) }
        let ids = starters.map(\.tabID)
        scheduler.register(starters: starters, workspaceID: workspace, layoutRevision: 1, gateEnabled: true)
        let permit = try #require(reserve(scheduler, visible: ids))
        _ = try #require(reserve(scheduler, visible: ids))
        // Policy fired inside loadURL before it returned WKNavigation.
        var claim = ColdLayoutStarterScheduler.DownloadAssociation(token: permit.token)
        let navigation = NSObject(), unrelated = NSObject()
        let forged = ColdLayoutStarterScheduler.Token(generationID: permit.token.generationID, tabID: permit.token.tabID, loadID: UUID())
        #expect(claim.navigationID == nil)
        let rejectsWrongToken = !claim.bindReturnedNavigation(ObjectIdentifier(unrelated), token: forged)
        #expect(rejectsWrongToken)
        let bindsReturned = claim.bindReturnedNavigation(ObjectIdentifier(navigation), token: permit.token)
        #expect(bindsReturned)
        let rejectsAnotherNavigation = !claim.bindReturnedNavigation(ObjectIdentifier(unrelated), token: permit.token)
        #expect(rejectsAnotherNavigation)
        // Binding/policy does not release capacity; conversion arrives later.
        #expect(reserve(scheduler, visible: ids) == nil)
        #expect(!claim.matches(navigationID: ObjectIdentifier(unrelated), token: permit.token))
        #expect(!claim.matches(navigationID: ObjectIdentifier(navigation), token: forged))
        #expect(claim.matches(navigationID: ObjectIdentifier(navigation), token: permit.token))
        #expect(scheduler.terminal(claim.token, outcome: .download))
        #expect(scheduler.isDeferred(permit.token.tabID))
        #expect(!scheduler.terminal(claim.token, outcome: .download))
        #expect(try #require(reserve(scheduler, visible: ids)).token.tabID == ids[2])
    }

    @Test func hiddenAndCompactOmittedPanesWaitWithoutConsumingCapacity() throws {
        let scheduler = ColdLayoutStarterScheduler()
        let starters = (0..<3).map { starter($0) }, ids = starters.map(\.tabID)
        scheduler.register(starters: starters, workspaceID: workspace, layoutRevision: 1, gateEnabled: true)
        #expect(reserve(scheduler, visible: [], focus: ids[0]) == nil)
        #expect(scheduler.inFlightCount == 0)
        #expect(try #require(reserve(scheduler, visible: [ids[1]], focus: ids[0])).token.tabID == ids[1])
        #expect(scheduler.isDeferred(ids[0]))
        #expect(scheduler.isDeferred(ids[2]))
    }

    @Test func retiredGenerationKeepsItsBudgetAndNewestRestoreGetsNextFreeSlot() throws {
        let scheduler = ColdLayoutStarterScheduler()
        let old = (0..<4).map { starter($0) }, oldIDs = old.map(\.tabID)
        scheduler.register(starters: old, workspaceID: workspace, layoutRevision: 1, gateEnabled: true)
        let first = try #require(reserve(scheduler, visible: oldIDs))
        let second = try #require(reserve(scheduler, visible: oldIDs))
        let newest = (5..<8).map { starter($0) }, newIDs = newest.map(\.tabID)
        let generation = scheduler.register(starters: newest, workspaceID: workspace, layoutRevision: 2, gateEnabled: true)
        #expect(scheduler.inFlightCount == 2)
        #expect(scheduler.isDeferred(oldIDs[2]))
        #expect(scheduler.isDeferred(oldIDs[3]))
        #expect(reserve(scheduler, visible: newIDs, revision: 2) == nil)
        #expect(scheduler.terminal(first.token))
        let next = try #require(reserve(scheduler, visible: newIDs, focus: newIDs[2], revision: 2))
        #expect(next.token.generationID == generation)
        #expect(next.token.tabID == newIDs[2])
        #expect(scheduler.inFlightCount == 2)
        #expect(scheduler.activePermit(for: second.token.tabID) == second)
    }

    @Test func staleAndDuplicateTerminalsCannotReleaseAnotherPermitForTheSameTab() throws {
        let scheduler = ColdLayoutStarterScheduler(), tabID = UUID()
        let candidate = starter(0, id: tabID)
        scheduler.register(starters: [candidate], workspaceID: workspace, layoutRevision: 1, gateEnabled: true)
        let first = try #require(reserve(scheduler, visible: [tabID]))
        let forged = ColdLayoutStarterScheduler.Token(generationID: first.token.generationID, tabID: tabID, loadID: UUID())
        #expect(!scheduler.terminal(forged))
        #expect(scheduler.inFlightCount == 1)
        #expect(scheduler.terminal(first.token))
        scheduler.register(starters: [candidate], workspaceID: workspace, layoutRevision: 2, gateEnabled: true)
        let second = try #require(reserve(scheduler, visible: [tabID], revision: 2))
        #expect(first.token != second.token)
        #expect(!scheduler.terminal(first.token))
        #expect(scheduler.activePermit(for: tabID) == second)
        #expect(scheduler.inFlightCount == 1)
    }

    @Test func aNewGenerationCannotRegisterAnActiveTabAgain() throws {
        let scheduler = ColdLayoutStarterScheduler()
        let first = starter(0), second = starter(1)
        scheduler.register(starters: [first], workspaceID: workspace, layoutRevision: 1, gateEnabled: true)
        let permit = try #require(reserve(scheduler, visible: [first.tabID]))
        scheduler.register(starters: [first, second], workspaceID: workspace, layoutRevision: 2, gateEnabled: true)
        #expect(scheduler.pendingTabIDs == [second.tabID])
        #expect(scheduler.activePermit(for: first.tabID) == permit)
        #expect(!scheduler.isDeferred(first.tabID))
    }

    @Test func undoCancellationDefersUnstartedTabsAndPreservesStartedWork() throws {
        let scheduler = ColdLayoutStarterScheduler()
        let starters = (0..<3).map { starter($0) }, ids = starters.map(\.tabID)
        scheduler.register(starters: starters, workspaceID: workspace, layoutRevision: 1, gateEnabled: true)
        let permit = try #require(reserve(scheduler, visible: ids))
        scheduler.cancelPending(reason: .undo)
        #expect(scheduler.pendingTabIDs.isEmpty)
        #expect(scheduler.currentGenerationID == nil)
        #expect(scheduler.lastCancellationReason == .undo)
        #expect(scheduler.inFlightCount == 1)
        #expect(reserve(scheduler, visible: ids) == nil)
        #expect(scheduler.isDeferred(ids[1]))
        #expect(scheduler.releaseDeferredForUserAction(ids[1]))
        #expect(!scheduler.isDeferred(ids[1]))
        #expect(scheduler.isDeferred(ids[2]))
        #expect(scheduler.terminal(permit.token))
    }

    @Test func selectingAQueuedTabPromotesItThroughAdmissionWithoutBypassingBudget() throws {
        let scheduler = ColdLayoutStarterScheduler()
        let starters = (0..<3).map { starter($0) }, ids = starters.map(\.tabID)
        scheduler.register(starters: starters, workspaceID: workspace, layoutRevision: 1, gateEnabled: true)
        _ = try #require(reserve(scheduler, visible: ids))
        _ = try #require(reserve(scheduler, visible: ids))
        #expect(!scheduler.releaseDeferredForUserAction(ids[2]))
        #expect(scheduler.isDeferred(ids[2]))
        #expect(reserve(scheduler, visible: ids, focus: ids[2]) == nil)
    }

    @Test func manualNavigationCancelsPendingAndOnlyReleasesItsExplicitTarget() throws {
        let scheduler = ColdLayoutStarterScheduler()
        let starters = (0..<3).map { starter($0) }, ids = starters.map(\.tabID)
        scheduler.register(starters: starters, workspaceID: workspace, layoutRevision: 1, gateEnabled: true)
        let permit = try #require(reserve(scheduler, visible: ids))
        scheduler.cancelForManualNavigation(tabID: ids[1])
        #expect(scheduler.lastCancellationReason == .manualNavigation)
        #expect(scheduler.pendingTabIDs.isEmpty)
        #expect(!scheduler.isDeferred(ids[1]))
        #expect(scheduler.isDeferred(ids[2]))
        #expect(scheduler.activePermit(for: ids[0]) == permit)
    }

    @Test func changedWorkspaceRevisionOrGateInvalidatesPendingBeforeAdmission() {
        for reason: ColdLayoutStarterScheduler.CancellationReason in [.workspaceChanged, .layoutChanged, .rolloutDisabled] {
            let scheduler = ColdLayoutStarterScheduler(), candidate = starter(0)
            scheduler.register(starters: [candidate], workspaceID: workspace, layoutRevision: 1, gateEnabled: true)
            let permit = scheduler.reserveNext(visibleTabIDs: [candidate.tabID], focusedTabID: candidate.tabID,
                workspaceID: reason == .workspaceChanged ? UUID() : workspace,
                layoutRevision: reason == .layoutChanged ? 2 : 1,
                gateEnabled: reason != .rolloutDisabled)
            #expect(permit == nil)
            #expect(scheduler.inFlightCount == 0)
            #expect(scheduler.lastCancellationReason == reason)
            #expect(scheduler.isDeferred(candidate.tabID))
        }
    }

    @Test func manualMeetingPrivateLiveAndUnsafeSlotsNeverBecomeAutomaticNavigation() {
        let scheduler = ColdLayoutStarterScheduler()
        let valid = starter(0), profile = UUID()
        let container = starter(1, profile: profile)
        let excluded: [ColdLayoutStarterScheduler.Starter] = [
            .init(tabID: UUID(), startingURL: nil),
            .init(tabID: UUID(), startingURL: URL(string: "https://meet.google.com/abc-defg-hij")),
            .init(tabID: UUID(), startingURL: URL(string: "https://example.test/private"), isPrivate: true),
            .init(tabID: UUID(), startingURL: URL(string: "https://example.test/live"), isAlreadyLive: true),
            .init(tabID: UUID(), startingURL: URL(string: "https://example.test/page?token=secret")),
            .init(tabID: UUID(), startingURL: URL(string: "https://example.test/oauth/callback")),
            .init(tabID: UUID(), startingURL: URL(string: "file:///tmp/document.html"))
        ]
        scheduler.register(starters: excluded + [valid, container], workspaceID: workspace, layoutRevision: 1, gateEnabled: true)
        #expect(scheduler.pendingTabIDs == [valid.tabID, container.tabID])
        #expect(scheduler.deferredTabIDs.isDisjoint(with: excluded.map(\.tabID)))
        _ = reserve(scheduler, visible: [valid.tabID, container.tabID])
        let permit = reserve(scheduler, visible: [container.tabID])
        #expect(permit?.profileID == profile)
        #expect(permit?.workspaceID == workspace)
    }

    @Test func gateDisabledRegistrationDefersSafeStartersWithoutStartingGeneration() {
        let scheduler = ColdLayoutStarterScheduler(), candidate = starter(0)
        #expect(scheduler.register(starters: [candidate], workspaceID: workspace, layoutRevision: 1, gateEnabled: false) == nil)
        #expect(scheduler.isDeferred(candidate.tabID))
        #expect(scheduler.inFlightCount == 0)
        #expect(reserve(scheduler, visible: [candidate.tabID]) == nil)
    }

    @Test func failedStartersStayDeferredWhileSuccessfulStartersRetireOwnership() throws {
        let scheduler = ColdLayoutStarterScheduler()
        let starters = (0..<2).map { starter($0) }, ids = starters.map(\.tabID)
        scheduler.register(starters: starters, workspaceID: workspace, layoutRevision: 1, gateEnabled: true)
        let failed = try #require(reserve(scheduler, visible: ids))
        let finished = try #require(reserve(scheduler, visible: ids))
        #expect(scheduler.terminal(failed.token, outcome: .failed))
        #expect(scheduler.terminal(finished.token))
        #expect(scheduler.isDeferred(failed.token.tabID))
        #expect(!scheduler.isDeferred(finished.token.tabID))
        #expect(scheduler.ownsStarter(failed.token.tabID))
        #expect(!scheduler.ownsStarter(finished.token.tabID))
        #expect(reserve(scheduler, visible: ids) == nil)
        #expect(scheduler.releaseDeferredForUserAction(failed.token.tabID))
        #expect(!scheduler.ownsStarter(failed.token.tabID))
        #expect(!scheduler.ownsStarter(finished.token.tabID))
    }

    @Test func aSuccessfulStarterCanUseNormalRestorationAfterItsWebViewIsDisposed() throws {
        let scheduler = ColdLayoutStarterScheduler(), candidate = starter(0)
        scheduler.register(starters: [candidate], workspaceID: workspace, layoutRevision: 1, gateEnabled: true)
        let permit = try #require(reserve(scheduler, visible: [candidate.tabID]))
        #expect(scheduler.ownsStarter(candidate.tabID))
        #expect(scheduler.terminal(permit.token, outcome: .finished))
        // The host's automatic-load gate consults ownsStarter after memory
        // disposal. Success must allow the baseline URL/session restore path
        // without requiring a manual-load overlay or another queue admission.
        #expect(scheduler.activePermit(for: candidate.tabID) == nil)
        #expect(!scheduler.ownsStarter(candidate.tabID))
        #expect(!scheduler.isDeferred(candidate.tabID))
        #expect(reserve(scheduler, visible: [candidate.tabID]) == nil)
        #expect(!scheduler.terminal(permit.token, outcome: .terminated))
        #expect(!scheduler.ownsStarter(candidate.tabID))
        #expect(!scheduler.isDeferred(candidate.tabID))
        // A later layout restore can reuse this normal live session without
        // re-registering it as an automatic cold starter.
        scheduler.register(starters: [.init(tabID: candidate.tabID, startingURL: candidate.startingURL, isAlreadyLive: true)],
                           workspaceID: workspace, layoutRevision: 2, gateEnabled: true)
        #expect(!scheduler.ownsStarter(candidate.tabID))
        #expect(scheduler.pendingTabIDs.isEmpty)
    }

    @Test func oldCancellationCannotReclaimATabAfterAnExplicitManualNavigation() throws {
        let scheduler = ColdLayoutStarterScheduler(), candidate = starter(0)
        scheduler.register(starters: [candidate], workspaceID: workspace, layoutRevision: 1, gateEnabled: true)
        let permit = try #require(reserve(scheduler, visible: [candidate.tabID]))
        scheduler.cancelForManualNavigation(tabID: candidate.tabID)
        #expect(scheduler.inFlightCount == 1)
        #expect(scheduler.terminal(permit.token, outcome: .cancelled))
        #expect(!scheduler.isDeferred(candidate.tabID))
        #expect(!scheduler.ownsStarter(candidate.tabID))
    }

    @Test func ambiguousDuplicateTabRegistrationsAreRejectedAndCloseForgetsOnlyDeferredState() {
        let scheduler = ColdLayoutStarterScheduler(), id = UUID()
        let valid = starter(2)
        scheduler.register(starters: [starter(0, id: id), starter(1, id: id), valid],
                           workspaceID: workspace, layoutRevision: 1, gateEnabled: true)
        #expect(scheduler.pendingTabIDs == [valid.tabID])
        scheduler.forgetDeferredTab(valid.tabID)
        #expect(scheduler.pendingTabIDs.isEmpty)
        #expect(!scheduler.isDeferred(valid.tabID))
    }

    @Test func retryCannotBypassTwoRetiredActiveLoadsAndWaitsForAnExactTerminal() throws {
        let scheduler = ColdLayoutStarterScheduler()
        let starters = (0..<3).map { starter($0) }, ids = starters.map(\.tabID)
        scheduler.register(starters: starters, workspaceID: workspace, layoutRevision: 1, gateEnabled: true)
        let first = try #require(reserve(scheduler, visible: ids))
        let second = try #require(reserve(scheduler, visible: ids))
        scheduler.cancelPending(reason: .undo)
        #expect(scheduler.retryDeferredStarter(starter: starters[2], workspaceID: workspace, layoutRevision: 2, gateEnabled: true))
        #expect(reserve(scheduler, visible: ids, focus: ids[2], revision: 2) == nil)
        #expect(scheduler.inFlightCount == 2)
        #expect(scheduler.terminal(first.token))
        let retry = try #require(reserve(scheduler, visible: ids, focus: ids[2], revision: 2))
        #expect(retry.token.tabID == ids[2])
        #expect(scheduler.inFlightCount == 2)
        #expect(!scheduler.terminal(first.token))
        #expect(scheduler.activePermit(for: retry.token.tabID) == retry)
        #expect(scheduler.activePermit(for: second.token.tabID) == second)
    }

    @Test func retryPreservesCurrentPendingPagesAndFocusPromotesItWithoutDuplication() throws {
        let scheduler = ColdLayoutStarterScheduler(), deferred = starter(0)
        scheduler.register(starters: [deferred], workspaceID: workspace, layoutRevision: 1, gateEnabled: true)
        scheduler.cancelPending(reason: .undo)
        let current = [starter(1), starter(2)], ids = current.map(\.tabID)
        let generation = scheduler.register(starters: current, workspaceID: workspace, layoutRevision: 2, gateEnabled: true)
        #expect(scheduler.retryDeferredStarter(starter: deferred, workspaceID: workspace, layoutRevision: 2, gateEnabled: true))
        #expect(scheduler.currentGenerationID == generation)
        #expect(scheduler.pendingTabIDs == ids + [deferred.tabID])
        #expect(scheduler.retryDeferredStarter(starter: deferred, workspaceID: workspace, layoutRevision: 2, gateEnabled: true))
        #expect(scheduler.pendingTabIDs == ids + [deferred.tabID])
        let retry = try #require(reserve(scheduler, visible: ids + [deferred.tabID], focus: deferred.tabID, revision: 2))
        #expect(retry.token.tabID == deferred.tabID)
        #expect(scheduler.pendingTabIDs == ids)
    }

    @Test func retryInANewContextDefersOldPendingAndGateOffStartsNothing() {
        let scheduler = ColdLayoutStarterScheduler(), deferred = starter(0), current = starter(1)
        scheduler.register(starters: [deferred], workspaceID: workspace, layoutRevision: 1, gateEnabled: true)
        scheduler.cancelPending(reason: .undo)
        scheduler.register(starters: [current], workspaceID: workspace, layoutRevision: 2, gateEnabled: true)
        let nextWorkspace = UUID()
        #expect(scheduler.retryDeferredStarter(starter: deferred, workspaceID: nextWorkspace, layoutRevision: 3, gateEnabled: true))
        #expect(scheduler.pendingTabIDs == [deferred.tabID])
        #expect(scheduler.isDeferred(current.tabID))
        #expect(!scheduler.retryDeferredStarter(starter: deferred, workspaceID: nextWorkspace, layoutRevision: 3, gateEnabled: false))
        #expect(scheduler.currentGenerationID == nil)
        #expect(scheduler.pendingTabIDs.isEmpty)
        #expect(scheduler.isDeferred(deferred.tabID))
        #expect(scheduler.inFlightCount == 0)
    }

    @Test func retryRejectsSuccessfulOrActivePagesAndChangedOrUnsafeSpecifications() throws {
        let scheduler = ColdLayoutStarterScheduler(), candidate = starter(0, profile: UUID())
        scheduler.register(starters: [candidate], workspaceID: workspace, layoutRevision: 1, gateEnabled: true)
        let first = try #require(reserve(scheduler, visible: [candidate.tabID]))
        #expect(!scheduler.retryDeferredStarter(starter: candidate, workspaceID: workspace, layoutRevision: 1, gateEnabled: true))
        #expect(scheduler.terminal(first.token, outcome: .failed))
        #expect(scheduler.registeredStarter(for: candidate.tabID) == candidate)
        for invalid in [
            ColdLayoutStarterScheduler.Starter(tabID: candidate.tabID, startingURL: candidate.startingURL, profileID: UUID()),
            .init(tabID: candidate.tabID, startingURL: URL(string: "https://example.test/changed"), profileID: candidate.profileID),
            .init(tabID: candidate.tabID, startingURL: candidate.startingURL, profileID: candidate.profileID, isPrivate: true),
            .init(tabID: candidate.tabID, startingURL: candidate.startingURL, profileID: candidate.profileID, isAlreadyLive: true),
            .init(tabID: candidate.tabID, startingURL: URL(string: "https://meet.google.com/abc-defg-hij"), profileID: candidate.profileID),
            .init(tabID: candidate.tabID, startingURL: nil, profileID: candidate.profileID)
        ] {
            #expect(!scheduler.retryDeferredStarter(starter: invalid, workspaceID: workspace, layoutRevision: 1, gateEnabled: true))
        }
        #expect(scheduler.retryDeferredStarter(starter: candidate, workspaceID: workspace, layoutRevision: 1, gateEnabled: true))
        let successful = try #require(reserve(scheduler, visible: [candidate.tabID]))
        #expect(scheduler.terminal(successful.token))
        #expect(scheduler.registeredStarter(for: candidate.tabID) == nil)
        #expect(!scheduler.retryDeferredStarter(starter: candidate, workspaceID: workspace, layoutRevision: 1, gateEnabled: true))
        #expect(!scheduler.terminal(first.token, outcome: .failed))
        #expect(!scheduler.isDeferred(candidate.tabID))
    }
}
