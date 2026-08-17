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

@MainActor
enum AgentReplayFrameEncoder {
    static func encode(
        _ image: NSImage,
        maximumBytes: Int = AgentRunStore.maximumReplayFrameBytes
    ) -> (data: Data, contentType: String)? {
        guard maximumBytes > 0,
              let tiff = image.tiffRepresentation,
              let original = NSBitmapImageRep(data: tiff) else { return nil }

        if let png = original.representation(using: .png, properties: [:]),
           png.count <= maximumBytes {
            return (png, "image/png")
        }
        for quality in [0.82, 0.60, 0.40] {
            if let jpeg = original.representation(
                using: .jpeg,
                properties: [.compressionFactor: quality]
            ), jpeg.count <= maximumBytes {
                return (jpeg, "image/jpeg")
            }
        }

        var source = image
        var pixelWidth = original.pixelsWide
        var pixelHeight = original.pixelsHigh
        for _ in 0..<5 {
            pixelWidth = max(1, Int((Double(pixelWidth) * 0.65).rounded(.down)))
            pixelHeight = max(1, Int((Double(pixelHeight) * 0.65).rounded(.down)))
            guard let downscaled = downscaledRepresentation(
                source,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            ) else { return nil }
            if let jpeg = downscaled.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.72]
            ), jpeg.count <= maximumBytes {
                return (jpeg, "image/jpeg")
            }
            let next = NSImage(size: NSSize(width: pixelWidth, height: pixelHeight))
            next.addRepresentation(downscaled)
            source = next
            if pixelWidth == 1 && pixelHeight == 1 { break }
        }
        return nil
    }

    private static func downscaledRepresentation(
        _ image: NSImage,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> NSBitmapImageRep? {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: representation) else {
            return nil
        }
        representation.size = NSSize(width: pixelWidth, height: pixelHeight)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return representation
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
    private var forceNewTabAction: () -> Void
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
    private var semanticGenerationTracker = SemanticPageGenerationTracker()
    private var semanticSnapshotsByTabID: [UUID: SemanticPageSnapshot] = [:]

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
        forceNewTabAction: @escaping () -> Void,
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
        self.forceNewTabAction = forceNewTabAction
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

        let forceNewTabObserver = NotificationCenter.default.addMainActorObserver(
            forName: .browserForceNewTab,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, BrowserWindowCommandRouting.matches(
                target: notification.object as AnyObject?,
                recipient: self.webViewManager.activeWebView?.window
            ) else { return }
            self.forceNewTabAction()
        }
        observers.append(forceNewTabObserver)


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
            let components = pageId.split(separator: ":", maxSplits: 1).map(String.init)
            guard components.count == 2,
                  UUID(uuidString: components[0]) == automationWindowId,
                  let id = UUID(uuidString: components[1]) else { return nil }
            return id
        }
        if let raw = arguments["tabId"] as? String {
            return UUID(uuidString: raw)
        }
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

    /// Resolves a Page against the host's live WebView and captures the
    /// per-document token held in our isolated semantic content world. URL and
    /// history alone are insufficient because a same-URL reload replaces the
    /// document without changing either value.
    func automationPageAuthoritySnapshot(
        pageID: String?
    ) async -> BrowserAutomationPageAuthoritySnapshot? {
        var arguments: [String: Any] = [:]
        if let pageID { arguments["pageId"] = pageID }
        guard let tab = tab(for: arguments),
              let webView = automationWebView(for: arguments) else { return nil }
        if webView.isLoading {
            try? await waitForWebViewLoad(webView, timeout: 10)
        }
        guard let url = webView.url ?? tab.url,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        let session: AgentBrowserSession = switch tab.sessionKind {
        case .normal:
            .normal
        case .incognito:
            .incognito
        case .container:
            .container(tab.sessionId ?? tab.id)
        }
        guard let rawToken = try? await webView.callAsyncJavaScript(
            SemanticPageJavaScript.bootstrap
                + "\nreturn window['\(SemanticPageJavaScript.runtimeKey)'].documentToken;",
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        ) as? String,
              let token = UUID(uuidString: rawToken) else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return BrowserAutomationPageAuthoritySnapshot(
            target: AgentPageTarget(
                pageID: pageId(for: tab.id),
                origin: "\(scheme)://\(host)\(port)",
                session: session
            ),
            document: PageDocumentGeneration(rawValue: token)
        )
    }

    func automationPageAuthoritySnapshots(
        pageIDs: [String]
    ) async -> [BrowserAutomationPageAuthoritySnapshot]? {
        guard !pageIDs.isEmpty, Set(pageIDs).count == pageIDs.count else {
            return nil
        }
        var snapshots: [BrowserAutomationPageAuthoritySnapshot] = []
        for pageID in pageIDs {
            guard let snapshot = await automationPageAuthoritySnapshot(pageID: pageID),
                  snapshot.target.pageID == pageID else { return nil }
            snapshots.append(snapshot)
        }
        return snapshots
    }

    /// Captures only the currently visible viewport for replay evidence. The
    /// Page's isolated-world document token must remain identical across the
    /// snapshot so a navigation or same-URL reload can never attach pixels
    /// from a replacement document to the authorized invocation.
    func captureAgentReplayFrame(
        expectedBinding: BrowserAutomationPageDispatchBinding
    ) async -> AgentReplayCapturedFrame? {
        let pageID = expectedBinding.target.pageID
        guard expectedBinding.target.session != .incognito,
              let before = await automationPageAuthoritySnapshot(pageID: pageID),
              replaySnapshot(before, matches: expectedBinding),
              (try? PageHandle(parsing: before.target.pageID)) != nil else {
            return nil
        }
        let arguments: [String: Any] = ["pageId": pageID]
        guard let webView = automationWebView(for: arguments) else { return nil }
        let width = Int(webView.bounds.width.rounded(.toNearestOrAwayFromZero))
        let height = Int(webView.bounds.height.rounded(.toNearestOrAwayFromZero))
        let scale = Double(
            webView.window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 1
        )
        guard width > 0, height > 0, scale.isFinite, scale > 0 else {
            return nil
        }
        let image: NSImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, _ in
                continuation.resume(returning: image)
            }
        }
        guard let image,
              let encoded = AgentReplayFrameEncoder.encode(image),
              let after = await automationPageAuthoritySnapshot(pageID: pageID),
              replaySnapshot(after, matches: expectedBinding) else {
            return nil
        }
        return AgentReplayCapturedFrame(
            data: encoded.data,
            contentType: encoded.contentType,
            target: before.target,
            viewport: AgentReplayViewport(
                width: width,
                height: height,
                scale: scale
            )
        )
    }

    private func replaySnapshot(
        _ snapshot: BrowserAutomationPageAuthoritySnapshot,
        matches expected: BrowserAutomationPageDispatchBinding
    ) -> Bool {
        do {
            try expected.validate(
                live: BrowserAutomationPageDispatchBinding(
                    target: snapshot.target,
                    version: AgentPageLeaseVersion(
                        navigation: expected.version.navigation,
                        document: snapshot.document
                    )
                ),
                allowIncognito: true
            )
            return true
        } catch {
            return false
        }
    }

    /// Synchronous metadata for settings pickers only. Execution authority must
    /// use `automationPageAuthoritySnapshot`, which also binds the document.
    func automationPageTargetSummary(pageID: String?) -> AgentPageTarget? {
        var arguments: [String: Any] = [:]
        if let pageID { arguments["pageId"] = pageID }
        guard let tab = tab(for: arguments),
              let url = tab.url,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        let session: AgentBrowserSession = switch tab.sessionKind {
        case .normal: .normal
        case .incognito: .incognito
        case .container: .container(tab.sessionId ?? tab.id)
        }
        let port = url.port.map { ":\($0)" } ?? ""
        return AgentPageTarget(
            pageID: pageId(for: tab.id),
            origin: "\(scheme)://\(host)\(port)",
            session: session
        )
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

    func automationJSONResult(
        tool: String,
        arguments: [String: Any],
        permit: AgentExecutionPermit? = nil,
        authorizedPageBindings: [BrowserAutomationPageDispatchBinding] = []
    ) async -> String {
        guard let descriptor = AgentToolCatalog.canonical.descriptor(named: tool) else {
            return automationJSONString(["error": "unknown agent tool"])
        }
        // This entry point is used by an in-app Run after AgentPolicyEngine has
        // issued a concrete execution permit. CLI/MCP preferences protect the
        // external entry points and must not reject an already-authorized Run.
        guard let permit, permit.toolName == tool else {
            return automationJSONString([
                "error": "policy authorization does not match requested tool",
            ])
        }
        var boundArguments = arguments
        if descriptor.requiresLivePageTarget {
            guard let validated = await validatedAutomationArguments(
                      arguments,
                      descriptor: descriptor,
                      authorizedPageBindings: authorizedPageBindings
                  ) else {
                return automationJSONString([
                    "error": "authorized Page target is missing, stale, or changed",
                ])
            }
            boundArguments = validated
        }
        if descriptor.requiresLivePageTarget,
           let targetTab = tab(for: boundArguments),
           let targetWebView = automationWebView(for: boundArguments) {
            do {
                _ = try await activateAgentSignalScope(
                    tab: targetTab,
                    webView: targetWebView,
                    permit: permit
                )
            } catch {
                return automationJSONString([
                    "error": "could not activate the authorized page signal scope",
                ])
            }
        }
        let operation: () async -> String = { [self] in
            var dispatchArguments = boundArguments
            if descriptor.requiresLivePageTarget {
                guard let revalidated = await validatedAutomationArguments(
                    boundArguments,
                    descriptor: descriptor,
                    authorizedPageBindings: authorizedPageBindings
                ) else {
                    return automationJSONString([
                        "error": "authorized Page changed immediately before dispatch",
                    ])
                }
                dispatchArguments = revalidated
            }
            return await performBoundAutomationJSONResult(
                tool: tool,
                arguments: dispatchArguments,
                permit: permit,
                authorizedPageBindings: authorizedPageBindings
            )
        }
        guard descriptor.requiresLivePageTarget,
              let authorizedBinding = authorizedPageBindings.first else {
            return await operation()
        }
        return await AgentReplayCaptureCoordinator.around(
            descriptor: descriptor,
            authorizedBinding: authorizedBinding,
            permit: permit,
            capture: { [self] expectedBinding in
                await captureAgentReplayFrame(expectedBinding: expectedBinding)
            },
            operationSucceeded: {
                BrowserAutomationInvocationResult(
                    responseData: Data($0.utf8)
                ).kind == .succeeded
            },
            resolvePostOperationBinding: { [self] in
                guard let snapshot = await automationPageAuthoritySnapshot(
                    pageID: authorizedBinding.target.pageID
                ) else { return nil }
                return BrowserAutomationPageDispatchBinding(
                    target: snapshot.target,
                    version: AgentPageLeaseVersion(
                        navigation: authorizedBinding.version.navigation,
                        document: snapshot.document
                    )
                )
            },
            operation: operation
        )
    }

    private func performBoundAutomationJSONResult(
        tool: String,
        arguments: [String: Any],
        permit: AgentExecutionPermit?,
        authorizedPageBindings: [BrowserAutomationPageDispatchBinding]
    ) async -> String {
        if Self.semanticAutomationTools.contains(tool) {
            guard let permit, permit.toolName == tool else {
                return automationJSONString([
                    "error": "policy authorization does not match requested tool",
                ])
            }
            return await semanticAutomationJSONResult(
                tool: tool,
                arguments: arguments,
                permit: permit
            )
        }
        if tool == "wait_for" {
            guard let permit, permit.toolName == tool else {
                return automationJSONString([
                    "error": "policy authorization does not match requested tool",
                ])
            }
            return await performAgentWaitTool(arguments: arguments, permit: permit)
        }
        if tool == "observe_webkit_signals" || tool == "wait_for_webkit_signal" {
            guard let permit, permit.toolName == tool else {
                return automationJSONString([
                    "error": "policy authorization does not match requested tool",
                ])
            }
            return await performAgentSignalTool(tool, arguments: arguments, permit: permit)
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
            responseFilePath: file.path,
            permit: permit,
            authorizedPageBindings: authorizedPageBindings,
            authorizedToolName: tool
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

    private func validatedAutomationArguments(
        _ arguments: [String: Any],
        descriptor: AgentToolDescriptor,
        authorizedPageBindings: [BrowserAutomationPageDispatchBinding]
    ) async -> [String: Any]? {
        guard descriptor.requiresLivePageTarget,
              !authorizedPageBindings.isEmpty else { return nil }
        let requestedPageIDs: [String]
        if descriptor.acceptsMultiplePageTargets {
            requestedPageIDs = arguments["pageIds"] as? [String] ?? []
            guard !requestedPageIDs.isEmpty else { return nil }
        } else if let requested = arguments["pageId"] as? String {
            requestedPageIDs = [requested]
        } else if authorizedPageBindings.count == 1 {
            requestedPageIDs = [authorizedPageBindings[0].target.pageID]
        } else {
            return nil
        }
        guard Set(requestedPageIDs)
                == Set(authorizedPageBindings.map(\.target.pageID)),
              let snapshots = await automationPageAuthoritySnapshots(
                  pageIDs: requestedPageIDs
              ) else { return nil }
        let liveByPageID = Dictionary(uniqueKeysWithValues: snapshots.map {
            ($0.target.pageID, $0)
        })
        do {
            for authorized in authorizedPageBindings {
                guard let snapshot = liveByPageID[authorized.target.pageID] else {
                    return nil
                }
                try authorized.validate(
                    live: BrowserAutomationPageDispatchBinding(
                        target: snapshot.target,
                        version: AgentPageLeaseVersion(
                            navigation: authorized.version.navigation,
                            document: snapshot.document
                        )
                    ),
                    allowIncognito: true
                )
            }
        } catch {
            return nil
        }
        var bound = arguments
        if !descriptor.acceptsMultiplePageTargets, bound["pageId"] == nil {
            bound["pageId"] = requestedPageIDs[0]
        }
        return bound
    }

    private static let semanticAutomationTools: Set<String> = [
        "take_snapshot", "take_enhanced_snapshot",
        "click", "download_file", "hover", "focus", "fill", "clear",
        "check", "uncheck", "select_option", "drag", "scroll", "upload_file",
    ]

    static func handlesSemanticAutomationTool(_ tool: String) -> Bool {
        semanticAutomationTools.contains(tool)
    }

    /// Executes semantic tools without translating their stable IDs into page
    /// attributes or raw selectors. This is intentionally internal so the local
    /// MCP registry can use the exact same document-bound implementation.
    func semanticAutomationJSONResult(
        tool: String,
        arguments: [String: Any],
        permit: AgentExecutionPermit
    ) async -> String {
        guard Self.semanticAutomationTools.contains(tool), permit.toolName == tool else {
            return automationJSONString(["error": "semantic tool authorization mismatch"])
        }
        guard let tab = tab(for: arguments),
              let webView = automationWebView(for: arguments) else {
            return automationJSONString(["error": "page not found"])
        }
        let page = PageHandle(windowID: automationWindowId, tabID: tab.id)

        do {
            _ = try await BrowserAgentWebKitSignalRuntime.shared.activate(
                runID: permit.runID,
                page: page,
                browserSession: agentSignalSession(for: tab)
            )
            if tool == "take_snapshot" || tool == "take_enhanced_snapshot" {
                let captured = try await captureSemanticSnapshot(
                    page: page,
                    tabID: tab.id,
                    webView: webView
                )
                return automationJSONString([
                    "ok": true,
                    "result": SemanticPageJavaScriptSnapshot.renderCompatibilityText(
                        captured,
                        enhanced: tool == "take_enhanced_snapshot"
                    ),
                ])
            }

            let request = try await semanticEffectRequest(
                tool: tool,
                arguments: arguments,
                page: page,
                tabID: tab.id,
                webView: webView
            )
            let result = try await webView.callAsyncJavaScript(
                SemanticPageJavaScript.effect,
                arguments: ["request": request],
                in: nil,
                contentWorld: .defaultClient
            )
            return automationJSONString([
                "ok": true,
                "result": result ?? NSNull(),
            ])
        } catch let error as SemanticReferenceResolutionError {
            return automationJSONString([
                "error": "semantic reference is stale or ambiguous: \(String(describing: error))",
            ])
        } catch {
            return automationJSONString([
                "error": "semantic automation failed: \(error.localizedDescription)",
            ])
        }
    }

    private func captureSemanticSnapshot(
        page: PageHandle,
        tabID: UUID,
        webView: WKWebView,
        selectors: [String] = []
    ) async throws -> SemanticPageJavaScriptSnapshot {
        _ = try await webView.callAsyncJavaScript(
            SemanticPageJavaScript.bootstrap + "\nreturn true;",
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        )
        guard let value = try await webView.callAsyncJavaScript(
            SemanticPageJavaScript.snapshot,
            arguments: [
                "selectors": Array(selectors.prefix(16)),
                "maximumNodes": 4_096,
                "maximumRoots": 128,
                "maximumDepth": 32,
                "maximumText": 65_536,
            ],
            in: nil,
            contentWorld: .defaultClient
        ) else {
            throw SemanticPageJavaScriptError.invalidPayload
        }
        let decoded = try SemanticPageJavaScriptSnapshot.decode(
            value,
            page: page,
            generationTracker: &semanticGenerationTracker
        )
        semanticSnapshotsByTabID[tabID] = decoded.snapshot
        return decoded
    }

    private func semanticEffectRequest(
        tool: String,
        arguments: [String: Any],
        page: PageHandle,
        tabID: UUID,
        webView: WKWebView
    ) async throws -> [String: Any] {
        let source = try await semanticEffectReference(
            elementID: arguments["elementId"] as? String,
            selector: arguments["selector"] as? String,
            page: page,
            tabID: tabID,
            webView: webView,
            required: tool != "scroll"
        )
        var request: [String: Any] = ["action": tool]
        if let source {
            request["reference"] = SemanticPageJavaScriptSnapshot.effectReference(
                for: source.node,
                in: source.snapshot
            )
        }

        switch tool {
        case "fill":
            request["value"] = arguments["value"] as? String ?? ""
        case "select_option":
            request["values"] = arguments["values"] as? [String] ?? []
        case "scroll":
            let direction = arguments["direction"] as? String ?? "down"
            let amount = (arguments["amount"] as? NSNumber)?.doubleValue ?? 600
            let delta = direction == "up" || direction == "left" ? -amount : amount
            request["x"] = direction == "left" || direction == "right" ? delta : 0
            request["y"] = direction == "up" || direction == "down" ? delta : 0
        case "drag":
            if let target = try await semanticEffectReference(
                elementID: arguments["targetElementId"] as? String,
                selector: arguments["targetSelector"] as? String,
                page: page,
                tabID: tabID,
                webView: webView,
                required: false
            ) {
                request["targetReference"] = SemanticPageJavaScriptSnapshot.effectReference(
                    for: target.node,
                    in: target.snapshot
                )
            } else {
                request["x"] = (arguments["x"] as? NSNumber)?.doubleValue ?? 0
                request["y"] = (arguments["y"] as? NSNumber)?.doubleValue ?? 0
            }
        case "upload_file":
            guard let paths = arguments["paths"] as? [String], !paths.isEmpty else {
                throw BrowserSemanticAutomationError.missingArgument(
                    "upload_file requires at least one path"
                )
            }
            request["files"] = try paths.map { path in
                let url = URL(fileURLWithPath: path).standardizedFileURL
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard data.count <= 5_000_000 else {
                    throw BrowserSemanticAutomationError.fileTooLarge(url.lastPathComponent)
                }
                return [
                    "name": url.lastPathComponent,
                    "data": data.base64EncodedString(),
                ]
            }
        default:
            break
        }
        return request
    }

    private func semanticEffectReference(
        elementID: String?,
        selector: String?,
        page: PageHandle,
        tabID: UUID,
        webView: WKWebView,
        required: Bool
    ) async throws -> (node: SemanticNodeSnapshot, snapshot: SemanticPageSnapshot)? {
        let requestedID = elementID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedSelector = selector?.trimmingCharacters(in: .whitespacesAndNewlines)
        if requestedID?.isEmpty != false, requestedSelector?.isEmpty != false {
            if required {
                throw BrowserSemanticAutomationError.missingArgument(
                    "Supply selector or elementId from take_snapshot"
                )
            }
            return nil
        }

        let reference: SemanticElementReference
        if let requestedID, !requestedID.isEmpty {
            guard let cached = semanticSnapshotsByTabID[tabID] else {
                throw BrowserSemanticAutomationError.snapshotRequired
            }
            let identifier = try SemanticElementIdentifier(parsing: requestedID)
            let matches = cached.nodes.filter { node in
                switch identifier {
                case .local(let localID): return node.localID == localID
                case .legacySub(let ordinal): return node.legacySubID == ordinal
                }
            }
            guard matches.count == 1, let node = matches.first else {
                if matches.isEmpty { throw SemanticReferenceResolutionError.missing(identifier) }
                throw SemanticReferenceResolutionError.ambiguous(
                    identifier: identifier,
                    matches: matches.count
                )
            }
            let prefersLegacyIdentifier: Bool
            if case .legacySub = identifier {
                prefersLegacyIdentifier = true
            } else {
                prefersLegacyIdentifier = false
            }
            reference = node.reference(
                on: cached.page,
                navigationGeneration: cached.navigationGeneration,
                documentGeneration: cached.documentGeneration,
                preferLegacyIdentifier: prefersLegacyIdentifier
            )
        } else {
            guard let requestedSelector, !requestedSelector.isEmpty else {
                throw BrowserSemanticAutomationError.snapshotRequired
            }
            let selected = try await captureSemanticSnapshot(
                page: page,
                tabID: tabID,
                webView: webView,
                selectors: [requestedSelector]
            ).snapshot.nodes.filter { $0.matchedSelectors.contains(requestedSelector) }
            guard selected.count == 1, let node = selected.first else {
                if selected.isEmpty {
                    throw BrowserSemanticAutomationError.selectorMissing(requestedSelector)
                }
                throw BrowserSemanticAutomationError.selectorAmbiguous(
                    requestedSelector,
                    selected.count
                )
            }
            let snapshot = semanticSnapshotsByTabID[tabID]!
            reference = node.reference(
                on: snapshot.page,
                navigationGeneration: snapshot.navigationGeneration,
                documentGeneration: snapshot.documentGeneration
            )
        }

        // This fresh snapshot and typed resolver reject navigation, document
        // replacement, duplicate IDs, frame movement, or fingerprint changes.
        // The JavaScript effect repeats the same check atomically before acting.
        let current = try await captureSemanticSnapshot(
            page: page,
            tabID: tabID,
            webView: webView
        ).snapshot
        let node = try SemanticElementResolver.resolve(reference, in: current)
        return (node, current)
    }

    private enum BrowserSemanticAutomationError: LocalizedError {
        case missingArgument(String)
        case snapshotRequired
        case selectorMissing(String)
        case selectorAmbiguous(String, Int)
        case fileTooLarge(String)

        var errorDescription: String? {
            switch self {
            case .missingArgument(let message): message
            case .snapshotRequired:
                "Take a fresh snapshot before using a semantic element ID."
            case .selectorMissing(let selector):
                "No element matches selector \(selector)."
            case .selectorAmbiguous(let selector, let count):
                "Selector \(selector) is ambiguous (\(count) matches)."
            case .fileTooLarge(let name):
                "\(name) exceeds the 5 MB automation upload limit."
            }
        }
    }

    private func automationJSONString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"Could not encode the tool response.\"}"
        }
        return value
    }

    private func automationEncodedResult<Value: Encodable>(
        _ value: Value,
        key: String
    ) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return automationJSONString(["error": "Could not encode the tool response."])
        }
        return automationJSONString(["ok": true, key: object])
    }

    private func agentSignalSession(for tab: Tab) -> WebKitAgentSignalSession {
        switch tab.sessionKind {
        case .normal:
            return .normal
        case .container:
            return .container(tab.sessionId ?? tab.id)
        case .incognito:
            return .incognito(tab.sessionId ?? tab.id)
        }
    }

    private func activateAgentSignalScope(
        tab: Tab,
        webView: WKWebView,
        permit: AgentExecutionPermit
    ) async throws -> WebKitAgentSignalScope {
        let runtime = BrowserAgentWebKitSignalRuntime.shared
        let scope = try await runtime.activate(
            runID: permit.runID,
            page: PageHandle(windowID: automationWindowId, tabID: tab.id),
            browserSession: agentSignalSession(for: tab)
        )
        if UserDefaults.standard.bool(forKey: "agentWebKitConsoleCaptureEnabled"),
           let capabilities = await agentRunCapabilities(permit.runID),
           capabilities.contains(.pageScript),
           let token = await runtime.consoleBridgeToken(tabID: tab.id) {
            try await webViewManager.activateAgentConsoleBridge(on: webView, token: token)
        }
        return scope
    }

    private func agentRunCapabilities(_ runID: UUID) async -> Set<AgentCapability>? {
        guard let store = try? AgentRunStoreRegistry.store(baseDirectory: BrowserCLI.supportDirectory),
              let run = await store.run(id: runID) else { return nil }
        return run.configuration.enabledCapabilities
    }

    private func performAgentSignalTool(
        _ tool: String,
        arguments: [String: Any],
        permit: AgentExecutionPermit
    ) async -> String {
        guard let tab = tab(for: arguments),
              let webView = automationWebView(for: arguments) else {
            return automationJSONString(["error": "page not found"])
        }
        guard let capabilities = await agentRunCapabilities(permit.runID) else {
            return automationJSONString(["error": "run scope is unavailable"])
        }

        let runtime = BrowserAgentWebKitSignalRuntime.shared
        let scope: WebKitAgentSignalScope
        do {
            scope = try await activateAgentSignalScope(
                tab: tab,
                webView: webView,
                permit: permit
            )
        } catch {
            return automationJSONString(["error": "could not activate the page signal scope"])
        }

        func requireAdditionalCapability(for kind: WebKitAgentSignalKind) -> String? {
            switch kind {
            case .console:
                guard capabilities.contains(.pageScript) else {
                    return "console signals require the pageScript capability"
                }
                guard UserDefaults.standard.bool(forKey: "agentWebKitConsoleCaptureEnabled") else {
                    return "console capture is disabled in Agent settings"
                }
            case .download:
                guard capabilities.contains(.download) else {
                    return "download signals require the download capability"
                }
            case .navigation, .resourceFailure, .dialog, .pageLifecycle:
                break
            }
            return nil
        }

        if tool == "observe_webkit_signals" {
            if let rawDetail = arguments["unsupportedDetail"] as? String {
                guard let detail = WebKitAgentUnsupportedDetail(rawValue: rawDetail) else {
                    return automationJSONString(["error": "unknown unsupportedDetail"])
                }
                do {
                    switch try await runtime.observe(.detail(detail), in: scope) {
                    case .buffered(let snapshot):
                        return automationEncodedResult(snapshot, key: "snapshot")
                    case .unsupported(let unsupported):
                        return automationEncodedResult(unsupported, key: "unsupported")
                    }
                } catch {
                    return automationJSONString(["error": "could not inspect signal support"])
                }
            }

            let rawKinds = arguments["kinds"] as? [String] ?? []
            let parsedKinds = rawKinds.compactMap(WebKitAgentSignalKind.init(rawValue:))
            guard parsedKinds.count == rawKinds.count else {
                return automationJSONString(["error": "unknown WebKit signal kind"])
            }
            var kinds = Set(parsedKinds)
            if kinds.isEmpty {
                kinds = [.navigation, .resourceFailure, .dialog, .pageLifecycle]
                if capabilities.contains(.download) { kinds.insert(.download) }
                if capabilities.contains(.pageScript),
                   UserDefaults.standard.bool(forKey: "agentWebKitConsoleCaptureEnabled") {
                    kinds.insert(.console)
                }
            }
            for kind in kinds {
                if let error = requireAdditionalCapability(for: kind) {
                    return automationJSONString(["error": error])
                }
            }
            let afterSequence = max(
                0,
                (arguments["afterSequence"] as? NSNumber)?.int64Value ?? 0
            )
            let limit = (arguments["limit"] as? NSNumber)?.intValue ?? 200
            do {
                let result = try await runtime.observe(
                    .buffered(.init(
                        kinds: kinds,
                        afterSequence: UInt64(afterSequence),
                        maximumResults: limit
                    )),
                    in: scope
                )
                guard case .buffered(let snapshot) = result else {
                    return automationJSONString(["error": "unexpected signal observation result"])
                }
                return automationEncodedResult(snapshot, key: "snapshot")
            } catch {
                return automationJSONString(["error": "could not read WebKit signals"])
            }
        }

        guard let rawKind = arguments["kind"] as? String,
              let kind = WebKitAgentSignalKind(rawValue: rawKind) else {
            return automationJSONString(["error": "wait_for_webkit_signal requires a valid kind"])
        }
        if let error = requireAdditionalCapability(for: kind) {
            return automationJSONString(["error": error])
        }
        let condition: WebKitAgentSignalWaitCondition
        let rawPhase = arguments["phase"] as? String
        switch kind {
        case .console:
            if let rawLevel = arguments["level"] as? String {
                guard let level = WebKitAgentConsoleLevel(rawValue: rawLevel) else {
                    return automationJSONString(["error": "unknown console level"])
                }
                condition = .console(level)
            } else {
                condition = .console(nil)
            }
        case .navigation:
            if let rawPhase {
                guard let phase = WebKitAgentNavigationPhase(rawValue: rawPhase) else {
                    return automationJSONString(["error": "unknown navigation phase"])
                }
                condition = .navigation(phase)
            } else {
                condition = .kind(.navigation)
            }
        case .resourceFailure:
            condition = .resourceFailure
        case .download:
            if let rawPhase {
                guard let phase = WebKitAgentDownloadPhase(rawValue: rawPhase) else {
                    return automationJSONString(["error": "unknown download phase"])
                }
                let downloadID = (arguments["downloadId"] as? String).flatMap(UUID.init(uuidString:))
                condition = .download(downloadID: downloadID, phase: phase)
            } else {
                condition = .kind(.download)
            }
        case .dialog:
            if let rawPhase {
                guard let dialogKind = WebKitAgentDialogKind(rawValue: rawPhase) else {
                    return automationJSONString(["error": "unknown dialog kind"])
                }
                condition = .dialog(dialogKind)
            } else {
                condition = .dialog(nil)
            }
        case .pageLifecycle:
            if let rawPhase {
                guard let phase = WebKitAgentPageLifecyclePhase(rawValue: rawPhase) else {
                    return automationJSONString(["error": "unknown page lifecycle phase"])
                }
                condition = .pageLifecycle(phase)
            } else {
                condition = .kind(.pageLifecycle)
            }
        }
        let timeout = max(
            0.1,
            min((arguments["timeout"] as? NSNumber)?.doubleValue ?? 15, 60)
        )
        let afterSequence = max(
            0,
            (arguments["afterSequence"] as? NSNumber)?.int64Value ?? 0
        )
        do {
            let request = try WebKitAgentSignalWaitRequest(
                scope: scope,
                condition: condition,
                afterSequence: UInt64(afterSequence),
                maximumTimeout: .seconds(timeout)
            )
            return automationEncodedResult(
                try await runtime.wait(for: request),
                key: "event"
            )
        } catch is CancellationError {
            return automationJSONString(["error": "signal wait cancelled"])
        } catch {
            return automationJSONString(["error": "signal wait timed out or ended"])
        }
    }

    private enum AgentAutomationWaitFailure: Error {
        case timedOut
        case sourceEnded
    }

    private func performAgentWaitTool(
        arguments: [String: Any],
        permit: AgentExecutionPermit
    ) async -> String {
        guard let condition = arguments["condition"] as? String else {
            return automationJSONString(["error": "wait_for requires a condition"])
        }
        guard let tab = tab(for: arguments),
              let webView = automationWebView(for: arguments) else {
            return automationJSONString(["error": "page not found"])
        }
        guard let capabilities = await agentRunCapabilities(permit.runID) else {
            return automationJSONString(["error": "run scope is unavailable"])
        }
        let timeout = max(
            0.1,
            min((arguments["timeout"] as? NSNumber)?.doubleValue ?? 15, 60)
        )

        do {
            switch condition {
            case "load":
                try await waitForWebViewLoad(webView, timeout: timeout)
                return automationJSONString([
                    "ok": true,
                    "condition": condition,
                    "url": webView.url?.absoluteString ?? "",
                    "title": webView.title ?? "",
                ])

            case "url":
                guard let expected = arguments["value"] as? String, !expected.isEmpty else {
                    return automationJSONString(["error": "url wait requires value"])
                }
                let observed = try await waitForWebViewURL(
                    webView,
                    expected: expected,
                    timeout: timeout
                )
                return automationJSONString([
                    "ok": true,
                    "condition": condition,
                    "url": observed.absoluteString,
                ])

            case "selector", "text", "elementState":
                guard capabilities.contains(.pageScript) else {
                    return automationJSONString([
                        "error": "DOM waits require the pageScript capability",
                    ])
                }
                return await performDOMAgentWait(
                    condition: condition,
                    arguments: arguments,
                    webView: webView,
                    timeout: timeout
                )

            case "dialog", "downloadStarted", "downloadCompleted", "pageClosed":
                let runtime = BrowserAgentWebKitSignalRuntime.shared
                let scope = try await activateAgentSignalScope(
                    tab: tab,
                    webView: webView,
                    permit: permit
                )
                let snapshot = try await runtime.snapshot(in: scope)
                let waitCondition: WebKitAgentSignalWaitCondition
                switch condition {
                case "dialog":
                    if let raw = arguments["value"] as? String, !raw.isEmpty {
                        guard let kind = WebKitAgentDialogKind(rawValue: raw) else {
                            return automationJSONString(["error": "unknown dialog kind"])
                        }
                        waitCondition = .dialog(kind)
                    } else {
                        waitCondition = .dialog(nil)
                    }
                case "downloadStarted", "downloadCompleted":
                    guard capabilities.contains(.download) else {
                        return automationJSONString([
                            "error": "download waits require the download capability",
                        ])
                    }
                    let downloadID = (arguments["downloadId"] as? String)
                        .flatMap(UUID.init(uuidString:))
                    waitCondition = .download(
                        downloadID: downloadID,
                        phase: condition == "downloadStarted" ? .started : .completed
                    )
                case "pageClosed":
                    waitCondition = .pageLifecycle(.closed)
                default:
                    throw AgentAutomationWaitFailure.sourceEnded
                }
                let request = try WebKitAgentSignalWaitRequest(
                    scope: scope,
                    condition: waitCondition,
                    afterSequence: snapshot.latestSequence,
                    maximumTimeout: .seconds(timeout)
                )
                return automationEncodedResult(
                    try await runtime.wait(for: request),
                    key: "event"
                )

            default:
                return automationJSONString(["error": "unknown wait_for condition"])
            }
        } catch is CancellationError {
            return automationJSONString(["error": "wait cancelled"])
        } catch AgentAutomationWaitFailure.timedOut {
            return automationJSONString(["error": "wait timed out"])
        } catch {
            return automationJSONString(["error": "wait timed out or the page ended"])
        }
    }

    private func waitForWebViewLoad(
        _ webView: WKWebView,
        timeout: Double
    ) async throws {
        if !webView.isLoading, webView.url != nil { return }
        let pair = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observation = webView.observe(\.isLoading, options: [.initial, .new]) { _, change in
            if let value = change.newValue { pair.continuation.yield(value) }
        }
        defer {
            observation.invalidate()
            pair.continuation.finish()
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await isLoading in pair.stream where !isLoading { return }
                throw AgentAutomationWaitFailure.sourceEnded
            }
            group.addTask {
                try await ContinuousClock().sleep(for: .seconds(timeout))
                throw AgentAutomationWaitFailure.timedOut
            }
            defer { group.cancelAll() }
            guard try await group.next() != nil else {
                throw AgentAutomationWaitFailure.sourceEnded
            }
        }
    }

    private func waitForWebViewURL(
        _ webView: WKWebView,
        expected: String,
        timeout: Double
    ) async throws -> URL {
        let matches: @Sendable (URL) -> Bool = { url in
            if expected.hasSuffix("*") {
                return url.absoluteString.hasPrefix(String(expected.dropLast()))
            }
            return url.absoluteString == expected
        }
        if let url = webView.url, matches(url) { return url }
        let pair = AsyncStream<URL>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observation = webView.observe(\.url, options: [.initial, .new]) { _, change in
            if let wrapped = change.newValue, let value = wrapped {
                pair.continuation.yield(value)
            }
        }
        defer {
            observation.invalidate()
            pair.continuation.finish()
        }
        return try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                for await url in pair.stream where matches(url) { return url }
                throw AgentAutomationWaitFailure.sourceEnded
            }
            group.addTask {
                try await ContinuousClock().sleep(for: .seconds(timeout))
                throw AgentAutomationWaitFailure.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw AgentAutomationWaitFailure.sourceEnded
            }
            return result
        }
    }

    private func performDOMAgentWait(
        condition: String,
        arguments: [String: Any],
        webView: WKWebView,
        timeout: Double
    ) async -> String {
        let token = UUID().uuidString
        let value = arguments["value"] as? String ?? ""
        let selector = arguments["selector"] as? String ?? value
        let state = arguments["state"] as? String ?? "visible"
        let isPresent = arguments["isPresent"] as? Bool ?? true
        guard condition == "text" ? !value.isEmpty : !selector.isEmpty else {
            return automationJSONString(["error": "DOM wait requires a value or selector"])
        }
        guard let tabID = webViewManager.tabId(for: webView) else {
            return automationJSONString(["error": "page not found"])
        }
        let page = PageHandle(windowID: automationWindowId, tabID: tabID)
        do {
            let semanticCondition: PageWaitCondition
            let initialSelectors = condition == "selector" ? [selector] : []
            if condition == "selector" {
                semanticCondition = .selector(selector)
            } else if condition == "text" {
                semanticCondition = .text(.contains(value))
            } else {
                guard let expectedState = SemanticElementState(rawValue: state) else {
                    return automationJSONString(["error": "unknown semantic element state"])
                }
                guard let resolved = try await semanticEffectReference(
                    elementID: value,
                    selector: nil,
                    page: page,
                    tabID: tabID,
                    webView: webView,
                    required: true
                ) else {
                    return automationJSONString(["error": "semantic element is unavailable"])
                }
                semanticCondition = .elementState(
                    reference: resolved.node.reference(
                        on: resolved.snapshot.page,
                        navigationGeneration: resolved.snapshot.navigationGeneration,
                        documentGeneration: resolved.snapshot.documentGeneration,
                        preferLegacyIdentifier: value.hasPrefix("sub-")
                    ),
                    state: expectedState,
                    isPresent: isPresent
                )
            }

            let initial = try await captureSemanticSnapshot(
                page: page,
                tabID: tabID,
                webView: webView,
                selectors: initialSelectors
            )
            let source = WebKitPageWaitEventBuffer(
                page: page,
                initialState: PageWaitState(page: page, semanticSnapshot: initial.snapshot)
            )
            let request = try PageWaitRequest(
                page: page,
                condition: semanticCondition,
                maximumTimeout: .seconds(timeout)
            )
            let localID: String?
            if case .elementState(let reference, _, _) = semanticCondition {
                localID = try SemanticElementResolver.resolve(
                    reference,
                    in: initial.snapshot
                ).localID
            } else {
                localID = nil
            }
            let observation = Task { [weak self, weak webView] in
                guard let self, let webView else {
                    await source.finish()
                    return
                }
                do {
                    let raw = try await webView.callAsyncJavaScript(
                        SemanticPageJavaScript.wait,
                        arguments: ["request": [
                            "condition": condition,
                            "value": value,
                            "selector": selector,
                            "state": state,
                            "isPresent": isPresent,
                            "localID": localID ?? NSNull(),
                            "timeoutMilliseconds": timeout * 1_000,
                            "token": token,
                        ]],
                        in: nil,
                        contentWorld: .defaultClient
                    )
                    guard let dictionary = raw as? [String: Any] else {
                        await source.finish()
                        return
                    }
                    // The native coordinator owns the required timeout and
                    // cancellation contract. A JavaScript-side timeout merely
                    // stops observation; leaving the event stream open lets the
                    // coordinator return the typed PageWaitError.timedOut.
                    guard dictionary["status"] as? String == "matched" else { return }
                    guard let payload = dictionary["snapshot"] else {
                        await source.finish()
                        return
                    }
                    let decoded = try SemanticPageJavaScriptSnapshot.decode(
                        payload,
                        page: page,
                        generationTracker: &self.semanticGenerationTracker
                    )
                    self.semanticSnapshotsByTabID[tabID] = decoded.snapshot
                    await source.emit(.semanticSnapshot(decoded.snapshot))
                } catch {
                    await source.finish()
                }
            }
            defer {
                observation.cancel()
                Task { [weak webView] in
                    guard let webView else { return }
                    _ = try? await webView.callAsyncJavaScript(
                        SemanticPageJavaScript.cancelWait,
                        arguments: ["token": token],
                        in: nil,
                        contentWorld: .defaultClient
                    )
                }
            }
            let result = try await PageWaitCoordinator(source: source).wait(for: request)
            return automationJSONString(automationDictionary(for: result, condition: condition))
        } catch let error as PageWaitError {
            switch error {
            case .timedOut:
                return automationJSONString(["error": "wait timed out"])
            case .cancelled:
                return automationJSONString(["error": "wait cancelled"])
            case .sourceEnded:
                return automationJSONString(["error": "page context ended during wait"])
            case .sourcePageMismatch:
                return automationJSONString(["error": "wait page identity changed"])
            }
        } catch let error as SemanticReferenceResolutionError {
            return automationJSONString([
                "error": "semantic reference became stale during wait: \(String(describing: error))",
            ])
        } catch {
            return automationJSONString([
                "error": Task.isCancelled ? "wait cancelled" : "page context ended during wait",
            ])
        }
    }

    private func automationDictionary(
        for result: PageWaitResult,
        condition: String
    ) -> [String: Any] {
        switch result {
        case .selector(let selector, let references):
            return [
                "ok": true,
                "condition": condition,
                "selector": selector,
                "matchCount": references.count,
                "elementIds": references.map(\.identifier.compatibilityString),
            ]
        case .text(_, let observedText):
            return [
                "ok": true,
                "condition": condition,
                "observedText": String(observedText.prefix(500)),
            ]
        case .elementState(let reference, let state, let isPresent):
            return [
                "ok": true,
                "condition": condition,
                "elementId": reference.identifier.compatibilityString,
                "state": state.rawValue,
                "present": isPresent,
            ]
        default:
            return ["ok": true, "condition": condition]
        }
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
        func scriptRequest(_ script: String) -> (String, [String: Any]) {
            var result = arguments
            result["script"] = script
            return ("evaluate_script", result)
        }

        switch tool {
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
        case "press_key":
            let key = arguments["key"] as? String ?? ""
            return scriptRequest("var e=document.activeElement||document.body,o={key:\(literal(key)),code:\(literal(key)),bubbles:true,cancelable:true};e.dispatchEvent(new KeyboardEvent('keydown',o));e.dispatchEvent(new KeyboardEvent('keyup',o));'pressed'")
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
