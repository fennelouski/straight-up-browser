//
//  SiteHistory.swift
//  Straight Up Browser
//
//  Which sites you actually go back to, so the omnibar can turn a nickname into
//  the site you meant: "gmail" -> mail.google.com, "cal" -> calendar.google.com,
//  "giz" -> gizmodo.com. Per-tab `historyStrings` can't do this — it's a URL list
//  with no visit counts, no recency, and no page titles (the only place the word
//  "Gmail" appears anywhere near mail.google.com).
//
//  One row per host, kept in UserDefaults. Small by construction: a few hundred
//  hosts, capped, pruned oldest-first.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct SiteVisit: Codable {
    var host: String        // www-stripped, e.g. "mail.google.com"
    var title: String       // most recent page title — the nickname source
    var count: Int
    var lastVisit: Date
    // Names the on-device model knows this site by ("hn" for news.ycombinator.com).
    // Optional, not defaulted: synthesized Codable throws on a missing key even when
    // the property has a default, so rows written before this existed must decode.
    // nil = not asked yet (or the model wasn't available); [] = asked, nothing known.
    var nicknames: [String]?

    var url: URL? { URL(string: "https://\(host)/") }
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, *)
@Generable
struct ModeledSiteNicknames {
    @Guide(description: "Up to three lowercase names people commonly type for this site — its short name and any well-known initialism, e.g. \"hn\" and \"hackernews\" for news.ycombinator.com. One word each, no spaces, no punctuation. Empty array if the site has no name in common use.")
    var nicknames: [String]
}
#endif

final class SiteHistory {
    static let shared = SiteHistory()

    // A site earns bare-word navigation ("woot" + Return goes to woot.com instead
    // of searching for the word) only once it's a habit, not a one-off.
    static let habitVisits = 5
    static let habitWindow: TimeInterval = 90 * 24 * 3600   // 3 months

    private static let storeKey = "siteVisitHistory"
    private static let maxEntries = 500
    // Two page loads on the same host inside this window are one visit, so a
    // link-heavy browse of one site doesn't outrank a site you open daily.
    private static let visitCoalesceWindow: TimeInterval = 30 * 60

    // Escape hatch, mirroring FastForward: kill the model branch without killing
    // nicknames — the derived initials below keep working either way.
    static let useAppleIntelligenceKey = "siteNicknamesUseAppleIntelligence"

