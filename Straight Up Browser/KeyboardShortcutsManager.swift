//
//  KeyboardShortcutsManager.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import AppKit

// Only shortcuts the menu bar can't own reliably live here (Ctrl-based combos
// a WKWebView would swallow, bracket navigation, reload, and the hold-Cmd+Q
// quit gate). Everything else is a menu item in the App's .commands, which is
// leak-free and discoverable.
class KeyboardShortcutsManager {
    private var showOmnibar: Binding<Bool>
    private var reloadAction: () -> Void
    private var hardReloadAction: () -> Void
    private var reloadAllTabsAction: () -> Void
    private var goBackAction: () -> Void
    private var goForwardAction: () -> Void
    private var monitorToken: Any?

    // Hold Cmd+Q for 2 seconds to quit (Chrome-style)
    private static let quitHoldDuration: TimeInterval = 2.0
    private var quitHoldStart: Date?
    private var quitHoldTimer: Timer?

    init(
        showOmnibar: Binding<Bool>,
        reloadAction: @escaping () -> Void,
        hardReloadAction: @escaping () -> Void,
        reloadAllTabsAction: @escaping () -> Void,
        goBackAction: @escaping () -> Void,
        goForwardAction: @escaping () -> Void
    ) {
        self.showOmnibar = showOmnibar
        self.reloadAction = reloadAction
        self.hardReloadAction = hardReloadAction
        self.reloadAllTabsAction = reloadAllTabsAction
        self.goBackAction = goBackAction
        self.goForwardAction = goForwardAction
    }

    func setupKeyboardShortcuts() {
        guard monitorToken == nil else { return }

        monitorToken = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self = self else { return event }

            // Quit-hold bookkeeping runs regardless of omnibar state
            switch event.type {
            case .keyUp:
                if self.quitHoldStart != nil && event.charactersIgnoringModifiers?.lowercased() == "q" {
                    self.cancelQuitHold()
                    return nil
                }
                return event
            case .flagsChanged:
                if self.quitHoldStart != nil && !event.modifierFlags.contains(.command) {
                    self.cancelQuitHold()
                }
                return event
            default:
                break
            }

            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])

            // Cmd+Q must be held for 2s; swallow the event (including key
            // repeats) so the Quit menu item never fires from the keyboard
            if mods == .command && event.charactersIgnoringModifiers == "q" {
                if self.quitHoldStart == nil {
                    self.startQuitHold()
                }
                return nil
            }

            // Ctrl+Space toggles the omnibar
            if mods == .control && event.charactersIgnoringModifiers == " " {
                self.showOmnibar.wrappedValue.toggle()
                return nil
            }

            // While the omnibar is open, every other key passes through so
            // editing shortcuts work in the text field
            if self.showOmnibar.wrappedValue {
                return event
            }

            // Ctrl+Tab / Ctrl+Shift+Tab cycle tabs
            if mods.contains(.control) && (event.keyCode == 48 || event.charactersIgnoringModifiers == "\t") {
                let name: Notification.Name = mods.contains(.shift) ? .browserPreviousTab : .browserNextTab
                NotificationCenter.default.post(name: name, object: nil)
                return nil
            }

            if mods == .command {
                switch event.charactersIgnoringModifiers {
                case "n": // Cmd+N is a second New Tab shortcut (Cmd+T is the menu item)
                    NotificationCenter.default.post(name: .browserNewTab, object: nil)
                    return nil
                case "r":
                    self.reloadAction()
                    return nil
                case "[":
                    self.goBackAction()
                    return nil
                case "]":
                    self.goForwardAction()
                    return nil
                default:
                    break
                }
            }

            if event.charactersIgnoringModifiers?.lowercased() == "r" {
                if mods == [.command, .shift] {
                    self.hardReloadAction()
                    return nil
                }
                if mods == [.command, .shift, .option] {
                    self.reloadAllTabsAction()
                    return nil
                }
            }

            return event
        }
    }

    private func startQuitHold() {
        quitHoldStart = Date()
        quitHoldTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.quitHoldStart else { return }
            let progress = Date().timeIntervalSince(start) / Self.quitHoldDuration
            NotificationCenter.default.post(name: .browserQuitHoldProgress, object: nil, userInfo: ["progress": progress])
            if progress >= 1.0 {
                self.quitHoldTimer?.invalidate()
                NSApp.terminate(nil)
            }
        }
    }

    private func cancelQuitHold() {
        quitHoldTimer?.invalidate()
        quitHoldTimer = nil
        quitHoldStart = nil
        NotificationCenter.default.post(name: .browserQuitHoldProgress, object: nil, userInfo: ["progress": 0.0])
    }

    func teardown() {
        cancelQuitHold()
        if let token = monitorToken {
            NSEvent.removeMonitor(token)
            monitorToken = nil
        }
    }
}
