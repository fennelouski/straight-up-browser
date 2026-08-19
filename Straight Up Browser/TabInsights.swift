//
//  TabInsights.swift
//  Straight Up Browser
//
//  What a website costs you, per tab: memory, CPU, how long it has actually
//  been on your screen, how slowly it loads, whether it's quietly playing
//  something, and how many other companies it invited along. The numbers a
//  browser normally keeps to itself.
//
//  Sampling only runs while the dashboard window is open — nobody pays for a
//  window they aren't looking at.
//

import Foundation
import WebKit
import Combine
import Darwin

#if canImport(AppKit)
import AppKit

struct TabInsight: Identifiable {
    var id: UUID
    var title: String
    var host: String
    var favicon: Data?
    var isDisplayed: Bool
    var isLoaded: Bool

    // Web content process. nil when the tab has no process, or when WebKit
    // stops handing out the process id (see TabProcessMetrics).
    var memoryBytes: UInt64?
    var cpuPercent: Double?
    var cpuPercentFiveMinutes: Double?
    var cpuTotalSeconds: Double?

    var screenSeconds: TimeInterval
    var averageLoadSeconds: Double?
    var loadCount: Int

    var playingAudio = false
    var playingVideo = false
    var adRequests = 0
    var thirdPartyHosts = 0
    var cookieCount = 0
    var storageKeys = 0
    var accountLabel: String?
}

// MARK: - Per-process sampling

// WebKit runs each tab's page in its own process but publishes no supported way
// to ask which one. -[WKWebView _webProcessIdentifier] is the only route, so it
// is called through a responds(to:) check and everything downstream treats a
// missing pid as "unknown" rather than zero — if a future WebKit drops the
// selector the dashboard loses two columns instead of breaking.
// ponytail: no XPC broker, no process-tree walk. Upgrade path if the SPI goes
// away: match WebContent pids by launch order and accept the ambiguity.
enum TabProcessMetrics {
    struct Sample {
        var residentBytes: UInt64
        var cpuSeconds: Double
    }

    static func processIdentifier(of webView: WKWebView) -> pid_t? {
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard webView.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> pid_t
        let implementation = unsafeBitCast(webView.method(for: selector), to: Getter.self)
        let pid = implementation(webView, selector)
        return pid > 0 ? pid : nil
    }

    // proc_pid_rusage is the obvious call and the App Sandbox denies it (EPERM)
    // for the web content processes; proc_pidinfo(PROC_PIDTASKINFO) returns the
    // same two numbers and is allowed. Its CPU counters are mach absolute time,
    // not nanoseconds — measured against a one-second busy loop in
    // TabProcessMetricsTests, which is what pins both facts down.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func sample(pid: pid_t) -> Sample? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        let ticks = Double(info.pti_total_user &+ info.pti_total_system)
        return Sample(
            residentBytes: info.pti_resident_size,
            cpuSeconds: ticks * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        )
    }
}

// MARK: - Model

@MainActor
final class TabInsights: ObservableObject {
    static let shared = TabInsights()

    @Published private(set) var rows: [TabInsight] = []
    @Published private(set) var appMemoryBytes: UInt64 = 0
    @Published private(set) var processMetricsAvailable = true

    // Set by ContentView; the dashboard is its own window scene and has no
    // other way to reach the live browser state.
    weak var webViewManager: WebViewManager?
    var tabsProvider: (() -> [Tab])?
    var displayedTabIdsProvider: (() -> [UUID])?

    private struct Accumulated {
        var screenSeconds: TimeInterval = 0
        var loadStartedAt: Date?
        var loadTotal: TimeInterval = 0
        var loadCount = 0
        var lastCPUSeconds: Double?
        var lastSampledAt: Date?
        var cpuPercent: Double?
        // 5-minute rolling window at one sample per SampleInterval.
        var cpuHistory: [Double] = []
        var page = PageStats()
    }

    private struct PageStats {
        var playingAudio = false
        var playingVideo = false
        var adRequests = 0
        var thirdPartyHosts = 0
        var cookieCount = 0
        var storageKeys = 0
        var accountLabel: String?
    }

