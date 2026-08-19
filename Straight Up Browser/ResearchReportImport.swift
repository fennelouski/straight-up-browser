//
//  ResearchReportImport.swift
//  Straight Up Browser
//
//  Deep-research import (Phase 7, docs/phase7-design.md): a pasted
//  Gemini/Claude/ChatGPT report becomes a workspace document; its citations
//  become sources, references (with lineage back to the report), and anchors —
//  and one ordinary Phase 2 save turns its links into pre-populated edges.
//  Provenance tracing is then Phase 4's Shared Upstream fan, already shipped.
//

import Foundation

// MARK: - Parser (pure, table-tested)

nonisolated enum ResearchReportParser {

    struct Citation: Equatable {
        let url: URL
        /// The link text for Markdown links; empty for bare URLs.
        let text: String
        /// Only genuine Markdown links get edges — an edge needs a text range
        /// that says something. Bare URLs still join the bundle.
        let isMarkdownLink: Bool
    }

    struct Report: Equatable {
        let title: String
        let markdown: String
        let citations: [Citation]
    }

    static let maximumTitleLength = 80

    static func parse(_ raw: String, titleOverride: String? = nil) -> Report {
        let markdown = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return Report(
            title: cleanTitle(titleOverride) ?? inferredTitle(from: markdown),
            markdown: markdown,
            citations: citations(in: markdown)
        )
    }

    /// First heading, else the first non-empty line — cleaned and capped.
    static func inferredTitle(from markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        let heading = lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let candidate = heading ?? lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return cleanTitle(candidate) ?? String(localized: "Imported Report")
    }

    private static func cleanTitle(_ raw: String?) -> String? {
        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        while title.hasPrefix("#") { title.removeFirst() }
        title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        if title.count > maximumTitleLength {
            title = String(title.prefix(maximumTitleLength))
        }
        return title
    }

    /// Markdown links first, then bare URLs — deduplicated by canonical key so
    /// tracking-param variants collapse and a video's ?t= stays a locator, not
    /// a second source. First occurrence wins (Markdown links come first, so a
    /// link always beats its own bare footnote twin).
    static func citations(in markdown: String) -> [Citation] {
        var seen: Set<String> = []
        var citations: [Citation] = []
        func add(_ url: URL, text: String, isMarkdownLink: Bool) {
            guard url.scheme == "http" || url.scheme == "https" else { return }
            guard seen.insert(SourceCanonicalizer.canonicalKey(for: url)).inserted else { return }
            citations.append(Citation(url: url, text: text, isMarkdownLink: isMarkdownLink))
        }
        for match in AnchorLink.parseAllMatches(in: markdown) {
            add(match.parsed.url, text: match.parsed.text, isMarkdownLink: true)
        }
        for bare in bareURLs(in: markdown) {
            add(bare, text: "", isMarkdownLink: false)
        }
        return citations
    }

    /// Plain http(s) URLs outside Markdown link syntax — footnote lists, mostly.
    static func bareURLs(in markdown: String) -> [URL] {
        let pattern = #"(?<!\]\()https?://[^\s\)\]>"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        return regex.matches(in: markdown, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: markdown) else { return nil }
            // Trailing sentence punctuation is prose, not URL.
            var text = String(markdown[matchRange])
            while let last = text.last, ".,;:!?".contains(last) { text.removeLast() }
            return URL(string: text)
        }
    }

    /// The locator a citation URL already carries, in stored form — the same
    /// forms the resolver matches on (fallback #2) so repair finds the anchor.
    static func inferredLocator(for url: URL, modality: SourceModality) -> AnchorLocator {
        switch modality {
        case .video:
            if let seconds = SourceCanonicalizer.youTubeTimestampSeconds(in: url) {
                return .timestamp(start: seconds, end: nil)
            }
            return .wholeSource
        case .webPage, .importedFile:
            if let directive = AnchorResolver.textFragmentDirective(in: url) {
                return .textFragment(directive)
            }
            return .wholeSource
        case .pdf, .image:
            return .wholeSource
        }
    }
}

// MARK: - Importer (the §3 pipeline)

@MainActor
enum ResearchReportImporter {

    struct Summary: Equatable {
        let documentId: UUID
        let documentName: String
        let citedSources: Int
        let linkedEdges: Int
    }

    /// The whole import. Returns nil (with no partial document) only when the
    /// document itself cannot be created — iCloud unavailable, mostly.
    static func importReport(
        text: String,
        titleOverride: String?,
        workspace: Workspace,
        ledgerStore: LedgerStore,
        documentStore: DocumentStore
    ) async -> Summary? {
        let report = ResearchReportParser.parse(text, titleOverride: titleOverride)
        guard !report.markdown.isEmpty else { return nil }

        // 1. The report becomes a source — content-hashed, so re-importing the
        //    same report is the same source (the Phase 3 identity rule).
        let reportSource = ledgerStore.recordFileImport(
            data: Data(report.markdown.utf8),
            suggestedName: report.title + ".md",
            workspaceId: workspace.id,
            importsDirectory: ShareIngest.importsDirectory(),
            method: .importBundle
        )

        // 2 + 3. Every citation: source + reference (with lineage back to the
        //    report — the Shared Upstream fan) + an anchor for the save pass
        //    to resolve against.
        var cited = 0
        for citation in report.citations {
            let article = ledgerStore.recordBundleSource(
                url: citation.url,
                title: citation.text.isEmpty ? citation.url.host ?? citation.url.absoluteString : citation.text,
                workspaceId: workspace.id,
                openedFromSourceId: reportSource?.id
            )
            cited += 1
            if citation.isMarkdownLink {
                let locator = ResearchReportParser.inferredLocator(for: citation.url, modality: article.modality)
                ledgerStore.createAnchor(
                    source: article,
                    modality: article.modality,
                    locator: locator,
                    quote: citation.text
                )
            }
        }

        // 4. The report becomes a document; ONE ordinary Phase 2 save performs
        //    title repair (^id markers into the file) and edge reconciliation
        //    (the pre-populated claim-citation edges).
        guard let row = documentStore.createDocument(in: workspace, name: report.title) else { return nil }
        let session = documentStore.session(for: row, workspaceId: workspace.id)
        await session.open()
        session.editorDidChangeText(report.markdown)
        await session.saveNow()

        return Summary(
            documentId: row.id,
            documentName: row.displayName,
            citedSources: cited,
            linkedEdges: ledgerStore.edges(documentId: row.id).count
        )
    }
}
