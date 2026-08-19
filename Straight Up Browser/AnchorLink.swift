//
//  AnchorLink.swift
//  Straight Up Browser
//
//  The anchor Markdown syntax. Enriched in-app, an ordinary working link
//  everywhere else:
//
//      [the gut bacteria finding](https://ex.com/a#:~:text=gut%20bacteria "^a1b2c3d4")
//
//  The href is the genuine deep link, so it works in any browser with none of
//  our software involved. The title attribute carries the ledger id, which
//  external readers show as a tooltip or ignore. If the ledger is deleted
//  entirely, the link still works — a document is never hostage to the database.
//

import Foundation

/// A modality-specific position inside a source. Stored as one string; this
/// type composes it into a URL and parses it back.
nonisolated enum AnchorLocator: Equatable, Sendable {
    case wholeSource
    /// The text-fragment directive without its `#:~:` prefix.
    case textFragment(String)
    /// Seconds from the start, optionally to an end second.
    case timestamp(start: Int, end: Int?)
    case pdfPage(Int, quote: String?)
    /// W3C Media Fragments spatial region — a real standard that renderers
    /// ignore harmlessly rather than a private invention.
    case imageRegion(String)

    /// The stored form, which is always URL-fragment shaped.
    var stored: String {
        switch self {
        case .wholeSource:
            return ""
        case .textFragment(let directive):
            return directive.hasPrefix("text=") ? directive : "text=\(directive)"
        case .timestamp(let start, let end):
            return end.map { "t=\(start),\($0)" } ?? "t=\(start)"
        case .pdfPage(let page, let quote):
            guard let quote, !quote.isEmpty else { return "page=\(page)" }
            return "page=\(page)&text=\(Self.encode(quote))"
        case .imageRegion(let region):
            return region.hasPrefix("xywh=") ? region : "xywh=\(region)"
        }
    }

    static func parse(_ stored: String, modality: SourceModality) -> AnchorLocator {
        guard !stored.isEmpty else { return .wholeSource }
        switch modality {
        case .video:
            let value = stored.hasPrefix("t=") ? String(stored.dropFirst(2)) : stored
            let parts = value.split(separator: ",").map { Int($0) }
            guard let start = parts.first ?? nil else { return .wholeSource }
            return .timestamp(start: start, end: parts.count > 1 ? parts[1] : nil)
        case .pdf:
            var page: Int?
            var quote: String?
            for pair in stored.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                if kv[0] == "page" { page = Int(kv[1]) }
                if kv[0] == "text" { quote = decode(kv[1]) }
            }
            guard let page else { return .wholeSource }
            return .pdfPage(page, quote: quote)
        case .image:
            return .imageRegion(stored)
        case .webPage, .importedFile:
            return .textFragment(stored)
        }
    }

    /// Compose the deep link a reader actually follows.
    func url(base: URL, modality: SourceModality) -> URL {
        switch self {
        case .wholeSource:
            return base
        case .textFragment(let directive):
            let value = directive.hasPrefix("text=") ? directive : "text=\(directive)"
            return URL(string: base.absoluteString + "#:~:" + value) ?? base
        case .timestamp(let start, _):
            // A timestamp is a query param on YouTube, not a fragment.
            guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            else { return base }
            var items = components.queryItems ?? []
            items.removeAll { $0.name == "t" || $0.name == "start" }
            items.append(URLQueryItem(name: "t", value: String(start)))
            components.queryItems = items
            return components.url ?? base
        case .pdfPage(let page, _):
            return URL(string: base.absoluteString + "#page=\(page)") ?? base
        case .imageRegion(let region):
            let value = region.hasPrefix("xywh=") ? region : "xywh=\(region)"
            return URL(string: base.absoluteString + "#" + value) ?? base
        }
    }

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
    }

    private static func decode(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }
}

