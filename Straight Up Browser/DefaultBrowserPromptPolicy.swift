import Foundation

/// Only aggregate foreground duration is stored; no URLs or browsing history.
struct DefaultBrowserPromptPolicy: Codable {
    static let requiredUsage: TimeInterval = 4 * 60 * 60
    private static let usageWindow: TimeInterval = 7 * 24 * 60 * 60
    struct Usage: Codable {
        var start: Date
        var end: Date
    }
    var usage: [Usage] = []
    var usedLaunches = 0
    var dismissals = 0
    var nextOfferLaunch = 0
    var hasOffered = false
    var never = false

    mutating func recordUsage(from start: Date, to end: Date) {
        guard end > start else { return }
        let cutoff = end.addingTimeInterval(-Self.usageWindow)
        usage.removeAll { $0.end <= cutoff }
        if let last = usage.last, start <= last.end, end >= last.start {
            usage[usage.count - 1].start = min(last.start, start)
            usage[usage.count - 1].end = max(last.end, end)
        } else {
            usage.append(Usage(start: start, end: end))
        }
    }

    func recentUsage(at now: Date) -> TimeInterval {
        let cutoff = now.addingTimeInterval(-Self.usageWindow)
        return usage.reduce(0) { $0 + max(0, min($1.end, now).timeIntervalSince(max($1.start, cutoff))) }
    }

    func shouldOffer(at now: Date, enabled: Bool, isDefault: Bool) -> Bool {
        guard enabled, !never, !isDefault else { return false }
        if !hasOffered { return recentUsage(at: now) >= Self.requiredUsage }
        return usedLaunches >= nextOfferLaunch
    }

    var offersNever: Bool { dismissals >= 2 && usedLaunches >= nextOfferLaunch }

    mutating func recordDismissal() {
        dismissals += 1
        // First two offers are on separate launches. After the second X, earn
        // ten additional used launches before the next launch can offer Never.
        nextOfferLaunch = dismissals >= 2 ? max(12, usedLaunches + 10) : usedLaunches + 1
    }
}
