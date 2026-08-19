//
//  WebView_iOS.swift
//  Browser (iPadOS)
//
//  UIKit twin of the Mac WebView.swift. The heavy lifting (WKWebView ownership,
//  ad-block, memory-pressure unload) lives in the shared WebViewManager; this is
//  the SwiftUI bridge + delegate coordinator + the container that swaps the
//  active tab's web view in and out.
//
//  iPad adaptations vs. macOS: UIViewRepresentable, a UIView container,
//  UIAlertController for JS dialogs, a share sheet for finished downloads,
//  UIImage favicon validation, UIKeyModifierFlags for ⌘/⌥-click, and no file
//  open-panel (WKWebView shows the native picker itself) or magnification
//  (Mac-only). Favicon fallback is left to the SwiftUI tab row's letter avatar.
//

import SwiftUI
import WebKit
import UIKit

// Named TabWebView, not WebView: iOS 26's WebKit ships a SwiftUI `WebView`, and
// our same-named type shadowed it in a way that produced an empty (zero-drawing)
// view. The distinct name avoids the collision.
struct TabWebView: UIViewRepresentable {
    @Binding var url: URL?
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var title: String
    @Binding var isLoading: Bool
    @Binding var progressValue: Double
    @Binding var hasRenderedContent: Bool

    var webViewManager: WebViewManager?
    var tabManager: TabManager?
    var fastForward: FastForward?
    var tabs: [Tab]?
    var activeTabId: UUID?
    var splitTabIds: [UUID]
    // ADR 0008 on iPad: pane ids resolve to a document view first, then a web
    // view. Nil (iPhone) keeps splits tab-only.
    var documentPaneProvider: ((UUID) -> UIView?)?
    var focusedDocumentId: UUID?
    var onURLChange: ((URL?) -> Void)?
    var onPageFinished: ((WKWebView) -> Void)?

    init(url: Binding<URL?>,
         canGoBack: Binding<Bool>,
         canGoForward: Binding<Bool>,
         title: Binding<String>,
         isLoading: Binding<Bool>,
         progressValue: Binding<Double>,
         hasRenderedContent: Binding<Bool>,
         webViewManager: WebViewManager?,
         tabManager: TabManager?,
         fastForward: FastForward? = nil,
         tabs: [Tab]?,
         activeTabId: UUID?,
         splitTabIds: [UUID] = [],
         documentPaneProvider: ((UUID) -> UIView?)? = nil,
         focusedDocumentId: UUID? = nil,
         onURLChange: ((URL?) -> Void)?,
         onPageFinished: ((WKWebView) -> Void)? = nil) {
        self._url = url
        self._canGoBack = canGoBack
        self._canGoForward = canGoForward
        self._title = title
        self._isLoading = isLoading
        self._progressValue = progressValue
        self._hasRenderedContent = hasRenderedContent
        self.webViewManager = webViewManager
        self.tabManager = tabManager
        self.fastForward = fastForward
        self.tabs = tabs
        self.activeTabId = activeTabId
        self.splitTabIds = splitTabIds
        self.documentPaneProvider = documentPaneProvider
        self.focusedDocumentId = focusedDocumentId
        self.onURLChange = onURLChange
        self.onPageFinished = onPageFinished
    }

    func makeUIView(context: Context) -> WebViewContainer_iOS {
        WebViewContainer_iOS(webViewManager: webViewManager, coordinator: context.coordinator)
    }

