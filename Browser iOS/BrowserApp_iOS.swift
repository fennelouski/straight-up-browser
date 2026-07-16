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

    init() {
        #if DEBUG
        OmnibarInput.selfCheck()
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
            cmd("New Tab", .browserNewTab, "t")
            cmd("Close Tab", .browserCloseTab, "w")
            cmd("Reopen Closed Tab", .reopenLastClosedTab, "t", [.command, .shift])
            Divider()
            cmd("Open Location…", .showOmnibar, "l")
        }
        CommandMenu("Go") {
            cmd("Back", .browserGoBack, "[")
            cmd("Forward", .browserGoForward, "]")
            cmd("Reload", .browserReload, "r")
            Divider()
            cmd("Find…", .browserFindInPage, "f")
        }
        CommandMenu("View") {
            cmd("Toggle Sidebar", .browserToggleTabBar, "l", [.command, .shift])
            Divider()
            cmd("Zoom In", .browserZoomIn, "=")
            cmd("Zoom Out", .browserZoomOut, "-")
            cmd("Actual Size", .browserZoomReset, "0")
            Divider()
            cmd("Settings…", .browserShowSettings, ",")
            cmd("Keyboard Shortcuts", .browserToggleShortcutOverlay, "h", [.command, .shift])
        }
        CommandMenu("Bookmarks") {
            cmd("Add Bookmark", .browserAddBookmark, "d")
        }
        CommandMenu("Tabs") {
            cmd("Show Next Tab", .browserNextTab, .tab, .control)
            cmd("Show Previous Tab", .browserPreviousTab, .tab, [.control, .shift])
            Divider()
            ForEach(1...9, id: \.self) { i in
                Button("Show Tab \(i)") {
                    NotificationCenter.default.post(name: .browserSwitchTab, object: nil, userInfo: ["index": i])
                }
                .keyboardShortcut(KeyEquivalent(Character("\(i)")), modifiers: .command)
            }
        }
    }

    // A command button that posts a notification with a ⌘-shortcut.
    private func cmd(_ title: String, _ name: Notification.Name, _ key: KeyEquivalent,
                     _ modifiers: EventModifiers = .command) -> some View {
        Button(title) { NotificationCenter.default.post(name: name, object: nil) }
            .keyboardShortcut(key, modifiers: modifiers)
    }
}
