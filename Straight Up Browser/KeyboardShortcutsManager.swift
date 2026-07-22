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
    private weak var webViewManager: WebViewManager?
    private var monitorToken: Any?

    // Hold Cmd+Q to quit (Chrome-style). How long is user-configurable in
    // Settings — quitHoldPercentKey stores 0.08 (quick) to 1.0 (slow), scaled
    // against the max bar duration. See also GeneralSettingsView.
    static let quitHoldPercentKey = "quitHoldPercent"
    static let quitHoldMinPercent: Double = 0.08
    static let quitHoldMaxPercent: Double = 1.0
    static let quitHoldDefaultPercent: Double = 0.8
    private static let quitHoldMaxDuration: TimeInterval = 2.0
    // Fixed beat after the bar reads full, so the total hold time is always
    // predictable — the actual quit work (state persistence) is front-loaded
    // during the hold instead of happening here, where it used to add a
    // variable-length stall.
    private static let postFillQuitDelay: TimeInterval = 0.15

    private static var quitHoldDuration: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: quitHoldPercentKey)
        let percent = stored == 0 ? quitHoldDefaultPercent : stored
        return max(quitHoldMinPercent, min(quitHoldMaxPercent, percent)) * quitHoldMaxDuration
    }

    private var quitHoldStart: Date?
    private var quitHoldTimer: Timer?

    init(
        showOmnibar: Binding<Bool>,
        reloadAction: @escaping () -> Void,
        hardReloadAction: @escaping () -> Void,
        reloadAllTabsAction: @escaping () -> Void,
        goBackAction: @escaping () -> Void,
        goForwardAction: @escaping () -> Void,
        webViewManager: WebViewManager? = nil
    ) {
        self.showOmnibar = showOmnibar
        self.reloadAction = reloadAction
        self.hardReloadAction = hardReloadAction
        self.reloadAllTabsAction = reloadAllTabsAction
        self.goBackAction = goBackAction
        self.goForwardAction = goForwardAction
        self.webViewManager = webViewManager
    }

    func setupKeyboardShortcuts() {
        guard monitorToken == nil else { return }

        monitorToken = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self = self else { return event }

            // Feed the responsive ⇧⌘H cheat sheet; no-op unless it's on screen.
            LiveKeyState.shared.update(from: event)

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
            let store = ShortcutStore.shared

            // Cmd+Q must be held for 2s; swallow the event (including key
            // repeats) so the Quit menu item never fires from the keyboard.
            // The hold gate isn't a normal binding, so it stays a literal.
            if mods == .command && event.charactersIgnoringModifiers == "q" {
                if self.quitHoldStart == nil {
                    self.startQuitHold()
                }
                return nil
            }

            // Omnibar toggle (rebindable)
            if store.shortcut(for: .omnibar).matches(event) {
                self.showOmnibar.wrappedValue.toggle()
                return nil
            }

            // While the omnibar is open, every other key passes through so
            // editing shortcuts work in the text field
            if self.showOmnibar.wrappedValue {
                return event
            }

            // The shortcuts the menu bar can't own reliably, each read live from
            // the store so a rebinding in Settings takes effect immediately.
            if store.shortcut(for: .nextTab).matches(event) {
                NotificationCenter.default.post(name: .browserNextTab, object: nil)
                return nil
            }
            if store.shortcut(for: .previousTab).matches(event) {
                NotificationCenter.default.post(name: .browserPreviousTab, object: nil)
                return nil
            }
            // ponytail: ⌘N stays a fixed second New Tab alias; only the primary
            // (⌘T) is rebindable, via the menu item.
            if mods == .command && event.charactersIgnoringModifiers == "n" {
                NotificationCenter.default.post(name: .browserNewTab, object: nil)
                return nil
            }
            if store.shortcut(for: .reload).matches(event) {
                self.reloadAction()
                return nil
            }
            if store.shortcut(for: .back).matches(event) {
                self.goBackAction()
                return nil
            }
            if store.shortcut(for: .forward).matches(event) {
                self.goForwardAction()
                return nil
            }
            if store.shortcut(for: .hardReload).matches(event) {
                self.hardReloadAction()
                return nil
            }
            if store.shortcut(for: .reloadAll).matches(event) {
                self.reloadAllTabsAction()
                return nil
            }

            return event
        }
    }

    private func startQuitHold() {
        quitHoldStart = Date()
        let duration = Self.quitHoldDuration

        // Do the slow part now, while the bar is still filling, instead of at
        // the end: persisting per-tab page state is what used to make the app
        // linger past a full bar. Front-loading it means the fixed delay below
        // is the *only* wait once the bar reads full.
        webViewManager?.persistInteractionStates()

        // The HUD animates itself 0→1 over the hold (Core Animation, immune to
        // main-thread jitter), so we no longer feed per-frame progress — that
        // irregular 30fps feed was what made the bar jumpy. Just fire once at
        // the end, in .common mode so a tracking run loop (menus, scrollbars)
        // can't delay it.
        let timer = Timer(timeInterval: duration, repeats: false) { _ in
            // Bar reads full here. Wait one fixed beat — not NSApp.terminate,
            // which would re-run the willTerminate persistence we already did
            // above and reintroduce the same variable stall — then pull the
            // windows off screen and end the process directly. Safe: nothing
            // else here depends on the normal termination lifecycle (no
            // applicationShouldTerminate, autosaved SwiftData context, no other
            // willTerminate observers).
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.postFillQuitDelay) {
                NSApp.windows.forEach { $0.orderOut(nil) }
                exit(0)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        quitHoldTimer = timer
        NotificationCenter.default.post(name: .browserQuitHoldProgress, object: nil,
            userInfo: ["progress": 1.0, "duration": duration])
    }

    private func cancelQuitHold() {
        quitHoldTimer?.invalidate()
        quitHoldTimer = nil
        quitHoldStart = nil
        NotificationCenter.default.post(name: .browserQuitHoldProgress, object: nil,
            userInfo: ["progress": 0.0, "duration": 0.0])
    }

    func teardown() {
        cancelQuitHold()
        if let token = monitorToken {
            NSEvent.removeMonitor(token)
            monitorToken = nil
        }
    }
}
