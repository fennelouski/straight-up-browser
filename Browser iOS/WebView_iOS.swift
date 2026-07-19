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
    var tabs: [Tab]?
    var activeTabId: UUID?
    var onURLChange: ((URL?) -> Void)?

    init(url: Binding<URL?>,
         canGoBack: Binding<Bool>,
         canGoForward: Binding<Bool>,
         title: Binding<String>,
         isLoading: Binding<Bool>,
         progressValue: Binding<Double>,
         hasRenderedContent: Binding<Bool>,
         webViewManager: WebViewManager?,
         tabManager: TabManager?,
         tabs: [Tab]?,
         activeTabId: UUID?,
         onURLChange: ((URL?) -> Void)?) {
        self._url = url
        self._canGoBack = canGoBack
        self._canGoForward = canGoForward
        self._title = title
        self._isLoading = isLoading
        self._progressValue = progressValue
        self._hasRenderedContent = hasRenderedContent
        self.webViewManager = webViewManager
        self.tabManager = tabManager
        self.tabs = tabs
        self.activeTabId = activeTabId
        self.onURLChange = onURLChange
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

        uiView.setActiveTab(activeTabId)

        guard let activeWebView = uiView.activeWebView else { return }

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
        var tabs: [Tab]?
        private var downloadDestinations: [WKDownload: URL] = [:]
        var lastRequestedURL: URL?
        var lastSuccessfullyLoadedURL: URL?

        // Redirect loop detection
        private var navigationHistory: [(url: URL, timestamp: Date)] = []
        private let maxNavigationHistorySize = 5
        private let loopDetectionTimeWindow: TimeInterval = 10.0
        private let maxRedirectsInTimeWindow = 3

        private func isRedirectLoop(_ url: URL) -> Bool {
            let now = Date()
            let recentNavigations = navigationHistory.filter { now.timeIntervalSince($0.timestamp) <= loopDetectionTimeWindow }
            let urlCount = recentNavigations.filter { $0.url.absoluteString == url.absoluteString }.count
            return urlCount >= maxRedirectsInTimeWindow
        }

        private func recordNavigation(_ url: URL) {
            navigationHistory.append((url: url, timestamp: Date()))
            if navigationHistory.count > maxNavigationHistorySize {
                navigationHistory.removeFirst()
            }
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
            if let url = webView.url, isRedirectLoop(url) {
                parent.isLoading = false
                return
            }
            if isActiveWebView(webView) {
                parent.isLoading = true
                parent.hasRenderedContent = false
                parent.progressValue = 0.0
            }
            if let url = webView.url {
                if isActiveWebView(webView) { lastRequestedURL = url }
                recordNavigation(url)
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
            if let tab = tab(for: webView) { TabSync.restoreSessionStorage(tab, into: webView) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if isActiveWebView(webView) {
                parent.isLoading = false
                parent.hasRenderedContent = true
                parent.canGoBack = webView.canGoBack
                parent.canGoForward = webView.canGoForward
                parent.title = webView.title ?? ""
            }

            if let url = webView.url { lastSuccessfullyLoadedURL = url }
            navigationHistory.removeAll()

            if let currentURL = webView.url, let tab = tab(for: webView) {
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
                parent.onURLChange?(currentURL)
            }

            loadFavicon(for: webView)
            if let tab = tab(for: webView) { TabSync.captureCacheState(from: webView, into: tab) }
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
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            webView.scrollView.refreshControl?.endRefreshing()
            Logger.log("WebView provisional navigation failed: \(error.localizedDescription)", type: "WebView")
            lastRequestedURL = nil
        }

        // MARK: - Favicon

        private func loadFavicon(for webView: WKWebView) {
            let faviconScript = """
            (function() {
                var links = document.getElementsByTagName('link');
                var rels = ['icon', 'shortcut icon', 'apple-touch-icon', 'apple-touch-icon-precomposed'];
                for (var i = 0; i < links.length; i++) {
                    var link = links[i];
                    if (link.rel) {
                        var linkRel = link.rel.toLowerCase();
                        for (var j = 0; j < rels.length; j++) {
                            if (linkRel.indexOf(rels[j]) !== -1) { return link.href; }
                        }
                    }
                }
                return window.location.origin + '/favicon.ico';
            })();
            """
            webView.evaluateJavaScript(faviconScript) { [weak self] result, _ in
                guard let self = self else { return }
                if let faviconURLString = result as? String,
                   let baseURL = webView.url,
                   let faviconURL = URL(string: faviconURLString, relativeTo: baseURL)?.absoluteURL {
                    self.downloadFavicon(from: faviconURL, webView: webView)
                }
                // No initial-letter image on iPad: the SwiftUI tab row draws the
                // letter avatar when favicon is nil (replaces DomainInitialsGenerator).
            }
        }

        private func downloadFavicon(from url: URL, webView: WKWebView) {
            if let cachedData = FaviconCache.shared.getFavicon(for: url) {
                setFavicon(cachedData, for: webView)
                return
            }
            URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
                guard let self = self else { return }
                if let data = data,
                   let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 200, data.count > 0,
                   UIImage(data: data) != nil {
                    FaviconCache.shared.setFavicon(data, for: url)
                    self.setFavicon(data, for: webView)
                }
            }.resume()
        }

        private func setFavicon(_ data: Data, for webView: WKWebView) {
            DispatchQueue.main.async { self.tab(for: webView)?.favicon = data }
        }

        override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
            if keyPath == "estimatedProgress", let webView = object as? WKWebView {
                DispatchQueue.main.async { self.parent.progressValue = webView.estimatedProgress }
            } else if keyPath == #keyPath(WKWebView.url), let webView = object as? WKWebView {
                // The page rewrote its own URL (pushState/replaceState/hash) — no
                // delegate callback fires. Sync the tab, or the next view update
                // sees tab != web view and re-loads the stale URL.
                guard let newURL = webView.url else { return }
                DispatchQueue.main.async {
                    if self.isActiveWebView(webView) { self.lastRequestedURL = newURL }
                    if let tab = self.tab(for: webView),
                       Tab.normalizeURLForComparison(tab.url) != Tab.normalizeURLForComparison(newURL) {
                        tab.url = newURL
                    }
                }
            }
        }

        // MARK: - SSL

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
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

            // Strict SSL (settings toggle, default on): refuse invalid certs outright.
            let strict = UserDefaults.standard.object(forKey: "sslStrictMode") == nil
                || UserDefaults.standard.bool(forKey: "sslStrictMode")
            if strict {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            showSSLErrorDialog(for: host) { proceed in
                if proceed {
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

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
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
                    _ = tabManager?.createNewTab(url: url, select: mods.contains(.shift))
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
            decisionHandler(.allow, preferences)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            // Anything WebKit can't render inline (zip, attachments…) is a download.
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
        }

        // MARK: - Downloads

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
            resetTabURLAfterDownload(webView)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
            resetTabURLAfterDownload(webView)
        }

        // A download is not a navigation. If the tab's URL points at the file,
        // snap it back to the last real page — otherwise updateUIView re-requests
        // the file on every view update, downloading it forever.
        private func resetTabURLAfterDownload(_ webView: WKWebView) {
            parent.isLoading = false
            lastRequestedURL = lastSuccessfullyLoadedURL
            if let tabManager = tabManager, let tabs = tabs,
               let activeTab = tabManager.getActiveTab(from: tabs),
               Tab.normalizeURLForComparison(activeTab.url) != Tab.normalizeURLForComparison(lastSuccessfullyLoadedURL) {
                activeTab.url = lastSuccessfullyLoadedURL
            }
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            // iPad sandbox: downloads land in Documents/Downloads (the only writable
            // spot). The macOS `downloadsFolder` setting has no iPad equivalent.
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let folder = docs.appendingPathComponent("Downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

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
            completionHandler(destination)
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let url = downloadDestinations.removeValue(forKey: download) else { return }
            // ponytail: a share sheet is the whole downloads UI on iPad (Save to
            // Files / AirDrop reachable from here); a downloads panel is the
            // upgrade path if this grates with multi-file downloads.
            DispatchQueue.main.async {
                guard let presenter = self.topPresenter() else { return }
                let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                av.popoverPresentationController?.sourceView = presenter.view
                av.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 44, width: 1, height: 1)
                presenter.present(av, animated: true)
            }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            downloadDestinations.removeValue(forKey: download)
            Logger.log("Download failed: \(error.localizedDescription)", type: "WebView")
        }

        // MARK: - Popups (window.open / target="_blank" → new tab)

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let tabManager = tabManager, let webViewManager = parent.webViewManager else { return nil }
            let popupWebView = WKWebView(frame: .zero, configuration: configuration)
            let newTab = tabManager.createNewTab()
            webViewManager.adoptWebView(popupWebView, for: newTab.id)
            return popupWebView
        }

        // MARK: - JS dialogs (file uploads use WKWebView's native iOS picker)

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            guard let presenter = topPresenter() else { completionHandler(); return }
            let alert = UIAlertController(title: frame.request.url?.host ?? String(localized: "This page"), message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in completionHandler() })
            presenter.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            guard let presenter = topPresenter() else { completionHandler(false); return }
            let alert = UIAlertController(title: frame.request.url?.host ?? String(localized: "This page"), message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in completionHandler(true) })
            presenter.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
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
    private var visibleWebViews: Set<WKWebView> = []

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

    func setActiveTab(_ tabId: UUID?) {
        let tabChanged = activeTabId != tabId
        activeTabId = tabId
        webViewManager?.setActiveTab(tabId)

        for webView in visibleWebViews { webView.isHidden = true }
        visibleWebViews.removeAll()

        guard let newTabId = tabId, let webViewManager = webViewManager else { return }
        let webView = webViewManager.getWebView(for: newTabId)

        if webView.superview !== self {
            webView.frame = bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
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
            // Observe real load progress and page-driven URL rewrites (pushState/
            // replaceState/hash) — the only signal for the latter. Removed in
            // willRemoveSubview. The Obj-C keypath is "URL", not "url".
            webView.addObserver(self, forKeyPath: "estimatedProgress", options: .new, context: nil)
            webView.addObserver(self, forKeyPath: #keyPath(WKWebView.url), options: .new, context: nil)
            addSubview(webView)
        } else {
            webView.frame = bounds
        }

        webView.isHidden = false
        visibleWebViews.insert(webView)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true

        // Give the page key focus on a real tab change so a hardware keyboard's
        // arrow keys / space scroll it.
        if tabChanged { webView.becomeFirstResponder() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for subview in subviews where subview is WKWebView { subview.frame = bounds }
    }

    override func willRemoveSubview(_ subview: UIView) {
        if let webView = subview as? WKWebView {
            webView.removeObserver(self, forKeyPath: "estimatedProgress")
            webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.url))
            visibleWebViews.remove(webView)
        }
        super.willRemoveSubview(subview)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "estimatedProgress" || keyPath == #keyPath(WKWebView.url), object is WKWebView {
            coordinator?.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
}
