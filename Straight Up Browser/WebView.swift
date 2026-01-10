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
    var onPopupRequest: ((URL, WKWindowFeatures?) -> Void)?
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
         onPopupRequest: ((URL, WKWindowFeatures?) -> Void)?,
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
        self.onPopupRequest = onPopupRequest
        self.tabManager = tabManager
        self.tabs = tabs
        self.activeTabId = activeTabId
        self.onURLChange = onURLChange

        Logger.log("WebView init: activeTabId=\(activeTabId?.uuidString ?? "nil")", type: "WebView")
    }

    func makeNSView(context: Context) -> WebViewContainer {
        Logger.log("WebView makeNSView called for activeTabId: \(activeTabId?.uuidString ?? "nil")", type: "WebView")
        let container = WebViewContainer(webViewManager: webViewManager, coordinator: context.coordinator)

        // Add observer for progress changes - we'll add this to the container
        container.addObserver(context.coordinator, forKeyPath: "estimatedProgress", options: .new, context: nil)

        return container
    }

    static func dismantleNSView(_ nsView: WebViewContainer, coordinator: Coordinator) {
        // Clean up observers
        nsView.removeObserver(coordinator, forKeyPath: "estimatedProgress")
    }

    // Get the current active web view from the manager
    private func getCurrentWebView() -> WKWebView {
        Logger.log("WebView getCurrentWebView called with activeTabId: \(activeTabId?.uuidString ?? "nil")", type: "WebView")
        if let activeTabId = activeTabId {
            let webView = webViewManager?.getWebView(for: activeTabId) ?? WKWebView()
            Logger.log("WebView getCurrentWebView: returning WebView \(Unmanaged.passUnretained(webView).toOpaque()) for tab \(activeTabId)", type: "WebView")
            return webView
        }
        Logger.log("WebView getCurrentWebView: returning new WKWebView (no activeTabId)", type: "WebView")
        return WKWebView()
    }

    private func configureWebView(_ webView: WKWebView) {
        // Set realistic user agent string to avoid bot detection and browser warnings
        // Using Chrome 141.0 on macOS (current as of January 2026)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

        // Configure cookie policy
        let dataStore = WKWebsiteDataStore.default()
        webView.configuration.websiteDataStore = dataStore

        // Configure JavaScript settings
        webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Note: javaScriptEnabled is deprecated, using webpage preferences instead
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        // Configure media playback policies
        webView.configuration.mediaTypesRequiringUserActionForPlayback = .video

        // Configure viewport and responsive design settings
        configureViewportSettings(for: webView.configuration)

        // Set up content blockers (basic ad blocking) - temporarily disabled for Google compatibility
        // setupContentBlockers(for: webView.configuration)

        // Set up custom URL scheme handlers
        setupCustomURLSchemes(for: webView.configuration)

        // Configure file access preferences (removed problematic private API calls)
        // Note: File URL access preferences are handled by WebKit defaults
    }

    private func configureViewportSettings(for configuration: WKWebViewConfiguration) {
        // Use desktop content mode for proper desktop interface rendering
        if #available(macOS 12.0, *) {
            configuration.defaultWebpagePreferences.preferredContentMode = .recommended
        } else {
            // Fallback for older macOS versions - use desktop mode
            configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        }

        // Allow content to adapt to different screen sizes
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        // Ensure we don't override viewport settings that might confuse Google
        // Remove any viewport manipulation that could trigger mobile interface
    }

    private func setupContentBlockers(for configuration: WKWebViewConfiguration) {
        // Basic ad blocking rules
        let blockRules = """
        [
            {
                "trigger": {
                    "url-filter": ".*googlesyndication\\.com.*",
                    "resource-type": ["script", "image"]
                },
                "action": {
                    "type": "block"
                }
            },
            {
                "trigger": {
                    "url-filter": ".*doubleclick\\.net.*",
                    "resource-type": ["script", "image"]
                },
                "action": {
                    "type": "block"
                }
            }
        ]
        """

        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "AdBlockRules",
            encodedContentRuleList: blockRules
        ) { (contentRuleList, error) in
            if let contentRuleList = contentRuleList {
                configuration.userContentController.add(contentRuleList)
            }
        }
    }

    private func setupCustomURLSchemes(for configuration: WKWebViewConfiguration) {
        // Handle custom URL schemes (e.g., app-specific protocols)
        configuration.setURLSchemeHandler(CustomURLSchemeHandler(), forURLScheme: "straightup")
    }

    func updateNSView(_ nsView: WebViewContainer, context: Context) {
        Logger.log("WebView updateNSView: activeTabId=\(activeTabId?.uuidString ?? "nil"), url=\(url?.absoluteString ?? "nil")", type: "WebView")

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

        // Load the URL when it changes, but prevent rapid reloading
        let normalizedURL = Tab.normalizeURLForComparison(url)
        let normalizedWebViewURL = Tab.normalizeURLForComparison(activeWebView.url)

        // Only load if the URL is different from what's currently displayed and not loading
        // Also check if enough time has passed since last load to prevent rapid reloading
        let timeSinceLastLoad = context.coordinator.lastLoadTime.map { Date().timeIntervalSince($0) } ?? Double.greatestFiniteMagnitude
        let minLoadInterval: TimeInterval = 1.0 // 1 second minimum between loads

        if let url = url, normalizedURL != normalizedWebViewURL, !activeWebView.isLoading, timeSinceLastLoad >= minLoadInterval {
            Logger.log("WebView loading URL: \(url.absoluteString) (current: \(activeWebView.url?.absoluteString ?? "nil"))", type: "WebView")
            context.coordinator.lastRequestedURL = url
            context.coordinator.lastLoadTime = Date()
            let request = URLRequest(url: url)
            activeWebView.load(request)
        } else if let url = url, normalizedURL == normalizedWebViewURL {
            Logger.log("WebView skipping duplicate load: \(url.absoluteString)", type: "WebView")
            // Ensure lastRequestedURL is set correctly
            context.coordinator.lastRequestedURL = url
        } else if activeWebView.isLoading {
            Logger.log("WebView skipping load while already loading: \(url?.absoluteString ?? "nil")", type: "WebView")
        } else if timeSinceLastLoad < minLoadInterval {
            Logger.log("WebView skipping load - too soon since last load (\(timeSinceLastLoad)s < \(minLoadInterval)s)", type: "WebView")
        }

        // Removed JavaScript injection that may interfere with user interactions
    }

    func makeCoordinator() -> Coordinator {
        Logger.log("WebView makeCoordinator called", type: "WebView")
        return Coordinator(self, tabManager: tabManager, tabs: tabs)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: WebView
        var tabManager: TabManager?
        var tabs: [Tab]?
        private var currentPageIsHTTPS = false
        private var mixedContentWarningsShown = Set<String>()
        var lastRequestedURL: URL?
        var lastSuccessfullyLoadedURL: URL?
        var lastLoadTime: Date?
        var lastViewSize: NSSize?

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

                    // Add to history if this was user-initiated navigation (not from our binding)
                    // We can detect this by checking if the navigation type was linkClicked
                    // For now, we'll add it to history for any successful navigation that's different from current
                    if activeTab.history.last != currentURL {
                        activeTab.history.append(currentURL)
                        activeTab.currentHistoryIndex = activeTab.history.count - 1

                        // Limit history size
                        let maxHistorySize = 100 // Use a reasonable default
                        if activeTab.history.count > maxHistorySize {
                            let excess = activeTab.history.count - maxHistorySize
                            activeTab.currentHistoryIndex = max(activeTab.history.count - 1, 0)
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
            // JavaScript to find the favicon URL - check multiple possible rel values
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

                // Fallback to default favicon location
                return window.location.origin + '/favicon.ico';
            })();
            """

            webView.evaluateJavaScript(faviconScript) { [weak self] result, error in
                guard let self = self else { return }

                if let faviconURLString = result as? String,
                   let faviconURL = URL(string: faviconURLString),
                   let baseURL = webView.url {
                    // Resolve relative URLs
                    let resolvedURL = faviconURL.scheme != nil ? faviconURL : URL(string: faviconURLString, relativeTo: baseURL)?.absoluteURL

                    Logger.log("Favicon debug: Found favicon URL: \(resolvedURL?.absoluteString ?? "nil") for page: \(baseURL.absoluteString)", type: "WebView")

                    if let finalURL = resolvedURL {
                        self.downloadFavicon(from: finalURL, webView: webView)
                    }
                } else {
                    Logger.log("Favicon debug: No favicon URL found for page: \(webView.url?.absoluteString ?? "nil"), trying alternative images", type: "WebView")
                    // Try to find alternative images as fallback - dispatch to main thread
                    DispatchQueue.main.async {
                        self.findAlternativeImage(for: webView)
                    }
                }
            }
        }

        private func downloadFavicon(from url: URL, webView: WKWebView? = nil) {
            Logger.log("Favicon debug: Attempting to download favicon from: \(url.absoluteString)", type: "WebView")

            // First check if favicon is already cached
            if let cachedData = FaviconCache.shared.getFavicon(for: url) {
                Logger.log("Favicon debug: Found cached favicon for: \(url.absoluteString), size: \(cachedData.count) bytes", type: "WebView")
                // Use cached favicon
                DispatchQueue.main.async {
                    if let tabManager = self.tabManager,
                       let tabs = self.tabs,
                       let activeTab = tabManager.getActiveTab(from: tabs) {
                        activeTab.favicon = cachedData
                    }
                }
                return
            }

            Logger.log("Favicon debug: No cached favicon found, downloading from: \(url.absoluteString)", type: "WebView")

            // Download favicon if not in cache
            URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
                guard let self = self else { return }

                Logger.log("Favicon debug: Download completed for \(url.absoluteString) - data size: \(data?.count ?? 0), error: \(error?.localizedDescription ?? "none")", type: "WebView")

                if let data = data,
                   let httpResponse = response as? HTTPURLResponse {
                    Logger.log("Favicon debug: HTTP status: \(httpResponse.statusCode), content type: \(httpResponse.allHeaderFields["Content-Type"] ?? "unknown")", type: "WebView")

                    if httpResponse.statusCode == 200, data.count > 0 {
                        Logger.log("Favicon debug: Successfully downloaded favicon, caching and setting for tab", type: "WebView")

                        // Validate that it's actually an image
                        if let _ = NSImage(data: data) {
                            Logger.log("Favicon debug: Valid image data, proceeding with caching", type: "WebView")

                            // Cache the favicon
                            FaviconCache.shared.setFavicon(data, for: url)

                            // Update the tab's favicon on the main thread
                            DispatchQueue.main.async {
                                // Find the active tab and update its favicon
                                if let tabManager = self.tabManager,
                                   let tabs = self.tabs,
                                   let activeTab = tabManager.getActiveTab(from: tabs) {
                                    activeTab.favicon = data
                                }
                            }
                        } else {
                            Logger.log("Favicon debug: Downloaded data is not a valid image", type: "WebView")
                            // Try alternative images if this was the favicon attempt
                            if webView != nil {
                                DispatchQueue.main.async {
                                    self.findAlternativeImage(for: webView!)
                                }
                            }
                        }
                    } else {
                        Logger.log("Favicon debug: Failed to download favicon - status: \(httpResponse.statusCode), data size: \(data.count)", type: "WebView")
                        // Try alternative images if this was the favicon attempt
                        if webView != nil {
                            DispatchQueue.main.async {
                                self.findAlternativeImage(for: webView!)
                            }
                        }
                    }
                } else {
                    Logger.log("Favicon debug: No response data received", type: "WebView")
                    // Try alternative images if this was the favicon attempt
                    if webView != nil {
                        DispatchQueue.main.async {
                            self.findAlternativeImage(for: webView!)
                        }
                    }
                }
            }.resume()
        }

        private func findAlternativeImage(for webView: WKWebView) {
            Logger.log("Favicon debug: Looking for alternative images for page: \(webView.url?.absoluteString ?? "unknown")", type: "WebView")

            // JavaScript to find alternative images from meta tags and header
            let alternativeImageScript = """
            (function() {
                // Check meta tags for Open Graph, Twitter, and other social media images
                var metaTags = document.getElementsByTagName('meta');
                for (var i = 0; i < metaTags.length; i++) {
                    var meta = metaTags[i];
                    var property = meta.getAttribute('property') || meta.getAttribute('name');
                    var content = meta.getAttribute('content');

                    if (property && content) {
                        property = property.toLowerCase();
                        // Open Graph image
                        if (property === 'og:image' || property === 'og:image:secure_url') {
                            return content;
                        }
                        // Twitter image
                        if (property === 'twitter:image' || property === 'twitter:image:src') {
                            return content;
                        }
                    }
                }

                // Look for structured data (JSON-LD)
                var scripts = document.getElementsByTagName('script');
                for (var i = 0; i < scripts.length; i++) {
                    var script = scripts[i];
                    if (script.type === 'application/ld+json') {
                        try {
                            var data = JSON.parse(script.textContent || script.innerText);
                            if (data.logo) {
                                if (typeof data.logo === 'string') {
                                    return data.logo;
                                } else if (data.logo.url) {
                                    return data.logo.url;
                                }
                            }
                            if (data.image) {
                                if (typeof data.image === 'string') {
                                    return data.image;
                                } else if (Array.isArray(data.image) && data.image.length > 0) {
                                    return data.image[0];
                                }
                            }
                        } catch (e) {
                            // Ignore JSON parsing errors
                        }
                    }
                }

                // Look for common logo selectors in header
                var selectors = [
                    'header img[src*="logo"]',
                    'header .logo img',
                    '.site-header img[src*="logo"]',
                    '.navbar-brand img',
                    '.brand img',
                    'h1 img',
                    '.logo img',
                    'header img:first-child',
                    '.site-logo img'
                ];

                for (var i = 0; i < selectors.length; i++) {
                    var element = document.querySelector(selectors[i]);
                    if (element && element.src) {
                        return element.src;
                    }
                }

                // Last resort: look for any reasonably sized image in the header
                var headerImages = document.querySelectorAll('header img, .header img, .site-header img');
                for (var i = 0; i < headerImages.length; i++) {
                    var img = headerImages[i];
                    if (img.src && img.naturalWidth >= 32 && img.naturalHeight >= 32) {
                        return img.src;
                    }
                }

                return null;
            })();
            """

            webView.evaluateJavaScript(alternativeImageScript) { [weak self] result, error in
                guard let self = self else { return }

                Logger.log("Favicon debug: Alternative image search result: \(result ?? "nil"), error: \(error?.localizedDescription ?? "none")", type: "WebView")

                if let imageURLString = result as? String,
                   let imageURL = URL(string: imageURLString),
                   let baseURL = webView.url {
                    // Resolve relative URLs
                    let resolvedURL = imageURL.scheme != nil ? imageURL : URL(string: imageURLString, relativeTo: baseURL)?.absoluteURL

                    Logger.log("Favicon debug: Found alternative image URL: \(resolvedURL?.absoluteString ?? "nil")", type: "WebView")

                    if let finalURL = resolvedURL {
                        self.downloadAndResizeAlternativeImage(from: finalURL, for: webView)
                    }
                } else {
                    Logger.log("Favicon debug: No alternative image found, trying domain initial", type: "WebView")
                    // Final fallback: generate domain initial
                    self.generateDomainInitial(for: webView)
                }
            }
        }

        private func downloadAndResizeAlternativeImage(from url: URL, for webView: WKWebView) {
            Logger.log("Favicon debug: Downloading alternative image from: \(url.absoluteString)", type: "WebView")

            // Check if we already have this alternative image cached
            // Use a safer approach for the cache key to avoid URL parsing issues
            let cacheKey = "alt_\(url.absoluteString)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "alt_\(url.absoluteString.hashValue)"
            if let cacheURL = URL(string: cacheKey), let cachedData = FaviconCache.shared.getFavicon(for: cacheURL) {
                Logger.log("Favicon debug: Found cached alternative image, size: \(cachedData.count) bytes", type: "WebView")
                DispatchQueue.main.async {
                    if let tabManager = self.tabManager,
                       let tabs = self.tabs,
                       let activeTab = tabManager.getActiveTab(from: tabs) {
                        activeTab.favicon = cachedData
                    }
                }
                return
            }

            URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
                guard let self = self else { return }

                Logger.log("Favicon debug: Alternative image download completed - data size: \(data?.count ?? 0), error: \(error?.localizedDescription ?? "none")", type: "WebView")

                if let data = data,
                   let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 200,
                   data.count > 0,
                   let originalImage = NSImage(data: data) {

                    Logger.log("Favicon debug: Successfully downloaded alternative image, resizing for favicon use", type: "WebView")

                    // Resize the image to favicon size (16x16 for tabs, but we'll keep it at 32x32 for better quality)
                    let resizedData = self.resizeImage(originalImage, to: NSSize(width: 32, height: 32))

                    if let resizedData = resizedData {
                        // Cache the resized alternative image with a special key
                        if let cacheURL = URL(string: cacheKey) {
                            FaviconCache.shared.setFavicon(resizedData, for: cacheURL)
                        }

                        // Update the tab's favicon on the main thread
                        DispatchQueue.main.async {
                            if let tabManager = self.tabManager,
                               let tabs = self.tabs,
                               let activeTab = tabManager.getActiveTab(from: tabs) {
                                activeTab.favicon = resizedData
                            }
                        }
                    } else {
                        Logger.log("Favicon debug: Failed to resize alternative image", type: "WebView")
                    }
                } else {
                    Logger.log("Favicon debug: Failed to download or validate alternative image", type: "WebView")
                    // Final fallback: generate domain initial - dispatch to main thread
                    DispatchQueue.main.async {
                        self.generateDomainInitial(for: webView)
                    }
                }
            }.resume()
        }

        private func resizeImage(_ image: NSImage, to targetSize: NSSize) -> Data? {
            // Create a new image with the target size
            let newImage = NSImage(size: targetSize)

            newImage.lockFocus()

            // Calculate the aspect ratio and draw the image centered
            let imageSize = image.size
            let aspectRatio = min(targetSize.width / imageSize.width, targetSize.height / imageSize.height)
            let scaledSize = NSSize(width: imageSize.width * aspectRatio, height: imageSize.height * aspectRatio)
            let drawRect = NSRect(
                x: (targetSize.width - scaledSize.width) / 2,
                y: (targetSize.height - scaledSize.height) / 2,
                width: scaledSize.width,
                height: scaledSize.height
            )

            image.draw(in: drawRect, from: NSRect(origin: .zero, size: imageSize), operation: .copy, fraction: 1.0)

            newImage.unlockFocus()

            // Convert to PNG data
            if let tiffData = newImage.tiffRepresentation,
               let bitmapImageRep = NSBitmapImageRep(data: tiffData) {
                return bitmapImageRep.representation(using: .png, properties: [:])
            }

            return nil
        }

        private func generateDomainInitial(for webView: WKWebView) {
            guard let url = webView.url, let domain = url.host else {
                Logger.log("Favicon debug: Cannot generate domain initial - no URL or host", type: "WebView")
                return
            }

            Logger.log("Favicon debug: Generating domain initial for: \(domain)", type: "WebView")

            // Generate the initial image
            if let initialImageData = DomainInitialsGenerator.shared.generateInitialImage(for: domain) {
                Logger.log("Favicon debug: Successfully generated domain initial, size: \(initialImageData.count) bytes", type: "WebView")

                // Update the tab's favicon on the main thread
                DispatchQueue.main.async {
                    if let tabManager = self.tabManager,
                       let tabs = self.tabs,
                       let activeTab = tabManager.getActiveTab(from: tabs) {
                        activeTab.favicon = initialImageData
                    }
                }
            } else {
                Logger.log("Favicon debug: Failed to generate domain initial", type: "WebView")
            }
        }

        private func triggerResponsiveLayout(in webView: WKWebView) {
            // Trigger viewport resize event to ensure responsive design updates
            let responsiveScript = """
            // Trigger resize event for responsive design
            window.dispatchEvent(new Event('resize'));

            // Also trigger orientation change if viewport API is available
            if (window.visualViewport) {
                window.visualViewport.dispatchEvent(new Event('resize'));
            }

            // Force layout recalculation for CSS media queries
            document.body.style.display = 'none';
            document.body.offsetHeight; // Trigger reflow
            document.body.style.display = '';
            """

            webView.evaluateJavaScript(responsiveScript) { _, _ in
                // Layout triggered successfully
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

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Handle special browser URLs
            if let url = navigationAction.request.url, url.scheme == "browser" {
                if url.host == "history" {
                    // Handle history page
                    showHistoryPage(webView: webView)
                    decisionHandler(.cancel)
                    return
                }
            }

            // Track if current page is HTTPS for mixed content detection
            if let url = navigationAction.request.url {
                currentPageIsHTTPS = (url.scheme == "https")
                if currentPageIsHTTPS && navigationAction.navigationType == .other {
                    // Reset warnings for new HTTPS page
                    mixedContentWarningsShown.removeAll()
                }
            }

            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            // Check for mixed content warnings
            if let response = navigationResponse.response as? HTTPURLResponse,
               let url = response.url {

                checkForMixedContent(url)
            }

            decisionHandler(.allow)
        }

        private func checkForMixedContent(_ resourceURL: URL) {
            // Only warn about mixed content on HTTPS pages
            guard currentPageIsHTTPS else { return }

            // Check if this resource is loaded over HTTP (insecure)
            if resourceURL.scheme == "http" {
                let warningKey = resourceURL.absoluteString

                // Only show each warning once per page load
                if !mixedContentWarningsShown.contains(warningKey) {
                    mixedContentWarningsShown.insert(warningKey)
                    showMixedContentWarning(for: resourceURL)
                }
            }
        }

        private func showHistoryPage(webView: WKWebView) {
            // Collect browsing history from all tabs
            var allHistory: [(url: URL, timestamp: Date)] = []

            if let tabs = tabs {
                for tab in tabs {
                    // Add current URL if it exists
                    if let currentUrl = tab.url {
                        allHistory.append((url: currentUrl, timestamp: tab.lastAccessed))
                    }

                    // Add all URLs from history
                    for url in tab.history {
                        allHistory.append((url: url, timestamp: tab.lastAccessed))
                    }
                }
            }

            // Also add closed tabs history
            if let tabManager = tabManager {
                for closedTab in tabManager.closedTabs {
                    if let currentUrl = closedTab.url {
                        allHistory.append((url: currentUrl, timestamp: closedTab.lastAccessed))
                    }

                    for url in closedTab.history {
                        allHistory.append((url: url, timestamp: closedTab.lastAccessed))
                    }
                }
            }

            // Remove duplicates, keeping the most recent timestamp
            var uniqueHistory: [URL: Date] = [:]
            for (url, timestamp) in allHistory {
                if let existingTimestamp = uniqueHistory[url] {
                    uniqueHistory[url] = max(existingTimestamp, timestamp)
                } else {
                    uniqueHistory[url] = timestamp
                }
            }

            // Sort by timestamp (most recent first)
            let sortedHistory = uniqueHistory.sorted { $0.value > $1.value }

            // Generate HTML content
            let htmlContent = generateHistoryHTML(history: sortedHistory)
            webView.loadHTMLString(htmlContent, baseURL: nil)
        }

        private func generateHistoryHTML(history: [(key: URL, value: Date)]) -> String {
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short

            var html = """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <title>Browsing History</title>
                <style>
                    body {
                        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                        margin: 0;
                        padding: 20px;
                        background-color: #f5f5f5;
                    }
                    .header {
                        text-align: center;
                        margin-bottom: 30px;
                    }
                    .header h1 {
                        color: #333;
                        margin: 0;
                        font-size: 28px;
                    }
                    .history-item {
                        background: white;
                        border-radius: 8px;
                        padding: 15px;
                        margin-bottom: 10px;
                        box-shadow: 0 2px 4px rgba(0,0,0,0.1);
                        display: flex;
                        align-items: center;
                        text-decoration: none;
                        color: inherit;
                        transition: transform 0.1s ease;
                    }
                    .history-item:hover {
                        transform: translateY(-2px);
                        box-shadow: 0 4px 8px rgba(0,0,0,0.15);
                    }
                    .favicon {
                        width: 16px;
                        height: 16px;
                        margin-right: 12px;
                        border-radius: 2px;
                    }
                    .url-info {
                        flex: 1;
                    }
                    .url {
                        font-size: 16px;
                        color: #007aff;
                        margin-bottom: 4px;
                        word-break: break-all;
                    }
                    .domain {
                        font-size: 14px;
                        color: #666;
                        margin-bottom: 2px;
                    }
                    .timestamp {
                        font-size: 12px;
                        color: #999;
                    }
                    .empty-state {
                        text-align: center;
                        padding: 60px 20px;
                        color: #666;
                    }
                    .empty-state h2 {
                        margin: 0 0 10px 0;
                        font-size: 24px;
                    }
                </style>
            </head>
            <body>
                <div class="header">
                    <h1>🕒 Browsing History</h1>
                </div>
            """

            if history.isEmpty {
                html += """
                <div class="empty-state">
                    <h2>No browsing history</h2>
                    <p>Your browsing history will appear here as you visit websites.</p>
                </div>
                """
            } else {
                for (url, timestamp) in history {
                    let domain = url.host ?? url.absoluteString
                    let formattedDate = dateFormatter.string(from: timestamp)

                    html += """
                    <a href="\(url.absoluteString)" class="history-item">
                        <img src="https://www.google.com/s2/favicons?domain=\(domain)&sz=16" class="favicon" onerror="this.style.display='none'">
                        <div class="url-info">
                            <div class="url">\(url.absoluteString)</div>
                            <div class="domain">\(domain)</div>
                            <div class="timestamp">\(formattedDate)</div>
                        </div>
                    </a>
                    """
                }
            }

            html += """
            </body>
            </html>
            """

            return html
        }

        private func showMixedContentWarning(for resourceURL: URL) {
            let alert = NSAlert()
            alert.messageText = "Mixed Content Warning"
            alert.informativeText = "This secure HTTPS page is loading an insecure HTTP resource:\n\n\(resourceURL.absoluteString)\n\nThis may expose your connection to eavesdropping or man-in-the-middle attacks."

            alert.alertStyle = .warning
            alert.addButton(withTitle: "Continue")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't show this warning again for this site"

            DispatchQueue.main.async {
                let response = alert.runModal()
                // Note: In a production app, you might want to store user preferences
                // about suppressing mixed content warnings for specific sites
                _ = response // Use response if needed for future enhancement
            }
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

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Handle new window requests (like target="_blank")
            guard let url = navigationAction.request.url else { return nil }

            // Implement popup blocking logic
            let isPopup = self.isPopupAttempt(windowFeatures)
            let isWhitelisted = self.isDomainWhitelisted(url)

            if isPopup && !isWhitelisted {
                // Show popup blocker dialog to user
                self.showPopupBlockerDialog(for: url, windowFeatures: windowFeatures) { shouldAllow in
                    if shouldAllow {
                        // User allowed the popup - open in new tab
                        self.parent.onPopupRequest?(url, windowFeatures)
                    }
                    // If not allowed, do nothing (popup is blocked)
                }
            } else {
                // Allow the popup or redirect to new tab
                self.parent.onPopupRequest?(url, windowFeatures)
            }

            return nil // Always return nil to prevent WebKit from creating its own window
        }

        private func isPopupAttempt(_ windowFeatures: WKWindowFeatures) -> Bool {
            // Analyze window features to determine if this is likely a popup/advertisement

            // Check size - very small windows are likely popups
            if let width = windowFeatures.width?.doubleValue, width < 400 { return true }
            if let height = windowFeatures.height?.doubleValue, height < 300 { return true }

            // Check for unusual positioning (negative coordinates or off-screen)
            if let x = windowFeatures.x?.doubleValue, x < 0 { return true }
            if let y = windowFeatures.y?.doubleValue, y < 0 { return true }

            // Check for zero size (some popups specify 0,0)
            if let width = windowFeatures.width?.doubleValue, width <= 0 { return true }
            if let height = windowFeatures.height?.doubleValue, height <= 0 { return true }

            // Check for extreme sizes that indicate ads
            if let width = windowFeatures.width?.doubleValue, width > 2000 { return true }
            if let height = windowFeatures.height?.doubleValue, height > 1500 { return true }

            // Consider windows without standard features as suspicious
            // Note: Some WKWindowFeatures properties may not be available in current WebKit

            return false // Not detected as popup
        }

        private func isDomainWhitelisted(_ url: URL) -> Bool {
            // Basic whitelist for trusted domains
            let whitelistedDomains = [
                "github.com",
                "stackoverflow.com",
                "developer.apple.com",
                "docs.swift.org"
            ]

            if let host = url.host {
                return whitelistedDomains.contains { host.contains($0) }
            }
            return false
        }

        private func showPopupBlockerDialog(for url: URL, windowFeatures: WKWindowFeatures?, completion: @escaping (Bool) -> Void) {
            let alert = NSAlert()
            alert.messageText = "Popup Blocked"
            alert.informativeText = "A popup window was blocked from \(url.host ?? "unknown site").\n\nURL: \(url.absoluteString)"

            // Add window feature details if available
            if let features = windowFeatures {
                var details = "\n\nWindow details:"
                if let width = features.width?.doubleValue {
                    details += "\nWidth: \(Int(width))px"
                }
                if let height = features.height?.doubleValue {
                    details += "\nHeight: \(Int(height))px"
                }
                if let x = features.x?.doubleValue {
                    details += "\nPosition X: \(Int(x))"
                }
                if let y = features.y?.doubleValue {
                    details += "\nPosition Y: \(Int(y))"
                }
                alert.informativeText += details
            }

            alert.alertStyle = .warning
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Block")

            // Run on main thread
            DispatchQueue.main.async {
                let response = alert.runModal()
                completion(response == .alertFirstButtonReturn)
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

        // Add observer for frame changes to trigger responsive layout
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(webViewFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: self
        )
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

    @objc func webViewFrameDidChange(_ notification: Notification) {
        // Trigger responsive layout on the active web view
        if let activeWebView = activeWebView {
            triggerResponsiveLayout(in: activeWebView)
        }
    }

    private func triggerResponsiveLayout(in webView: WKWebView) {
        // Trigger viewport resize event to ensure responsive design updates
        let responsiveScript = """
        // Trigger resize event for responsive design
        window.dispatchEvent(new Event('resize'));

        // Also trigger orientation change if viewport API is available
        if (window.visualViewport) {
            window.visualViewport.dispatchEvent(new Event('resize'));
        }

        // Force layout recalculation for CSS media queries
        document.body.style.display = 'none';
        document.body.offsetHeight; // Trigger reflow
        document.body.style.display = '';
        """

        webView.evaluateJavaScript(responsiveScript) { _, _ in
            // Layout triggered successfully
        }
    }

    // Forward KVO changes to the coordinator for the estimatedProgress property
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "estimatedProgress", let webView = object as? WKWebView {
            coordinator?.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
}

class CustomURLSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        // Handle custom URL schemes
        let url = urlSchemeTask.request.url!

        // For now, redirect to a default page or handle the scheme appropriately
        if url.scheme == "straightup" {
            // Handle app-specific URLs
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html"]
            )!

            let html = """
            <!DOCTYPE html>
            <html>
            <head><title>Browser</title></head>
            <body>
                <h1>Custom URL Scheme Handler</h1>
                <p>Handled URL: \(url.absoluteString)</p>
            </body>
            </html>
            """

            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(html.data(using: .utf8)!)
            urlSchemeTask.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Handle stopping the URL scheme task
    }
}
#endif
