//
//  WorkspaceSettleCapture.swift
//  Straight Up Browser
//
//  Capture is triggered by a page SETTLING, never by a tab closing.
//
//  Twenty seconds after a page finishes loading, with no navigation in between,
//  it enters the ledger. That is not "the page loaded" — it is "you stayed with
//  it", so the ledger records sources that were considered rather than every
//  page that scrolled past. Closing before then is a rejection, handled by
//  TabManager.closeTab, and at this dwell that is most rejections.
//

import Foundation
import SwiftData
import WebKit

@MainActor
final class WorkspaceSettleCapture {
    private let ledgerStore: LedgerStore
    private let newspaper: NewspaperStore
    /// One pending settle per tab. A new navigation replaces the task, which is
    /// what makes a URL change — including a same-document SPA route change —
    /// reset the timer rather than record whichever route was showing at
    /// didFinish.
    private var pending: [UUID: Task<Void, Never>] = [:]

    /// Video sources get their caption track fetched at capture (Phase 2);
    /// async and failure-tolerant — never on the capture path's critical path.
    let transcriptFetcher: TranscriptFetcher

    init(ledgerStore: LedgerStore, modelContext: ModelContext) {
        self.ledgerStore = ledgerStore
        newspaper = NewspaperStore(modelContext: modelContext)
        transcriptFetcher = TranscriptFetcher(ledgerStore: ledgerStore)
    }

    /// Called on every committed navigation. Cancels any settle in flight for
    /// this tab and, when the tab belongs to a workspace, starts a new one.
    ///
    /// Background tabs settle exactly like displayed ones: opening ten search
    /// results and closing the seven bad ones is the workflow this is for.
    func pageDidSettleEventually(
        tab: Tab,
        webView: WKWebView?,
        openedFromSourceId: UUID? = nil,
        dwell: Duration = WorkspaceCapturePolicy.settleDwell
    ) {
        cancel(tabId: tab.id)

        // Incognito never reaches the ledger, and the default workspace captures
        // nothing at all.
        guard tab.sessionKind != .incognito,
              let workspaceId = tab.workspaceId,
              let url = tab.url
        else { return }

        // Fast guard: a reference already exists and the source is fully
        // captured, so a revisit costs one indexed fetch and zero writes.
        guard !ledgerStore.isFullyCaptured(workspaceId: workspaceId, url: url) else { return }

        let tabId = tab.id
        pending[tabId] = Task { [weak self, weak tab, weak webView] in
            try? await Task.sleep(for: dwell)
            guard !Task.isCancelled, let self, let tab else { return }
            self.pending[tabId] = nil

            // Re-read rather than trusting the captured values: twenty seconds
            // is long enough for the tab to have moved on, changed workspace, or
            // gone away entirely.
            guard let currentURL = tab.url,
                  tab.sessionKind != .incognito,
                  let currentWorkspaceId = tab.workspaceId,
                  SourceCanonicalizer.canonicalKey(for: currentURL)
                      == SourceCanonicalizer.canonicalKey(for: url)
            else { return }

            guard let article = self.ledgerStore.recordSettle(
                url: currentURL,
                title: tab.title,
                workspaceId: currentWorkspaceId,
                openedFromSourceId: openedFromSourceId
            ) else { return }

            // Everything above is the guaranteed floor: the source and its
            // reference exist. Extraction and archiving are opportunistic on
            // top, and neither can fail in a way the user sees.
            self.captureOpportunistically(article: article, webView: webView, expectedURL: currentURL)
        }
    }

    /// Deliberate one-keystroke capture: the user says "keep this one" without
    /// waiting out the dwell. Same writes as a settle, but the method records
    /// that a person chose it. Returns false when there is nothing to capture.
    @discardableResult
    func captureNow(tab: Tab, webView: WKWebView?) -> Bool {
        guard tab.sessionKind != .incognito,
              let workspaceId = tab.workspaceId,
              let url = tab.url
        else { return false }

        // A pending settle for this tab is now redundant.
        cancel(tabId: tab.id)

        let article = ledgerStore.recordManualCapture(
            url: url,
            title: tab.title,
            workspaceId: workspaceId
        )
        captureOpportunistically(article: article, webView: webView, expectedURL: url)
        return true
    }

    func cancel(tabId: UUID) {
        pending[tabId]?.cancel()
        pending[tabId] = nil
    }

    func cancelAll() {
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }

    // MARK: Opportunistic capture

    private func captureOpportunistically(
        article: NewspaperArticle,
        webView: WKWebView?,
        expectedURL: URL
    ) {
        guard let webView, !webView.isLoading else { return }
        guard let live = webView.url,
              SourceCanonicalizer.canonicalKey(for: live)
                  == SourceCanonicalizer.canonicalKey(for: expectedURL)
        else { return }

        NewspaperCaptureCoordinator.capture(
            article,
            from: webView,
            expectedURL: expectedURL,
            store: newspaper
        )
        archive(article: article, from: webView)
        if article.modality == .video {
            let fetcher = transcriptFetcher
            Task { @MainActor [weak webView] in
                _ = await fetcher.ensureTranscript(for: article, webView: webView)
            }
        }
    }

    private func archive(article: NewspaperArticle, from webView: WKWebView) {
        let sourceId = article.id
        let sourceKey = article.sourceKey
        webView.createWebArchiveData { [weak self] result in
            guard let self, case .success(let data) = result else { return }
            guard data.count <= WorkspaceCapturePolicy.maximumArchiveBytes else { return }
            Task { @MainActor in
                self.ledgerStore.storeArchive(sourceId: sourceId, sourceKey: sourceKey, data: data)
            }
        }
    }
}
