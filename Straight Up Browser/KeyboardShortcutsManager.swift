//
//  KeyboardShortcutsManager.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import AppKit

// Only shortcuts the menu bar can't own reliably live here (Ctrl-based combos
// a WKWebView would swallow, plus bracket navigation and reload). Everything
// else is a menu item in the App's .commands, which is leak-free and discoverable.
class KeyboardShortcutsManager {
    private var showOmnibar: Binding<Bool>
    private var reloadAction: () -> Void
    private var reloadAllTabsAction: () -> Void
    private var goBackAction: () -> Void
    private var goForwardAction: () -> Void
    private var monitorToken: Any?

    init(
        showOmnibar: Binding<Bool>,
        reloadAction: @escaping () -> Void,
        reloadAllTabsAction: @escaping () -> Void,
        goBackAction: @escaping () -> Void,
        goForwardAction: @escaping () -> Void
    ) {
        self.showOmnibar = showOmnibar
        self.reloadAction = reloadAction
        self.reloadAllTabsAction = reloadAllTabsAction
        self.goBackAction = goBackAction
        self.goForwardAction = goForwardAction
    }

    func setupKeyboardShortcuts() {
        guard monitorToken == nil else { return }

        monitorToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])

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

            if mods == [.command, .shift] && event.charactersIgnoringModifiers?.lowercased() == "r" {
                self.reloadAllTabsAction()
                return nil
            }

            return event
        }
    }

    func teardown() {
        if let token = monitorToken {
            NSEvent.removeMonitor(token)
            monitorToken = nil
        }
    }
}