    func updateUIView(_ uiView: WebViewContainer_iOS, context: Context) {
        // Refresh the coordinator's snapshot of the world (see the Mac note): it
        // otherwise keeps the tab list captured at creation and writes titles/URLs
        // into tabs that no longer match.
        context.coordinator.parent = self
        context.coordinator.tabs = tabs
        context.coordinator.tabManager = tabManager

        uiView.documentPaneProvider = documentPaneProvider
        uiView.setDisplayedTabs(
            activeTabId: activeTabId,
            splitTabIds: splitTabIds,
            focusedDocumentId: focusedDocumentId
        )

        // Restored split members may not have been selected yet this launch.
        // Prime each visible pane without making it the active command target.
        // Document ids are skipped BEFORE getWebView — it would create a web
        // view as a side effect (ADR 0008).
        let displayedIds = splitTabIds.count >= 2
            ? splitTabIds
            : [activeTabId].compactMap { $0 }
        for id in displayedIds where id != activeTabId {
            guard documentPaneProvider?(id) == nil,
                  let tab = tabs?.first(where: { $0.id == id }),
                  let pane = webViewManager?.getWebView(for: id) else { continue }
            pane.pageZoom = tab.zoomLevel
            if pane.url == nil, let paneURL = tab.url, !pane.isLoading {
                pane.load(URLRequest(url: paneURL))
            }
        }

        guard let activeWebView = uiView.activeWebView else { return }
        if let tab = tabs?.first(where: { $0.id == activeTabId }) {
            webViewManager?.setMuted(tab.isMuted, for: tab.id)
        }

        // Reapply the tab's persisted zoom (the zoom shortcuts write it).
        if let tab = tabs?.first(where: { $0.id == activeTabId }), activeWebView.pageZoom != tab.zoomLevel {
            activeWebView.pageZoom = tab.zoomLevel
        }

        // Cache-state sync: restore a synced tab's page state into a fresh web
        // view (scroll + history), then skip the plain URL load.
        if activeWebView.url == nil,
           let tab = tabs?.first(where: { $0.id == activeTabId }),
           TabSync.restoreInteractionState(tab, into: activeWebView) {
            context.coordinator.lastRequestedURL = tab.url
            return
        }

        // Load the URL when it changes, deduped against what the web view already
        // shows and what we already requested (no time-based throttle).
        let normalizedURL = Tab.normalizeURLForComparison(url)
        let normalizedWebViewURL = Tab.normalizeURLForComparison(activeWebView.url)
        let normalizedRequestedURL = Tab.normalizeURLForComparison(context.coordinator.lastRequestedURL)

        if let url = url, normalizedURL != normalizedWebViewURL,
           !(activeWebView.isLoading && normalizedURL == normalizedRequestedURL) {
            context.coordinator.lastRequestedURL = url
            activeWebView.load(URLRequest(url: url))
        } else if let url = url, normalizedURL == normalizedWebViewURL {
            context.coordinator.lastRequestedURL = url
        }
    }

