#if os(macOS)
import AppKit
import Combine
import SwiftUI

@MainActor
enum DefaultBrowser {
    static let promptEnabledKey = "defaultBrowserPromptEnabled"
    enum RequestResult { case succeeded, notChanged, failed }
    private static let schemes = ["http", "https"]

    static var isDefault: Bool {
        schemes.allSatisfy { scheme in
            guard let probe = URL(string: "\(scheme)://example.com"),
                  let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
            return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
        }
    }

    static func setPromptEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: promptEnabledKey)
        if enabled { DefaultBrowserEngagement.shared.rearm() }
    }

    static func makeDefault() async -> RequestResult {
        DefaultBrowserEngagement.shared.recordDefaultAction()
        do {
            for scheme in schemes {
                try await NSWorkspace.shared.setDefaultApplication(
                    at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
            }
            return isDefault ? .succeeded : .notChanged
        } catch {
            if isDefault { return .succeeded }
            let error = error as NSError
            return error.domain == NSCocoaErrorDomain && error.code == CocoaError.userCancelled.rawValue
                ? .notChanged : .failed
        }
    }
}

/// One launch decision per process, shared by all window instances.
@MainActor
final class DefaultBrowserEngagement {
    static let shared = DefaultBrowserEngagement()
    private let defaults: UserDefaults
    static let storageKey = "defaultBrowserEngagement.v1"
    private(set) var policy: DefaultBrowserPromptPolicy
    private let firstOfferEligibleAtLaunch: Bool
    private var decidedThisLaunch = false
    private var usedThisLaunch = false
    private var previousSample: Date?
    private var wasBrowsing = false

    init(defaults: UserDefaults = .standard, launchDate: Date = .now) {
        self.defaults = defaults
        policy = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(DefaultBrowserPromptPolicy.self, from: $0) }
            ?? DefaultBrowserPromptPolicy()
        firstOfferEligibleAtLaunch = policy.recentUsage(at: launchDate) >= DefaultBrowserPromptPolicy.requiredUsage
    }

    var offersNever: Bool { policy.offersNever }

    func offerAtLaunch(isDefault: Bool) -> Bool {
        guard !decidedThisLaunch else { return false }
        decidedThisLaunch = true
        let enabled = defaults.object(forKey: DefaultBrowser.promptEnabledKey) as? Bool ?? true
        guard enabled, !policy.never, !isDefault else { return false }
        guard policy.hasOffered ? policy.usedLaunches >= policy.nextOfferLaunch : firstOfferEligibleAtLaunch else { return false }
        policy.hasOffered = true
        save()
        return true
    }

    func sample(isBrowsing: Bool, now: Date = .now) {
        var changed = false
        if isBrowsing && !usedThisLaunch {
            usedThisLaunch = true
            policy.usedLaunches += 1
            changed = true
        }
        // Account for the final foreground interval when focus leaves Browser.
        // A long gap means sleep/suspension; don't credit that elapsed time.
        if wasBrowsing, let previousSample {
            let duration = now.timeIntervalSince(previousSample)
            if duration > 0 && duration <= 45 {
                policy.recordUsage(from: previousSample, to: now)
                changed = true
            }
        }
        previousSample = now
        wasBrowsing = isBrowsing
        if changed { save() }
    }

    func dismiss() {
        policy.recordDismissal()
        save()
    }

    func never() {
        policy.never = true
        defaults.set(false, forKey: DefaultBrowser.promptEnabledKey)
        save()
    }

    func recordDefaultAction() {
        // A macOS confirmation decline is also an answer: give it breathing room.
        policy.dismissals = 0
        policy.nextOfferLaunch = policy.usedLaunches + 10
        save()
    }

    func rearm() {
        policy.never = false
        policy.dismissals = 0
        policy.nextOfferLaunch = 0
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(policy) { defaults.set(data, forKey: Self.storageKey) }
    }
}

/// Foreground browser-window time, sampled independently of the prompt's visibility.
struct DefaultBrowserEngagementObserver: View {
    @ObservedObject var tabManager: TabManager
    var hasWebPage: Bool
    @AppStorage(DefaultBrowser.promptEnabledKey) private var promptEnabled = true
    @State private var browserWindow = DefaultBrowserWindowReference()
    @State private var sleeping = false
    @State private var timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var isBrowsing: Bool {
        guard NSApp.isActive, !sleeping, let window = browserWindow.window,
              window.isVisible, window.isKeyWindow, !window.isMiniaturized,
              hasWebPage else { return false }
        return true
    }

    private func sample() {
        DefaultBrowserEngagement.shared.sample(isBrowsing: isBrowsing)
        let isDefault = DefaultBrowser.isDefault
        if isBrowsing, DefaultBrowserEngagement.shared.offerAtLaunch(isDefault: isDefault) {
            tabManager.offerDefaultBrowser = true
        }
        if isDefault || !promptEnabled { tabManager.offerDefaultBrowser = false }
    }

    var body: some View {
        DefaultBrowserWindowReader { window in
            browserWindow.window = window
            sample()
        }
            .allowsHitTesting(false)
            .onAppear { sample() }
            .onReceive(timer) { _ in sample() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in sample() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                DefaultBrowserEngagement.shared.sample(isBrowsing: false)
            }
            .onChange(of: tabManager.selectedTabId) { _, _ in sample() }
            .onChange(of: hasWebPage) { _, _ in sample() }
            .onChange(of: promptEnabled) { _, _ in sample() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
                sleeping = true
                DefaultBrowserEngagement.shared.sample(isBrowsing: false)
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in
                sleeping = true
                DefaultBrowserEngagement.shared.sample(isBrowsing: false)
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                sleeping = false
                sample()
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification)) { _ in
                sleeping = false
                sample()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in sample() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
                if let window = note.object as? NSWindow, window === browserWindow.window {
                    DefaultBrowserEngagement.shared.sample(isBrowsing: false)
                }
            }
            .onDisappear { DefaultBrowserEngagement.shared.sample(isBrowsing: false) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                DefaultBrowserEngagement.shared.sample(isBrowsing: isBrowsing)
            }
    }
}
private final class DefaultBrowserWindowReference {
    weak var window: NSWindow?
}

/// Resolve this view's window instead of treating Settings or panels as browsing.
private struct DefaultBrowserWindowReader: NSViewRepresentable {
    var onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ view: WindowView, context: Context) {
        view.onWindowChange = onWindowChange
    }

    final class WindowView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Don't publish SwiftUI model changes during hierarchy attachment.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                onWindowChange?(window)
            }
        }
    }
}
#endif
