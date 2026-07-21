//
//  NotificationManager.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import Foundation
import WebKit
import UniformTypeIdentifiers

class NotificationManager {
    private var tabManager: TabManager
    private var navigationManager: NavigationManager
    private var webViewManager: WebViewManager
    private var pageTranslator: PageTranslator
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
        pageTranslator: PageTranslator,
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
        self.pageTranslator = pageTranslator
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

    // App Intents poll this before posting: a notification sent before
    // ContentView.onAppear wires the observers would be silently dropped.
    static var observersReady = false

    func setupNotificationObservers() {
        guard observers.isEmpty else { return } // idempotent; cleanup() re-arms
        defer { Self.observersReady = true }

        let openURLOobserver = NotificationCenter.default.addObserver(
            forName: .browserOpenURL,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let urlString = notification.userInfo?["url"] as? String {
                // The global omnibar asks for a new tab so it never clobbers
                // the page the user was reading; CLI posts keep the old
                // navigate-the-active-tab behavior.
                if notification.userInfo?["newTab"] as? Bool == true, let url = URL(string: urlString) {
                    self?.tabManager.createNewTab(url: url, select: true)
                } else {
                    _ = self?.navigationManager.navigateToURL(urlString, activeTab: self?.tabManager.getActiveTab(from: self?.tabs() ?? []))
                }
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
            let tabList: [[String: Any]] = tabs.enumerated().map { index, tab in
                [
                    "index": index + 1, // 1-based, matches `switch <index>`
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
        ) { [weak self] _ in self?.resetZoom() })

        observers.append(NotificationCenter.default.addObserver(
            forName: .browserPrint, object: nil, queue: .main
        ) { [weak self] _ in self?.printCurrentPage() })

        observers.append(NotificationCenter.default.addObserver(
            forName: .browserExportPDF, object: nil, queue: .main
        ) { [weak self] _ in self?.exportPDF() })

        observers.append(NotificationCenter.default.addObserver(
            forName: .browserToggleTranslation, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.pageTranslator.toggle(webView: self.webViewManager.activeWebView)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .browserTranslateInSplit, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let tabs = self.tabs()
            guard let activeTab = self.tabManager.getActiveTab(from: tabs) else { return }
            self.pageTranslator.translateIntoSplitPane(
                tab: activeTab, tabManager: self.tabManager, webViewManager: self.webViewManager, tabs: tabs)
        })

        for (name, kind): (Notification.Name, ScreenshotKind) in [
            (.browserScreenshotVisible, .visible),
            (.browserScreenshotFullPage, .fullPage),
            (.browserScreenshotElement, .element),
            (.browserScreenshotWindow, .window),
        ] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                ScreenshotManager.capture(kind, in: self.webViewManager)
            })
        }

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

