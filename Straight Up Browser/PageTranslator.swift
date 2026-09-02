//
//  PageTranslator.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 7/21/26.
//

import Foundation
import SwiftUI
import Combine
import Translation
import NaturalLanguage
import WebKit

// On-device page translation. The page's visible text nodes come out of
// WebViewManager's __subTranslate JS; NLLanguageRecognizer detects the page's
// language from the longest of them and drops nodes already in the target
// language (a mail client's chrome around a foreign message). The rest is
// batch-translated via Apple's Translation framework and written back into the
// DOM. `configuration` drives a single `.translationTask` (attached once at the
// window root in ContentView) — a FIFO queue serializes translate requests
// since TranslationSession only runs one task at a time.
@MainActor
final class PageTranslator: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?

    // Per web view, 0…1 from the moment a translation is queued until it's
    // applied. ContentView tints the window-edge loading bar with it, so a
    // multi-minute model download or a long page visibly counts as work.
    @Published private(set) var progress: [ObjectIdentifier: Double] = [:]

    typealias TextNode = (id: String, text: String)

    private struct PendingRequest {
        // nil webView = prefetch: download the pair's model, translate nothing.
        let webView: WKWebView?
        let nodes: [TextNode]
        // nil source = translationd identifies each string itself (a short
        // selection the recognizer can't place).
        let source: Locale.Language?
        let sourceCode: String?
        let target: Locale.Language
        let targetCode: String
    }

    private var queue: [PendingRequest] = []

    // Set by translateIntoSplitPane before the pane loads: the next didFinish
    // for that web view should translate unconditionally, ignoring both the
    // auto-translate toggle and the "already in a preferred language" check.
    private var forcedTargets: [ObjectIdentifier: String] = [:]

    // MARK: - Preferences

    private func preferredLanguageCodes() -> [String] {
        let stored = UserDefaults.standard.string(forKey: "translationPreferredLanguages") ?? ""
        let codes = stored.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !codes.isEmpty { return codes }
        return Locale.preferredLanguages.map { Locale.Language(identifier: $0).languageCode?.identifier ?? $0 }
    }

    private var defaultTargetCode: String {
        preferredLanguageCodes().first ?? Locale.current.language.languageCode?.identifier ?? "en"
    }

    // MARK: - Auto-detect on page load

    // Called from WebView's didFinish. Cheap early-outs (setting off, no page
    // text) skip before touching the Translation framework at all.
    func maybeAutoTranslate(webView: WKWebView) {
        let forced = forcedTargets.removeValue(forKey: ObjectIdentifier(webView))
        let autoEnabled = UserDefaults.standard.object(forKey: "autoTranslateEnabled") as? Bool ?? true
        guard forced != nil || autoEnabled else { return }
        Task { @MainActor in
            await translate(webView: webView, target: forced, explicit: forced != nil)
        }
    }

    // MARK: - Toggle shortcut

    // Translates whatever foreign text the page has gained since the last pass
    // (a web app showing the next message) — or, with nothing new, flips
    // original/translated. Ignores the auto-translate toggle and the "already
    // in a preferred language" check: the user asked.
    func toggle(webView: WKWebView?) {
        guard let webView else { return }
        Task { @MainActor in
            let showingOriginal = (try? await webView.evaluateJavaScript(
                "!!(window.__subTranslate && window.__subTranslate.isShowingOriginal())")) as? Bool == true
            if showingOriginal { _ = try? await webView.evaluateJavaScript("window.__subTranslate.toggle()") }
            let queued = await translate(webView: webView, explicit: true)
            if !queued, !showingOriginal {
                _ = try? await webView.evaluateJavaScript(
                    "window.__subTranslate && window.__subTranslate.hasTranslation() && window.__subTranslate.toggle()")
            }
        }
    }

    // MARK: - Explicit translation (menus, shortcuts)

    // Detects, filters and queues the page's text. A forced source or target
    // (View ▸ Translate Page From/To) re-offers every node, translated ones
    // included, so the page can be redone from the language the user named
    // or into a different one. Returns whether anything was queued.
    @discardableResult
    func translate(webView: WKWebView, source forcedSource: String? = nil, target forcedTarget: String? = nil,
                   explicit: Bool = true) async -> Bool {
        var all = forcedSource != nil || forcedTarget != nil
        if !all, explicit {
            all = (try? await webView.evaluateJavaScript(
                "!(window.__subTranslate && window.__subTranslate.hasTranslation())")) as? Bool == true
        }
        let candidates = await extractNodes(from: webView, call: "extract(\(all))")
        guard !candidates.isEmpty else { return false }
        let targetCode = forcedTarget ?? defaultTargetCode
        let sample = Self.sample(from: candidates)
        guard let sourceCode = forcedSource ?? (sample.count > 40 ? Self.detectLanguage(sample) : nil) else { return false }
        guard sourceCode != targetCode else { return false }
        if !explicit, preferredLanguageCodes().contains(where: { sourceCode.hasPrefix($0) || $0.hasPrefix(sourceCode) }) {
            return false
        }
        let nodes = forcedSource != nil ? candidates
            : await Task.detached { Self.foreignNodes(candidates, target: targetCode) }.value
        guard !nodes.isEmpty else { return false }
        return await enqueue(webView: webView, nodes: nodes, sourceCode: sourceCode, targetCode: targetCode)
    }

    // Context menu: translate just the selected text, in place. A word or a
    // sentence out of a paragraph keeps its surroundings as written, so the
    // original language stays readable in context.
    func translateSelection(webView: WKWebView, target forcedTarget: String? = nil) {
        Task { @MainActor in
            let nodes = await extractNodes(from: webView, call: "extractSelection()")
            guard !nodes.isEmpty else { return }
            let targetCode = forcedTarget ?? defaultTargetCode
            // The recognizer guesses on short strings; when it's unsure, or
            // sure the selection is already in the target language (the user
            // disagrees), let translationd identify the text itself.
            var sourceCode = Self.detectLanguage(nodes.map(\.text).joined(separator: " "), minimumConfidence: 0.5)
            if sourceCode == targetCode { sourceCode = nil }
            await enqueue(webView: webView, nodes: nodes, sourceCode: sourceCode, targetCode: targetCode)
        }
    }

    // MARK: - Split-pane shortcut

    // Duplicates the tab, adds it to the split, and marks its web view to
    // force-translate (to the top preferred language) once it loads.
    func translateIntoSplitPane(tab: Tab, tabManager: TabManager, webViewManager: WebViewManager, tabs: [Tab]) {
        guard tabManager.splitTabIds.count < TabManager.maxSplitTabs else { return }
        // Not selected: toggleSplitMembership pairs the new tab with the
        // *selected* one, and selecting the copy first left nothing to pair
        // with — the shortcut just opened a plain new tab.
        let newTab = tabManager.duplicateTab(tab, select: false)
        let webView = webViewManager.getWebView(for: newTab.id)
        forcedTargets[ObjectIdentifier(webView)] = defaultTargetCode
        if let url = newTab.url { webView.loadURL(url) }
        tabManager.toggleSplitMembership(newTab, tabs: tabs + [newTab])
    }

    // MARK: - Prefetch

    // Languages you're likely to hit that aren't yours: CLDR likely-subtags
    // gives the region's dominant language ("und-NL" → nl); this supplement
    // covers regions with more than one everyday language.
    // ponytail: short static list, extend if users report a missed region.
    private static let extraRegionLanguages: [String: [String]] = [
        "CA": ["fr"], "CH": ["fr", "it"], "BE": ["fr", "de"], "LU": ["fr", "de"],
        "ES": ["ca"], "FI": ["sv"], "US": ["es"], "IE": ["ga"], "IL": ["ar"],
        "IN": ["hi"], "ZA": ["af", "zu"], "SG": ["zh", "ms", "ta"], "HK": ["zh"],
    ]

    // Just-in-case packs for travel: the most-encountered web languages per
    // continent, preselected in the onboarding picker. Each pair's model is
    // ~100–200 MB, one-time. ponytail: flat lists, extend if users ask.
    private static let europePack = ["fr", "de", "es", "it", "pt"]
    private static let asiaPack = ["zh", "ja", "ko", "hi", "th"]

    struct PackChoice: Identifiable {
        let id: String       // language code
        let name: String     // localized display name
        var selected: Bool
    }

    // Non-nil → ContentView shows the one-time onboarding sheet.
    @Published var packChoices: [PackChoice]?

    // One-time onboarding: offer to pre-download translation models so the
    // first real translation doesn't stall on a multi-minute download.
    // Suggested (preselected) = region languages + travel packs; the full
    // pickable list is everything the Translation framework supports that
    // isn't installed already. Region comes from the device locale — no
    // network/IP lookup.
    func offerPackDownloadIfNeeded() async {
        // Never during UI tests: the sheet appears ~10s in and steals key focus.
        guard !ProcessInfo.processInfo.arguments.contains("-uiTesting") else { return }
        guard !UserDefaults.standard.bool(forKey: "translationPackPromptShown") else { return }
        guard UserDefaults.standard.object(forKey: "autoTranslateEnabled") as? Bool ?? true else { return }
        let region = Locale.current.region?.identifier
        // maximalIdentifier applies CLDR likely subtags: "und-NL" → "nl-Latn-NL"
        let dominant = region.flatMap { r -> String? in
            let code = Locale.Language(identifier: "und-\(r)").maximalIdentifier
                .split(separator: "-").first.map(String.init)
            return code == "und" ? nil : code
        }
        let suggested = Set([dominant].compactMap { $0 }
            + (region.flatMap { Self.extraRegionLanguages[$0] } ?? [])
            + Self.europePack + Self.asiaPack)

        let downloadable = await languagePackStatuses().filter { $0.status == .supported }
        guard !downloadable.isEmpty else {
            UserDefaults.standard.set(true, forKey: "translationPackPromptShown")
            return
        }
        let choices = downloadable.map { PackChoice(id: $0.id, name: $0.name, selected: suggested.contains($0.id)) }
        packChoices = choices.sorted {
            ($0.selected ? 0 : 1, $0.name) < ($1.selected ? 0 : 1, $1.name)
        }
    }

    // MARK: - Language pack status (Settings > Content > Translation)

    struct LanguagePackStatus: Identifiable {
        let id: String       // language code
        let name: String     // localized display name
        let status: LanguageAvailability.Status
    }

    // Every language the Translation framework can pair with the user's target
    // language, minus ones already in their preferred-reading list. Drives both
    // the onboarding pack picker above and the Settings language manager.
    func languagePackStatuses() async -> [LanguagePackStatus] {
        let preferred = preferredLanguageCodes()
        let target = Locale.Language(identifier: defaultTargetCode)
        var result: [LanguagePackStatus] = []
        var seen = Set<String>()
        for code in await Self.supportedLanguageCodes() {
            guard seen.insert(code).inserted else { continue }
            if preferred.contains(where: { code.hasPrefix($0) || $0.hasPrefix(code) }) { continue }
            let status = await LanguageAvailability().status(from: Locale.Language(identifier: code), to: target)
            guard status != .unsupported else { continue }
            let name = Locale.current.localizedString(forLanguageCode: code) ?? code
            result.append(LanguagePackStatus(id: code, name: name, status: status))
        }
        return result.sorted { $0.name < $1.name }
    }

    // LanguageAvailability is not Sendable; keep the instance inside a
    // nonisolated call so only the [String] result crosses back to the actor.
    @concurrent nonisolated static func supportedLanguageCodes() async -> [String] {
        await LanguageAvailability().supportedLanguages.compactMap { $0.languageCode?.identifier }
    }

    // Sheet dismissal: queue downloads for the checked languages (or nothing),
    // and never show the prompt again.
    func confirmPackDownload(download: Bool) {
        UserDefaults.standard.set(true, forKey: "translationPackPromptShown")
        let chosen = (packChoices ?? []).filter(\.selected).map(\.id)
        packChoices = nil
        guard download, !chosen.isEmpty else { return }
        chosen.forEach(downloadLanguage)
    }

    // Queues a model-only prefetch for one language, e.g. from the Settings
    // language manager's "Download" button.
    func downloadLanguage(_ code: String) {
        queue.append(PendingRequest(
            webView: nil, nodes: [], source: Locale.Language(identifier: code), sourceCode: code,
            target: Locale.Language(identifier: defaultTargetCode), targetCode: defaultTargetCode))
        if configuration == nil { pump() }
    }

    // MARK: - Detection + queue

    nonisolated static func detectLanguage(_ text: String, minimumConfidence: Double = 0) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage,
              (recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0) >= minimumConfidence else { return nil }
        return language.rawValue
    }

    // The longest strings on the page, not the first ones: a mail client's
    // sidebar comes first in the DOM, but the message is where the prose is.
    nonisolated static func sample(from nodes: [TextNode], limit: Int = 2000) -> String {
        var out = ""
        for node in nodes.sorted(by: { $0.text.count > $1.text.count }) {
            if out.count >= limit { break }
            out += node.text + "\n"
        }
        return String(out.prefix(limit))
    }

    // Pages mix languages: a mail client's chrome is in your language while the
    // message isn't. Strings the recognizer confidently places in the target
    // language stay put; everything else, including strings too short to judge,
    // goes to the translator. ponytail: 24 chars / 0.6 confidence are guesses —
    // tune if users report chrome getting mangled or paragraphs skipped.
    nonisolated static func foreignNodes(_ nodes: [TextNode], target: String) -> [TextNode] {
        let recognizer = NLLanguageRecognizer()
        return nodes.filter { node in
            guard node.text.count >= 24 else { return true }
            recognizer.reset()
            recognizer.processString(node.text)
            guard let language = recognizer.dominantLanguage, language.rawValue.hasPrefix(target) else { return true }
            return (recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0) < 0.6
        }
    }

    @discardableResult
    private func enqueue(webView: WKWebView, nodes: [TextNode], sourceCode: String?, targetCode: String) async -> Bool {
        let source = sourceCode.map { Locale.Language(identifier: $0) }
        let target = Locale.Language(identifier: targetCode)
        // LanguageAvailability is not Sendable, so keep each instance scoped to
        // the async call instead of retaining it across actor boundaries.
        if let source, await LanguageAvailability().status(from: source, to: target) == .unsupported { return false }

        if let sourceCode, let url = webView.url, let host = SiteHistory.normalizedHost(url) {
            TranslationHistoryStore.shared.recordDetection(
                host: host, title: webView.title ?? host, source: sourceCode, target: targetCode)
        }

        progress[ObjectIdentifier(webView)] = 0.02
        queue.append(PendingRequest(webView: webView, nodes: nodes, source: source, sourceCode: sourceCode,
                                    target: target, targetCode: targetCode))
        if configuration == nil { pump() }
        return true
    }

    private func pump() {
        guard let next = queue.first else { configuration = nil; return }
        configuration = TranslationSession.Configuration(source: next.source, target: next.target)
    }

    // Invoked by ContentView's `.translationTask(pageTranslator.configuration)`
    // whenever `configuration` changes to a fresh (non-nil) value.
    func perform(session: sending TranslationSession) async {
        guard let request = queue.first else { return }
        queue.removeFirst()
        await runTranslation(request, using: session)
        pump()
    }

    private func runTranslation(_ request: PendingRequest, using session: sending TranslationSession) async {
        guard let webView = request.webView else {
            // Prefetch: pull down the language-pair model so the first real
            // translation doesn't stall on a download.
            if (try? await session.prepareTranslation()) != nil, let code = request.sourceCode {
                TranslationLanguageUsage.shared.markInstalled(code)
            }
            return
        }
        let key = ObjectIdentifier(webView)
        defer { progress.removeValue(forKey: key) }
        progress[key] = 0.05
        // Models are per-pair downloads; without this, translations() throws
        // (swallowed) and the feature silently does nothing. Shows the system
        // download sheet the first time a pair is needed; no-op once installed.
        // Nothing to prepare without a source: translationd identifies it.
        if let sourceCode = request.sourceCode {
            do { try await session.prepareTranslation() } catch {
                Logger.warning("language download declined or failed: \(error)", type: "PageTranslator")
                return
            }
            TranslationLanguageUsage.shared.markInstalled(sourceCode)
        }
        guard let map = await Self.translate(nodes: request.nodes, using: session, onProgress: { [weak self] fraction in
            self?.progress[key] = 0.05 + 0.95 * fraction
        }) else { return }
        guard !map.isEmpty,
              let json = try? JSONSerialization.data(withJSONObject: map),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        _ = try? await webView.evaluateJavaScript("window.__subTranslate.apply(\(jsonString))")
        guard let sourceCode = request.sourceCode else { return }
        TranslationLanguageUsage.shared.markUsed(sourceCode)
        if let url = webView.url, let host = SiteHistory.normalizedHost(url) {
            TranslationHistoryStore.shared.recordTranslation(
                host: host, title: webView.title ?? host, source: sourceCode, target: request.targetCode)
        }
    }

    // translationd runs the batch through a 4096-token context. Hand it a whole
    // page at once and it takes the request, goes idle and never replies — the
    // await never returns, `pump()` never runs, and every later page queues
    // behind a translation that will never finish. Batches that fit come back in
    // a couple of seconds, so send the page in character-budgeted chunks.
    // ponytail: chars as a token proxy, and no per-chunk deadline — racing a
    // timeout would mean capturing the non-Sendable session in a child task.
    // Add one (or a session teardown) if translationd wedges on a small batch.
    nonisolated private static let batchCharBudget = 2000

    nonisolated private static func translate(
        nodes: [TextNode],
        using session: sending TranslationSession,
        onProgress: @MainActor @Sendable (Double) -> Void
    ) async -> [String: String]? {
        var batches: [[TextNode]] = []
        var chunk: [TextNode] = []
        var chunkChars = 0
        for node in nodes {
            if !chunk.isEmpty && chunkChars + node.text.count > batchCharBudget {
                batches.append(chunk)
                chunk = []
                chunkChars = 0
            }
            chunk.append(node)
            chunkChars += node.text.count
        }
        if !chunk.isEmpty { batches.append(chunk) }

        var map: [String: String] = [:]
        for (index, batch) in batches.enumerated() {
            let requests = batch.map {
                TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id)
            }
            guard let responses = try? await session.translations(from: requests) else {
                Logger.warning("translation batch of \(requests.count) failed", type: "PageTranslator")
                continue
            }
            for response in responses {
                if let id = response.clientIdentifier { map[id] = response.targetText }
            }
            await onProgress(Double(index + 1) / Double(batches.count))
        }
        return map
    }

    // MARK: - JS bridge helpers

    private func extractNodes(from webView: WKWebView, call: String) async -> [TextNode] {
        let result = try? await webView.evaluateJavaScript("window.__subTranslate ? window.__subTranslate.\(call) : []")
        return (result as? [[String: String]])?.compactMap { entry in
            guard let id = entry["id"], let text = entry["text"] else { return nil }
            return (id: id, text: text)
        } ?? []
    }
}

