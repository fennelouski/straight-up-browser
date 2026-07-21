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

extension NSKeyedUnarchiver {
    // Non-deprecated replacement for unarchiveTopLevelObjectWithData: decodes a
    // root object archived without secure coding (e.g. WKWebView.interactionState,
    // an opaque type). Returns nil instead of crashing on a corrupt archive.
    static func unarchiveTopLevelObject(from data: Data) -> Any? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
    }
}

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

        // First-paint ping. Two rAFs: the first is scheduled before the frame
        // that draws this document, the second lands after it — so by the time
        // this posts there really is content on screen. beginFadeIn is waiting.
        requestAnimationFrame(function() {
            requestAnimationFrame(function() {
                window.webkit.messageHandlers.sub.postMessage({type: 'painted'});
            });
        });
    })();
    """

    // On-device page translation (PageTranslator.swift is the Swift-side driver).
    // window.__subTranslate.sampleText() feeds language detection; .extract()
    // wraps visible text nodes in spans and returns {id, text} for translation;
    // .apply(map) writes translated text back in; .toggle() flips every wrapped
    // span between translated/original. Peek: holding Option anywhere on the
    // page reveals the original text of just the element under the cursor, via
    // a body class + CSS :hover/::before (no per-mousemove JS, so it can't
    // collide with KeyboardShortcutsManager's global modifier monitor).
    private static let translateScript = """
    (function() {
        var nextId = 0, nodeMap = new Map(), showOriginal = false;

        function isVisible(el) {
            var style = window.getComputedStyle(el);
            return style && style.display !== 'none' && style.visibility !== 'hidden';
        }

        function collectTextNodes(root, limit) {
            var out = [];
            var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
                acceptNode: function(node) {
                    if (!node.nodeValue || !node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
                    var parent = node.parentElement;
                    if (!parent || parent.isContentEditable) return NodeFilter.FILTER_REJECT;
                    if (/^(SCRIPT|STYLE|NOSCRIPT|TEXTAREA)$/.test(parent.tagName)) return NodeFilter.FILTER_REJECT;
                    if (!isVisible(parent)) return NodeFilter.FILTER_REJECT;
                    return NodeFilter.FILTER_ACCEPT;
                }
            });
            var node;
            while (out.length < limit && (node = walker.nextNode())) out.push(node);
            return out;
        }

        // ponytail: position:absolute overlay for the peek/toggle swap - good
        // enough for prose text, can misalign on tightly-laid-out inline text.
        // Upgrade to an inline-reflow-safe technique if that's reported janky.
        function injectStyle() {
            if (document.getElementById('sub-translate-style')) return;
            var style = document.createElement('style');
            style.id = 'sub-translate-style';
            style.textContent =
                '.sub-translated[data-original]{position:relative}' +
                'body.sub-peek-mode .sub-translated:hover,' +
                'body.sub-show-original .sub-translated{visibility:hidden}' +
                'body.sub-peek-mode .sub-translated:hover::before,' +
                'body.sub-show-original .sub-translated::before{' +
                'content:attr(data-original);visibility:visible;position:absolute;' +
                'left:0;top:0;width:max-content;max-width:100vw}';
            (document.head || document.documentElement).appendChild(style);
        }
        if (document.head) { injectStyle(); } else {
            document.addEventListener('DOMContentLoaded', injectStyle);
        }

        window.__subTranslate = {
            sampleText: function() {
                return document.body ? document.body.innerText.slice(0, 2000) : '';
            },
            hasTranslation: function() {
                return nodeMap.size > 0;
            },
            extract: function() {
                if (!document.body) return [];
                var results = [];
                collectTextNodes(document.body, 500).forEach(function(node) {
                    var span = document.createElement('span');
                    span.className = 'sub-translated';
                    var id = 'st' + (nextId++);
                    span.dataset.tid = id;
                    span.dataset.original = node.nodeValue;
                    node.parentNode.replaceChild(span, node);
                    span.appendChild(node);
                    nodeMap.set(id, node);
                    results.push({id: id, text: node.nodeValue});
                });
                return results;
            },
            apply: function(map) {
                Object.keys(map).forEach(function(id) {
                    var node = nodeMap.get(id);
                    if (node) node.nodeValue = map[id];
                });
            },
            toggle: function() {
                showOriginal = !showOriginal;
                if (document.body) document.body.classList.toggle('sub-show-original', showOriginal);
            }
        };

        document.addEventListener('keydown', function(e) {
            if (e.key === 'Alt' && document.body) document.body.classList.add('sub-peek-mode');
        }, true);
        document.addEventListener('keyup', function(e) {
            if (e.key === 'Alt' && document.body) document.body.classList.remove('sub-peek-mode');
        }, true);
        window.addEventListener('blur', function() {
            if (document.body) document.body.classList.remove('sub-peek-mode');
        });
    })();
    """

    // Store web views per tab ID
    private var webViews: [UUID: WKWebView] = [:]

    // Session isolation (see SessionKind). A tab's session is registered here so
    // getWebView can pick its WKWebsiteDataStore when the web view is first built.
    // Absent => normal (shared default store). Populated on tab creation and synced
    // from the tab list (syncSessions) so container tabs restored at launch are known.
    private var tabSessions: [UUID: (kind: SessionKind, sessionId: UUID?)] = [:]
    // Ephemeral incognito stores, held so every tab in one incognito session shares a
    // jar. Dropped (and thus wiped) when a session's last tab closes; all die on quit.
    private var incognitoStores: [UUID: WKWebsiteDataStore] = [:]

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
                  let state = NSKeyedUnarchiver.unarchiveTopLevelObject(from: stateData) else { continue }
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
        // Never persist incognito tabs' page state — that would write a private URL
        // (and form/scroll state) to disk, defeating the point of incognito.
        for (id, state) in savedInteractionStates where !isIncognito(id) {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false) {
                out[id.uuidString] = data
            }
        }
        for (id, webView) in webViews where !isIncognito(id) {
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
        let webView = createWebView(for: tabId)
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
            // Keep the session across a memory unload (the tab reactivates and must
            // rebuild in the same store); drop it only on a genuine close.
            if notifyClosed { tabSessions.removeValue(forKey: tabId) }

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

    // MARK: - Session isolation

    // Record a tab's session so getWebView can pick its data store at creation.
    func registerSession(for tabId: UUID, kind: SessionKind, sessionId: UUID?) {
        if kind == .normal { tabSessions.removeValue(forKey: tabId) }
        else { tabSessions[tabId] = (kind, sessionId) }
    }

    // Rebuild the map from the current tab list. Covers container tabs restored from
    // SwiftData at launch, which must be known before their web views are built.
    func syncSessions(from tabs: [Tab]) {
        for tab in tabs where tab.sessionKind != .normal {
            tabSessions[tab.id] = (tab.sessionKind, tab.sessionId)
        }
    }

    // The WKWebsiteDataStore (cookie/cache/storage jar) a tab browses in. See SessionKind.
    private func dataStore(for tabId: UUID) -> WKWebsiteDataStore {
        guard let session = tabSessions[tabId] else { return .default() }
        switch session.kind {
        case .normal:
            return .default()
        case .container:
            guard let id = session.sessionId else { return .default() }
            return WKWebsiteDataStore(forIdentifier: id)
        case .incognito:
            let id = session.sessionId ?? tabId
            if let store = incognitoStores[id] { return store }
            let store = WKWebsiteDataStore.nonPersistent()
            incognitoStores[id] = store
            return store
        }
    }

    // The store a live tab is using, for scoped cache clearing. Reads the web view's
    // own config when built; otherwise resolves from the registry.
    func dataStore(forTab tabId: UUID) -> WKWebsiteDataStore {
        webViews[tabId]?.configuration.websiteDataStore ?? dataStore(for: tabId)
    }

    // Drop (and thus wipe) an incognito session's jar once its last tab is gone.
    func discardIncognitoStore(_ sessionId: UUID) {
        incognitoStores.removeValue(forKey: sessionId)
    }

    // Build the ephemeral jar for a tab-to-incognito conversion, before any tab
    // joins the session. Cookies are copied from the source tab's store so
    // cookie-based logins survive the switch; localStorage/IndexedDB have no
    // copy API and are left behind, so sites keeping auth tokens there sign out.
    // Completion fires on main once the jar is ready to browse in.
    func prepareIncognitoStore(sessionId: UUID, copyingCookiesFromTab tabId: UUID, completion: @escaping () -> Void) {
        let store = WKWebsiteDataStore.nonPersistent()
        incognitoStores[sessionId] = store
        dataStore(forTab: tabId).httpCookieStore.getAllCookies { cookies in
            let group = DispatchGroup()
            for cookie in cookies {
                group.enter()
                store.httpCookieStore.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main) { completion() }
        }
    }

    // Whether a tab is incognito (its page state must never be persisted to disk).
    private func isIncognito(_ tabId: UUID) -> Bool {
        tabSessions[tabId]?.kind == .incognito
    }

    // A tab's session, for inheriting it onto a new tab (Cmd+T, window.open popups).
    func session(for tabId: UUID) -> (kind: SessionKind, sessionId: UUID?) {
        tabSessions[tabId] ?? (.normal, nil)
    }

    // Create a new WKWebView with proper configuration
    private func createWebView(for tabId: UUID) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The tab's session decides its cookie/cache/storage jar. Normal tabs get the
        // shared default store (unchanged); containers/incognito get isolated stores.
        // Popups adopted via adoptWebView inherit the opener's store from its config.
        configuration.websiteDataStore = dataStore(for: tabId)
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
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.translateScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
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
        // What WebKit paints where the page hasn't yet — the source of the white
        // flash. Matching the window means even an unpainted web view is invisible.
        #if os(macOS)
        if #available(macOS 12.0, *) { webView.underPageBackgroundColor = .windowBackgroundColor }
        #endif
    }

    // MARK: - Fade in on first paint

    // Between didCommit (old document gone) and the page's first paint there is
    // nothing to show, and WebKit flashes its background. So: hide at commit,
    // fade in when the page's double-rAF ping says pixels exist. Backstops —
    // didFinish, didFail, and a hard timer — cover content that never runs our
    // script (PDFs, downloads, plugin content) so a tab can't be left blank.
    private var fadePending: Set<ObjectIdentifier> = []

    func beginFadeIn(_ webView: WKWebView) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "fadeInPages") == nil || defaults.bool(forKey: "fadeInPages") else { return }
        fadePending.insert(ObjectIdentifier(webView))
        setAlpha(webView, 0, duration: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak webView] in
            guard let webView else { return }
            self?.revealPage(webView)
        }
    }

    func revealPage(_ webView: WKWebView) {
        guard fadePending.remove(ObjectIdentifier(webView)) != nil else { return }
        let ms = UserDefaults.standard.object(forKey: "fadeInDuration") as? Double ?? 250
        setAlpha(webView, 1, duration: min(max(ms, 100), 1000) / 1000)
    }

    private func setAlpha(_ webView: WKWebView, _ alpha: CGFloat, duration: TimeInterval) {
        #if os(macOS)
        guard duration > 0 else { webView.alphaValue = alpha; return }
        NSAnimationContext.runAnimationGroup {
            $0.duration = duration
            webView.animator().alphaValue = alpha
        }
        #else
        UIView.animate(withDuration: duration) { webView.alpha = alpha }
        #endif
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
        case "painted":
            if let webView = message.webView { revealPage(webView) }
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