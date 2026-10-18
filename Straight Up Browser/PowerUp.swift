// Power Up stores only bounded, local action aggregates. It never receives page or input text.
#if os(macOS)
import Foundation
import Observation

enum PowerUpFeatureID: String, Codable, CaseIterable, Identifiable {
    case globalOmnibar, quickOpen, splitLayout, swapPanes, savedWorkspace, centerWindow
    var id: String { rawValue }
}

enum PowerUpInputMethod: String, Codable { case shortcut, menu, button, practice }
enum PowerUpKnowledge: String, Codable { case unseen, available, practicing, familiar, mastered, snoozed, suppressed }

struct PowerUpRecord: Codable, Equatable {
    var knowledge: PowerUpKnowledge = .unseen
    var shortcutUses = 0
    var directUses = 0
    // Rotating launch counters, capped at the mastery threshold, never exported or synced.
    var shortcutSessions: [Int] = []
    var directSessions: [Int] = []
    var practiced = false
    var lastActivityDay: Int?
    var aggregateStartDay: Int?
    var snoozedUntilDay: Int?
    var unsolicitedShown = false
}

struct PowerUpLearningState: Codable, Equatable {
    var schemaVersion = 1
    var session = 0
    var adaptiveEnabled = false
    var tipsPaused = false
    var records: [String: PowerUpRecord] = [:]
    var tipDays: [Int] = []
}

/// A candidate is usable only at a current, explicitly safe command context. No queued tips.
struct PowerUpTipContext {
    var age: TimeInterval = 0
    var typing = false
    var composing = false
    var fullScreen = false
    var modal = false
    var isPrivate = false
    var activeMedia = false
    var dragging = false
    var recordingShortcut = false
    var accessibilityAnnouncement = false
    var secondsSinceTransient: TimeInterval = 10
    var hasValidBinding = true
    var isSafe: Bool {
        age >= 0 && age <= 30 && !typing && !composing && !fullScreen && !modal && !isPrivate
            && !activeMedia && !dragging && !recordingShortcut && !accessibilityAnnouncement
            && secondsSinceTransient >= 10 && hasValidBinding
    }
}

@MainActor @Observable
final class PowerUpLearning {
    static let shared = PowerUpLearning()
    static let storageKey = "browserPowerUp.local.v1"
    private(set) var state: PowerUpLearningState
    private let defaults: UserDefaults
    private var writable = true

