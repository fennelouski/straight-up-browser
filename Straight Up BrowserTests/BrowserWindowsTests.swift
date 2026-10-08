import AppKit
import Foundation
import SwiftData
import Testing
@testable import Browser

@MainActor
struct BrowserWindowsTests {
    @Test func namesAndDistinctWorkspacesSurviveRelaunch() throws {
        let suite = "BrowserWindowsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowserWindows(defaults: defaults)
        let primary = store.primaryID
        let work = store.create(name: "Work")
        let personal = store.create(name: "Personal")
        #expect(store.record(work)?.homeWorkspaceID != store.record(personal)?.homeWorkspaceID)
        #expect(store.record(primary)?.homeWorkspaceID == nil)
        store.rename(work, to: "  Research  ")
        store.rename(work, to: "   ")
        let restored = BrowserWindows(defaults: defaults)
        #expect(restored.record(work)?.name == "Research")
        #expect(restored.records == store.records)
        var opened: [UUID] = []
        restored.restoreOtherWindows(excluding: primary) { opened.append($0) }
        restored.restoreOtherWindows(excluding: primary) { opened.append($0) }
        #expect(opened == [work, personal])
    }

    @Test func closedWindowsDoNotReopenOrDiscardTheirWorkspaces() throws {
        let suite = "BrowserWindowsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowserWindows(defaults: defaults)
        let second = store.create()
        let workspace = store.record(second)?.workspaceID
        store.didClose(second)
        let restored = BrowserWindows(defaults: defaults)
        var reopened: [UUID] = []
        restored.restoreOtherWindows(excluding: restored.primaryID) { reopened.append($0) }
        #expect(reopened.isEmpty)
        #expect(restored.record(second)?.workspaceID == workspace)
    }

    @Test func windowSelectionsAndSplitsPersistIndependently() {
        let a = UUID(), b = UUID(), tabA = Tab(), tabB = Tab()
        let managerA = TabManager(windowID: a, terminateApplication: {})
        let managerB = TabManager(windowID: b, terminateApplication: {})
        defer {
            for id in [a, b] {
                for key in ["selectedTabId", "splitTabIds", "activeWorkspaceId"] {
                    UserDefaults.standard.removeObject(forKey: key + "." + id.uuidString)
                }
            }
        }
        managerA.selectedTabId = tabA.id
        managerB.selectedTabId = tabB.id
        managerA.splitTabIds = [tabA.id, tabB.id]
        let restoredA = TabManager(windowID: a, terminateApplication: {})
        let restoredB = TabManager(windowID: b, terminateApplication: {})
        restoredA.restoreSplit(from: [tabA, tabB])
        restoredB.restoreSplit(from: [tabA, tabB])
        #expect(restoredA.splitTabIds == [tabA.id, tabB.id])
        #expect(restoredB.splitTabIds.isEmpty)
        #expect(UserDefaults.standard.string(forKey: "selectedTabId." + a.uuidString) == tabA.id.uuidString)
        #expect(UserDefaults.standard.string(forKey: "selectedTabId." + b.uuidString) == tabB.id.uuidString)
    }

    @Test func targetedCommandsReachOnlyTheSpecifiedWindow() throws {
        let suite = "BrowserWindowsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowserWindows(defaults: defaults)
        let a = store.primaryID, b = store.create()
        let windowA = NSWindow(), windowB = NSWindow()
        store.attach(windowA, id: a)
        store.attach(windowB, id: b)
        let command = Notification(name: .browserNewTab, object: windowA)
        #expect(store.accepts(command, in: a))
        #expect(!store.accepts(command, in: b))
        store.rename(b, to: "Personal")
        #expect(windowB.title == "Personal")
        #expect(windowA.title == "Browser")
    }

    @Test func leavingAWorkspaceReturnsToThatWindowsHome() {
        let home = UUID(), other = UUID(), window = UUID()
        let manager = TabManager(windowID: window, homeWorkspaceID: home, terminateApplication: {})
        defer { UserDefaults.standard.removeObject(forKey: "activeWorkspaceId." + window.uuidString) }
        manager.activeWorkspaceId = other
        manager.suspendWorkspace()
        #expect(manager.activeWorkspaceId == home)
    }
}
