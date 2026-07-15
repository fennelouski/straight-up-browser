//
//  WebViewManager.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import WebKit
import Combine

class WebViewManager: NSObject, ObservableObject {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

    // Injected into every page: alt-click image download, long-press link
    // preview signals, and percentage-based spacebar scrolling. Native side
    // sets window.__subSpacePct per navigation in the coordinator's didCommit.
    private static let pageScript = """
    (function() {
        // Option+click on a bare image downloads it (links are handled natively)
        document.addEventListener('click', function(e) {
            if (!e.altKey || e.metaKey || e.ctrlKey) return;
            if (e.target.closest('a[href]')) return;
            var img = e.target.closest('img');
            if (img && img.currentSrc) {
                e.preventDefault(); e.stopPropagation();
                window.webkit.messageHandlers.sub.postMessage({type: 'downloadImage', url: img.currentSrc});
            }
        }, true);

        // Long-press a link -> preview. Prefetch starts on mousedown.
        var pressTimer = null, longPressed = false, startX = 0, startY = 0;
        document.addEventListener('mousedown', function(e) {
            if (e.button !== 0 || e.metaKey || e.altKey || e.ctrlKey || e.shiftKey) return;
            var a = e.target.closest('a[href]');
            if (!a || !/^https?:/.test(a.href)) return;
            longPressed = false; startX = e.clientX; startY = e.clientY;
            window.webkit.messageHandlers.sub.postMessage({type: 'linkDown', url: a.href});
            pressTimer = setTimeout(function() {
                longPressed = true;
                window.webkit.messageHandlers.sub.postMessage({type: 'linkLongPress'});
            }, 500);
        }, true);
        document.addEventListener('mousemove', function(e) {
            if (pressTimer && (Math.abs(e.clientX - startX) > 10 || Math.abs(e.clientY - startY) > 10)) {
                clearTimeout(pressTimer); pressTimer = null;
            }
        }, true);
        document.addEventListener('mouseup', function() {
            if (pressTimer) { clearTimeout(pressTimer); pressTimer = null; }
            if (!longPressed) window.webkit.messageHandlers.sub.postMessage({type: 'linkUp'});
        }, true);
        document.addEventListener('click', function(e) {
            if (longPressed) { e.preventDefault(); e.stopPropagation(); longPressed = false; }
        }, true);

        // Spacebar scrolls a settings-defined fraction of the viewport
        document.addEventListener('keydown', function(e) {
            if (e.key !== ' ' || e.metaKey || e.ctrlKey || e.altKey) return;
            var t = e.target;
            if (t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))) return;
            e.preventDefault();
            var pct = (window.__subSpacePct || 90) / 100;
            window.scrollBy({top: (e.shiftKey ? -1 : 1) * window.innerHeight * pct});
        }, true);
    })();
    """

    // Store web views per tab ID
    private var webViews: [UUID: WKWebView] = [:]

    // Active web view for the currently selected tab
    @Published var activeWebView: WKWebView?

    override init() {
        super.init()
        Logger.log("WebViewManager initialized", type: "WebViewManager")
    }

    // Get or create a web view for a specific tab
    func getWebView(for tabId: UUID) -> WKWebView {
        Logger.log("WebViewManager getWebView called for tab \(tabId)", type: "WebViewManager")
        if let existingWebView = webViews[tabId] {
            Logger.log("WebViewManager getWebView: returning existing WebView \(Unmanaged.passUnretained(existingWebView).toOpaque()) for tab \(tabId)", type: "WebViewManager")
            return existingWebView
        }

        Logger.log("WebViewManager: Creating new WKWebView for tab \(tabId)", type: "WebViewManager")
        let webView = createWebView()
        webViews[tabId] = webView
        Logger.log("WebViewManager: Created new WebView \(Unmanaged.passUnretained(webView).toOpaque()) for tab \(tabId)", type: "WebViewManager")
        return webView
    }

    // Set the active tab (switches which web view is considered active)
    func setActiveTab(_ tabId: UUID?) {
        Logger.log("WebViewManager setActiveTab called with tabId: \(tabId?.uuidString ?? "nil")", type: "WebViewManager")
        guard let tabId = tabId else {
            activeWebView = nil
            return
        }

        let webView = getWebView(for: tabId)
        Logger.log("WebViewManager setActiveTab: got WebView for tab \(tabId): \(Unmanaged.passUnretained(webView).toOpaque())", type: "WebViewManager")
        if activeWebView !== webView {
            Logger.log("WebViewManager: Switching active web view for tab \(tabId)", type: "WebViewManager")
            activeWebView = webView
        } else {
            Logger.log("WebViewManager setActiveTab: activeWebView already correct for tab \(tabId)", type: "WebViewManager")
        }
    }