    // Fill the proposed space. Without this the representable reports the
    // container's zero intrinsic size and collapses unless a sibling forces the
    // parent's height (iOS 26 / SwiftUI sizing).
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WebViewContainer_iOS, context: Context) -> CGSize? {
        // Fill: unspecified proposals become large so the parent frame clips us to
        // full size (an unspecified→10pt default left the web view invisibly tiny).
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 100_000, height: 100_000))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self, tabManager: tabManager, tabs: tabs)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        var parent: TabWebView
        var tabManager: TabManager?
        var tabs: [Tab]? {
            didSet {
                guard let tabs else { return }
                downloadNavigationHistory.retainOnly(Set(tabs.map(\.id)))
            }
        }
        private var downloadDestinations: [WKDownload: URL] = [:]
        private var downloadTransferIds: [WKDownload: UUID] = [:]
        private var downloadProgressObservers: [WKDownload: NSKeyValueObservation] = [:]
        var lastRequestedURL: URL?
        private var downloadNavigationHistory = DownloadNavigationHistory()
        private var certificateOverrideWebViews: Set<ObjectIdentifier> = []
        private var popupTabs: [ObjectIdentifier: Tab] = [:]

        // Each web view owns a separate redirect chain; background tabs must not
        // trip the active tab's loop threshold.
        private var redirectLoopGuards: [ObjectIdentifier: RedirectLoopGuard] = [:]

        private func shouldBlockRedirect(to url: URL, in webView: WKWebView) -> Bool {
            let key = ObjectIdentifier(webView)
            var guardrail = redirectLoopGuards[key] ?? RedirectLoopGuard()
            let shouldBlock = guardrail.shouldBlock(url)
            redirectLoopGuards[key] = guardrail
            return shouldBlock
        }

        private func resetRedirectLoopGuard(for webView: WKWebView) {
            redirectLoopGuards.removeValue(forKey: ObjectIdentifier(webView))
        }

        init(_ parent: TabWebView, tabManager: TabManager?, tabs: [Tab]?) {
            self.parent = parent
            self.tabManager = tabManager
            self.tabs = tabs
        }

        // All web views share this coordinator, so "the active tab" is wrong for
        // background loads — resolve the owning tab from the web view.
        private func tab(for webView: WKWebView) -> Tab? {
            guard let tabId = parent.webViewManager?.tabId(for: webView) else { return nil }
            return tabs?.first(where: { $0.id == tabId })
        }

        private func isActiveWebView(_ webView: WKWebView) -> Bool {
            webView === parent.webViewManager?.activeWebView
        }

        // MARK: - Navigation

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            certificateOverrideWebViews.remove(ObjectIdentifier(webView))
            tab(for: webView)?.securityLevel = .none
            if isActiveWebView(webView) {
                parent.isLoading = true
                parent.hasRenderedContent = false
                parent.progressValue = 0.0
            }
            if let url = webView.url {
                if isActiveWebView(webView) { lastRequestedURL = url }
                // Sync the tab's URL as the web view starts navigating, or a link
                // click triggers a view update while the tab still holds the old
                // URL and updateUIView re-loads it — "refreshing" instead of navigating.
                if let tab = tab(for: webView),
                   Tab.normalizeURLForComparison(tab.url) != Tab.normalizeURLForComparison(url) {
                    tab.url = url
                }
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // Push the spacebar-scroll percentage into the new page; the injected
            // user script reads it on each keypress.
            let pct = UserDefaults.standard.object(forKey: "spaceScrollPercent") as? Double ?? 90
            webView.evaluateJavaScript("window.__subSpacePct = \(pct)")
            if let tab = tab(for: webView) {
                parent.fastForward?.pageCommitted(webView: webView, tab: tab)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if isActiveWebView(webView) {
                parent.isLoading = false
                parent.hasRenderedContent = true
                parent.canGoBack = webView.canGoBack
                parent.canGoForward = webView.canGoForward
                parent.title = webView.title ?? ""
            }

            if let url = webView.url,
               let tabId = parent.webViewManager?.tabId(for: webView) {
                downloadNavigationHistory.recordSuccessfulLoad(url, for: tabId)
            }
            resetRedirectLoopGuard(for: webView)

            if let currentURL = webView.url, let tab = tab(for: webView) {
                parent.webViewManager?.setMuted(tab.isMuted, for: tab.id)
                tab.securityLevel = PageSecurityEvaluator.level(
                    for: currentURL,
                    hasOnlySecureContent: webView.hasOnlySecureContent,
                    certificateWasOverridden: certificateOverrideWebViews.contains(ObjectIdentifier(webView))
                )
                if Tab.normalizeURLForComparison(tab.url) != Tab.normalizeURLForComparison(currentURL) {
                    tab.url = currentURL
                }
                // Record the visit for omnibar suggestions; WKWebView owns back/forward.
                if tab.historyStrings.last != currentURL.absoluteString {
                    tab.historyStrings.append(currentURL.absoluteString)
                    let maxHistorySize = SettingsManager.shared.maxHistorySize
                    if tab.historyStrings.count > maxHistorySize {
                        tab.historyStrings.removeFirst(tab.historyStrings.count - maxHistorySize)
                    }
                }
                if tab.sessionKind != .incognito {
                    SiteHistory.shared.record(url: currentURL, title: webView.title)
                }
                BrowsingHistoryStore.shared.record(
                    url: currentURL,
                    title: webView.title,
                    sessionKind: tab.sessionKind
                )
                parent.onURLChange?(currentURL)
            }

            loadFavicon(for: webView)
            parent.onPageFinished?(webView)
            if let tab = tab(for: webView) {
                parent.fastForward?.pageFinished(webView: webView, tab: tab)
                TabSync.captureCacheState(from: webView, into: tab)
            }
            webView.scrollView.refreshControl?.endRefreshing()

            DispatchQueue.main.async {
                webView.allowsBackForwardNavigationGestures = true
                webView.allowsLinkPreview = true
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            webView.scrollView.refreshControl?.endRefreshing()
            Logger.log("WebView navigation failed: \(error.localizedDescription)", type: "WebView")
            lastRequestedURL = nil
            if (error as NSError).code != NSURLErrorCancelled {
                resetRedirectLoopGuard(for: webView)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            webView.scrollView.refreshControl?.endRefreshing()
            Logger.log("WebView provisional navigation failed: \(error.localizedDescription)", type: "WebView")
            lastRequestedURL = nil
            if (error as NSError).code != NSURLErrorCancelled {
                resetRedirectLoopGuard(for: webView)
            }
        }

        // MARK: - Favicon

        private func loadFavicon(for webView: WKWebView) {
            // Every declared icon, in document order, then /favicon.ico. iOS needs
            // the list, not just the first hit: UIImage can't decode SVG, so an
            // svg-first site has to fall through to a PNG/ICO candidate.
            let faviconScript = """
            (function() {
                var rels = ['icon', 'shortcut icon', 'apple-touch-icon', 'apple-touch-icon-precomposed'];
                var links = document.getElementsByTagName('link');
                var hrefs = [];
                for (var i = 0; i < links.length; i++) {
                    var link = links[i];
                    if (!link.rel || !link.href) { continue; }
                    var linkRel = link.rel.toLowerCase();
                    for (var j = 0; j < rels.length; j++) {
                        if (linkRel.indexOf(rels[j]) !== -1) { hrefs.push(link.href); break; }
                    }
                }
                hrefs.push(window.location.origin + '/favicon.ico');
                return hrefs;
            })();
            """
            webView.evaluateJavaScript(faviconScript) { [weak self] result, _ in
                guard let self = self else { return }
                let base = webView.url
                let candidates = (result as? [String] ?? []).compactMap {
                    URL(string: $0, relativeTo: base)?.absoluteURL
                }
                self.downloadFavicon(candidates: candidates, webView: webView)
            }
        }

        private func downloadFavicon(candidates: [URL], webView: WKWebView) {
            guard let tab = tab(for: webView) else { return }
            let scope = FaviconCacheScope.forTab(tab)
            for url in candidates {
                if let cachedData = FaviconCache.shared.getFavicon(for: url, scope: scope) {
                    setFavicon(cachedData, for: webView)
                    return
                }
            }

            let expectedPageURL = webView.url
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                for url in candidates {
                    guard webView.url == expectedPageURL else { return }
                    guard let data = await FaviconLoadingPolicy.load(from: url, in: webView),
                          UIImage(data: data) != nil else { continue }
                    _ = FaviconCache.shared.setFavicon(data, for: url, scope: scope)
                    self.setFavicon(data, for: webView)
                    return
                }
                // Nothing decodable: clear it, or the row keeps showing the
                // previous page's icon. The SwiftUI tab row draws the letter
                // avatar when favicon is nil (replaces DomainInitialsGenerator).
                guard webView.url == expectedPageURL else { return }
                self.setFavicon(nil, for: webView)
            }
        }

        private func setFavicon(_ data: Data?, for webView: WKWebView) {
            DispatchQueue.main.async { self.tab(for: webView)?.favicon = data }
        }

        nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
            let transfer = MainActorKVOChange(object: object, change: change)
            Task { @MainActor in
                if keyPath == "estimatedProgress", let webView = transfer.object as? WKWebView {
                    self.parent.progressValue = webView.estimatedProgress
                } else if keyPath == #keyPath(WKWebView.url), let webView = transfer.object as? WKWebView {
                    // The page rewrote its own URL (pushState/replaceState/hash) — no
                    // delegate callback fires. Sync the tab, or the next view update
                    // sees tab != web view and re-loads the stale URL.
                    guard let newURL = webView.url else { return }
                    if self.isActiveWebView(webView) { self.lastRequestedURL = newURL }
                    if let tab = self.tab(for: webView),
                       Tab.normalizeURLForComparison(tab.url) != Tab.normalizeURLForComparison(newURL) {
                        tab.url = newURL
                    }
                }
            }
        }

        // MARK: - SSL

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let serverTrust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            let host = challenge.protectionSpace.host
            let policy = SecPolicyCreateSSL(true, host as CFString)
            SecTrustSetPolicies(serverTrust, policy)
            let valid = SecTrustEvaluateWithError(serverTrust, nil)

            if valid {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }

            tab(for: webView)?.securityLevel = .insecure
            // Strict SSL (settings toggle, default on): refuse invalid certs outright.
            let strict = UserDefaults.standard.object(forKey: "sslStrictMode") == nil
                || UserDefaults.standard.bool(forKey: "sslStrictMode")
            if strict {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            showSSLErrorDialog(for: host) { proceed in
                if proceed {
                    self.certificateOverrideWebViews.insert(ObjectIdentifier(webView))
                    completionHandler(.useCredential, URLCredential(trust: serverTrust))
                } else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            }
        }

        private func showSSLErrorDialog(for host: String, completion: @escaping (Bool) -> Void) {
            DispatchQueue.main.async {
                guard let presenter = self.topPresenter() else { completion(false); return }
                let alert = UIAlertController(
                    title: String(localized: "SSL Certificate Warning"),
                    message: String(localized: "The certificate for \(host) could not be verified. This may indicate a security risk. Do you want to proceed anyway?"),
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in completion(false) })
                alert.addAction(UIAlertAction(title: String(localized: "Proceed"), style: .destructive) { _ in completion(true) })
                presenter.present(alert, animated: true)
            }
        }

        // MARK: - Navigation policy (downloads, ⌘/⌥-click, JS toggle)

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download, preferences)
                return
            }

            // Keyboard/trackpad modifier clicks need iOS 18.4+; older iOS just
            // navigates normally.
            if #available(iOS 18.4, *),
               navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                let mods = navigationAction.modifierFlags
                // ⌘-click: open in a new tab; add Shift to focus it.
                if mods.contains(.command) {
                    let context = parent.webViewManager?.tabId(for: webView)
                        .flatMap { id in tabs?.first(where: { $0.id == id })?.browsingContext }
                        ?? .normalWebKit
                    _ = tabManager?.createTab(
                        inheriting: context,
                        url: url,
                        select: mods.contains(.shift)
                    )
                    decisionHandler(.cancel, preferences)
                    return
                }
                // ⌥-click: download the link target (settings-gated).
                if mods.contains(.alternate), SettingsManager.shared.optionClickShouldDownload(url, isImage: false) {
                    decisionHandler(.download, preferences)
                    return
                }
            }

            // JS on/off per navigation (unset means enabled) — the path WebKit
            // reliably honors.
            preferences.allowsContentJavaScript =
                UserDefaults.standard.object(forKey: "javaScriptEnabled") == nil
                || UserDefaults.standard.bool(forKey: "javaScriptEnabled")

            if navigationAction.navigationType != .other {
                resetRedirectLoopGuard(for: webView)
            }
            if let url = navigationAction.request.url,
               shouldBlockRedirect(to: url, in: webView) {
                Logger.log("WebView iOS: Cancelled redirect loop at \(url.absoluteString)", type: "WebView")
                if isActiveWebView(webView) {
                    parent.isLoading = false
                }
                decisionHandler(.cancel, preferences)
                return
            }

            decisionHandler(.allow, preferences)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
            // Anything WebKit can't render inline (zip, attachments…) is a download.
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
        }

        // MARK: - Downloads

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            track(download, from: webView)
            resetTabURLAfterDownload(webView)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            track(download, from: webView)
            resetTabURLAfterDownload(webView)
        }

        private func track(_ download: WKDownload, from webView: WKWebView) {
            download.delegate = self
            let owningTab = tab(for: webView)
            let transferId = DownloadManager.shared.beginDownload(
                tabId: owningTab?.id ?? UUID(),
                source: download.originalRequest?.url,
                privacy: owningTab?.sessionKind == .incognito
                    ? .privateSession
                    : .standard
            )
            downloadTransferIds[download] = transferId
            downloadProgressObservers[download] = download.progress.observe(
                \.fractionCompleted,
                options: [.initial, .new]
            ) { _, change in
                guard let progress = change.newValue else { return }
                Task { @MainActor in
                    DownloadManager.shared.update(
                        transferId,
                        progress: progress
                    )
                }
            }
        }

        // A download is not a navigation. If the tab's URL points at the file,
        // snap it back to the last real page — otherwise updateUIView re-requests
        // the file on every view update, downloading it forever.
        private func resetTabURLAfterDownload(_ webView: WKWebView) {
            guard let owningTab = tab(for: webView) else { return }
            let restorationURL = downloadNavigationHistory.restorationURL(for: owningTab.id)
            if isActiveWebView(webView) {
                parent.isLoading = false
                lastRequestedURL = restorationURL
            }
            if Tab.normalizeURLForComparison(owningTab.url) != Tab.normalizeURLForComparison(restorationURL) {
                owningTab.url = restorationURL
            }
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
            // iPad sandbox: downloads land in Documents/Downloads (the only writable
            // spot). The macOS `downloadsFolder` setting has no iPad equivalent.
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let folder = docs.appendingPathComponent("Downloads", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: folder,
                    withIntermediateDirectories: true
                )
            } catch {
                if let transferId = downloadTransferIds[download] {
                    DownloadManager.shared.markFailed(
                        transferId,
                        error: error,
                        canRestart: false
                    )
                }
                cleanup(download)
                completionHandler(nil)
                return
            }

            var destination = folder.appendingPathComponent(suggestedFilename)
            let base = destination.deletingPathExtension().lastPathComponent
            let ext = destination.pathExtension
            var counter = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
                destination = folder.appendingPathComponent(name)
                counter += 1
            }
            downloadDestinations[download] = destination
            if let transferId = downloadTransferIds[download] {
                DownloadManager.shared.setDestination(
                    transferId,
                    url: destination,
                    suggestedFilename: suggestedFilename
                )
            }
            completionHandler(destination)
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let url = downloadDestinations[download],
                  let transferId = downloadTransferIds[download] else {
                cleanup(download)
                return
            }
            DownloadManager.shared.finish(transferId, at: url)
            cleanup(download)
            DispatchQueue.main.async {
                guard let presenter = self.topPresenter() else { return }
                let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                av.popoverPresentationController?.sourceView = presenter.view
                av.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 44, width: 1, height: 1)
                presenter.present(av, animated: true)
            }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            Logger.log("Download failed: \(error.localizedDescription)", type: "WebView")
            if let transferId = downloadTransferIds[download] {
                DownloadManager.shared.markFailed(
                    transferId,
                    error: error,
                    canRestart: false
                )
            }
            cleanup(download)
        }

        private func cleanup(_ download: WKDownload) {
            downloadProgressObservers.removeValue(forKey: download)?.invalidate()
            downloadTransferIds.removeValue(forKey: download)
            downloadDestinations.removeValue(forKey: download)
        }

        // MARK: - Popups (window.open / target="_blank" → new tab)

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let tabManager = tabManager, let webViewManager = parent.webViewManager else { return nil }
            let popupWebView = WKWebView(frame: .zero, configuration: configuration)
            let openerContext = webViewManager.tabId(for: webView)
                .flatMap { id in tabs?.first(where: { $0.id == id })?.browsingContext }
                ?? .normalWebKit
            let isPopup = navigationAction.navigationType != .linkActivated
            let newTab = tabManager.createTab(
                inheriting: openerContext,
                select: !isPopup
            )
            webViewManager.adoptWebView(
                popupWebView,
                for: newTab.id,
                navigationDelegate: self,
                uiDelegate: self
            )
            popupTabs[ObjectIdentifier(popupWebView)] = newTab
            // JavaScript popups (OAuth/payment flows) stay visible beside their
            // opener on iPad. A normal target=_blank link is a foreground tab.
            // iPhone intentionally remains single-pane.
            if isPopup {
                if UIDevice.current.userInterfaceIdiom == .pad,
                   tabManager.splitTabIds.count < TabManager.maxSplitTabs {
                    tabManager.toggleSplitMembership(newTab, tabs: tabs ?? [])
                } else {
                    tabManager.selectedTabId = newTab.id
                }
            }
            return popupWebView
        }

        func webViewDidClose(_ webView: WKWebView) {
            let popupTab = popupTabs.removeValue(
                forKey: ObjectIdentifier(webView)
            )
            guard let tabManager,
                  let id = parent.webViewManager?.tabId(for: webView),
                  let tab = popupTab
                    ?? (tabs ?? []).first(where: { $0.id == id })
                    ?? tabManager.incognitoTabs.first(where: { $0.id == id })
            else { return }
            // The page closed itself; the user did not reject the source.
            tabManager.closeTab(tab, tabs: tabs ?? [], reason: .housekeeping)
        }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
            let originKey = SitePermissionOrigin.canonical(origin)
            let kinds = type.sitePermissionKinds
            if let stored = SitePermissionStore.shared.decision(
                for: kinds,
                origin: originKey
            ) {
                decisionHandler(stored.webKitDecision)
                return
            }

            guard let presenter = topPresenter() else {
                decisionHandler(.deny)
                return
            }
            let owningTab = tab(for: webView)
            let isPrivate = owningTab?.sessionKind == .incognito
            let capabilities = kinds
                .sorted { $0.rawValue < $1.rawValue }
                .map(\.title)
                .joined(separator: String(localized: " and "))
                .lowercased()
            let message = isPrivate
                ? String(localized: "This choice applies only to this private session.")
                : String(localized: "You can revoke this choice in Privacy settings.")
            let alert = UIAlertController(
                title: String(
                    localized: "Allow \(originKey) to use \(capabilities)?"
                ),
                message: message,
                preferredStyle: .alert
            )
            alert.addAction(
                UIAlertAction(
                    title: String(localized: "Block"),
                    style: .cancel
                ) { _ in
                    if !isPrivate {
                        SitePermissionStore.shared.set(
                            .denied,
                            for: kinds,
                            origin: originKey
                        )
                    }
                    decisionHandler(.deny)
                }
            )
            alert.addAction(
                UIAlertAction(
                    title: String(localized: "Allow"),
                    style: .default
                ) { _ in
                    if !isPrivate {
                        SitePermissionStore.shared.set(
                            .allowed,
                            for: kinds,
                            origin: originKey
                        )
                    }
                    decisionHandler(.grant)
                }
            )
            presenter.present(alert, animated: true)
        }

        // MARK: - JS dialogs (file uploads use WKWebView's native iOS picker)

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
            guard let presenter = topPresenter() else { completionHandler(); return }
            let alert = UIAlertController(title: frame.request.url?.host ?? String(localized: "This page"), message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in completionHandler() })
            presenter.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
            guard let presenter = topPresenter() else { completionHandler(false); return }
            let alert = UIAlertController(title: frame.request.url?.host ?? String(localized: "This page"), message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in completionHandler(true) })
            presenter.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
            guard let presenter = topPresenter() else { completionHandler(nil); return }
            let alert = UIAlertController(title: frame.request.url?.host ?? String(localized: "This page"), message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { [weak alert] _ in
                completionHandler(alert?.textFields?.first?.text)
            })
            presenter.present(alert, animated: true)
        }

        // The frontmost view controller to present alerts / share sheets from.
        private func topPresenter() -> UIViewController? {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let keyWindow = scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow })
                ?? scenes.first?.windows.first
            var top = keyWindow?.rootViewController
            while let presented = top?.presentedViewController { top = presented }
            return top
        }
    }
}

