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
        ) { [weak self] _ in
            let tabs = self?.tabs() ?? []
            if tabs.isEmpty {
                print("No tabs open")
            } else {
                print("Open tabs:")
                for (index, tab) in tabs.enumerated() {
                    let activeIndicator = tab.isActive ? " (active)" : ""
                    let title = tab.title
                    let url = tab.url?.absoluteString ?? "about:blank"
                    print("\(index + 1). \(title)\(activeIndicator)")
                    print("   URL: \(url)")
                }
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

        let getPageDataObserver = NotificationCenter.default.addObserver(
            forName: .browserGetPageData,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let urlString = notification.userInfo?["url"] as? String {
                self?.extractPageData(from: urlString)
            }
        }
        observers.append(getPageDataObserver)
    }

    private func extractPageData(from urlString: String) {
        guard let backgroundWebView = backgroundWebView,
              let url = URL(string: urlString) else {
            print("Error: Invalid URL or background web view not available")
            return
        }

        print("Loading page data for: \(urlString)")

        // Load the URL in the background web view
        let request = URLRequest(url: url)
        backgroundWebView.load(request)

        // Wait for the page to load, then extract data
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.extractDataFromLoadedPage(urlString: urlString)
        }
    }

    private func extractDataFromLoadedPage(urlString: String) {
        guard let backgroundWebView = backgroundWebView else { return }

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

        backgroundWebView.evaluateJavaScript(extractionScript) { [weak self] result, error in
            if let error = error {
                print("Error extracting page data: \(error)")
                return
            }

            if let resultString = result as? String {
                // Print the JSON data to stdout for the CLI
                print(resultString)
            } else {
                print("{\"error\": \"Failed to extract page data\", \"url\": \"\(urlString)\"}")
            }
        }
    }

    func cleanup() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
}
