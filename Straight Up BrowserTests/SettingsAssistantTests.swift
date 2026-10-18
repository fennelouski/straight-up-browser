import Foundation
import Testing
@testable import Browser

@MainActor private final class SettingsTestStore: SettingsPreferenceStore {
    var supportsRecoverableCommit = true
    var values: [BrowserSettingID: BrowserSettingValue] = [:]
    var writeCount = 0
    var failCommit = false
    var failReadOnce = false
    var operationIDs: Set<UUID> = []
    func read(_ descriptor: BrowserSettingDescriptor) -> BrowserSettingValue? { values[descriptor.id] }
    func readVersioned(_ descriptor: BrowserSettingDescriptor) throws -> SettingsStoreSnapshot {
        if failReadOnce { failReadOnce = false; throw SettingsAssistantError.applyFailed }
        return .init(stored: read(descriptor), revision: nil)
    }
    func write(_ value: BrowserSettingValue?, for descriptor: BrowserSettingDescriptor) throws {
        values[descriptor.id] = value
        writeCount += 1
    }
    func commit(operationID: UUID, value: BrowserSettingValue?, expected: BrowserSettingValue?, expectedRevision: UInt64?, for descriptor: BrowserSettingDescriptor) throws -> SettingsStoreSnapshot {
        if operationIDs.contains(operationID) { return .init(stored: value, revision: nil) }
        guard !failCommit, read(descriptor) == expected else { throw SettingsAssistantError.applyFailed }
        try write(value, for: descriptor)
        operationIDs.insert(operationID)
        return .init(stored: value, revision: nil)
    }
}

@MainActor struct SettingsAssistantTests {
    private func preview(_ coordinator: SettingsTransactionCoordinator, id: BrowserSettingID = .fadeInPages, value: BrowserSettingValue = .bool(false), session: UUID = UUID(), generation: UInt64 = 1, now: Date = Date()) throws -> SettingsValidatedProposal {
        try coordinator.preview(id: id, value: value, sessionID: session, generation: generation, questionOnly: false, available: true, now: now)
    }

    private func apply(_ proposal: SettingsValidatedProposal, with coordinator: SettingsTransactionCoordinator, now: Date = Date()) throws -> SettingsChangeReceipt {
        try coordinator.applyFromNativeUI(proposal, sessionID: proposal.sessionID, generation: proposal.requestGeneration, questionOnly: false, available: true, now: now)
    }

    private func json(value: String = "false", id: String = "appearance.fadeInPages", kind: String = "proposal", scope: String = "app") -> Data {
        Data("""
        {"schemaVersion":1,"requestContextID":"ctx_12345678","kind":"\(kind)","summary":"A suggestion, not a result.","settingReferences":["\(id)"],"question":null,"changes":[{"settingID":"\(id)","operation":"set","scope":{"kind":"\(scope)"},"value":\(value)}]}
        """.utf8)
    }

    @Test func questionAndPreviewNeverWrite() {
        let store = SettingsTestStore()
        let coordinator = SettingsConversationCoordinator(transactions: SettingsTransactionCoordinator(store: store))
        coordinator.input = "Why do pages fade?"
        coordinator.submit(available: true)
        #expect(coordinator.answer.contains("On"))
        #expect(coordinator.answer.contains("default"))
        #expect(coordinator.proposal == nil)
        coordinator.mode = .preview
        coordinator.input = "Turn page fading off"
        coordinator.submit(available: true)
        #expect(coordinator.proposal?.after == .bool(false))
        #expect(store.writeCount == 0)
    }

    @Test func questionInPreviewModeCannotCreateChange() {
        let store = SettingsTestStore()
        let conversation = SettingsConversationCoordinator(transactions: SettingsTransactionCoordinator(store: store))
        conversation.mode = .preview
        conversation.input = "Can you disable page fades?"
        conversation.submit(available: true)
        #expect(conversation.proposal == nil)
        #expect(store.writeCount == 0)
    }

    @Test func callAndVagueMotionAdviceDoNotBundlePreferences() {
        let store = SettingsTestStore()
        let conversation = SettingsConversationCoordinator(transactions: SettingsTransactionCoordinator(store: store))
        conversation.mode = .preview
        conversation.input = "Keep my call on the left while I research"
        conversation.submit(available: true)
        #expect(conversation.proposal == nil)
        #expect(conversation.answer.contains("existing call"))
        conversation.input = "I hate all this motion"
        conversation.submit(available: true)
        #expect(conversation.proposal == nil)
        #expect(store.writeCount == 0)
    }

