//
//  KeyboardShortcutsManager.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import AppKit
import QuartzCore

// Only shortcuts the menu bar can't own reliably live here (Ctrl-based combos
// a WKWebView would swallow, bracket navigation, reload, and the hold-Cmd+Q
// quit gate). Everything else is a menu item in the App's .commands, which is
// leak-free and discoverable.
class KeyboardShortcutsManager {
    static let overrideWebsiteQuickOpenKey = "overrideWebsiteQuickOpen"

    private var showOmnibar: Binding<Bool>
    private let windowsForQuit: () -> [NSWindow]
    private let terminateApplication: () -> Void
    private var reloadAction: () -> Void
    private var hardReloadAction: () -> Void
    private var reloadAllTabsAction: () -> Void
    private var goBackAction: () -> Void
    private var goForwardAction: () -> Void
    private weak var webViewManager: WebViewManager?
    private var monitorToken: Any?
    private var deactivateToken: Any?

    // Hold Cmd+Q to quit (Chrome-style). How long is user-configurable in
    // Settings — quitHoldPercentKey stores 0.08 (quick) to 1.0 (slow), scaled
    // against the max bar duration. See also GeneralSettingsView.
    static let quitHoldPercentKey = "quitHoldPercent"
    static let quitHoldMinPercent: Double = 0.08
    static let quitHoldMaxPercent: Double = 1.0
    static let quitHoldDefaultPercent: Double = 0.8
    private static let quitHoldMaxDuration: TimeInterval = 2.0

    private enum QuitHoldState {
        case inactive
        case holding
        case terminating
    }

