//
//  BrowserApp_iOS.swift
//  Browser (iOS and iPadOS)
//
//  Touch- and keyboard-first mobile browser. Shares the model/manager core with the Mac app
//  (Tab, TabManager, WebViewManager, SettingsManager, …) and brings its own
//  purpose-built iPad UI. See Straight_Up_BrowserApp.swift for the Mac entry point.
//

import SwiftUI
import SwiftData

@MainActor
final class ExternalURLRouter_iOS: ObservableObject {
    @Published private(set) var pendingURL: URL?

    func receive(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return
        }
        pendingURL = url
    }

    func takePendingURL() -> URL? {
        defer { pendingURL = nil }
        return pendingURL
    }
}

@main
struct BrowserApp: App {
    @UIApplicationDelegateAdaptor(BrowserAppDelegate_iOS.self) private var appDelegate
    @StateObject private var externalURLRouter = ExternalURLRouter_iOS()

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
                    .environmentObject(externalURLRouter)
                    .onOpenURL { externalURLRouter.receive($0) }
                    .task {
                        if !MobileTestConfiguration.isUITesting {
                            _ = try? await AgentDefinitionSyncRuntime.shared.refresh()
                        }
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
        .commands { browserCommands }
    }

    // Keyboard commands surface in the hold-⌘ discoverability HUD and drive the
    // browser via notifications handled in BrowserView_iOS — the same menu/handler
    // decoupling the Mac app uses.
    @CommandsBuilder
    private var browserCommands: some Commands {
        CommandMenu("File") {
            commandButtons(in: .file)
        }
        CommandMenu("Go") {
            commandButtons(in: .go)
        }
        CommandMenu("View") {
            commandButtons(in: .view)
        }
        CommandMenu("Bookmarks") {
            commandButtons(in: .bookmarks)
        }
        CommandMenu("Tabs") {
            commandButtons(in: .tabs)
        }
    }

    // Menu registration and dispatch metadata come from the same registry the
    // handler and cheat sheet consume, preventing advertised but inert commands.
    private func commandButtons(in group: BrowserPlatformCommandGroup) -> some View {
        ForEach(BrowserPlatformCommandRegistry.iPadEntries(in: group)) { entry in
            Button {
                NotificationCenter.default.post(
                    name: entry.notification,
                    object: nil,
                    userInfo: entry.userInfo
                )
            } label: {
                Text(entry.command.title)
            }
            .keyboardShortcut(shortcut(entry.command))
        }
    }

    private func shortcut(_ command: ShortcutCommand) -> KeyboardShortcut {
        _ = shortcutsRevision
        return ShortcutStore.shared.shortcut(for: command).keyboardShortcut
    }
}
