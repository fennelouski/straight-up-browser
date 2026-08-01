//
//  BrowserApp_iOS.swift
//  Browser (iPadOS)
//
//  Keyboard-first iPad browser. Shares the model/manager core with the Mac app
//  (Tab, TabManager, WebViewManager, SettingsManager, …) and brings its own
//  purpose-built iPad UI. See Straight_Up_BrowserApp.swift for the Mac entry point.
//

import SwiftUI
import SwiftData

@main
struct BrowserApp: App {
    // Same SwiftData schema as the Mac app (Straight_Up_BrowserApp.swift). `Tab`
    // is the @Model class; the `BrowserTab` typealias lives in the Mac-only
    // ContentView, so iOS code refers to `Tab` directly.
    private let modelStartup = ModelContainerStartup.makeDefault()
    @State private var showStartupRecoveryNotice = true

    // Rebuilds the keyboard commands when a shortcut (or preset) changes.
    @AppStorage(ShortcutStore.revisionKey) private var shortcutsRevision = 0

    init() {
        #if DEBUG
        OmnibarInput.selfCheck()
        ShortcutStore.selfCheck()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            if let container = modelStartup.container {
                BrowserView_iOS()
                    .modelContainer(container)
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
        .commands { browserCommands }
    }

    // Keyboard commands surface in the hold-⌘ discoverability HUD and drive the
    // browser via notifications handled in BrowserView_iOS — the same menu/handler
    // decoupling the Mac app uses.
    @CommandsBuilder
    private var browserCommands: some Commands {
        CommandMenu("File") {
            cmd("New Tab", .browserNewTab, .newTab)
            cmd("New Incognito Tab", .browserNewIncognitoTab, .newIncognitoTab)
            cmd("Close Tab", .browserCloseTab, .closeTab)
            cmd("Close Tab Set", .browserCloseTabSet, .closeTabSet)
            cmd("Reopen Closed Tab", .reopenLastClosedTab, .reopenTab)
            Divider()
            cmd("Open Location…", .showOmnibar, .openLocation)
        }
        CommandMenu("Go") {
            cmd("Back", .browserGoBack, .back)
            cmd("Forward", .browserGoForward, .forward)
            cmd("Reload", .browserReload, .reload)
            Divider()
            cmd("Find…", .browserFindInPage, .findInPage)
        }
        CommandMenu("View") {
            cmd("Toggle Sidebar", .browserToggleTabBar, .toggleTabBar)
            Divider()
            cmd("Zoom In", .browserZoomIn, .zoomIn)
            cmd("Zoom Out", .browserZoomOut, .zoomOut)
            cmd("Actual Size", .browserZoomReset, .actualSize)
            Divider()
            cmd("Settings…", .browserShowSettings, .settings)
            cmd("Keyboard Shortcuts", .browserToggleShortcutOverlay, .shortcutOverlay)
        }
        CommandMenu("Bookmarks") {
            cmd("Add Bookmark", .browserAddBookmark, .addBookmark)
        }
        CommandMenu("Tabs") {
            cmd("Show Next Tab", .browserNextTab, .nextTab)
            cmd("Show Previous Tab", .browserPreviousTab, .previousTab)
            Divider()
            ForEach(Array(ShortcutCommand.switchTabs.enumerated()), id: \.element.id) { index, command in
                Button("Show Tab \(index + 1)") {
                    NotificationCenter.default.post(name: .browserSwitchTab, object: nil, userInfo: ["index": index + 1])
                }
                .keyboardShortcut(shortcut(command))
            }
        }
    }

    // A command button that posts a notification, keyed by the store's current
    // shortcut for `command` so presets/rebindings take effect live.
    private func cmd(_ title: String, _ name: Notification.Name, _ command: ShortcutCommand) -> some View {
        Button(title) { NotificationCenter.default.post(name: name, object: nil) }
            .keyboardShortcut(shortcut(command))
    }

    private func shortcut(_ command: ShortcutCommand) -> KeyboardShortcut {
        _ = shortcutsRevision
        return ShortcutStore.shared.shortcut(for: command).keyboardShortcut
    }
}