    private static var quitHoldDuration: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: quitHoldPercentKey)
        let percent = stored == 0 ? quitHoldDefaultPercent : stored
        return max(quitHoldMinPercent, min(quitHoldMaxPercent, percent)) * quitHoldMaxDuration
    }

    // Tracks Control across flagsChanged events so the release edge is visible.
    private var controlWasDown = false

    private var quitHoldState: QuitHoldState = .inactive
    private var quitTiming: QuitHoldTiming?
    private var quitPanel: NSPanel?
    private var quitPreparation: Task<Void, Never>?
    private var windowFadeTask: Task<Void, Never>?
    private var fadedWindows: [(window: NSWindow, alpha: CGFloat)] = []
    private weak var windowBeforeQuit: NSWindow?

    init(
        showOmnibar: Binding<Bool>,
        reloadAction: @escaping () -> Void,
        hardReloadAction: @escaping () -> Void,
        reloadAllTabsAction: @escaping () -> Void,
        goBackAction: @escaping () -> Void,
        goForwardAction: @escaping () -> Void,
        webViewManager: WebViewManager? = nil,
        windowsForQuit: @escaping () -> [NSWindow] = { NSApp.windows },
        terminateApplication: @escaping () -> Void = { NSApp.terminate(nil) }
    ) {
        self.showOmnibar = showOmnibar
        self.reloadAction = reloadAction
        self.hardReloadAction = hardReloadAction
        self.reloadAllTabsAction = reloadAllTabsAction
        self.goBackAction = goBackAction
        self.goForwardAction = goForwardAction
        self.webViewManager = webViewManager
        self.windowsForQuit = windowsForQuit
        self.terminateApplication = terminateApplication
    }

    func setupKeyboardShortcuts() {
        guard monitorToken == nil else { return }

        deactivateToken = NotificationCenter.default.addMainActorObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.cancelQuitHold()
        }

        monitorToken = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self = self else { return event }

            // Feed the responsive ⇧⌘H cheat sheet; no-op unless it's on screen.
            LiveKeyState.shared.update(from: event)

            // Quit-hold bookkeeping runs regardless of omnibar state
            switch event.type {
            case .keyUp:
                if self.quitHoldState == .holding && event.charactersIgnoringModifiers?.lowercased() == "q" {
                    self.handleQuitKeyRelease(at: event.timestamp)
                    return nil
                }
                return event
            case .flagsChanged:
                if self.quitHoldState == .holding && !event.modifierFlags.contains(.command) {
                    self.handleQuitKeyRelease(at: event.timestamp)
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

            if self.quitHoldState == .holding && event.keyCode == 53 {
                self.cancelQuitHold()
                return nil
            }

            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let store = ShortcutStore.shared

            // Swallow Cmd+Q and its repeats so the Quit menu item never fires.
            // Only a fresh press can start a hold, including after Escape.
            // The hold gate isn't a normal binding, so it stays a literal.
            if mods == .command && event.charactersIgnoringModifiers == "q" {
                if !event.isARepeat {
                    self.startQuitHold(at: event.timestamp)
                }
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
            // ⇧⌘N saves the page behind the omnibar as well as the ordinarily
            // focused page, and is fixed so websites cannot claim it.
            // Two bugs used to live here. ⌥⌘N was a second alias, and a local
            // monitor runs before menu key equivalents, so it silently ate
            // Scratch Pad's ⌥⌘N and made that Settings row a lie. ⇧⌘N itself
            // never fired: charactersIgnoringModifiers keeps Shift, so the
            // comparison was "N" == "n". One chord per action, lowercased.
            if mods == [.command, .shift],
               event.charactersIgnoringModifiers?.lowercased() == "n" {
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
            if store.matches(event, .bibliographySearch) {
                NotificationCenter.default.post(name: .browserToggleBibliography, object: nil)
                return nil
            }
            if store.matches(event, .claimsPanel) {
                NotificationCenter.default.post(name: .browserToggleClaims, object: nil)
                return nil
            }
            if store.matches(event, .importReport) {
                NotificationCenter.default.post(name: .browserImportReport, object: nil)
                return nil
            }
            // Dispatched here rather than left to its menu item: the chord is
            // pressed with a login field focused, which means WKWebView sees it
            // first and a page that binds it would take the fill away.
            if store.matches(event, .passwordPicker) {
                NotificationCenter.default.post(name: .browserShowPasswordPicker, object: nil)
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
                    // With nothing to go forward to the chord is dead weight, so
                    // spend it on the login in front of you: fill and sign in.
                    if self.webViewManager?.canGoForward == true {
                        self.goForwardAction()
                    } else {
                        NotificationCenter.default.post(name: .browserFillAndSubmitPassword, object: nil)
                    }
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
    // Chords claimed outside the rebindable store: this monitor's fixed
    // aliases and the hardcoded menu items. ShortcutStore.selfCheck() proves
    // no two *registered* defaults collide; nothing proved a registered
    // default did not land on one of these until ⌥⌘N did.
    static let fixedChords: [Shortcut: String] = [
        Shortcut(key: "n", command: true): "New Tab (fixed alias)",
        Shortcut(key: "n", command: true, shift: true): "Add to Newspaper",
        Shortcut(key: "k", command: true, shift: true): "Keyboard Shortcuts (fixed alias)",
        Shortcut(key: "i", command: true, option: true): "Developer Tools",
        Shortcut(key: "j", command: true, option: true): "Developer Console",
        Shortcut(key: "c", command: true, option: true): "Select Page Element",
        // Settings > General > "⌘P and ⌘\\ navigate Back/Forward" is ON by
        // default, and this monitor swallows the chord, so a registered default
        // landing here would never fire. Password Fill shipped on ⌘\\ and did
        // exactly that. ⌘P is deliberately absent: Export as PDF shares it, and
        // the same setting is what arbitrates between them.
        Shortcut(key: "\\", command: true): "Go Forward (Settings > General alias)",
    ]

    // ponytail: the two things that can silently rot — a command offered in
    // Settings that the monitor has no way to dispatch, and one that lands on
    // a chord something else already claims.
    static func selfCheck() {
        for command in ShortcutCommand.all {
            assert(
                fixedChords[command.defaultShortcut] == nil,
                "\(command.id) defaults to \(command.defaultShortcut.displayString), "
                    + "already fixed for \(fixedChords[command.defaultShortcut] ?? "")"
            )
        }
        for command in ShortcutPriorityStore.contestable where command != .quickOpen {
            assert(action(for: command) != nil, "no dispatch for contested command \(command.id)")
        }
        // Defaults, not live settings — the user is allowed to flip either way.
        assert(ShortcutPriorityStore.defaultWins.contains(ShortcutCommand.reload.id))
        assert(!ShortcutPriorityStore.defaultWins.contains(ShortcutCommand.findInPage.id))
        assert(ShortcutPriorityStore.normalize("WWW.Example.com") == "example.com")
    }
    #endif

    func startQuitHold(at uptime: TimeInterval) {
        guard quitHoldState == .inactive else { return }
        quitHoldState = .holding
        let timing = QuitHoldTiming(startUptime: uptime,
                                    duration: Self.quitHoldDuration)
        quitTiming = timing
        windowBeforeQuit = NSApp.keyWindow

        // A separate key panel keeps receiving release events even after all
        // browser windows have faded away. Keeping them alive preserves the session.
        let panel = QuitHoldPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 150),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: QuitHoldPrompt(timing: timing))
        if let frame = windowBeforeQuit?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 160, y: frame.midY - 75))
        } else {
            panel.center()
        }
        quitPanel = panel
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            panel.animator().alphaValue = 1
        }

        // Commit the complete layer animation before persistence can occupy the
        // main thread. TimelineView alone cannot render frames during that work.
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
        quitPreparation = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.webViewManager?.prepareInteractionStatesForTermination()
            await BrowsingHistoryStore.shared.flush()
            await DownloadManager.shared.flush()
        }
        windowFadeTask = Task { @MainActor [weak self] in
            let remaining = max(0, timing.deadline - ProcessInfo.processInfo.systemUptime)
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard let self, self.quitHoldState == .holding else { return }
            self.fadeWindowsForQuit()
        }
    }

    func fadeWindowsForQuit() {
        guard let panel = quitPanel else { return }
        fadedWindows = windowsForQuit().filter { $0.isVisible && $0 !== panel }
            .map { ($0, $0.alphaValue) }
        let windows = fadedWindows
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.35
            for (window, _) in windows { window.animator().alphaValue = 0 }
        }
        // Keep the windows alive and retain the keyboard monitor until release.
    }

    func handleQuitKeyRelease(at uptime: TimeInterval) {
        guard quitHoldState == .holding, let timing = quitTiming else { return }
        if timing.isReady(at: uptime) {
            performQuitNow()
        } else {
            cancelQuitHold()
        }
    }

    private func performQuitNow() {
        quitHoldState = .terminating
        windowFadeTask?.cancel()
        // Make release immediate visually, then allow the normal termination
        // delegate and willTerminate observers to finish saving and updating.
        quitPanel?.orderOut(nil)
        windowsForQuit().forEach { $0.orderOut(nil) }
        terminateApplication()
    }

    func cancelQuitHold() {
        guard quitHoldState == .holding else { return }
        quitHoldState = .inactive
        quitTiming = nil
        windowFadeTask?.cancel()
        quitPreparation?.cancel()
        webViewManager?.cancelInteractionStateTerminationPreparation()
        quitPanel?.orderOut(nil)
        quitPanel = nil
        let windows = fadedWindows
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            for (window, alpha) in windows { window.animator().alphaValue = alpha }
        }
        fadedWindows.removeAll()
        windowBeforeQuit?.makeKeyAndOrderFront(nil)
    }

    func teardown() {
        cancelQuitHold()
        windowFadeTask?.cancel()
        quitPreparation?.cancel()
        quitPanel?.orderOut(nil)
        if let token = deactivateToken {
            NotificationCenter.default.removeObserver(token)
            deactivateToken = nil
        }
        if let token = monitorToken {
            NSEvent.removeMonitor(token)
            monitorToken = nil
        }
    }
}

