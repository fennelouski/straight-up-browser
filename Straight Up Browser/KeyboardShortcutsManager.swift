//
//  KeyboardShortcutsManager.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
#if os(macOS)
import WebKit
#endif

class KeyboardShortcutsManager {
    private var tabManager: TabManager
    private var navigationManager: NavigationManager
    private var webViewManager: WebViewManager?
    private var showOmnibar: Binding<Bool>
    private var activeTab: () -> Tab?
    private var reloadAction: () -> Void
    private var goBackAction: () -> Void
    private var goForwardAction: () -> Void
    private var hardReloadAction: () -> Void
    private var switchToNextTabAction: () -> Void
    private var switchToPreviousTabAction: () -> Void
    private var switchToTabAction: (Int) -> Void
    private var closeTabAction: () -> Void
    private var reloadAllTabsAction: () -> Void
    private var setTabBarWidth: (Double) -> Void
    private var getWindowWidth: () -> Double

    // For detecting double Control key presses
    private var lastControlPressTime: Date?
    private let doublePressThreshold: TimeInterval = 0.5 // 500ms window for double press

    init(
        tabManager: TabManager,
        navigationManager: NavigationManager,
        webViewManager: WebViewManager?,
        showOmnibar: Binding<Bool>,
        activeTab: @escaping () -> Tab?,
        reloadAction: @escaping () -> Void,
        goBackAction: @escaping () -> Void,
        goForwardAction: @escaping () -> Void,
        hardReloadAction: @escaping () -> Void,
        switchToNextTabAction: @escaping () -> Void,
        switchToPreviousTabAction: @escaping () -> Void,
        switchToTabAction: @escaping (Int) -> Void,
        closeTabAction: @escaping () -> Void,
        reloadAllTabsAction: @escaping () -> Void,
        setTabBarWidth: @escaping (Double) -> Void,
        getWindowWidth: @escaping () -> Double
    ) {
        self.tabManager = tabManager
        self.navigationManager = navigationManager
        self.webViewManager = webViewManager
        self.showOmnibar = showOmnibar
        self.activeTab = activeTab
        self.reloadAction = reloadAction
        self.goBackAction = goBackAction
        self.goForwardAction = goForwardAction
        self.hardReloadAction = hardReloadAction
        self.switchToNextTabAction = switchToNextTabAction
        self.switchToPreviousTabAction = switchToPreviousTabAction
        self.switchToTabAction = switchToTabAction
        self.closeTabAction = closeTabAction
        self.reloadAllTabsAction = reloadAllTabsAction
        self.setTabBarWidth = setTabBarWidth
        self.getWindowWidth = getWindowWidth
    }

    func setupKeyboardShortcuts() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Debug logging for troubleshooting - show ALL keyboard events
            let modifiers = self.formatModifiers(event.modifierFlags)
            let chars = event.charactersIgnoringModifiers ?? ""
            let keyCode = event.keyCode
            Logger.log("🔹 KEY EVENT: [\(modifiers)] + '\(chars)' (keyCode: \(keyCode))", type: "KeyboardShortcutsManager")

            // Check if we're in an input field that should receive normal typing
            if self.shouldAllowNormalTyping(for: event) {
                Logger.log("✅ ALLOWED: Normal typing in input field", type: "KeyboardShortcutsManager")
                return event // Allow normal typing in input fields
            }

            // Check for double Control key press to toggle tab title display
            if self.handleDoubleControlPress(event) {
                return nil
            }

            if event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == " " {
                Logger.log("🎯 COMMAND: Control+Space → Toggle omnibar", type: "KeyboardShortcutsManager")
                self.showOmnibar.wrappedValue.toggle()
                return nil
            }

