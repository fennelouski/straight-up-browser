//
//  WebViewManager.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import WebKit
import Combine
#if canImport(AppKit)
import AppKit
#endif

class WebViewManager: NSObject, ObservableObject {
    // Claiming to be Chrome while running WebKit gets us flagged as an unsafe
    // embedded webview by Google sign-in (no Sec-CH-UA client hints to back it
    // up). Appending Safari's tokens makes WebKit build a genuine Safari UA and
    // fill in the OS/WebKit versions itself.
    static let userAgentAppName = "Version/26.4 Safari/605.1.15"

    // WebKit exposes the WebAuthn API in WKWebView but leaves it non-functional
    // without the Apple-gated com.apple.developer.web-browser.public-key-credential
    // entitlement: isUserVerifyingPlatformAuthenticatorAvailable() reports false and
    // no ceremony can complete. Advertising an API we can't honor makes sites offer
    // passkey sign-in that dead-ends (Google loops on it), so we hide it and let them
    // fall back to password. navigator.credentials stays for password autofill.
    // ponytail: delete this if the entitlement is ever granted.
    private static let hideWebAuthnScript = """
    delete window.PublicKeyCredential;
    delete window.AuthenticatorAttestationResponse;
    delete window.AuthenticatorAssertionResponse;
    """

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

    // Saved WKWebView.interactionState for tabs unloaded under memory pressure,
    // consumed when the tab is reactivated (restores scroll + back/forward).
    private var savedInteractionStates: [UUID: Any] = [:]

