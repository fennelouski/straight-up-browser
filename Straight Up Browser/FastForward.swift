//
//  FastForward.swift
//  Straight Up Browser
//
//  Anticipatory split-pane navigation. When a search query implies a
//  *destination* ("download slack") rather than a *question* ("is slack down"),
//  the search results stay put and the resolved destination opens beside them,
//  scrolled to and pulsing on the thing you came for.
//
//  The split is the safety property: the left pane always holds the exact page
//  the user asked for, so a wrong guess costs a pane, never an outcome. Closing
//  the pane both undoes the guess and teaches Fast Forward not to repeat it.
//
//  Intent is recovered by parsing the search URL back apart rather than hooking
//  the omnibar, which picks up the CLI, App Intents, the global omnibar and
//  Google's own search box for free.
//

import Foundation
import SwiftUI
import Combine
import WebKit
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Intents

enum FastForwardIntent: String, Codable, CaseIterable {
    case download, login, pricing, docs, support
}

struct FastForwardMatch {
    let intent: FastForwardIntent
    let noun: String
    let rule: FastForwardRule

    // "download slack" and "slack download" collide onto one entry.
    var signature: String { "\(intent.rawValue):\(noun)" }
}

// A phrasing family: what selects the intent, what to discard when isolating the
// product name, and what to look for once the destination page loads.
struct FastForwardRule {
    let intent: FastForwardIntent
    let triggers: [String]     // regex; any match selects this intent
    let extraStrip: [String]   // discarded when isolating the noun
    let targets: [String]      // on-page text to scroll to, best first
    let preferred: [String]    // bonus keywords when scoring candidates