    init(defaults: UserDefaults = .standard, now: Date = .now) {
        self.defaults = defaults
        let decoded = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(PowerUpLearningState.self, from: $0) }
        if let decoded, decoded.schemaVersion != 1 {
            // Preserve a future version verbatim. Never overwrite an unrecognized schema.
            state = .init()
            writable = false
            return
        }
        state = decoded ?? .init()
        state.session = state.session == Int.max ? 1 : state.session + 1
        prune(day: Self.day(now))
        // Reading the static library alone does not create a learning record on disk.
        if decoded != nil { save() }
    }

    static func day(_ date: Date) -> Int { Int(floor(date.timeIntervalSince1970 / 86_400)) }
    var adaptiveEnabled: Bool { state.adaptiveEnabled }
    var tipsPaused: Bool { state.tipsPaused }
    var supportsCurrentSchema: Bool { writable }

    func setAdaptiveEnabled(_ enabled: Bool) { guard writable else { return }; state.adaptiveEnabled = enabled; save() }
    func setTipsPaused(_ paused: Bool) { guard writable else { return }; state.tipsPaused = paused; save() }

    func record(for feature: PowerUpFeatureID, now: Date = .now) -> PowerUpRecord {
        var value = state.records[feature.rawValue] ?? .init()
        if value.knowledge == .snoozed, let until = value.snoozedUntilDay, until <= Self.day(now) {
            value.knowledge = value.practiced ? .familiar : .available
        }
        return value
    }

    /// Called only after the app-owned command outcome succeeds, never on raw key events.
    func recordSuccess(feature: PowerUpFeatureID, method: PowerUpInputMethod, isPrivate: Bool, now: Date = .now) {
        guard writable, state.adaptiveEnabled, !isPrivate else { return }
        let day = Self.day(now)
        prune(day: day)
        var value = record(for: feature, now: now)
        guard value.knowledge != .suppressed else { return }
        value.lastActivityDay = day
        if value.aggregateStartDay == nil { value.aggregateStartDay = day }
        if method == .practice {
            value.practiced = true
            if value.knowledge != .mastered { value.knowledge = .familiar }
        } else if method == .shortcut {
            value.shortcutUses = min(99, value.shortcutUses + 1)
            if !value.shortcutSessions.contains(state.session), value.shortcutSessions.count < 3 {
                value.shortcutSessions.append(state.session)
            }
            if value.shortcutSessions.count >= 3 || value.practiced { value.knowledge = .mastered }
            else if value.knowledge == .unseen { value.knowledge = .available }
        } else {
            value.directUses = min(99, value.directUses + 1)
            if !value.directSessions.contains(state.session), value.directSessions.count < 2 {
                value.directSessions.append(state.session)
            }
            if value.practiced { value.knowledge = .mastered }
            else if value.knowledge == .unseen { value.knowledge = .available }
        }
        state.records[feature.rawValue] = value
        save()
    }

    // Explicit knowledge/dismissal preferences remain available with adaptive learning disabled.
    @discardableResult func markKnown(_ feature: PowerUpFeatureID) -> PowerUpRecord {
        let previous = record(for: feature)
        update(feature) { $0.knowledge = .mastered; $0.snoozedUntilDay = nil }
        return previous
    }
    func restore(_ record: PowerUpRecord, for feature: PowerUpFeatureID) {
        guard writable else { return }; state.records[feature.rawValue] = record; save()
    }
    func suppress(_ feature: PowerUpFeatureID) { update(feature) { $0.knowledge = .suppressed; $0.snoozedUntilDay = nil } }
    func snooze(_ feature: PowerUpFeatureID, now: Date = .now) {
        update(feature) { $0.knowledge = .snoozed; $0.snoozedUntilDay = Self.day(now) + 30; $0.unsolicitedShown = true }
    }
    func reset(_ feature: PowerUpFeatureID) {
        guard writable else { return }; state.records.removeValue(forKey: feature.rawValue); save()
    }
    func deleteHistory() {
        guard writable else { return }
        state.records = [:]; state.tipDays = []; save()
    }
    func isRecommended(_ feature: PowerUpFeatureID, now: Date = .now) -> Bool {
        ![.mastered, .suppressed, .snoozed].contains(record(for: feature, now: now).knowledge)
    }

    func canShowTip(for feature: PowerUpFeatureID, context: PowerUpTipContext, now: Date = .now) -> Bool {
        let day = Self.day(now)
        let value = record(for: feature, now: now)
        return writable && state.adaptiveEnabled && !state.tipsPaused && context.isSafe
            && isRecommended(feature, now: now) && !value.unsolicitedShown
            && value.directUses >= 3 && value.directSessions.count >= 2
            && !state.tipDays.contains(day) && state.tipDays.filter { $0 > day - 7 }.count < 2
    }
    @discardableResult func consumeTip(for feature: PowerUpFeatureID, context: PowerUpTipContext, now: Date = .now) -> Bool {
        guard canShowTip(for: feature, context: context, now: now) else { return false }
        state.tipDays = state.tipDays.filter { $0 > Self.day(now) - 7 }
        state.tipDays.append(Self.day(now))
        update(feature) { $0.unsolicitedShown = true }
        return true
    }

    private func update(_ feature: PowerUpFeatureID, mutation: (inout PowerUpRecord) -> Void) {
        guard writable else { return }
        var value = record(for: feature); mutation(&value); state.records[feature.rawValue] = value; save()
    }
    private func prune(day: Int) {
        let allowed = Set(PowerUpFeatureID.allCases.map(\.rawValue))
        state.records = state.records.filter { allowed.contains($0.key) }
        for key in Array(state.records.keys) {
            guard var value = state.records[key], let start = value.aggregateStartDay ?? value.lastActivityDay, start <= day - 90 else { continue }
            value.shortcutUses = 0; value.directUses = 0
            value.shortcutSessions = []; value.directSessions = []; value.lastActivityDay = nil; value.aggregateStartDay = nil
            if ![.mastered, .suppressed, .snoozed].contains(value.knowledge) { value.knowledge = .unseen; value.practiced = false }
            state.records[key] = value
        }
        // Retain future day buckets after a wall-clock rollback so it cannot reset the budget.
        state.tipDays = Array(state.tipDays.filter { $0 > day - 7 }.suffix(2))
    }
    private func save() {
        guard writable, let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
/// Isolated sample identities and recipes: deliberately never receives BrowserTab or URLs.
struct PowerUpSamplePractice {
    var contents = ["Field notes", "Overview", "Notes", "Code review", "Next steps"]
    var source: Int?
    var target: Int?
    var fivePane = false
    var leadingRatio = 0.46
    private var saved: [String]?
    private(set) var completed = false
    private var centerStep = 0
    var hasSaved: Bool { saved != nil }
    var hasChangedSaved: Bool { saved.map { $0 != contents } ?? false }
    var centerRatio: Double { [0.5, 1.0 / 3.0, 0.25][centerStep % 3] }
    var centerLabel: String { ["50%", "33⅓%", "25%"][centerStep % 3] }
    var swapPreview: (String, String)? {
        guard let source, let target else { return nil }; return (contents[source], contents[target])
    }
    mutating func select(_ index: Int) {
        guard contents.indices.contains(index) else { return }
        if source == index { cancelSwap() }
        else if source == nil { source = index }
        else { target = index }
    }
    mutating func applySwap() {
        guard let source, let target, source != target else { return }
        contents.swapAt(source, target); cancelSwap(); completed = true
    }
    mutating func cancelSwap() { source = nil; target = nil }
    mutating func selectFivePane() { fivePane = true }
    mutating func resize() { if fivePane { completed = true } }
    mutating func saveSample() { saved = contents }
    mutating func changeSample() { contents.reverse() }
    mutating func restoreSample() { guard let saved, saved != contents else { return }; contents = saved; completed = true }
    mutating func cycleWidth() { centerStep += 1; if centerStep >= 3 { completed = true } }
}

#endif
