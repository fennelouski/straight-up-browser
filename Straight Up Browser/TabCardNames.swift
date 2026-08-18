//
//  TabCardNames.swift
//  Straight Up Browser
//
//  A preview card has two lines, and "Google Docs" over "Google Docs" is worth
//  no more than one. So each page gets named twice — the product it belongs to,
//  and the page itself — and the card decides which half goes on top: whichever
//  one tells this tab apart from the others open right now.
//

import Foundation
import Combine
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, *)
@Generable
struct ModeledTabName {
    @Guide(description: "The product or site this page belongs to, as a person would say it: \"Google Docs\", \"GitHub\", \"The Verge\". Never a URL, never a tagline. Under 24 characters.")
    var site: String
    @Guide(description: "This page on its own — the document, article, thread, or view name, with the site name removed. \"Q3 Budget\", not \"Q3 Budget - Google Docs\". Under 32 characters. Empty string if the page is just the site's front door.")
    var page: String
}
#endif

@MainActor
final class TabCardNames: ObservableObject {
    static let shared = TabCardNames()

    static let useAppleIntelligenceKey = "tabCardNamesUseAppleIntelligence"
    private static let storageKey = "tabCardNames"
    private static let storageLimit = 300

    struct Pair: Codable, Equatable {
        var site: String
        var page: String
    }

    @Published private(set) var names: [String: Pair] = [:]
    private var asking: Set<String> = []
    private let defaults = UserDefaults.standard

    private init() {
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([String: Pair].self, from: data) {
            names = saved
        }
    }

    /// The two lines of a tab's card. Falls back to the domain and the tab's own
    /// distinct label until (or unless) the model has answered.
    func labels(for tab: Tab, among tabs: [Tab]) -> (title: String, detail: String) {
        let modeled = tab.url.flatMap { names[Self.key(for: $0)] }
        let site = modeled.map(\.site).flatMap(Self.clean) ?? Self.fallbackSite(for: tab)
        let page = modeled.map(\.page).flatMap(Self.clean) ?? tab.peekLabel(among: tabs, maxLength: 48)

        // One tab on a site and its name identifies the tab. Several, and the
        // site name stops telling them apart, so the page has to lead.
        let host = Self.host(tab.url)
        let peers = tabs.filter { Self.host($0.url) == host }.count
        if peers > 1, !page.isEmpty, page.caseInsensitiveCompare(site) != .orderedSame {
            return (page, site)
        }
        return (site, page == site ? (tab.url?.host ?? "") : page)
    }

    /// Ask the model for anything unnamed. Cheap to call repeatedly — it skips
    /// pages that are already named, already in flight, or still loading in.
    func requestMissing(for tabs: [Tab]) {
        guard defaults.object(forKey: Self.useAppleIntelligenceKey) as? Bool ?? true else { return }
        for tab in tabs {
            guard let url = tab.url, !tab.title.isEmpty else { continue }
            let key = Self.key(for: url)
            guard names[key] == nil, !asking.contains(key) else { continue }
            asking.insert(key)
            Task { @MainActor [weak self] in
                let pair = await Self.modelName(url: url, title: tab.title)
                guard let self else { return }
                self.asking.remove(key)
                // nil means the model wasn't available; leave the page unnamed so
                // a later pass tries again.
                guard let pair else { return }
                self.names[key] = pair
                self.save()
            }
        }
    }

    private func save() {
        if names.count > Self.storageLimit {
            names = Dictionary(uniqueKeysWithValues: names.suffix(Self.storageLimit))
        }
        defaults.set(try? JSONEncoder().encode(names), forKey: Self.storageKey)
    }

    // MARK: - Naming

    #if canImport(FoundationModels)
    private static func modelName(url: URL, title: String) async -> Pair? {
        guard #available(macOS 26.0, iOS 26.0, *),
              SystemLanguageModel.default.availability == .available else { return nil }
        let session = LanguageModelSession(instructions: """
            You label browser tabs. Split a page's identity into the site it \
            belongs to and the page itself, so the two labels never repeat each \
            other. Use the names people say out loud, keep them short, and never \
            invent detail the title and URL don't support.
            """)
        guard let output = try? await session.respond(
            to: "URL: \(url.absoluteString)\nPage title: \(title)",
            generating: ModeledTabName.self).content else { return nil }
        let site = clean(output.site) ?? fallbackSite(host: url.host)
        return Pair(site: site, page: clean(output.page) ?? "")
    }
    #else
    private static func modelName(url: URL, title: String) async -> Pair? { nil }
    #endif

    private static func clean(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 48 else { return nil }
        return trimmed
    }

    private static func key(for url: URL) -> String {
        Tab.normalizeURLForComparison(url)?.absoluteString ?? url.absoluteString
    }

    private static func host(_ url: URL?) -> String {
        guard var host = url?.host?.lowercased() else { return "" }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private static func fallbackSite(for tab: Tab) -> String {
        guard tab.url != nil else { return String(localized: "New Tab") }
        return fallbackSite(host: tab.url?.host)
    }

    // "docs.google.com" -> "Google". The registrable name is the one people
    // recognise; the subdomain and the TLD are noise on a card this small.
    private static func fallbackSite(host: String?) -> String {
        var parts = host?.lowercased().split(separator: ".").map(String.init) ?? []
        if parts.first == "www" { parts.removeFirst() }
        guard let name = parts.count >= 2 ? parts[parts.count - 2] : parts.first else {
            return String(localized: "New Tab")
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