            // Control+Tab shortcuts (before command checks so they take precedence)
            if event.modifierFlags.contains(.control) && event.keyCode == 48 { // Tab key (0x30)
                if event.modifierFlags.contains(.shift) {
                    // Control+Shift+Tab - Previous tab
                    Logger.log("🎯 COMMAND: Control+Shift+Tab → Switch to previous tab", type: "KeyboardShortcutsManager")
                    NotificationCenter.default.post(name: .browserPreviousTab, object: nil)
                    return nil
                } else {
                    // Control+Tab - Next tab
                    Logger.log("🎯 COMMAND: Control+Tab → Switch to next tab", type: "KeyboardShortcutsManager")
                    NotificationCenter.default.post(name: .browserNextTab, object: nil)
                    return nil
                }
            }
            // Alternative: Check for Tab character
            if event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == "\t" {
                if event.modifierFlags.contains(.shift) {
                    Logger.log("🎯 COMMAND: Control+Shift+Tab → Switch to previous tab", type: "KeyboardShortcutsManager")
                    NotificationCenter.default.post(name: .browserPreviousTab, object: nil)
                    return nil
                } else {
                    Logger.log("🎯 COMMAND: Control+Tab → Switch to next tab", type: "KeyboardShortcutsManager")
                    NotificationCenter.default.post(name: .browserNextTab, object: nil)
                    return nil
                }
            }

            // Check for Command key combinations
            if event.modifierFlags.contains(.command) {
                // Cmd+Option+` - Hide tab bar
                if event.modifierFlags.contains(.option) && (event.charactersIgnoringModifiers == "`" || event.charactersIgnoringModifiers == "~") {
                    Logger.log("🎯 COMMAND: Cmd+Option+` → Hide tab bar", type: "KeyboardShortcutsManager")
                    NotificationCenter.default.post(name: .browserHideTabBar, object: nil)
                    return nil
                }

                // Cmd+Option+1 - Minimal favicon view (just icons)
                if event.modifierFlags.contains(.option) && event.charactersIgnoringModifiers == "1" {
                    Logger.log("🎯 COMMAND: Cmd+Option+1 → Set minimal tab bar view", type: "KeyboardShortcutsManager")
                    NotificationCenter.default.post(name: .browserMinimalTabBar, object: nil)
                    return nil
                }

                // Cmd+Option+2 - Compact view (favicon + ~14 chars)
                if event.modifierFlags.contains(.option) && event.charactersIgnoringModifiers == "2" {
                    Logger.log("🎯 COMMAND: Cmd+Option+2 → Set compact tab bar view", type: "KeyboardShortcutsManager")
                    NotificationCenter.default.post(name: .browserCompactTabBar, object: nil)
                    return nil
                }

                // Cmd+Option+3 - Wide view (20% of window or 200px, whichever is greater)
                if event.modifierFlags.contains(.option) && event.charactersIgnoringModifiers == "3" {
                    Logger.log("🎯 COMMAND: Cmd+Option+3 → Set wide tab bar view", type: "KeyboardShortcutsManager")
                    NotificationCenter.default.post(name: .browserWideTabBar, object: nil)
                    return nil
                }

                // Direct tab switching (Cmd + 1-9)
                if !event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.shift) {
                    if let characters = event.charactersIgnoringModifiers, let number = Int(characters), number >= 1 && number <= 9 {
                        Logger.log("🎯 COMMAND: Cmd+\(number) → Switch to tab \(number)", type: "KeyboardShortcutsManager")
                        let notificationName: Notification.Name
                        switch number {
                        case 1: notificationName = .browserSwitchToTab1
                        case 2: notificationName = .browserSwitchToTab2
                        case 3: notificationName = .browserSwitchToTab3
                        case 4: notificationName = .browserSwitchToTab4
                        case 5: notificationName = .browserSwitchToTab5
                        case 6: notificationName = .browserSwitchToTab6
                        case 7: notificationName = .browserSwitchToTab7
                        case 8: notificationName = .browserSwitchToTab8
                        case 9: notificationName = .browserSwitchToTab9
                        default: return event
                        }
                        NotificationCenter.default.post(name: notificationName, object: nil)
                        return nil
                    }
                }

                // Cmd+Shift+R - Reload all tabs
                if event.modifierFlags.contains(.shift) && !event.modifierFlags.contains(.option) && event.charactersIgnoringModifiers == "R" {
                    Logger.log("🎯 COMMAND: Cmd+Shift+R → Reload all tabs", type: "KeyboardShortcutsManager")
                    self.reloadAllTabsAction()
                    return nil
                }

