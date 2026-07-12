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
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Disable automatic window tabbing
        NSWindow.allowsAutomaticWindowTabbing = false

        // Initialize CLI interface
        _ = BrowserCLI.shared
    }
}

@main
struct Straight_Up_BrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var showSettings = false
    @Environment(\.openWindow) private var openWindow
    private var colorScheme: ColorScheme? {
        SettingsManager.shared.colorScheme
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Tab.self,
            Bookmark.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

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
        .windowStyle(.automatic)
        .defaultSize(width: 600, height: 400)
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

            // View menu commands
            CommandGroup(after: .toolbar) {
                Button("Reopen Last Closed Tab") {
                    NotificationCenter.default.post(name: .reopenLastClosedTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

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
                Button("Show Omnibar") {
                    NotificationCenter.default.post(name: .showOmnibar, object: nil)
                }
                .keyboardShortcut(" ", modifiers: .control)

                Button("Settings...") {
                    NotificationCenter.default.post(name: .browserShowSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