    // Active web view for the currently selected tab
    @Published var activeWebView: WKWebView?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(adBlockSettingChanged), name: .adBlockChanged, object: nil)
        // Restore last session's per-tab page state; getWebView consumes it the
        // first time each tab is activated. Persist again when the app quits.
        loadPersistedInteractionStates()
        #if canImport(AppKit)
        NotificationCenter.default.addObserver(
            self, selector: #selector(persistInteractionStates),
            name: NSApplication.willTerminateNotification, object: nil)
        #endif
        startMemoryPressureMonitoring()
        Logger.log("WebViewManager initialized", type: "WebViewManager")
    }

    // MARK: - Session restore (local, per-tab scroll + in-page history)

    // interactionState for open tabs, stashed between launches so a relaunch
    // resumes each page where it was. Local (Application Support) on purpose: it
    // never touches the iCloud cache-state column, so the sync privacy toggle
    // stays authoritative for what leaves the device.
    private static var interactionStateFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SessionInteractionState.plist")
    }

    private func loadPersistedInteractionStates() {
        guard #available(macOS 12.0, *),
              let url = Self.interactionStateFileURL,
              let data = try? Data(contentsOf: url),
              let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data]
        else { return }
        for (idString, stateData) in raw {
            guard let id = UUID(uuidString: idString),
                  let state = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(stateData) else { continue }
            savedInteractionStates[id] = state
        }
        Logger.log("Loaded \(savedInteractionStates.count) persisted interaction states", type: "WebViewManager")
    }

    // Archive every open tab's page state to disk. Live web views win over a
    // stale saved copy for the same tab. ponytail: uncapped file; if heavy
    // sessions bloat it, cap total bytes or drop the least-recently-used tabs.
    @objc private func persistInteractionStates() {
        guard #available(macOS 12.0, *), let url = Self.interactionStateFileURL else { return }
        var out: [String: Data] = [:]
        for (id, state) in savedInteractionStates {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false) {
                out[id.uuidString] = data
            }
        }
        for (id, webView) in webViews {
            if let state = webView.interactionState,
               let data = try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false) {
                out[id.uuidString] = data
            }
        }
        guard let plist = try? PropertyListSerialization.data(fromPropertyList: out, format: .binary, options: 0) else { return }
        try? plist.write(to: url, options: .atomic)
        Logger.log("Persisted \(out.count) interaction states", type: "WebViewManager")
    }

    // MARK: - Memory pressure

    // The OS signals when memory is tight; we relay it so ContentView (which
    // knows each tab's policy) decides what to unload. ponytail: macOS exposes
    // only .warning/.critical, so "always" and "when needed" share the warning
    // trigger. Upgrade path: poll os_proc_available_memory() for finer tiers.
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    private func startMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak source] in
            let critical = source?.data.contains(.critical) ?? false
            Logger.log("Memory pressure relayed (critical=\(critical))", type: "WebViewManager")
            NotificationCenter.default.post(name: .memoryPressure, object: nil, userInfo: ["critical": critical])
        }
        source.resume()
        memoryPressureSource = source
    }

    // MARK: - Ad blocking (WKContentRuleList)

    // ponytail: built-in list of the biggest ad/tracker networks, not EasyList.
    // Swap in a downloaded filter list if users want deeper coverage.
    private static let adHosts = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "google-analytics.com", "adservice.google.com", "2mdn.net",
        "amazon-adsystem.com", "adnxs.com", "adsrvr.org", "criteo.com",
        "criteo.net", "taboola.com", "outbrain.com", "rubiconproject.com",
        "pubmatic.com", "openx.net", "moatads.com", "scorecardresearch.com",
        "adsafeprotected.com", "doubleverify.com", "smartadserver.com",
        "casalemedia.com", "33across.com", "quantserve.com", "yieldmo.com",
        "media.net", "teads.tv", "sharethrough.com", "spotxchange.com",
        "indexexchange.com",
    ]

    private static var adBlockList: WKContentRuleList?

    private static func compileAdBlockList(_ completion: @escaping (WKContentRuleList?) -> Void) {
        if let list = adBlockList { completion(list); return }
        // Content-blocker regex has no alternation, so one block rule per host
        let rules = adHosts.map { host in
            let escaped = host.replacingOccurrences(of: ".", with: "\\\\.")
            return #"{"trigger":{"url-filter":"^https?://([^/]+\\.)?\#(escaped)[:/]","load-type":["third-party"]},"action":{"type":"block"}}"#
        }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "sub-adblock",
            encodedContentRuleList: "[\(rules.joined(separator: ","))]"
        ) { list, error in
            if let error {
                Logger.log("Ad block rule compile failed: \(error)", type: "WebViewManager")
            }
            adBlockList = list
            completion(list)
        }
    }

    @objc private func adBlockSettingChanged() {
        if UserDefaults.standard.bool(forKey: "adBlockEnabled") {
            Self.compileAdBlockList { [weak self] list in
                guard let self, let list else { return }
                for webView in self.webViews.values {
                    let controller = webView.configuration.userContentController
                    controller.remove(list) // avoid double-add
                    controller.add(list)
                }
                self.reloadAllTabs()
            }
        } else {
            guard let list = Self.adBlockList else { return }
            for webView in webViews.values {
                webView.configuration.userContentController.remove(list)
            }
            reloadAllTabs()
        }
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
        #if canImport(AppKit)
        MainActor.assumeIsolated { WebExtensionManager.shared.tabOpened(tabId) }
        #endif
        // Restore scroll + back/forward if this tab was unloaded under memory pressure
        if #available(macOS 12.0, *), let state = savedInteractionStates.removeValue(forKey: tabId) {
            webView.interactionState = state
        }
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

        let previousTabId = activeTabId
        let webView = getWebView(for: tabId)
        Logger.log("WebViewManager setActiveTab: got WebView for tab \(tabId): \(Unmanaged.passUnretained(webView).toOpaque())", type: "WebViewManager")
        if activeWebView !== webView {
            Logger.log("WebViewManager: Switching active web view for tab \(tabId)", type: "WebViewManager")
            activeWebView = webView
            #if canImport(AppKit)
            MainActor.assumeIsolated { WebExtensionManager.shared.activeTabChanged(to: tabId, from: previousTabId) }
            #endif
        } else {
            Logger.log("WebViewManager setActiveTab: activeWebView already correct for tab \(tabId)", type: "WebViewManager")
        }
    }

    // Reverse lookup: which tab owns this web view (delegate callbacks arrive
    // for background webviews too, so callers can't assume "the active tab")
    func tabId(for webView: WKWebView) -> UUID? {
        webViews.first(where: { $0.value === webView })?.key
    }

    // Live tab state read by the web extension bridge (WebExtension.swift).
    var liveTabIds: [UUID] { Array(webViews.keys) }
    func existingWebView(for id: UUID) -> WKWebView? { webViews[id] }
    var activeTabId: UUID? { activeWebView.flatMap { tabId(for: $0) } }

    // Remove a web view. `notifyClosed` is true for a real tab close and false
    // for a memory unload (the tab lives on), so the extension bridge only sees
    // genuine closes rather than unload/reactivate churn.
    func removeWebView(for tabId: UUID, notifyClosed: Bool = true) {
        if let webView = webViews[tabId] {
            // Stop any loading and detach so the view can actually deallocate
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.removeFromSuperview()

            // Remove from storage
            webViews.removeValue(forKey: tabId)
            savedInteractionStates.removeValue(forKey: tabId)

            // If this was the active web view, clear it
            if activeWebView === webView {
                activeWebView = nil
            }

            if notifyClosed {
                #if canImport(AppKit)
                MainActor.assumeIsolated { WebExtensionManager.shared.tabClosed(tabId) }
                #endif
            }
            Logger.log("Removed web view for tab \(tabId)", type: "WebViewManager")
        }
    }

    // Release a tab's web view (and its content process) to reclaim RAM. Saves
    // interaction state (scroll + back/forward) so getWebView restores it when
    // the tab is reactivated. The tab stays open; only its RAM is freed.
    func unloadWebView(for tabId: UUID) {
        guard let webView = webViews[tabId] else { return }
        var state: Any?
        if #available(macOS 12.0, *) { state = webView.interactionState }
        removeWebView(for: tabId, notifyClosed: false)  // unload, not close: keep the extension's tab

        if let state { savedInteractionStates[tabId] = state }  // set AFTER teardown clears it
    }

    // Register an externally created web view (a window.open popup, which must
    // be built from the configuration WebKit hands us) under a tab's ID.
    func adoptWebView(_ webView: WKWebView, for tabId: UUID) {
        applyStandardSetup(to: webView)
        webViews[tabId] = webView
        #if canImport(AppKit)
        MainActor.assumeIsolated { WebExtensionManager.shared.tabOpened(tabId) }
        #endif
        Logger.log("WebViewManager: adopted external WebView for tab \(tabId)", type: "WebViewManager")
    }

    // Create a new WKWebView with proper configuration
    private func createWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Popups adopted via adoptWebView inherit this from the opener's config
        configuration.applicationNameForUserAgent = Self.userAgentAppName

        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // JS on/off is decided per navigation in the policy delegate - the
        // settings toggle read here wouldn't reliably stick
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = .video

        // ponytail: the content controller retains us (handler) and we retain
        // the webviews - a cycle, but WebViewManager lives for the app lifetime
        configuration.userContentController.add(self, name: "sub")
        if UserDefaults.standard.bool(forKey: "adBlockEnabled") {
            let controller = configuration.userContentController
            Self.compileAdBlockList { list in
                if let list { controller.add(list) }
            }
        }
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.pageScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        // Must run before any page code so feature detection sees the truth, and
        // in subframes because sign-in flows are often framed.
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.hideWebAuthnScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        // Attach the app-wide web extension controller so any loaded extension's
        // content scripts run in this tab. Inert when no extension is loaded, but
        // must be set before the web view exists — it can't be added later.
        // ponytail: web extensions are macOS-only in v1; the controller wiring is
        // compiled out on iPad. Port WebExtension.swift when iPad needs extensions.
        #if canImport(AppKit)
        MainActor.assumeIsolated {
            configuration.webExtensionController = WebExtensionManager.shared.controller
            WebExtensionManager.shared.register(self)
        }
        #endif

        let webView = WKWebView(frame: .zero, configuration: configuration)
        applyStandardSetup(to: webView)
        return webView
    }

    private func applyStandardSetup(to webView: WKWebView) {
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