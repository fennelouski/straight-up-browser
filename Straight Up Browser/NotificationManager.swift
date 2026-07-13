//
//  NotificationManager.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import Foundation
import WebKit

class NotificationManager {
    private var tabManager: TabManager
    private var navigationManager: NavigationManager
    private var webViewManager: WebViewManager
    private var showOmnibar: Binding<Bool>
    private var tabs: () -> [Tab]
    private var closeTabAction: (Tab, [Tab]) -> Void
    private var createNewTabAction: () -> Void
    private var setTabBarWidth: (Double) -> Void
    private var switchToTabAction: (Int) -> Void
    private var switchToNextTabAction: () -> Void
    private var switchToPreviousTabAction: () -> Void
    private var addBookmarkAction: () -> Void
    private var showBookmarksAction: () -> Void
    private var importBookmarksAction: () -> Void
    private var observers: [NSObjectProtocol] = []
    private var backgroundWebView: WKWebView?

    init(
        tabManager: TabManager,
        navigationManager: NavigationManager,
        webViewManager: WebViewManager,
        showOmnibar: Binding<Bool>,
        tabs: @escaping () -> [Tab],
        closeTabAction: @escaping (Tab, [Tab]) -> Void,
        createNewTabAction: @escaping () -> Void,
        setTabBarWidth: @escaping (Double) -> Void,
        switchToTabAction: @escaping (Int) -> Void,
        switchToNextTabAction: @escaping () -> Void,
        switchToPreviousTabAction: @escaping () -> Void,
        addBookmarkAction: @escaping () -> Void,
        showBookmarksAction: @escaping () -> Void,
        importBookmarksAction: @escaping () -> Void
    ) {
        self.tabManager = tabManager
        self.navigationManager = navigationManager
        self.webViewManager = webViewManager
        self.showOmnibar = showOmnibar
        self.tabs = tabs
        self.closeTabAction = closeTabAction
        self.createNewTabAction = createNewTabAction
        self.setTabBarWidth = setTabBarWidth
        self.switchToTabAction = switchToTabAction
        self.switchToNextTabAction = switchToNextTabAction
        self.switchToPreviousTabAction = switchToPreviousTabAction
        self.addBookmarkAction = addBookmarkAction
        self.showBookmarksAction = showBookmarksAction
        self.importBookmarksAction = importBookmarksAction

        // Initialize background web view for page data extraction
        self.backgroundWebView = WKWebView()
    }