    @Test(arguments: ["Disable page fades in this window", "Disable page fades for example.com", "Turn page fades off on this site", "Don't turn page fades off", "Do not disable page fading"])
    func scopedAndNegatedRequestsNeverBroadenToAppChange(request: String) {
        let store = SettingsTestStore()
        let conversation = SettingsConversationCoordinator(transactions: SettingsTransactionCoordinator(store: store))
        conversation.mode = .preview
        conversation.input = request
        conversation.submit(available: true)
        #expect(conversation.proposal == nil)
        #expect(store.writeCount == 0)
    }

    @Test func previewIsTypedAppScopedAndNoOpHasNoReceipt() throws {
        let store = SettingsTestStore()
        let coordinator = SettingsTransactionCoordinator(store: store)
        let proposal = try preview(coordinator)
        #expect(proposal.before.stored == nil)
        #expect(proposal.before.effective == .bool(true))
        #expect(proposal.settingID == .fadeInPages)
        #expect(throws: SettingsAssistantError.alreadySet) { try preview(coordinator, value: .bool(true)) }
        #expect(store.writeCount == 0)
    }

    @Test func explicitApplyIsIdempotentAndUndoRestoresAbsence() throws {
        let store = SettingsTestStore()
        let coordinator = SettingsTransactionCoordinator(store: store)
        let proposal = try preview(coordinator)
        let receipt = try apply(proposal, with: coordinator)
        #expect(try apply(proposal, with: coordinator) == receipt)
        #expect(store.writeCount == 1)
        #expect(store.values[.fadeInPages] == .bool(false))
        try coordinator.undoFromNativeUI(receipt, available: true, questionOnly: false)
        #expect(store.values[.fadeInPages] == nil)
        #expect(coordinator.snapshot(.fadeInPages).effective == .bool(true))
        #expect(throws: SettingsAssistantError.undoConflict) { try coordinator.undoFromNativeUI(receipt, available: true, questionOnly: false) }
    }

    @Test func manualEditAndABACycleInvalidatePreview() throws {
        let store = SettingsTestStore()
        let coordinator = SettingsTransactionCoordinator(store: store)
        let proposal = try preview(coordinator)
        coordinator.setManually(id: .fadeInPages, value: .bool(false))
        coordinator.setManually(id: .fadeInPages, value: .bool(true))
        #expect(coordinator.snapshot(.fadeInPages).effective == proposal.before.effective)
        #expect(throws: SettingsAssistantError.stalePreview) { try apply(proposal, with: coordinator) }
        #expect(store.writeCount == 2)
    }

    @Test func sameValueManualWriteBlocksUndo() throws {
        let store = SettingsTestStore()
        let coordinator = SettingsTransactionCoordinator(store: store)
        let receipt = try apply(preview(coordinator), with: coordinator)
        coordinator.setManually(id: .fadeInPages, value: .bool(false))
        #expect(throws: SettingsAssistantError.undoConflict) { try coordinator.undoFromNativeUI(receipt, available: true, questionOnly: false) }
        #expect(store.values[.fadeInPages] == .bool(false))
    }

    @Test func undoNeverMutatesAfterEnteringRecoveryDuringItsSnapshot() throws {
        let store = SettingsTestStore()
        let coordinator = SettingsTransactionCoordinator(store: store)
        let receipt = try apply(preview(coordinator), with: coordinator)
        store.failReadOnce = true
        #expect(throws: SettingsAssistantError.recoveryRequired) { try coordinator.undoFromNativeUI(receipt, available: true, questionOnly: false) }
        #expect(store.writeCount == 1)
        #expect(store.values[.fadeInPages] == .bool(false))
        #expect(coordinator.recoveryRequired)
    }

    @Test func externalValueChangeIsRecheckedBeforeCommit() throws {
        let store = SettingsTestStore()
        let coordinator = SettingsTransactionCoordinator(store: store)
        let proposal = try preview(coordinator)
        store.values[.fadeInPages] = .bool(false)
        #expect(throws: SettingsAssistantError.stalePreview) { try apply(proposal, with: coordinator) }
        #expect(store.writeCount == 0)
    }

