//
//  WebViewManager.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import WebKit
import Combine

class WebViewManager: ObservableObject {
    // Store web views per tab ID
    private var webViews: [UUID: WKWebView] = [:]

    // Active web view for the currently selected tab
    @Published var activeWebView: WKWebView?

    init() {
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

    // Create a new WKWebView with proper configuration
    private func createWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()

        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = .video

        // Create web view
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true

        return webView
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