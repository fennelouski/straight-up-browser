import Foundation
import Testing
@testable import Browser

@MainActor
struct PageFadeCircuitBreakerTests {
    private final class Clock { var time: TimeInterval = 0 }
    private let page = URL(string: "https://example.test/call?x=1&x=2#room")!

    @Test func secondAttemptAtInclusiveBoundaryIsSuppressedAndDuplicatesDoNotCount() {
        let clock = Clock()
        let policy = PageFadeCircuitBreaker(now: { clock.time })
        let tab = UUID(), first = UUID()
        policy.setResidence(context: tab, committedURL: page, eligible: true)
        #expect(policy.attempt(context: tab, url: page, episode: first, reducedMotion: false).shouldAnimate)
        #expect(policy.attempt(context: tab, url: page, episode: first, reducedMotion: false).isDuplicate)
        clock.time = 2
        let second = policy.attempt(context: tab, url: page, episode: UUID(), reducedMotion: false)
        #expect(second.isSuppressed)
        #expect(!second.shouldAnimate)
    }

    @Test func slidingPairsExtendSuppressionWhileIsolatedAttemptsDoNot() {
        let clock = Clock(), tab = UUID()
        let policy = PageFadeCircuitBreaker(now: { clock.time })
        policy.setResidence(context: tab, committedURL: page, eligible: true)
        for time in [0.0, 1.9, 3.8] {
            clock.time = time
            _ = policy.attempt(context: tab, url: page, episode: UUID(), reducedMotion: false)
        }
        clock.time = 1_800
        #expect(!policy.attempt(context: tab, url: page, episode: UUID(), reducedMotion: false).shouldAnimate)
        clock.time = 3_603.799_999
        #expect(policy.isSuppressed(context: tab, url: page))
        clock.time = 3_603.8
        #expect(!policy.isSuppressed(context: tab, url: page))
    }

    @Test func justOutsideBoundaryAndIndependentContextsDoNotTrip() {
        let clock = Clock(), tab = UUID(), other = UUID()
        let policy = PageFadeCircuitBreaker(now: { clock.time })
        _ = policy.attempt(context: tab, url: page, episode: UUID(), reducedMotion: false)
        clock.time = 2.001
        #expect(policy.attempt(context: tab, url: page, episode: UUID(), reducedMotion: false).shouldAnimate)
        #expect(policy.attempt(context: other, url: page, episode: UUID(), reducedMotion: false).shouldAnimate)
    }

    @Test func pairWinsOverRecoveryAtTheExactDeadline() {
        let clock = Clock(), tab = UUID()
        let policy = PageFadeCircuitBreaker(now: { clock.time })
        policy.setResidence(context: tab, committedURL: page, eligible: true)
        for time in [0.0, 1.0, 3_600.0, 3_601.0] {
            clock.time = time
            _ = policy.attempt(context: tab, url: page, episode: UUID(), reducedMotion: false)
        }
        #expect(policy.isSuppressed(context: tab, url: page))
        clock.time = 7_200.999
        #expect(policy.isSuppressed(context: tab, url: page))
        clock.time = 7_201
        #expect(!policy.isSuppressed(context: tab, url: page))
    }

    @Test func reloadAndPaneFocusRetainResidenceButVisibilityAndNavigationResetIt() {
        let clock = Clock(), tab = UUID()
        let policy = PageFadeCircuitBreaker(now: { clock.time })
        policy.setResidence(context: tab, committedURL: page, eligible: true)
        _ = policy.attempt(context: tab, url: page, episode: UUID(), reducedMotion: false)
        clock.time = 1
        _ = policy.attempt(context: tab, url: page, episode: UUID(), reducedMotion: false)
        clock.time = 3_000
        policy.setResidence(context: tab, committedURL: page, eligible: true)
        clock.time = 3_601
        #expect(!policy.isSuppressed(context: tab, url: page))
        _ = policy.attempt(context: tab, url: page, episode: UUID(), reducedMotion: false)
        clock.time = 3_602
        _ = policy.attempt(context: tab, url: page, episode: UUID(), reducedMotion: false)
        policy.setResidence(context: tab, committedURL: page, eligible: false)
        clock.time = 4_000
        policy.setResidence(context: tab, committedURL: page, eligible: true)
        clock.time = 7_599.999
        #expect(policy.isSuppressed(context: tab, url: page))
        clock.time = 7_600
        #expect(!policy.isSuppressed(context: tab, url: page))
    }