    @Test func manualDraftBlocksOnlyItsTargetAndClosingRestoresEligibility() throws {
        let store = SettingsTestStore()
        let coordinator = SettingsTransactionCoordinator(store: store)
        let draft = UUID()
        coordinator.setDraft(.theme, owner: draft, isOpen: true)
        #expect(throws: SettingsAssistantError.draftConflict) { try preview(coordinator, id: .theme, value: .choice("Dark")) }
        _ = try preview(coordinator)
        coordinator.setDraft(.theme, owner: draft, isOpen: false)
        _ = try preview(coordinator, id: .theme, value: .choice("Dark"))
        #expect(store.writeCount == 0)
    }

    @Test func draftOpenedAfterPreviewBlocksApply() throws {
        let store = SettingsTestStore()
        let coordinator = SettingsTransactionCoordinator(store: store)
        let proposal = try preview(coordinator)
        coordinator.setDraft(.fadeInPages, owner: UUID(), isOpen: true)
        #expect(throws: SettingsAssistantError.draftConflict) { try apply(proposal, with: coordinator) }
    }

    @Test func revocationBeforeCommitPreventsWrite() throws {
        let store = SettingsTestStore()
        let coordinator = SettingsTransactionCoordinator(store: store)
        let proposal = try preview(coordinator)
        coordinator.revoke()
        #expect(throws: SettingsAssistantError.permissionDenied) { try apply(proposal, with: coordinator) }
        #expect(store.writeCount == 0)
    }

    @Test func revocationAfterCommitBlocksSubsequentOperations() throws {
        let store = SettingsTestStore()
        let coordinator = SettingsTransactionCoordinator(store: store)
        let proposal = try preview(coordinator)
        _ = try apply(proposal, with: coordinator)
        coordinator.revoke()
        #expect(throws: SettingsAssistantError.permissionDenied) { try apply(proposal, with: coordinator) }
        #expect(store.writeCount == 1)
    }

    @Test func finalLiveEligibilityWinsOverStaleViewAvailability() throws {
        let store = SettingsTestStore()
        var liveEligibility = true
        let coordinator = SettingsTransactionCoordinator(store: store, eligibilityCheck: { liveEligibility })
        let proposal = try preview(coordinator)
        liveEligibility = false
        #expect(throws: SettingsAssistantError.permissionDenied) { try apply(proposal, with: coordinator) }
        #expect(store.writeCount == 0)
        let second = SettingsTransactionCoordinator(store: store, eligibilityCheck: { liveEligibility })
        liveEligibility = true
        let receipt = try apply(preview(second), with: second)
        liveEligibility = false
        #expect(throws: SettingsAssistantError.permissionDenied) { try second.undoFromNativeUI(receipt, available: true, questionOnly: false) }
        #expect(store.writeCount == 1)
    }

    @Test func switchingToAskAndChangingRequestInvalidateOldCard() throws {
        let store = SettingsTestStore()
        let coordinator = SettingsTransactionCoordinator(store: store)
        let conversation = SettingsConversationCoordinator(transactions: coordinator)
        conversation.mode = .preview
        conversation.input = "Turn page fading off"
        conversation.submit(available: true)
        let proposal = try #require(conversation.proposal)
        conversation.mode = .ask
        #expect(conversation.proposal == nil)
        #expect(throws: SettingsAssistantError.stalePreview) { try apply(proposal, with: coordinator) }
        conversation.apply(available: true)
        #expect(store.writeCount == 0)
    }

    @Test func expiredAndWrongSessionCannotCommit() throws {
        let store = SettingsTestStore()
        let coordinator = SettingsTransactionCoordinator(store: store)
        let now = Date(timeIntervalSince1970: 10)
        let proposal = try preview(coordinator, now: now)
        #expect(throws: SettingsAssistantError.expired) { try apply(proposal, with: coordinator, now: now.addingTimeInterval(301)) }
        #expect(throws: SettingsAssistantError.stalePreview) { try coordinator.applyFromNativeUI(proposal, sessionID: UUID(), generation: proposal.requestGeneration, questionOnly: false, available: true, now: now) }
        #expect(store.writeCount == 0)
    }

