//
//  RedirectLoopGuard.swift
//  Straight Up Browser
//
//  Shared redirect-loop policy state for the macOS and iPadOS WebKit delegates.
//

import Foundation

struct RedirectLoopGuard {
    private struct Entry {
        let key: String
        let timestamp: Date
    }

    private let maxOccurrences: Int
    private let timeWindow: TimeInterval
    private let maxEntries: Int
    private var entries: [Entry] = []

    init(maxOccurrences: Int = 3, timeWindow: TimeInterval = 10, maxEntries: Int = 64) {
        precondition(maxOccurrences > 0)
        precondition(timeWindow > 0)
        precondition(maxEntries >= maxOccurrences)
        self.maxOccurrences = maxOccurrences
        self.timeWindow = timeWindow
        self.maxEntries = maxEntries
    }

    /// Returns true once an equivalent URL has already been accepted the
    /// configured number of times inside the rolling window. Fragment-only
    /// changes count as the same server destination.
    mutating func shouldBlock(_ url: URL, at now: Date = Date()) -> Bool {
        entries.removeAll { now.timeIntervalSince($0.timestamp) > timeWindow }

        let key = Self.navigationKey(for: url)
        guard entries.lazy.filter({ $0.key == key }).count < maxOccurrences else {
            return true
        }

        entries.append(Entry(key: key, timestamp: now))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        return false
    }

    mutating func reset() {
        entries.removeAll(keepingCapacity: true)
    }

    private static func navigationKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        return components.string ?? url.absoluteString
    }
}

/// Whether a web view still needs the load its tab's URL is asking for.
/// Every clause here is a bug that shipped once, so it lives outside the view:
/// - `showing` it already: nothing to do.
/// - a navigation the *page* started (link click) beats the stale SwiftUI
///   binding, which only catches up when didFinish writes the tab's URL back.
/// - `inFlight` is our own load that hasn't committed yet. webView.url stays nil
///   through the provisional phase, so without this a burst of view updates
///   re-issues the same load until RedirectLoopGuard cancels it and the pane
///   sits blank — what ⌘Return into a new split pane used to do every time.
enum WebViewLoadDecision {
    static func shouldLoad(
        target: URL?,
        showing: URL?,
        requested: URL?,
        inFlight: URL?,
        isLoading: Bool
    ) -> Bool {
        guard let target else { return false }
        let wanted = Tab.normalizeURLForComparison(target)
        let shown = Tab.normalizeURLForComparison(showing)
        guard wanted != shown else { return false }
        if isLoading, shown == Tab.normalizeURLForComparison(requested) { return false }
        return wanted != Tab.normalizeURLForComparison(inFlight)
    }
}