    private static let sampleInterval: TimeInterval = 2
    private static var cpuWindowSamples: Int { Int(300 / sampleInterval) }

    private var accumulated: [UUID: Accumulated] = [:]
    private var samplingTask: Task<Void, Never>?
    private var observers = 0

    // MARK: Load timing (called from the navigation delegate)

    func loadStarted(_ tabId: UUID) {
        accumulated[tabId, default: Accumulated()].loadStartedAt = Date()
    }

    func loadFinished(_ tabId: UUID) {
        guard var entry = accumulated[tabId], let started = entry.loadStartedAt else { return }
        entry.loadStartedAt = nil
        // A restored back/forward entry can finish in microseconds and a hung
        // page can sit for minutes; neither says anything about the site.
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > 0.02, elapsed < 120 {
            entry.loadTotal += elapsed
            entry.loadCount += 1
        }
        accumulated[tabId] = entry
    }

    func forget(_ tabId: UUID) { accumulated.removeValue(forKey: tabId) }

    // MARK: Sampling lifetime

    func addObserver() {
        observers += 1
        guard samplingTask == nil else { return }
        samplingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .seconds(Self.sampleInterval))
            }
        }
    }

    func removeObserver() {
        observers = max(0, observers - 1)
        guard observers == 0 else { return }
        samplingTask?.cancel()
        samplingTask = nil
    }

    // MARK: The sample

    private func sample() {
        let tabs = tabsProvider?() ?? []
        let displayed = Set(displayedTabIdsProvider?() ?? [])
        let manager = webViewManager
        appMemoryBytes = Self.appResidentBytes()

        var anyProcessMetrics = false
        var next: [TabInsight] = []

        for tab in tabs {
            var entry = accumulated[tab.id] ?? Accumulated()
            if displayed.contains(tab.id) { entry.screenSeconds += Self.sampleInterval }

            let webView = manager?.existingWebView(for: tab.id)
            var memoryBytes: UInt64?
            var cpuTotal: Double?

            if let webView, let pid = TabProcessMetrics.processIdentifier(of: webView),
               let sample = TabProcessMetrics.sample(pid: pid) {
                anyProcessMetrics = true
                memoryBytes = sample.residentBytes
                cpuTotal = sample.cpuSeconds
                let now = Date()
                if let previous = entry.lastCPUSeconds, let previousAt = entry.lastSampledAt {
                    let wall = now.timeIntervalSince(previousAt)
                    if wall > 0 {
                        let percent = max(0, (sample.cpuSeconds - previous) / wall * 100)
                        entry.cpuPercent = percent
                        entry.cpuHistory.append(percent)
                        if entry.cpuHistory.count > Self.cpuWindowSamples {
                            entry.cpuHistory.removeFirst(entry.cpuHistory.count - Self.cpuWindowSamples)
                        }
                    }
                }
                entry.lastCPUSeconds = sample.cpuSeconds
                entry.lastSampledAt = now
            } else {
                entry.cpuPercent = nil
            }

            if let webView {
                readPageStats(from: webView, into: tab.id)
            } else {
                entry.page = PageStats()
            }

            accumulated[tab.id] = entry

            let average = entry.cpuHistory.isEmpty
                ? nil
                : entry.cpuHistory.reduce(0, +) / Double(entry.cpuHistory.count)

            next.append(TabInsight(
                id: tab.id,
                title: tab.title.isEmpty ? Tab.extractDomain(from: tab.url) : tab.title,
                host: tab.url?.host ?? "",
                favicon: tab.favicon,
                isDisplayed: displayed.contains(tab.id),
                isLoaded: webView != nil,
                memoryBytes: memoryBytes,
                cpuPercent: entry.cpuPercent,
                cpuPercentFiveMinutes: average,
                cpuTotalSeconds: cpuTotal,
                screenSeconds: entry.screenSeconds,
                averageLoadSeconds: entry.loadCount > 0 ? entry.loadTotal / Double(entry.loadCount) : nil,
                loadCount: entry.loadCount,
                playingAudio: entry.page.playingAudio,
                playingVideo: entry.page.playingVideo,
                adRequests: entry.page.adRequests,
                thirdPartyHosts: entry.page.thirdPartyHosts,
                cookieCount: entry.page.cookieCount,
                storageKeys: entry.page.storageKeys,
                accountLabel: entry.page.accountLabel
            ))
        }

        // Stay optimistic until a loaded tab has actually been measured, so the
        // "unavailable" note doesn't flash while the session is still empty.
        if next.contains(where: { $0.isLoaded }) {
            processMetricsAvailable = anyProcessMetrics
        }
        rows = next.sorted { ($0.memoryBytes ?? 0, $0.screenSeconds) > ($1.memoryBytes ?? 0, $1.screenSeconds) }
    }

    // The page's own view of itself. Runs in the page world because that's the
    // only world that can see the document's cookies and storage.
    // ponytail: one script per loaded tab per sample, no staggering — fine for
    // the tab counts a person actually keeps. If a 100-tab session makes the
    // window stutter, poll the page stats every fifth sample instead.
    private func readPageStats(from webView: WKWebView, into tabId: UUID) {
        Task { @MainActor [weak self] in
            let result = try? await webView.callAsyncJavaScript(
                Self.pageStatsScript,
                arguments: ["adHosts": WebViewManager.adHostList],
                in: nil,
                contentWorld: .page
            )
            guard let self, let dictionary = result as? [String: Any] else { return }
            var stats = PageStats()
            stats.playingAudio = dictionary["audio"] as? Bool ?? false
            stats.playingVideo = dictionary["video"] as? Bool ?? false
            stats.adRequests = dictionary["ads"] as? Int ?? 0
            stats.thirdPartyHosts = dictionary["thirdParty"] as? Int ?? 0
            stats.cookieCount = dictionary["cookies"] as? Int ?? 0
            stats.storageKeys = dictionary["storage"] as? Int ?? 0
            stats.accountLabel = (dictionary["account"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            self.accumulated[tabId, default: Accumulated()].page = stats
        }
    }

    private static let pageStatsScript = """
    const matches = (host) => adHosts.some((ad) => host === ad || host.endsWith('.' + ad));

    let audio = false, video = false;
    for (const element of document.querySelectorAll('video, audio')) {
      if (element.paused || element.ended || element.readyState < 2) continue;
      if (element.tagName === 'VIDEO') { video = true; }
      if (!element.muted && element.volume > 0) { audio = true; }
    }

    let ads = 0;
    const hosts = new Set();
    try {
      for (const entry of performance.getEntriesByType('resource')) {
        let host;
        try { host = new URL(entry.name, location.href).hostname; } catch (error) { continue; }
        if (!host || host === location.hostname) continue;
        hosts.add(host);
        if (matches(host)) ads++;
      }
    } catch (error) {}

    const cookies = document.cookie
      ? document.cookie.split(';').filter((part) => part.trim().length).length
      : 0;
    let storage = 0;
    try { storage = localStorage.length + sessionStorage.length; } catch (error) {}

    // Best-effort: whoever the page thinks you are, read off the avatar it
    // renders for you. No standard exists for this, so it misses as often as
    // it hits — a miss shows nothing rather than something wrong.
    let account = '';
    const avatar = document.querySelector(
      'img[alt*="avatar" i], img[alt*="profile" i], img[class*="avatar" i], [class*="avatar" i] img, [aria-label*="account" i] img'
    );
    if (avatar) {
      account = (avatar.getAttribute('alt') || avatar.getAttribute('title') || '').trim();
      if (!account) {
        const labelled = avatar.closest('[aria-label]');
        account = labelled ? labelled.getAttribute('aria-label').trim() : '';
      }
      if (!account) account = 'Signed in';
    }

    return {
      audio, video, ads, cookies, storage,
      thirdParty: hosts.size,
      account: account.slice(0, 60)
    };
    """

    // The browser's own footprint. The web content processes are separate, so
    // this is the UI process only — the per-tab rows are the rest of the bill.
    private static func appResidentBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
#endif