    // ponytail: verb table + regex, not a parser. Add grammar when a real query misses.
    static let all: [FastForwardRule] = [
        FastForwardRule(
            intent: .download,
            triggers: [#"\bdownloads?\b"#, #"\binstall(er)?\b"#, #"\bdmg\b"#,
                       #"\bget\b.*\b(for|on)\b.*\b(mac|macos|osx)\b"#],
            extraStrip: ["download", "downloads", "install", "installer", "dmg", "pkg",
                         "mac", "macos", "osx", "os", "x", "apple", "silicon",
                         "m1", "m2", "m3", "m4", "desktop", "client", "software"],
            targets: ["download", "get it", "install", "try for free"],
            preferred: ["mac", "macos", "apple silicon"]
        ),
        FastForwardRule(
            intent: .login,
            triggers: [#"\blog ?in\b"#, #"\bsign ?in\b"#, #"\bsignin\b"#, #"\blogin\b"#],
            extraStrip: ["log", "in", "login", "signin", "sign", "account", "portal"],
            targets: ["sign in", "log in", "login"],
            preferred: []
        ),
        FastForwardRule(
            intent: .pricing,
            triggers: [#"\bpricing\b"#, #"\bprices?\b"#, #"\bhow much (is|does|do)\b"#,
                       #"\bcosts?\b"#, #"\bplans?\b"#],
            extraStrip: ["pricing", "price", "prices", "cost", "costs", "much", "does",
                         "do", "plan", "plans", "per", "month", "year", "subscription"],
            targets: ["pricing", "plans", "per month", "per user"],
            preferred: ["month"]
        ),
        FastForwardRule(
            intent: .docs,
            triggers: [#"\bdocs\b"#, #"\bdocumentation\b"#, #"\bapi reference\b"#],
            extraStrip: ["docs", "documentation", "api", "reference", "guide", "guides"],
            targets: ["getting started", "documentation", "quickstart"],
            preferred: []
        ),
        FastForwardRule(
            intent: .support,
            triggers: [#"\bsupport\b"#, #"\bcontact\b"#, #"\bhelp ?(desk|center)\b"#,
                       #"\bcancel\b.*\b(subscription|plan|account|membership)\b"#],
            extraStrip: ["support", "contact", "help", "desk", "center", "centre",
                         "cancel", "subscription", "membership", "customer", "service"],
            targets: ["contact", "support", "help center", "cancel"],
            preferred: []
        ),
    ]

    // Query words that never identify a product.
    private static let stopwords: Set<String> = [
        "the", "a", "an", "for", "my", "on", "to", "from", "of", "in", "is", "are",
        "how", "do", "i", "can", "where", "what", "get", "app", "apps", "official",
        "site", "website", "web", "page", "latest", "free", "new", "version",
        "now", "please", "and", "or", "with", "best", "safe",
    ]

    static func rule(for intent: FastForwardIntent) -> FastForwardRule {
        all.first { $0.intent == intent } ?? all[0]
    }

    /// Classify a raw search query. Pure — this is what the unit tests drive.
    static func parse(_ raw: String) -> FastForwardMatch? {
        let query = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // A long query is prose, not a destination.
        guard !query.isEmpty, query.count <= 60 else { return nil }
        for rule in all where rule.matches(query) {
            if let noun = rule.noun(from: query) {
                return FastForwardMatch(intent: rule.intent, noun: noun, rule: rule)
            }
        }
        return nil
    }

    func matches(_ query: String) -> Bool {
        triggers.contains { query.range(of: $0, options: [.regularExpression]) != nil }
    }

    /// Whatever is left once the verb, the platform words and the stopwords are gone.
    func noun(from query: String) -> String? {
        let discard = FastForwardRule.stopwords.union(extraStrip)
        let tokens = query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "+" })
            .map(String.init)
            .filter { !discard.contains($0) }
        // More than three words left means it was a sentence, not a product name.
        guard !tokens.isEmpty, tokens.count <= 3 else { return nil }
        return tokens.joined(separator: " ")
    }
}

// MARK: - Recipes

// Known destinations for the queries people actually type, so the common case
// costs no search round-trip at all. User memory outranks this table: a
// correction always wins over the shipped guess.
//
// ponytail: 35 entries inline, not a bundled resource. Extract when it needs
// updating without a build.
enum FastForwardRecipes {
    static let table: [String: String] = [
        "download:slack": "https://slack.com/downloads/mac",
        "download:zoom": "https://zoom.us/download",
        "download:discord": "https://discord.com/download",
        "download:spotify": "https://www.spotify.com/download/mac/",
        "download:vscode": "https://code.visualstudio.com/download",
        "download:visual studio code": "https://code.visualstudio.com/download",
        "download:chrome": "https://www.google.com/chrome/",
        "download:firefox": "https://www.mozilla.org/firefox/new/",
        "download:brave": "https://brave.com/download/",
        "download:zed": "https://zed.dev/download",
        "download:docker": "https://www.docker.com/products/docker-desktop/",
        "download:notion": "https://www.notion.so/desktop",
        "download:figma": "https://www.figma.com/downloads/",
        "download:obsidian": "https://obsidian.md/download",
        "download:steam": "https://store.steampowered.com/about/",
        "download:blender": "https://www.blender.org/download/",
        "download:vlc": "https://www.videolan.org/vlc/",
        "download:obs": "https://obsproject.com/download",
        "download:postman": "https://www.postman.com/downloads/",
        "download:1password": "https://1password.com/downloads/mac/",
        "download:dropbox": "https://www.dropbox.com/install",
        "download:telegram": "https://desktop.telegram.org/",
        "download:signal": "https://signal.org/download/",
        "download:python": "https://www.python.org/downloads/",
        "download:node": "https://nodejs.org/en/download",
        "download:nodejs": "https://nodejs.org/en/download",
        "download:git": "https://git-scm.com/downloads",
        "download:homebrew": "https://brew.sh",
        "download:handbrake": "https://handbrake.fr/downloads.php",
        "download:audacity": "https://www.audacityteam.org/download/",
        "download:gimp": "https://www.gimp.org/downloads/",
        "download:raycast": "https://www.raycast.com/",
        "download:iterm": "https://iterm2.com/downloads.html",
        "download:iterm2": "https://iterm2.com/downloads.html",
        // A few non-download destinations where the first search result is reliably wrong.
        "docs:google": "https://docs.google.com",
        "docs:stripe": "https://docs.stripe.com",
        "docs:react": "https://react.dev",
        "login:gmail": "https://mail.google.com",
        "login:github": "https://github.com/login",
    ]
}

// MARK: - Memory

struct FastForwardLearned: Codable {
    var url: String
    var target: String?
    var accepts: Int
    var strikes: Int
    var lastUsed: Date
}

// What this user's own corrections taught us. Local JSON, following
// DownloadManager: this is per-machine telemetry, and a new @Model would mean a
// new CloudKit record type (see docs/adr/0001-split-is-view-state.md).
final class FastForwardMemory {
    private(set) var entries: [String: FastForwardLearned] = [:]

    // ponytail: same 500 cap as DownloadManager; the file stays trivially small.
    private let maxEntries = 500
    private let storeURL: URL

    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Straight Up Browser", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.storeURL = dir.appendingPathComponent("fast-forward.json")
        }
        load()
    }

    /// Two unanswered strikes and we stop guessing this query — but a signature the
    /// user usually keeps is forgiven the occasional dismissal.
    // ponytail: no time decay. Add lastUsed-based forgiveness if users complain it gave up.
    func isBlocked(_ signature: String) -> Bool {
        guard let entry = entries[signature] else { return false }
        return entry.strikes - entry.accepts >= 2
    }

    /// A destination the user has actually kept. Outranks the shipped recipe table.
    func destination(for signature: String) -> (url: URL, target: String?)? {
        guard let entry = entries[signature], entry.accepts > 0, !isBlocked(signature),
              let url = URL(string: entry.url) else { return nil }
        return (url, entry.target)
    }

    func record(signature: String, url: String, target: String?, accepted: Bool) {
        var entry = entries[signature] ?? FastForwardLearned(
            url: url, target: target, accepts: 0, strikes: 0, lastUsed: Date())
        if accepted {
            entry.accepts += 1
            entry.url = url        // whatever they kept is now the answer
            entry.target = target
        } else {
            entry.strikes += 1
        }
        entry.lastUsed = Date()
        entries[signature] = entry
        if entries.count > maxEntries {
            let doomed = entries.sorted { $0.value.lastUsed < $1.value.lastUsed }
                .prefix(entries.count - maxEntries)
            for (key, _) in doomed { entries.removeValue(forKey: key) }
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([String: FastForwardLearned].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

// MARK: - Pulse ring

// The ring/glow/zoom pulse, shared with find-in-page so both ride the same
// Find Emphasis slider the user already set. `rectJS` is any JS expression
// yielding a DOMRect (or null to skip).
enum PulseRing {
    static func script(intensity: Double, rectJS: String) -> String? {
        let t = max(0, min(1, intensity / 100))
        guard t > 0 else { return nil } // 0 = no flash
        let pad = 4 + 8 * t
        let border = 1 + 4 * t
        let glow = 6 + 48 * t
        let scale = 1 + 1.5 * t * t // negligible when subtle, a real zoom at the top end
        let dim = max(0, t - 0.5) * 0.8 // spotlight it by darkening the rest of the page
        let hold = Int(300 + 1200 * t)
        return """
        (function() {
            var r = \(rectJS);
            if (!r) return;
            var d = document.createElement('div');
            d.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;' +
                'left:' + (r.left - \(pad)) + 'px;top:' + (r.top - \(pad)) + 'px;' +
                'width:' + (r.width + \(pad * 2)) + 'px;height:' + (r.height + \(pad * 2)) + 'px;' +
                'border:\(border)px solid #FFD60A;border-radius:6px;' +
                'box-shadow:0 0 \(glow)px #FFD60A, 0 0 0 9999px rgba(0,0,0,\(dim));' +
                'transform:scale(\(scale));opacity:1;' +
                'transition:transform 0.35s cubic-bezier(0.2,0.9,0.3,1),opacity 0.6s ease-out;';
            document.body.appendChild(d);
            requestAnimationFrame(function() { d.style.transform = 'scale(1)'; });
            setTimeout(function() { d.style.opacity = '0'; }, \(hold));
            setTimeout(function() { d.remove(); }, \(hold + 700));
        })();
        """
    }

    /// The find bar's rect: wherever the current selection is.
    static let selectionRectJS = """
    (function(){var s=window.getSelection();\
    return s && s.rangeCount ? s.getRangeAt(0).getBoundingClientRect() : null;})()
    """
}

// MARK: - FoundationModels

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct ModeledFastForwardIntent {
    @Guide(description: "Exactly one of: download, login, pricing, docs, support. Empty string if the query is a general question rather than an attempt to reach a specific company or product's page.")
    var intent: String

    @Guide(description: "The product or company name only, lowercased, no more than three words. Empty string if there isn't one.")
    var noun: String
}
#endif

// MARK: - FastForward

@MainActor
final class FastForward: ObservableObject {
    enum Key {
        static let enabled = "fastForwardEnabled"
        // Escape hatch: kill the model branch without killing the feature.
        static let useAppleIntelligence = "fastForwardUseAppleIntelligence"
    }

    private let memory: FastForwardMemory
    private weak var tabManager: TabManager?
    private weak var webViewManager: WebViewManager?
    private var tabsProvider: () -> [Tab] = { [] }

    // Search tabs whose SERP still owes us a first-result scrape.
    private var awaitingScrape: [UUID: FastForwardMatch] = [:]
    // Panes that still owe us a scroll-and-pulse once they finish loading.
    private var awaitingPulse: [UUID: FastForwardMatch] = [:]
    // Search URLs already acted on, so back-nav and SPA reloads don't re-fire.
    private var handled: Set<String> = []
    // Live panes, for the accept/strike verdict when one closes.
    private var panes: [UUID: PaneRecord] = [:]

    private struct PaneRecord {
        let signature: String
        let url: String
        let target: String?
        let openedAt: Date
        var wasFocused = false
        var navigated = false
    }

    init(memory: FastForwardMemory? = nil) {
        self.memory = memory ?? FastForwardMemory()
    }

    func configure(tabManager: TabManager, webViewManager: WebViewManager, tabs: @escaping () -> [Tab]) {
        self.tabManager = tabManager
        self.webViewManager = webViewManager
        self.tabsProvider = tabs
    }

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true
    }

    // MARK: Search URL → query

    /// Pull the query back out of a search-engine results URL. Nil for anything else.
    static func searchQuery(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else { return nil }
        let engines = ["google.", "duckduckgo.", "bing.", "search.yahoo."]
        guard engines.contains(where: { host.contains($0) }) else { return nil }
        let param = host.contains("yahoo") ? "p" : "q"
        guard let value = components.queryItems?.first(where: { $0.name == param })?.value,
              !value.isEmpty else { return nil }
        return value
    }

    // MARK: Hooks from WebView.Coordinator

    /// didCommit: the search URL is known. A memory or recipe hit opens the pane
    /// immediately, racing the search results' own load.
    func pageCommitted(webView: WKWebView, tab: Tab) {
        if panes[tab.id] != nil, let url = webView.url,
           url.absoluteString != panes[tab.id]?.url {
            panes[tab.id]?.navigated = true   // they used it: that's an accept
        }
        guard isEnabled, tab.sessionKind != .incognito else { return }
        guard let tabManager, tabManager.splitTabIds.isEmpty else { return }
        guard let url = webView.url, !handled.contains(url.absoluteString),
              let query = Self.searchQuery(from: url) else { return }

        if let match = FastForwardRule.parse(query) {
            resolve(match, searchURL: url, from: tab)
            return
        }

        // Table missed. On macOS 26 the on-device model gets a shot at phrasings
        // the regexes don't cover ("where do I get the slack app"). Pure upside:
        // everything above this line works on every supported OS.
        if #available(macOS 26.0, *),
           UserDefaults.standard.object(forKey: Key.useAppleIntelligence) as? Bool ?? true {
            Task { [weak self] in
                guard let match = await Self.modelParse(query) else { return }
                guard let self, let current = webView.url,
                      current.absoluteString == url.absoluteString else { return }
                self.resolve(match, searchURL: url, from: tab)
            }
        }
    }

    /// didFinish: pulse a loaded pane, or scrape the SERP the table couldn't shortcut.
    func pageFinished(webView: WKWebView, tab: Tab) {
        if let match = awaitingPulse.removeValue(forKey: tab.id) {
            pulse(match, in: webView)
            return
        }
        guard let match = awaitingScrape.removeValue(forKey: tab.id),
              let url = webView.url, !handled.contains(url.absoluteString) else { return }
        scrapeFirstResult(in: webView) { [weak self] destination in
            guard let self, let destination else { return }
            self.open(destination, target: nil, match: match, searchURL: url, from: tab)
        }
    }

    /// Focus is an accept signal — they looked at it on purpose.
    func noteFocus(_ tabId: UUID?) {
        guard let tabId, panes[tabId] != nil else { return }
        panes[tabId]?.wasFocused = true
    }

    /// Called from TabManager.closeTab. Closing a pane IS the "no thanks" —
    /// which is exactly why the feature needs no feedback chrome.
    func paneClosed(_ tabId: UUID) {
        awaitingPulse.removeValue(forKey: tabId)
        guard let record = panes.removeValue(forKey: tabId) else { return }
        let accepted = record.wasFocused
            || record.navigated
            || Date().timeIntervalSince(record.openedAt) > 20
        memory.record(signature: record.signature, url: record.url,
                      target: record.target, accepted: accepted)
    }

    // MARK: Resolution ladder

    private func resolve(_ match: FastForwardMatch, searchURL: URL, from tab: Tab) {
        guard !memory.isBlocked(match.signature) else { return }

        if let learned = memory.destination(for: match.signature) {
            open(learned.url, target: learned.target, match: match, searchURL: searchURL, from: tab)
        } else if let recipe = FastForwardRecipes.table[match.signature],
                  let url = URL(string: recipe) {
            open(url, target: nil, match: match, searchURL: searchURL, from: tab)
        } else {
            awaitingScrape[tab.id] = match   // fall through to the scrape at didFinish
        }
    }

    // ponytail: first plausible organic <a>, no ranking. Revisit if SERP churn breaks it.
    private func scrapeFirstResult(in webView: WKWebView, completion: @escaping (URL?) -> Void) {
        let js = """
        (function() {
            var bad = /(^|\\.)(google|googleadservices|googleusercontent|gstatic|youtube|\
        doubleclick|bing|duckduckgo|yahoo|schema)\\./i;
            var root = document.querySelector('#rso') || document.querySelector('#search') ||
                       document.querySelector('#links') || document.querySelector('#b_results') ||
                       document.body;
            var links = root.querySelectorAll('a[href^="http"]');
            for (var i = 0; i < links.length; i++) {
                var a = links[i], host;
                try { host = new URL(a.href).hostname; } catch (e) { continue; }
                if (bad.test(host)) continue;
                if (a.closest('[data-text-ad],[aria-label*="Ad"],[data-hveid][role="listitem"] [aria-label="Ads"]')) continue;
                if (!a.innerText || a.innerText.trim().length < 3) continue;
                return a.href;
            }
            return null;
        })();
        """
        webView.evaluateJavaScript(js) { value, _ in
            completion((value as? String).flatMap(URL.init(string:)))
        }
    }

    // MARK: Opening the pane

    private func open(_ destination: URL, target: String?, match: FastForwardMatch,
                      searchURL: URL, from searchTab: Tab) {
        guard let tabManager, let webViewManager,
              tabManager.splitTabIds.isEmpty,
              tabManager.splitTabIds.count < TabManager.maxSplitTabs else { return }
        handled.insert(searchURL.absoluteString)

        let pane = tabManager.createTab(
            inheriting: (searchTab.sessionKind, searchTab.sessionId),
            url: destination, select: false)
        webViewManager.getWebView(for: pane.id).load(URLRequest(url: destination))

        awaitingPulse[pane.id] = match
        panes[pane.id] = PaneRecord(signature: match.signature,
                                    url: destination.absoluteString,
                                    target: target, openedAt: Date())

        tabManager.toggleSplitMembership(pane, tabs: tabsProvider() + [pane])
        // toggleSplitMembership focuses whatever it just added. Fast Forward is a
        // suggestion, not a takeover — hand focus back to the search they typed.
        tabManager.selectedTabId = searchTab.id

        Logger.log("FastForward: \(match.signature) → \(destination.absoluteString)", type: "FastForward")
    }

    // MARK: Scroll + pulse

    private func pulse(_ match: FastForwardMatch, in webView: WKWebView) {
        guard let targets = jsArray(match.rule.targets),
              let preferred = jsArray(match.rule.preferred) else { return }
        let intensity = UserDefaults.standard.object(forKey: FindBar.intensityKey) as? Double
            ?? FindBar.defaultIntensity
        // Find the best candidate, centre it, and report where it landed. The rect
        // is read *after* scrolling, so the ring draws over the settled position.
        let findRect = """
        (function(targets, preferred) {
            var best = null, bestScore = 0;
            var nodes = document.querySelectorAll('a,button,[role=button],input[type=submit],h1,h2,h3');
            for (var i = 0; i < nodes.length; i++) {
                var el = nodes[i];
                var text = (el.innerText || el.value || '').trim().toLowerCase();
                if (!text || text.length > 80) continue;
                var box = el.getBoundingClientRect();
                if (box.width < 8 || box.height < 8) continue;
                var score = 0;
                for (var t = 0; t < targets.length; t++) {
                    if (text.indexOf(targets[t]) >= 0) score += (targets.length - t) * 10;
                }
                if (!score) continue;
                for (var p = 0; p < preferred.length; p++) {
                    if (text.indexOf(preferred[p]) >= 0) score += 25;
                }
                if (el.tagName === 'A' || el.tagName === 'BUTTON') score += 5;
                if (score > bestScore) { bestScore = score; best = el; }
            }
            if (!best) return null;
            best.scrollIntoView({block: 'center'});
            return best.getBoundingClientRect();
        })(\(targets), \(preferred))
        """
        guard let script = PulseRing.script(intensity: intensity, rectJS: findRect) else { return }
        webView.evaluateJavaScript(script)
    }

    private func jsArray(_ strings: [String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: strings) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: On-device model

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func modelParse(_ query: String) async -> FastForwardMatch? {
        guard SystemLanguageModel.default.availability == .available else { return nil }
        let session = LanguageModelSession(instructions: """
            You classify web search queries for a browser.
            If the query is someone trying to REACH a specific company or product's \
            page — to download it, log in, see pricing, read its docs, or contact \
            support — return that intent and the product name.
            If it is a general question, a news lookup, or anything ambiguous, \
            return empty strings for both fields.
            """)
        guard let output = try? await session.respond(
                to: query, generating: ModeledFastForwardIntent.self).content,
              let intent = FastForwardIntent(rawValue:
                output.intent.lowercased().trimmingCharacters(in: .whitespaces))
        else { return nil }
        let noun = output.noun.lowercased().trimmingCharacters(in: .whitespaces)
        guard !noun.isEmpty, noun.split(separator: " ").count <= 3 else { return nil }
        Logger.log("FastForward: model classified '\(query)' → \(intent.rawValue):\(noun)",
                   type: "FastForward")
        return FastForwardMatch(intent: intent, noun: noun, rule: FastForwardRule.rule(for: intent))
    }
    #else
    @available(macOS 26.0, *)
    private static func modelParse(_ query: String) async -> FastForwardMatch? { nil }
    #endif
}
