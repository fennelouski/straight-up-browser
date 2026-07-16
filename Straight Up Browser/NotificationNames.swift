//
//  NotificationNames.swift
//  Straight Up Browser
//
//  The app's internal notification vocabulary. Shared by both the macOS and
//  iPadOS targets (WebViewManager and others reference these). The names are
//  plain string identifiers, so the whole set is platform-agnostic; the Mac-only
//  CLI/menu names simply go unused on iPad.
//

import Foundation

// Notification names
extension Notification.Name {
    static let browserOpenURL = Notification.Name("browserOpenURL")
    static let browserCloseTab = Notification.Name("browserCloseTab")
    static let browserNewTab = Notification.Name("browserNewTab")
    static let reopenLastClosedTab = Notification.Name("reopenLastClosedTab")
    static let showOmnibar = Notification.Name("showOmnibar")
    static let browserListTabs = Notification.Name("browserListTabs")

    // Edit menu
    static let browserFindInPage = Notification.Name("browserFindInPage")
    static let browserFindNext = Notification.Name("browserFindNext")
    static let browserFindPrevious = Notification.Name("browserFindPrevious")

    // Navigation (iPad drives these from .commands; macOS uses its NSEvent monitor)
    static let browserGoBack = Notification.Name("browserGoBack")
    static let browserGoForward = Notification.Name("browserGoForward")
    static let browserReload = Notification.Name("browserReload")

    // View menu
    static let browserZoomIn = Notification.Name("browserZoomIn")
    static let browserZoomOut = Notification.Name("browserZoomOut")
    static let browserZoomReset = Notification.Name("browserZoomReset")
    static let browserPrint = Notification.Name("browserPrint")
    static let browserExportPDF = Notification.Name("browserExportPDF")

    // Link preview (long-press) signals from the injected page script
    static let browserLinkPreviewDown = Notification.Name("browserLinkPreviewDown")
    static let browserLinkPreviewLongPress = Notification.Name("browserLinkPreviewLongPress")
    static let browserLinkPreviewUp = Notification.Name("browserLinkPreviewUp")

    // Hold-Cmd+Q-to-quit progress (userInfo["progress"]: Double, 0 = cancelled)
    static let browserQuitHoldProgress = Notification.Name("browserQuitHoldProgress")

    // Ad blocker toggled in Settings
    static let adBlockChanged = Notification.Name("adBlockChanged")
    // System memory pressure (userInfo["critical"]: Bool)
    static let memoryPressure = Notification.Name("memoryPressure")
    // Cmd+Shift+H shortcut cheat-sheet overlay
    static let browserToggleShortcutOverlay = Notification.Name("browserToggleShortcutOverlay")
    static let browserToggleTabBar = Notification.Name("browserToggleTabBar")
    static let browserHideTabBar = Notification.Name("browserHideTabBar")
    static let browserMinimalTabBar = Notification.Name("browserMinimalTabBar")
    static let browserCompactTabBar = Notification.Name("browserCompactTabBar")
    static let browserWideTabBar = Notification.Name("browserWideTabBar")

    // Bookmarks menu
    static let browserShowBookmarks = Notification.Name("browserShowBookmarks")
    static let browserAddBookmark = Notification.Name("browserAddBookmark")
    static let browserImportBookmarks = Notification.Name("browserImportBookmarks")

    // Window menu
    static let browserNextTab = Notification.Name("browserNextTab")
    static let browserPreviousTab = Notification.Name("browserPreviousTab")
    static let browserSwitchToTab1 = Notification.Name("browserSwitchToTab1")
    static let browserSwitchToTab2 = Notification.Name("browserSwitchToTab2")
    static let browserSwitchToTab3 = Notification.Name("browserSwitchToTab3")
    static let browserSwitchToTab4 = Notification.Name("browserSwitchToTab4")
    static let browserSwitchToTab5 = Notification.Name("browserSwitchToTab5")
    static let browserSwitchToTab6 = Notification.Name("browserSwitchToTab6")
    static let browserSwitchToTab7 = Notification.Name("browserSwitchToTab7")
    static let browserSwitchToTab8 = Notification.Name("browserSwitchToTab8")
    static let browserSwitchToTab9 = Notification.Name("browserSwitchToTab9")

    // Settings
    static let browserShowSettings = Notification.Name("browserShowSettings")
    static let browserTabTitleDisplayModeChanged = Notification.Name("browserTabTitleDisplayModeChanged")

    // CLI data command
    static let browserGetPageData = Notification.Name("browserGetPageData")

    // CLI agent commands (userInfo carries responseFilePath where the
    // observer writes the JSON result)
    static let browserNavigate = Notification.Name("browserNavigate") // userInfo["action"]: back|forward|reload
    static let browserSwitchTab = Notification.Name("browserSwitchTab") // userInfo["index"]: 1-based
    static let browserRunJS = Notification.Name("browserRunJS") // userInfo["script"]
    static let browserWaitForLoad = Notification.Name("browserWaitForLoad") // userInfo["timeout"]
    static let browserScreenshot = Notification.Name("browserScreenshot")
    static let browserRealClick = Notification.Name("browserRealClick") // userInfo["selector"]
    static let browserNotifyUser = Notification.Name("browserNotifyUser") // userInfo["message"]
    static let browserFocusWindow = Notification.Name("browserFocusWindow")
}