                // Other Cmd shortcuts
                if !event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.shift) {
                    switch event.charactersIgnoringModifiers {
                    case "t", "n":
                        Logger.log("🎯 COMMAND: Cmd+T/Cmd+N → New tab", type: "KeyboardShortcutsManager")
                        NotificationCenter.default.post(name: .browserNewTab, object: nil)
                        return nil
                    case "w":
                        Logger.log("🎯 COMMAND: Cmd+W → Close tab", type: "KeyboardShortcutsManager")
                        self.closeTabAction()
                        return nil
                    case "r":
                        Logger.log("🎯 COMMAND: Cmd+R → Reload page", type: "KeyboardShortcutsManager")
                        self.reloadAction()
                        return nil
                    case "l":
                        Logger.log("🎯 COMMAND: Cmd+L → Focus omnibar", type: "KeyboardShortcutsManager")
                        self.showOmnibar.wrappedValue.toggle()
                        return nil
                    case "o":
                        Logger.log("🎯 COMMAND: Cmd+O → Focus omnibar", type: "KeyboardShortcutsManager")
                        self.showOmnibar.wrappedValue.toggle()
                        return nil
                    case "[":
                        Logger.log("🎯 COMMAND: Cmd+[ → Go back", type: "KeyboardShortcutsManager")
                        self.goBackAction()
                        return nil
                    case "]":
                        Logger.log("🎯 COMMAND: Cmd+] → Go forward", type: "KeyboardShortcutsManager")
                        self.goForwardAction()
                        return nil
                    default:
                        break
                    }
                }
            }

            Logger.log("❌ IGNORED: No matching keyboard shortcut", type: "KeyboardShortcutsManager")
            return event
        }
    }

    private func formatModifiers(_ modifierFlags: NSEvent.ModifierFlags) -> String {
        var modifiers: [String] = []

        if modifierFlags.contains(.command) {
            modifiers.append("Cmd")
        }
        if modifierFlags.contains(.option) {
            modifiers.append("Option")
        }
        if modifierFlags.contains(.control) {
            modifiers.append("Control")
        }
        if modifierFlags.contains(.shift) {
            modifiers.append("Shift")
        }

        return modifiers.isEmpty ? "None" : modifiers.joined(separator: "+")
    }

    private func shouldAllowNormalTyping(for event: NSEvent) -> Bool {
        // Always allow typing when omnibar is open
        if showOmnibar.wrappedValue {
            // Only allow normal typing (no modifiers) when omnibar is open
            let hasModifiers = event.modifierFlags.contains(.command) ||
                              event.modifierFlags.contains(.option) ||
                              event.modifierFlags.contains(.control) ||
                              event.modifierFlags.contains(.shift)
            return !hasModifiers
        }

        // Get the current first responder
        guard let firstResponder = NSApp.keyWindow?.firstResponder else {
            return false
        }

        // Allow typing if the first responder is a WebView or text input field
        // AND the event has no modifier keys (normal typing)
        let isInputField = firstResponder is NSTextField ||
                          firstResponder is NSTextView ||
                          firstResponder is NSSecureTextField
        #if os(macOS)
        let isWebView = firstResponder is WKWebView
        #else
        let isWebView = false
        #endif

        if isInputField || isWebView {
            // Only allow normal typing (no modifiers) to pass through to input fields
            let hasModifiers = event.modifierFlags.contains(.command) ||
                              event.modifierFlags.contains(.option) ||
                              event.modifierFlags.contains(.control) ||
                              event.modifierFlags.contains(.shift)
            return !hasModifiers
        }

        return false
    }

    private func handleDoubleControlPress(_ event: NSEvent) -> Bool {
        // Check if Control key was pressed (without other modifiers for now)
        if event.keyCode == 59 || event.keyCode == 62 { // Left Control (59) or Right Control (62)
            let currentTime = Date()
            var isDoublePress = false

            if let lastPressTime = lastControlPressTime {
                let timeDifference = currentTime.timeIntervalSince(lastPressTime)
                if timeDifference <= doublePressThreshold {
                    isDoublePress = true
                }
            }

            lastControlPressTime = currentTime

            if isDoublePress {
                Logger.log("🎯 COMMAND: Double Control press → Toggle tab title display mode", type: "KeyboardShortcutsManager")
                SettingsManager.shared.showWebpageTitlesInTabs.toggle()
                NotificationCenter.default.post(name: .browserTabTitleDisplayModeChanged, object: nil)
                return true
            }
        }

        return false
    }
}