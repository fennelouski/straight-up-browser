//
//  HelpWindow.swift
//  Straight Up Browser
//

import SwiftUI

struct HelpWindow: View {
    @State private var selectedTab = 0

    private var colorScheme: ColorScheme? {
        SettingsManager.shared.colorScheme
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            GettingStartedView()
                .tabItem {
                    Label("Getting Started", systemImage: "sparkles")
                }
                .tag(0)

            ShortcutsHelpView()
                .tabItem {
                    Label("Keyboard Shortcuts", systemImage: "keyboard")
                }
                .tag(1)

            CLIHelpView()
                .tabItem {
                    Label("Tips & CLI", systemImage: "terminal")
                }
                .tag(2)
        }
        .frame(width: 600, height: 560)
        .padding()
        .preferredColorScheme(colorScheme)
    }
}

// MARK: - Getting Started
private struct GettingStartedView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your Window to the Internet")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("The simplest way to use the internet — here's everything you need to get browsing.")
                        .foregroundStyle(.secondary)
                }

                GroupBox(label: Text("The Omnibar")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Everything starts at the omnibar. Press ⌃Space, ⌘K, or ⌘L to open it, then type a web address or a search — your browser figures out which one you meant.")
                        Text("It also matches your open tabs, history, and bookmarks as you type, so it doubles as a quick switcher.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                GroupBox(label: Text("Tabs")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Open a new tab with ⌘T, close one with ⌘W, and bring back the last closed tab with ⇧⌘T. Cycle through tabs with ⌃Tab, or jump straight to one with ⌘1 through ⌘9.")
                        Text("The tab bar has several sizes — toggle it with ⇧⌘L or pick a style from the View menu.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                GroupBox(label: Text("Bookmarks")) {
                    Text("Bookmark the current page with ⌘D and browse your bookmarks with ⇧⌘B. You can import bookmarks from another browser via Bookmarks → Import Bookmarks.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }

                GroupBox(label: Text("From Anywhere")) {
                    Text("A system-wide hotkey (⌥Space by default) opens the omnibar even when your browser isn't the front app. Change the hotkey in Settings (⌘,).")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }

                GroupBox(label: Text("Quitting")) {
                    Text("To avoid losing your tabs to a mistyped shortcut, quitting requires holding ⌘Q for two seconds.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
            .padding()
        }
    }
}

// MARK: - Keyboard Shortcuts
// Single source of truth for the shortcut list; the Help window and the
// in-browser cheat sheet (⇧⌘H) both render it.
enum ShortcutReference {
    static let sections: [(String, [(String, String)])] = [
        ("Tabs", [
            ("New Tab", "⌘T or ⌘N"),
            ("Close Tab", "⌘W"),
            ("Reopen Last Closed Tab", "⇧⌘T"),
            ("Next / Previous Tab", "⌃Tab / ⌃⇧Tab"),
            ("Jump to Tab 1–9", "⌘1 – ⌘9"),
        ]),
        ("Navigation", [
            ("Open Location", "⌘L"),
            ("Back / Forward", "⌘[ / ⌘]"),
            ("Reload", "⌘R"),
            ("Hard Reload (bypass cache)", "⇧⌘R"),
            ("Reload All Tabs", "⌥⇧⌘R"),
        ]),
        ("Page", [
            ("Find on Page", "⌘F"),
            ("Find Next / Previous", "⌘G / ⇧⌘G"),
            ("Zoom In / Out", "⌘= / ⌘-"),
            ("Actual Size", "⌘0"),
            ("Print", "⇧⌘P"),
            ("Export as PDF", "⌘P"),
            ("Toggle Full Screen", "⇧⌘F"),
        ]),
        ("Tab Bar", [
            ("Toggle Tab Bar", "⇧⌘L"),
            ("Hide Tab Bar", "⌥⌘`"),
            ("Minimal / Compact / Wide", "⌥⌘1 / ⌥⌘2 / ⌥⌘3"),
        ]),
        ("Bookmarks", [
            ("Add Bookmark", "⌘D"),
            ("Show Bookmarks", "⇧⌘B"),
        ]),
        ("App", [
            ("Omnibar", "⌃Space or ⌘K"),
            ("Omnibar from any app", "⌥Space (configurable)"),
            ("Shortcut cheat sheet", "⇧⌘H"),
            ("Settings", "⌘,"),
            ("Help", "⌘?"),
            ("Quit", "hold ⌘Q for 2s"),
        ]),
    ]
}

private struct ShortcutsHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Keyboard Shortcuts")
                    .font(.title)
                    .fontWeight(.bold)

                ForEach(ShortcutReference.sections, id: \.0) { title, shortcuts in
                    GroupBox(label: Text(title)) {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                            ForEach(shortcuts, id: \.0) { name, keys in
                                GridRow {
                                    Text(name)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(keys)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(8)
                    }
                }

                Text("⌘P prints instead of exporting a PDF if you turn off “⌘P exports PDF” in Settings → General.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

// MARK: - Tips & CLI
private struct CLIHelpView: View {
    private static let commands: [(String, String)] = [
        ("open <url>", "Open a URL"),
        ("search <query>", "Search the web"),
        ("new", "Create a new tab"),
        ("close", "Close the active tab"),
        ("tabs", "List open tabs (JSON)"),
        ("get [url]", "Get page data (JSON)"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Tips & CLI")
                    .font(.title)
                    .fontWeight(.bold)

                GroupBox(label: Text("Shortcuts & Siri")) {
                    Text("Your browser's actions — Open URL, Search the Web, New Tab — appear in the Shortcuts app, Spotlight, and Siri. Try saying “New tab in Internet.”")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }

                GroupBox(label: Text("Command Line")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your Internet browser can be driven from the terminal with browser-cli (see CLI_USAGE.md in the project for setup):")
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                            ForEach(Self.commands, id: \.0) { command, purpose in
                                GridRow {
                                    Text(command)
                                        .font(.system(.body, design: .monospaced))
                                    Text(purpose)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }
            .padding()
        }
    }
}
