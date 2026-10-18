#if os(macOS)
import Foundation
import Testing
@testable import Browser

@MainActor struct PowerUpTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func withStore(_ body: (PowerUpLearning, UserDefaults) throws -> Void) throws {
        let name = "PowerUpTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(PowerUpLearning(defaults: defaults, now: now), defaults)
    }
    @Test func staticLibraryDoesNotOptInOrPersistSearch() throws {
        try withStore { store, defaults in
            #expect(!store.adaptiveEnabled)
            #expect(defaults.data(forKey: PowerUpLearning.storageKey) == nil)
            store.recordSuccess(feature: .globalOmnibar, method: .shortcut, isPrivate: false, now: now)
            #expect(store.state.records.isEmpty)
            #expect(defaults.data(forKey: PowerUpLearning.storageKey) == nil)
        }
    }
    @Test func optedOutAndPrivateActionsDonateNothing() throws {
        try withStore { store, _ in
            store.setAdaptiveEnabled(true)
            store.recordSuccess(feature: .splitLayout, method: .button, isPrivate: true, now: now)
            #expect(store.state.records.isEmpty)
            store.setAdaptiveEnabled(false)
            store.recordSuccess(feature: .splitLayout, method: .practice, isPrivate: false, now: now)
            #expect(store.state.records.isEmpty)
        }
    }
    @Test func threeShortcutsInOneSessionDoNotClaimMastery() throws {
        try withStore { store, defaults in
            store.setAdaptiveEnabled(true)
            for _ in 0..<3 { store.recordSuccess(feature: .quickOpen, method: .shortcut, isPrivate: false, now: now) }
            #expect(store.record(for: .quickOpen).knowledge == .available)
            let second = PowerUpLearning(defaults: defaults, now: now)
            second.recordSuccess(feature: .quickOpen, method: .shortcut, isPrivate: false, now: now)
            #expect(second.record(for: .quickOpen).knowledge == .available)
            let third = PowerUpLearning(defaults: defaults, now: now)
            third.recordSuccess(feature: .quickOpen, method: .shortcut, isPrivate: false, now: now)
            #expect(third.record(for: .quickOpen).knowledge == .mastered)
            #expect(!third.canShowTip(for: .quickOpen, context: .init(), now: now))
        }
    }
    @Test func samplePracticeNeedsLaterIndependentUseForMastery() throws {
        try withStore { store, _ in
            store.setAdaptiveEnabled(true)
            store.recordSuccess(feature: .savedWorkspace, method: .practice, isPrivate: false, now: now)
            #expect(store.record(for: .savedWorkspace).knowledge == .familiar)
            store.recordSuccess(feature: .savedWorkspace, method: .button, isPrivate: false, now: now)
            #expect(store.record(for: .savedWorkspace).knowledge == .mastered)
        }
    }
    @Test func knownCanBeUndoneAndSuppressionSurvivesOptOut() throws {
        try withStore { store, defaults in
            let previous = store.markKnown(.centerWindow)
            #expect(!store.isRecommended(.centerWindow))
            store.restore(previous, for: .centerWindow)
            #expect(store.isRecommended(.centerWindow))
            store.suppress(.centerWindow)
            store.setAdaptiveEnabled(false)
            #expect(PowerUpLearning(defaults: defaults, now: now).record(for: .centerWindow).knowledge == .suppressed)
        }
    }
    private func eligibleStore(_ defaults: UserDefaults, feature: PowerUpFeatureID, dayOffset: Int = 0) -> PowerUpLearning {
        let date = now.addingTimeInterval(Double(dayOffset) * 86_400)
        let first = PowerUpLearning(defaults: defaults, now: date)
        first.setAdaptiveEnabled(true)
        first.recordSuccess(feature: feature, method: .menu, isPrivate: false, now: date)
        let second = PowerUpLearning(defaults: defaults, now: date)
        for _ in 0..<2 { second.recordSuccess(feature: feature, method: .menu, isPrivate: false, now: date) }
        return second
    }
    @Test func tipBudgetRequiresSuccessfulUsesAcrossSessionsAndNoReplacementsToday() throws {
        try withStore { _, defaults in
            let store = eligibleStore(defaults, feature: .swapPanes)
            #expect(store.canShowTip(for: .swapPanes, context: .init(), now: now))
            #expect(store.consumeTip(for: .swapPanes, context: .init(), now: now))
            #expect(!store.canShowTip(for: .swapPanes, context: .init(), now: now))
            let next = eligibleStore(defaults, feature: .splitLayout)
            #expect(!next.canShowTip(for: .splitLayout, context: .init(), now: now))
            #expect(next.consumeTip(for: .splitLayout, context: .init(), now: now.addingTimeInterval(86_400)))
            let third = eligibleStore(defaults, feature: .savedWorkspace)
            #expect(!third.canShowTip(for: .savedWorkspace, context: .init(), now: now.addingTimeInterval(2 * 86_400)))
        }
    }
    @Test func snoozeExpiryDoesNotResetLifetimeExposure() throws {
        try withStore { _, defaults in
            let store = eligibleStore(defaults, feature: .swapPanes)
            #expect(store.consumeTip(for: .swapPanes, context: .init(), now: now))
            store.snooze(.swapPanes, now: now)
            #expect(!store.isRecommended(.swapPanes, now: now.addingTimeInterval(29 * 86_400)))
            #expect(store.isRecommended(.swapPanes, now: now.addingTimeInterval(30 * 86_400)))
            #expect(!store.canShowTip(for: .swapPanes, context: .init(), now: now.addingTimeInterval(31 * 86_400)))
        }
    }
    @Test func everyUnsafeContextBlocksTeachingAndPauseIsIndefinite() throws {
        try withStore { _, defaults in
            let store = eligibleStore(defaults, feature: .quickOpen)
            let unsafe: [PowerUpTipContext] = [
                .init(age: 31), .init(typing: true), .init(composing: true), .init(fullScreen: true),
                .init(modal: true), .init(isPrivate: true), .init(activeMedia: true), .init(dragging: true),
                .init(recordingShortcut: true), .init(accessibilityAnnouncement: true),
                .init(secondsSinceTransient: 9), .init(hasValidBinding: false)
            ]
            for context in unsafe { #expect(!store.canShowTip(for: .quickOpen, context: context, now: now)) }
            store.setTipsPaused(true)
            #expect(!store.canShowTip(for: .quickOpen, context: .init(), now: now.addingTimeInterval(500 * 86_400)))
        }
    }
    @Test func oldAggregatesExpireWithoutErasingPermanentPreferences() throws {
        try withStore { store, defaults in
            store.setAdaptiveEnabled(true)
            store.recordSuccess(feature: .quickOpen, method: .menu, isPrivate: false, now: now)
            store.recordSuccess(feature: .centerWindow, method: .shortcut, isPrivate: false, now: now)
            store.markKnown(.centerWindow)
            store.suppress(.swapPanes)
            let restored = PowerUpLearning(defaults: defaults, now: now.addingTimeInterval(91 * 86_400))
            #expect(restored.record(for: .quickOpen).directUses == 0)
            #expect(restored.record(for: .quickOpen).knowledge == .unseen)
            #expect(restored.record(for: .centerWindow).knowledge == .mastered)
            #expect(restored.record(for: .centerWindow).shortcutSessions.isEmpty)
            #expect(restored.record(for: .swapPanes).knowledge == .suppressed)
        }
    }
    @Test func continuingUseDoesNotExtendAggregateRetention() throws {
        try withStore { store, defaults in
            store.setAdaptiveEnabled(true)
            store.recordSuccess(feature: .quickOpen, method: .menu, isPrivate: false, now: now)
            store.recordSuccess(feature: .quickOpen, method: .menu, isPrivate: false, now: now.addingTimeInterval(89 * 86_400))
            #expect(store.record(for: .quickOpen).directUses == 2)
            let restored = PowerUpLearning(defaults: defaults, now: now.addingTimeInterval(90 * 86_400))
            #expect(restored.record(for: .quickOpen).directUses == 0)
        }
    }
    @Test func futureSchemaIsPreservedAndDeleteIsNarrow() throws {
        try withStore { store, defaults in
            defaults.set("retain", forKey: "unrelated.setting")
            defaults.set("declined", forKey: "browserOnboarding.v1")
            store.markKnown(.quickOpen)
            store.deleteHistory()
            #expect(store.state.records.isEmpty)
            #expect(defaults.string(forKey: "unrelated.setting") == "retain")
            #expect(defaults.string(forKey: "browserOnboarding.v1") == "declined")
            var future = PowerUpLearningState(); future.schemaVersion = 2
            let bytes = try JSONEncoder().encode(future)
            defaults.set(bytes, forKey: PowerUpLearning.storageKey)
            let restored = PowerUpLearning(defaults: defaults, now: now)
            restored.setAdaptiveEnabled(true); restored.markKnown(.quickOpen); restored.deleteHistory()
            #expect(!restored.supportsCurrentSchema)
            #expect(defaults.data(forKey: PowerUpLearning.storageKey) == bytes)
        }
    }
    @Test func persistedLearningHasOnlyFixedIDsAndBoundedCoarseValues() throws {
        try withStore { store, defaults in
            store.setAdaptiveEnabled(true)
            for _ in 0..<500 { store.recordSuccess(feature: .quickOpen, method: .menu, isPrivate: false, now: now) }
            let value = store.record(for: .quickOpen)
            #expect(value.directUses == 99)
            #expect(value.directSessions.count == 1)
            let data = try #require(defaults.data(forKey: PowerUpLearning.storageKey))
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(object.keys).isSubset(of: ["schemaVersion", "session", "adaptiveEnabled", "tipsPaused", "records", "tipDays"]))
            #expect(store.state.records.keys.allSatisfy { PowerUpFeatureID(rawValue: $0) != nil })
        }
    }
    @Test func sampleSwapRequiresPreviewAndPreservesSlotsAndProportions() {
        var sample = PowerUpSamplePractice()
        let old = sample.contents, ratio = sample.leadingRatio
        sample.select(0); sample.select(2)
        #expect(sample.contents == old && sample.swapPreview != nil && !sample.completed)
        sample.cancelSwap(); #expect(sample.contents == old)
        sample.select(0); sample.select(2); sample.applySwap()
        #expect(sample.contents[0] == old[2] && sample.contents[2] == old[0])
        #expect(sample.leadingRatio == ratio && Set(sample.contents) == Set(old) && sample.completed)
    }
    @Test func sampleSaveRestoreIsExplicitAndWidthCycleUsesFullRatios() {
        var sample = PowerUpSamplePractice()
        let original = sample.contents
        sample.restoreSample(); #expect(!sample.completed)
        sample.saveSample(); sample.changeSample(); #expect(sample.hasChangedSaved)
        sample.restoreSample(); #expect(sample.contents == original && sample.completed)
        var center = PowerUpSamplePractice()
        #expect(center.centerRatio == 0.5)
        center.cycleWidth(); #expect(center.centerRatio == 1.0 / 3.0)
        center.cycleWidth(); #expect(center.centerRatio == 0.25 && !center.completed)
        center.cycleWidth(); #expect(center.centerRatio == 0.5 && center.completed)
    }
}
#endif
