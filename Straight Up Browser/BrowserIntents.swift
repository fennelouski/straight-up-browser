//
//  BrowserIntents.swift
//  Straight Up Browser
//
//  App Intents surface the browser's actions in Spotlight, the Shortcuts
//  app, and Siri/Apple Intelligence. Each intent posts the same
//  NotificationCenter notifications the menus and CLI already use.
//

import AppIntents
import Foundation

// ponytail: cold-launch race — observers attach in ContentView.onAppear,
// which can lag intent delivery (or the EULA modal). Bounded poll, then
// give up quietly like the CLI does when no window is open.
@MainActor
func waitForObservers() async throws {
    for _ in 0..<100 where !NotificationManager.observersReady {
        try await Task.sleep(for: .milliseconds(50))
    }
}

struct OpenURLIntent: AppIntent {
    static let title: LocalizedStringResource = "Open URL"
    static let description = IntentDescription("Opens a URL in a new tab.")
    static let openAppWhenRun = true

    @Parameter(title: "URL") var url: URL

    @MainActor
    func perform() async throws -> some IntentResult {
        try await waitForObservers()
        NotificationCenter.default.post(
            name: .browserOpenURL, object: nil,
            userInfo: ["url": url.absoluteString, "newTab": true]
        )
        return .result()
    }
}

struct SearchWebIntent: AppIntent {
    static let title: LocalizedStringResource = "Search the Web"
    static let description = IntentDescription("Searches the web in a new tab.")
    static let openAppWhenRun = true

    @Parameter(title: "Query") var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        try await waitForObservers()
        // Same funnel as BrowserCLI's "search" command
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        NotificationCenter.default.post(
            name: .browserOpenURL, object: nil,
            userInfo: ["url": "https://www.google.com/search?q=" + encoded, "newTab": true]
        )
        return .result()
    }
}

struct NewTabIntent: AppIntent {
    static let title: LocalizedStringResource = "New Tab"
    static let description = IntentDescription("Opens a new tab.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try await waitForObservers()
        NotificationCenter.default.post(name: .browserNewTab, object: nil)
        return .result()
    }
}

struct BrowserAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenURLIntent(),
            phrases: ["Open a URL in \(.applicationName)"],
            shortTitle: "Open URL",
            systemImageName: "globe"
        )
        AppShortcut(
            intent: SearchWebIntent(),
            phrases: ["Search the web in \(.applicationName)"],
            shortTitle: "Search Web",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: NewTabIntent(),
            phrases: ["New tab in \(.applicationName)"],
            shortTitle: "New Tab",
            systemImageName: "plus.square.on.square"
        )
    }
}
