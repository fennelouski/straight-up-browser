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

    // Tracks Control across flagsChanged events so the release edge is visible.
    private var controlWasDown = false

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
                // Letting go of Control commits a ⌃Tab run, the same moment the
                // macOS app switcher commits. Rebinding Next Tab to a chord
                // without Control leaves the run open until the next ordinary
                // tab selection closes it instead.
                let controlDown = event.modifierFlags.contains(.control)
                if self.controlWasDown && !controlDown {
                    NotificationCenter.default.post(name: .browserEndTabCycle, object: nil)
                }
                self.controlWasDown = controlDown
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
            if store.matches(event, .omnibar) {
                self.showOmnibar.wrappedValue.toggle()
                return nil
            }

            // A fixed second way into the shortcut sheet. ⇧⌘H remains the
            // customizable menu binding; ⇧⌘K is deliberately stable and is
            // handled before Quick Open so a website or old binding cannot win.
            if mods == [.command, .shift],
               event.charactersIgnoringModifiers?.lowercased() == "k" {
                NotificationCenter.default.post(
                    name: .browserToggleShortcutOverlay,
                    object: self.webViewManager?.activeWebView?.window
                )
                return nil
            }

            // Websites commonly bind ⌘K themselves. This opt-in route consumes
            // the configured Quick Open chord before WKWebView can deliver it
            // to page JavaScript.
            if self.captureQuickOpenIfNeeded(event) {
                return nil
            }

            // Fixed Mac aliases are handled before the omnibar pass-through.
            // ⌘N deliberately creates a fresh blank tab even when an omnibar
            // query matches an existing tab; ⌘T keeps its undo/reuse behavior.
            if mods == .command && event.charactersIgnoringModifiers == "n" {
                NotificationCenter.default.post(
                    name: .browserForceNewTab,
                    object: self.webViewManager?.activeWebView?.window
                )
                return nil
            }
            // Both newspaper chords save the page behind the omnibar as well as
            // the ordinarily focused page. They are fixed so websites cannot
            // claim them and so the two aliases stay equivalent.
            if (mods == [.command, .option] || mods == [.command, .shift]),
               event.charactersIgnoringModifiers == "n" {
                NotificationCenter.default.post(
                    name: .browserAddToNewspaper,
                    object: self.webViewManager?.activeWebView?.window
                )
                return nil
            }

            // Research commands (Phase 2): rebindable, dispatched here because
            // they have no Mac menu item (the @CommandsBuilder is at its cap).
            if store.matches(event, .anchorSelection) {
                NotificationCenter.default.post(name: .browserAnchorSelection, object: nil)
                return nil
            }
            if store.matches(event, .newWorkspaceDocument) {
                NotificationCenter.default.post(name: .browserNewWorkspaceDocument, object: nil)
                return nil
            }
            if store.matches(event, .transcriptPanel) {
                NotificationCenter.default.post(name: .browserToggleTranscript, object: nil)
                return nil
            }
            if store.matches(event, .auditView) {
                NotificationCenter.default.post(name: .browserToggleAuditView, object: nil)
                return nil
            }

            // While the omnibar is open, every other key passes through so
            // editing shortcuts work in the text field.
            if self.showOmnibar.wrappedValue {
                return event
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

            if self.claimContestedShortcut(event) { return nil }

            return event
        }
    }

    /// Returns true when the browser owns this Quick Open event and the caller
    /// should stop it from reaching the focused website. Kept ahead of the
    /// contested loop below so ⌘K still closes an open omnibar.
    func captureQuickOpenIfNeeded(_ event: NSEvent) -> Bool {
        guard ShortcutPriorityStore.shared.browserWins(.quickOpen, host: currentHost),
              ShortcutStore.shared.shortcut(for: .quickOpen).matches(event) else {
            return false
        }
        showOmnibar.wrappedValue.toggle()
        return true
    }

    private var currentHost: String? { webViewManager?.url?.host() }

    /// Claim a chord the focused page would otherwise swallow. Returns true when
    /// the browser handled it and the event must not travel any further.
    private func claimContestedShortcut(_ event: NSEvent) -> Bool {
        // Nothing here applies over Settings/Downloads/Help — no web page is
        // competing, and ⌘W must still close the window itself.
        guard !Self.auxiliaryWindowIsKey else { return false }

        let store = ShortcutStore.shared
        let priority = ShortcutPriorityStore.shared
        let host = currentHost
        let normalized = ShortcutPriorityStore.normalize(host)
        if priority.currentHost != normalized { priority.currentHost = normalized }

        for command in ShortcutPriorityStore.contestable {
            let chord = store.shortcut(for: command)
            // The ⌃ twin is ours by construction — no page binds it — so it
            // works even where the page is allowed to win the ⌘ chord.
            let viaTwin = store.alternate(for: command)?.matches(event) == true
            guard viaTwin || (chord.matches(event) && priority.browserWins(command, host: host)) else { continue }
            // Two commands on one chord: ambiguous, so leave it to the menu.
            guard store.commandsSharing(chord, excluding: command).isEmpty else { continue }
            guard let action = Self.action(for: command) else { continue }
            action(self)
            return true
        }
        return false
    }

    private static var auxiliaryWindowIsKey: Bool {
        guard let id = NSApp.keyWindow?.identifier?.rawValue else { return false }
        return [
            "settings", "downloads", "newspaper", "agent-tasks",
            "agent-integrations", "agent-audit", "help"
        ].contains { id.contains($0) }
    }

    // What each contested command does when we claim it — the same work the
    // menu item would have done. Quick Open is absent on purpose: it's handled
    // above, before the omnibar pass-through gate.
    static func action(for command: ShortcutCommand) -> ((KeyboardShortcutsManager) -> Void)? {
        switch command {
        case .reload: return { $0.reloadAction() }
        case .hardReload: return { $0.hardReloadAction() }
        case .reloadAll: return { $0.reloadAllTabsAction() }
        case .back: return { $0.goBackAction() }
        case .forward: return { $0.goForwardAction() }
        case .newTab: return post(.browserNewTab)
        case .closeTab: return post(.browserCloseTab)
        case .closeTabSet: return post(.browserCloseTabSet)
        case .reopenTab: return post(.reopenLastClosedTab)
        case .nextTab: return post(.browserNextTab)
        case .previousTab: return post(.browserPreviousTab)
        case .openLocation: return post(.showOmnibar)
        case .findInPage: return post(.browserFindInPage)
        case .addBookmark: return post(.browserAddBookmark)
        case .captureSource: return post(.browserCaptureSource)
        case .printPage: return post(.browserPrint)
        case .toggleTabBar: return post(.browserToggleTabBar)
        default: return nil
        }
    }

    private static func post(_ name: Notification.Name) -> (KeyboardShortcutsManager) -> Void {
        { _ in NotificationCenter.default.post(name: name, object: nil) }
    }

    #if DEBUG
    // ponytail: the one thing that can silently rot — a command offered in
    // Settings that the monitor has no way to dispatch.
    static func selfCheck() {
        for command in ShortcutPriorityStore.contestable where command != .quickOpen {
            assert(action(for: command) != nil, "no dispatch for contested command \(command.id)")
        }
        // Defaults, not live settings — the user is allowed to flip either way.
        assert(ShortcutPriorityStore.defaultWins.contains(ShortcutCommand.reload.id))
        assert(!ShortcutPriorityStore.defaultWins.contains(ShortcutCommand.findInPage.id))
        assert(ShortcutPriorityStore.normalize("WWW.Example.com") == "example.com")
    }
    #endif

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
            Task { @MainActor in
                self?.openReleaseWindow()
            }
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
            Task { @MainActor in
                self?.performQuitNow()
            }
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