    @Test func leavingSuppressedURLRequiresANewContinuousHourOnReturn() {
        let clock = Clock(), tab = UUID()
        let policy = PageFadeCircuitBreaker(now: { clock.time })
        policy.setResidence(context: tab, committedURL: page, eligible: true)
        _ = policy.attempt(context: tab, url: page, episode: UUID(), reducedMotion: false)
        clock.time = 1
        _ = policy.attempt(context: tab, url: page, episode: UUID(), reducedMotion: false)
        clock.time = 500
        policy.setResidence(context: tab, committedURL: URL(string: "https://example.test/other"), eligible: true)
        clock.time = 1_200
        policy.setResidence(context: tab, committedURL: page, eligible: true)
        clock.time = 4_799.999
        #expect(policy.isSuppressed(context: tab, url: page))
        clock.time = 4_800
        #expect(!policy.isSuppressed(context: tab, url: page))
    }

    @Test func sleepResetsResidenceAndAttemptHistoryWithoutDroppingTheLatch() {
        let clock = Clock(), tab = UUID()
        let policy = PageFadeCircuitBreaker(now: { clock.time })
        policy.setResidence(context: tab, committedURL: page, eligible: true)
        for time in [0.0, 1.0] {
            clock.time = time
            _ = policy.attempt(context: tab, url: page, episode: UUID(), reducedMotion: false)
        }
        clock.time = 3_540
        policy.interrupt(clearRecentAttempts: true)
        clock.time = 3_840
        policy.setResidence(context: tab, committedURL: page, eligible: true)
        #expect(policy.isSuppressed(context: tab, url: page))
        clock.time = 7_440
        #expect(!policy.isSuppressed(context: tab, url: page))
    }

    @Test func reduceMotionStillObservesAttemptsAndCanRecoverWithoutReplaying() {
        let clock = Clock(), tab = UUID()
        let policy = PageFadeCircuitBreaker(now: { clock.time })
        policy.setResidence(context: tab, committedURL: page, eligible: true)
        #expect(!policy.attempt(context: tab, url: page, episode: UUID(), reducedMotion: true).shouldAnimate)
        clock.time = 1
        #expect(policy.attempt(context: tab, url: page, episode: UUID(), reducedMotion: true).isSuppressed)
        clock.time = 3_601
        #expect(!policy.isSuppressed(context: tab, url: page))
        #expect(!policy.attempt(context: tab, url: page, episode: UUID(), reducedMotion: true).shouldAnimate)
    }

    @Test func aPreSleepRedirectCannotReintroduceClearedAttemptHistory() {
        let clock = Clock(), tab = UUID(), redirect = UUID()
        let policy = PageFadeCircuitBreaker(now: { clock.time })
        _ = policy.attempt(context: tab, url: page, episode: UUID(), reducedMotion: false)
        clock.time = 0.5
        _ = policy.attempt(context: tab, url: URL(string: "https://example.test/redirect"), episode: redirect, reducedMotion: false)
        policy.interrupt(clearRecentAttempts: true)
        clock.time = 1.5
        #expect(policy.attempt(context: tab, url: page, episode: UUID(), reducedMotion: false).shouldAnimate)
        #expect(!policy.reconcile(context: tab, episode: redirect, committedURL: page))
        #expect(!policy.isSuppressed(context: tab, url: page))
    }

