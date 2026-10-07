#if os(macOS)
import Foundation
import Testing
@testable import Browser

@MainActor
struct DefaultBrowserEngagementTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func withDefaults(
        policy: DefaultBrowserPromptPolicy = .init(),
        _ body: (UserDefaults) throws -> Void
    ) throws {
        let name = "DefaultBrowserEngagementTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(try JSONEncoder().encode(policy), forKey: DefaultBrowserEngagement.storageKey)
        try body(defaults)
    }

    @Test func foregroundChangesCountOnlyOneUsedLaunch() throws {
        try withDefaults { defaults in
            let tracker = DefaultBrowserEngagement(defaults: defaults, launchDate: now)
            tracker.sample(isBrowsing: false, now: now)
            #expect(tracker.policy.usedLaunches == 0)
            tracker.sample(isBrowsing: true, now: now.addingTimeInterval(1))
            tracker.sample(isBrowsing: false, now: now.addingTimeInterval(20))
            tracker.sample(isBrowsing: true, now: now.addingTimeInterval(40))
            #expect(tracker.policy.usedLaunches == 1)
            #expect(tracker.policy.recentUsage(at: now.addingTimeInterval(40)) == 19)
        }
    }

    @Test func resigningFocusFlushesFinalSecondsWithoutCreditingBackgroundTime() throws {
        try withDefaults { defaults in
            let tracker = DefaultBrowserEngagement(defaults: defaults, launchDate: now)
            tracker.sample(isBrowsing: true, now: now)
            tracker.sample(isBrowsing: false, now: now.addingTimeInterval(12))
            tracker.sample(isBrowsing: false, now: now.addingTimeInterval(600))
            let restored = DefaultBrowserEngagement(defaults: defaults, launchDate: now.addingTimeInterval(601))
            #expect(restored.policy.recentUsage(at: now.addingTimeInterval(601)) == 12)
        }
    }

    @Test func sleepAndClockRollbackDoNotEarnUsage() throws {
        try withDefaults { defaults in
            let tracker = DefaultBrowserEngagement(defaults: defaults, launchDate: now)
            tracker.sample(isBrowsing: true, now: now)
            tracker.sample(isBrowsing: true, now: now.addingTimeInterval(-60))
            tracker.sample(isBrowsing: true, now: now.addingTimeInterval(3_600))
            #expect(tracker.policy.recentUsage(at: now.addingTimeInterval(3_600)) == 0)
            tracker.sample(isBrowsing: true, now: now.addingTimeInterval(3_630))
            #expect(tracker.policy.recentUsage(at: now.addingTimeInterval(3_630)) == 30)
        }
    }

    @Test func crossingFourHoursWaitsForNextLaunch() throws {
        var policy = DefaultBrowserPromptPolicy()
        policy.recordUsage(from: now.addingTimeInterval(-14_390), to: now)
        try withDefaults(policy: policy) { defaults in
            let tracker = DefaultBrowserEngagement(defaults: defaults, launchDate: now)
            tracker.sample(isBrowsing: true, now: now)
            tracker.sample(isBrowsing: true, now: now.addingTimeInterval(30))
            #expect(!tracker.offerAtLaunch(isDefault: false))
            let nextLaunch = now.addingTimeInterval(31)
            let restored = DefaultBrowserEngagement(defaults: defaults, launchDate: nextLaunch)
            restored.sample(isBrowsing: true, now: nextLaunch)
            #expect(restored.offerAtLaunch(isDefault: false))
            #expect(!restored.offerAtLaunch(isDefault: false))
        }
    }

    @Test func launchEligibilitySurvivesLaterRollingWindowPruning() throws {
        var policy = DefaultBrowserPromptPolicy()
        let oldest = now.addingTimeInterval(-7 * 86_400)
        policy.recordUsage(from: oldest, to: oldest.addingTimeInterval(14_400))
        try withDefaults(policy: policy) { defaults in
            let tracker = DefaultBrowserEngagement(defaults: defaults, launchDate: now)
            tracker.sample(isBrowsing: true, now: now.addingTimeInterval(600))
            tracker.sample(isBrowsing: true, now: now.addingTimeInterval(630))
            #expect(tracker.policy.recentUsage(at: now.addingTimeInterval(630)) < 14_400)
            #expect(tracker.offerAtLaunch(isDefault: false))
        }
    }

    @Test func defaultAndDisabledPreferencesSuppressEligibleLaunch() throws {
        var policy = DefaultBrowserPromptPolicy()
        policy.hasOffered = true
        try withDefaults(policy: policy) { defaults in
            let tracker = DefaultBrowserEngagement(defaults: defaults, launchDate: now)
            #expect(!tracker.offerAtLaunch(isDefault: true))
            defaults.set(false, forKey: DefaultBrowser.promptEnabledKey)
            let next = DefaultBrowserEngagement(defaults: defaults, launchDate: now)
            #expect(!next.offerAtLaunch(isDefault: false))
        }
    }

    @Test func neverPersistsAndExplicitSettingsOptInRearms() throws {
        var policy = DefaultBrowserPromptPolicy()
        policy.hasOffered = true
        try withDefaults(policy: policy) { defaults in
            let tracker = DefaultBrowserEngagement(defaults: defaults, launchDate: now)
            tracker.never()
            #expect(!defaults.bool(forKey: DefaultBrowser.promptEnabledKey))
            let restored = DefaultBrowserEngagement(defaults: defaults, launchDate: now)
            #expect(!restored.offerAtLaunch(isDefault: false))
            defaults.set(true, forKey: DefaultBrowser.promptEnabledKey)
            restored.rearm()
            let optedIn = DefaultBrowserEngagement(defaults: defaults, launchDate: now)
            #expect(optedIn.offerAtLaunch(isDefault: false))
            #expect(!optedIn.offersNever)
        }
    }

    @Test func defaultActionBreaksConsecutiveDismissalsAndPausesOffers() throws {
        try withDefaults { defaults in
            let tracker = DefaultBrowserEngagement(defaults: defaults, launchDate: now)
            tracker.sample(isBrowsing: true, now: now)
            tracker.dismiss()
            tracker.recordDefaultAction()
            #expect(tracker.policy.dismissals == 0)
            #expect(tracker.policy.nextOfferLaunch == 11)
            #expect(!tracker.offersNever)
        }
    }
}
#endif
