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
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Tab.self, TabGroup.self, Bookmark.self])
        // Tab sync (Settings → Sync) selects the CloudKit private DB; off = no
        // CloudKit. Read at launch, so toggling sync takes effect after relaunch.
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: TabSync.cloudKitDatabase
        )
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

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
            BrowserView_iOS()
        }
        .modelContainer(sharedModelContainer)
        .commands { browserCommands }
    }

    // Keyboard commands surface in the hold-⌘ discoverability HUD and drive the
    // browser via notifications handled in BrowserView_iOS — the same menu/handler
    // decoupling the Mac app uses.
    @CommandsBuilder
    private var browserCommands: some Commands {
        CommandMenu("File") {
            cmd("New Tab", .browserNewTab, .newTab)
            cmd("Close Tab", .browserCloseTab, .closeTab)
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
