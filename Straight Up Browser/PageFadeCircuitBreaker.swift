import Foundation

/// Session-only policy. The owner supplies a monotonic clock and serializes calls.
/// No URL, page content, or correlation identifier is written to disk or logs.
final class PageFadeCircuitBreaker {
    struct Decision: Equatable {
        let shouldAnimate: Bool
        let isSuppressed: Bool
        let isDuplicate: Bool
    }

    private struct Attempt {
        let id: UUID
        let time: TimeInterval
    }
    private struct Record {
        var attempts: [Attempt] = []
        var suppressed = false
        var lastBurst: TimeInterval?
        var residence: TimeInterval?
    }
    private struct Attribution {
        var url: String
        let time: TimeInterval
    }
    private struct Context {
        var records: [String: Record] = [:]
        var committedURL: String?
        var eligible = false
        var active: [UUID: Attribution] = [:]
        var seen: [UUID] = []
        // Never evict a latch into an enabled state. Additional URLs share one
        // conservative record; navigating away discards its recovery credit.
        var overflowURL: String?
        var overflow: Record?
    }

    private let now: () -> TimeInterval
    private let maximumKeys: Int
    private var contexts: [UUID: Context] = [:]
    static let burstInterval: TimeInterval = 2
    static let recoveryInterval: TimeInterval = 3_600

    init(maximumKeys: Int = 1_024,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.maximumKeys = max(1, maximumKeys)
        self.now = now
    }