// Every language the Translation framework knows, for the View menu's
// Translate Page To / From submenus. Loaded once, off the menu's critical path.
final class TranslationLanguages: ObservableObject {
    static let shared = TranslationLanguages()

    @Published private(set) var codes: [String] = []

    init() {
        Task { [weak self] in
            let codes = Set(await PageTranslator.supportedLanguageCodes())
            self?.codes = codes.sorted { Self.name($0) < Self.name($1) }
        }
    }

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}

// One-time onboarding sheet: pick which language packs to pre-download.
// Presented by ContentView while `packChoices` is non-nil.
struct TranslationPackSheet: View {
    @ObservedObject var translator: PageTranslator

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { translator.packChoices?.first(where: { $0.id == id })?.selected ?? false },
            set: { value in
                guard let index = translator.packChoices?.firstIndex(where: { $0.id == id }) else { return }
                translator.packChoices?[index].selected = value
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Translate Pages Offline", comment: "Title of the language pack download onboarding sheet")
                .font(.title2).bold()
            Text("Download languages now so pages translate instantly — even on a slow connection while traveling. Languages common near you are preselected.",
                 comment: "Explanation on the language pack download sheet")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(translator.packChoices ?? []) { choice in
                Toggle(choice.name, isOn: binding(for: choice.id))
            }
            Text("Each language is a one-time download of roughly 100–200 MB. macOS may ask you to confirm each one.",
                 comment: "Footnote on the language pack download sheet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    translator.confirmPackDownload(download: false)
                } label: {
                    Text("Not Now", comment: "Button dismissing the language pack sheet without downloading")
                }
                Spacer()
                Button {
                    translator.confirmPackDownload(download: true)
                } label: {
                    Text("Download", comment: "Button starting the language pack downloads")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400, height: 480)
    }
}
