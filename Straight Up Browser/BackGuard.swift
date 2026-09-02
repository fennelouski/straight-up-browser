import Combine
import Foundation
import WebKit

// Confirm before Back drops a live call or full-screen video (the wrong split
// pane focused + ⌘[ = you just left the meeting). Global triggers decide what
// counts; a per-site override (always ask / never ask) wins over them.
final class BackGuardStore: ObservableObject {
    enum Trigger: String, CaseIterable, Identifiable {
        case camera, microphone, fullscreen
        var id: String { rawValue }
        var title: LocalizedStringResource {
            switch self {
            case .camera: "Camera is on"
            case .microphone: "Microphone is on"
            case .fullscreen: "Playing full screen"
            }
        }
    }

    static let shared = BackGuardStore()
    static let defaultTriggers: Set<Trigger> = [.camera, .microphone]
    private static let triggersKey = "backGuardTriggers"
    private static let hostKey = "backGuardByHost"

    @Published private(set) var triggers: Set<Trigger>
    /// true = always ask on this site, false = never ask; absent = use triggers.
    @Published private(set) var byHost: [String: Bool]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.stringArray(forKey: Self.triggersKey) {
            triggers = Set(raw.compactMap(Trigger.init))
        } else {
            triggers = Self.defaultTriggers
        }
        byHost = (defaults.dictionary(forKey: Self.hostKey) as? [String: Bool]) ?? [:]
    }

    func shouldConfirm(host: String?, active: Set<Trigger>) -> Bool {
        if let perSite = override(for: host) { return perSite }
        return !triggers.isDisjoint(with: active)
    }

    func set(_ trigger: Trigger, enabled: Bool) {
        if enabled { triggers.insert(trigger) } else { triggers.remove(trigger) }
        defaults.set(triggers.map(\.rawValue).sorted(), forKey: Self.triggersKey)
    }

    func override(for host: String?) -> Bool? {
        ShortcutPriorityStore.normalize(host).flatMap { byHost[$0] }
    }

    /// Pass nil to clear the override and fall back to the triggers.
    func set(_ value: Bool?, host: String?) {
        guard let host = ShortcutPriorityStore.normalize(host) else { return }
        byHost[host] = value
        defaults.set(byHost, forKey: Self.hostKey)
    }

    var customizedHosts: [String] { byHost.keys.sorted() }

    func resetAll() {
        triggers = Self.defaultTriggers
        byHost = [:]
        defaults.removeObject(forKey: Self.triggersKey)
        defaults.removeObject(forKey: Self.hostKey)
    }
}

extension WKWebView {
    // WebKit's own view of the page: .muted still counts, Meet keeps the mic
    // track while you're muted. A call lobby also captures, so this can
    // over-warn there, which is the safe direction.
    var activeBackGuardTriggers: Set<BackGuardStore.Trigger> {
        var active = Set<BackGuardStore.Trigger>()
        if cameraCaptureState != .none { active.insert(.camera) }
        if microphoneCaptureState != .none { active.insert(.microphone) }
        if fullscreenState == .inFullscreen { active.insert(.fullscreen) }
        return active
    }
}
