#if os(macOS)
import AppKit
import Combine
import SwiftUI

enum OnboardingTrack: String, Codable, CaseIterable, Identifiable {
    case quickStart, customization, deepDive
    var id: Self { self }
    var title: String {
        switch self {
        case .quickStart: "Quick Start"
        case .customization: "Quick Customization"
        case .deepDive: "Deep Dive"
        }
    }
    var detail: String {
        switch self {
        case .quickStart: "One page. The keys and essentials to start browsing."
        case .customization: "A few choices to make Browser feel like yours."
        case .deepDive: "Build a workspace, research, and discover the advanced tools."
        }
    }
}

enum OnboardingStep: String, Codable, Identifiable {
    case essentials, interests, navigation, appearance, windows, memory
    case workspaces, sources, documents, splits, screenshots, downloads
    case translation, newspaper, ai, automation, finished
    var id: Self { self }
    var title: String {
        switch self {
        case .essentials: "Your launch pad"
        case .interests: "What do you make?"
        case .navigation: "Find your way around"
        case .appearance: "Make yourself comfortable"
        case .windows: "Give your windows room"
        case .memory: "A little breathing room"
        case .workspaces: "A home for each project"
        case .sources: "Keep the sources that matter"
        case .documents: "Turn research into something useful"
        case .splits: "See the bigger picture"
        case .screenshots: "Show what you mean"
        case .downloads: "A home for your downloads"
        case .translation: "Read across languages"
        case .newspaper: "Your reading, without the clutter"
        case .ai: "An assistant, if you want one"
        case .automation: "Let your tools lend a hand"
        case .finished: "Ready for your own orbit"
        }
    }
    var target: OnboardingTarget? {
        switch self {
        case .workspaces: .workspaces
        case .documents: .documents
        case .newspaper: .newspaper
        case .navigation: .omnibar
        case .splits, .sources, .screenshots, .translation: .page
        case .appearance: .tabs
        default: nil
        }
    }
}

struct OnboardingContext: Equatable {
    var largeScreen: Bool
    var nightInDarkMode: Bool
    static func make(screenSize: CGSize, hour: Int, dark: Bool) -> Self {
        Self(largeScreen: screenSize.width >= 1600, nightInDarkMode: dark && (hour >= 18 || hour < 7))
    }
}

enum OnboardingRole: String, CaseIterable, Codable, Identifiable {
    case development = "Development", design = "Design", product = "Product management"
    var id: Self { self }
}

struct OnboardingProgress: Codable, Equatable {
    enum Decision: String, Codable { case new, later, declined, learning, completed }
    var decision: Decision = .new
    var remindAfter: Date?
    var track: OnboardingTrack?
    var step: OnboardingStep?
    var roles: Set<OnboardingRole> = []

    func shouldOffer(at date: Date) -> Bool {
        switch decision {
        case .new, .learning: true
        case .later: remindAfter.map { date >= $0 } ?? true
        case .declined, .completed: false
        }
    }

    func steps(context: OnboardingContext) -> [OnboardingStep] {
        switch track {
        case .quickStart: return [.essentials]
        case .customization:
            return [.interests, .appearance, .navigation, .splits]
                + (context.largeScreen ? [.windows] : [])
                + [.memory, .automation]
                + (roles.isEmpty ? [] : [.screenshots]) + [.finished]
        case .deepDive:
            return [.interests, .navigation, .workspaces, .sources, .documents, .splits]
                + (context.largeScreen ? [.windows] : [])
                + [.appearance, .memory, .downloads, .translation, .newspaper, .ai, .automation]
                + (roles.isEmpty ? [] : [.screenshots]) + [.finished]
        case nil: return []
        }
    }
}

/// One invitation and one guide owner across all browser windows.
final class BrowserOnboarding: ObservableObject {
    static let shared = BrowserOnboarding()
    static let storageKey = "browserOnboarding.v1"
    @Published private(set) var progress: OnboardingProgress
    @Published private(set) var windowID: UUID?
    @Published private(set) var invitation = false
    @Published var minimized = false
    @Published var animations = true
    @Published var spring = true
    @Published private(set) var context = OnboardingContext(largeScreen: false, nightInDarkMode: false)
    private let defaults: UserDefaults
    private var offeredThisLaunch = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let testing = ProcessInfo.processInfo.arguments.contains("-uiTesting")
        progress = (testing ? nil : defaults.data(forKey: Self.storageKey))
            .flatMap { try? JSONDecoder().decode(OnboardingProgress.self, from: $0) } ?? .init()
        animations = testing ? false : (defaults.object(forKey: "onboardingAnimations") as? Bool ?? true)
        spring = defaults.object(forKey: "onboardingSpring") as? Bool ?? true
    }

    var step: OnboardingStep? { progress.step }
    var steps: [OnboardingStep] { progress.steps(context: context) }
    var position: Int { step.flatMap { steps.firstIndex(of: $0) } ?? 0 }
    var active: Bool { windowID != nil }

    func offer(in id: UUID, context: OnboardingContext, now: Date = .now) {
        guard !offeredThisLaunch, !active else { return }
        offeredThisLaunch = true
        self.context = context
        guard progress.shouldOffer(at: now) else { return }
        windowID = id
        invitation = true
    }

    func show(in id: UUID, context: OnboardingContext? = nil) {
        if let context { self.context = context }
        windowID = id
        invitation = false
        minimized = false
        // Keep a paused guide's place; completed and declined users get the chooser.
        if progress.decision != .learning {
            progress.track = nil
            progress.step = nil
        }
    }

    func accept() {
        invitation = false
        progress.decision = .learning
        save()
    }

    func decline() {
        progress.decision = .declined
        save()
        dismiss()
    }

    func later(now: Date = .now) {
        progress.decision = .later
        progress.remindAfter = now.addingTimeInterval(3 * 24 * 60 * 60)
        save()
        dismiss()
    }

    func choose(_ track: OnboardingTrack) {
        progress.track = track
        progress.decision = .learning
        progress.step = progress.steps(context: context).first
        save()
    }

    func toggleRole(_ role: OnboardingRole) {
        if progress.roles.contains(role) { progress.roles.remove(role) }
        else { progress.roles.insert(role) }
        save()
    }

    func move(_ delta: Int) {
        let index = min(max(position + delta, 0), max(0, steps.count - 1))
        progress.step = steps.indices.contains(index) ? steps[index] : nil
        save()
    }

    func changeTrack() { progress.track = nil; progress.step = nil; save() }
    func pause() { progress.decision = .learning; save(); dismiss() }
    func finish() { progress.decision = .completed; save(); dismiss() }
    func windowClosed(_ id: UUID) { if windowID == id { pause() } }
    func dismiss() { windowID = nil; invitation = false; minimized = false }
    func saveMotion() {
        defaults.set(animations, forKey: "onboardingAnimations")
        defaults.set(spring, forKey: "onboardingSpring")
    }
    private func save() {
        if let data = try? JSONEncoder().encode(progress) { defaults.set(data, forKey: Self.storageKey) }
    }
}

enum OnboardingTarget: Hashable { case tabs, workspaces, newspaper, documents, omnibar, page }
struct OnboardingAnchors: PreferenceKey {
    static let defaultValue: [OnboardingTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [OnboardingTarget: Anchor<CGRect>], nextValue: () -> [OnboardingTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
extension View {
    func onboardingTarget(_ target: OnboardingTarget) -> some View {
        anchorPreference(key: OnboardingAnchors.self, value: .bounds) { [target: $0] }
    }
}
#endif
