//
//  WebView.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
@preconcurrency import WebKit
import CoreImage
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
    var pageTranslator: PageTranslator?
    var fastForward: FastForward?
    var tabs: [Tab]?
    var activeTabId: UUID?
    // Split view: all tabs shown as panes (ordered). Normally just [activeTabId].
    var displayedTabIds: [UUID] = []
    var onURLChange: ((URL?) -> Void)?
    var onSaveLinkToNewspaper: ((URL, WKWebView) -> Void)?
    /// Non-nil result = the pane id is a workspace document; the returned view
    /// is laid out where a web view would be (ADR 0008). Nil = ordinary tab.
    var documentPaneProvider: ((UUID) -> NSView?)?

    // Trackpad pinch + two-finger double-tap smart zoom. @AppStorage here so
    // flipping the setting re-runs updateNSView and applies it live.
    @AppStorage("pinchToZoomEnabled") private var pinchToZoomEnabled = true

    // Max page brightness, 100 = untouched. Same deal: @AppStorage so dragging
    // the slider re-runs updateNSView and you see it change under you.
    @AppStorage("pageWhitePoint") private var pageWhitePoint = 100.0
    // Black point, 0 = untouched. Positive lifts blacks toward grey, negative
    // crushes greys down to black.
    @AppStorage("pageBlackPoint") private var pageBlackPoint = 0.0
    // Off outside its scheduled hours: pages go back to untouched.
    @ObservedObject private var toneSchedule = ToneSchedule.shared

    init(url: Binding<URL?>,
         canGoBack: Binding<Bool>,
         canGoForward: Binding<Bool>,
         title: Binding<String>,
         isLoading: Binding<Bool>,
         progressValue: Binding<Double>,
         hasRenderedContent: Binding<Bool>,
         webViewManager: WebViewManager?,
         tabManager: TabManager?,
         pageTranslator: PageTranslator? = nil,
         fastForward: FastForward? = nil,
         tabs: [Tab]?,
         activeTabId: UUID?,
         displayedTabIds: [UUID] = [],
         onURLChange: ((URL?) -> Void)?,
         onSaveLinkToNewspaper: ((URL, WKWebView) -> Void)? = nil,
         documentPaneProvider: ((UUID) -> NSView?)? = nil) {
        self._url = url
        self._canGoBack = canGoBack
        self._canGoForward = canGoForward
        self._title = title
        self._isLoading = isLoading
        self._progressValue = progressValue
        self._hasRenderedContent = hasRenderedContent
        self.webViewManager = webViewManager
        self.tabManager = tabManager
        self.pageTranslator = pageTranslator
        self.fastForward = fastForward
        self.tabs = tabs
        self.activeTabId = activeTabId
        self.displayedTabIds = displayedTabIds.isEmpty ? [activeTabId].compactMap { $0 } : displayedTabIds
        self.onURLChange = onURLChange
        self.onSaveLinkToNewspaper = onSaveLinkToNewspaper
        self.documentPaneProvider = documentPaneProvider

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
        nsView.documentPaneProvider = documentPaneProvider
        let isDocumentPane: (UUID) -> Bool = { [documentPaneProvider] id in
            documentPaneProvider?(id) != nil
        }
        nsView.onPaneFocus = { [tabManager] id in
            if isDocumentPane(id) {
                tabManager?.selectDocument(id)
            } else {
                tabManager?.selectedTabId = id
            }
        }
        nsView.whitePoint = toneSchedule.isActive ? pageWhitePoint : 100
        nsView.blackPoint = toneSchedule.isActive ? pageBlackPoint : 0
        nsView.setDisplayedTabs(displayedTabIds, focusedTabId: activeTabId)
        for id in displayedTabIds {
            if let tab = tabs?.first(where: { $0.id == id }) {
                webViewManager?.setMuted(tab.isMuted, for: id)
            }
        }

        // Non-focused panes never go through the url-binding load path below, so a
        // pane restored at launch would sit blank: load its tab's URL once here.
        for id in displayedTabIds where id != activeTabId {
            guard let paneWebView = webViewManager?.existingWebView(for: id),
                  paneWebView.url == nil, !paneWebView.isLoading,
                  let tab = tabs?.first(where: { $0.id == id }) else { continue }
            if TabSync.restoreInteractionState(tab, into: paneWebView) { continue }
            if let paneURL = tab.url {
                context.coordinator.beginLoad(paneURL, in: paneWebView)
                webViewManager?.beginFadeIn(paneWebView)
                paneWebView.loadURL(paneURL)
            }
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
        if let url = url, WebViewLoadDecision.shouldLoad(
            target: url,
            showing: activeWebView.url,
            requested: context.coordinator.lastRequestedURL,
            inFlight: context.coordinator.loadInFlight(for: activeWebView),
            isLoading: activeWebView.isLoading
        ) {
            context.coordinator.beginLoad(url, in: activeWebView)
            Logger.log("WebView loading URL: \(url.absoluteString) (current: \(activeWebView.url?.absoluteString ?? "nil"))", type: "WebView")
            context.coordinator.lastRequestedURL = url
            // Hide now, synchronously, rather than waiting for didCommit - that
            // callback arrives after WebKit has already swapped the compositor
            // layer, so the old/blank frame flickers through for a frame or two
            // before the fade catches up.
            webViewManager?.beginFadeIn(activeWebView)
            activeWebView.loadURL(url)
        } else if let url = url,
                  Tab.normalizeURLForComparison(url) == Tab.normalizeURLForComparison(activeWebView.url) {
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
        var tabs: [Tab]? {
            didSet {
                guard let tabs else { return }
                downloadNavigationHistory.retainOnly(Set(tabs.map(\.id)))
            }
        }
        private var downloadDestinations: [WKDownload: URL] = [:]
        private var downloadTransferIds: [WKDownload: UUID] = [:]
        private var downloadProgressObservers: [WKDownload: NSKeyValueObservation] = [:]
        private var intentionallyPausedTransfers: Set<UUID> = []
        var lastRequestedURL: URL?
        private var downloadNavigationHistory = DownloadNavigationHistory()
        private var certificateOverrideWebViews: Set<ObjectIdentifier> = []
        private var agentNavigationObservationIDs: [ObjectIdentifier: UUID] = [:]
        private var agentLastNavigationURLs: [ObjectIdentifier: URL] = [:]
        private weak var contextMenuWebView: WKWebView?

        // One guard per WKWebView: background tabs and split panes must not
        // contribute to each other's redirect counts.
        private var redirectLoopGuards: [ObjectIdentifier: RedirectLoopGuard] = [:]

        // The load we issued for a web view that hasn't committed yet.
        // webView.url stays nil through the provisional phase, and
        // lastRequestedURL only tracks the *active* web view — so a burst of
        // SwiftUI updates during that window re-issued the same load over and
        // over, and past three the redirect-loop guard cancelled the
        // navigation and left the pane blank. A new split pane hit it every
        // time: gathering the panes reorders tabs, which churns the view.
        private var inFlightLoads: [ObjectIdentifier: URL] = [:]

        func loadInFlight(for webView: WKWebView) -> URL? {
            inFlightLoads[ObjectIdentifier(webView)]
        }

        func beginLoad(_ url: URL, in webView: WKWebView) {
            inFlightLoads[ObjectIdentifier(webView)] = url
        }

        private func endLoad(in webView: WKWebView) {
            inFlightLoads.removeValue(forKey: ObjectIdentifier(webView))
        }

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

        private func publishAgentSignal(_ draft: WebKitAgentSignalDraft, from webView: WKWebView) {
            guard let tabID = parent.webViewManager?.tabId(for: webView) else { return }
            Task {
                await BrowserAgentWebKitSignalRuntime.shared.publish(draft, tabID: tabID)
            }
        }

        private func agentObservationID(for webView: WKWebView) -> UUID {
            let key = ObjectIdentifier(webView)
            if let existing = agentNavigationObservationIDs[key] { return existing }
            let created = UUID()
            agentNavigationObservationIDs[key] = created
            return created
        }

        private func agentTLSState(for webView: WKWebView, url: URL?) -> WebKitAgentTLSState {
            switch url?.scheme?.lowercased() {
            case "https":
                if certificateOverrideWebViews.contains(ObjectIdentifier(webView)) { return .userOverridden }
                return webView.hasOnlySecureContent ? .secure : .insecure
            case "http":
                return .insecure
            case .some:
                return .notApplicable
            case nil:
                return .unknown
            }
        }

        private func publishAgentNavigationFailure(_ error: Error, from webView: WKWebView) {
            let nsError = error as NSError
            let includeText = UserDefaults.standard.bool(forKey: "agentWebKitDiagnosticContentEnabled")
            publishAgentSignal(
                .navigation(.init(
                    observationID: agentObservationID(for: webView),
                    phase: .failed,
                    url: webView.url,
                    tlsState: agentTLSState(for: webView, url: webView.url),
                    isMainFrame: true
                )),
                from: webView
            )
            publishAgentSignal(
                .resourceFailure(.init(
                    observationID: UUID(),
                    surface: .mainNavigationDelegate,
                    url: webView.url,
                    errorDomain: nsError.domain,
                    errorCode: nsError.code,
                    errorDescription: includeText ? nsError.localizedDescription : ""
                )),
                from: webView
            )
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            certificateOverrideWebViews.remove(ObjectIdentifier(webView))
            if let tabId = parent.webViewManager?.tabId(for: webView) {
                TabInsights.shared.loadStarted(tabId)
            }
            if isActiveWebView(webView) {
                NotificationCenter.default.post(name: .browserAutofillDismissed, object: nil)
            }
            let key = ObjectIdentifier(webView)
            agentNavigationObservationIDs[key] = UUID()
            if let url = webView.url { agentLastNavigationURLs[key] = url }
            publishAgentSignal(
                .navigation(.init(
                    observationID: agentObservationID(for: webView),
                    phase: .provisionalStarted,
                    url: webView.url,
                    tlsState: agentTLSState(for: webView, url: webView.url),
                    isMainFrame: true
                )),
                from: webView
            )
            publishAgentSignal(
                .pageLifecycle(.init(phase: .loadStarted, url: webView.url)),
                from: webView
            )
            tab(for: webView)?.securityLevel = .none
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

        func webView(
            _ webView: WKWebView,
            didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
        ) {
            let key = ObjectIdentifier(webView)
            let previousURL = agentLastNavigationURLs[key]
            publishAgentSignal(
                .navigation(.init(
                    observationID: agentObservationID(for: webView),
                    phase: .serverRedirectObserved,
                    url: webView.url,
                    redirectSourceURL: previousURL,
                    tlsState: agentTLSState(for: webView, url: webView.url),
                    isMainFrame: true
                )),
                from: webView
            )
            if let url = webView.url { agentLastNavigationURLs[key] = url }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            endLoad(in: webView)
            publishAgentSignal(
                .navigation(.init(
                    observationID: agentObservationID(for: webView),
                    phase: .committed,
                    url: webView.url,
                    tlsState: agentTLSState(for: webView, url: webView.url),
                    isMainFrame: true
                )),
                from: webView
            )
            publishAgentSignal(
                .pageLifecycle(.init(phase: .contentCommitted, url: webView.url)),
                from: webView
            )
            // Old document is gone and the new one hasn't painted: hold the view
            // invisible until it has, so the gap isn't a flash of white.
            parent.webViewManager?.beginFadeIn(webView)
            // Push the current spacebar-scroll percentage into the new page;
            // the injected user script reads it on each keypress
            let pct = UserDefaults.standard.object(forKey: "spaceScrollPercent") as? Double ?? 90
            webView.evaluateJavaScript("window.__subSpacePct = \(pct)")
            if let tab = tab(for: webView) {
                // The search URL is known here, so a recipe/memory hit can open the
                // pane already — racing the search results' own load.
                parent.fastForward?.pageCommitted(webView: webView, tab: tab)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            publishAgentSignal(
                .navigation(.init(
                    observationID: agentObservationID(for: webView),
                    phase: .finished,
                    url: webView.url,
                    tlsState: agentTLSState(for: webView, url: webView.url),
                    isMainFrame: true
                )),
                from: webView
            )
            publishAgentSignal(
                .pageLifecycle(.init(phase: .loadCompleted, url: webView.url)),
                from: webView
            )
            if let url = webView.url { agentLastNavigationURLs[ObjectIdentifier(webView)] = url }
            parent.webViewManager?.revealPage(webView)  // backstop: content that never pings
            if isActiveWebView(webView) {
                parent.isLoading = false
                parent.hasRenderedContent = true
                parent.canGoBack = webView.canGoBack
                parent.canGoForward = webView.canGoForward
                parent.title = webView.title ?? ""
            }

            // Track the last real page separately for every tab. Download
            // navigations are provisional and must restore their owning tab.
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
                    Logger.log("WebView didFinish: updating tab URL to \(currentURL.absoluteString)", type: "WebView")
                    tab.url = currentURL
                }

                // Start the settle clock for research capture. Nothing happens
                // for tabs outside a workspace, and any further navigation
                // restarts it — see WorkspaceSettleCapture.
                tabManager?.notePageFinished(tab: tab, webView: webView, tabs: tabs ?? [])

                // Record the visit for omnibar suggestions; WKWebView owns back/forward
                if tab.historyStrings.last != currentURL.absoluteString {
                    tab.historyStrings.append(currentURL.absoluteString)

                    // Limit history size
                    let maxHistorySize = SettingsManager.shared.maxHistorySize
                    if tab.historyStrings.count > maxHistorySize {
                        tab.historyStrings.removeFirst(tab.historyStrings.count - maxHistorySize)
                    }
                }

                // Cross-tab visit frequency for omnibar nicknames ("gmail" ->
                // mail.google.com). Incognito never contributes — that's the point of it.
                if tab.sessionKind != .incognito {
                    SiteHistory.shared.record(url: currentURL, title: webView.title)
                }
                BrowsingHistoryStore.shared.record(
                    url: currentURL,
                    title: webView.title,
                    sessionKind: tab.sessionKind
                )

                // Notify parent of URL change to update stable URL
                parent.onURLChange?(currentURL)
            }

            if let tabId = parent.webViewManager?.tabId(for: webView) {
                TabInsights.shared.loadFinished(tabId)
            }

            // Load favicon for the current page
            loadFavicon(for: webView)
            if let tab = tab(for: webView) { TabSync.captureCacheState(from: webView, into: tab) }

            // Async and JS-driven only (see translateScript) - can't interfere
            // with interactivity the way the removed injection below did.
            parent.pageTranslator?.maybeAutoTranslate(webView: webView)

            // Pulse a fast-forwarded pane, or scrape the results the recipe table missed.
            if let tab = tab(for: webView) {
                parent.fastForward?.pageFinished(webView: webView, tab: tab)
            }

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
            guard let tab = tab(for: webView) else {
                generateDomainInitial(for: webView)
                return
            }
            let scope = FaviconCacheScope.forTab(tab)
            if let cachedData = FaviconCache.shared.getFavicon(
                for: url,
                scope: scope
            ) {
                setFavicon(cachedData, for: webView)
                return
            }

            let expectedPageURL = webView.url
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                let data = await FaviconLoadingPolicy.load(from: url, in: webView)
                guard webView.url == expectedPageURL,
                      let data,
                      NSImage(data: data) != nil else {
                    self.generateDomainInitial(for: webView)
                    return
                }
                _ = FaviconCache.shared.setFavicon(
                    data,
                    for: url,
                    scope: scope
                )
                self.setFavicon(data, for: webView)
            }
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

        nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
            let transfer = MainActorKVOChange(object: object, change: change)
            Task { @MainActor in
                let object = transfer.object
                if keyPath == "estimatedProgress", let webView = object as? WKWebView {
                    // Only the focused tab drives the chrome progress bar; a
                    // background split pane loading shouldn't wiggle it.
                    if self.isActiveWebView(webView) {
                        self.parent.progressValue = webView.estimatedProgress
                    }
                } else if keyPath == #keyPath(WKWebView.url), let webView = object as? WKWebView {
                    // The page changed its own URL (pushState/replaceState/hash) -
                    // no delegate callback fires for these. Sync the tab, or the
                    // next view update sees tab != webview and re-loads the stale
                    // URL: the "page randomly reloads a few seconds after loading"
                    // bug. Deliberately leaves downloadNavigationHistory alone -
                    // the download path needs it pointing at the last real page.
                    guard let newURL = webView.url else { return }
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
            publishAgentNavigationFailure(error, from: webView)
            parent.webViewManager?.revealPage(webView)  // don't leave a failed load invisible
            parent.isLoading = false
            Logger.log("WebView navigation failed: \(error.localizedDescription)", type: "WebView")
            Logger.log("Error domain: \(error._domain), code: \((error as NSError).code)", type: "WebView")
            // Reset lastRequestedURL on failure so we can retry
            Logger.log("WebView didFail: resetting lastRequestedURL to nil", type: "WebView")
            lastRequestedURL = nil
            endLoad(in: webView)
            if (error as NSError).code != NSURLErrorCancelled {
                resetRedirectLoopGuard(for: webView)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            publishAgentNavigationFailure(error, from: webView)
            parent.isLoading = false
            Logger.log("WebView provisional navigation failed: \(error.localizedDescription)", type: "WebView")
            Logger.log("Error domain: \(error._domain), code: \((error as NSError).code)", type: "WebView")
            if let url = webView.url {
                Logger.log("Failed URL: \(url.absoluteString)", type: "WebView")
            }
            // Reset lastRequestedURL on failure so we can retry
            Logger.log("WebView didFailProvisionalNavigation: resetting lastRequestedURL to nil", type: "WebView")
            lastRequestedURL = nil
            endLoad(in: webView)
            if (error as NSError).code != NSURLErrorCancelled {
                resetRedirectLoopGuard(for: webView)
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            endLoad(in: webView)
            publishAgentSignal(
                .pageLifecycle(.init(
                    phase: .webContentProcessTerminated,
                    url: webView.url
                )),
                from: webView
            )
        }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // Handle SSL certificate validation
            handleAuthenticationChallenge(challenge, for: webView, completionHandler: completionHandler)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
            // <a download> links
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download, preferences)
                return
            }

            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                let mods = navigationAction.modifierFlags

                // Shift+click files the destination in Newspaper without
                // navigating away. The owning ContentView performs capture in
                // the source tab's browsing context and supplies the flight cue.
                if mods.intersection([.command, .shift, .option, .control]) == .shift {
                    parent.onSaveLinkToNewspaper?(url, webView)
                    decisionHandler(.cancel, preferences)
                    return
                }

                // Option+click opens beside the source. This replaces the old
                // option-download default; explicit download links and the
                // context menu continue to use WebKit's download path.
                if mods.intersection([.command, .shift, .option, .control]) == .option {
                    let sourceTabId = parent.webViewManager?.tabId(for: webView)
                    let context = sourceTabId
                        .flatMap { id in tabs?.first(where: { $0.id == id })?.browsingContext }
                        ?? .normalWebKit
                    if let newTab = tabManager?.createTab(inheriting: context, url: url, select: false) {
                        if let sourceTabId { tabManager?.selectedTabId = sourceTabId }
                        if (tabManager?.splitTabIds.count ?? 0) < TabManager.maxSplitTabs {
                            tabManager?.toggleSplitMembership(newTab, tabs: (tabs ?? []) + [newTab])
                        } else {
                            tabManager?.selectedTabId = newTab.id
                        }
                    }
                    decisionHandler(.cancel, preferences)
                    return
                }

                // Cmd+click: open in a new tab (background; add Shift to focus it)
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

            }

            // Settings toggle; unset means enabled. Per-navigation is the path
            // WebKit actually honors - defaultWebpagePreferences on the
            // configuration doesn't reliably stick.
            preferences.allowsContentJavaScript =
                UserDefaults.standard.object(forKey: "javaScriptEnabled") == nil
                || UserDefaults.standard.bool(forKey: "javaScriptEnabled")

            if navigationAction.navigationType != .other {
                resetRedirectLoopGuard(for: webView)
            }
            if let url = navigationAction.request.url,
               shouldBlockRedirect(to: url, in: webView) {
                Logger.log("WebView: Cancelled redirect loop at \(url.absoluteString)", type: "WebView")
                if isActiveWebView(webView) {
                    parent.isLoading = false
                }
                decisionHandler(.cancel, preferences)
                return
            }

            decisionHandler(.allow, preferences)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
            let response = navigationResponse.response
            let httpResponse = response as? HTTPURLResponse
            publishAgentSignal(
                .navigation(.init(
                    observationID: agentObservationID(for: webView),
                    phase: .responseReceived,
                    url: response.url ?? webView.url,
                    statusCode: httpResponse?.statusCode,
                    mimeType: response.mimeType,
                    canShowMIMEType: navigationResponse.canShowMIMEType,
                    tlsState: agentTLSState(for: webView, url: response.url ?? webView.url),
                    isMainFrame: navigationResponse.isForMainFrame
                )),
                from: webView
            )
            // Anything WebKit can't render inline (zip, dmg, attachments…) is a download
            if !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
                return
            }

            decisionHandler(.allow)
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

        func track(_ download: WKDownload, from webView: WKWebView, transferId existingId: UUID? = nil) {
            guard let tabId = parent.webViewManager?.tabId(for: webView) else { return }
            download.delegate = self
            let privacy: FileTransferPrivacy =
                parent.webViewManager?.isPrivateTab(tabId) == true ? .privateSession : .standard
            let transferId = existingId ?? DownloadManager.shared.beginDownload(
                tabId: tabId,
                source: download.originalRequest?.url,
                privacy: privacy
            )
            downloadTransferIds[download] = transferId
            publishAgentSignal(
                .download(.init(
                    downloadID: transferId,
                    phase: .started,
                    sourceURL: download.originalRequest?.url
                )),
                from: webView
            )
            downloadProgressObservers[download] = download.progress.observe(
                \.fractionCompleted,
                options: [.initial, .new]
            ) { [weak self, weak download, weak webView] _, change in
                guard let progress = change.newValue else { return }
                Task { @MainActor in
                    DownloadManager.shared.update(transferId, progress: progress)
                    guard let self, let download, let webView else { return }
                    let completed = download.progress.completedUnitCount
                    let expected = download.progress.totalUnitCount
                    self.publishAgentSignal(
                        .download(.init(
                            downloadID: transferId,
                            phase: .progress,
                            sourceURL: download.originalRequest?.url,
                            progress: progress,
                            receivedBytes: completed >= 0 ? UInt64(completed) : nil,
                            expectedBytes: expected >= 0 ? UInt64(expected) : nil
                        )),
                        from: webView
                    )
                }
            }
            DownloadManager.shared.setPauseHandler(transferId) { [weak self, weak download, weak webView] in
                guard let self, let download, let webView else { return }
                self.pause(download, transferId: transferId, webView: webView)
            }
        }

        private func pause(_ download: WKDownload, transferId: UUID, webView: WKWebView) {
            intentionallyPausedTransfers.insert(transferId)
            let request = download.originalRequest
            download.cancel { [weak self, weak webView] resumeData in
                guard let self, let webView else { return }
                self.cleanup(download)
                let canRestart = resumeData != nil || request != nil
                if canRestart {
                    DownloadManager.shared.setRestartHandler(transferId) { [weak self, weak webView] in
                        guard let self, let webView else { return }
                        self.restart(transferId: transferId, resumeData: resumeData, request: request, webView: webView)
                    }
                }
                DownloadManager.shared.markPaused(transferId, canResume: canRestart)
                self.intentionallyPausedTransfers.remove(transferId)
            }
        }

        private func restart(transferId: UUID, resumeData: Data?, request: URLRequest?, webView: WKWebView) {
            DownloadManager.shared.markRestarting(transferId)
            let attach: @MainActor @Sendable (WKDownload) -> Void = { [weak self, weak webView] resumedDownload in
                guard let self, let webView else { return }
                self.track(resumedDownload, from: webView, transferId: transferId)
            }
            if let resumeData {
                webView.resumeDownload(fromResumeData: resumeData, completionHandler: attach)
            } else if let request {
                webView.startDownload(using: request, completionHandler: attach)
            }
        }

        private func cleanup(_ download: WKDownload) {
            downloadProgressObservers.removeValue(forKey: download)?.invalidate()
            downloadTransferIds.removeValue(forKey: download)
            downloadDestinations.removeValue(forKey: download)
        }

        // A download is not a navigation. If the tab's URL points at the file
        // (omnibar/CLI navigation straight to a zip), snap it back to the last
        // page that actually loaded - otherwise updateNSView sees tab != webview
        // and re-requests the file on every view update, downloading it forever.
        // Note: webView.url is unusable here - it still holds the provisional
        // (file) URL until the cancelled navigation unwinds.
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
            let configuredPath = UserDefaults.standard.string(forKey: "downloadsFolder") ?? ""
            let defaultFolder = FileManager.default.urls(
                for: .downloadsDirectory,
                in: .userDomainMask
            )[0]
            let folder = configuredPath.isEmpty
                ? defaultFolder
                : DownloadFolderAccess.shared.configuredFolder() ?? defaultFolder

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
            if let transferId = downloadTransferIds[download] {
                DownloadManager.shared.setDestination(transferId, url: destination, suggestedFilename: suggestedFilename)
                if let webView = download.webView {
                    publishAgentSignal(
                        .download(.init(
                            downloadID: transferId,
                            phase: .destinationSelected,
                            sourceURL: download.originalRequest?.url,
                            suggestedFilename: UserDefaults.standard.bool(
                                forKey: "agentWebKitDiagnosticContentEnabled"
                            ) ? suggestedFilename : nil
                        )),
                        from: webView
                    )
                }
            }
            Logger.log("Download starting: \(destination.path)", type: "WebView")
            completionHandler(destination)
        }

        func downloadDidFinish(_ download: WKDownload) {
            let transferId = downloadTransferIds[download]
            if let transferId, let webView = download.webView {
                publishAgentSignal(
                    .download(.init(
                        downloadID: transferId,
                        phase: .completed,
                        sourceURL: download.originalRequest?.url,
                        progress: 1
                    )),
                    from: webView
                )
            }
            if let url = downloadDestinations[download] {
                Logger.log("Download finished: \(url.path)", type: "WebView")
                if let transferId {
                    DownloadManager.shared.finish(transferId, at: url)
                }
                // Reveal in Finder is the immediate "it's done" feedback; the
                // browsable history lives in the Downloads window (File ▸ Show Downloads).
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            cleanup(download)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            guard let transferId = downloadTransferIds[download] else {
                cleanup(download)
                return
            }
            if intentionallyPausedTransfers.contains(transferId) {
                if let webView = download.webView {
                    publishAgentSignal(
                        .download(.init(
                            downloadID: transferId,
                            phase: .cancelled,
                            sourceURL: download.originalRequest?.url
                        )),
                        from: webView
                    )
                }
                Logger.log("Download paused: \(error.localizedDescription)", type: "WebView")
                return
            }
            let request = download.originalRequest
            let webView = download.webView
            if let webView {
                let nsError = error as NSError
                publishAgentSignal(
                    .download(.init(
                        downloadID: transferId,
                        phase: .failed,
                        sourceURL: request?.url,
                        errorDomain: nsError.domain,
                        errorCode: nsError.code,
                        errorDescription: UserDefaults.standard.bool(
                            forKey: "agentWebKitDiagnosticContentEnabled"
                        ) ? nsError.localizedDescription : nil
                    )),
                    from: webView
                )
            }
            cleanup(download)
            if resumeData != nil || request != nil, let webView {
                DownloadManager.shared.setRestartHandler(transferId) { [weak self, weak webView] in
                    guard let self, let webView else { return }
                    self.restart(transferId: transferId, resumeData: resumeData, request: request, webView: webView)
                }
            }
            DownloadManager.shared.markFailed(transferId, error: error, canRestart: resumeData != nil || request != nil)
            Logger.log("Download failed: \(error.localizedDescription)", type: "WebView")
        }

        private func handleAuthenticationChallenge(
            _ challenge: URLAuthenticationChallenge,
            for webView: WKWebView,
            completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
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
                        tab(for: webView)?.securityLevel = .insecure
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
                                self.certificateOverrideWebViews.insert(ObjectIdentifier(webView))
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
            let sourceTabId = webViewManager.tabId(for: webView)
            let openerContext = sourceTabId
                .flatMap { id in tabs?.first(where: { $0.id == id })?.browsingContext }
                ?? .normalWebKit
            // A clicked target="_blank" link (.linkActivated) is a plain "open in a new
            // tab" — the vast majority of these — so give it a normal foreground tab.
            // Only a JS window.open() popup (.other: OAuth consent, a payment sheet)
            // joins the opener in a split: a popup that hides the page that opened it
            // reads as "nothing happened", so opener and popup both stay on screen.
            let isPopup = navigationAction.navigationType != .linkActivated
            let newTab = tabManager.createTab(inheriting: openerContext, select: false)
            webViewManager.adoptWebView(
                popupWebView,
                for: newTab.id,
                navigationDelegate: self,
                uiDelegate: self
            )
            // ponytail: pairs with the *focused* tab, which is the opener in every case
            // except a popup fired from a background pane — rare enough not to track
            // opener identity for. At the 4-pane cap there's no room, so just focus it.
            if isPopup {
                if tabManager.splitTabIds.count < TabManager.maxSplitTabs {
                    tabManager.toggleSplitMembership(newTab, tabs: tabs ?? [])
                } else {
                    tabManager.selectedTabId = newTab.id
                }
            } else {
                tabManager.presentAutomaticallyOpenedLink(
                    newTab,
                    from: sourceTabId,
                    tabs: tabs ?? []
                )
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
            // The page closed itself; the user did not reject the source.
            tabManager.closeTab(tab, tabs: tabs ?? [], reason: .housekeeping)
        }

        // Keep WebKit's comprehensive native menu, then add Browser's own link
        // action and SF Symbols. The page-world context listener in
        // WebViewManager records the clicked href before this delegate fires.
        func webView(_ webView: WKWebView, willOpenMenu menu: NSMenu, with event: NSEvent) {
            for item in menu.items where item.title == "Open Link in New Window" {
                item.title = "Open Link in New Tab"
            }

            if let url = parent.webViewManager?.contextMenuLink(for: webView),
               !menu.items.contains(where: { $0.action == #selector(addContextLinkToNewspaper(_:)) }) {
                contextMenuWebView = webView
                let newspaperItem = NSMenuItem(
                    title: "Add Link to Newspaper",
                    action: #selector(addContextLinkToNewspaper(_:)),
                    keyEquivalent: ""
                )
                newspaperItem.target = self
                newspaperItem.representedObject = url
                newspaperItem.image = menuImage(named: "newspaper", description: newspaperItem.title)
                newspaperItem.isEnabled = tab(for: webView)?.sessionKind != .incognito

                let lastOpenLinkIndex = menu.items.lastIndex {
                    $0.title.localizedCaseInsensitiveContains("open link")
                }
                let insertionIndex = min((lastOpenLinkIndex.map { $0 + 1 } ?? 0), menu.items.count)
                menu.insertItem(newspaperItem, at: insertionIndex)
            }

            // Anchor the page selection into the active workspace's current
            // document (Phase 2). Only offered inside a workspace — outside one
            // there is nothing to anchor into.
            if tabManager?.activeWorkspaceId != nil,
               tab(for: webView)?.sessionKind != .incognito,
               !menu.items.contains(where: { $0.action == #selector(anchorSelectionFromContextMenu(_:)) }) {
                let anchorItem = NSMenuItem(
                    title: String(localized: "Anchor Selection to Document"),
                    action: #selector(anchorSelectionFromContextMenu(_:)),
                    keyEquivalent: ""
                )
                anchorItem.target = self
                anchorItem.image = menuImage(named: "link.badge.plus", description: anchorItem.title)
                let copyIndex = menu.items.firstIndex { $0.title.localizedCaseInsensitiveContains("copy") }
                menu.insertItem(anchorItem, at: copyIndex ?? menu.items.count)
            }

            // In-place translation of just the selected text (WebKit's own
            // "Translate" item opens the system popover instead).
            if parent.pageTranslator != nil,
               parent.webViewManager?.contextMenuHasSelection(for: webView) == true,
               !menu.items.contains(where: { $0.action == #selector(translateSelectionFromContextMenu(_:)) }) {
                contextMenuWebView = webView
                let translateItem = NSMenuItem(
                    title: String(localized: "Translate Selection in Place"),
                    action: #selector(translateSelectionFromContextMenu(_:)),
                    keyEquivalent: ""
                )
                translateItem.target = self
                translateItem.image = menuImage(named: "character.bubble", description: translateItem.title)
                let lookUpIndex = menu.items.firstIndex { $0.title.localizedCaseInsensitiveContains("look up") }
                menu.insertItem(translateItem, at: lookUpIndex.map { $0 + 1 } ?? 0)
            }

            decorateMenu(menu)
        }

        @objc private func translateSelectionFromContextMenu(_ sender: NSMenuItem) {
            guard let webView = contextMenuWebView else { return }
            parent.pageTranslator?.translateSelection(webView: webView)
        }

        @objc private func anchorSelectionFromContextMenu(_ sender: NSMenuItem) {
            NotificationCenter.default.post(name: .browserAnchorSelection, object: nil)
        }

        @objc private func addContextLinkToNewspaper(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL,
                  let webView = contextMenuWebView else { return }
            parent.onSaveLinkToNewspaper?(url, webView)
        }

        private func decorateMenu(_ menu: NSMenu) {
            for item in menu.items where !item.isSeparatorItem {
                if item.image == nil {
                    item.image = menuImage(
                        named: menuSymbolName(for: item.title),
                        description: item.title
                    )
                }
                if let submenu = item.submenu { decorateMenu(submenu) }
            }
        }

        private func menuImage(named name: String, description: String) -> NSImage? {
            let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
            image?.isTemplate = true
            return image
        }

        private func menuSymbolName(for title: String) -> String {
            let title = title.lowercased()
            if title.contains("newspaper") { return "newspaper" }
            if title.contains("new tab") || title.contains("open link") { return "plus.square.on.square" }
            if title.contains("new window") { return "macwindow.badge.plus" }
            if title.contains("download") { return "arrow.down.circle" }
            if title.contains("copy") { return "doc.on.doc" }
            if title.contains("share") { return "square.and.arrow.up" }
            if title.contains("image") { return "photo" }
            if title.contains("search") || title.contains("find") { return "magnifyingglass" }
            if title.contains("look up") || title.contains("dictionary") { return "book" }
            if title.contains("translat") { return "character.bubble" }
            if title.contains("inspect") { return "cursorarrow.rays" }
            if title.contains("reload") { return "arrow.clockwise" }
            if title.contains("back") { return "chevron.backward" }
            if title.contains("forward") { return "chevron.forward" }
            if title.contains("print") { return "printer" }
            if title.contains("save") { return "square.and.arrow.down" }
            if title.contains("open") { return "arrow.up.forward.square" }
            return "ellipsis.circle"
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

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
            let dialogID = UUID()
            let includeText = UserDefaults.standard.bool(forKey: "agentWebKitDiagnosticContentEnabled")
            publishAgentSignal(
                .dialog(.init(
                    dialogID: dialogID,
                    phase: .presented,
                    kind: .alert,
                    message: includeText ? message : nil
                )),
                from: webView
            )
            let alert = makeDialogAlert(message: message, frame: frame)
            alert.addButton(withTitle: String(localized: "OK"))
            presentSheet(alert, over: webView) { [weak self, weak webView] _ in
                if let self, let webView {
                    self.publishAgentSignal(
                        .dialog(.init(dialogID: dialogID, phase: .dismissed, kind: .alert)),
                        from: webView
                    )
                }
                completionHandler()
            }
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
            let dialogID = UUID()
            let includeText = UserDefaults.standard.bool(forKey: "agentWebKitDiagnosticContentEnabled")
            publishAgentSignal(
                .dialog(.init(
                    dialogID: dialogID,
                    phase: .presented,
                    kind: .confirm,
                    message: includeText ? message : nil
                )),
                from: webView
            )
            let alert = makeDialogAlert(message: message, frame: frame)
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            presentSheet(alert, over: webView) { [weak self, weak webView] response in
                if let self, let webView {
                    self.publishAgentSignal(
                        .dialog(.init(dialogID: dialogID, phase: .dismissed, kind: .confirm)),
                        from: webView
                    )
                }
                completionHandler(response == .alertFirstButtonReturn)
            }
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
            let dialogID = UUID()
            let includeText = UserDefaults.standard.bool(forKey: "agentWebKitDiagnosticContentEnabled")
            publishAgentSignal(
                .dialog(.init(
                    dialogID: dialogID,
                    phase: .presented,
                    kind: .prompt,
                    message: includeText ? prompt : nil,
                    defaultText: includeText ? defaultText : nil
                )),
                from: webView
            )
            let alert = makeDialogAlert(message: prompt, frame: frame)
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            input.stringValue = defaultText ?? ""
            alert.accessoryView = input
            alert.window.initialFirstResponder = input
            presentSheet(alert, over: webView) { [weak self, weak webView] response in
                if let self, let webView {
                    self.publishAgentSignal(
                        .dialog(.init(dialogID: dialogID, phase: .dismissed, kind: .prompt)),
                        from: webView
                    )
                }
                completionHandler(response == .alertFirstButtonReturn ? input.stringValue : nil)
            }
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

            let tabId = parent.webViewManager?.tabId(for: webView)
            let isPrivate = tabId.map {
                parent.webViewManager?.isPrivateTab($0) == true
            } ?? false
            let capabilities = kinds
                .sorted { $0.rawValue < $1.rawValue }
                .map(\.title)
                .joined(separator: String(localized: " and "))
                .lowercased()
            let alert = NSAlert()
            alert.messageText = String(
                localized: "Allow \(originKey) to use \(capabilities)?"
            )
            alert.informativeText = isPrivate
                ? String(localized: "This choice applies only to this private session.")
                : String(localized: "You can revoke this choice in Privacy settings.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "Allow"))
            alert.addButton(withTitle: String(localized: "Block"))
            presentSheet(alert, over: webView) { response in
                let decision: SitePermissionDecision =
                    response == .alertFirstButtonReturn ? .allowed : .denied
                if !isPrivate {
                    SitePermissionStore.shared.set(
                        decision,
                        for: kinds,
                        origin: originKey
                    )
                }
                decisionHandler(decision.webKitDecision)
            }
        }

        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            let site = webView.url
            let tabId = parent.webViewManager?.tabId(for: webView)
            let isPrivate = tabId.map { parent.webViewManager?.isPrivateTab($0) == true } ?? false
            let finish: (NSApplication.ModalResponse) -> Void = { response in
                let urls = response == .OK ? panel.urls : nil
                let privacy: FileTransferPrivacy = isPrivate ? .privateSession : .standard
                urls?.forEach {
                    DownloadManager.shared.record($0, kind: .upload, source: site, privacy: privacy)
                }
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
    // Workspace document panes displayed beside (or instead of) web views
    // (ADR 0008). The provider decides which pane ids are documents; it must be
    // consulted BEFORE getWebView, which creates a web view as a side effect.
    var documentPaneProvider: ((UUID) -> NSView?)?
    private var visibleDocumentViews: Set<NSView> = []

    /// The view behind one pane id: a document editor, or the tab's web view.
    private func paneView(for id: UUID) -> NSView? {
        if let documentView = documentPaneProvider?(id) { return documentView }
        return webViewManager?.getWebView(for: id)
    }

    // Split pane geometry. colFractions are per-column width fractions for 2–3
    // panes; for the 2×2 grid it's [leftColumnFraction] plus rowFraction (top row).
    // Reset to equal whenever membership changes; deliberately not persisted.
    private var colFractions: [CGFloat] = []
    private var rowFraction: CGFloat = 0.5
    private var dividers: [PaneDivider] = []
    private var clickMonitor: Any?
    // Clicking inside a non-focused pane moves focus there (sets selectedTabId).
    var onPaneFocus: ((UUID) -> Void)?

    // Page white point, 100 = untouched. Below 100, a black veil at
    // (100 - whitePoint)% composites as a plain multiply: white drops to the
    // chosen level, black text doesn't move at all, and midtones — most body
    // text — shift about half as far. Above 100 (extended range only) the same
    // veil turns into added light. It sits over the web views rather than inside
    // the page, so it covers PDFs and error pages too and can't break a site's
    // layout the way an injected CSS filter would. ponytail: linear multiply,
    // not a tone curve; swap in a shaped CIFilter if highlights need rolloff.
    var whitePoint: Double = 100 {
        didSet {
            guard whitePoint != oldValue else { return }
            let amount = abs(whitePoint - 100) / 100
            if whitePoint < 100 {
                whiteOverlay.set(NSColor.black.withAlphaComponent(CGFloat(min(amount, 1))), filter: nil)
            } else {
                whiteOverlay.set(NSColor.white.withAlphaComponent(CGFloat(min(amount, 1))),
                                 filter: CIFilter(name: "CIAdditionCompositing"))
            }
        }
    }

    // Page black point, 0 = untouched. Positive adds light everywhere, so black
    // lifts to grey (whites are already clipped and barely move). Negative
    // subtracts via linear burn — out = page - amount — so near-blacks clip to
    // true black while white only dips a little.
    var blackPoint: Double = 0 {
        didSet {
            guard blackPoint != oldValue else { return }
            let amount = CGFloat(min(abs(blackPoint) / 100, 1))
            if blackPoint > 0 {
                blackOverlay.set(NSColor.white.withAlphaComponent(amount),
                                 filter: CIFilter(name: "CIAdditionCompositing"))
            } else if let burn = CIFilter(name: "CILinearBurnBlendMode") {
                // Opaque grey — linear burn needs the full source colour, and the
                // filter is what keeps it from just painting over the page.
                blackOverlay.set(NSColor(white: 1 - amount, alpha: 1), filter: burn)
            } else {
                blackOverlay.set(.clear, filter: nil)
            }
        }
    }

    private let whiteOverlay = ToneOverlay()
    private let blackOverlay = ToneOverlay()

    var activeWebView: WKWebView? {
        // The WebView for the focused tab, not necessarily the manager's
        // activeWebView. Reads through pendingDisplay: setDisplayedTabs applies a
        // runloop hop late, but updateNSView reads this back inside the same pass
        // to pick which web view to load the tab's URL into. Answering with the
        // *previous* focus there loaded the newly selected tab's page into the
        // old tab's web view — the "tabs showing each other's pages" bug.
        if let focusedTabId = pendingDisplay?.focused ?? focusedTabId, let webViewManager = webViewManager {
            // A focused document pane has no web view — and asking getWebView
            // for one would create it as a side effect.
            if documentPaneProvider?(focusedTabId) != nil { return nil }
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
        // A pane genuinely joining/leaving/reordering (not the first-ever
        // layout, not a live drag or window resize) is the only case worth
        // animating — those other call sites need frames to track 1:1.
        let paneShapeChanged = !displayedTabIds.isEmpty && displayedTabIds != ids
        if displayedTabIds != ids {
            displayedTabIds = ids
            resetFractions()
        }
        self.focusedTabId = focusedTabId

        // Update the WebViewManager's active tab (the focused pane) — unless a
        // document owns focus, in which case no tab is "active" for web chrome.
        let focusedIsDocument = focusedTabId.map { documentPaneProvider?($0) != nil } ?? false
        webViewManager?.setActiveTab(focusedIsDocument ? nil : focusedTabId)

        // Hide all currently visible panes
        for webView in visibleWebViews {
            webView.isHidden = true
        }
        visibleWebViews.removeAll()
        for documentView in visibleDocumentViews {
            documentView.isHidden = true
        }
        visibleDocumentViews.removeAll()

        guard !ids.isEmpty, let webViewManager = webViewManager else {
            Logger.log("WebViewContainer setDisplayedTabs: no tabs or webViewManager", type: "WebView")
            return
        }

        for id in ids {
            if let documentView = documentPaneProvider?(id) {
                attachPane(documentView)
                documentView.isHidden = false
                visibleDocumentViews.insert(documentView)
                documentView.layer?.borderWidth = (ids.count > 1 && id == focusedTabId) ? 2 : 0
                documentView.layer?.borderColor = NSColor.controlAccentColor.cgColor
                continue
            }
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

        layoutPanes(animated: paneShapeChanged)

        // Give the page key focus so arrow keys / space / cmd+arrows scroll
        // it. Only on a real tab change (or when nothing has focus) so
        // routine SwiftUI updates don't steal focus from the omnibar.
        if let focusedTabId, let window = self.window, tabChanged || window.firstResponder === window {
            if let documentView = documentPaneProvider?(focusedTabId) {
                (documentView as? DocumentPaneView)?.focusEditor()
            } else {
                window.makeFirstResponder(webViewManager.getWebView(for: focusedTabId))
            }
        }
    }

    // A document pane joining this container: plain subview, frames owned by
    // layoutPanes. None of the web-view delegate/KVO setup applies.
    private func attachPane(_ view: NSView) {
        guard view.superview !== self else { return }
        view.autoresizingMask = []
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        addSubview(view)
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

    // `animated` covers a real join/leave/reorder of the split — callers on a
    // live divider drag or window resize always pass false, since animating
    // those would fight the cursor instead of tracking it.
    private func layoutPanes(animated: Bool = false) {
        // Keep the veils covering everything, and last in z-order — attach() and
        // ensureDividers() both append subviews above them. White point first,
        // black point on top: scale the page down, then shift it.
        for overlay in [whiteOverlay, blackOverlay] {
            overlay.frame = bounds
            if subviews.last !== overlay { addSubview(overlay, positioned: .above, relativeTo: nil) }
        }

        guard webViewManager != nil, !displayedTabIds.isEmpty else { return }
        let views = displayedTabIds.compactMap { paneView(for: $0) }
        guard views.count == displayedTabIds.count else { return }

        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.placePanes(views) { $0.animator() }
            }
        } else {
            placePanes(views) { $0 }
        }
    }

    private func placePanes(_ views: [NSView], target: (NSView) -> NSView) {
        let b = bounds

        if views.count == 4 {
            // Rigid 2×2 grid in reading order: dividers span the full grid.
            let leftWidth = floor(b.width * colFractions[0])
            let topHeight = floor(b.height * rowFraction)
            let topY = b.height - topHeight
            target(views[0]).frame = NSRect(x: 0, y: topY, width: leftWidth, height: topHeight)
            target(views[1]).frame = NSRect(x: leftWidth, y: topY, width: b.width - leftWidth, height: topHeight)
            target(views[2]).frame = NSRect(x: 0, y: 0, width: leftWidth, height: topY)
            target(views[3]).frame = NSRect(x: leftWidth, y: 0, width: b.width - leftWidth, height: topY)
            ensureDividers([true, false])
            dividers[0].frame = NSRect(x: leftWidth - 4, y: 0, width: 8, height: b.height)
            dividers[1].frame = NSRect(x: 0, y: topY - 4, width: b.width, height: 8)
        } else if views.count > 1 {
            // 2–3 vertical columns
            var x: CGFloat = 0
            for (index, view) in views.enumerated() {
                let width = index == views.count - 1 ? b.width - x : floor(b.width * colFractions[index])
                target(view).frame = NSRect(x: x, y: 0, width: width, height: b.height)
                x += width
            }
            ensureDividers(Array(repeating: true, count: views.count - 1))
            var edge: CGFloat = 0
            for (index, divider) in dividers.enumerated() {
                edge += floor(b.width * colFractions[index])
                divider.frame = NSRect(x: edge - 4, y: 0, width: 8, height: b.height)
            }
        } else {
            target(views[0]).frame = b
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
        guard displayedTabIds.count > 1, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        for id in displayedTabIds where id != focusedTabId {
            if paneView(for: id)?.frame.contains(point) == true {
                DispatchQueue.main.async { self.onPaneFocus?(id) }
                return
            }
        }
    }

    isolated deinit {
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

// The white-point veil. Transparent to the mouse so the page underneath still
// gets every click.
/// A pass-through veil over the web views: a flat colour composited onto whatever
/// is underneath, optionally through a Core Image blend filter.
final class ToneOverlay: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(_ color: NSColor, filter: CIFilter?) {
        layer?.compositingFilter = filter
        layer?.backgroundColor = color.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