    @Test func failureFreezesWriterWithoutClaimingSuccess() throws {
        let store = SettingsTestStore()
        let coordinator = SettingsTransactionCoordinator(store: store)
        let proposal = try preview(coordinator)
        store.failCommit = true
        #expect(throws: SettingsAssistantError.recoveryRequired) { try apply(proposal, with: coordinator) }
        #expect(coordinator.recoveryRequired)
        #expect(!coordinator.canApply)
        #expect(store.writeCount == 0)
    }

    @Test func legacyValuesAreReadAccuratelyAndNeverNormalizedWithoutPreview() throws {
        let store = SettingsTestStore()
        store.values[.fadeDuration] = .number(272.5)
        let coordinator = SettingsTransactionCoordinator(store: store)
        #expect(coordinator.snapshot(.fadeDuration).effective == .number(272.5))
        #expect(throws: SettingsAssistantError.invalidProposal) { try preview(coordinator, id: .fadeDuration, value: .number(275)) }
        let proposal = try preview(coordinator, id: .fadeDuration, value: .number(250))
        #expect(proposal.before.effective == .number(272.5))
        #expect(store.writeCount == 0)
    }

    @Test func productionCacheOnlyAdapterWithholdsApply() throws {
        let name = "SettingsAssistantTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let coordinator = SettingsTransactionCoordinator(store: SettingsDefaultsStore(defaults: defaults))
        let proposal = try preview(coordinator)
        #expect(!coordinator.canApply)
        #expect(throws: SettingsAssistantError.persistenceUnavailable) { try apply(proposal, with: coordinator) }
        #expect(defaults.object(forKey: "fadeInPages") == nil)
    }

    @Test func availabilityRequiresExplicitOptInAndMasterSwitch() throws {
        let name = "SettingsAvailabilityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!SettingsAssistantAvailability.isVisible(defaults: defaults))
        defaults.set(true, forKey: SettingsAssistantAvailability.enabledKey)
        #expect(SettingsAssistantAvailability.isVisible(defaults: defaults))
        defaults.set(false, forKey: "aiFeaturesEnabled")
        #expect(!SettingsAssistantAvailability.isVisible(defaults: defaults))
    }

    @Test func validSuggestionDoesNotWriteAndQuestionOnlyRejectsProposal() throws {
        let data = json()
        let suggestion = try SettingsAssistantSuggestion.decode(data, contextID: "ctx_12345678", questionOnly: false)
        #expect(suggestion.changes.count == 1)
        #expect(throws: SettingsAssistantError.questionOnly) { try SettingsAssistantSuggestion.decode(data, contextID: "ctx_12345678", questionOnly: true) }
    }

    @Test(arguments: ["0", "1", "\"false\"", "null", "[]", "{}"])
    func wrongBooleanTypesAreRejected(value: String) {
        #expect(throws: (any Error).self) { try SettingsAssistantSuggestion.decode(json(value: value), contextID: "ctx_12345678", questionOnly: false) }
    }

    @Test(arguments: ["50", "275", "1001", "true", "1e9999", "NaN"])
    func invalidDurationValuesAreRejected(value: String) {
        #expect(throws: (any Error).self) { try SettingsAssistantSuggestion.decode(json(value: value, id: "appearance.fadeDurationMs"), contextID: "ctx_12345678", questionOnly: false) }
    }

    @Test(arguments: ["security.strictSSL", "agent.externalConnections", "appearance.reduceMotion", "arbitrary.key"])
    func unknownAndSensitiveIDsAreRejected(id: String) {
        #expect(throws: (any Error).self) { try SettingsAssistantSuggestion.decode(json(id: id), contextID: "ctx_12345678", questionOnly: false) }
    }

