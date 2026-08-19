//
//  AnchorComposer.swift
//  Straight Up Browser
//
//  The anchor creation funnel (Phase 2, design §6.1). Every surface — the Mac
//  keystroke and context menu, the iOS edit-menu action, the transcript panel —
//  lands here: ensure the source is captured, build the locator, write the
//  LedgerAnchor, append the Markdown link to the workspace's current document,
//  write the edge, and copy the link for precise placement later.
//

import Foundation
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class AnchorComposer {
    private let ledgerStore: LedgerStore
    private let documentStore: DocumentStore
    private let settleCapture: WorkspaceSettleCapture

    init(ledgerStore: LedgerStore, documentStore: DocumentStore, settleCapture: WorkspaceSettleCapture) {
        self.ledgerStore = ledgerStore
        self.documentStore = documentStore
        self.settleCapture = settleCapture
    }

    /// The whole page gesture. Returns the localized transient note to show.
    func anchorSelection(tab: Tab, webView: WKWebView?, workspaceId: UUID?) async -> String {
        guard tab.sessionKind != .incognito else {
            return String(localized: "Private tabs are never captured.")
        }
        guard let workspaceId else {
            return String(localized: "Open a workspace to anchor sources into it.")
        }
        guard let url = tab.url else {
            return String(localized: "Nothing to anchor yet.")
        }

        // Selection and playback position come from the live page.
        let selection = await selectionText(in: webView)
        let videoSeconds = await currentVideoSeconds(in: webView)

        // Capture first (the deliberate path — same writes as ⇧⌘D), so the
        // anchor always has a source row to hang from.
        settleCapture.captureNow(tab: tab, webView: webView)
        guard let article = ledgerStore.source(
            sourceKey: SourceCanonicalizer.canonicalKey(for: url)
        ) else {
            return String(localized: "Couldn't capture this page.")
        }

        let locator: AnchorLocator
        switch article.modality {
        case .video:
            // The URL's ?t= wins over playback position: a shared timestamp link
            // anchors the moment it names.
            let start = SourceCanonicalizer.youTubeTimestampSeconds(in: url) ?? videoSeconds ?? 0
            locator = .timestamp(start: start, end: nil)
        case .webPage, .importedFile:
            if let selection, !selection.isEmpty {
                locator = .textFragment(Self.textFragmentDirective(for: selection))
            } else {
                locator = .wholeSource
            }
        case .pdf, .image:
            // Page-level PDF and region-level image anchor CREATION are out of
            // Phase 2 scope (design §10); the locator formats are ready.
            locator = .wholeSource
        }

        let quote = String((selection ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        let linkText = Self.linkText(selection: selection, title: tab.title, locator: locator)
        return finishAnchor(
            article: article,
            locator: locator,
            quote: quote,
            linkText: linkText,
            workspaceId: workspaceId
        )
    }

    /// The transcript panel's gesture: caption text selected → a timestamped
    /// video anchor whose quote is the caption text (design §8.2).
    func anchorTranscript(
        article: NewspaperArticle,
        startSeconds: Int,
        endSeconds: Int?,
        captionText: String,
        workspaceId: UUID
    ) -> String {
        let locator = AnchorLocator.timestamp(start: startSeconds, end: endSeconds)
        let linkText = Self.linkText(selection: captionText, title: article.title, locator: locator)
        return finishAnchor(
            article: article,
            locator: locator,
            quote: captionText,
            linkText: linkText,
            workspaceId: workspaceId
        )
    }

    /// Phase 5's acceptance gesture: a bibliography passage becomes an anchor
    /// with a text-fragment locator — exactly what the manual selection gesture
    /// would have produced.
    func anchorPassage(article: NewspaperArticle, passageText: String, workspaceId: UUID) -> String {
        let locator = AnchorLocator.textFragment(Self.textFragmentDirective(for: passageText))
        let linkText = Self.linkText(selection: passageText, title: article.title, locator: locator)
        return finishAnchor(
            article: article,
            locator: locator,
            quote: String(passageText.prefix(2000)),
            linkText: linkText,
            workspaceId: workspaceId
        )
    }

    // MARK: Shared tail

    private func finishAnchor(
        article: NewspaperArticle,
        locator: AnchorLocator,
        quote: String,
        linkText: String,
        workspaceId: UUID
    ) -> String {
        let anchor = ledgerStore.createAnchor(
            source: article,
            modality: article.modality,
            locator: locator,
            quote: quote
        )
        // The canonical key is the clean base for http(s) sources (tracking
        // params already stripped); hash-keyed imports fall back to the raw URL.
        let base = article.sourceKey.hasPrefix("http")
            ? (URL(string: article.sourceKey) ?? article.url)
            : article.url
        let href = locator.url(base: base, modality: article.modality)
        let markdown = AnchorLink.markdown(text: linkText, url: href, anchorId: anchor.id)

        copyToClipboard(markdown)

        // Destination: the workspace's current document, auto-creating "Notes"
        // on first capture (design §3.1).
        guard let workspace = ledgerStore.workspace(id: workspaceId) else {
            return String(localized: "Link copied.")
        }
        let destination = documentStore.currentDocument(workspaceId: workspaceId)
            ?? documentStore.createDocument(in: workspace, name: String(localized: "Notes"))
        guard let destination else {
            // iCloud unavailable: the anchor exists and the link is on the
            // clipboard — the document write is the only thing that failed.
            return String(localized: "Link copied — iCloud Drive is unavailable, so nothing was appended.")
        }
        documentStore.append(line: "- " + markdown, to: destination)
        ledgerStore.recordEdge(documentId: destination.id, anchorId: anchor.id, quote: linkText)
        return String(localized: "Anchored to “\(destination.displayName)” — link copied.")
    }

    // MARK: Page reads

    private func selectionText(in webView: WKWebView?) async -> String? {
        guard let webView else { return nil }
        let js = "window.getSelection ? window.getSelection().toString() : ''"
        let result = try? await webView.evaluateJavaScript(js)
        let text = result as? String
        return (text?.isEmpty == false) ? text : nil
    }

    private func currentVideoSeconds(in webView: WKWebView?) async -> Int? {
        guard let webView else { return nil }
        let js = "(() => { const v = document.querySelector('video'); return v ? v.currentTime : null })()"
        guard let result = try? await webView.evaluateJavaScript(js) else { return nil }
        if let seconds = result as? Double { return Int(seconds) }
        if let seconds = result as? Int { return seconds }
        return nil
    }

    // MARK: Pure helpers (unit-tested directly)

    /// A text-fragment directive for a selection: the whole (normalized)
    /// selection when short, a start,end pair when long — the same forms the
    /// href composes and the resolver matches.
    nonisolated static func textFragmentDirective(for selection: String) -> String {
        let normalized = selection
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if normalized.count <= 150 {
            return "text=" + encode(normalized)
        }
        let words = normalized.components(separatedBy: " ")
        let start = words.prefix(6).joined(separator: " ")
        let end = words.suffix(6).joined(separator: " ")
        return "text=" + encode(start) + "," + encode(end)
    }

    /// The user-visible link text: the selection trimmed to 120 characters at a
    /// word boundary, else the page/video title with the timestamp appended.
    nonisolated static func linkText(selection: String?, title: String, locator: AnchorLocator) -> String {
        if let selection {
            let normalized = selection
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !normalized.isEmpty {
                if normalized.count <= 120 { return normalized }
                let cut = normalized.prefix(120)
                let atBoundary = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
                return String(atBoundary) + "…"
            }
        }
        let cleanTitle = title.isEmpty ? String(localized: "Untitled") : title
        if case .timestamp(let start, _) = locator {
            return cleanTitle + " " + String(localized: "at \(formatTimestamp(start))")
        }
        return cleanTitle
    }

    nonisolated static func formatTimestamp(_ seconds: Int) -> String {
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60, secs = seconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    private nonisolated static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
