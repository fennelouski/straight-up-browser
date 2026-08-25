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

// On-device page translation. NLLanguageRecognizer detects the loaded page's
// language from a short text sample; if it isn't one of the user's preferred
// languages, the page's visible text is extracted (WebViewManager's
// __subTranslate JS), batch-translated via Apple's Translation framework, and
// written back into the DOM. `configuration` drives a single `.translationTask`
// (attached once at the window root in ContentView) — a FIFO queue serializes
// translate requests since TranslationSession only runs one task at a time.
@MainActor
final class PageTranslator: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?

    private struct PendingRequest {
        // nil webView = prefetch: download the pair's model, translate nothing.
        let webView: WKWebView?
        let source: Locale.Language
        let target: Locale.Language
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
            guard let sample = await sampleText(from: webView), sample.count > 40 else { return }
            await detectAndEnqueue(sample: sample, webView: webView, forceTarget: forced)
        }
    }

    // MARK: - Toggle shortcut

    // Flips original/translated if the page already has a translation;
    // otherwise translates it into the user's top preferred language first
    // (covers pages auto-translate skipped, or got the detection wrong).
    func toggle(webView: WKWebView?) {
        guard let webView else { return }
        Task { @MainActor in
            let raw = try? await webView.evaluateJavaScript(
                "!!(window.__subTranslate && window.__subTranslate.hasTranslation())")
            if (raw as? Bool) == true {
                _ = try? await webView.evaluateJavaScript("window.__subTranslate.toggle()")
                return
            }
            guard let sample = await sampleText(from: webView), sample.count > 40 else { return }
            await detectAndEnqueue(sample: sample, webView: webView, forceTarget: defaultTargetCode)
        }
    }

    // MARK: - Split-pane shortcut

    // Duplicates the tab, adds it to the split, and marks its web view to
    // force-translate (to the top preferred language) once it loads.
    func translateIntoSplitPane(tab: Tab, tabManager: TabManager, webViewManager: WebViewManager, tabs: [Tab]) {
        guard tabManager.splitTabIds.count < TabManager.maxSplitTabs else { return }
        let newTab = tabManager.duplicateTab(tab)
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
        let preferred = preferredLanguageCodes()
        let target = Locale.Language(identifier: defaultTargetCode)

        var choices: [PackChoice] = []
        var seen = Set<String>()
        for code in await Self.supportedLanguageCodes() {
            guard seen.insert(code).inserted else { continue }
            if preferred.contains(where: { code.hasPrefix($0) || $0.hasPrefix(code) }) { continue }
            // Only .supported needs a download; .installed and .unsupported don't.
            let language = Locale.Language(identifier: code)
            guard await LanguageAvailability().status(from: language, to: target) == .supported else { continue }
            let name = Locale.current.localizedString(forLanguageCode: code) ?? code
            choices.append(PackChoice(id: code, name: name, selected: suggested.contains(code)))
        }
        guard !choices.isEmpty else {
            UserDefaults.standard.set(true, forKey: "translationPackPromptShown")
            return
        }
        packChoices = choices.sorted {
            ($0.selected ? 0 : 1, $0.name) < ($1.selected ? 0 : 1, $1.name)
        }
    }

    // LanguageAvailability is not Sendable; keep the instance inside a
    // nonisolated call so only the [String] result crosses back to the actor.
    @concurrent nonisolated private static func supportedLanguageCodes() async -> [String] {
        await LanguageAvailability().supportedLanguages.compactMap { $0.languageCode?.identifier }
    }

    // Sheet dismissal: queue downloads for the checked languages (or nothing),
    // and never show the prompt again.
    func confirmPackDownload(download: Bool) {
        UserDefaults.standard.set(true, forKey: "translationPackPromptShown")
        let chosen = (packChoices ?? []).filter(\.selected).map(\.id)
        packChoices = nil
        guard download, !chosen.isEmpty else { return }
        let target = Locale.Language(identifier: defaultTargetCode)
        for code in chosen {
            queue.append(PendingRequest(webView: nil, source: Locale.Language(identifier: code), target: target))
        }
        if configuration == nil { pump() }
    }

    // MARK: - Detection + queue

    private func detectAndEnqueue(sample: String, webView: WKWebView, forceTarget: String?) async {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let detected = recognizer.dominantLanguage else { return }
        let sourceCode = detected.rawValue
        let targetCode = forceTarget ?? defaultTargetCode
        guard sourceCode != targetCode else { return }
        if forceTarget == nil {
            let preferred = preferredLanguageCodes()
            if preferred.contains(where: { sourceCode.hasPrefix($0) || $0.hasPrefix(sourceCode) }) { return }
        }

        let source = Locale.Language(identifier: sourceCode)
        let target = Locale.Language(identifier: targetCode)
        // LanguageAvailability is not Sendable, so keep each instance scoped to
        // the async call instead of retaining it across actor boundaries.
        guard await LanguageAvailability().status(from: source, to: target) != .unsupported else { return }

        queue.append(PendingRequest(webView: webView, source: source, target: target))
        if configuration == nil { pump() }
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
            try? await session.prepareTranslation()
            return
        }
        guard let nodes = await extractNodes(from: webView), !nodes.isEmpty else { return }
        // Models are per-pair downloads; without this, translations() throws
        // (swallowed) and the feature silently does nothing. Shows the system
        // download sheet the first time a pair is needed; no-op once installed.
        do { try await session.prepareTranslation() } catch {
            Logger.warning("language download declined or failed: \(error)", type: "PageTranslator")
            return
        }
        guard let map = await Self.translate(nodes: nodes, using: session) else { return }
        guard !map.isEmpty,
              let json = try? JSONSerialization.data(withJSONObject: map),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        _ = try? await webView.evaluateJavaScript("window.__subTranslate.apply(\(jsonString))")
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
        nodes: [(id: String, text: String)],
        using session: sending TranslationSession
    ) async -> [String: String]? {
        var batches: [[(id: String, text: String)]] = []
        var chunk: [(id: String, text: String)] = []
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
        for batch in batches {
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
        }
        return map
    }

    // MARK: - JS bridge helpers

    private func sampleText(from webView: WKWebView) async -> String? {
        let result = try? await webView.evaluateJavaScript("window.__subTranslate ? window.__subTranslate.sampleText() : null")
        return result as? String
    }

    private func extractNodes(from webView: WKWebView) async -> [(id: String, text: String)]? {
        let result = try? await webView.evaluateJavaScript("window.__subTranslate ? window.__subTranslate.extract() : null")
        guard let array = result as? [[String: String]] else { return nil }
        return array.compactMap { entry in
            guard let id = entry["id"], let text = entry["text"] else { return nil }
            return (id: id, text: text)
        }
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