    @Test func unknownFieldsDuplicateKeysScopeAndContextAreRejected() throws {
        let valid = String(decoding: json(), as: UTF8.self)
        let invalid = [
            valid.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2"),
            valid.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"approved\":true"),
            valid.replacingOccurrences(of: "\"value\":false", with: "\"value\":true,\"value\":false"),
            valid.replacingOccurrences(of: "\"scope\":{\"kind\":\"app\"}", with: "\"scope\":{\"kind\":\"app\",\"host\":\"example.com\"}"),
            valid.replacingOccurrences(of: "\"question\":null", with: "\"question\":\"Apply now?\""),
        ]
        for input in invalid {
            #expect(throws: (any Error).self) { try SettingsAssistantSuggestion.decode(Data(input.utf8), contextID: "ctx_12345678", questionOnly: false) }
        }
        #expect(throws: (any Error).self) { try SettingsAssistantSuggestion.decode(json(scope: "window"), contextID: "ctx_12345678", questionOnly: false) }
        #expect(throws: (any Error).self) { try SettingsAssistantSuggestion.decode(json(), contextID: "ctx_other123", questionOnly: false) }
    }

    @Test func excessiveDepthAndSizeAreRejected() {
        let deep = String(repeating: "[", count: 12) + "0" + String(repeating: "]", count: 12)
        #expect(throws: (any Error).self) { try SettingsAssistantSuggestion.decode(Data(deep.utf8), contextID: "ctx_12345678", questionOnly: false) }
        #expect(throws: (any Error).self) { try SettingsAssistantSuggestion.decode(Data(repeating: 32, count: 16_385), contextID: "ctx_12345678", questionOnly: false) }
    }
}

struct SettingsAssistantPolicyTests {
    @Test func settingsProfileDoesNotExpandLegacyProfiles() throws {
        let catalog = AgentToolCatalog.canonical
        try catalog.validate()
        #expect(catalog.descriptors(visibleIn: .browserOSMCP).count == 53)
        #expect(catalog.descriptors(visibleIn: .localMCP).count == 56)
        #expect(catalog.descriptors(visibleIn: .settingsAssistantV1).count == 4)
        #expect(catalog.descriptors(visibleIn: .settingsAssistantV1).allSatisfy { !$0.requiredCapabilities.intersection(AgentCapability.settingsCapabilities).isEmpty })
        #expect(catalog.descriptor(named: "browser_settings_apply") == nil)
        #expect(catalog.descriptor(named: "browser_settings_undo") == nil)
    }

    @Test func broadRunAndExactLegacyGrantCannotAuthorizeSettings() throws {
        let descriptor = try #require(AgentToolCatalog.canonical.descriptor(named: "browser_settings_get"))
        let context = AgentInvocationContext(runID: UUID(), entryPoint: .localMCP, humanPresent: true, toolName: descriptor.name, arguments: .object(["settingIDs": .array([.string("appearance.theme")])]), target: .none, runScope: .init(capabilities: Set(AgentCapability.allCases)))
        let now = Date()
        let digest = try AgentInvocationDigest.make(descriptor: descriptor, context: context)
        let request = AgentApprovalRequest(id: UUID(), runID: context.runID, invocationDigest: digest, toolName: descriptor.name, risk: descriptor.risk, normalizedArguments: context.arguments, target: .none, effectSummary: "Broad prior approval", dataLeavesDevice: false, createdAt: now, expiresAt: now.addingTimeInterval(60), availableScopes: [.exactTargetForRun])
        let grant = AgentApprovalGrant(request: request, scope: .exactTargetForRun, approvedAt: now, expiresAt: now.addingTimeInterval(60))
        let decision = try AgentPolicyEngine().evaluate(descriptor: descriptor, context: context, grants: [grant], at: now)
        guard case .deny(code: .capabilityOutsideRunScope, _) = decision else { Issue.record("Legacy grants must not authorize Settings"); return }
    }

    @Test func legacyCLIUnknownAndSettingsCapabilitiesFailClosed() throws {
        let name = "SettingsCLITests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: CLIAuthorization.Key.enabled)
        defaults.set(true, forKey: CLIAuthorization.Key.pageRead)
        let authorization = CLIAuthorization(defaults: defaults)
        #expect(CLIAuthorization.capability(forAgentTool: "unknown_tool") == .unavailable)
        #expect(!authorization.allows(action: "browser_settings_apply"))
        for descriptor in AgentToolCatalog.canonical.descriptors(visibleIn: .settingsAssistantV1) {
            #expect(!authorization.allows(capability: CLIAuthorization.capability(forAgentTool: descriptor.name)))
        }
        #expect(authorization.allows(action: "open"))
        #expect(authorization.allows(capability: CLIAuthorization.capability(forAgentTool: "list_pages")))
    }
}
