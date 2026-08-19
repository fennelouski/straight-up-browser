//
//  AnchorResolver.swift
//  Straight Up Browser
//
//  Resolving anchor links in a document against the ledger, in exactly the
//  order docs/phase1-handoff.md §2 ships:
//
//    1. Parse "^…" from the title, prefix-match LedgerAnchor.id → enriched.
//    2. Miss → match canonical URL + parsed locator against the anchor table
//       → enriched, and repair the title on next save.
//    3. Miss → render as a plain link. Never an error, never a broken document.
//
//  The save pass lives here too, because fallback #2's title repair is a
//  document rewrite and belongs beside the resolution that demands it.
//

import Foundation

@MainActor
final class AnchorResolver {
    private let ledgerStore: LedgerStore

    init(ledgerStore: LedgerStore) {
        self.ledgerStore = ledgerStore
    }

    /// How one link in a document resolved.
    enum State: Equatable {
        /// Step 1: the "^…" marker matched an anchor id.
        case enrichedById
        /// Step 2: no usable marker, but URL + locator matched an anchor.
        /// The next save rewrites the title with the anchor's marker.
        case enrichedByLocator
        /// Step 3: an ordinary link. Rendered exactly like one the user typed.
        case plain
    }

    struct ResolvedLink: Equatable {
        let match: AnchorLink.Match
        let state: State
        /// Present for both enriched states; nil for plain.
        let anchorId: UUID?
        let sourceKey: String?
        let disposition: SourceDisposition?

        var isEnriched: Bool { state != .plain }
    }

    // MARK: Resolution

    func resolve(markdown: String, workspaceId: UUID?) -> [ResolvedLink] {
        AnchorLink.parseAllMatches(in: markdown).map { match in
            resolveOne(match, workspaceId: workspaceId)
        }
    }

    private func resolveOne(_ match: AnchorLink.Match, workspaceId: UUID?) -> ResolvedLink {
        // Step 1: id-prefix from the title.
        if let prefix = match.parsed.idPrefix, let anchor = ledgerStore.anchor(idPrefix: prefix) {
            return enriched(match, anchor: anchor, state: .enrichedById, workspaceId: workspaceId)
        }
        // Step 2: canonical URL + locator. Covers links pasted from outside the
        // app, and titles mangled by an external editor.
        if let anchor = anchorByLocator(for: match.parsed.url) {
            return enriched(match, anchor: anchor, state: .enrichedByLocator, workspaceId: workspaceId)
        }
        // Step 3: plain. Never an error.
        return ResolvedLink(match: match, state: .plain, anchorId: nil, sourceKey: nil, disposition: nil)
    }

    private func enriched(
        _ match: AnchorLink.Match,
        anchor: LedgerAnchor,
        state: State,
        workspaceId: UUID?
    ) -> ResolvedLink {
        let disposition = workspaceId.flatMap {
            ledgerStore.reference(workspaceId: $0, sourceKey: anchor.sourceKey)?.disposition
        }
        return ResolvedLink(
            match: match,
            state: state,
            anchorId: anchor.id,
            sourceKey: anchor.sourceKey,
            disposition: disposition
        )
    }

    /// Fallback #2's lookup: the link URL's canonical identity plus whatever
    /// locator its fragment/params carry, matched against stored anchors.
    private func anchorByLocator(for url: URL) -> LedgerAnchor? {
        let key = SourceCanonicalizer.canonicalKey(for: url)
        let candidates = ledgerStore.anchors(sourceKey: key)
        guard !candidates.isEmpty else { return nil }
        return candidates.first { candidate in
            Self.locatorMatches(url: url, anchor: candidate)
        }
    }

    /// Whether a link URL addresses the same location as a stored anchor.
    /// Modality-aware because the URL form loses information (a video href
    /// carries only the start second; the stored locator may carry an end).
    nonisolated static func locatorMatches(url: URL, anchor: LedgerAnchor) -> Bool {
        let stored = AnchorLocator.parse(anchor.locator, modality: anchor.modality)
        switch anchor.modality {
        case .video:
            guard case .timestamp(let start, _) = stored else { return urlHasNoLocator(url, modality: .video) }
            return SourceCanonicalizer.youTubeTimestampSeconds(in: url) == start
        case .webPage, .importedFile:
            let directive = textFragmentDirective(in: url)
            guard case .textFragment(let storedDirective) = stored else { return directive == nil }
            return directive == storedDirective
        case .pdf:
            guard case .pdfPage(let page, _) = stored else { return url.fragment == nil }
            return url.fragment?.hasPrefix("page=\(page)") == true
        case .image:
            guard case .imageRegion(let region) = stored else { return url.fragment == nil }
            let value = region.hasPrefix("xywh=") ? region : "xywh=" + region
            return url.fragment == value
        }
    }

    private nonisolated static func urlHasNoLocator(_ url: URL, modality: SourceModality) -> Bool {
        modality == .video ? SourceCanonicalizer.youTubeTimestampSeconds(in: url) == nil : url.fragment == nil
    }

    /// The `text=…` directive from a `#:~:text=…` fragment, un-decoded — the
    /// same form `AnchorLocator.textFragment` stores.
    nonisolated static func textFragmentDirective(in url: URL) -> String? {
        let absolute = url.absoluteString
        guard let range = absolute.range(of: "#:~:") else { return nil }
        let directive = String(absolute[range.upperBound...])
        return directive.isEmpty ? nil : directive
    }

    // MARK: The save pass

    struct SaveResult: Equatable {
        /// The buffer after title repair. Identical to the input when no link
        /// needed repair — untouched regions are never rewritten.
        let markdown: String
        /// Edge occurrences for LedgerStore.reconcileEdges, offsets in UTF-16.
        let occurrences: [LedgerStore.EdgeOccurrence]
    }

    /// Runs on every save, before bytes hit the coordinator:
    ///   1. Title repair — links resolved via fallback #2 get their "^id" marker
    ///      written into the title, so the fast path works next time.
    ///   2. Edge extraction — every enriched link becomes an edge occurrence.
    func processForSave(markdown: String, workspaceId: UUID?) -> SaveResult {
        var text = markdown
        // Repair back-to-front so earlier ranges stay valid while editing.
        let resolved = resolve(markdown: text, workspaceId: workspaceId)
        for link in resolved.reversed() {
            guard link.state == .enrichedByLocator, let anchorId = link.anchorId else { continue }
            let token = AnchorLink.idToken(for: anchorId)
            let nsText = text as NSString
            if let titleRange = link.match.titleRange {
                // A foreign title is replaced: the marker is what makes the
                // document self-healing, and external readers only ever saw a
                // tooltip.
                text = nsText.replacingCharacters(in: titleRange, with: token)
            } else {
                // No title: insert one before the closing paren.
                let insertAt = link.match.range.location + link.match.range.length - 1
                text = nsText.replacingCharacters(in: NSRange(location: insertAt, length: 0), with: " \"\(token)\"")
            }
        }
        // Re-resolve against the repaired text so offsets are final.
        let final = resolve(markdown: text, workspaceId: workspaceId)
        let occurrences = final.compactMap { link -> LedgerStore.EdgeOccurrence? in
            guard let anchorId = link.anchorId else { return nil }
            return LedgerStore.EdgeOccurrence(
                anchorId: anchorId,
                quote: link.match.parsed.text,
                start: link.match.range.location,
                length: link.match.range.length
            )
        }
        return SaveResult(markdown: text, occurrences: occurrences)
    }
}
