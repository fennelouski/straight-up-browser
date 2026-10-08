import Foundation
import Testing
@testable import Browser

@MainActor
struct OnboardingTests {
    private func withGuide(_ body: (BrowserOnboarding, UserDefaults) throws -> Void) throws {
        let name = "OnboardingTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(BrowserOnboarding(defaults: defaults), defaults)
    }
    private let context = OnboardingContext(largeScreen: false, nightInDarkMode: false)

    @Test func invitationHasOneWindowOwnerPerLaunch() throws {
        try withGuide { guide, _ in
            let first = UUID()
            guide.offer(in: first, context: context)
            guide.offer(in: UUID(), context: context)
            #expect(guide.windowID == first)
            #expect(guide.invitation)
            guide.later()
            guide.offer(in: UUID(), context: context, now: .distantFuture)
            #expect(!guide.active)
        }
    }
    @Test func decliningPersistsButHelpStillOpensTheGuide() throws {
        try withGuide { guide, defaults in
            guide.decline()
            let restored = BrowserOnboarding(defaults: defaults)
            restored.offer(in: UUID(), context: context)
            #expect(!restored.active)
            restored.show(in: UUID())
            #expect(restored.active)
            #expect(restored.progress.track == nil)
        }
    }
    @Test func laterWaitsThreeDaysAndDoesNotDiscardPreferences() throws {
        try withGuide { guide, defaults in
            let now = Date(timeIntervalSince1970: 1_000)
            defaults.set(true, forKey: "memorySaverEnabled")
            defaults.set(false, forKey: CLIAuthorization.Key.enabled)
            guide.later(now: now)
            #expect(!guide.progress.shouldOffer(at: now.addingTimeInterval(24 * 60 * 60)))
            #expect(guide.progress.shouldOffer(at: now.addingTimeInterval(3 * 24 * 60 * 60)))
            #expect(defaults.bool(forKey: "memorySaverEnabled"))
            #expect(!defaults.bool(forKey: CLIAuthorization.Key.enabled))
        }
    }
    @Test func pausedGuideRestoresTrackStepAndInterests() throws {
        try withGuide { guide, defaults in
            guide.show(in: UUID(), context: context)
            guide.choose(.deepDive)
            guide.toggleRole(.design)
            guide.move(3)
            guide.pause()
            let restored = BrowserOnboarding(defaults: defaults)
            restored.show(in: UUID(), context: context)
            #expect(restored.progress.track == .deepDive)
            #expect(restored.step == .sources)
            #expect(restored.progress.roles == [.design])
        }
    }
    @Test func quickStartIsOnePageAndDeepDiveTeachesWorkspaceBeforeAdvancedTools() {
        var p = OnboardingProgress(track: .quickStart)
        #expect(p.steps(context: context) == [.essentials])
        p.track = .deepDive
        let steps = p.steps(context: context)
        #expect(steps.firstIndex(of: .workspaces)! < steps.firstIndex(of: .documents)!)
        #expect(steps.firstIndex(of: .documents)! < steps.firstIndex(of: .ai)!)
        #expect(steps.contains(.downloads) && steps.contains(.translation) && steps.contains(.newspaper))
    }
    @Test func contextAndInterestsSelectRelevantLessons() {
        let night = OnboardingContext.make(screenSize: .init(width: 1920, height: 1080), hour: 22, dark: true)
        #expect(night.largeScreen && night.nightInDarkMode)
        #expect(!OnboardingContext.make(screenSize: .init(width: 1280, height: 800), hour: 12, dark: true).nightInDarkMode)
        var p = OnboardingProgress(track: .customization)
        #expect(!p.steps(context: context).contains(.windows))
        #expect(!p.steps(context: context).contains(.screenshots))
        p.roles = [.development]
        #expect(p.steps(context: night).contains(.windows))
        #expect(p.steps(context: night).contains(.screenshots))
    }
    @Test func completingStopsAutomaticInvitationsAndWindowClosureSavesProgress() throws {
        try withGuide { guide, defaults in
            let id = UUID()
            guide.show(in: id, context: context)
            guide.choose(.customization)
            guide.move(2)
            guide.windowClosed(id)
            #expect(!guide.active)
            #expect(guide.progress.decision == .learning)
            guide.finish()
            #expect(!BrowserOnboarding(defaults: defaults).progress.shouldOffer(at: .distantFuture))
        }
    }
}
