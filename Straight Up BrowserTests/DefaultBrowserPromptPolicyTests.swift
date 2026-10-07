import Foundation
import Testing
@testable import Browser

struct DefaultBrowserPromptPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func firstOfferRequiresFourRecentHours() {
        var policy = DefaultBrowserPromptPolicy()
        policy.recordUsage(from: now.addingTimeInterval(-14_399), to: now)
        #expect(!policy.shouldOffer(at: now, enabled: true, isDefault: false))
        policy.recordUsage(from: now, to: now.addingTimeInterval(1))
        #expect(policy.shouldOffer(at: now.addingTimeInterval(1), enabled: true, isDefault: false))
        #expect(!policy.shouldOffer(at: now.addingTimeInterval(8 * 86_400), enabled: true, isDefault: false))
    }

    @Test func rollingWindowClipsIntervalsAtBothEnds() {
        var policy = DefaultBrowserPromptPolicy()
        policy.recordUsage(from: now.addingTimeInterval(-8 * 86_400), to: now.addingTimeInterval(-7 * 86_400 + 600))
        #expect(policy.recentUsage(at: now) == 600)
        #expect(policy.recentUsage(at: now.addingTimeInterval(-7 * 86_400 + 300)) == 86_700)
    }

    @Test func twoDismissalsWaitForTenMoreUsedLaunches() {
        var policy = DefaultBrowserPromptPolicy()
        policy.hasOffered = true
        policy.usedLaunches = 1
        policy.recordDismissal()
        #expect(!policy.shouldOffer(at: now, enabled: true, isDefault: false))
        policy.usedLaunches = 2
        #expect(policy.shouldOffer(at: now, enabled: true, isDefault: false))
        #expect(!policy.offersNever)
        policy.recordDismissal()
        for launch in 3...11 {
            policy.usedLaunches = launch
            #expect(!policy.shouldOffer(at: now, enabled: true, isDefault: false))
            #expect(!policy.offersNever)
        }
        policy.usedLaunches = 12
        #expect(policy.shouldOffer(at: now, enabled: true, isDefault: false))
        #expect(policy.offersNever)
    }

    @Test func cooldownIsRelativeToSecondDismissal() {
        var policy = DefaultBrowserPromptPolicy()
        policy.hasOffered = true
        policy.usedLaunches = 20
        policy.recordDismissal()
        policy.usedLaunches = 21
        policy.recordDismissal()
        #expect(policy.nextOfferLaunch == 31)
    }

    @Test func neverDisabledAndDefaultAlwaysSuppress() throws {
        var policy = DefaultBrowserPromptPolicy()
        policy.hasOffered = true
        #expect(!policy.shouldOffer(at: now, enabled: false, isDefault: false))
        #expect(!policy.shouldOffer(at: now, enabled: true, isDefault: true))
        policy.never = true
        let restored = try JSONDecoder().decode(DefaultBrowserPromptPolicy.self, from: JSONEncoder().encode(policy))
        #expect(!restored.shouldOffer(at: now, enabled: true, isDefault: false))
    }

    @Test func usagePrunesOldDataAndMergesContinuousSamples() {
        var policy = DefaultBrowserPromptPolicy()
        policy.recordUsage(from: now.addingTimeInterval(-8 * 86_400), to: now.addingTimeInterval(-8 * 86_400 + 30))
        policy.recordUsage(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(-30))
        policy.recordUsage(from: now.addingTimeInterval(-30), to: now)
        #expect(policy.usage.count == 1)
        #expect(policy.recentUsage(at: now) == 60)
    }
    @Test func overlappingSamplesDoNotDoubleCountAndBriefBreaksStaySeparate() {
        var policy = DefaultBrowserPromptPolicy()
        policy.recordUsage(from: now, to: now.addingTimeInterval(30))
        policy.recordUsage(from: now.addingTimeInterval(20), to: now.addingTimeInterval(40))
        #expect(policy.recentUsage(at: now.addingTimeInterval(40)) == 40)
        policy.recordUsage(from: now.addingTimeInterval(40.5), to: now.addingTimeInterval(50.5))
        #expect(policy.usage.count == 2)
        #expect(policy.recentUsage(at: now.addingTimeInterval(50.5)) == 50)
    }

}
