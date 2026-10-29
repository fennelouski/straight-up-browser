#if os(macOS)
import Foundation
import Testing
@testable import Browser

@MainActor
struct NewCommandTests {
    @Test func preferencesRoundTripEveryCombinationAndRecoverInvalidValues() throws {
        let suite = "NewCommandTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(NewCommandPreferences.destination(defaults: defaults) == .window)
        #expect(NewCommandPreferences.presentation(defaults: defaults) == .omnibar)
        for destination in NewCommandDestination.allCases {
            for presentation in NewCommandPresentation.allCases {
                defaults.set(destination.rawValue, forKey: NewCommandDestination.key)
                defaults.set(presentation.rawValue, forKey: NewCommandPresentation.key)
                #expect(NewCommandPreferences.destination(defaults: defaults) == destination)
                #expect(NewCommandPreferences.presentation(defaults: defaults) == presentation)
            }
        }
        defaults.set("unknown", forKey: NewCommandDestination.key)
        defaults.set("unknown", forKey: NewCommandPresentation.key)
        #expect(NewCommandPreferences.destination(defaults: defaults) == .window)
        #expect(NewCommandPreferences.presentation(defaults: defaults) == .omnibar)
    }

    @Test func paneMovementPreservesFocusAndPersistsOrderWithoutWrapping() {
        let window = UUID()
        defer {
            for key in ["selectedTabId", "splitTabIds", "activeWorkspaceId"] {
                UserDefaults.standard.removeObject(forKey: key + "." + window.uuidString)
            }
        }
        let manager = TabManager(windowID: window, terminateApplication: {})
        let tabs = [Tab(), Tab(), Tab()]
        let ids = tabs.map(\.id)
        manager.splitTabIds = ids
        manager.selectedTabId = ids[1]
        #expect(manager.moveFocusedPane(by: -1))
        #expect(manager.splitTabIds == [ids[1], ids[0], ids[2]])
        #expect(manager.selectedTabId == ids[1])
        #expect(!manager.moveFocusedPane(by: -1))
        #expect(manager.moveFocusedPane(by: 1))
        #expect(manager.moveFocusedPane(by: 1))
        #expect(!manager.moveFocusedPane(by: 1))
        #expect(!manager.moveFocusedPane(by: 2))
        let restored = TabManager(windowID: window, terminateApplication: {})
        restored.restoreSplit(from: tabs)
        #expect(restored.splitTabIds == [ids[0], ids[2], ids[1]])
        #expect(UserDefaults.standard.string(forKey: "selectedTabId." + window.uuidString) == ids[1].uuidString)
    }

    @Test func focusedDocumentMovesAndSoloPaneDoesNothing() {
        let window = UUID()
        defer {
            for key in ["selectedTabId", "splitTabIds", "activeWorkspaceId"] {
                UserDefaults.standard.removeObject(forKey: key + "." + window.uuidString)
            }
        }
        let manager = TabManager(windowID: window, terminateApplication: {})
        let web = UUID(), document = UUID()
        manager.selectedTabId = web
        #expect(!manager.moveFocusedPane(by: 1))
        manager.splitTabIds = [web, document]
        manager.focusedDocumentId = document
        #expect(manager.moveFocusedPane(by: -1))
        #expect(manager.splitTabIds == [document, web])
        #expect(manager.focusedDocumentId == document)
    }

    @Test func splitCreationKeepsSessionFocusAndExistingBlankPanesAtTheCap() throws {
        let window = UUID()
        defer {
            for key in ["selectedTabId", "splitTabIds", "activeWorkspaceId"] {
                UserDefaults.standard.removeObject(forKey: key + "." + window.uuidString)
            }
        }
        let manager = TabManager(windowID: window, terminateApplication: {})
        let source = manager.createIncognitoTab()
        var tabs = [source]
        for _ in 1..<TabManager.maxSplitTabs {
            let created = try #require(manager.createCommandTab(inSplit: true, tabs: tabs, inheriting: source.browsingContext))
            tabs.append(created)
            #expect(created.sessionId == source.sessionId)
            #expect(created.sessionKind == .incognito)
            #expect(manager.selectedTabId == created.id)
            #expect(manager.splitTabIds == tabs.map(\.id))
        }
        let order = manager.splitTabIds
        let focus = manager.selectedTabId
        #expect(manager.createCommandTab(inSplit: true, tabs: tabs, inheriting: source.browsingContext) == nil)
        #expect(manager.splitTabIds == order)
        #expect(manager.selectedTabId == focus)
        #expect(manager.splitTabIds.contains(source.id))
    }

    @Test func paneChordsDoNotSnapWindowsOrCollideWithDefaults() {
        #expect(ShortcutCommand.movePaneLeft.defaultShortcut == Shortcut(key: "\u{F702}", command: true, option: true, control: true))
        #expect(ShortcutCommand.movePaneRight.defaultShortcut == Shortcut(key: "\u{F703}", command: true, option: true, control: true))
        let defaults = ShortcutCommand.all.map(\.defaultShortcut)
        #expect(Set(defaults).count == defaults.count)
        #expect(ShortcutCommand.windowSnapLeft.defaultShortcut.shift)
        #expect(ShortcutCommand.windowSnapRight.defaultShortcut.shift)
        #expect(KeyboardShortcutsManager.fixedChords[ShortcutCommand.newCommand.defaultShortcut] == nil)
    }
}
#endif