/// Building and parsing the Markdown form.
nonisolated enum AnchorLink {

    /// How many hex characters of the anchor id go in the title. Enough to be
    /// unambiguous in a document, short enough to read as a marker.
    static let idPrefixLength = 8

    static func idToken(for anchorId: UUID) -> String {
        "^" + anchorId.uuidString.replacingOccurrences(of: "-", with: "")
            .prefix(idPrefixLength).lowercased()
    }

    /// `[text](url "^id")`
    static func markdown(text: String, url: URL, anchorId: UUID) -> String {
        let escaped = text.replacingOccurrences(of: "]", with: "\\]")
        return "[\(escaped)](\(url.absoluteString) \"\(idToken(for: anchorId))\")"
    }

    nonisolated struct Parsed: Equatable, Sendable {
        let text: String
        let url: URL
        /// nil when the link is an ordinary Markdown link with no ledger marker.
        let idPrefix: String?
    }

    /// A parsed link plus where it sits in the document — the spans the editor
    /// needs for pill rendering, edge offsets, and title repair. All ranges are
    /// UTF-16 (NSRange) offsets into the markdown string.
    nonisolated struct Match: Equatable, Sendable {
        let parsed: Parsed
        /// The whole `[text](url "title")` span.
        let range: NSRange
        /// The link-text span (inside the brackets).
        let textRange: NSRange
        /// The title-content span (inside the quotes), or nil when no title.
        let titleRange: NSRange?
    }

    /// `parseAll` with source ranges. Same regex, same tolerance: links with no
    /// `"^…"` title carry a nil idPrefix.
    static func parseAllMatches(in markdown: String) -> [Match] {
        let pattern = #"\[([^\]]*)\]\(([^\s\)]+)(?:\s+"([^"]*)")?\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        return regex.matches(in: markdown, range: range).compactMap { match in
            guard let textRange = Range(match.range(at: 1), in: markdown),
                  let urlRange = Range(match.range(at: 2), in: markdown),
                  let url = URL(string: String(markdown[urlRange]))
            else { return nil }
            var idPrefix: String?
            var titleRange: NSRange?
            if match.range(at: 3).location != NSNotFound,
               let range3 = Range(match.range(at: 3), in: markdown) {
                titleRange = match.range(at: 3)
                let title = String(markdown[range3])
                if title.hasPrefix("^") { idPrefix = String(title.dropFirst()).lowercased() }
            }
            return Match(
                parsed: Parsed(
                    text: String(markdown[textRange]).replacingOccurrences(of: "\\]", with: "]"),
                    url: url,
                    idPrefix: idPrefix
                ),
                range: match.range,
                textRange: match.range(at: 1),
                titleRange: titleRange
            )
        }
    }

    /// Finds every Markdown link in a chunk of document text. Links with no
    /// `"^…"` title parse fine and simply carry a nil idPrefix — resolution
    /// falls back to matching URL + locator, and failing that renders plainly.
    static func parseAll(in markdown: String) -> [Parsed] {
        // [text](url) or [text](url "title")
        let pattern = #"\[([^\]]*)\]\(([^\s\)]+)(?:\s+"([^"]*)")?\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        return regex.matches(in: markdown, range: range).compactMap { match in
            guard let textRange = Range(match.range(at: 1), in: markdown),
                  let urlRange = Range(match.range(at: 2), in: markdown),
                  let url = URL(string: String(markdown[urlRange]))
            else { return nil }
            var idPrefix: String?
            if match.range(at: 3).location != NSNotFound,
               let titleRange = Range(match.range(at: 3), in: markdown) {
                let title = String(markdown[titleRange])
                if title.hasPrefix("^") { idPrefix = String(title.dropFirst()).lowercased() }
            }
            return Parsed(
                text: String(markdown[textRange]).replacingOccurrences(of: "\\]", with: "]"),
                url: url,
                idPrefix: idPrefix
            )
        }
    }

    /// Whether a stored anchor id matches a prefix pulled out of a document.
    static func matches(anchorId: UUID, idPrefix: String) -> Bool {
        anchorId.uuidString.replacingOccurrences(of: "-", with: "")
            .lowercased()
            .hasPrefix(idPrefix.lowercased())
    }
}
