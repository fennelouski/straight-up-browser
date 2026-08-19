//
//  MarkdownStyling.swift
//  Straight Up Browser
//
//  The hybrid live-render core shared by the Mac and iOS editors (Phase 2,
//  docs/phase2-design.md §2). Pure span computation: given the document text,
//  which ranges are headings, emphasis, code, list markers, links, and syntax
//  marks. The platform text views map spans to attributes and decide caret-line
//  behavior; nothing here mutates text — what is on disk is always exactly what
//  the storage holds.
//
//  ponytail: regex-per-line styling, recomputed for the whole document on edit.
//  Markdown notes are tens of KB; switch to per-paragraph incremental restyle
//  if profiling ever shows this in a trace.
//

import Foundation

nonisolated enum MarkdownStyling {

    enum Kind: Equatable {
        case heading(Int)        // 1–6
        case bold
        case italic
        case inlineCode
        case codeBlock           // interior of a fenced block, whole line
        case listMarker          // "- ", "1. ", "> "
        case blockquoteText
        case syntaxMark          // #, **, `, [, ](…) — faded off the caret line
        case linkText            // the [text] of any Markdown link
    }

    struct Span: Equatable {
        let range: NSRange       // UTF-16 offsets into the document
        let kind: Kind
    }

    /// All spans for the document, in application order: block-level first,
    /// then inline emphasis, then links — so later spans override where they
    /// overlap, exactly as the text views apply them.
    static func spans(for text: String) -> [Span] {
        var spans: [Span] = []
        let nsText = text as NSString
        var inFence = false

        nsText.enumerateSubstrings(in: NSRange(location: 0, length: nsText.length),
                                   options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let line = nsText.substring(with: lineRange)

            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                spans.append(Span(range: lineRange, kind: .syntaxMark))
                inFence.toggle()
                return
            }
            if inFence {
                spans.append(Span(range: lineRange, kind: .codeBlock))
                return
            }

            // Block-level prefixes.
            if let match = firstMatch(headingPattern, in: line) {
                let level = min(match.range(at: 1).length, 6)
                spans.append(Span(range: offset(match.range(at: 1), by: lineRange.location), kind: .syntaxMark))
                let rest = NSRange(location: lineRange.location + match.range.length,
                                   length: lineRange.length - match.range.length)
                if rest.length > 0 { spans.append(Span(range: rest, kind: .heading(level))) }
            } else if let match = firstMatch(blockquotePattern, in: line) {
                spans.append(Span(range: offset(match.range(at: 1), by: lineRange.location), kind: .listMarker))
                let rest = NSRange(location: lineRange.location + match.range.length,
                                   length: lineRange.length - match.range.length)
                if rest.length > 0 { spans.append(Span(range: rest, kind: .blockquoteText)) }
            } else if let match = firstMatch(listPattern, in: line) {
                spans.append(Span(range: offset(match.range(at: 1), by: lineRange.location), kind: .listMarker))
            }

            // Inline emphasis and code, skipped inside headings only for marks.
            appendInline(in: line, lineStart: lineRange.location, to: &spans)
        }

        // Links, whole-text: brackets/URL/title are marks, the text is linkText.
        for match in AnchorLink.parseAllMatches(in: text) {
            let full = match.range
            let inner = match.textRange
            // "[" up to the text
            spans.append(Span(range: NSRange(location: full.location, length: inner.location - full.location), kind: .syntaxMark))
            spans.append(Span(range: inner, kind: .linkText))
            // "](url "title")" after the text
            let tailStart = inner.location + inner.length
            spans.append(Span(range: NSRange(location: tailStart, length: full.location + full.length - tailStart), kind: .syntaxMark))
        }
        return spans
    }

    // MARK: Inline runs

    private static func appendInline(in line: String, lineStart: Int, to spans: inout [Span]) {
        for match in matches(inlineCodePattern, in: line) {
            mark(match, group: 2, kind: .inlineCode, lineStart: lineStart, to: &spans)
        }
        for match in matches(boldPattern, in: line) {
            mark(match, group: 2, kind: .bold, lineStart: lineStart, to: &spans)
        }
        for match in matches(italicPattern, in: line) {
            mark(match, group: 2, kind: .italic, lineStart: lineStart, to: &spans)
        }
    }

    /// The delimiters become syntax marks; the captured group becomes `kind`.
    private static func mark(_ match: NSTextCheckingResult, group: Int, kind: Kind, lineStart: Int, to spans: inout [Span]) {
        let full = match.range, content = match.range(at: group)
        guard content.location != NSNotFound else { return }
        spans.append(Span(range: offset(NSRange(location: full.location, length: content.location - full.location), by: lineStart), kind: .syntaxMark))
        spans.append(Span(range: offset(content, by: lineStart), kind: kind))
        let tailStart = content.location + content.length
        spans.append(Span(range: offset(NSRange(location: tailStart, length: full.location + full.length - tailStart), by: lineStart), kind: .syntaxMark))
    }

    // MARK: Regexes (compiled once)

    private static let headingPattern = regex(#"^(#{1,6})[ \t]"#)
    private static let blockquotePattern = regex(#"^([ \t]*>[ \t]?)"#)
    private static let listPattern = regex(#"^([ \t]*(?:[-*+]|\d{1,3}\.)[ \t])"#)
    private static let inlineCodePattern = regex(#"(`+)([^`]+)\1"#)
    // Emphasis: deliberately simple. Nested/edge-case Markdown (e.g. "**a *b***")
    // styles imperfectly and renders fine everywhere else — the file is the truth.
    private static let boldPattern = regex(#"(\*\*|__)([^*_]+)\1"#)
    private static let italicPattern = regex(#"(?<![*_])([*_])([^*_\s][^*_]*)\1(?![*_])"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants; a typo fails the first test run.
        try! NSRegularExpression(pattern: pattern)
    }

    private static func firstMatch(_ regex: NSRegularExpression, in line: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
    }

    private static func matches(_ regex: NSRegularExpression, in line: String) -> [NSTextCheckingResult] {
        regex.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length))
    }

    private static func offset(_ range: NSRange, by location: Int) -> NSRange {
        NSRange(location: range.location + location, length: range.length)
    }

    // MARK: Shared metrics

    /// Heading sizes as multiples of the body size, index = level - 1.
    static let headingScales: [CGFloat] = [1.6, 1.4, 1.25, 1.15, 1.05, 1.0]

    /// Syntax marks fade to this opacity when the caret is elsewhere. Deliberate
    /// deviation from full hiding: layout never reflows, and the bytes on disk
    /// are always the bytes on screen. Recorded in docs/phase2-design.md §2.2.
    static let fadedMarkOpacity: CGFloat = 0.28

    /// The custom attribute carrying a resolved anchor's id on its pill range.
    static let anchorIdAttribute = NSAttributedString.Key("BrowserAnchorId")
    /// Carried alongside: the anchor's source key, for peek/disposition lookups.
    static let anchorSourceKeyAttribute = NSAttributedString.Key("BrowserAnchorSourceKey")
}
