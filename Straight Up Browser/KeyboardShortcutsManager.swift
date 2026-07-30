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
    static let overrideWebsiteQuickOpenKey = "overrideWebsiteQuickOpen"

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
    // If the bar fills, you get a short release window to let go of ⌘Q.
    // Only when the key is released inside this window do we quit; otherwise
    // the hold is canceled and must be started again.
    private static let quitReleaseWindowDuration: TimeInterval = 1.5

    private enum QuitHoldState {
        case inactive
        case holding
        case releaseWindowOpen
    }

    private static var quitHoldDuration: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: quitHoldPercentKey)
        let percent = stored == 0 ? quitHoldDefaultPercent : stored
        return max(quitHoldMinPercent, min(quitHoldMaxPercent, percent)) * quitHoldMaxDuration
    }

    private var quitHoldState: QuitHoldState = .inactive
    private var quitHoldTimer: Timer?
    private var quitHoldReleaseTimer: Timer?

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
                if self.quitHoldState != .inactive && event.charactersIgnoringModifiers?.lowercased() == "q" {
                    self.handleQuitKeyRelease()
                    return nil
                }
                return event
            case .flagsChanged:
                if self.quitHoldState != .inactive && !event.modifierFlags.contains(.command) {
                    self.terminateHoldBecauseModifierLost()
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
                self.startQuitHold()
                return nil
            }

            // Omnibar toggle (rebindable)
            if store.shortcut(for: .omnibar).matches(event) {
                self.showOmnibar.wrappedValue.toggle()
                return nil
            }

            // Websites commonly bind ⌘K themselves. This opt-in route consumes
            // the configured Quick Open chord before WKWebView can deliver it
            // to page JavaScript.
            if self.captureQuickOpenIfNeeded(event) {
                return nil
            }

            // While the omnibar is open, every other key passes through so
            // editing shortcuts work in the text field
            if self.showOmnibar.wrappedValue {
                return event
            }

            // The shortcuts the menu bar can't own reliably, each read live from
            // the store so a rebinding in Settings takes effect immediately.
            if self.hasNoConflict(for: .closeTabSet) && store.shortcut(for: .closeTabSet).matches(event) {
                NotificationCenter.default.post(name: .browserCloseTabSet, object: nil)
                return nil
            }
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
            // Settings > General > "⌘P and ⌘\ navigate": frees the everyday
            // print chord for navigation instead. Fixed aliases, not rebindable
            // — they piggyback on whatever Back/Forward already do.
            if SettingsManager.shared.expandBackForwardShortcuts {
                if mods == .command && event.charactersIgnoringModifiers == "p" {
                    self.goBackAction()
                    return nil
                }
                if mods == .command && event.charactersIgnoringModifiers == "\\" {
                    self.goForwardAction()
                    return nil
                }
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

    /// Returns true when the browser owns this Quick Open event and the caller
    /// should stop it from reaching the focused website.
    func captureQuickOpenIfNeeded(_ event: NSEvent) -> Bool {
        guard SettingsManager.shared.overrideWebsiteQuickOpen,
              ShortcutStore.shared.shortcut(for: .quickOpen).matches(event) else {
            return false
        }
        showOmnibar.wrappedValue.toggle()
        return true
    }

    private func hasNoConflict(for command: ShortcutCommand) -> Bool {
        let shortcut = ShortcutStore.shared.shortcut(for: command)
        return ShortcutStore.shared.commandsSharing(shortcut, excluding: command).isEmpty
    }

    private func startQuitHold() {
        guard quitHoldState == .inactive else { return }
        clearQuitHoldTimers()
        quitHoldState = .holding
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
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            self?.openReleaseWindow()
        }
        RunLoop.main.add(timer, forMode: .common)
        quitHoldTimer = timer
        NotificationCenter.default.post(name: .browserQuitHoldProgress, object: nil,
            userInfo: ["progress": 1.0, "duration": duration])
    }

    private func openReleaseWindow() {
        guard quitHoldState == .holding else { return }
        quitHoldState = .releaseWindowOpen

        // If the key wasn't released during this window, quit at the end so a
        // long hold still closes this app instead of leaking into the next one.
        let releaseWindowTimer = Timer(timeInterval: Self.quitReleaseWindowDuration, repeats: false) { [weak self] _ in
            self?.performQuitNow()
        }
        RunLoop.main.add(releaseWindowTimer, forMode: .common)
        quitHoldReleaseTimer = releaseWindowTimer
    }

    private func handleQuitKeyRelease() {
        switch quitHoldState {
        case .holding:
            cancelQuitHold()
        case .releaseWindowOpen:
            performQuitNow()
        default:
            break
        }
    }

    private func terminateHoldBecauseModifierLost() {
        switch quitHoldState {
        case .releaseWindowOpen:
            cancelQuitHold()
        case .holding:
            cancelQuitHold()
        default:
            break
        }
    }

    private func performQuitNow() {
        clearQuitHoldTimers()
        quitHoldState = .inactive
        NotificationCenter.default.post(name: .browserQuitHoldProgress, object: nil,
            userInfo: ["progress": 0.0, "duration": 0.0])
        NSApp.windows.forEach { $0.orderOut(nil) }
        exit(0)
    }

    private func cancelQuitHold() {
        clearQuitHoldTimers()
        quitHoldState = .inactive
        NotificationCenter.default.post(name: .browserQuitHoldProgress, object: nil,
            userInfo: ["progress": 0.0, "duration": 0.0])
    }

    private func clearQuitHoldTimers(stopReleaseTimer: Bool = true) {
        quitHoldTimer?.invalidate()
        quitHoldTimer = nil
        if stopReleaseTimer {
            quitHoldReleaseTimer?.invalidate()
            quitHoldReleaseTimer = nil
        }
    }

    func teardown() {
        cancelQuitHold()
        if let token = monitorToken {
            NSEvent.removeMonitor(token)
            monitorToken = nil
        }
    }
}
