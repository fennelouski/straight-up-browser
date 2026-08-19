//
//  SourceCanonicalizer.swift
//  Straight Up Browser
//
//  One canonical identity per source. This is what makes "seen before" work and
//  what stops a video's anchor locator (?t=417) from forking the video itself
//  into two sources.
//
//  NewspaperStore.sourceKey(for:) delegates here, so the reading list and the
//  research ledger can never disagree about what page they are looking at.
//

import Foundation

nonisolated enum SourceCanonicalizer {

    /// Params that identify a campaign, not a document.
    private static let trackingParams: Set<String> = [
        "fbclid", "gclid", "msclkid", "mc_cid", "mc_eid", "igshid",
        "si", "ref", "ref_src", "ref_url", "feature"
    ]

    /// YouTube params that describe a viewing position or a playlist context
    /// rather than which video this is. `t` is an ANCHOR LOCATOR — dropping it
    /// here is the entire reason this type exists.
    private static let youTubeNoiseParams: Set<String> = [
        "t", "start", "list", "index", "pp", "ab_channel"
    ]

    static func canonicalKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        var host = (components.host ?? "").lowercased()
        // Near-universally an alias, and the duplicate-source cost of keeping it
        // is constant. ponytail: drop this rule if a site ever serves different
        // content at the apex.
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        components.host = host.isEmpty ? components.host : host

        if let siteSpecific = siteSpecific(components: components, host: host) {
            return siteSpecific
        }

        components.queryItems = cleanedQuery(components.queryItems, dropping: trackingParams)
        components.path = trimmedPath(components.path)
        return components.url?.absoluteString ?? url.absoluteString
    }

    // MARK: Per-site rules

    private static func siteSpecific(components: URLComponents, host: String) -> String? {
        if host == "youtube.com" || host == "m.youtube.com" || host == "music.youtube.com" {
            if let id = youTubeID(path: components.path, query: components.queryItems) {
                return "https://youtube.com/watch?v=\(id)"
            }
        }
        if host == "youtu.be" {
            let id = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !id.isEmpty { return "https://youtube.com/watch?v=\(id)" }
        }
        if host == "x.com" || host == "twitter.com", components.path.contains("/status/") {
            return "https://x.com" + trimmedPath(components.path)
        }
        if host == "arxiv.org" {
            // /pdf/2401.12345v2.pdf -> /abs/2401.12345v2. Version suffixes are
            // preserved: v1 and v2 of a paper are genuinely different sources.
            var path = trimmedPath(components.path)
            if path.hasPrefix("/pdf/") {
                path = "/abs/" + String(path.dropFirst(5))
                if path.hasSuffix(".pdf") { path = String(path.dropLast(4)) }
            }
            return "https://arxiv.org" + path
        }
        if host == "doi.org" || host == "dx.doi.org" {
            return "https://doi.org" + trimmedPath(components.path).lowercased()
        }
        return nil
    }

    private static func youTubeID(path: String, query: [URLQueryItem]?) -> String? {
        if path == "/watch", let v = query?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return v
        }
        for prefix in ["/shorts/", "/live/", "/embed/", "/v/"] where path.hasPrefix(prefix) {
            let id = String(path.dropFirst(prefix.count)).split(separator: "/").first.map(String.init)
            if let id, !id.isEmpty { return id }
        }
        return nil
    }

    // MARK: Generic helpers

    private static func cleanedQuery(
        _ items: [URLQueryItem]?,
        dropping drops: Set<String>
    ) -> [URLQueryItem]? {
        guard let items else { return nil }
        let kept = items
            .filter { !drops.contains($0.name.lowercased()) }
            .filter { !$0.name.lowercased().hasPrefix("utm_") }
            // Sorted so ?a=1&b=2 and ?b=2&a=1 are the same source.
            .sorted { $0.name == $1.name ? ($0.value ?? "") < ($1.value ?? "") : $0.name < $1.name }
        return kept.isEmpty ? nil : kept
    }

    /// Strips a trailing slash on non-root paths so /a/ and /a agree.
    private static func trimmedPath(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    /// Sources with no meaningful URL (imported files) are identified by content.
    static func contentKey(forHash hash: String) -> String { "hash:\(hash)" }

    /// Whether the YouTube noise list would have changed this URL — used by the
    /// video anchor path to recover a timestamp the canonical key drops.
    static func youTubeTimestampSeconds(in url: URL) -> Int? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "t" || $0.name == "start" })?.value
        else { return nil }
        if let seconds = Int(raw) { return seconds }
        // "1h2m3s" / "417s"
        var total = 0, digits = ""
        for character in raw {
            if character.isNumber { digits.append(character); continue }
            let value = Int(digits) ?? 0
            switch character {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default: break
            }
            digits = ""
        }
        if let trailing = Int(digits) { total += trailing }
        return total > 0 ? total : nil
    }

    /// Params the YouTube rule removes, exposed so the noise set has one owner.
    static var youTubeDroppedParams: Set<String> { youTubeNoiseParams }
}