    func setupNotificationObservers() {
        guard observers.isEmpty else { return } // idempotent; cleanup() re-arms

        let openURLOobserver = NotificationCenter.default.addObserver(
            forName: .browserOpenURL,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let urlString = notification.userInfo?["url"] as? String {
                _ = self?.navigationManager.navigateToURL(urlString, activeTab: self?.tabManager.getActiveTab(from: self?.tabs() ?? []))
            }
        }
        observers.append(openURLOobserver)

        let closeTabObserver = NotificationCenter.default.addObserver(
            forName: .browserCloseTab,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            if let activeTab = self?.tabManager.getActiveTab(from: self?.tabs() ?? []) {
                self?.closeTabAction(activeTab, self?.tabs() ?? [])
            }
        }
        observers.append(closeTabObserver)

        let newTabObserver = NotificationCenter.default.addObserver(
            forName: .browserNewTab,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.createNewTabAction()
        }
        observers.append(newTabObserver)


        let reopenLastClosedTabObserver = NotificationCenter.default.addObserver(
            forName: .reopenLastClosedTab,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            _ = self?.tabManager.reopenLastClosedTab()
        }
        observers.append(reopenLastClosedTabObserver)
        
        let showOmnibarObserver = NotificationCenter.default.addObserver(
            forName: .showOmnibar,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showOmnibar.wrappedValue.toggle()
        }
        observers.append(showOmnibarObserver)

        let listTabsObserver = NotificationCenter.default.addObserver(
            forName: .browserListTabs,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let tabs = self?.tabs() ?? []
            let tabList: [[String: Any]] = tabs.map { tab in
                [
                    "title": tab.title,
                    "url": tab.url?.absoluteString ?? "",
                    "active": tab.isActive
                ]
            }

            if let responseFilePath = notification.userInfo?["responseFilePath"] as? String,
               let data = try? JSONSerialization.data(withJSONObject: ["tabs": tabList], options: .prettyPrinted) {
                try? data.write(to: URL(fileURLWithPath: responseFilePath))
            } else {
                Logger.log("Open tabs: \(tabList)", type: "NotificationManager")
            }
        }
        observers.append(listTabsObserver)

        // Tab bar control observers
        let hideTabBarObserver = NotificationCenter.default.addObserver(
            forName: .browserHideTabBar,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setTabBarWidth(0)
        }
        observers.append(hideTabBarObserver)

        let minimalTabBarObserver = NotificationCenter.default.addObserver(
            forName: .browserMinimalTabBar,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setTabBarWidth(30)
        }
        observers.append(minimalTabBarObserver)

        let compactTabBarObserver = NotificationCenter.default.addObserver(
            forName: .browserCompactTabBar,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setTabBarWidth(120)
        }
        observers.append(compactTabBarObserver)

        let wideTabBarObserver = NotificationCenter.default.addObserver(
            forName: .browserWideTabBar,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Get window width for 20% calculation
            let windowWidth = Double(NSApplication.shared.keyWindow?.frame.width ?? 1000)
            let wideWidth = max(windowWidth * 0.2, 200)
            self?.setTabBarWidth(min(wideWidth, windowWidth * 0.8))
        }
        observers.append(wideTabBarObserver)

        // Tab switching observers
        let nextTabObserver = NotificationCenter.default.addObserver(
            forName: .browserNextTab,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.switchToNextTabAction()
        }
        observers.append(nextTabObserver)

        let previousTabObserver = NotificationCenter.default.addObserver(
            forName: .browserPreviousTab,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.switchToPreviousTabAction()
        }
        observers.append(previousTabObserver)

        // Direct tab switching observers
        let tab1Observer = NotificationCenter.default.addObserver(
            forName: .browserSwitchToTab1,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.switchToTabAction(0)
        }
        observers.append(tab1Observer)

        let tab2Observer = NotificationCenter.default.addObserver(
            forName: .browserSwitchToTab2,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.switchToTabAction(1)
        }
        observers.append(tab2Observer)

        let tab3Observer = NotificationCenter.default.addObserver(
            forName: .browserSwitchToTab3,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.switchToTabAction(2)
        }
        observers.append(tab3Observer)

        let tab4Observer = NotificationCenter.default.addObserver(
            forName: .browserSwitchToTab4,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.switchToTabAction(3)
        }
        observers.append(tab4Observer)

        let tab5Observer = NotificationCenter.default.addObserver(
            forName: .browserSwitchToTab5,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.switchToTabAction(4)
        }
        observers.append(tab5Observer)

        let tab6Observer = NotificationCenter.default.addObserver(
            forName: .browserSwitchToTab6,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.switchToTabAction(5)
        }
        observers.append(tab6Observer)

        let tab7Observer = NotificationCenter.default.addObserver(
            forName: .browserSwitchToTab7,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.switchToTabAction(6)
        }
        observers.append(tab7Observer)

        let tab8Observer = NotificationCenter.default.addObserver(
            forName: .browserSwitchToTab8,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.switchToTabAction(7)
        }
        observers.append(tab8Observer)

        let tab9Observer = NotificationCenter.default.addObserver(
            forName: .browserSwitchToTab9,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.switchToTabAction(8)
        }
        observers.append(tab9Observer)

        let addBookmarkObserver = NotificationCenter.default.addObserver(
            forName: .browserAddBookmark,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.addBookmarkAction()
        }
        observers.append(addBookmarkObserver)

        let showBookmarksObserver = NotificationCenter.default.addObserver(
            forName: .browserShowBookmarks,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showBookmarksAction()
        }
        observers.append(showBookmarksObserver)

        let importBookmarksObserver = NotificationCenter.default.addObserver(
            forName: .browserImportBookmarks,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.importBookmarksAction()
        }
        observers.append(importBookmarksObserver)

        // Zoom and print act on the active web view directly
        observers.append(NotificationCenter.default.addObserver(
            forName: .browserZoomIn, object: nil, queue: .main
        ) { [weak self] _ in self?.scaleZoom(by: 1.1) })

        observers.append(NotificationCenter.default.addObserver(
            forName: .browserZoomOut, object: nil, queue: .main
        ) { [weak self] _ in self?.scaleZoom(by: 1 / 1.1) })

        observers.append(NotificationCenter.default.addObserver(
            forName: .browserZoomReset, object: nil, queue: .main
        ) { [weak self] _ in self?.setZoom(1.0) })

        observers.append(NotificationCenter.default.addObserver(
            forName: .browserPrint, object: nil, queue: .main
        ) { [weak self] _ in self?.printCurrentPage() })

        let getPageDataObserver = NotificationCenter.default.addObserver(
            forName: .browserGetPageData,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Logger.log("browserGetPageData notification received", type: "NotificationManager")
            let responseFilePath = notification.userInfo?["responseFilePath"] as? String
            Logger.log("Response file path: \(responseFilePath ?? "nil")", type: "NotificationManager")
            if let urlString = notification.userInfo?["url"] as? String {
                Logger.log("Extracting page data from URL: \(urlString)", type: "NotificationManager")
                self?.extractPageData(from: urlString, responseFilePath: responseFilePath)
            } else if notification.userInfo?["currentPage"] as? Bool == true {
                Logger.log("Extracting current page data", type: "NotificationManager")
                self?.extractCurrentPageData(responseFilePath: responseFilePath)
            } else {
                Logger.log("No URL or currentPage flag in notification", type: "NotificationManager")
            }
        }
        observers.append(getPageDataObserver)
    }

