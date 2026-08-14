//
//  Straight_Up_BrowserApp.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import SwiftData
import AppKit
import Sparkle


class AppDelegate: NSObject, NSApplicationDelegate {
    private let globalOmnibar = GlobalOmnibarController()
    // Starts checking immediately (SUEnableAutomaticChecks/SUAutomaticallyUpdate
    // in Browser-Info.plist mean it's silent — downloads and installs on quit,
    // no prompt). "Check for Updates…" below just triggers an on-demand check.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    // Keep in sync with EULA.md; bump the version to re-prompt existing users.
    private let eulaVersion = 1
    private var isRunningUnderTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCInjectBundleInto"] != nil
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        ShortcutStore.selfCheck()
        KeyboardShortcutsManager.selfCheck()
        ScreenshotSettings.selfCheck()
        #endif

        // Disable automatic window tabbing
        NSWindow.allowsAutomaticWindowTabbing = false

        // Initialize CLI interface
        _ = BrowserCLI.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Has to land before the window's first layout pass — see the note on
        // hideTitleBar for what happens if it doesn't.
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.contentView != nil }) {
            WindowLayout.hideTitleBar(on: window)
            WindowLayout.applyCornerMask(to: window)
        }
        installURLHandler()
        // Test hosts cannot interact with this modal before the app finishes
        // bootstrapping. UI tests pass the accepted version explicitly; unit
        // test hosts use this environment-based bypass instead.
        if !isRunningUnderTests && UserDefaults.standard.integer(forKey: "acceptedEULAVersion") < eulaVersion {
            guard runEULAAlert() else {
                NSApp.terminate(nil)
                return
            }
            UserDefaults.standard.set(eulaVersion, forKey: "acceptedEULAVersion")
        }
        registerGlobalHotkey()
        if !isRunningUnderTests {
            Task { @MainActor in
                await AgentDefinitionSyncService.shared.start()
            }
        }
        // Belt and braces: this app is single-window, and a stray open event that
        // SwiftUI answers itself leaves a second browser window the user has no way
        // to close (no title bar, ⌘W closes a tab). Sweep once after launch settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Self.closeExtraBrowserWindows() }
    }

    // Identified positively - .windowStyle(.hiddenTitleBar) is what marks a browser
    // window - so Settings/Downloads/Help, the omnibar panel, and Sparkle's update
    // windows are never candidates.
    static func closeExtraBrowserWindows() {
        let browserWindows = NSApp.windows.filter {
            $0.isVisible && !($0 is NSPanel)
                // Square corners drop .titled, and with it the transparent-titlebar flag.
                && ($0.titlebarAppearsTransparent || !$0.styleMask.contains(.titled))
                && $0.styleMask.contains(.fullSizeContentView)
        }
        // Keep the one the user is actually looking at.
        let keep = NSApp.mainWindow.flatMap { browserWindows.contains($0) ? $0 : nil } ?? browserWindows.first
        for extra in browserWindows where extra != keep {
            Logger.log("Closing extra browser window: \(extra.identifier?.rawValue ?? "nil")", type: "App")
            extra.close()
        }
    }

    // A link clicked in another app arrives as a GURL Apple Event. SwiftUI's own
    // app delegate claims that event and then drops it — neither an AppDelegate
    // application(_:open:) nor .onOpenURL on the WindowGroup ever runs (verified
    // both). So claim it back here: this registration happens after SwiftUI's,
    // and for Apple Events the last handler installed wins.
    private func installURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        // Finder's "Open With" sends odoc instead, and SwiftUI answers it by
        // spawning a second WindowGroup window - this app is single-window.
        // Claim it back the same way and open the file as a tab.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocumentsEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    @objc private func handleOpenDocumentsEvent(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        // A single file arrives as a bare descriptor (numberOfItems == 0).
        let items = list.numberOfItems == 0
            ? [list]
            : (1...list.numberOfItems).compactMap { list.atIndex($0) }
        for url in items.compactMap({ $0.fileURLValue }) {
            openInNewTab(url)
        }
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        openInNewTab(url)
    }

    private func openInNewTab(_ url: URL) {
        Task { @MainActor in
            // Cold launch: observers attach in ContentView.onAppear, after this.
            try? await waitForObservers()
            // Same funnel the CLI and Shortcuts post to.
            NotificationCenter.default.post(
                name: .browserOpenURL, object: nil,
                userInfo: ["url": url.absoluteString, "newTab": true]
            )
        }
    }

    // Returns true if the user accepted.
    private func runEULAAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "License Agreement")
        alert.informativeText = String(localized: "Before you open your window to the Internet, please accept the End User License Agreement.")

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 220))
        textView.string = Self.eulaText
        textView.isEditable = false
        textView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 220))
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        alert.accessoryView = scrollView

        alert.addButton(withTitle: String(localized: "Accept"))
        alert.addButton(withTitle: String(localized: "Decline"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    // Registered only after the EULA gate passes, so the global omnibar is
    // inert until the terms are accepted.
    private func registerGlobalHotkey() {
        GlobalOmnibarHotkey.install { [weak self] in
            // Browser already frontmost with a window: use the in-app overlay
            // instead of stacking a second omnibar on top of it.
            if NSApp.isActive, let keyWindow = NSApp.keyWindow, !(keyWindow is NSPanel) {
                NotificationCenter.default.post(name: .showOmnibar, object: nil)
            } else {
                self?.globalOmnibar.toggle()
            }
        }
        GlobalOmnibarHotkey.applyFromDefaults()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in GlobalOmnibarHotkey.applyFromDefaults() }
        }
    }

    // Keep in sync with EULA.md.
    private static let eulaText = """
    END USER LICENSE AGREEMENT
    EULA version 1 — © 2026 Nathan Fennel. All rights reserved.

    This Agreement is between you and Nathan Fennel ("the Author") and governs \
    your use of the browser application, also known as Straight Up \
    Browser ("the Software"). By \
    clicking Accept, or by installing or using the Software, you agree to this \
    Agreement. If you do not agree, do not use the Software.

    1. LICENSE. The Author grants you a personal, non-exclusive, \
    non-transferable, revocable license to install and use the Software for \
    your own use. You may not redistribute, sell, rent, sublicense, modify, or \
    reverse engineer the Software, in whole or in part, except where such \
    restriction is prohibited by applicable law.

    2. NO WARRANTY. THE SOFTWARE IS PROVIDED "AS IS" AND "AS AVAILABLE", \
    WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT \
    LIMITED TO WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR \
    PURPOSE, ACCURACY, RELIABILITY, SECURITY, OR NON-INFRINGEMENT. THE AUTHOR \
    DOES NOT WARRANT THAT THE SOFTWARE WILL BE ERROR-FREE OR UNINTERRUPTED, OR \
    THAT DEFECTS WILL BE CORRECTED.

    3. LIMITATION OF LIABILITY. TO THE MAXIMUM EXTENT PERMITTED BY LAW, THE \
    AUTHOR SHALL NOT BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, \
    CONSEQUENTIAL, OR EXEMPLARY DAMAGES WHATSOEVER — INCLUDING BUT NOT LIMITED \
    TO LOSS OF DATA, LOSS OF PROFITS, BUSINESS INTERRUPTION, DEVICE DAMAGE, OR \
    PERSONAL INJURY — ARISING OUT OF OR RELATED TO YOUR USE OF OR INABILITY TO \
    USE THE SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGES. YOUR \
    SOLE AND EXCLUSIVE REMEDY IS TO STOP USING THE SOFTWARE.

    4. YOUR RESPONSIBILITY. The Software is a web browser. You are solely \
    responsible for the websites you visit, the content you view, the files \
    you download, the information you transmit, and your compliance with all \
    applicable laws. The Author has no control over, and assumes no \
    responsibility for, any third-party websites, content, or services \
    accessed through the Software.

    5. TERMINATION. This license terminates automatically if you breach this \
    Agreement. Upon termination you must stop using and delete the Software.

    6. CHANGES. The Author may update this Agreement in future versions of \
    the Software. Continued use after an update constitutes acceptance of the \
    revised terms.
    """
}

