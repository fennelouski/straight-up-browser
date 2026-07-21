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
        let webView: WKWebView
        let source: Locale.Language
        let target: Locale.Language
    }

    private var queue: [PendingRequest] = []
    private let availability = LanguageAvailability()

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
        if let url = newTab.url { webView.load(URLRequest(url: url)) }
        tabManager.toggleSplitMembership(newTab, tabs: tabs + [newTab])
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
        guard await availability.status(from: source, to: target) != .unsupported else { return }

        queue.append(PendingRequest(webView: webView, source: source, target: target))
        if configuration == nil { pump() }
    }

    private func pump() {
        guard let next = queue.first else { configuration = nil; return }
        configuration = TranslationSession.Configuration(source: next.source, target: next.target)
    }

    // Invoked by ContentView's `.translationTask(pageTranslator.configuration)`
    // whenever `configuration` changes to a fresh (non-nil) value.
    func perform(session: TranslationSession) async {
        guard let request = queue.first else { return }
        queue.removeFirst()
        await runTranslation(request, using: session)
        pump()
    }

    private func runTranslation(_ request: PendingRequest, using session: TranslationSession) async {
        guard let nodes = await extractNodes(from: request.webView), !nodes.isEmpty else { return }
        let sessionRequests = nodes.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id) }
        guard let responses = try? await session.translations(from: sessionRequests) else { return }

        var map: [String: String] = [:]
        for response in responses {
            if let id = response.clientIdentifier { map[id] = response.targetText }
        }
        guard !map.isEmpty,
              let json = try? JSONSerialization.data(withJSONObject: map),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        _ = try? await request.webView.evaluateJavaScript("window.__subTranslate.apply(\(jsonString))")
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
