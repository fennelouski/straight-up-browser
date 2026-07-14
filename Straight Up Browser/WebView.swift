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

        // Update the active tab in the container
        nsView.setActiveTab(activeTabId)

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

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            // Check for redirect loops before starting navigation
            if let url = webView.url, isRedirectLoop(url) {
                Logger.log("WebView didStartProvisionalNavigation: Blocking redirect loop for URL: \(url.absoluteString)", type: "WebView")
                parent.isLoading = false
                return
            }

            parent.isLoading = true
            parent.hasRenderedContent = false
            parent.progressValue = 0.0
            // Update lastRequestedURL to reflect what we're actually loading
            if let url = webView.url {
                Logger.log("WebView didStartProvisionalNavigation: setting lastRequestedURL to \(url.absoluteString)", type: "WebView")
                lastRequestedURL = url
                recordNavigation(url)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.hasRenderedContent = true
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
            parent.title = webView.title ?? ""

            // Track the URL that successfully loaded
            if let url = webView.url {
                lastSuccessfullyLoadedURL = url
            }

            // Clear navigation history on successful page load to reset loop detection
            navigationHistory.removeAll()

            // Update the tab's URL if it changed (e.g., user clicked a link)
            let normalizedCurrentURL = Tab.normalizeURLForComparison(webView.url)
            let normalizedParentURL = Tab.normalizeURLForComparison(parent.url)
            if let currentURL = webView.url, normalizedCurrentURL != normalizedParentURL {
                Logger.log("WebView didFinish: updating tab URL to \(currentURL.absoluteString)", type: "WebView")
                // Update the tab URL directly without triggering navigateTo to avoid recursion
                if let tabManager = self.tabManager,
                   let tabs = self.tabs,
                   let activeTab = tabManager.getActiveTab(from: tabs) {
                    activeTab.url = currentURL

                    // Record the visit for omnibar suggestions; WKWebView owns back/forward
                    if activeTab.history.last != currentURL {
                        activeTab.historyStrings.append(currentURL.absoluteString)

                        // Limit history size
                        let maxHistorySize = SettingsManager.shared.maxHistorySize
                        if activeTab.historyStrings.count > maxHistorySize {
                            activeTab.historyStrings.removeFirst(activeTab.historyStrings.count - maxHistorySize)
                        }
                    }
                }

                // Notify parent of URL change to update stable URL
                parent.onURLChange?(currentURL)
            }

            // Load favicon for the current page
            loadFavicon(for: webView)

            // Ensure WebView remains interactive after loading
            DispatchQueue.main.async {
                // Re-enable interactions
                webView.allowsBackForwardNavigationGestures = true
                webView.allowsMagnification = true
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
                setActiveTabFavicon(cachedData)
                return
            }

            URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
                guard let self = self else { return }

                if let data = data,
                   let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 200, data.count > 0,
                   NSImage(data: data) != nil {
                    FaviconCache.shared.setFavicon(data, for: url)
                    self.setActiveTabFavicon(data)
                } else {
                    DispatchQueue.main.async {
                        self.generateDomainInitial(for: webView)
                    }
                }
            }.resume()
        }

        private func setActiveTabFavicon(_ data: Data) {
            DispatchQueue.main.async {
                if let tabManager = self.tabManager,
                   let tabs = self.tabs,
                   let activeTab = tabManager.getActiveTab(from: tabs) {
                    activeTab.favicon = data
                }
            }
        }

        private func generateDomainInitial(for webView: WKWebView) {
            guard let url = webView.url, let domain = url.host else { return }

            if let initialImageData = DomainInitialsGenerator.shared.generateInitialImage(for: domain) {
                setActiveTabFavicon(initialImageData)
            }
        }

        override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
            if keyPath == "estimatedProgress", let webView = object as? WKWebView {
                DispatchQueue.main.async {
                    self.parent.progressValue = webView.estimatedProgress
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
                // ponytail: reveal in Finder is the entire downloads UI; build an
                // overlay panel if this grates with multi-file downloads
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
            alert.messageText = "SSL Certificate Warning"
            alert.informativeText = "The certificate for \(host) could not be verified.\n\nTrust Result: \(trustResultDescription(trustResult))\n\nThis may indicate a security risk. Do you want to proceed anyway?"

            alert.alertStyle = .warning
            alert.addButton(withTitle: "Proceed")
            alert.addButton(withTitle: "Cancel")

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
            let popupWebView = WKWebView(frame: .zero, configuration: configuration)
            let newTab = tabManager.createNewTab()
            webViewManager.adoptWebView(popupWebView, for: newTab.id)
            return popupWebView
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
            alert.messageText = frame.request.url?.host ?? "This page"
            alert.informativeText = message
            return alert
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = makeDialogAlert(message: message, frame: frame)
            alert.addButton(withTitle: "OK")
            presentSheet(alert, over: webView) { _ in completionHandler() }
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = makeDialogAlert(message: message, frame: frame)
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            presentSheet(alert, over: webView) { completionHandler($0 == .alertFirstButtonReturn) }
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            let alert = makeDialogAlert(message: prompt, frame: frame)
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
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
            if let window = webView.window {
                panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
            } else {
                completionHandler(panel.runModal() == .OK ? panel.urls : nil)
            }
        }
    }

}