        // CLI agent commands - each writes its JSON result to the response
        // file the CLI is polling (BrowserCLI.writeResponse no-ops on nil path)
        observers.append(NotificationCenter.default.addObserver(
            forName: .browserNavigate, object: nil, queue: .main
        ) { [weak self] notification in
            switch notification.userInfo?["action"] as? String {
            case "back": self?.webViewManager.goBack()
            case "forward": self?.webViewManager.goForward()
            case "reload": self?.webViewManager.reload()
            default: break
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .browserSwitchTab, object: nil, queue: .main
        ) { [weak self] notification in
            let path = notification.userInfo?["responseFilePath"] as? String
            guard let self = self else { return }
            let count = self.tabs().count
            if let index = notification.userInfo?["index"] as? Int, index >= 1, index <= count {
                self.switchToTabAction(index - 1)
                BrowserCLI.writeResponse(["ok": true], to: path)
            } else {
                BrowserCLI.writeResponse(["error": "no tab at that index (\(count) open, indices are 1-based)"], to: path)
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .browserRunJS, object: nil, queue: .main
        ) { [weak self] notification in
            let path = notification.userInfo?["responseFilePath"] as? String
            guard let script = notification.userInfo?["script"] as? String else { return }
            guard let webView = self?.webViewManager.activeWebView else {
                BrowserCLI.writeResponse(["error": "no active tab"], to: path)
                return
            }
            self?.runJS(script, in: webView, responseFilePath: path)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .browserWaitForLoad, object: nil, queue: .main
        ) { [weak self] notification in
            let path = notification.userInfo?["responseFilePath"] as? String
            let timeout = notification.userInfo?["timeout"] as? Double ?? 15
            guard let self = self, let webView = self.webViewManager.activeWebView else {
                BrowserCLI.writeResponse(["error": "no active tab"], to: path)
                return
            }
            self.waitForLoad(webView, timeout: timeout) { loaded in
                if loaded {
                    BrowserCLI.writeResponse([
                        "ok": true,
                        "url": webView.url?.absoluteString ?? "",
                        "title": webView.title ?? ""
                    ], to: path)
                } else {
                    BrowserCLI.writeResponse(["error": "timeout waiting for page load"], to: path)
                }
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .browserScreenshot, object: nil, queue: .main
        ) { [weak self] notification in
            let path = notification.userInfo?["responseFilePath"] as? String
            guard let webView = self?.webViewManager.activeWebView else {
                BrowserCLI.writeResponse(["error": "no active tab"], to: path)
                return
            }
            webView.takeSnapshot(with: nil) { image, error in
                guard let path = path else { return }
                guard let image = image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    BrowserCLI.writeResponse(["error": error?.localizedDescription ?? "snapshot failed"], to: path)
                    return
                }
                // Binary PNG straight into the response file; the CLI sniffs
                // the magic bytes and moves it to the requested path
                try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .browserRealClick, object: nil, queue: .main
        ) { [weak self] notification in
            let path = notification.userInfo?["responseFilePath"] as? String
            guard let selector = notification.userInfo?["selector"] as? String else { return }
            self?.performRealClick(selector: selector, responseFilePath: path)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .browserNotifyUser, object: nil, queue: .main
        ) { [weak self] notification in
            let message = notification.userInfo?["message"] as? String ?? "The browser needs your attention."
            self?.focusWindow()
            NSApp.requestUserAttention(.criticalRequest)
            let alert = NSAlert()
            alert.messageText = String(localized: "Your browser needs a human")
            alert.informativeText = message
            if let window = self?.webViewManager.activeWebView?.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .browserFocusWindow, object: nil, queue: .main
        ) { [weak self] _ in
            self?.focusWindow()
        })
    }

    private func focusWindow() {
        NSApp.activate(ignoringOtherApps: true)
        (webViewManager.activeWebView?.window ?? NSApp.windows.first)?.makeKeyAndOrderFront(nil)
    }

    // ponytail: 0.2s poll on isLoading, not KVO/delegate - one code path for
    // `wait` and background `get`. 0.3s grace so a just-issued load() that
    // hasn't flipped isLoading yet doesn't return instantly.
    private func waitForLoad(_ webView: WKWebView, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if !webView.isLoading { completion(true); return }
            if Date() >= deadline { completion(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: poll)
    }

    private func runJS(_ code: String, in webView: WKWebView, responseFilePath: String?) {
        // eval the code as-is (last expression is the result) inside a wrapper
        // that JSON-serializes success or the thrown error
        guard let escapedData = try? JSONSerialization.data(withJSONObject: code, options: .fragmentsAllowed),
              let escaped = String(data: escapedData, encoding: .utf8) else {
            BrowserCLI.writeResponse(["error": "could not encode script"], to: responseFilePath)
            return
        }
        let wrapper = "(function(){try{var r=eval(\(escaped));return JSON.stringify({ok:true,result:r===undefined?null:r})}catch(e){return JSON.stringify({error:String(e)})}})()"
        // Run in an isolated content world, not the page world: pages that ship a
        // Trusted Types CSP (require-trusted-types-for 'script') otherwise refuse
        // the eval and every js/click/type/snapshot fails. The isolated world is
        // exempt from the page CSP but shares the same DOM, which is all these
        // commands touch. Trade-off: page JS globals aren't visible here.
        webView.evaluateJavaScript(wrapper, in: nil, in: .defaultClient) { result in
            switch result {
            case .success(let value):
                if let json = value as? String, let responseFilePath = responseFilePath {
                    try? json.write(toFile: responseFilePath, atomically: true, encoding: .utf8)
                }
            case .failure(let error):
                BrowserCLI.writeResponse(["error": error.localizedDescription], to: responseFilePath)
            }
        }
    }

    private func performRealClick(selector: String, responseFilePath: String?) {
        guard UserDefaults.standard.bool(forKey: "cliRealEventsEnabled") else {
            BrowserCLI.writeResponse(["error": "Real input events are disabled. Ask the user to enable Settings > Security > CLI Automation."], to: responseFilePath)
            return
        }
        // macOS silently drops CGEvents from untrusted processes; surface the
        // system prompt instead of a click that goes nowhere
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            BrowserCLI.writeResponse(["error": "macOS blocked the synthetic click. Ask the user to allow Browser under System Settings > Privacy & Security > Accessibility (a prompt was just shown), then relaunch the browser and retry."], to: responseFilePath)
            return
        }
        guard let webView = webViewManager.activeWebView, let window = webView.window else {
            BrowserCLI.writeResponse(["error": "no active tab"], to: responseFilePath)
            return
        }
        focusWindow()

        guard let selectorData = try? JSONSerialization.data(withJSONObject: selector, options: .fragmentsAllowed),
              let escapedSelector = String(data: selectorData, encoding: .utf8) else {
            BrowserCLI.writeResponse(["error": "could not encode selector"], to: responseFilePath)
            return
        }
        // scrollIntoView forces synchronous layout, so the rect read after it
        // is already settled - one JS round-trip
        let script = """
        (function() {
            var el = document.querySelector(\(escapedSelector));
            if (!el) return null;
            el.scrollIntoView({block: 'center'});
            var r = el.getBoundingClientRect();
            return [r.left + r.width / 2, r.top + r.height / 2];
        })()
        """

        // Give activation a beat so the click lands on our window - CGEvents
        // hit whatever is frontmost at those screen coordinates
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            webView.evaluateJavaScript(script) { result, error in
                guard let coords = result as? [Double], coords.count == 2 else {
                    let message = error?.localizedDescription ?? "no element matches selector"
                    BrowserCLI.writeResponse(["error": message], to: responseFilePath)
                    return
                }
                // ponytail: zoom != 1 is approximate; CSS px -> view points
                let viewPoint = NSPoint(x: coords[0] * webView.pageZoom, y: coords[1] * webView.pageZoom)
                let windowPoint = webView.convert(viewPoint, to: nil)
                let screenPoint = window.convertPoint(toScreen: windowPoint)
                // Cocoa screen coords are bottom-left origin; CG events want
                // top-left origin relative to the primary screen
                let cgPoint = CGPoint(x: screenPoint.x, y: NSScreen.screens[0].frame.maxY - screenPoint.y)

                CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                        mouseCursorPosition: cgPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                            mouseCursorPosition: cgPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
                    BrowserCLI.writeResponse(["ok": true, "x": cgPoint.x, "y": cgPoint.y], to: responseFilePath)
                }
            }
        }
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

    /// Actual Size (⌘0): undo page zoom *and* any trackpad pinch/smart-zoom magnification.
    private func resetZoom() {
        webViewManager.activeWebView?.magnification = 1.0
        setZoom(1.0)
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

    private func exportPDF() {
        guard let webView = webViewManager.activeWebView else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let title = webView.title?.isEmpty == false ? webView.title! : "Page"
        panel.nameFieldStringValue = title + ".pdf"

        let save: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            webView.createPDF { result in
                if case .success(let data) = result {
                    try? data.write(to: url)
                } else {
                    Logger.log("PDF export failed", type: "NotificationManager")
                }
            }
        }

        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: save)
        } else {
            save(panel.runModal())
        }
    }

    private func extractCurrentPageData(responseFilePath: String? = nil) {
        // Extract data from the currently active page
        let activeTab = tabManager.getActiveTab(from: tabs())

        guard let activeTab = activeTab else {
            Logger.log("Error: No active tab available", type: "NotificationManager")
            BrowserCLI.writeResponse(["error": "no active tab"], to: responseFilePath)
            return
        }

        let webView = webViewManager.getWebView(for: activeTab.id)

        Logger.log("Extracting data from current active page", type: "NotificationManager")
        extractDataFromLoadedPage(urlString: activeTab.url?.absoluteString ?? "current", webView: webView, responseFilePath: responseFilePath)
    }

    private func extractPageData(from urlString: String, responseFilePath: String? = nil) {
        // Always load the requested URL in the offscreen background webview -
        // `get <url>` must return that page, not whatever tab happens to be
        // active, and must not disturb the user's tabs
        guard let webView = backgroundWebView else {
            BrowserCLI.writeResponse(["error": "no background webview available"], to: responseFilePath)
            return
        }
        guard let url = URL(string: urlString), url.scheme != nil else {
            BrowserCLI.writeResponse(["error": "invalid URL (include the scheme, e.g. https://): \(urlString)"], to: responseFilePath)
            return
        }

        webView.load(URLRequest(url: url))
        // Extract whatever we have on timeout, matching the old fixed-delay behavior
        waitForLoad(webView, timeout: 12) { [weak self] _ in
            self?.extractDataFromLoadedPage(urlString: urlString, webView: webView, responseFilePath: responseFilePath)
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
        Self.observersReady = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
}
