//
//  NotificationManager.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
@preconcurrency import Foundation
import WebKit
import UniformTypeIdentifiers
import SwiftData

enum CLIPageReader {
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }

    static func makeWebView() -> WKWebView {
        WKWebView(frame: .zero, configuration: makeConfiguration())
    }
}

extension NotificationCenter {
    /// NotificationCenter's block is Sendable, but a non-nil OperationQueue
    /// guarantees delivery on that queue. Keep the runtime assertion at this
    /// boundary so UI-only observer bodies retain their MainActor contract.
    @discardableResult
    func addMainActorObserver(
        forName name: Notification.Name?,
        object objectToObserve: Any?,
        queue: OperationQueue,
        using block: @escaping @MainActor @Sendable (Notification) -> Void
    ) -> NSObjectProtocol {
        precondition(queue === OperationQueue.main)
        return addObserver(forName: name, object: objectToObserve, queue: queue) { notification in
            let transfer = MainActorNotification(notification)
            Task { @MainActor in
                block(transfer.value)
            }
        }
    }
}

class NotificationManager {
    let automationWindowId = UUID()
    private var tabManager: TabManager
    private var navigationManager: NavigationManager
    private var webViewManager: WebViewManager
    private var pageTranslator: PageTranslator
    private var showOmnibar: Binding<Bool>
    private var tabs: () -> [Tab]
    private var closeTabAction: (Tab, [Tab]) -> Void
    private var closeTabSetAction: () -> Void
    private var createNewTabAction: () -> Void
    private var setTabBarWidth: (Double) -> Void
    private var switchToTabAction: (Int) -> Void
    private var switchToNextTabAction: () -> Void
    private var switchToPreviousTabAction: () -> Void
    private var addBookmarkAction: () -> Void
    private var showBookmarksAction: () -> Void
    private var importBookmarksAction: () -> Void
    private var createWindowAction: () -> Void
    private var observers: [NSObjectProtocol] = []
    private var backgroundWebView: WKWebView?
    private var modelContext: ModelContext

    init(
        tabManager: TabManager,
        navigationManager: NavigationManager,
        webViewManager: WebViewManager,
        modelContext: ModelContext,
        pageTranslator: PageTranslator,
        showOmnibar: Binding<Bool>,
        tabs: @escaping () -> [Tab],
        closeTabAction: @escaping (Tab, [Tab]) -> Void,
        closeTabSetAction: @escaping () -> Void,
        createNewTabAction: @escaping () -> Void,
        setTabBarWidth: @escaping (Double) -> Void,
        switchToTabAction: @escaping (Int) -> Void,
        switchToNextTabAction: @escaping () -> Void,
        switchToPreviousTabAction: @escaping () -> Void,
        addBookmarkAction: @escaping () -> Void,
        showBookmarksAction: @escaping () -> Void,
        importBookmarksAction: @escaping () -> Void,
        createWindowAction: @escaping () -> Void
    ) {
        self.tabManager = tabManager
        self.navigationManager = navigationManager
        self.webViewManager = webViewManager
        self.modelContext = modelContext
        self.pageTranslator = pageTranslator
        self.showOmnibar = showOmnibar
        self.tabs = tabs
        self.closeTabAction = closeTabAction
        self.closeTabSetAction = closeTabSetAction
        self.createNewTabAction = createNewTabAction
        self.setTabBarWidth = setTabBarWidth
        self.switchToTabAction = switchToTabAction
        self.switchToNextTabAction = switchToNextTabAction
        self.switchToPreviousTabAction = switchToPreviousTabAction
        self.addBookmarkAction = addBookmarkAction
        self.showBookmarksAction = showBookmarksAction
        self.importBookmarksAction = importBookmarksAction
        self.createWindowAction = createWindowAction

        // Initialize background web view for page data extraction
        self.backgroundWebView = CLIPageReader.makeWebView()
    }

    // App Intents poll this before posting: a notification sent before
    // ContentView.onAppear wires the observers would be silently dropped.
    static var observersReady = false

