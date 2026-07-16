//
//  Straight_Up_BrowserApp.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import SwiftData
import AppKit


class AppDelegate: NSObject, NSApplicationDelegate {
    private let globalOmnibar = GlobalOmnibarController()

    // Keep in sync with EULA.md; bump the version to re-prompt existing users.
    private let eulaVersion = 1

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Disable automatic window tabbing
        NSWindow.allowsAutomaticWindowTabbing = false

        // Initialize CLI interface
        _ = BrowserCLI.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.integer(forKey: "acceptedEULAVersion") < eulaVersion {
            guard runEULAAlert() else {
                NSApp.terminate(nil)
                return
            }
            UserDefaults.standard.set(eulaVersion, forKey: "acceptedEULAVersion")
        }
        registerGlobalHotkey()
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
            MainActor.assumeIsolated { GlobalOmnibarHotkey.applyFromDefaults() }
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

@main
struct Straight_Up_BrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var showSettings = false
    @AppStorage("cmdPExportsPDF") private var cmdPExportsPDF = true
    @Environment(\.openWindow) private var openWindow
    private var colorScheme: ColorScheme? {
        SettingsManager.shared.colorScheme
    }

    var sharedModelContainer: ModelContainer = {
        // TabGroup included so the CloudKit record types match the iPad app.
        let schema = Schema([Tab.self, TabGroup.self, Bookmark.self])
        // Tab sync (Settings → Sync) selects the CloudKit private DB; off = local.
        // Read at launch, so toggling sync takes effect after relaunch.
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: TabSync.cloudKitDatabase
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    // Set up notification observer for settings
                    NotificationCenter.default.addObserver(
                        forName: .browserShowSettings,
                        object: nil,
                        queue: .main
                    ) { _ in
                        openWindow(id: "settings")
                    }
                }
        }
        .modelContainer(sharedModelContainer)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)

        Window("Settings", id: "settings") {
            SettingsWindow()
        }
        .modelContainer(sharedModelContainer)
        .windowStyle(.automatic)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 780, height: 560)
        .windowResizability(.contentSize)

        Window("Help", id: "help") {
            HelpWindow()
        }
        .windowStyle(.automatic)
        .windowResizability(.contentSize)
        .commands {
            // Add standard browser commands
            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    NotificationCenter.default.post(name: .browserNewTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                Button("Close Tab") {
                    NotificationCenter.default.post(name: .browserCloseTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }

            // File menu commands
            CommandGroup(after: .newItem) {
                Button("Open Location...") {
                    NotificationCenter.default.post(name: .showOmnibar, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)
            }

            CommandGroup(replacing: .printItem) {
                Button("Print...") {
                    NotificationCenter.default.post(name: .browserPrint, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                // Cmd+P makes a PDF (toggleable in Settings > General)
                if cmdPExportsPDF {
                    Button("Export as PDF...") {
                        NotificationCenter.default.post(name: .browserExportPDF, object: nil)
                    }
                    .keyboardShortcut("p", modifiers: .command)
                } else {
                    Button("Export as PDF...") {
                        NotificationCenter.default.post(name: .browserExportPDF, object: nil)
                    }
                }
            }

            // View menu commands
            CommandGroup(after: .toolbar) {
                Button("Reopen Last Closed Tab") {
                    NotificationCenter.default.post(name: .reopenLastClosedTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button("Toggle Full Screen") {
                    (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Divider()

                Button("Zoom In") {
                    NotificationCenter.default.post(name: .browserZoomIn, object: nil)
                }
                .keyboardShortcut("=", modifiers: .command)

                Button("Zoom Out") {
                    NotificationCenter.default.post(name: .browserZoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    NotificationCenter.default.post(name: .browserZoomReset, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)

                Divider()

                Button("Toggle Tab Bar") {
                    NotificationCenter.default.post(name: .browserToggleTabBar, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("Hide Tab Bar") {
                    NotificationCenter.default.post(name: .browserHideTabBar, object: nil)
                }
                .keyboardShortcut("`", modifiers: [.command, .option])

                Button("Minimal Tab Bar") {
                    NotificationCenter.default.post(name: .browserMinimalTabBar, object: nil)
                }
                .keyboardShortcut("1", modifiers: [.command, .option])

                Button("Compact Tab Bar") {
                    NotificationCenter.default.post(name: .browserCompactTabBar, object: nil)
                }
                .keyboardShortcut("2", modifiers: [.command, .option])

                Button("Wide Tab Bar") {
                    NotificationCenter.default.post(name: .browserWideTabBar, object: nil)
                }
                .keyboardShortcut("3", modifiers: [.command, .option])
            }

            // Bookmarks menu commands
            CommandGroup(after: .textEditing) {
                Button("Show Bookmarks") {
                    NotificationCenter.default.post(name: .browserShowBookmarks, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Button("Add Bookmark") {
                    NotificationCenter.default.post(name: .browserAddBookmark, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)

                Divider()

                Button("Import Bookmarks...") {
                    NotificationCenter.default.post(name: .browserImportBookmarks, object: nil)
                }
            }

            // Window menu commands
            CommandGroup(after: .windowArrangement) {
                Button("Show Next Tab") {
                    NotificationCenter.default.post(name: .browserNextTab, object: nil)
                }
                .keyboardShortcut(.tab, modifiers: .control)

                Button("Show Previous Tab") {
                    NotificationCenter.default.post(name: .browserPreviousTab, object: nil)
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])

                Divider()

                Button("Show Tab 1") {
                    NotificationCenter.default.post(name: .browserSwitchToTab1, object: nil)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Show Tab 2") {
                    NotificationCenter.default.post(name: .browserSwitchToTab2, object: nil)
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Show Tab 3") {
                    NotificationCenter.default.post(name: .browserSwitchToTab3, object: nil)
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("Show Tab 4") {
                    NotificationCenter.default.post(name: .browserSwitchToTab4, object: nil)
                }
                .keyboardShortcut("4", modifiers: .command)

                Button("Show Tab 5") {
                    NotificationCenter.default.post(name: .browserSwitchToTab5, object: nil)
                }
                .keyboardShortcut("5", modifiers: .command)

                Button("Show Tab 6") {
                    NotificationCenter.default.post(name: .browserSwitchToTab6, object: nil)
                }
                .keyboardShortcut("6", modifiers: .command)

                Button("Show Tab 7") {
                    NotificationCenter.default.post(name: .browserSwitchToTab7, object: nil)
                }
                .keyboardShortcut("7", modifiers: .command)

                Button("Show Tab 8") {
                    NotificationCenter.default.post(name: .browserSwitchToTab8, object: nil)
                }
                .keyboardShortcut("8", modifiers: .command)

                Button("Show Tab 9") {
                    NotificationCenter.default.post(name: .browserSwitchToTab9, object: nil)
                }
                .keyboardShortcut("9", modifiers: .command)
            }

            // Add omnibar shortcut and settings to menu
            CommandGroup(after: .textEditing) {
                Button("Find...") {
                    NotificationCenter.default.post(name: .browserFindInPage, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Find Next") {
                    NotificationCenter.default.post(name: .browserFindNext, object: nil)
                }
                .keyboardShortcut("g", modifiers: .command)

                Button("Find Previous") {
                    NotificationCenter.default.post(name: .browserFindPrevious, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Button("Show Omnibar") {
                    NotificationCenter.default.post(name: .showOmnibar, object: nil)
                }
                .keyboardShortcut(" ", modifiers: .control)

                // Slack-style quick open; same omnibar, second shortcut
                Button("Quick Open") {
                    NotificationCenter.default.post(name: .showOmnibar, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Settings...") {
                    NotificationCenter.default.post(name: .browserShowSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandMenu("Extensions") {
                Button("Load Extension…") {
                    WebExtensionManager.shared.presentLoadPanel()
                }
                Button("Open Extension Popup") {
                    WebExtensionManager.shared.showPopup()
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
            }

            CommandGroup(replacing: .help) {
                Button("Browser Help") {
                    openWindow(id: "help")
                }
                .keyboardShortcut("?", modifiers: .command)

                Button("Keyboard Shortcuts") {
                    NotificationCenter.default.post(name: .browserToggleShortcutOverlay, object: nil)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }
    }
}
