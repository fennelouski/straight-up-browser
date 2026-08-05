//
//  Prefetcher.swift
//  Straight Up Browser
//
//  Starts loading a page before you press Return. Once what you've typed in the
//  omnibar narrows to exactly one place you already go — same host across every
//  remaining suggestion, three visits or more, not already open — a hidden web
//  view loads it into the shared cache. Press Return and the real tab paints
//  from a warm cache instead of a cold round trip.
//
//  The hidden view browses the default data store, which is what makes the cache
//  shared — so prefetch never runs from an incognito or container tab.
//

import Foundation
import WebKit

@MainActor
final class Prefetcher: NSObject {
    static let shared = Prefetcher()

    static let enabledKey = "prefetchEnabled"

    // Below this, what you've typed is too vague to be sure — same threshold the
    // omnibar uses before a plain Return will hijack you into an open tab.
    private static let minTypedLength = 3
    private static let minVisits = 3
    // How long after a memory-pressure warning to stay out of the way.
    private static let pressureQuietPeriod: TimeInterval = 60

    private let webView: WKWebView
    private var inFlight: URL?
    private var lastPressure: Date?
    /// Visits per host, tallied once when the omnibar opens so the per-keystroke
    /// decision is a dictionary lookup.
    /// ponytail: counted per host, not per exact URL — a suggestion for a site you
    /// live in is usually its bare root ("mail.google.com"), which rarely matches a
    /// recorded URL character for character. Go per-URL only if prefetching the
    /// wrong page on a familiar host turns out to matter.
    private var counts: [String: Int] = [:]
    private var observer: NSObjectProtocol?

    private override init() {
        // Plain configuration: no page script, so a prefetch can't run our
        // injected handlers or record itself as a visit.
        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = WebViewManager.userAgentAppName
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        observer = NotificationCenter.default.addMainActorObserver(
            forName: .memoryPressure,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.lastPressure = Date()
            self?.cancel()
        }
    }

    static var isEnabled: Bool {
        // Absent key means on: this ships enabled.
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Tally the visit-count signal off the main thread when the omnibar opens,
    /// so typing never pays for it.
    func prime() {
        guard Self.isEnabled else { return }
        let visits = BrowsingHistoryStore.shared.visits
        Task {
            let tally = await Task.detached(priority: .utility) {
                var counts: [String: Int] = [:]
                for visit in visits {
                    guard let host = SiteHistory.normalizedHost(visit.url) else { continue }
                    counts[host, default: 0] += 1
                }
                return counts
            }.value
            self.counts = tally
        }
    }

    /// Called on every keystroke. Starts, redirects, or drops the prefetch.
    func consider(_ suggestions: [Suggestion], typed: String, openURLs: Set<URL>, session: SessionKind) {
        guard Self.isEnabled, session == .normal, !isUnderMemoryPressure else {
            cancel()
            return
        }
        let target = Self.candidate(
            from: suggestions,
            typed: typed,
            openURLs: openURLs,
            visitCount: { [counts] url in
                SiteHistory.normalizedHost(url).map { counts[$0] ?? 0 } ?? 0
            }
        )
        guard let target else {
            cancel()
            return
        }
        guard target != inFlight else { return }
        webView.stopLoading()
        inFlight = target
        webView.load(URLRequest(url: target))
    }

    /// The omnibar closed without going anywhere — drop the guess.
    func cancel() {
        guard inFlight != nil else { return }
        webView.stopLoading()
        inFlight = nil
    }

    /// The user committed to `urlString`. If that's what we were prefetching, let
    /// it finish — stopping mid-flight would throw away a partial response and the
    /// real tab would start over cold. Anywhere else, the guess was wrong: drop it.
    func committed(to urlString: String) {
        guard let inFlight else { return }
        if URL(string: urlString) != inFlight { cancel() }
        else { self.inFlight = nil }
    }

    private var isUnderMemoryPressure: Bool {
        guard let lastPressure else { return false }
        return Date().timeIntervalSince(lastPressure) < Self.pressureQuietPeriod
    }

    /// The gate. Pure so it can be tested without WebKit: returns a URL only when
    /// there is exactly one place the typed text could mean and it's somewhere the
    /// user already goes.
    static func candidate(
        from suggestions: [Suggestion],
        typed: String,
        openURLs: Set<URL>,
        visitCount: (URL) -> Int
    ) -> URL? {
        guard typed.trimmingCharacters(in: .whitespaces).count >= minTypedLength,
              let top = suggestions.first,
              top.type != .openTab else { return nil }

        // One candidate means one destination: if anything else in the list points
        // at a different site, we aren't sure enough to spend a page load.
        let hosts = Set(suggestions.compactMap { SiteHistory.normalizedHost($0.url) })
        guard hosts.count == 1 else { return nil }

        let url = top.url
        guard url.scheme == "http" || url.scheme == "https",
              visitCount(url) >= minVisits,
              !Set(openURLs.map(rootFolded)).contains(rootFolded(url)) else { return nil }
        return url
    }

    // A suggestion says "mail.google.com"; the open tab says "mail.google.com/".
    // Same page, so fold the root slash before comparing — Tab's normalizer keeps
    // it deliberately, and other callers rely on that.
    private static func rootFolded(_ url: URL) -> String {
        let text = Tab.normalizeURLForComparison(url)?.absoluteString ?? url.absoluteString
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }
}
