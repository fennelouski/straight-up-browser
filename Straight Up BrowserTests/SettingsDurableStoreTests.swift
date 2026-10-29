import Darwin
import CryptoKit
import Foundation
import Observation
import Testing
@testable import Browser

@MainActor struct SettingsDurableStoreTests {
    private struct Crash: Error {}
    private let theme = SettingsRegistry.descriptor(.theme)

    private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("DurableSettingsFixture-\(UUID().uuidString)", isDirectory: true) }
    private func suite() -> (String, UserDefaults) {
        let name = "DurableSettingsFixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(true, forKey: "aiFeaturesEnabled")
        defaults.set(true, forKey: SettingsAssistantAvailability.enabledKey)
        return (name, defaults)
    }

    @Test func actualFileCommitReopensIdempotentlyAndRestoresAbsence() throws {
        let directory = location(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SettingsDurableStore(directory: directory, allowedIDs: [.theme])
        let operation = UUID()
        let applied = try store.commit(operationID: operation, value: .choice("Dark"), expected: nil, expectedRevision: 0, for: theme)
        #expect(applied == .init(stored: .choice("Dark"), revision: 1))
        let reopened = try SettingsDurableStore(directory: directory, allowedIDs: [.theme])
        #expect(try reopened.commit(operationID: operation, value: .choice("Dark"), expected: nil, expectedRevision: 0, for: theme) == applied)
        #expect(try reopened.readVersioned(theme).revision == 1)
        _ = try reopened.commit(operationID: UUID(), value: nil, expected: .choice("Dark"), expectedRevision: 1, for: theme)
        #expect(try store.readVersioned(theme) == .init(stored: nil, revision: 2))
    }

    @Test func separateOwnersTrackSameValueAndABAWrites() throws {
        let directory = location(); defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SettingsDurableStore(directory: directory, allowedIDs: [.theme])
        let second = try SettingsDurableStore(directory: directory, allowedIDs: [.theme])
        let before = try first.readVersioned(theme)
        try second.write(.choice("Dark"), for: theme)
        try second.write(nil, for: theme)
        #expect(try first.readVersioned(theme) == .init(stored: before.stored, revision: 2))
        #expect(throws: SettingsDurableError.stale) { try first.commit(operationID: UUID(), value: .choice("Light"), expected: before.stored, expectedRevision: before.revision, for: theme) }
        try second.write(nil, for: theme)
        #expect(try first.readVersioned(theme).revision == 3)
    }

    @Test func operationIdentityCannotChangeValues() throws {
        let directory = location(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SettingsDurableStore(directory: directory, allowedIDs: [.theme])
        let operation = UUID()
        _ = try store.commit(operationID: operation, value: .choice("Dark"), expected: nil, expectedRevision: 0, for: theme)
        #expect(throws: SettingsDurableError.identityMismatch) { try store.commit(operationID: operation, value: .choice("Light"), expected: nil, expectedRevision: 0, for: theme) }
        #expect(try store.readVersioned(theme).stored == .choice("Dark"))
    }

    @Test func fourTypedIDsRoundTripAndKeepIndependentTargetRevisions() throws {
        let directory = location(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SettingsDurableStore(directory: directory, allowedIDs: Set(BrowserSettingID.allCases))
        let values: [(BrowserSettingID, BrowserSettingValue)] = [(.fadeInPages, .bool(false)), (.fadeDuration, .number(450)), (.theme, .choice("Light")), (.automaticLinkSplit, .bool(true))]
        for (id, value) in values { try store.write(value, for: SettingsRegistry.descriptor(id)) }
        let reopened = try SettingsDurableStore(directory: directory, allowedIDs: Set(BrowserSettingID.allCases))
        for (id, value) in values { #expect(try reopened.readVersioned(SettingsRegistry.descriptor(id)) == .init(stored: value, revision: 1)) }
        try reopened.write(.bool(false), for: SettingsRegistry.descriptor(.fadeInPages))
        #expect(try store.readVersioned(SettingsRegistry.descriptor(.fadeInPages)).revision == 2)
        for (id, _) in values where id != .fadeInPages { #expect(try store.readVersioned(SettingsRegistry.descriptor(id)).revision == 1) }
    }

    @Test(arguments: SettingsDurabilityBoundary.allCases)
    func crashAtEveryRealDurabilityBoundaryNeverBlindlyReplays(point: SettingsDurabilityBoundary) throws {
        let directory = location(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SettingsDurableStore(directory: directory, allowedIDs: [.theme])
        let operation = UUID()
        store.boundary = { if $0 == point { throw Crash() } }
        #expect(throws: Crash.self) { try store.commit(operationID: operation, value: .choice("Dark"), expected: nil, expectedRevision: 0, for: theme) }
        #expect(!store.supportsRecoverableCommit)
        let reopened = try SettingsDurableStore(directory: directory, allowedIDs: [.theme])
        let status = try reopened.operationWasApplied(operation)
        switch point {
        case .intentFileSynced:
            // The intent temp file was never admitted by rename. Status is
            // unknown, not an approval to retry. A restarted native coordinator
            // has no staged proposal/permit and cannot resurrect this action.
            #expect(status == nil)
            #expect(try reopened.readVersioned(theme) == .init(stored: nil, revision: 0))
        case .intentRenamed, .intentDirectorySynced, .stateFileSynced:
            #expect(status == false)
            #expect(try reopened.readVersioned(theme) == .init(stored: nil, revision: 1))
            #expect(throws: SettingsDurableError.notApplied) { try reopened.commit(operationID: operation, value: .choice("Dark"), expected: nil, expectedRevision: 0, for: theme) }
        default:
            #expect(status == true)
            #expect(try reopened.readVersioned(theme) == .init(stored: .choice("Dark"), revision: 1))
            _ = try reopened.commit(operationID: operation, value: .choice("Dark"), expected: nil, expectedRevision: 0, for: theme)
            #expect(try reopened.readVersioned(theme).revision == 1)
        }
    }

    @Test func recoveredNotAppliedRemainsStaleAfterOutcomeCompaction() throws {
        let directory = location(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SettingsDurableStore(directory: directory, allowedIDs: [.theme])
        let operation = UUID()
        store.boundary = { if $0 == .intentDirectorySynced { throw Crash() } }
        #expect(throws: Crash.self) { try store.commit(operationID: operation, value: .choice("Dark"), expected: nil, expectedRevision: 0, for: theme) }
        let reopened = try SettingsDurableStore(directory: directory, allowedIDs: [.theme])
        for _ in 0..<101 { try reopened.write(nil, for: theme) }
        #expect(try reopened.operationWasApplied(operation) == nil)
        #expect(throws: SettingsDurableError.stale) { try reopened.commit(operationID: operation, value: .choice("Dark"), expected: nil, expectedRevision: 0, for: theme) }
    }

    @Test func restartCannotResurrectAnUncertainNativeProposal() throws {
        let directory = location(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SettingsDurableStore(directory: directory, allowedIDs: [.theme])
        let coordinator = SettingsTransactionCoordinator(store: store)
        let session = UUID()
        let proposal = try coordinator.preview(id: .theme, value: .choice("Dark"), sessionID: session, generation: 1, questionOnly: false, available: true)
        store.boundary = { if $0 == .intentFileSynced { throw Crash() } }
        #expect(throws: SettingsAssistantError.recoveryRequired) { try coordinator.applyFromNativeUI(proposal, sessionID: session, generation: 1, questionOnly: false, available: true) }
        let restarted = SettingsTransactionCoordinator(store: try SettingsDurableStore(directory: directory, allowedIDs: [.theme]))
        #expect(throws: SettingsAssistantError.stalePreview) { try restarted.applyFromNativeUI(proposal, sessionID: session, generation: 1, questionOnly: false, available: true) }
        #expect(restarted.snapshot(.theme).effective == .choice("System"))
    }

    @Test func missingStateAfterMigrationCannotReimportDefaults() throws {
        let directory = location(); defer { try? FileManager.default.removeItem(at: directory) }
        let (name, defaults) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("Dark", forKey: "theme")
        let first = BrowserThemeStore(directory: directory, defaults: defaults)
        #expect(first.value == "Dark")
        try FileManager.default.removeItem(at: directory.appendingPathComponent(SettingsDurableStore.stateName))
        defaults.set("Light", forKey: "theme")
        let reopened = BrowserThemeStore(directory: directory, defaults: defaults)
        #expect(!reopened.canCommit)
        #expect(reopened.statusMessage != nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(SettingsDurableStore.stateName).path))
        #expect(defaults.string(forKey: "theme") == "Light")
    }

    @Test(arguments: ["future", "corrupt", "extraField"])
    func invalidAuthorityIsPreservedAndFrozen(kind: String) throws {
        let directory = location(); defer { try? FileManager.default.removeItem(at: directory) }
        _ = try SettingsDurableStore(directory: directory, allowedIDs: [.theme])
        let file = directory.appendingPathComponent(SettingsDurableStore.stateName)
        let original = try Data(contentsOf: file)
        var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        let invalid: Data
        if kind == "future" { object["schemaVersion"] = 2; invalid = try JSONSerialization.data(withJSONObject: object) }
        else if kind == "extraField" { object["unknown"] = true; invalid = try JSONSerialization.data(withJSONObject: object) }
        else { invalid = Data("broken state".utf8) }
        try invalid.write(to: file)
        #expect(throws: (any Error).self) { try SettingsDurableStore(directory: directory, allowedIDs: [.theme]) }
        #expect(try Data(contentsOf: file) == invalid)
    }

    @Test func themeMigrationPreservesValueOnceAndIgnoresRawDefaultsAfterwards() throws {
        let directory = location(); defer { try? FileManager.default.removeItem(at: directory) }
        let (name, defaults) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("Dark", forKey: "theme")
        let first = BrowserThemeStore(directory: directory, defaults: defaults)
        #expect(first.value == "Dark")
        #expect(first.revision == 0)
        defaults.set("Light", forKey: "theme")
        let reopened = BrowserThemeStore(directory: directory, defaults: defaults)
        #expect(reopened.value == "Dark")
        #expect(reopened.revision == 0)
        reopened.setManually("Dark")
        #expect(reopened.revision == 1)
        try first.refresh()
        #expect(first.revision == 1)
    }

    @Test func nativeThemeApplyAndUndoPreserveAbsenceWhileOtherKeysStayGated() throws {
        let directory = location(); defer { try? FileManager.default.removeItem(at: directory) }
        let (name, defaults) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        let owner = BrowserThemeStore(directory: directory, defaults: defaults)
        let store = SettingsNativeStore(defaults: defaults, theme: { owner })
        let coordinator = SettingsTransactionCoordinator(store: store)
        #expect(coordinator.canApply(.theme))
        for id in BrowserSettingID.allCases where id != .theme { #expect(!coordinator.canApply(id)) }
        let proposal = try coordinator.preview(id: .theme, value: .choice("Dark"), sessionID: UUID(), generation: 1, questionOnly: false, available: true)
        let receipt = try coordinator.applyFromNativeUI(proposal, sessionID: proposal.sessionID, generation: 1, questionOnly: false, available: true)
        #expect(owner.value == "Dark")
        #expect(defaults.string(forKey: "theme") == "Dark")
        try coordinator.undoFromNativeUI(receipt, available: true, questionOnly: false)
        #expect(owner.value == "System")
        #expect(owner.revision == 2)
        #expect(defaults.object(forKey: "theme") == nil)
    }

    @Test func themeQuestionsAndPreviewsDoNotChangePreferenceOrRevision() throws {
        let directory = location(); defer { try? FileManager.default.removeItem(at: directory) }
        let (name, defaults) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        let owner = BrowserThemeStore(directory: directory, defaults: defaults)
        let file = directory.appendingPathComponent(SettingsDurableStore.stateName)
        let before = try Data(contentsOf: file)
        let conversation = SettingsConversationCoordinator(transactions: SettingsTransactionCoordinator(store: SettingsNativeStore(defaults: defaults, theme: { owner })))
        conversation.input = "What does theme do?"; conversation.submit(available: true)
        #expect(conversation.proposal == nil)
        conversation.mode = .preview; conversation.input = "Set theme to Dark"; conversation.submit(available: true)
        #expect(conversation.proposal != nil)
        #expect(try Data(contentsOf: file) == before)
        #expect(owner.revision == 0)
        #expect(defaults.object(forKey: "theme") == nil)
    }

    @Test func questionsNeverReconcileAnOrphanOrBurnItsRevision() async throws {
        let directory = location(); defer { try? FileManager.default.removeItem(at: directory) }
        let (name, defaults) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        let owner = BrowserThemeStore(directory: directory, defaults: defaults)
        let writer = try SettingsDurableStore(directory: directory, allowedIDs: [.theme])
        writer.boundary = { if $0 == .intentDirectorySynced { throw Crash() } }
        #expect(throws: Crash.self) { try writer.write(.choice("Dark"), for: theme) }
        let file = directory.appendingPathComponent(SettingsDurableStore.stateName)
        let before = try Data(contentsOf: file)
        let conversation = SettingsConversationCoordinator(transactions: SettingsTransactionCoordinator(store: SettingsNativeStore(defaults: defaults, theme: { owner })))
        conversation.input = "What does theme do?"; conversation.submit(available: true)
        try await Task.sleep(for: .milliseconds(450)) // catch deferred write/retry bugs too
        #expect(conversation.proposal == nil)
        #expect(try Data(contentsOf: file) == before)
        #expect(owner.revision == 0)
        #expect(owner.canRetryLoading)
        owner.retryLoading() // deliberate native recovery, never the old change
        #expect(owner.value == "System")
        #expect(owner.revision == 1)
    }

    @Test func nativeAdapterRejectsRevokedOptInDespiteStaleAvailableViewAndKeepsManualThemeWorking() throws {
        let directory = location(); defer { try? FileManager.default.removeItem(at: directory) }
        let (name, defaults) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        let owner = BrowserThemeStore(directory: directory, defaults: defaults)
        let coordinator = SettingsTransactionCoordinator(store: SettingsNativeStore(defaults: defaults, theme: { owner }))
        let proposal = try coordinator.preview(id: .theme, value: .choice("Dark"), sessionID: UUID(), generation: 1, questionOnly: false, available: true)
        defaults.set(false, forKey: SettingsAssistantAvailability.enabledKey)
        #expect(throws: SettingsAssistantError.permissionDenied) { try coordinator.applyFromNativeUI(proposal, sessionID: proposal.sessionID, generation: 1, questionOnly: false, available: true) }
        #expect(!coordinator.recoveryRequired)
        #expect(owner.revision == 0)
        owner.setManually("Dark")
        #expect(owner.value == "Dark")
        #expect(owner.revision == 1)
    }

    @Test func selfConsistentButImpossibleRevisionStateIsRejected() throws {
        let directory = location(); defer { try? FileManager.default.removeItem(at: directory) }
        _ = try SettingsDurableStore(directory: directory, allowedIDs: [.theme])
        let file = directory.appendingPathComponent(SettingsDurableStore.stateName)
        var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var payload = envelope["payload"] as! [String: Any]
        payload["generation"] = 2 // impossible: sum of target revisions is zero
        let payloadBytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        envelope["payload"] = payload
        envelope["digest"] = SHA256.hash(data: payloadBytes).map { String(format: "%02x", $0) }.joined()
        let invalid = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
        try invalid.write(to: file)
        #expect(throws: SettingsDurableError.invalidState) { try SettingsDurableStore(directory: directory, allowedIDs: [.theme]) }
        #expect(try Data(contentsOf: file) == invalid)
    }

    @Test func postCommitReadFailureDoesNotReportAppliedOrPublishOptimistically() throws {
        let directory = location(); defer { try? FileManager.default.removeItem(at: directory) }
        let (name, defaults) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        let owner = BrowserThemeStore(directory: directory, defaults: defaults, boundary: { point in
            if point == .outcomeDirectorySynced { try Data("corrupt after commit".utf8).write(to: directory.appendingPathComponent(SettingsDurableStore.stateName)) }
        })
        let coordinator = SettingsTransactionCoordinator(store: SettingsNativeStore(defaults: defaults, theme: { owner }))
        let proposal = try coordinator.preview(id: .theme, value: .choice("Dark"), sessionID: UUID(), generation: 1, questionOnly: false, available: true)
        #expect(throws: SettingsAssistantError.recoveryRequired) { try coordinator.applyFromNativeUI(proposal, sessionID: proposal.sessionID, generation: 1, questionOnly: false, available: true) }
        #expect(owner.value == "System")
        #expect(!owner.canCommit)
        #expect(owner.statusMessage != nil)
    }

    @Test func testHostSelectionCannotChooseProductionAuthority() {
        for environment in [["XCTestConfigurationFilePath": "fixture"], ["XCInjectBundleInto": "fixture"]] { #expect(BrowserThemeEnvironment.isTest(environment: environment, arguments: [])) }
        #expect(BrowserThemeEnvironment.isTest(environment: [:], arguments: ["-uiTesting"]))
        #expect(!BrowserThemeEnvironment.isTest(environment: [:], arguments: []))
        let fixture = BrowserThemeEnvironment.testLocation(temporaryDirectory: URL(fileURLWithPath: "/tmp/synthetic-test-root"), identity: UUID())
        #expect(fixture.directory.path.hasPrefix("/tmp/synthetic-test-root/BrowserThemeTests-"))
        #expect(fixture.suite.hasPrefix("BrowserThemeTests."))
    }

    @Test func actualSecondProcessLockContentionAndCrashReleaseAreSafe() async throws {
        let directory = location(); defer { try? FileManager.default.removeItem(at: directory) }
        let (name, defaults) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        let owner = BrowserThemeStore(directory: directory, defaults: defaults, watchChanges: true)
        defer { owner.stopObserving() }
        let lock = directory.appendingPathComponent(SettingsDurableStore.lockName)
        let marker = directory.appendingPathComponent("child-lock-held")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import os,fcntl,sys; f=os.open(sys.argv[1],os.O_RDWR); fcntl.flock(f,fcntl.LOCK_EX); m=os.open(sys.argv[2],os.O_CREAT|os.O_WRONLY,0o600); os.write(m,b'held'); os.close(m); sys.stdin.buffer.read(1); os._exit(23)", lock.path, marker.path]
        let input = Pipe(); process.standardInput = input
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        for _ in 0..<100 { if FileManager.default.fileExists(atPath: marker.path) { break }; try await Task.sleep(for: .milliseconds(20)) }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(throws: SettingsDurableError.busy) { try owner.refresh() }
        #expect(owner.canCommit)
        let second = BrowserThemeStore(directory: directory, defaults: defaults)
        #expect(second.canRetryLoading)
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        process.waitUntilExit()
        #expect(process.terminationStatus == 23)
        second.retryLoading()
        #expect(second.canCommit)
        owner.retryLoading()
        #expect(owner.canCommit)
        #expect(owner.statusMessage == nil)
        owner.setManually("Dark")
        #expect(owner.value == "Dark")
        second.stopObserving()
    }
}