    @Test func redirectMovesOneAttemptAndLatchesNewlyDiscoveredPairAtReconciliation() {
        let clock = Clock(), tab = UUID(), episode = UUID()
        let target = URL(string: "https://example.test/redirect")!
        let policy = PageFadeCircuitBreaker(now: { clock.time })
        _ = policy.attempt(context: tab, url: page, episode: UUID(), reducedMotion: false)
        clock.time = 1
        _ = policy.attempt(context: tab, url: target, episode: episode, reducedMotion: false)
        clock.time = 20
        #expect(policy.reconcile(context: tab, episode: episode, committedURL: page))
        policy.setResidence(context: tab, committedURL: page, eligible: true)
        #expect(policy.attempt(context: tab, url: page, episode: episode, reducedMotion: false).isDuplicate)
        clock.time = 3_619.999
        #expect(policy.isSuppressed(context: tab, url: page))
        clock.time = 3_620
        #expect(!policy.isSuppressed(context: tab, url: page))
    }

    @Test func URLIdentityKeepsQueryPathAndFragmentDistinctions() {
        #expect(PageFadeCircuitBreaker.identity(for: URL(string: "HTTPS://EXAMPLE.TEST:443")) == "https://example.test/")
        #expect(PageFadeCircuitBreaker.identity(for: URL(string: "http://EXAMPLE.TEST:80")) == "http://example.test/")
        for different in ["https://example.test/Call?x=1&x=2#room",
                          "https://example.test/call?x=2&x=1#room",
                          "https://example.test/call?x=1#room",
                          "https://example.test/call?x=1&x=2#other"] {
            #expect(PageFadeCircuitBreaker.identity(for: page) != PageFadeCircuitBreaker.identity(for: URL(string: different)))
        }
        #expect(PageFadeCircuitBreaker.identity(for: nil) == nil)
    }

    @Test func overflowFailsClosedAndCloseClearsSessionState() {
        let clock = Clock(), tab = UUID()
        let policy = PageFadeCircuitBreaker(maximumKeys: 2, now: { clock.time })
        for index in 0..<4 {
            let url = URL(string: "https://example.test/\(index)")!
            policy.setResidence(context: tab, committedURL: url, eligible: true)
            _ = policy.attempt(context: tab, url: url, episode: UUID(), reducedMotion: false)
            clock.time += 1
            _ = policy.attempt(context: tab, url: url, episode: UUID(), reducedMotion: false)
            clock.time += 3
        }
        #expect(policy.retainedKeyCount(context: tab) <= 3)
        #expect(policy.isSuppressed(context: tab, url: URL(string: "https://example.test/3")))
        policy.close(context: tab)
        #expect(policy.retainedKeyCount(context: tab) == 0)
        #expect(policy.attempt(context: tab, url: page, episode: UUID(), reducedMotion: false).shouldAnimate)
    }

    @Test func overflowCanEarnOneQuietHourButLosesCreditOnNavigation() {
        let clock = Clock(), tab = UUID()
        let policy = PageFadeCircuitBreaker(maximumKeys: 1, now: { clock.time })
        policy.setResidence(context: tab, committedURL: page, eligible: true)
        _ = policy.attempt(context: tab, url: page, episode: UUID(), reducedMotion: false)
        clock.time = 1
        _ = policy.attempt(context: tab, url: page, episode: UUID(), reducedMotion: false)
        let extra = URL(string: "https://example.test/extra")!
        clock.time = 10
        policy.setResidence(context: tab, committedURL: extra, eligible: true)
        #expect(policy.isSuppressed(context: tab, url: extra))
        clock.time = 3_610
        #expect(!policy.isSuppressed(context: tab, url: extra))
        policy.setResidence(context: tab, committedURL: page, eligible: true)
        clock.time = 3_611
        policy.setResidence(context: tab, committedURL: extra, eligible: true)
        #expect(policy.isSuppressed(context: tab, url: extra))
    }
}