// UIKit twin of WebViewContainer: shows the active tab's WKWebView and hides the
// rest. The web views themselves are owned and reused by WebViewManager.
final class WebViewContainer_iOS: UIView {
    private var webViewManager: WebViewManager?
    private weak var coordinator: TabWebView.Coordinator?
    private var activeTabId: UUID?
    // Pane views in splitTabIds order: WKWebViews and (iPad, ADR 0008)
    // document pane views alike.
    private var visiblePanes: [UIView] = []
    var documentPaneProvider: ((UUID) -> UIView?)?
    // id of each displayed document pane view, for tap-to-focus.
    private var documentPaneIds: [UIView: UUID] = [:]

    var activeWebView: WKWebView? {
        if let activeTabId = activeTabId, let webViewManager = webViewManager {
            return webViewManager.getWebView(for: activeTabId)
        }
        return webViewManager?.activeWebView
    }

    init(webViewManager: WebViewManager?, coordinator: TabWebView.Coordinator?) {
        self.webViewManager = webViewManager
        self.coordinator = coordinator
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setDisplayedTabs(activeTabId tabId: UUID?, splitTabIds: [UUID], focusedDocumentId: UUID? = nil) {
        let tabChanged = activeTabId != tabId
        activeTabId = tabId
        webViewManager?.setActiveTab(tabId)

        for pane in visiblePanes { pane.isHidden = true }
        visiblePanes.removeAll()

        let desiredIds = splitTabIds.count >= 2
            ? splitTabIds
            : [tabId].compactMap { $0 }
        guard !desiredIds.isEmpty, let webViewManager else { return }

        // Exactly one pane owns focus: the focused document when there is one,
        // else the active tab (ADR 0008).
        let focusedPaneId = focusedDocumentId ?? tabId
        for desiredId in desiredIds {
            // Documents first — getWebView(for:) with a document id would
            // create an orphan web view as a side effect.
            if let documentView = documentPaneProvider?(desiredId) {
                configureDocumentPane(documentView, id: desiredId)
                documentView.isHidden = false
                documentView.layer.borderWidth = desiredId == focusedPaneId && desiredIds.count > 1 ? 2 : 0
                documentView.layer.borderColor = UIColor.tintColor.cgColor
                visiblePanes.append(documentView)
                continue
            }
            let webView = webViewManager.getWebView(for: desiredId)
            configure(webView)
            webView.isHidden = false
            webView.layer.borderWidth = desiredId == focusedPaneId && desiredIds.count > 1 ? 2 : 0
            webView.layer.borderColor = UIColor.tintColor.cgColor
            visiblePanes.append(webView)
        }

        setNeedsLayout()

        if tabChanged, let tabId, focusedDocumentId == nil,
           let webView = visiblePanes.first(where: { ($0 as? WKWebView).flatMap(webViewManager.tabId(for:)) == tabId }) {
            webView.becomeFirstResponder()
        }
    }

    private func configureDocumentPane(_ view: UIView, id: UUID) {
        documentPaneIds[view] = id
        if view.superview !== self {
            // Tapping anywhere in the pane focuses its document, exactly as
            // tapping a web pane focuses its tab.
            let focusTap = UITapGestureRecognizer(target: self, action: #selector(documentPaneTapped(_:)))
            focusTap.cancelsTouchesInView = false
            focusTap.name = "BrowserPaneFocus"
            view.addGestureRecognizer(focusTap)
            addSubview(view)
        }
    }

    @objc private func documentPaneTapped(_ recognizer: UITapGestureRecognizer) {
        guard let view = recognizer.view, let documentId = documentPaneIds[view] else { return }
        coordinator?.tabManager?.selectDocument(documentId)
    }

    private func configure(_ webView: WKWebView) {

        if webView.superview !== self {
            webView.clipsToBounds = true
            webView.navigationDelegate = coordinator
            webView.uiDelegate = coordinator
            webView.isFindInteractionEnabled = true  // native iOS find bar (⌘F)
            // Pull-to-refresh = reload: the native mobile reload gesture, no chrome.
            // Ended in the coordinator's didFinish/fail callbacks. weak so the
            // control (owned by the scroll view, owned by the web view) can't cycle.
            if webView.scrollView.refreshControl == nil {
                webView.scrollView.refreshControl = UIRefreshControl()
                webView.scrollView.refreshControl?.addAction(
                    UIAction { [weak webView] _ in webView?.reload() }, for: .valueChanged)
            }
            let focusTap = UITapGestureRecognizer(target: self, action: #selector(paneTapped(_:)))
            focusTap.cancelsTouchesInView = false
            focusTap.name = "BrowserPaneFocus"
            webView.addGestureRecognizer(focusTap)
            // Observe real load progress and page-driven URL rewrites (pushState/
            // replaceState/hash) — the only signal for the latter. Removed in
            // willRemoveSubview. The Obj-C keypath is "URL", not "url".
            webView.addObserver(self, forKeyPath: "estimatedProgress", options: .new, context: nil)
            webView.addObserver(self, forKeyPath: #keyPath(WKWebView.url), options: .new, context: nil)
            addSubview(webView)
        }
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // `visiblePanes` is rebuilt in splitTabIds order. UIKit subview
        // insertion order reflects creation history and must not decide pane
        // order after the user reorders a split.
        let panes = visiblePanes.filter { !$0.isHidden && $0.superview === self }
        guard panes.count > 1 else {
            panes.first?.frame = bounds
            return
        }

        if panes.count == 4 {
            let halfWidth = bounds.width / 2
            let halfHeight = bounds.height / 2
            for (index, pane) in panes.enumerated() {
                pane.frame = CGRect(
                    x: index.isMultiple(of: 2) ? 0 : halfWidth,
                    y: index < 2 ? 0 : halfHeight,
                    width: halfWidth,
                    height: halfHeight
                ).insetBy(dx: 1, dy: 1)
            }
        } else if bounds.width >= bounds.height {
            let width = bounds.width / CGFloat(panes.count)
            for (index, pane) in panes.enumerated() {
                pane.frame = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
                    .insetBy(dx: 1, dy: 1)
            }
        } else {
            let height = bounds.height / CGFloat(panes.count)
            for (index, pane) in panes.enumerated() {
                pane.frame = CGRect(x: 0, y: CGFloat(index) * height, width: bounds.width, height: height)
                    .insetBy(dx: 1, dy: 1)
            }
        }
    }

    @objc private func paneTapped(_ recognizer: UITapGestureRecognizer) {
        guard let webView = recognizer.view as? WKWebView,
              let tabId = webViewManager?.tabId(for: webView) else { return }
        coordinator?.tabManager?.selectedTabId = tabId
    }

    override func willRemoveSubview(_ subview: UIView) {
        if let webView = subview as? WKWebView {
            webView.removeObserver(self, forKeyPath: "estimatedProgress")
            webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.url))
        }
        visiblePanes.removeAll { $0 === subview }
        documentPaneIds.removeValue(forKey: subview)
        super.willRemoveSubview(subview)
    }

    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        let transfer = MainActorKVOChange(
            object: object,
            change: change,
            context: context
        )
        Task { @MainActor in
            self.handleObservedValue(forKeyPath: keyPath, transfer: transfer)
        }
    }

    private func handleObservedValue(
        forKeyPath keyPath: String?,
        transfer: MainActorKVOChange
    ) {
        if keyPath == "estimatedProgress" || keyPath == #keyPath(WKWebView.url),
           transfer.object is WKWebView {
            coordinator?.observeValue(
                forKeyPath: keyPath,
                of: transfer.object,
                change: transfer.change,
                context: transfer.context
            )
        } else {
            super.observeValue(
                forKeyPath: keyPath,
                of: transfer.object,
                change: transfer.change,
                context: transfer.context
            )
        }
    }
}