/// Bridges SwiftData's live persistent Session set into the local-only
/// receiving-device activation gate. No Session content leaves the device.
private struct AgentDefinitionBrowserSessionRegistrationView: View {
    @Query private var browserSessions: [BrowserSession]

    private var sessionIDs: [UUID] {
        browserSessions.map(\.id).sorted { $0.uuidString < $1.uuidString }
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { update(sessionIDs) }
            .onChange(of: sessionIDs) { _, ids in update(ids) }
    }

    private func update(_ ids: [UUID]) {
        AgentDefinitionLiveDependencyResolver.shared
            .updateAvailableBrowserSessionIDs(Set(ids))
    }
}

@main
struct Straight_Up_BrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var showSettings = false
    @AppStorage("cmdPExportsPDF") private var cmdPExportsPDF = true
    @AppStorage("expandBackForwardShortcuts") private var expandBackForwardShortcuts = true
    @AppStorage("convertToIncognitoEnabled") private var convertToIncognitoEnabled = false
    // Reading this in the .commands builder (via `sc`) makes the menu bar rebuild
    // its key equivalents whenever a shortcut is rebound — same invalidation the
    // cmdPExportsPDF toggle relies on.
    @AppStorage(ShortcutStore.revisionKey) private var shortcutsRevision = 0
    @State private var showStartupRecoveryNotice = true
    @Environment(\.openWindow) private var openWindow
    private var colorScheme: ColorScheme? {
        SettingsManager.shared.colorScheme
    }

    // Current shortcut for a command, read live from the store.
    private func sc(_ command: ShortcutCommand) -> KeyboardShortcut {
        _ = shortcutsRevision
        return ShortcutStore.shared.shortcut(for: command).keyboardShortcut
    }

    private let modelStartup = ModelContainerStartup.makeDefault()

    var body: some Scene {
        WindowGroup(id: "browser") {
            if let container = modelStartup.container {
                ContentView()
                    .background(AgentDefinitionBrowserSessionRegistrationView())
                    .modelContainer(container)
                    .onReceive(NotificationCenter.default.publisher(for: .browserShowSettings)) { _ in
                        openWindow(id: "settings")
                    }
                    .alert(
                        "Browsing Data Recovery Mode",
                        isPresented: Binding(
                            get: { showStartupRecoveryNotice && modelStartup.didRecover },
                            set: { showStartupRecoveryNotice = $0 }
                        )
                    ) {
                        Button("Continue", role: .cancel) {}
                    } message: {
                        Text("The persistent browser database could not be opened. This session is using temporary storage, so its tabs and bookmarks won’t be saved. Restart to retry.\n\n\(modelStartup.errorDescription ?? "")")
                    }
            } else {
                ContentUnavailableView(
                    "Browser Data Unavailable",
                    systemImage: "externaldrive.badge.xmark",
                    description: Text(modelStartup.errorDescription ?? "The browser database could not be opened.")
                )
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)

        Window("Settings", id: "settings") {
            if let container = modelStartup.container {
                SettingsWindow().modelContainer(container)
            } else {
                ContentUnavailableView(
                    "Settings Unavailable",
                    systemImage: "externaldrive.badge.xmark"
                )
            }
        }
        .windowStyle(.automatic)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 780, height: 560)
        .windowResizability(.contentSize)

        Window("Developer Tools", id: "developer-tools") {
            DeveloperToolsDetachedWindow()
        }
        .windowStyle(.automatic)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 560)

        Window("Downloads", id: "downloads") {
            FilesWindow()
        }
        .windowStyle(.automatic)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 700, height: 540)

        Window("Newspaper", id: "newspaper") {
            if let container = modelStartup.container {
                NewspaperWindowScene().modelContainer(container)
            } else {
                ContentUnavailableView(
                    "Newspaper Unavailable",
                    systemImage: "externaldrive.badge.xmark"
                )
            }
        }
        .windowStyle(.automatic)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1120, height: 780)

        Window("Scheduled Agent Tasks", id: "agent-tasks") {
            BrowserAgentTasksView()
        }
        .windowStyle(.automatic)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 860, height: 600)

        Window("Agent App Integrations", id: "agent-integrations") {
            BrowserAgentMCPConnectionsView()
        }
        .windowStyle(.automatic)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 600)

        Window("Agent Timeline & Replay", id: "agent-audit") {
            BrowserAgentAuditView()
        }
        .windowStyle(.automatic)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1000, height: 700)

        Window("Help", id: "help") {
            HelpWindow()
        }
        .windowStyle(.automatic)
        .windowResizability(.contentSize)
        .commands {
            // The stock About panel renders "Version X.Y.Z (N)" — the parenthetical is
            // CFBundleVersion. Blanking it leaves just the marketing version.
            // Check for Updates lives here too rather than its own CommandGroup:
            // @CommandsBuilder caps top-level children at 10 and we're there.
            CommandGroup(replacing: .appInfo) {
                Button("About Browser") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [.version: ""])
                }
                Button("Check for Updates…") {
                    appDelegate.updaterController.updater.checkForUpdates()
                }
            }

            // Add standard browser commands
            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    NotificationCenter.default.post(name: .browserNewTab, object: nil)
                }
                .keyboardShortcut(sc(.newTab))
            }

            // File menu commands (one group: @CommandsBuilder caps top-level children at 10)
            CommandGroup(after: .newItem) {
                Button("Close Tab") {
                    // Cmd+W is a global menu shortcut, so it fires even when an
                    // auxiliary window (Downloads/Settings/Help) is key. Over one of
                    // those, close that window instead of a browser tab underneath it.
                    let key = NSApp.keyWindow
                    let isBrowserWindow = key.map {
                        !($0 is NSPanel)
                            && ($0.titlebarAppearsTransparent || !$0.styleMask.contains(.titled))
                            && $0.styleMask.contains(.fullSizeContentView)
                    } ?? false
                    if let key, !isBrowserWindow {
                        key.performClose(nil)
                    } else {
                        NotificationCenter.default.post(name: .browserCloseTab, object: nil)
                    }
                }
                .keyboardShortcut(sc(.closeTab))

                Button("Open Location...") {
                    NotificationCenter.default.post(name: .showOmnibar, object: nil)
                }
                .keyboardShortcut(sc(.openLocation))

                Button("Show Downloads") {
                    openWindow(id: "downloads")
                }
                .keyboardShortcut(sc(.showDownloads))
            }

            CommandGroup(replacing: .printItem) {
                // Settings > General > "⌘P and ⌘\ navigate Back/Forward" frees
                // both print chords for navigation, so neither item gets a
                // keyboard shortcut then (they're still here in the menu).
                if expandBackForwardShortcuts {
                    Button("Print...") {
                        NotificationCenter.default.post(name: .browserPrint, object: nil)
                    }
                    Button("Export as PDF...") {
                        NotificationCenter.default.post(name: .browserExportPDF, object: nil)
                    }
                } else {
                    Button("Print...") {
                        NotificationCenter.default.post(name: .browserPrint, object: nil)
                    }
                    .keyboardShortcut(sc(.printPage))

                    // Cmd+P makes a PDF (toggleable in Settings > General)
                    if cmdPExportsPDF {
                        Button("Export as PDF...") {
                            NotificationCenter.default.post(name: .browserExportPDF, object: nil)
                        }
                        .keyboardShortcut(sc(.exportPDF))
                    } else {
                        Button("Export as PDF...") {
                            NotificationCenter.default.post(name: .browserExportPDF, object: nil)
                        }
                    }
                }

                // Lives inside the print group rather than its own CommandGroup:
                // @CommandsBuilder caps top-level children at 10 and we're there.
                Menu("Screenshot") {
                    Button("Visible Area") {
                        NotificationCenter.default.post(name: .browserScreenshotVisible, object: nil)
                    }
                    .keyboardShortcut(sc(.screenshotVisible))

                    Button("Full Page") {
                        NotificationCenter.default.post(name: .browserScreenshotFullPage, object: nil)
                    }
                    .keyboardShortcut(sc(.screenshotFullPage))

                    Button("Element Under Cursor") {
                        NotificationCenter.default.post(name: .browserScreenshotElement, object: nil)
                    }
                    .keyboardShortcut(sc(.screenshotElement))

                    Button("Window and Tab Bar") {
                        NotificationCenter.default.post(name: .browserScreenshotWindow, object: nil)
                    }
                    .keyboardShortcut(sc(.screenshotWindow))
                }
            }

            CommandMenu("Privacy") {
                Button("New Incognito Tab") {
                    NotificationCenter.default.post(name: .browserNewIncognitoTab, object: nil)
                }
                .keyboardShortcut(sc(.newIncognitoTab))

                Button("New Regular Tab") {
                    NotificationCenter.default.post(name: .browserNewRegularTab, object: nil)
                }

                if convertToIncognitoEnabled {
                    Button("Switch Tab to Incognito") {
                        NotificationCenter.default.post(name: .browserConvertTabToIncognito, object: nil)
                    }
                    .keyboardShortcut(sc(.convertToIncognito))
                }

                Divider()

                Button("Clear This Site's Data…") {
                    NotificationCenter.default.post(name: .browserClearSiteData, object: nil)
                }
                .keyboardShortcut(sc(.clearSiteData))

                Button("Clear This Session's Data…") {
                    NotificationCenter.default.post(name: .browserClearSessionData, object: nil)
                }

                Button("Clear All Browsing Data…") {
                    NotificationCenter.default.post(name: .browserClearAllData, object: nil)
                }
            }

            // View menu commands
            CommandGroup(after: .toolbar) {
                Button("Reopen Last Closed Tab") {
                    NotificationCenter.default.post(name: .reopenLastClosedTab, object: nil)
                }
                .keyboardShortcut(sc(.reopenTab))

                Button("AI Agent") {
                    NotificationCenter.default.post(name: .browserToggleAgent, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Button("Developer Tools") {
                    NotificationCenter.default.post(name: .browserToggleDeveloperTools, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .option])

                Button("Developer Console") {
                    NotificationCenter.default.post(name: .browserShowDeveloperConsole, object: nil)
                }
                .keyboardShortcut("j", modifiers: [.command, .option])

                Button("Select Page Element") {
                    NotificationCenter.default.post(name: .browserToggleDeveloperElementInspector, object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])

                Button("Snap Window to Size") {
                    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                        WindowLayout.toggle(window)
                    }
                }
                .keyboardShortcut(sc(.windowLayout))

                // No window has a title bar, so native full screen isn't available —
                // this shortcut now does the same thing as "Snap Window to Size".
                Button("Toggle Full Screen") {
                    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                        WindowLayout.toggle(window)
                    }
                }
                .keyboardShortcut(sc(.fullScreen))

                Divider()

                Button("Zoom In") {
                    NotificationCenter.default.post(name: .browserZoomIn, object: nil)
                }
                .keyboardShortcut(sc(.zoomIn))

                Button("Zoom Out") {
                    NotificationCenter.default.post(name: .browserZoomOut, object: nil)
                }
                .keyboardShortcut(sc(.zoomOut))

                Button("Actual Size") {
                    NotificationCenter.default.post(name: .browserZoomReset, object: nil)
                }
                .keyboardShortcut(sc(.actualSize))

                Divider()

                Button("Toggle Page Translation") {
                    NotificationCenter.default.post(name: .browserToggleTranslation, object: nil)
                }
                .keyboardShortcut(sc(.toggleTranslation))

                Button("Open Translation in Split Pane") {
                    NotificationCenter.default.post(name: .browserTranslateInSplit, object: nil)
                }
                .keyboardShortcut(sc(.translateInSplit))

                Button("Reader Mode") {
                    NotificationCenter.default.post(name: .browserToggleReader, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .option])

                Divider()

                Button("Toggle Tab Bar") {
                    NotificationCenter.default.post(name: .browserToggleTabBar, object: nil)
                }
                .keyboardShortcut(sc(.toggleTabBar))

                Button("Hide Tab Bar") {
                    NotificationCenter.default.post(name: .browserHideTabBar, object: nil)
                }
                .keyboardShortcut(sc(.hideTabBar))

                Button("Minimal Tab Bar") {
                    NotificationCenter.default.post(name: .browserMinimalTabBar, object: nil)
                }
                .keyboardShortcut(sc(.minimalTabBar))

                Button("Compact Tab Bar") {
                    NotificationCenter.default.post(name: .browserCompactTabBar, object: nil)
                }
                .keyboardShortcut(sc(.compactTabBar))

                Button("Wide Tab Bar") {
                    NotificationCenter.default.post(name: .browserWideTabBar, object: nil)
                }
                .keyboardShortcut(sc(.wideTabBar))
            }

            // Bookmarks menu commands
            CommandGroup(after: .textEditing) {
                Button("Open Newspaper") {
                    openWindow(id: "newspaper")
                }

                Button("Add to Newspaper") {
                    guard let keyWindow = NSApp.keyWindow else { return }
                    NotificationCenter.default.post(
                        name: .browserAddToNewspaper,
                        object: keyWindow
                    )
                }

                Divider()

                Button("Show Bookmarks") {
                    NotificationCenter.default.post(name: .browserShowBookmarks, object: nil)
                }
                .keyboardShortcut(sc(.showBookmarks))

                Button("Show History") {
                    NotificationCenter.default.post(name: .browserShowHistory, object: nil)
                }
                .keyboardShortcut(sc(.showHistory))

                Button("Add Bookmark") {
                    NotificationCenter.default.post(name: .browserAddBookmark, object: nil)
                }
                .keyboardShortcut(sc(.addBookmark))

                Divider()

                Button("Import Bookmarks...") {
                    NotificationCenter.default.post(name: .browserImportBookmarks, object: nil)
                }

                Divider()

                // Merged in from a second `after: .textEditing` group: @CommandsBuilder
                // caps top-level children at 10, and two groups sharing an anchor cost
                // two slots for no benefit.
                Button("Find...") {
                    NotificationCenter.default.post(name: .browserFindInPage, object: nil)
                }
                .keyboardShortcut(sc(.findInPage))

                Button("Find Next") {
                    NotificationCenter.default.post(name: .browserFindNext, object: nil)
                }
                .keyboardShortcut(sc(.findNext))

                Button("Find Previous") {
                    NotificationCenter.default.post(name: .browserFindPrevious, object: nil)
                }
                .keyboardShortcut(sc(.findPrevious))

                Button("Show Omnibar") {
                    NotificationCenter.default.post(name: .showOmnibar, object: nil)
                }
                .keyboardShortcut(sc(.omnibar))

                // Slack-style quick open; same omnibar, second shortcut
                Button("Quick Open") {
                    NotificationCenter.default.post(name: .showOmnibar, object: nil)
                }
                .keyboardShortcut(sc(.quickOpen))

                // Cmd+K/Cmd+N are an easy mistype of each other; Cmd+Shift+K
                // covers the slip by opening a new tab too.
                Button("New Tab (Quick Open Alt)") {
                    NotificationCenter.default.post(name: .browserNewTab, object: nil)
                }
                .keyboardShortcut(sc(.quickOpenNewTab))

                Divider()

                // Mirrors the sidebar's autofill button, so the feature is still
                // reachable when the tab bar is hidden or minimal. Same view in
                // both places — see AutofillMenu.swift.
                Menu("Autofill") {
                    AutofillMenuContent(hostsShortcut: true)
                }

                Button("Settings...") {
                    NotificationCenter.default.post(name: .browserShowSettings, object: nil)
                }
                .keyboardShortcut(sc(.settings))
            }

            // Window menu commands
            CommandGroup(after: .windowArrangement) {
                Button("Show Next Tab") {
                    NotificationCenter.default.post(name: .browserNextTab, object: nil)
                }
                .keyboardShortcut(sc(.nextTab))

                Button("Show Previous Tab") {
                    NotificationCenter.default.post(name: .browserPreviousTab, object: nil)
                }
                .keyboardShortcut(sc(.previousTab))

                Button("Show All Tabs") {
                    NotificationCenter.default.post(name: .browserShowTabGrid, object: nil)
                }
                .keyboardShortcut(sc(.tabGrid))

                Divider()

                ForEach(Array(ShortcutCommand.switchTabs.enumerated()), id: \.element.id) { index, command in
                    Button("Show Tab \(index + 1)") {
                        NotificationCenter.default.post(
                            name: Notification.Name("browserSwitchToTab\(index + 1)"), object: nil)
                    }
                    .keyboardShortcut(sc(command))
                }
            }

            CommandMenu("Extensions") {
                Button("Load Extension…") {
                    WebExtensionManager.shared.presentLoadPanel()
                }
                Button("Open Extension Popup") {
                    WebExtensionManager.shared.showPopup()
                }
                .keyboardShortcut(sc(.extensionPopup))
                Divider()
                Button("Manage Extensions…") {
                    WebExtensionManager.shared.presentManagementPanel()
                }
            }

            CommandGroup(replacing: .help) {
                Button("Browser Help") {
                    openWindow(id: "help")
                }
                .keyboardShortcut(sc(.help))

                Button("Keyboard Shortcuts") {
                    NotificationCenter.default.post(name: .browserToggleShortcutOverlay, object: nil)
                }
                .keyboardShortcut(sc(.shortcutOverlay))
            }
        }
    }
}