    func setupNotificationObservers() {
        guard observers.isEmpty else { return } // idempotent; cleanup() re-arms
        BrowserAutomationRegistry.shared.register(self)
        BrowserAgentScheduler.shared.register(self)
        defer { Self.observersReady = true }

        let openURLOobserver = NotificationCenter.default.addMainActorObserver(
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

        let closeTabObserver = NotificationCenter.default.addMainActorObserver(
            forName: .browserCloseTab,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            if let activeTab = self?.tabManager.getActiveTab(from: self?.tabs() ?? []) {
                self?.closeTabAction(activeTab, self?.tabs() ?? [])
            }
        }
        observers.append(closeTabObserver)

        let closeTabSetObserver = NotificationCenter.default.addMainActorObserver(
            forName: .browserCloseTabSet,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.closeTabSetAction()
        }
        observers.append(closeTabSetObserver)

        let newTabObserver = NotificationCenter.default.addMainActorObserver(
            forName: .browserNewTab,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.createNewTabAction()
        }
        observers.append(newTabObserver)


        let reopenLastClosedTabObserver = NotificationCenter.default.addMainActorObserver(
            forName: .reopenLastClosedTab,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            _ = self?.tabManager.reopenLastClosedTab()
        }
        observers.append(reopenLastClosedTabObserver)
        
        let showOmnibarObserver = NotificationCenter.default.addMainActorObserver(
            forName: .showOmnibar,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showOmnibar.wrappedValue.toggle()
        }
        observers.append(showOmnibarObserver)

        let listTabsObserver = NotificationCenter.default.addMainActorObserver(
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
        let hideTabBarObserver = NotificationCenter.default.addMainActorObserver(
            forName: .browserHideTabBar,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setTabBarWidth(0)
        }
        observers.append(hideTabBarObserver)

        let minimalTabBarObserver = NotificationCenter.default.addMainActorObserver(
            forName: .browserMinimalTabBar,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setTabBarWidth(30)
        }
        observers.append(minimalTabBarObserver)

        let compactTabBarObserver = NotificationCenter.default.addMainActorObserver(
            forName: .browserCompactTabBar,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setTabBarWidth(120)
        }
        observers.append(compactTabBarObserver)

        let wideTabBarObserver = NotificationCenter.default.addMainActorObserver(
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
        let nextTabObserver = NotificationCenter.default.addMainActorObserver(
            forName: .browserNextTab,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.switchToNextTabAction()
        }
        observers.append(nextTabObserver)

        let previousTabObserver = NotificationCenter.default.addMainActorObserver(
            forName: .browserPreviousTab,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.switchToPreviousTabAction()
        }
        observers.append(previousTabObserver)

        // Direct tab switching observers
        let tab1Observer = NotificationCenter.default.addMainActorObserver(
            forName: .browserSwitchToTab1,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.switchToTabAction(0)
        }
        observers.append(tab1Observer)

        let tab2Observer = NotificationCenter.default.addMainActorObserver(
            forName: .browserSwitchToTab2,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.switchToTabAction(1)
        }
        observers.append(tab2Observer)

        let tab3Observer = NotificationCenter.default.addMainActorObserver(
            forName: .browserSwitchToTab3,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.switchToTabAction(2)
        }
        observers.append(tab3Observer)

        let tab4Observer = NotificationCenter.default.addMainActorObserver(
            forName: .browserSwitchToTab4,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.switchToTabAction(3)
        }
        observers.append(tab4Observer)

        let tab5Observer = NotificationCenter.default.addMainActorObserver(
            forName: .browserSwitchToTab5,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.switchToTabAction(4)
        }
        observers.append(tab5Observer)

        let tab6Observer = NotificationCenter.default.addMainActorObserver(
            forName: .browserSwitchToTab6,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.switchToTabAction(5)
        }
        observers.append(tab6Observer)

        let tab7Observer = NotificationCenter.default.addMainActorObserver(
            forName: .browserSwitchToTab7,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.switchToTabAction(6)
        }
        observers.append(tab7Observer)

        let tab8Observer = NotificationCenter.default.addMainActorObserver(
            forName: .browserSwitchToTab8,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.switchToTabAction(7)
        }
        observers.append(tab8Observer)

        let tab9Observer = NotificationCenter.default.addMainActorObserver(
            forName: .browserSwitchToTab9,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.switchToTabAction(8)
        }
        observers.append(tab9Observer)

        let addBookmarkObserver = NotificationCenter.default.addMainActorObserver(
            forName: .browserAddBookmark,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.addBookmarkAction()
        }
        observers.append(addBookmarkObserver)

        let showBookmarksObserver = NotificationCenter.default.addMainActorObserver(
            forName: .browserShowBookmarks,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showBookmarksAction()
        }
        observers.append(showBookmarksObserver)

        let importBookmarksObserver = NotificationCenter.default.addMainActorObserver(
            forName: .browserImportBookmarks,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.importBookmarksAction()
        }
        observers.append(importBookmarksObserver)

        // Zoom and print act on the active web view directly
        observers.append(NotificationCenter.default.addMainActorObserver(
            forName: .browserZoomIn, object: nil, queue: .main
        ) { [weak self] _ in self?.scaleZoom(by: 1.1) })

        observers.append(NotificationCenter.default.addMainActorObserver(
            forName: .browserZoomOut, object: nil, queue: .main
        ) { [weak self] _ in self?.scaleZoom(by: 1 / 1.1) })

        observers.append(NotificationCenter.default.addMainActorObserver(
            forName: .browserZoomReset, object: nil, queue: .main
        ) { [weak self] _ in self?.resetZoom() })

        observers.append(NotificationCenter.default.addMainActorObserver(
            forName: .browserPrint, object: nil, queue: .main
        ) { [weak self] _ in self?.printCurrentPage() })

        observers.append(NotificationCenter.default.addMainActorObserver(
            forName: .browserExportPDF, object: nil, queue: .main
        ) { [weak self] _ in self?.exportPDF() })

        observers.append(NotificationCenter.default.addMainActorObserver(
            forName: .browserToggleTranslation, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pageTranslator.toggle(webView: self.webViewManager.activeWebView)
            }
        })

        observers.append(NotificationCenter.default.addMainActorObserver(
            forName: .browserTranslateInSplit, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let tabs = self.tabs()
                guard let activeTab = self.tabManager.getActiveTab(from: tabs) else { return }
                self.pageTranslator.translateIntoSplitPane(
                    tab: activeTab, tabManager: self.tabManager, webViewManager: self.webViewManager, tabs: tabs)
            }
        })

        for (name, kind): (Notification.Name, ScreenshotKind) in [
            (.browserScreenshotVisible, .visible),
            (.browserScreenshotFullPage, .fullPage),
            (.browserScreenshotElement, .element),
            (.browserScreenshotWindow, .window),
        ] {
            observers.append(NotificationCenter.default.addMainActorObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                ScreenshotManager.capture(kind, in: self.webViewManager)
            })
        }

        let getPageDataObserver = NotificationCenter.default.addMainActorObserver(
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
        observers.append(NotificationCenter.default.addMainActorObserver(
            forName: .browserNavigate, object: nil, queue: .main
        ) { [weak self] notification in
            switch notification.userInfo?["action"] as? String {
            case "back": self?.webViewManager.goBack()
            case "forward": self?.webViewManager.goForward()
            case "reload": self?.webViewManager.reload()
            default: break
            }
        })

        observers.append(NotificationCenter.default.addMainActorObserver(
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

        observers.append(NotificationCenter.default.addMainActorObserver(
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

        observers.append(NotificationCenter.default.addMainActorObserver(
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

        observers.append(NotificationCenter.default.addMainActorObserver(
            forName: .browserScreenshot, object: nil, queue: .main
        ) { [weak self] notification in
            let path = notification.userInfo?["responseFilePath"] as? String
            let fullPage = notification.userInfo?["fullPage"] as? Bool ?? false
            let toClipboard = notification.userInfo?["clipboard"] as? Bool ?? false
            let toShared = notification.userInfo?["shared"] as? Bool ?? false
            guard let webView = self?.webViewManager.activeWebView else {
                BrowserCLI.writeResponse(["error": "no active tab"], to: path)
                return
            }
            let deliver: (NSImage?, Error?) -> Void = { image, error in
                guard let path = path else { return }
                guard let image = image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    BrowserCLI.writeResponse(["error": error?.localizedDescription ?? "snapshot failed"], to: path)
                    return
                }
                if toClipboard { ScreenshotManager.copyPNGToClipboard(png) }
                if toShared { ScreenshotManager.writePNGToSharedFolder(png, source: webView.url, pageTitle: webView.title) }
                // Binary PNG straight into the response file; the CLI sniffs
                // the magic bytes and moves it to the requested path
                try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            // takeSnapshot(with: nil) only ever captures the current viewport -
            // `--full-page` needs the resize-and-snapshot dance that actually
            // covers the whole scrollable document.
            if fullPage {
                ScreenshotManager.snapshotFullPage(webView) { deliver($0, nil) }
            } else {
                webView.takeSnapshot(with: nil) { image, error in deliver(image, error) }
            }
        })

        observers.append(NotificationCenter.default.addMainActorObserver(
            forName: .browserRealClick, object: nil, queue: .main
        ) { [weak self] notification in
            let path = notification.userInfo?["responseFilePath"] as? String
            guard let selector = notification.userInfo?["selector"] as? String else { return }
            self?.performRealClick(selector: selector, responseFilePath: path)
        })

        observers.append(NotificationCenter.default.addMainActorObserver(
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

        observers.append(NotificationCenter.default.addMainActorObserver(
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
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
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

        webView.loadURL(url)
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

    // MARK: - Structured agent automation

    var isAutomationKeyWindow: Bool {
        automationWindow?.isKeyWindow == true
    }

    func requestAutomationWindow() {
        createWindowAction()
    }

    func setAutomationWindowHidden(_ hidden: Bool) {
        guard let window = automationWindow else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.setAutomationWindowHidden(hidden)
            }
            return
        }
        hidden ? window.orderOut(nil) : window.makeKeyAndOrderFront(nil)
    }

    private var automationWindow: NSWindow? {
        webViewManager.activeWebView?.window
    }

    private func pageId(for tabId: UUID) -> String {
        "\(automationWindowId.uuidString):\(tabId.uuidString)"
    }

    private func tabId(from arguments: [String: Any]) -> UUID? {
        if let pageId = arguments["pageId"] as? String {
            let raw = pageId.split(separator: ":", maxSplits: 1).last.map(String.init) ?? pageId
            if let id = UUID(uuidString: raw) { return id }
        }
        if let raw = arguments["tabId"] as? String, let id = UUID(uuidString: raw) { return id }
        return tabManager.selectedTabId
    }

    private func tab(for arguments: [String: Any]) -> Tab? {
        guard let id = tabId(from: arguments) else { return nil }
        return tabs().first { $0.id == id }
    }

    private func automationPageSummary(_ tab: Tab) -> [String: Any] {
        [
            "pageId": pageId(for: tab.id),
            "tabId": tab.id.uuidString,
            "windowId": automationWindowId.uuidString,
            "title": tab.title,
            "url": tab.url?.absoluteString ?? "",
            "active": tab.id == tabManager.selectedTabId,
            "visible": tab.id == tabManager.selectedTabId || tabManager.splitTabIds.contains(tab.id),
            "groupId": tab.groupId?.uuidString ?? NSNull(),
            "sessionKind": tab.sessionKind.rawValue,
            "incognito": tab.sessionKind == .incognito,
            "pinned": tab.isPinned,
            "muted": tab.isMuted,
        ]
    }

    func automationPageSummaries() -> [[String: Any]] {
        tabs().map(automationPageSummary)
    }

    func automationActivePageSummary() -> [String: Any]? {
        tabManager.getActiveTab(from: tabs()).map(automationPageSummary)
    }

    func automationWindowSummary() -> [String: Any] {
        let window = automationWindow
        return [
            "windowId": automationWindowId.uuidString,
            "active": window?.isKeyWindow == true,
            "visible": window?.isVisible ?? false,
            "title": window?.title ?? "Browser",
            "pageCount": tabs().count,
            "frame": [
                "x": window?.frame.origin.x ?? 0,
                "y": window?.frame.origin.y ?? 0,
                "width": window?.frame.width ?? 0,
                "height": window?.frame.height ?? 0,
            ],
        ]
    }

    private func automationWebView(for arguments: [String: Any]) -> WKWebView? {
        guard let tab = tab(for: arguments) else { return nil }
        let webView = webViewManager.getWebView(for: tab.id)
        if webView.url == nil, let url = tab.url { webView.loadURL(url) }
        return webView
    }

    private func respond(_ value: [String: Any], to path: String?) {
        BrowserCLI.writeResponse(value, to: path)
    }

    func performAutomationTool(
        _ tool: String,
        arguments: [String: Any],
        responseFilePath: String?
    ) {
        switch tool {
        case "navigate_page":
            guard let target = tab(for: arguments),
                  let webView = automationWebView(for: arguments) else {
                respond(["error": "page not found"], to: responseFilePath)
                return
            }
            if let action = arguments["action"] as? String {
                switch action {
                case "back": webView.goBack()
                case "forward": webView.goForward()
                case "reload": webView.reload()
                case "stop": webView.stopLoading()
                default:
                    respond(["error": "unknown navigation action: \(action)"], to: responseFilePath)
                    return
                }
            } else if let rawURL = arguments["url"] as? String,
                      let url = URL(string: rawURL), url.scheme != nil {
                target.navigateTo(url)
                webView.loadURL(url)
            } else {
                respond(["error": "navigate_page requires url or action"], to: responseFilePath)
                return
            }
            respond(["ok": true, "page": automationPageSummary(target)], to: responseFilePath)

        case "new_page", "new_hidden_page":
            let select = tool == "new_page" && (arguments["background"] as? Bool != true)
            let target: Tab
            if arguments["incognito"] as? Bool == true {
                target = tabManager.createIncognitoTab(select: select)
            } else {
                let current = tabManager.getActiveTab(from: tabs())
                let session = current.map { ($0.sessionKind, $0.sessionId) } ?? (.normal, nil)
                target = tabManager.createTab(inheriting: session, select: select)
            }
            if tool == "new_hidden_page" || arguments["background"] as? Bool == true {
                target.memoryPolicy = .never
            }
            let webView = webViewManager.getWebView(for: target.id)
            if let rawURL = arguments["url"] as? String,
               let url = URL(string: rawURL), url.scheme != nil {
                target.navigateTo(url)
                target.updateTitleFromURL()
                webView.loadURL(url)
            }
            respond(["ok": true, "page": automationPageSummary(target)], to: responseFilePath)

        case "show_page":
            guard let target = tab(for: arguments) else {
                respond(["error": "page not found"], to: responseFilePath)
                return
            }
            tabManager.selectedTabId = target.id
            webViewManager.setActiveTab(target.id)
            automationWindow?.makeKeyAndOrderFront(nil)
            respond(["ok": true, "page": automationPageSummary(target)], to: responseFilePath)

        case "close_page":
            guard let target = tab(for: arguments) else {
                respond(["error": "page not found"], to: responseFilePath)
                return
            }
            let summary = automationPageSummary(target)
            closeTabAction(target, tabs())
            respond(["ok": true, "closedPage": summary], to: responseFilePath)

        case "move_page":
            guard let target = tab(for: arguments) else {
                respond(["error": "page not found"], to: responseFilePath)
                return
            }
            let ordered = tabs().sorted { $0.orderIndex < $1.orderIndex }
            let requested = arguments["index"] as? Int ?? target.orderIndex
            let index = min(max(requested, 0), max(ordered.count - 1, 0))
            let destination = ordered[index]
            tabManager.reorderTabs(sourceTabId: target.id, targetTabId: destination.id, tabs: ordered)
            respond(["ok": true, "page": automationPageSummary(target)], to: responseFilePath)

        case "wait_for_page":
            guard let webView = automationWebView(for: arguments) else {
                respond(["error": "page not found"], to: responseFilePath)
                return
            }
            let timeout = max(0.1, min(arguments["timeout"] as? Double ?? 15, 60))
            waitForLoad(webView, timeout: timeout) { [weak self] loaded in
                guard let self else { return }
                if loaded {
                    self.respond([
                        "ok": true,
                        "url": webView.url?.absoluteString ?? "",
                        "title": webView.title ?? "",
                    ], to: responseFilePath)
                } else {
                    self.respond(["error": "timeout waiting for page load"], to: responseFilePath)
                }
            }

        case "evaluate_script":
            guard let script = arguments["script"] as? String,
                  let webView = automationWebView(for: arguments) else {
                respond(["error": "evaluate_script requires a page and script"], to: responseFilePath)
                return
            }
            runJS(script, in: webView, responseFilePath: responseFilePath)

        case "take_screenshot":
            guard let webView = automationWebView(for: arguments) else {
                respond(["error": "page not found"], to: responseFilePath)
                return
            }
            let fullPage = arguments["fullPage"] as? Bool ?? false
            let deliver: (NSImage?, Error?) -> Void = { [weak self] image, error in
                guard let self else { return }
                guard let image, let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff) else {
                    self.respond(["error": error?.localizedDescription ?? "snapshot failed"], to: responseFilePath)
                    return
                }
                let wantsJPEG = (arguments["format"] as? String)?.lowercased() == "jpeg"
                let data = wantsJPEG
                    ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
                    : rep.representation(using: .png, properties: [:])
                guard let data else {
                    self.respond(["error": "could not encode screenshot"], to: responseFilePath)
                    return
                }
                self.respond([
                    "ok": true,
                    "mimeType": wantsJPEG ? "image/jpeg" : "image/png",
                    "data": data.base64EncodedString(),
                    "url": webView.url?.absoluteString ?? "",
                ], to: responseFilePath)
            }
            if fullPage {
                ScreenshotManager.snapshotFullPage(webView) { deliver($0, nil) }
            } else {
                webView.takeSnapshot(with: nil) { deliver($0, $1) }
            }

        case "save_pdf":
            guard let webView = automationWebView(for: arguments) else {
                respond(["error": "page not found"], to: responseFilePath)
                return
            }
            webView.createPDF { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let data):
                    self.respond([
                        "ok": true,
                        "mimeType": "application/pdf",
                        "data": data.base64EncodedString(),
                        "title": webView.title ?? "Page",
                    ], to: responseFilePath)
                case .failure(let error):
                    self.respond(["error": error.localizedDescription], to: responseFilePath)
                }
            }

        case "activate_window":
            NSApp.activate(ignoringOtherApps: true)
            automationWindow?.makeKeyAndOrderFront(nil)
            respond(["ok": true, "window": automationWindowSummary()], to: responseFilePath)

        case "close_window":
            let summary = automationWindowSummary()
            respond(["ok": true, "closedWindow": summary], to: responseFilePath)
            automationWindow?.performClose(nil)

        case "get_bookmarks", "search_bookmarks", "create_bookmark", "remove_bookmark",
             "update_bookmark", "move_bookmark":
            performBookmarkTool(tool, arguments: arguments, responseFilePath: responseFilePath)

        case "search_history", "get_recent_history", "delete_history_url", "delete_history_range":
            performHistoryTool(tool, arguments: arguments, responseFilePath: responseFilePath)

        case "list_tab_groups", "group_tabs", "update_tab_group", "ungroup_tabs", "close_tab_group":
            performTabGroupTool(tool, arguments: arguments, responseFilePath: responseFilePath)

        case "handle_dialog":
            handleAutomationDialog(arguments: arguments, responseFilePath: responseFilePath)

        default:
            respond(["error": "unsupported agent tool: \(tool)"], to: responseFilePath)
        }
    }

    func automationJSONResult(tool: String, arguments: [String: Any]) async -> String {
        let authorization = CLIAuthorization()
        let capability = CLIAuthorization.capability(forAgentTool: tool)
        guard authorization.allows(capability: capability) else {
            return "{\"error\":\"\(authorization.denialMessage(for: capability))\"}"
        }
        let expanded = expandedAutomationTool(tool, arguments: arguments)
        let directory = BrowserCLI.responseDirectory
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return "{\"error\":\"Could not create the agent response directory.\"}"
        }
        let file = directory.appendingPathComponent("in-process-\(UUID().uuidString).json")
        BrowserAutomationRegistry.shared.execute(
            ["tool": expanded.tool, "arguments": expanded.arguments],
            responseFilePath: file.path
        )
        for _ in 0..<1_200 {
            if let data = try? Data(contentsOf: file), !data.isEmpty {
                try? FileManager.default.removeItem(at: file)
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let encoded = object["data"] as? String, encoded.count > 20_000 {
                    var compact = object
                    compact["data"] = "<binary data omitted from model context>"
                    if let safe = try? JSONSerialization.data(withJSONObject: compact),
                       let string = String(data: safe, encoding: .utf8) {
                        return string
                    }
                }
                return String(data: data, encoding: .utf8) ?? "{\"error\":\"Invalid tool response.\"}"
            }
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { break }
        }
        try? FileManager.default.removeItem(at: file)
        return "{\"error\":\"Tool timed out.\"}"
    }

    private func expandedAutomationTool(
        _ tool: String,
        arguments: [String: Any]
    ) -> (tool: String, arguments: [String: Any]) {
        func literal(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else {
                return "\"\""
            }
            return String(data: data, encoding: .utf8) ?? "\"\""
        }
        func selector() -> String? {
            if let value = arguments["selector"] as? String, !value.isEmpty { return value }
            if let id = arguments["elementId"] as? String, !id.isEmpty {
                return "[data-sub-agent-id=\(literal(id))]"
            }
            return nil
        }
        func scriptRequest(_ script: String) -> (String, [String: Any]) {
            var result = arguments
            result["script"] = script
            return ("evaluate_script", result)
        }

        let snapshot = #"""
        (function(enhanced){var q='a[href],button,input,select,textarea,[role=button],[role=link],[role=textbox],[role=checkbox],[role=combobox],[onclick],[contenteditable=true]';var es=Array.from(document.querySelectorAll(q)).filter(function(e){var r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none'});es.forEach(function(e,i){e.setAttribute('data-sub-agent-id','sub-'+(i+1))});function label(e){return String(e.getAttribute('aria-label')||e.innerText||e.value||e.placeholder||e.alt||e.title||'').replace(/\s+/g,' ').trim().slice(0,180)}var l=['URL: '+location.href,'TITLE: '+document.title,'','INTERACTIVE ('+es.length+'):'];es.slice(0,300).forEach(function(e,i){var r=e.getBoundingClientRect(),s='[sub-'+(i+1)+'] '+(e.getAttribute('role')||e.tagName.toLowerCase())+' "'+label(e)+'"';if(e.tagName==='A')s+=' -> '+e.href;if('checked'in e)s+=' checked='+!!e.checked;if(enhanced)s+=' rect=('+Math.round(r.x)+','+Math.round(r.y)+','+Math.round(r.width)+','+Math.round(r.height)+')';l.push(s)});l.push('','TEXT:');var t=(document.body?document.body.innerText:'').replace(/\n{3,}/g,'\n\n').trim(),n=enhanced?20000:8000;l.push(t.slice(0,n));if(t.length>n)l.push('…[truncated]');return l.join('\n')})(__ENHANCED__)
        """#

        switch tool {
        case "take_snapshot":
            return scriptRequest(snapshot.replacingOccurrences(of: "__ENHANCED__", with: "false"))
        case "take_enhanced_snapshot":
            return scriptRequest(snapshot.replacingOccurrences(of: "__ENHANCED__", with: "true"))
        case "get_page_content":
            return scriptRequest("(document.querySelector('main,article,[role=main]')||document.body)?.innerText||''")
        case "get_page_links":
            return scriptRequest("Array.from(new Map(Array.from(document.querySelectorAll('a[href]')).map(a=>[a.href,{text:String(a.innerText||a.getAttribute('aria-label')||'').trim(),url:a.href}])).values())")
        case "get_dom":
            if let selected = arguments["selector"] as? String {
                return scriptRequest("document.querySelector(\(literal(selected)))?.outerHTML||null")
            }
            return scriptRequest("document.documentElement.outerHTML")
        case "search_dom":
            let query = arguments["query"] as? String ?? ""
            let mode = arguments["mode"] as? String ?? "text"
            let limit = max(1, min(arguments["limit"] as? Int ?? 50, 500))
            return scriptRequest("(function(q,m,n){var a=[];if(m==='css')a=Array.from(document.querySelectorAll(q));else if(m==='xpath'){var x=document.evaluate(q,document,null,XPathResult.ORDERED_NODE_SNAPSHOT_TYPE,null);for(var i=0;i<x.snapshotLength;i++)a.push(x.snapshotItem(i))}else a=Array.from(document.querySelectorAll('body *')).filter(e=>e.children.length===0&&String(e.textContent||'').toLowerCase().includes(q.toLowerCase()));return a.slice(0,n).map(e=>({tag:e.tagName?.toLowerCase()||'',text:String(e.innerText||e.textContent||'').trim().slice(0,500),html:e.outerHTML?.slice(0,2000)||''}))})(\(literal(query)),\(literal(mode)),\(limit))")
        case "click":
            guard let selector = selector() else { return (tool, arguments) }
            return scriptRequest("var el=document.querySelector(\(literal(selector)));if(!el)throw new Error('element not found');el.scrollIntoView({block:'center'});el.click();'clicked'")
        case "fill":
            guard let selector = selector() else { return (tool, arguments) }
            let value = arguments["value"] as? String ?? ""
            return scriptRequest("var el=document.querySelector(\(literal(selector)));if(!el)throw new Error('element not found');el.focus();var p=el.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype,d=Object.getOwnPropertyDescriptor(p,'value');if(d&&d.set)d.set.call(el,\(literal(value)));else el.value=\(literal(value));el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));'filled'")
        case "press_key":
            let key = arguments["key"] as? String ?? ""
            return scriptRequest("var e=document.activeElement||document.body,o={key:\(literal(key)),code:\(literal(key)),bubbles:true,cancelable:true};e.dispatchEvent(new KeyboardEvent('keydown',o));e.dispatchEvent(new KeyboardEvent('keyup',o));'pressed'")
        case "scroll":
            let direction = arguments["direction"] as? String ?? "down"
            let amount = arguments["amount"] as? Double ?? 600
            let delta = direction == "up" || direction == "left" ? -amount : amount
            let x = direction == "left" || direction == "right" ? delta : 0
            let y = direction == "up" || direction == "down" ? delta : 0
            return scriptRequest("window.scrollBy({left:\(x),top:\(y),behavior:'instant'});({x:scrollX,y:scrollY})")
        default:
            return (tool, arguments)
        }
    }

    private func bookmarkDictionary(_ bookmark: Bookmark) -> [String: Any] {
        [
            "id": bookmark.id.uuidString,
            "title": bookmark.title,
            "url": bookmark.url.absoluteString,
            "folder": bookmark.category ?? "",
            "createdAt": ISO8601DateFormatter().string(from: bookmark.createdAt),
        ]
    }

    private var automationBookmarkFolders: [String] {
        get { UserDefaults.standard.stringArray(forKey: "agentBookmarkFolders") ?? [] }
        set { UserDefaults.standard.set(Array(Set(newValue)).sorted(), forKey: "agentBookmarkFolders") }
    }

    private func performBookmarkTool(
        _ tool: String,
        arguments: [String: Any],
        responseFilePath: String?
    ) {
        let manager = BookmarkManager(modelContext: modelContext)
        switch tool {
        case "get_bookmarks", "search_bookmarks":
            let query = arguments["query"] as? String ?? ""
            let bookmarks = query.isEmpty ? manager.fetchAllBookmarks() : manager.fetchBookmarks(matching: query)
            let folders = Array(Set(automationBookmarkFolders + bookmarks.compactMap(\.category))).sorted()
            respond([
                "ok": true,
                "bookmarks": bookmarks.map(bookmarkDictionary),
                "folders": folders.map { ["id": "folder:\($0)", "title": $0] },
            ], to: responseFilePath)
        case "create_bookmark":
            let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let rawURL = arguments["url"] as? String, let url = URL(string: rawURL), url.scheme != nil {
                let bookmark = manager.addBookmark(
                    title: title.isEmpty ? (url.host ?? rawURL) : title,
                    url: url,
                    category: arguments["folder"] as? String
                )
                respond(["ok": true, "bookmark": bookmarkDictionary(bookmark)], to: responseFilePath)
            } else if !title.isEmpty {
                automationBookmarkFolders.append(title)
                respond(["ok": true, "folder": ["id": "folder:\(title)", "title": title]], to: responseFilePath)
            } else {
                respond(["error": "create_bookmark requires a URL or folder title"], to: responseFilePath)
            }
        case "remove_bookmark":
            guard let rawId = arguments["id"] as? String else {
                respond(["error": "remove_bookmark requires id"], to: responseFilePath)
                return
            }
            if rawId.hasPrefix("folder:") {
                let folder = String(rawId.dropFirst("folder:".count))
                for bookmark in manager.fetchAllBookmarks() where bookmark.category == folder {
                    manager.updateBookmark(bookmark, title: bookmark.title, url: bookmark.url, category: nil)
                }
                automationBookmarkFolders.removeAll { $0 == folder }
                respond(["ok": true], to: responseFilePath)
            } else if let id = UUID(uuidString: rawId),
                      let bookmark = manager.fetchAllBookmarks().first(where: { $0.id == id }) {
                manager.removeBookmark(bookmark)
                respond(["ok": true], to: responseFilePath)
            } else {
                respond(["error": "bookmark not found"], to: responseFilePath)
            }
        case "update_bookmark", "move_bookmark":
            guard let rawId = arguments["id"] as? String,
                  let id = UUID(uuidString: rawId),
                  let bookmark = manager.fetchAllBookmarks().first(where: { $0.id == id }) else {
                respond(["error": "bookmark not found"], to: responseFilePath)
                return
            }
            let title = arguments["title"] as? String ?? bookmark.title
            let url = (arguments["url"] as? String).flatMap(URL.init(string:)) ?? bookmark.url
            let folder = arguments.keys.contains("folder") ? arguments["folder"] as? String : bookmark.category
            manager.updateBookmark(bookmark, title: title, url: url, category: folder)
            respond(["ok": true, "bookmark": bookmarkDictionary(bookmark)], to: responseFilePath)
        default:
            respond(["error": "unsupported bookmark operation"], to: responseFilePath)
        }
    }

    private func historyDictionary(_ visit: HistoryVisit) -> [String: Any] {
        [
            "id": visit.id.uuidString,
            "title": visit.title,
            "url": visit.url.absoluteString,
            "visitedAt": ISO8601DateFormatter().string(from: visit.visitedAt),
        ]
    }

    private func performHistoryTool(
        _ tool: String,
        arguments: [String: Any],
        responseFilePath: String?
    ) {
        let store = BrowsingHistoryStore.shared
        switch tool {
        case "search_history":
            let query = arguments["query"] as? String ?? ""
            let limit = arguments["limit"] as? Int ?? 50
            respond(["ok": true, "history": store.search(query, limit: limit).map(historyDictionary)], to: responseFilePath)
        case "get_recent_history":
            let limit = arguments["limit"] as? Int ?? 50
            respond(["ok": true, "history": Array(store.recentVisits.prefix(limit)).map(historyDictionary)], to: responseFilePath)
        case "delete_history_url":
            guard let rawURL = arguments["url"] as? String, let url = URL(string: rawURL) else {
                respond(["error": "delete_history_url requires url"], to: responseFilePath)
                return
            }
            store.remove(url: url)
            respond(["ok": true], to: responseFilePath)
        case "delete_history_range":
            let formatter = ISO8601DateFormatter()
            let start = (arguments["start"] as? String).flatMap(formatter.date(from:))
            let end = (arguments["end"] as? String).flatMap(formatter.date(from:))
            store.remove(from: start, through: end)
            respond(["ok": true], to: responseFilePath)
        default:
            respond(["error": "unsupported history operation"], to: responseFilePath)
        }
    }

    private func tabGroups() -> [TabGroup] {
        (try? modelContext.fetch(FetchDescriptor<TabGroup>(
            sortBy: [SortDescriptor(\.orderIndex)]
        ))) ?? []
    }

    private func tabGroupDictionary(_ group: TabGroup) -> [String: Any] {
        [
            "id": group.id.uuidString,
            "title": group.name,
            "color": group.colorHex,
            "pageIds": tabs().filter { $0.groupId == group.id }.map { pageId(for: $0.id) },
        ]
    }

    private func performTabGroupTool(
        _ tool: String,
        arguments: [String: Any],
        responseFilePath: String?
    ) {
        switch tool {
        case "list_tab_groups":
            respond(["ok": true, "groups": tabGroups().map(tabGroupDictionary)], to: responseFilePath)
        case "group_tabs":
            let group: TabGroup
            if let rawId = arguments["groupId"] as? String,
               let id = UUID(uuidString: rawId),
               let existing = tabGroups().first(where: { $0.id == id }) {
                group = existing
            } else {
                let name = arguments["title"] as? String ?? "Agent tabs"
                let color = Color(hex: arguments["color"] as? String ?? "#007AFF") ?? .blue
                group = TabGroup(name: name, color: color, orderIndex: tabGroups().count)
                modelContext.insert(group)
            }
            let ids = (arguments["pageIds"] as? [String] ?? []).compactMap { raw -> UUID? in
                let suffix = raw.split(separator: ":", maxSplits: 1).last.map(String.init) ?? raw
                return UUID(uuidString: suffix)
            }
            for tab in tabs() where ids.contains(tab.id) { tab.groupId = group.id }
            try? modelContext.save()
            respond(["ok": true, "group": tabGroupDictionary(group)], to: responseFilePath)
        case "update_tab_group":
            guard let rawId = arguments["groupId"] as? String,
                  let id = UUID(uuidString: rawId),
                  let group = tabGroups().first(where: { $0.id == id }) else {
                respond(["error": "tab group not found"], to: responseFilePath)
                return
            }
            if let title = arguments["title"] as? String { group.name = title }
            if let color = arguments["color"] as? String { group.colorHex = color }
            try? modelContext.save()
            respond(["ok": true, "group": tabGroupDictionary(group)], to: responseFilePath)
        case "ungroup_tabs":
            let ids = (arguments["pageIds"] as? [String] ?? []).compactMap { raw -> UUID? in
                let suffix = raw.split(separator: ":", maxSplits: 1).last.map(String.init) ?? raw
                return UUID(uuidString: suffix)
            }
            for tab in tabs() where ids.contains(tab.id) { tab.groupId = nil }
            try? modelContext.save()
            respond(["ok": true], to: responseFilePath)
        case "close_tab_group":
            guard let rawId = arguments["groupId"] as? String,
                  let id = UUID(uuidString: rawId),
                  let group = tabGroups().first(where: { $0.id == id }) else {
                respond(["error": "tab group not found"], to: responseFilePath)
                return
            }
            var remaining = tabs()
            for target in remaining.filter({ $0.groupId == id }) {
                closeTabAction(target, remaining)
                remaining.removeAll { $0.id == target.id }
            }
            modelContext.delete(group)
            try? modelContext.save()
            respond(["ok": true], to: responseFilePath)
        default:
            respond(["error": "unsupported tab group operation"], to: responseFilePath)
        }
    }

    private func handleAutomationDialog(arguments: [String: Any], responseFilePath: String?) {
        guard let webView = automationWebView(for: arguments),
              let sheet = webView.window?.attachedSheet else {
            respond(["error": "no JavaScript dialog is open for this page"], to: responseFilePath)
            return
        }
        if let promptText = arguments["promptText"] as? String {
            sheet.contentView?.descendants(of: NSTextField.self).first?.stringValue = promptText
        }
        let accept = arguments["accept"] as? Bool ?? true
        let buttons = sheet.contentView?.descendants(of: NSButton.self) ?? []
        let preferred = buttons.first { button in
            let title = button.title.lowercased()
            return accept ? ["ok", "allow", "yes"].contains(title) : ["cancel", "deny", "no"].contains(title)
        } ?? (accept ? buttons.first : buttons.last)
        guard let preferred else {
            respond(["error": "dialog has no actionable button"], to: responseFilePath)
            return
        }
        preferred.performClick(nil)
        respond(["ok": true, "accepted": accept], to: responseFilePath)
    }

    func cleanup() {
        BrowserAgentScheduler.shared.unregister(self)
        BrowserAutomationRegistry.shared.unregister(self)
        Self.observersReady = BrowserAutomationRegistry.shared.hasLiveManagers
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
}

private extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { view -> [T] in
            let current = (view as? T).map { [$0] } ?? []
            return current + view.descendants(of: type)
        }
    }
}