/// Both the displayed bar and release eligibility use this monotonic deadline.
struct QuitHoldTiming {
    let startUptime: TimeInterval
    let duration: TimeInterval

    var deadline: TimeInterval { startUptime + duration }

    func progress(at uptime: TimeInterval) -> Double {
        guard duration > 0, !isReady(at: uptime) else { return 1 }
        return min(1, max(0, (uptime - startUptime) / duration))
    }

    func isReady(at uptime: TimeInterval) -> Bool { uptime >= deadline }
}

private final class QuitHoldPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct QuitHoldPrompt: View {
    let timing: QuitHoldTiming
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
            let uptime = ProcessInfo.processInfo.systemUptime
            let ready = timing.isReady(at: uptime)
            VStack(spacing: 12) {
                Image(systemName: ready ? "checkmark.circle.fill" : "power")
                    .font(.title2)
                    .foregroundStyle(ready ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                Text(ready ? "Release ⌘Q to quit" : "Keep holding ⌘Q to quit")
                    .font(.headline)
                    .contentTransition(.opacity)
                QuitHoldProgressBar(timing: timing)
                    .frame(width: 220, height: 4)
                    .accessibilityLabel("Hold to quit progress")
                Text(ready ? "Or press Esc to cancel" : "Release early to cancel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: ready)
        }
    }
}

private struct QuitHoldProgressBar: NSViewRepresentable {
    let timing: QuitHoldTiming

    func makeNSView(context: Context) -> QuitHoldProgressNSView {
        QuitHoldProgressNSView(timing: timing)
    }

    func updateNSView(_ view: QuitHoldProgressNSView, context: Context) {
        // SwiftUI's label updates must not restart the committed animation.
        view.setAccessibilityValue(timing.progress(at: ProcessInfo.processInfo.systemUptime))
    }
}

/// Core Animation renders the fill without asking the main thread for frames.
/// The immutable deadline still belongs to the quit gesture, not the animation.
final class QuitHoldProgressNSView: NSView {
    private let timing: QuitHoldTiming
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private var animationStarted = false

    init(timing: QuitHoldTiming) {
        self.timing = timing
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        for shape in [track, fill] {
            shape.lineWidth = 4
            shape.lineCap = .round
            shape.fillColor = nil
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(1)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        guard bounds.width > 4, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 2, y: bounds.midY))
        path.addLine(to: CGPoint(x: bounds.width - 2, y: bounds.midY))
        for shape in [track, fill] {
            shape.frame = bounds
            shape.path = path
        }
        track.strokeColor = NSColor.quaternaryLabelColor.cgColor
        fill.strokeColor = NSColor.controlAccentColor.cgColor
        if !animationStarted {
            animationStarted = true
            let uptime = ProcessInfo.processInfo.systemUptime
            fill.strokeEnd = 1
            let remaining = max(0, timing.deadline - uptime)
            if remaining > 0 {
                let animation = CABasicAnimation(keyPath: "strokeEnd")
                animation.fromValue = timing.progress(at: uptime)
                animation.toValue = 1
                animation.duration = remaining
                animation.beginTime = fill.convertTime(CACurrentMediaTime(), from: nil)
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                fill.add(animation, forKey: "quitHoldFill")
            }
        }
        CATransaction.commit()
    }
}
