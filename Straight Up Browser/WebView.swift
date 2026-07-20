//
//  WebView.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#endif

#if os(macOS)
struct WebView: NSViewRepresentable {
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
    // Split view: all tabs shown as panes (ordered). Normally just [activeTabId].
    var displayedTabIds: [UUID] = []
    var onURLChange: ((URL?) -> Void)?

    // Trackpad pinch + two-finger double-tap smart zoom. @AppStorage here so
    // flipping the setting re-runs updateNSView and applies it live.
    @AppStorage("pinchToZoomEnabled") private var pinchToZoomEnabled = true

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
         displayedTabIds: [UUID] = [],
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
        self.displayedTabIds = displayedTabIds.isEmpty ? [activeTabId].compactMap { $0 } : displayedTabIds
        self.onURLChange = onURLChange

        Logger.log("WebView init: activeTabId=\(activeTabId?.uuidString ?? "nil")", type: "WebView")
    }

    func makeNSView(context: Context) -> WebViewContainer {
        Logger.log("WebView makeNSView called for activeTabId: \(activeTabId?.uuidString ?? "nil")", type: "WebView")
        return WebViewContainer(webViewManager: webViewManager, coordinator: context.coordinator)
    }

    func updateNSView(_ nsView: WebViewContainer, context: Context) {
        Logger.log("WebView updateNSView: activeTabId=\(activeTabId?.uuidString ?? "nil"), url=\(url?.absoluteString ?? "nil")", type: "WebView")

        // Refresh the coordinator's view of the world. Without this it keeps the
        // struct (and tab list) captured at creation, so its bindings write into
        // a stale snapshot - titles/URLs never landed on tabs created later.
        context.coordinator.parent = self
        context.coordinator.tabs = tabs
        context.coordinator.tabManager = tabManager

        // Update the displayed panes (one pane normally, 2–4 in a split)
        nsView.onPaneFocus = { [tabManager] id in tabManager?.selectedTabId = id }
        nsView.setDisplayedTabs(displayedTabIds, focusedTabId: activeTabId)

        // Non-focused panes never go through the url-binding load path below, so a
        // pane restored at launch would sit blank: load its tab's URL once here.
        for id in displayedTabIds where id != activeTabId {
            guard let paneWebView = webViewManager?.existingWebView(for: id),
                  paneWebView.url == nil, !paneWebView.isLoading,
                  let tab = tabs?.first(where: { $0.id == id }) else { continue }
            if TabSync.restoreInteractionState(tab, into: paneWebView) { continue }
            if let paneURL = tab.url { paneWebView.load(URLRequest(url: paneURL)) }
        }

        // Log the active WebView after the update
        if let activeWebView = nsView.activeWebView {
            Logger.log("WebView updateNSView: activeWebView after update: \(Unmanaged.passUnretained(activeWebView).toOpaque())", type: "WebView")
        } else {
            Logger.log("WebView updateNSView: no activeWebView after update", type: "WebView")
        }

        Logger.log("WebView updateNSView: after setActiveTab, checking activeWebView", type: "WebView")

        // Ensure we have an active web view
        guard let activeWebView = nsView.activeWebView else {
            Logger.log("WebView updateNSView: no active web view available - activeWebView is nil", type: "WebView")
            return
        }

        Logger.log("WebView updateNSView: activeWebView found: \(Unmanaged.passUnretained(activeWebView).toOpaque())", type: "WebView")

        // Reapply the tab's persisted zoom (the zoom menu items write it)
        if let tab = tabs?.first(where: { $0.id == activeTabId }), activeWebView.pageZoom != tab.zoomLevel {
            activeWebView.pageZoom = tab.zoomLevel
        }

        // Pinch / two-finger double-tap smart zoom, live per the setting.
        activeWebView.allowsMagnification = pinchToZoomEnabled

        // Cache-state sync: restore a synced tab's page state into a fresh web view
        // (scroll + history), then skip the plain URL load.
        if activeWebView.url == nil,
           let tab = tabs?.first(where: { $0.id == activeTabId }),
           TabSync.restoreInteractionState(tab, into: activeWebView) {
            context.coordinator.lastRequestedURL = tab.url
            return
        }

        // Load the URL when it changes. Dedupe against what the webview already
        // shows and what we already requested - no time-based throttle, which
        // silently dropped legitimate navigations.
        let normalizedURL = Tab.normalizeURLForComparison(url)
        let normalizedWebViewURL = Tab.normalizeURLForComparison(activeWebView.url)
        let normalizedRequestedURL = Tab.normalizeURLForComparison(context.coordinator.lastRequestedURL)

        // Guard against in-flight navigations that the webview itself kicked off
        // (e.g. the user clicking a link). In that case webView.url/lastRequestedURL
        // race ahead of the SwiftUI `url` binding - which only catches up once
        // didFinish updates activeTab.url - so comparing the *stale* `url` binding
        // against lastRequestedURL here would wrongly conclude "this is a new
        // request" and re-`load()` the old URL, cancelling the link navigation and
        // making it look like the page just refreshed. Compare the webview's live
        // URL instead: if it's already loading toward what we last requested, don't
        // issue a second, stale load.
        if let url = url, normalizedURL != normalizedWebViewURL,
           !(activeWebView.isLoading && normalizedWebViewURL == normalizedRequestedURL) {
            Logger.log("WebView loading URL: \(url.absoluteString) (current: \(activeWebView.url?.absoluteString ?? "nil"))", type: "WebView")
            context.coordinator.lastRequestedURL = url
            activeWebView.load(URLRequest(url: url))
        } else if let url = url, normalizedURL == normalizedWebViewURL {
            // Ensure lastRequestedURL is set correctly
            context.coordinator.lastRequestedURL = url
        }
    }

    func makeCoordinator() -> Coordinator {
        Logger.log("WebView makeCoordinator called", type: "WebView")
        return Coordinator(self, tabManager: tabManager, tabs: tabs)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        var parent: WebView
        var tabManager: TabManager?
        var tabs: [Tab]?
        private var downloadDestinations: [WKDownload: URL] = [:]
        var lastRequestedURL: URL?
        var lastSuccessfullyLoadedURL: URL?

        // Redirect loop detection
        private var navigationHistory: [(url: URL, timestamp: Date)] = []
        private let maxNavigationHistorySize = 5
        private let loopDetectionTimeWindow: TimeInterval = 10.0 // 10 seconds
        private let maxRedirectsInTimeWindow = 3

        private func isRedirectLoop(_ url: URL) -> Bool {
            let now = Date()
            let recentNavigations = navigationHistory.filter { now.timeIntervalSince($0.timestamp) <= loopDetectionTimeWindow }

            // Count how many times this URL has been navigated to recently
            let urlCount = recentNavigations.filter { $0.url.absoluteString == url.absoluteString }.count

            // If we've seen this URL more than maxRedirectsInTimeWindow times in the last loopDetectionTimeWindow seconds, it's a loop
            if urlCount >= maxRedirectsInTimeWindow {
                Logger.log("WebView: Detected redirect loop for URL: \(url.absoluteString) (navigated \(urlCount) times in \(loopDetectionTimeWindow)s)", type: "WebView")
                return true
            }

            return false
        }

        private func recordNavigation(_ url: URL) {
            navigationHistory.append((url: url, timestamp: Date()))

            // Keep only the most recent navigations
            if navigationHistory.count > maxNavigationHistorySize {
                navigationHistory.removeFirst()
            }
        }

        init(_ parent: WebView, tabManager: TabManager?, tabs: [Tab]?) {
            self.parent = parent
            self.tabManager = tabManager
            self.tabs = tabs
        }

        // Resolve which tab a delegate callback belongs to. All webviews share
        // this coordinator, so "the active tab" is wrong for background loads.
        private func tab(for webView: WKWebView) -> Tab? {
            guard let tabId = parent.webViewManager?.tabId(for: webView) else { return nil }
            return tabs?.first(where: { $0.id == tabId })
        }

        private func isActiveWebView(_ webView: WKWebView) -> Bool {
            webView === parent.webViewManager?.activeWebView
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            // Check for redirect loops before starting navigation
            if let url = webView.url, isRedirectLoop(url) {
                Logger.log("WebView didStartProvisionalNavigation: Blocking redirect loop for URL: \(url.absoluteString)", type: "WebView")
                parent.isLoading = false
                return
            }

            if isActiveWebView(webView) {
                parent.isLoading = true
                parent.hasRenderedContent = false
                parent.progressValue = 0.0
            }
            if let url = webView.url {
                Logger.log("WebView didStartProvisionalNavigation: setting lastRequestedURL to \(url.absoluteString)", type: "WebView")
                if isActiveWebView(webView) {
                    lastRequestedURL = url
                }
                recordNavigation(url)

                // Sync the tab's URL as soon as the webview starts navigating.
                // Without this, a link click triggers a view update while the
                // tab still holds the old URL, and updateNSView re-loads the old
                // URL - cancelling the click and "refreshing" the page instead.
                if let tab = tab(for: webView),
                   Tab.normalizeURLForComparison(tab.url) != Tab.normalizeURLForComparison(url) {
                    tab.url = url
                }
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // Push the current spacebar-scroll percentage into the new page;
            // the injected user script reads it on each keypress
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

            // Track the URL that successfully loaded
            if let url = webView.url {
                lastSuccessfullyLoadedURL = url
            }

            // Clear navigation history on successful page load to reset loop detection
            navigationHistory.removeAll()

            if let currentURL = webView.url, let tab = tab(for: webView) {
                if Tab.normalizeURLForComparison(tab.url) != Tab.normalizeURLForComparison(currentURL) {
                    Logger.log("WebView didFinish: updating tab URL to \(currentURL.absoluteString)", type: "WebView")
                    tab.url = currentURL
                }

                // Record the visit for omnibar suggestions; WKWebView owns back/forward
                if tab.historyStrings.last != currentURL.absoluteString {
                    tab.historyStrings.append(currentURL.absoluteString)

                    // Limit history size
                    let maxHistorySize = SettingsManager.shared.maxHistorySize
                    if tab.historyStrings.count > maxHistorySize {
                        tab.historyStrings.removeFirst(tab.historyStrings.count - maxHistorySize)
                    }
                }

                // Notify parent of URL change to update stable URL
                parent.onURLChange?(currentURL)
            }

            // Load favicon for the current page
            loadFavicon(for: webView)
            if let tab = tab(for: webView) { TabSync.captureCacheState(from: webView, into: tab) }

            // Ensure WebView remains interactive after loading
            DispatchQueue.main.async {
                // Re-enable interactions
                webView.allowsBackForwardNavigationGestures = true
                webView.allowsMagnification = SettingsManager.shared.pinchToZoomEnabled
                webView.allowsLinkPreview = true
            }

            // Removed JavaScript injection that may interfere with user interactions
        }

        private func loadFavicon(for webView: WKWebView) {
            // Standard source: <link rel="icon"...>, else /favicon.ico
            let faviconScript = """
            (function() {
                var links = document.getElementsByTagName('link');
                var rels = ['icon', 'shortcut icon', 'apple-touch-icon', 'apple-touch-icon-precomposed'];

                for (var i = 0; i < links.length; i++) {
                    var link = links[i];
                    if (link.rel) {
                        var linkRel = link.rel.toLowerCase();
                        for (var j = 0; j < rels.length; j++) {
                            if (linkRel.indexOf(rels[j]) !== -1) {
                                return link.href;
                            }
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
                } else {
                    self.generateDomainInitial(for: webView)
                }
            }
        }

        // ponytail: no OG/JSON-LD/header-logo scraping tiers; a declared icon,
        // favicon.ico, or the generated domain initial covers real sites
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
                   NSImage(data: data) != nil {
                    FaviconCache.shared.setFavicon(data, for: url)
                    self.setFavicon(data, for: webView)
                } else {
                    DispatchQueue.main.async {
                        self.generateDomainInitial(for: webView)
                    }
                }
            }.resume()
        }

        private func setFavicon(_ data: Data, for webView: WKWebView) {
            DispatchQueue.main.async {
                self.tab(for: webView)?.favicon = data
            }
        }

        private func generateDomainInitial(for webView: WKWebView) {
            guard let url = webView.url, let domain = url.host else { return }

            if let initialImageData = DomainInitialsGenerator.shared.generateInitialImage(for: domain) {
                setFavicon(initialImageData, for: webView)
            }
        }

        override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
            if keyPath == "estimatedProgress", let webView = object as? WKWebView {
                DispatchQueue.main.async {
                    // Only the focused tab drives the chrome progress bar; a
                    // background split pane loading shouldn't wiggle it.
                    if self.isActiveWebView(webView) {
                        self.parent.progressValue = webView.estimatedProgress
                    }
                }
            } else if keyPath == #keyPath(WKWebView.url), let webView = object as? WKWebView {
                // The page changed its own URL (pushState/replaceState/hash) -
                // no delegate callback fires for these. Sync the tab, or the
                // next view update sees tab != webview and re-loads the stale
                // URL: the "page randomly reloads a few seconds after loading"
                // bug. Deliberately leaves lastSuccessfullyLoadedURL alone -
                // the download path needs it pointing at a real page.
                guard let newURL = webView.url else { return }
                DispatchQueue.main.async {
                    if self.isActiveWebView(webView) {
                        self.lastRequestedURL = newURL
                    }
                    if let tab = self.tab(for: webView),
                       Tab.normalizeURLForComparison(tab.url) != Tab.normalizeURLForComparison(newURL) {
                        tab.url = newURL
                    }
                }
            }
        }


        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            Logger.log("WebView navigation failed: \(error.localizedDescription)", type: "WebView")
            Logger.log("Error domain: \(error._domain), code: \((error as NSError).code)", type: "WebView")
            // Reset lastRequestedURL on failure so we can retry
            Logger.log("WebView didFail: resetting lastRequestedURL to nil", type: "WebView")
            lastRequestedURL = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            Logger.log("WebView provisional navigation failed: \(error.localizedDescription)", type: "WebView")
            Logger.log("Error domain: \(error._domain), code: \((error as NSError).code)", type: "WebView")
            if let url = webView.url {
                Logger.log("Failed URL: \(url.absoluteString)", type: "WebView")
            }
            // Reset lastRequestedURL on failure so we can retry
            Logger.log("WebView didFailProvisionalNavigation: resetting lastRequestedURL to nil", type: "WebView")
            lastRequestedURL = nil
        }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // Handle SSL certificate validation
            handleAuthenticationChallenge(challenge, completionHandler: completionHandler)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
            // <a download> links
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download, preferences)
                return
            }

            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                let mods = navigationAction.modifierFlags

                // Cmd+click: open in a new tab (background; add Shift to focus it)
                if mods.contains(.command) {
                    _ = tabManager?.createNewTab(url: url, select: mods.contains(.shift))
                    decisionHandler(.cancel, preferences)
                    return
                }

                // Option+click: download the link target (settings-gated)
                if mods.contains(.option), SettingsManager.shared.optionClickShouldDownload(url, isImage: false) {
                    decisionHandler(.download, preferences)
                    return
                }
            }

            // Settings toggle; unset means enabled. Per-navigation is the path
            // WebKit actually honors - defaultWebpagePreferences on the
            // configuration doesn't reliably stick.
            preferences.allowsContentJavaScript =
                UserDefaults.standard.object(forKey: "javaScriptEnabled") == nil
                || UserDefaults.standard.bool(forKey: "javaScriptEnabled")

            decisionHandler(.allow, preferences)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            // Anything WebKit can't render inline (zip, dmg, attachments…) is a download
            if !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
                return
            }

            decisionHandler(.allow)
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

        // A download is not a navigation. If the tab's URL points at the file
        // (omnibar/CLI navigation straight to a zip), snap it back to the last
        // page that actually loaded - otherwise updateNSView sees tab != webview
        // and re-requests the file on every view update, downloading it forever.
        // Note: webView.url is unusable here - it still holds the provisional
        // (file) URL until the cancelled navigation unwinds.
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
            let configuredPath = UserDefaults.standard.string(forKey: "downloadsFolder") ?? ""
            let folder = configuredPath.isEmpty
                ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                : URL(fileURLWithPath: (configuredPath as NSString).expandingTildeInPath)

            // Dedupe "name.ext" -> "name-2.ext" so WKDownload doesn't fail on collision
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
            Logger.log("Download starting: \(destination.path)", type: "WebView")
            completionHandler(destination)
        }

        func downloadDidFinish(_ download: WKDownload) {
            if let url = downloadDestinations.removeValue(forKey: download) {
                Logger.log("Download finished: \(url.path)", type: "WebView")
                DownloadManager.shared.record(url, kind: .download, source: download.originalRequest?.url)
                // Reveal in Finder is the immediate "it's done" feedback; the
                // browsable history lives in the Downloads window (File ▸ Show Downloads).
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            downloadDestinations.removeValue(forKey: download)
            Logger.log("Download failed: \(error.localizedDescription)", type: "WebView")
        }

        private func handleAuthenticationChallenge(_ challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                // SSL/TLS certificate challenge
                if let serverTrust = challenge.protectionSpace.serverTrust {
                    let host = challenge.protectionSpace.host

                    // Evaluate the certificate
                    let policy = SecPolicyCreateSSL(true, host as CFString)
                    SecTrustSetPolicies(serverTrust, policy)
                    var trustResult: SecTrustResultType = .invalid
                    let evaluationResult = SecTrustEvaluateWithError(serverTrust, nil)
                    if evaluationResult {
                        trustResult = .proceed
                    } else {
                        trustResult = .recoverableTrustFailure
                    }

                    // Display certificate information
                    displaySSLCertificateInfo(serverTrust, for: host)

                    // For now, accept valid certificates automatically
                    // In a production app, you might want more sophisticated validation
                    switch trustResult {
                    case .proceed, .unspecified:
                        // Certificate is valid
                        let credential = URLCredential(trust: serverTrust)
                        completionHandler(.useCredential, credential)
                    default:
                        // Strict SSL (settings toggle, default on): refuse invalid certs outright
                        let strict = UserDefaults.standard.object(forKey: "sslStrictMode") == nil
                            || UserDefaults.standard.bool(forKey: "sslStrictMode")
                        if strict {
                            completionHandler(.cancelAuthenticationChallenge, nil)
                            return
                        }

                        // Certificate is invalid - show warning but allow user to proceed
                        showSSLErrorDialog(for: host, trustResult: trustResult) { shouldProceed in
                            if shouldProceed {
                                let credential = URLCredential(trust: serverTrust)
                                completionHandler(.useCredential, credential)
                            } else {
                                completionHandler(.cancelAuthenticationChallenge, nil)
                            }
                        }
                    }
                } else {
                    completionHandler(.performDefaultHandling, nil)
                }
            } else {
                // Handle other authentication methods (username/password, etc.)
                completionHandler(.performDefaultHandling, nil)
            }
        }

        private func displaySSLCertificateInfo(_ serverTrust: SecTrust, for host: String) {
            // Extract certificate information
            if let certificateChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
               let certificate = certificateChain.first {
                var commonName: CFString?

                // Get certificate details
                if let summary = SecCertificateCopySubjectSummary(certificate) {
                    commonName = summary
                }

                // Display certificate info in console for debugging
                Logger.log("SSL Certificate for \(host):", type: "WebView")
                Logger.log("- Common Name: \(commonName ?? "Unknown" as CFString)", type: "WebView")
                Logger.log("- Valid certificate chain established", type: "WebView")
            }
        }

        private func showSSLErrorDialog(for host: String, trustResult: SecTrustResultType, completion: @escaping (Bool) -> Void) {
            let alert = NSAlert()
            alert.messageText = String(localized: "SSL Certificate Warning")
            alert.informativeText = String(localized: "The certificate for \(host) could not be verified.\n\nTrust Result: \(trustResultDescription(trustResult))\n\nThis may indicate a security risk. Do you want to proceed anyway?")

            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "Proceed"))
            alert.addButton(withTitle: String(localized: "Cancel"))

            DispatchQueue.main.async {
                let response = alert.runModal()
                completion(response == .alertFirstButtonReturn)
            }
        }

        private func trustResultDescription(_ result: SecTrustResultType) -> String {
            switch result {
            case .proceed: return "Valid"
            case .unspecified: return "Valid (unspecified)"
            case .deny: return "Denied by user"
            case .fatalTrustFailure: return "Fatal trust failure"
            case .otherError: return "Other error"
            case .recoverableTrustFailure: return "Recoverable trust failure"
            case .invalid: return "Invalid"
            @unknown default: return "Unknown"
            }
        }

        // window.open() / target="_blank": hand WebKit a real WKWebView built from
        // its configuration so window.opener works (OAuth popup flows), displayed
        // as a new tab. Non-user-gesture popups are already blocked by
        // javaScriptCanOpenWindowsAutomatically = false, so no custom heuristics.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let tabManager = tabManager, let webViewManager = parent.webViewManager else { return nil }

            // WebKit drives the load; the tab's URL/title land via the navigation
            // delegate once the popup web view becomes the active subview.
            // WebKit built the popup from the opener's configuration, so it already
            // shares the opener's data store — keep the tab in the same session too, so
            // an incognito/container popup doesn't leak out into a normal persisted tab.
            let popupWebView = WKWebView(frame: .zero, configuration: configuration)
            let openerSession = webViewManager.tabId(for: webView).map { webViewManager.session(for: $0) } ?? (.normal, nil)
            // Create it unselected: a popup joins the opener in a split rather than
            // replacing it. A popup that hides the page that opened it (OAuth consent,
            // a payment sheet) reads as "nothing happened" — the opener is what gives
            // the popup its meaning, so both stay on screen.
            let newTab = tabManager.createTab(inheriting: openerSession, select: false)
            webViewManager.adoptWebView(popupWebView, for: newTab.id)
            // ponytail: pairs with the *focused* tab, which is the opener in every case
            // except a popup fired from a background pane — rare enough not to track
            // opener identity for. At the 4-pane cap there's no room, so just focus it.
            if tabManager.splitTabIds.count < TabManager.maxSplitTabs {
                tabManager.toggleSplitMembership(newTab, tabs: tabs ?? [])
            } else {
                tabManager.selectedTabId = newTab.id
            }
            return popupWebView
        }

        // window.close() from a popup: take its pane down with it. OAuth and payment
        // popups close themselves once they've handed control back to the opener, and
        // without this the finished popup just sits there as a dead pane.
        func webViewDidClose(_ webView: WKWebView) {
            guard let tabManager,
                  let id = parent.webViewManager?.tabId(for: webView),
                  let tab = (tabs ?? []).first(where: { $0.id == id })
                    ?? tabManager.incognitoTabs.first(where: { $0.id == id })
            else { return }
            tabManager.closeTab(tab, tabs: tabs ?? [])
        }

        // WebKit's native right-click menu offers "Open Link in New Window" -
        // we don't support multiple windows, and createWebViewWith above
        // actually opens that link in a new tab. Relabel the item so it says
        // what it does instead of advertising a window we never open.
        func webView(_ webView: WKWebView, willOpenMenu menu: NSMenu, with event: NSEvent) {
            for item in menu.items where item.title == "Open Link in New Window" {
                item.title = "Open Link in New Tab"
            }
        }

        // MARK: - JS dialogs and file uploads

        private func presentSheet(_ alert: NSAlert, over webView: WKWebView, completion: @escaping (NSApplication.ModalResponse) -> Void) {
            if let window = webView.window {
                alert.beginSheetModal(for: window, completionHandler: completion)
            } else {
                completion(alert.runModal())
            }
        }

        private func makeDialogAlert(message: String, frame: WKFrameInfo) -> NSAlert {
            let alert = NSAlert()
            alert.messageText = frame.request.url?.host ?? String(localized: "This page")
            alert.informativeText = message
            return alert
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = makeDialogAlert(message: message, frame: frame)
            alert.addButton(withTitle: String(localized: "OK"))
            presentSheet(alert, over: webView) { _ in completionHandler() }
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = makeDialogAlert(message: message, frame: frame)
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            presentSheet(alert, over: webView) { completionHandler($0 == .alertFirstButtonReturn) }
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            let alert = makeDialogAlert(message: prompt, frame: frame)
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            input.stringValue = defaultText ?? ""
            alert.accessoryView = input
            alert.window.initialFirstResponder = input
            presentSheet(alert, over: webView) { completionHandler($0 == .alertFirstButtonReturn ? input.stringValue : nil) }
        }

        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            let site = webView.url
            let finish: (NSApplication.ModalResponse) -> Void = { response in
                let urls = response == .OK ? panel.urls : nil
                urls?.forEach { DownloadManager.shared.record($0, kind: .upload, source: site) }
                completionHandler(urls)
            }
            if let window = webView.window {
                panel.beginSheetModal(for: window, completionHandler: finish)
            } else {
                finish(panel.runModal())
            }
        }
    }

}

class WebViewContainer: NSView {
    private var webViewManager: WebViewManager?
    private weak var coordinator: WebView.Coordinator?
    private var focusedTabId: UUID?
    private var displayedTabIds: [UUID] = []
    private var visibleWebViews: Set<WKWebView> = []

    // Split pane geometry. colFractions are per-column width fractions for 2–3
    // panes; for the 2×2 grid it's [leftColumnFraction] plus rowFraction (top row).
    // Reset to equal whenever membership changes; deliberately not persisted.
    private var colFractions: [CGFloat] = []
    private var rowFraction: CGFloat = 0.5
    private var dividers: [PaneDivider] = []
    private var clickMonitor: Any?
    // Clicking inside a non-focused pane moves focus there (sets selectedTabId).
    var onPaneFocus: ((UUID) -> Void)?

    var activeWebView: WKWebView? {
        // The WebView for the focused tab, not necessarily the manager's
        // activeWebView. Reads through pendingDisplay: setDisplayedTabs applies a
        // runloop hop late, but updateNSView reads this back inside the same pass
        // to pick which web view to load the tab's URL into. Answering with the
        // *previous* focus there loaded the newly selected tab's page into the
        // old tab's web view — the "tabs showing each other's pages" bug.
        if let focusedTabId = pendingDisplay?.focused ?? focusedTabId, let webViewManager = webViewManager {
            return webViewManager.getWebView(for: focusedTabId)
        }
        return webViewManager?.activeWebView
    }

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func becomeFirstResponder() -> Bool {
        // Try to make the active WebView the first responder
        if let activeWebView = activeWebView {
            return activeWebView.becomeFirstResponder()
        }
        return super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        Logger.log("WebViewContainer mouseDown received", type: "WebView")
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        Logger.log("WebViewContainer keyDown received", type: "WebView")
        super.keyDown(with: event)
    }

    init(webViewManager: WebViewManager?, coordinator: WebView.Coordinator?) {
        self.webViewManager = webViewManager
        self.coordinator = coordinator
        super.init(frame: .zero)

        // Set up the container
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
        self.layer?.masksToBounds = true // Ensure subviews are clipped to bounds
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // SwiftUI calls updateNSView for any state change, most of which leave the
    // panes alone — so bail unless something actually moved, then apply one
    // runloop hop later. Every isHidden write below makes AppKit recompute the
    // key-view loop, and that walk re-enters SwiftUI's focus machinery; doing it
    // *inside* the update pass is a fatal Swift access conflict ("Simultaneous
    // accesses to ... FocusableViewResponder.frame"). A link handed to us by
    // another app hit it every time: the new tab changed the panes while the
    // window was taking focus. Off the pass, the walk finds the graph idle.
    // Coalesced, so a burst of updates still applies only the final state.
    func setDisplayedTabs(_ ids: [UUID], focusedTabId: UUID?) {
        // Compare against what's *pending* when there is one, not what's applied:
        // a burst of updates that dips back through the applied state would
        // otherwise early-return and strand the newer request in pendingDisplay,
        // leaving the panes on a tab nobody selected.
        let current = pendingDisplay ?? (displayedTabIds, self.focusedTabId)
        guard current.ids != ids || current.focused != focusedTabId else { return }
        let alreadyScheduled = pendingDisplay != nil
        pendingDisplay = (ids, focusedTabId)
        guard !alreadyScheduled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let pending = self.pendingDisplay else { return }
            self.pendingDisplay = nil
            self.applyDisplayedTabs(pending.ids, focusedTabId: pending.focused)
        }
    }

    private var pendingDisplay: (ids: [UUID], focused: UUID?)?

    private func applyDisplayedTabs(_ ids: [UUID], focusedTabId: UUID?) {
        Logger.log("WebViewContainer setDisplayedTabs: \(ids.count) pane(s), focused \(focusedTabId?.uuidString ?? "nil")", type: "WebView")

        let tabChanged = self.focusedTabId != focusedTabId
        if displayedTabIds != ids {
            displayedTabIds = ids
            resetFractions()
        }
        self.focusedTabId = focusedTabId

        // Update the WebViewManager's active tab (the focused pane)
        webViewManager?.setActiveTab(focusedTabId)

        // Hide all currently visible web views
        for webView in visibleWebViews {
            webView.isHidden = true
        }
        visibleWebViews.removeAll()

        guard !ids.isEmpty, let webViewManager = webViewManager else {
            Logger.log("WebViewContainer setDisplayedTabs: no tabs or webViewManager", type: "WebView")
            return
        }

        for id in ids {
            let webView = webViewManager.getWebView(for: id)
            attach(webView)
            webView.isHidden = false
            visibleWebViews.insert(webView)

            // Ensure WebView can accept user interactions
            webView.allowsBackForwardNavigationGestures = true
            webView.allowsMagnification = SettingsManager.shared.pinchToZoomEnabled
            webView.allowsLinkPreview = true

            // Subtle accent border marks the focused pane — only while split
            webView.layer?.borderWidth = (ids.count > 1 && id == focusedTabId) ? 2 : 0
            webView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }

        layoutPanes()

        // Give the page key focus so arrow keys / space / cmd+arrows scroll
        // it. Only on a real tab change (or when nothing has focus) so
        // routine SwiftUI updates don't steal focus from the omnibar.
        if let focusedTabId, let window = self.window, tabChanged || window.firstResponder === window {
            window.makeFirstResponder(webViewManager.getWebView(for: focusedTabId))
        }
    }

    // The one-time setup for a webview joining this container (delegates + KVO,
    // balanced in willRemoveSubview). Frames are owned by layoutPanes.
    private func attach(_ webView: WKWebView) {
        guard webView.superview !== self else { return }
        webView.autoresizingMask = []
        webView.wantsLayer = true
        webView.layer?.masksToBounds = true

        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator

        // Observe real load progress; removed in willRemoveSubview
        webView.addObserver(self, forKeyPath: "estimatedProgress", options: .new, context: nil)

        // Observe the page rewriting its own URL (history.pushState/
        // replaceState, hash jumps) - none of those fire a navigation
        // delegate callback, so this is the only signal. The Obj-C
        // keypath is "URL", not "url" - #keyPath gets it right.
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.url), options: .new, context: nil)

        self.addSubview(webView)
    }

    // MARK: - Pane layout

    private func resetFractions() {
        let count = displayedTabIds.count
        colFractions = count == 4 ? [0.5] : Array(repeating: 1.0 / CGFloat(max(count, 1)), count: max(count, 1))
        rowFraction = 0.5
    }

    private func layoutPanes() {
        guard let webViewManager = webViewManager, !displayedTabIds.isEmpty else { return }
        let views = displayedTabIds.map { webViewManager.getWebView(for: $0) }
        let b = bounds

        if views.count == 4 {
            // Rigid 2×2 grid in reading order: dividers span the full grid.
            let leftWidth = floor(b.width * colFractions[0])
            let topHeight = floor(b.height * rowFraction)
            let topY = b.height - topHeight
            views[0].frame = NSRect(x: 0, y: topY, width: leftWidth, height: topHeight)
            views[1].frame = NSRect(x: leftWidth, y: topY, width: b.width - leftWidth, height: topHeight)
            views[2].frame = NSRect(x: 0, y: 0, width: leftWidth, height: topY)
            views[3].frame = NSRect(x: leftWidth, y: 0, width: b.width - leftWidth, height: topY)
            ensureDividers([true, false])
            dividers[0].frame = NSRect(x: leftWidth - 4, y: 0, width: 8, height: b.height)
            dividers[1].frame = NSRect(x: 0, y: topY - 4, width: b.width, height: 8)
        } else if views.count > 1 {
            // 2–3 vertical columns
            var x: CGFloat = 0
            for (index, view) in views.enumerated() {
                let width = index == views.count - 1 ? b.width - x : floor(b.width * colFractions[index])
                view.frame = NSRect(x: x, y: 0, width: width, height: b.height)
                x += width
            }
            ensureDividers(Array(repeating: true, count: views.count - 1))
            var edge: CGFloat = 0
            for (index, divider) in dividers.enumerated() {
                edge += floor(b.width * colFractions[index])
                divider.frame = NSRect(x: edge - 4, y: 0, width: 8, height: b.height)
            }
        } else {
            views[0].frame = b
            ensureDividers([])
        }
    }

    // Rebuild divider views only when the shape changes; orientation per divider
    // (true = vertical divider, i.e. drags horizontally).
    private func ensureDividers(_ orientations: [Bool]) {
        guard dividers.map(\.isVertical) != orientations else { return }
        dividers.forEach { $0.removeFromSuperview() }
        dividers = orientations.enumerated().map { index, isVertical in
            let divider = PaneDivider(isVertical: isVertical)
            divider.onDrag = { [weak self] delta in self?.dividerDragged(index: index, isVertical: isVertical, delta: delta) }
            addSubview(divider, positioned: .above, relativeTo: nil)
            return divider
        }
    }

    private func dividerDragged(index: Int, isVertical: Bool, delta: CGFloat) {
        let minFraction: CGFloat = 0.15
        if displayedTabIds.count == 4 {
            if isVertical {
                colFractions[0] = min(max(colFractions[0] + delta / bounds.width, minFraction), 1 - minFraction)
            } else {
                // NSEvent deltaY is positive downward; dragging down grows the top row
                rowFraction = min(max(rowFraction + delta / bounds.height, minFraction), 1 - minFraction)
            }
        } else {
            let change = delta / bounds.width
            let clamped = min(max(change, minFraction - colFractions[index]), colFractions[index + 1] - minFraction)
            colFractions[index] += clamped
            colFractions[index + 1] -= clamped
        }
        layoutPanes()
    }

    // MARK: - Pane focus on click

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let monitor = clickMonitor { NSEvent.removeMonitor(monitor); clickMonitor = nil }
        } else if clickMonitor == nil {
            // Webviews swallow mouse events, so watch clicks at the window level
            // and move focus when one lands in a non-focused pane.
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                self?.handlePaneClick(event)
                return event
            }
        }
    }

    private func handlePaneClick(_ event: NSEvent) {
        guard displayedTabIds.count > 1, event.window === window, let webViewManager = webViewManager else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        for id in displayedTabIds where id != focusedTabId {
            if webViewManager.getWebView(for: id).frame.contains(point) {
                DispatchQueue.main.async { self.onPaneFocus?(id) }
                return
            }
        }
    }

    deinit {
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutPanes()
    }

    override func willRemoveSubview(_ subview: NSView) {
        if let webView = subview as? WKWebView {
            webView.removeObserver(self, forKeyPath: "estimatedProgress")
            webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.url))
            visibleWebViews.remove(webView)
        }
        super.willRemoveSubview(subview)
    }

    // Forward KVO changes to the coordinator
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "estimatedProgress" || keyPath == #keyPath(WKWebView.url), object is WKWebView {
            coordinator?.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
}

// Draggable boundary between split panes: an 8pt grab strip drawing a 1pt
// separator line. A vertical divider drags horizontally (and vice versa).
final class PaneDivider: NSView {
    let isVertical: Bool
    var onDrag: ((CGFloat) -> Void)?

    init(isVertical: Bool) {
        self.isVertical = isVertical
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isVertical ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(isVertical ? event.deltaX : event.deltaY)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        let line = isVertical
            ? NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
            : NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)
        line.fill()
    }
}
#endif