class WebViewContainer: NSView {
    private var webViewManager: WebViewManager?
    private weak var coordinator: WebView.Coordinator?
    private var activeTabId: UUID?
    private var visibleWebViews: Set<WKWebView> = []

    var activeWebView: WKWebView? {
        // Return the WebView for the currently active tab, not necessarily the manager's activeWebView
        if let activeTabId = activeTabId, let webViewManager = webViewManager {
            return webViewManager.getWebView(for: activeTabId)
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

    func setActiveTab(_ tabId: UUID?) {
        Logger.log("WebViewContainer setActiveTab called with tabId: \(tabId?.uuidString ?? "nil")", type: "WebView")

        // Update active tab first
        activeTabId = tabId

        // Update the WebViewManager's active tab
        webViewManager?.setActiveTab(tabId)

        // Hide all currently visible web views
        for webView in visibleWebViews {
            webView.isHidden = true
        }
        visibleWebViews.removeAll()

        // Update active tab
        activeTabId = tabId

        // Show new active web view
        if let newTabId = tabId, let webViewManager = webViewManager {
            let webView = webViewManager.getWebView(for: newTabId)
            Logger.log("WebViewContainer setActiveTab: got WebView \(Unmanaged.passUnretained(webView).toOpaque()) for tab \(newTabId)", type: "WebView")

            // Verify this matches the WebViewManager's activeWebView
            if let managerActiveWebView = webViewManager.activeWebView {
                if webView !== managerActiveWebView {
                    Logger.log("WebViewContainer setActiveTab: WARNING - WebView mismatch! Container got \(Unmanaged.passUnretained(webView).toOpaque()) but manager has \(Unmanaged.passUnretained(managerActiveWebView).toOpaque())", type: "WebView")
                } else {
                    Logger.log("WebViewContainer setActiveTab: WebView matches manager's activeWebView", type: "WebView")
                }
            }

            // Configure the web view if it's not already a subview
            if webView.superview !== self {
                webView.frame = self.bounds
                webView.autoresizingMask = [.width, .height]

                // Ensure web view doesn't extend beyond container bounds
                webView.wantsLayer = true
                webView.layer?.masksToBounds = true

                // Set up delegates
                webView.navigationDelegate = coordinator
                webView.uiDelegate = coordinator

                // Observe real load progress; removed in willRemoveSubview
                webView.addObserver(self, forKeyPath: "estimatedProgress", options: .new, context: nil)

                // Add to container
                self.addSubview(webView)
                Logger.log("WebViewContainer: added new WebView for tab \(newTabId)", type: "WebView")
            } else {
                // Update frame if already a subview
                webView.frame = self.bounds
                Logger.log("WebViewContainer: updated frame for existing WebView for tab \(newTabId)", type: "WebView")
            }

            // Show the web view
            webView.isHidden = false
            visibleWebViews.insert(webView)

            // Ensure WebView can accept user interactions
            webView.allowsBackForwardNavigationGestures = true
            webView.allowsMagnification = true
            webView.allowsLinkPreview = true

            Logger.log("WebViewContainer: showed WebView \(Unmanaged.passUnretained(webView).toOpaque()) for tab \(newTabId)", type: "WebView")
        } else {
            Logger.log("WebViewContainer setActiveTab: no tabId or webViewManager", type: "WebView")
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Update all subview web view frames when container size changes
        for subview in self.subviews {
            if let webView = subview as? WKWebView {
                webView.frame = self.bounds
            }
        }
    }

    override func willRemoveSubview(_ subview: NSView) {
        if let webView = subview as? WKWebView {
            webView.removeObserver(self, forKeyPath: "estimatedProgress")
            visibleWebViews.remove(webView)
        }
        super.willRemoveSubview(subview)
    }

    // Forward KVO changes to the coordinator for the estimatedProgress property
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "estimatedProgress", object is WKWebView {
            coordinator?.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
}
#endif