    private func scaleZoom(by factor: Double) {
        guard let webView = webViewManager.activeWebView else { return }
        setZoom(min(4.0, max(0.25, webView.pageZoom * factor)))
    }

    private func setZoom(_ zoom: Double) {
        guard let webView = webViewManager.activeWebView else { return }
        webView.pageZoom = zoom
        // Persist per tab; reapplied on tab switch in WebView.updateNSView
        tabManager.getActiveTab(from: tabs())?.zoomLevel = zoom
    }

    private func printCurrentPage() {
        guard let webView = webViewManager.activeWebView else { return }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        // WKWebView's print view comes back zero-sized; give it a frame or the
        // print panel renders an empty page
        operation.view?.frame = webView.bounds
        if let window = webView.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    private func extractCurrentPageData(responseFilePath: String? = nil) {
        // Extract data from the currently active page
        let activeTab = tabManager.getActiveTab(from: tabs())

        guard let activeTab = activeTab else {
            Logger.log("Error: No active tab available", type: "NotificationManager")
            return
        }

        let webView = webViewManager.getWebView(for: activeTab.id)

        Logger.log("Extracting data from current active page", type: "NotificationManager")
        extractDataFromLoadedPage(urlString: activeTab.url?.absoluteString ?? "current", webView: webView, responseFilePath: responseFilePath)
    }

    private func extractPageData(from urlString: String, responseFilePath: String? = nil) {
        // Try to use the active webview first, fallback to background webview
        let activeTab = tabManager.getActiveTab(from: tabs())
        var targetWebView: WKWebView?
        var shouldLoadURL = false

        if let activeTab = activeTab {
            // Get the webview for the active tab
            targetWebView = webViewManager.getWebView(for: activeTab.id)
            Logger.log("Using active tab webview for data extraction", type: "NotificationManager")
        }

        if targetWebView == nil {
            targetWebView = backgroundWebView
            shouldLoadURL = true
            Logger.log("Using background webview for data extraction", type: "NotificationManager")
        }

        guard let webView = targetWebView else {
            Logger.log("Error: No webview available for data extraction", type: "NotificationManager")
            return
        }

        if shouldLoadURL {
            // If using background webview, we need to load the URL first
            guard let url = URL(string: urlString) else {
                Logger.log("Error: Invalid URL", type: "NotificationManager")
                return
            }

            let request = URLRequest(url: url)
            webView.load(request)

            // Wait for background webview to load
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
                self?.extractDataFromLoadedPage(urlString: urlString, webView: webView, responseFilePath: responseFilePath)
            }
        } else {
            // Extract data from the current page in the active webview
            Logger.log("About to extract data from active webview", type: "NotificationManager")
            extractDataFromLoadedPage(urlString: urlString, webView: webView, responseFilePath: responseFilePath)
        }
    }

    private func extractDataFromLoadedPage(urlString: String, webView: WKWebView? = nil, responseFilePath: String? = nil) {
        let webViewToUse = webView ?? backgroundWebView
        guard let webViewToUse = webViewToUse else { return }

        // JavaScript to extract page data
        let extractionScript = """
        (function() {
            try {
                var data = {
                    url: window.location.href,
                    title: document.title,
                    html: document.documentElement.outerHTML,
                    text: document.body ? document.body.innerText : '',
                    links: Array.from(document.querySelectorAll('a[href]')).map(a => ({
                        text: a.textContent.trim(),
                        href: a.href
                    })),
                    images: Array.from(document.querySelectorAll('img[src]')).map(img => ({
                        src: img.src,
                        alt: img.alt || ''
                    })),
                    metaTags: Array.from(document.querySelectorAll('meta')).map(meta => ({
                        name: meta.name || meta.getAttribute('property') || '',
                        content: meta.content || meta.getAttribute('content') || ''
                    }))
                };
                return JSON.stringify(data);
            } catch (error) {
                return JSON.stringify({
                    error: error.message,
                    url: window.location.href
                });
            }
        })();
        """

        webViewToUse.evaluateJavaScript(extractionScript) { result, error in
            var resultString: String

            if let error = error {
                Logger.log("Error extracting page data: \(error)", type: "NotificationManager")
                resultString = "{\"error\": \"\(error.localizedDescription)\", \"url\": \"\(urlString)\"}"
            } else if let jsonString = result as? String {
                resultString = jsonString
                // Still log for debugging
                Logger.log("Page data extracted successfully", type: "NotificationManager")
            } else {
                resultString = "{\"error\": \"Failed to extract page data\", \"url\": \"\(urlString)\"}"
                Logger.log("Failed to extract page data", type: "NotificationManager")
            }

            // If we have a response file path, write the result there
            if let responseFilePath = responseFilePath {
                do {
                    try resultString.write(toFile: responseFilePath, atomically: true, encoding: .utf8)
                } catch {
                    Logger.log("Error writing response to file: \(error)", type: "NotificationManager")
                }
            } else {
                // Fallback to logging if no response file
                Logger.log(resultString, type: "NotificationManager")
            }
        }
    }

    func cleanup() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
}