    /// Foundation retains the engine's path/query/fragment serialization. Only
    /// scheme/host case, default port and empty HTTP path are normalized.
    static func identity(for url: URL?) -> String? {
        guard let url, var parts = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: true),
              let scheme = parts.scheme, !scheme.isEmpty else { return nil }
        parts.scheme = scheme.lowercased()
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "http" && parts.port == 80)
            || (parts.scheme == "https" && parts.port == 443) { parts.port = nil }
        if (parts.scheme == "http" || parts.scheme == "https") && parts.percentEncodedPath.isEmpty {
            parts.percentEncodedPath = "/"
        }
        return parts.string
    }

    func setResidence(context id: UUID, committedURL: URL?, eligible: Bool) {
        let time = now()
        let url = Self.identity(for: committedURL)
        var context = contexts[id] ?? Context()
        if context.committedURL != url || !eligible || !context.eligible {
            if let previous = context.committedURL {
                mutateRecord(previous, in: &context) { $0.residence = nil }
            }
            if context.overflowURL != url {
                context.overflowURL = nil
                context.overflow = nil
            }
            if eligible, let url {
                ensureRecord(url, in: &context, at: time)
                mutateRecord(url, in: &context) { $0.residence = time }
            }
        }
        context.committedURL = url
        context.eligible = eligible
        contexts[id] = context
    }

    /// Call only after semantic eligibility and visibility are established, even
    /// with Reduce Motion enabled or a currently suppressed URL.
    func attempt(context id: UUID, url: URL?, episode: UUID, reducedMotion: Bool) -> Decision {
        guard let key = Self.identity(for: url) else {
            return Decision(shouldAnimate: false, isSuppressed: false, isDuplicate: false)
        }
        let time = now()
        var context = contexts[id] ?? Context()
        if context.seen.contains(episode) {
            let suppressed = record(key, in: context)?.suppressed ?? false
            return Decision(shouldAnimate: false, isSuppressed: suppressed, isDuplicate: true)
        }
        context.seen.append(episode)
        if context.seen.count > 64 { context.seen.removeFirst(context.seen.count - 64) }
        context.active[episode] = Attribution(url: key, time: time)
        if context.active.count > 64,
           let oldest = context.active.min(by: { $0.value.time < $1.value.time })?.key {
            context.active.removeValue(forKey: oldest)
        }
        ensureRecord(key, in: &context, at: time)
        var state = record(key, in: context) ?? Record(suppressed: true, lastBurst: time)
        state.attempts.removeAll { time - $0.time > Self.burstInterval && context.active[$0.id] == nil }
        let burst = state.attempts.contains { 0...Self.burstInterval ~= time - $0.time }
        state.attempts.append(Attempt(id: episode, time: time))
        // An extreme event storm is already suppressed; keep bounded evidence.
        if state.attempts.count > 64 { state.attempts.removeFirst(state.attempts.count - 64) }
        if burst {
            state.suppressed = true
            state.lastBurst = time
        } else {
            recover(&state, at: time)
        }
        setRecord(state, key: key, in: &context)
        contexts[id] = context
        return Decision(shouldAnimate: !state.suppressed && !reducedMotion,
                        isSuppressed: state.suppressed, isDuplicate: false)
    }

    /// Move one attempt to a redirect's authoritative destination, retaining its
    /// original timestamp. A newly discovered pair starts its quiet hour now.
    @discardableResult
    func reconcile(context id: UUID, episode: UUID, committedURL: URL?) -> Bool {
        guard let key = Self.identity(for: committedURL), var context = contexts[id],
              var attribution = context.active[episode] else { return false }
        guard attribution.url != key else { return record(key, in: context)?.suppressed ?? false }
        let time = now()
        mutateRecord(attribution.url, in: &context) { state in
            state.attempts.removeAll { $0.id == episode }
        }
        ensureRecord(key, in: &context, at: time)
        var state = record(key, in: context) ?? Record(suppressed: true, lastBurst: time)
        let burst = state.attempts.contains { abs(attribution.time - $0.time) <= Self.burstInterval }
        state.attempts.append(Attempt(id: episode, time: attribution.time))
        if state.attempts.count > 64 { state.attempts.removeFirst(state.attempts.count - 64) }
        if burst { state.suppressed = true; state.lastBurst = time }
        setRecord(state, key: key, in: &context)
        attribution.url = key
        context.active[episode] = attribution
        contexts[id] = context
        return state.suppressed
    }

    func complete(context id: UUID, episode: UUID) {
        contexts[id]?.active.removeValue(forKey: episode)
    }

    func isSuppressed(context id: UUID, url: URL?) -> Bool {
        guard let key = Self.identity(for: url), var context = contexts[id],
              var state = record(key, in: context) else { return false }
        recover(&state, at: now())
        setRecord(state, key: key, in: &context)
        contexts[id] = context
        return state.suppressed
    }

    /// Sleep/lock is a real interruption, not elapsed quiet residence.
    func interrupt(clearRecentAttempts: Bool) {
        for id in Array(contexts.keys) {
            guard var context = contexts[id] else { continue }
            context.eligible = false
            // An unfinished pre-sleep attribution must not reintroduce old
            // attempt evidence later when a redirect finally commits.
            if clearRecentAttempts { context.active.removeAll() }
            for key in Array(context.records.keys) {
                context.records[key]?.residence = nil
                if clearRecentAttempts { context.records[key]?.attempts.removeAll() }
            }
            context.overflow?.residence = nil
            if clearRecentAttempts { context.overflow?.attempts.removeAll() }
            contexts[id] = context
        }
    }

    func close(context id: UUID) { contexts.removeValue(forKey: id) }
    func removeAll() { contexts.removeAll() }

    // Inspection exposes counts only, never browsing identifiers.
    func retainedKeyCount(context id: UUID) -> Int {
        guard let context = contexts[id] else { return 0 }
        return context.records.count + (context.overflow == nil ? 0 : 1)
    }

    private func recover(_ state: inout Record, at time: TimeInterval) {
        guard state.suppressed, let residence = state.residence, let burst = state.lastBurst,
              time >= max(residence, burst) + Self.recoveryInterval else { return }
        state.suppressed = false
    }

    private func ensureRecord(_ key: String, in context: inout Context, at time: TimeInterval) {
        if context.records[key] != nil || context.overflowURL == key { return }
        if context.records.count >= maximumKeys {
            // Expire only inactive, unsuppressed history. Suppression latches stay.
            context.records = context.records.filter { key, state in
                state.suppressed || key == context.committedURL
                    || state.attempts.contains { time - $0.time <= Self.burstInterval || context.active[$0.id] != nil }
            }
        }
        if context.records.count < maximumKeys {
            context.records[key] = Record()
        } else {
            context.overflowURL = key
            context.overflow = Record(suppressed: true, lastBurst: time,
                                      residence: context.eligible && context.committedURL == key ? time : nil)
        }
    }

    private func record(_ key: String, in context: Context) -> Record? {
        context.records[key] ?? (context.overflowURL == key ? context.overflow : nil)
    }
    private func setRecord(_ state: Record, key: String, in context: inout Context) {
        if context.records[key] != nil { context.records[key] = state }
        else if context.overflowURL == key { context.overflow = state }
    }
    private func mutateRecord(_ key: String, in context: inout Context, mutation: (inout Record) -> Void) {
        guard var state = record(key, in: context) else { return }
        mutation(&state)
        setRecord(state, key: key, in: &context)
    }
}