    // Reverse lookup: which tab owns this web view (delegate callbacks arrive
    // for background webviews too, so callers can't assume "the active tab")
    func tabId(for webView: WKWebView) -> UUID? {
        webViews.first(where: { $0.value === webView })?.key
    }

    // Remove a web view when a tab is closed
    func removeWebView(for tabId: UUID) {
        if let webView = webViews[tabId] {
            // Stop any loading and detach so the view can actually deallocate
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.removeFromSuperview()

            // Remove from storage
            webViews.removeValue(forKey: tabId)

            // If this was the active web view, clear it
            if activeWebView === webView {
                activeWebView = nil
            }

            Logger.log("Removed web view for tab \(tabId)", type: "WebViewManager")
        }
    }

    // Register an externally created web view (a window.open popup, which must
    // be built from the configuration WebKit hands us) under a tab's ID.
    func adoptWebView(_ webView: WKWebView, for tabId: UUID) {
        applyStandardSetup(to: webView)
        webViews[tabId] = webView
        Logger.log("WebViewManager: adopted external WebView for tab \(tabId)", type: "WebViewManager")
    }

    // Create a new WKWebView with proper configuration
    private func createWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()

        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // JS on/off is decided per navigation in the policy delegate - the
        // settings toggle read here wouldn't reliably stick
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = .video

        // ponytail: the content controller retains us (handler) and we retain
        // the webviews - a cycle, but WebViewManager lives for the app lifetime
        configuration.userContentController.add(self, name: "sub")
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.pageScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        applyStandardSetup(to: webView)
        return webView
    }

    private func applyStandardSetup(to webView: WKWebView) {
        webView.customUserAgent = Self.userAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        if #available(macOS 13.3, *) {
            // Right-click > Inspect Element via Safari Web Inspector
            webView.isInspectable = true
        }
    }

    // Navigation methods that delegate to the active web view
    func goBack() {
        activeWebView?.goBack()
    }

    func goForward() {
        activeWebView?.goForward()
    }

    func reload() {
        activeWebView?.reload()
    }

    func reloadAllTabs() {
        for (_, webView) in webViews {
            webView.reload()
        }
    }

    func stopLoading() {
        activeWebView?.stopLoading()
    }

    func load(_ request: URLRequest) {
        activeWebView?.load(request)
    }

    // Computed properties that delegate to the active web view
    var canGoBack: Bool {
        activeWebView?.canGoBack ?? false
    }

    var canGoForward: Bool {
        activeWebView?.canGoForward ?? false
    }

    var isLoading: Bool {
        activeWebView?.isLoading ?? false
    }

    var url: URL? {
        activeWebView?.url
    }

    var title: String? {
        activeWebView?.title
    }

    var estimatedProgress: Double {
        activeWebView?.estimatedProgress ?? 0.0
    }

    // Evaluate JavaScript on the active web view
    func evaluateJavaScript(_ javaScriptString: String, completionHandler: ((Any?, Error?) -> Void)? = nil) {
        activeWebView?.evaluateJavaScript(javaScriptString, completionHandler: completionHandler)
    }

    // Clean up all web views
    func cleanup() {
        for (_, webView) in webViews {
            webView.stopLoading()
        }
        webViews.removeAll()
        activeWebView = nil
    }

    deinit {
        cleanup()
        Logger.log("WebViewManager deallocated", type: "WebViewManager")
    }
}

extension WebViewManager: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }

        switch type {
        case "downloadImage":
            if let urlString = body["url"] as? String,
               let url = URL(string: urlString),
               SettingsManager.shared.optionClickShouldDownload(url, isImage: true),
               let webView = message.webView {
                webView.startDownload(using: URLRequest(url: url)) { download in
                    // The coordinator (navigation delegate) owns download destinations
                    download.delegate = webView.navigationDelegate as? WKDownloadDelegate
                }
            }
        case "linkDown":
            if let urlString = body["url"] as? String, let url = URL(string: urlString) {
                NotificationCenter.default.post(name: .browserLinkPreviewDown, object: nil, userInfo: ["url": url])
            }
        case "linkLongPress":
            NotificationCenter.default.post(name: .browserLinkPreviewLongPress, object: nil)
        case "linkUp":
            NotificationCenter.default.post(name: .browserLinkPreviewUp, object: nil)
        default:
            break
        }
    }
}