    private let defaults: UserDefaults
    private(set) var sites: [String: SiteVisit] = [:]
    // Hosts with a nickname request in flight, so a run of page loads on one site
    // doesn't queue the same question a dozen times.
    private var askingAbout: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storeKey),
           let decoded = try? JSONDecoder().decode([String: SiteVisit].self, from: data) {
            sites = decoded
        }
    }

    // MARK: - Recording

    func record(url: URL, title: String?, now: Date = Date()) {
        guard url.scheme == "https" || url.scheme == "http",
              let host = Self.normalizedHost(url) else { return }

        var entry = sites[host] ?? SiteVisit(host: host, title: "", count: 0, lastVisit: .distantPast)
        if now.timeIntervalSince(entry.lastVisit) > Self.visitCoalesceWindow {
            entry.count += 1
        }
        entry.lastVisit = now
        if let title, !title.isEmpty { entry.title = title }
        sites[host] = entry
        save()

        // Once a site is a habit it's worth knowing what you call it.
        if entry.count >= Self.habitVisits, entry.nicknames == nil {
            askModelForNicknames(host: host, title: entry.title)
        }
    }

    static func normalizedHost(_ url: URL) -> String? {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host
    }

    private func save() {
        if sites.count > Self.maxEntries {
            let keep = sites.values.sorted { $0.lastVisit > $1.lastVisit }.prefix(Self.maxEntries)
            sites = Dictionary(uniqueKeysWithValues: keep.map { ($0.host, $0) })
        }
        if let data = try? JSONEncoder().encode(sites) {
            defaults.set(data, forKey: Self.storeKey)
        }
    }

    func clear() {
        sites = [:]
        defaults.removeObject(forKey: Self.storeKey)
    }

    // MARK: - Matching

    // How well `query` starts this site's name. Prefix-only: typing "z" shouldn't
    // drag in every site containing a z. Shared with open-tab matching in the
    // omnibar so both rank things the same way.
    //   3 = the host itself starts with it   ("giz"    -> gizmodo.com)
    //   2 = a host label starts with it      ("cal"    -> calendar.google.com)
    //   1 = a word of the page title does    ("gmail"  -> mail.google.com)
    //   1 = a nickname: the title's initials ("hn"     -> news.ycombinator.com)
    //       or one the model gave us         ("email"  -> mail.google.com)
    static func matchRank(host: String, title: String,
                          aliases: [String] = [], query: String) -> Double? {
        let q = query.lowercased()
        guard !q.isEmpty, !q.contains(" ") else { return nil }
        let host = host.lowercased()
        if host.hasPrefix(q) { return 3 }
        if host.split(separator: ".").contains(where: { $0.hasPrefix(q) }) { return 2 }
        if titleWords(title).contains(where: { $0.hasPrefix(q) }) { return 1 }
        if aliases.contains(where: { $0.lowercased().hasPrefix(q) }) { return 1 }
        // Initialisms match whole or not at all — "h" meaning "hn" is a coincidence,
        // not an intention.
        if initialisms(of: title).contains(q) { return 1 }
        return nil
    }

    // "Some Article - Hacker News" -> "hn", "GitHub - user/repo" -> "gh". Sites put
    // their name at one end of the title or the other, so both ends get a candidate;
    // camel case counts as a word break so one-word names still yield an initialism.
    // Junk ("Inbox (3) - me@gmail.com - Gmail") self-filters on the length cap.
    static func initialisms(of title: String) -> [String] {
        let segments = title.split(whereSeparator: { "-–—|·:".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return [segments.first, segments.last].compactMap { segment -> String? in
            guard let segment, !segment.isEmpty else { return nil }
            let letters = segment
                .split(whereSeparator: { !$0.isLetter })
                .flatMap(splitCamelCase)
                .compactMap { $0.first?.lowercased() }
            guard (2...4).contains(letters.count) else { return nil }
            return letters.joined()
        }
    }

    private static func splitCamelCase(_ word: Substring) -> [Substring] {
        var parts: [Substring] = []
        var start = word.startIndex
        var previous: Character?
        for index in word.indices {
            if let previous, previous.isLowercase, word[index].isUppercase {
                parts.append(word[start..<index])
                start = index
            }
            previous = word[index]
        }
        parts.append(word[start...])
        return parts
    }

    static func titleWords(_ title: String) -> [String] {
        title.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 1 }
    }

    // Match quality scaled by how much of a habit the site is. Visits decay over
    // a month, so a site you used 50 times last year loses to one you use weekly.
    static func score(_ site: SiteVisit, query: String, now: Date = Date()) -> Double? {
        guard let rank = matchRank(host: site.host, title: site.title,
                                   aliases: site.nicknames ?? [], query: query) else { return nil }
        let days = max(0, now.timeIntervalSince(site.lastVisit)) / 86400
        return rank * (Double(site.count) / (1 + days / 30))
    }

    func matches(_ query: String, limit: Int = 5, now: Date = Date()) -> [SiteVisit] {
        sites.values
            .compactMap { site in Self.score(site, query: query, now: now).map { (site, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    // MARK: - On-device nicknames

    // Asked once per site, the first time it crosses the habit threshold — never on
    // the typing path. A wrong answer just means a nickname that never fires.
    // ponytail: SiteHistory is main-thread-only by convention (the omnibar and the
    // web view delegate are its only callers); the model hop comes back to the main
    // actor before touching `sites`.
    private func askModelForNicknames(host: String, title: String) {
        guard defaults.object(forKey: Self.useAppleIntelligenceKey) as? Bool ?? true,
              !askingAbout.contains(host) else { return }
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        askingAbout.insert(host)
        Task { @MainActor [weak self] in
            let names = await Self.modelNicknames(host: host, title: title)
            guard let self else { return }
            self.askingAbout.remove(host)
            // nil means the model wasn't available — leave the row unasked so a later
            // visit tries again. An empty answer is an answer: don't ask twice.
            guard let names else { return }
            self.sites[host]?.nicknames = names
            self.save()
            Logger.log("SiteHistory: nicknames for \(host) → \(names)", type: "SiteHistory")
        }
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, iOS 26.0, *)
    private static func modelNicknames(host: String, title: String) async -> [String]? {
        guard SystemLanguageModel.default.availability == .available else { return nil }
        let session = LanguageModelSession(instructions: """
            You give the short names people actually type for a website.
            Answer only with names in common use — an abbreviation, an initialism, or \
            the product's everyday name. Never invent one, never repeat the domain \
            itself, and return an empty array if nothing is well known.
            """)
        guard let output = try? await session.respond(
            to: "Site: \(host)\nPage title: \(title)",
            generating: ModeledSiteNicknames.self).content else { return nil }
        let cleaned = output.nicknames
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains(" ") && $0.count <= 20 && $0 != host }
        return Array(Set(cleaned)).sorted()
    }
    #else
    @available(macOS 26.0, iOS 26.0, *)
    private static func modelNicknames(host: String, title: String) async -> [String]? { nil }
    #endif

    // The site a bare typed word should navigate to, or nil to fall through to a
    // web search. Gated on the habit rule above.
    func habit(for query: String, now: Date = Date()) -> SiteVisit? {
        guard let top = matches(query, limit: 1, now: now).first,
              top.count >= Self.habitVisits,
              now.timeIntervalSince(top.lastVisit) < Self.habitWindow else { return nil }
        return top
    }
}
