//
//  Straight_Up_BrowserTests.swift
//  Straight Up BrowserTests
//
//  Created by Nathan Fennel on 1/9/26.
//

import Testing
import SwiftUI
import SwiftData
@testable import Browser

struct Straight_Up_BrowserTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

}

struct FindBarTests {

    @Test func matchCounterWrapsInBothDirections() {
        // Forward from "nothing found yet" lands on the first match and wraps at the end.
        #expect(FindBar.step(index: 0, count: 3, backwards: false) == 1)
        #expect(FindBar.step(index: 2, count: 3, backwards: false) == 3)
        #expect(FindBar.step(index: 3, count: 3, backwards: false) == 1)

        // Backwards from nothing (or from the first) wraps to the last.
        #expect(FindBar.step(index: 0, count: 3, backwards: true) == 3)
        #expect(FindBar.step(index: 1, count: 3, backwards: true) == 3)
        #expect(FindBar.step(index: 3, count: 3, backwards: true) == 2)

        // A single match stays put; no matches stays at zero.
        #expect(FindBar.step(index: 1, count: 1, backwards: false) == 1)
        #expect(FindBar.step(index: 1, count: 1, backwards: true) == 1)
        #expect(FindBar.step(index: 0, count: 0, backwards: false) == 0)
    }

    @Test func everyPositionMapsToADistinctAlignment() {
        let alignments = FindBar.positions.map(FindBar.alignment)
        for (i, a) in alignments.enumerated() {
            for b in alignments[(i + 1)...] { #expect(a != b) }
        }
        #expect(FindBar.alignment(FindBar.defaultPosition) == .topTrailing)
        #expect(FindBar.alignment("nonsense") == .topTrailing) // unknown value falls back
    }
}

// TabManager works with webViewManager: nil (optional chaining) and needs no
// modelContext for incognito, so its session logic is testable without a GUI.
@Suite(.serialized)
struct SessionIsolationTests {

    @Test func sessionKindAccessorRoundTrips() {
        let tab = Tab()
        #expect(tab.sessionKind == .normal)
        #expect(tab.sessionKindRaw == nil)

        tab.sessionKind = .incognito
        #expect(tab.sessionKind == .incognito)
        #expect(tab.sessionKindRaw == "incognito")

        // Normal stores nil, so existing rows never need migration.
        tab.sessionKind = .normal
        #expect(tab.sessionKindRaw == nil)
    }

    @Test func incognitoTabsAreInMemoryAndIsolated() {
        let manager = TabManager()
        let a = manager.createIncognitoTab()
        let b = manager.createIncognitoTab()

        // Held in the in-memory list (never inserted into SwiftData).
        #expect(manager.incognitoTabs.count == 2)
        #expect(a.sessionKind == .incognito && b.sessionKind == .incognito)
        // Two fresh incognito tabs are isolated: different session jars.
        #expect(a.sessionId != b.sessionId)

        // Opening into an existing session shares its jar id.
        let c = manager.createIncognitoTab(sessionId: a.sessionId)
        #expect(c.sessionId == a.sessionId)
    }

    @Test func closingIncognitoTabRemovesItWithoutSnapshot() {
        let manager = TabManager()
        let a = manager.createIncognitoTab()
        _ = manager.createIncognitoTab()
        let before = manager.closedTabs.count

        manager.closeTab(a, tabs: manager.incognitoTabs)
        #expect(!manager.incognitoTabs.contains { $0.id == a.id })
        #expect(manager.incognitoTabs.count == 1)
        // Incognito closes never hit the reopen stack (ephemeral + private).
        #expect(manager.closedTabs.count == before)
    }

    @Test func createTabInheritsSession() {
        let manager = TabManager()

        // Inheriting incognito → an incognito tab in the same session.
        let sid = UUID()
        let inc = manager.createTab(inheriting: (.incognito, sid))
        #expect(inc.sessionKind == .incognito && inc.sessionId == sid)
        #expect(manager.incognitoTabs.contains { $0.id == inc.id })

        // Inheriting container → a container tab tagged with the session, not in the
        // incognito list.
        let csid = UUID()
        let cont = manager.createTab(inheriting: (.container, csid))
        #expect(cont.sessionKind == .container && cont.sessionId == csid)
        #expect(!manager.incognitoTabs.contains { $0.id == cont.id })

        // Inheriting normal → a plain tab.
        let norm = manager.createTab(inheriting: (.normal, nil))
        #expect(norm.sessionKind == .normal && norm.sessionId == nil)
    }

    @Test func incognitoColorIsStablePerSession() {
        let id = UUID()
        #expect(BrowserSession.incognitoColor(for: id) == BrowserSession.incognitoColor(for: id))
    }

    // Builds the real app schema (with the new BrowserSession model + Tab session
    // fields) in memory to confirm it's valid and container tabs round-trip — a safe
    // proxy for "the app still launches and migrates" without touching real data.
    @Test func schemaBuildsAndPersistsContainerTabs() throws {
        let schema = Schema([Tab.self, TabGroup.self, Bookmark.self, BrowserSession.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let ctx = ModelContext(container)

        let session = BrowserSession(name: "Work", color: .blue)
        ctx.insert(session)
        let tab = Tab()
        tab.sessionKind = .container
        tab.sessionId = session.id
        ctx.insert(tab)
        try ctx.save()

        #expect(try ctx.fetch(FetchDescriptor<BrowserSession>()).count == 1)
        let stored = try ctx.fetch(FetchDescriptor<Browser.Tab>()).first
        #expect(stored?.sessionKind == .container)
        #expect(stored?.sessionId == session.id)
    }
}

// Serialized: these mutate the shared ShortcutStore singleton, so they must not
// run in parallel with each other.
@Suite(.serialized)
struct ShortcutTests {

    @Test func shortcutValueConversions() {
        let cmdShiftT = Shortcut(key: "t", command: true, shift: true)
        #expect(cmdShiftT.displayString == "⇧⌘T")
        #expect(cmdShiftT.displayTokens == ["⇧", "⌘", "T"])
        #expect(cmdShiftT.eventModifiers.contains(.command))
        #expect(cmdShiftT.eventModifiers.contains(.shift))
        #expect(cmdShiftT.hasModifier)

        // Special keys render as glyphs, not raw characters.
        #expect(ShortcutCommand.nextTab.defaultShortcut.displayTokens == ["⌃", "⇥"])
        #expect(ShortcutCommand.omnibar.defaultShortcut.displayString == "⌃Space")

        // No two defaults collide.
        var seen = Set<Shortcut>()
        for command in ShortcutCommand.all {
            #expect(seen.insert(command.defaultShortcut).inserted, "duplicate default for \(command.id)")
        }
    }

    @Test func shortcutStoreRebindResetAndConflicts() {
        let store = ShortcutStore.shared
        store.resetAll()

        // Defaults
        #expect(store.shortcut(for: .newTab).displayString == "⌘T")
        #expect(store.shortcut(for: .closeTab).displayString == "⌘W")
        #expect(store.conflicts().isEmpty)
        #expect(!store.isCustomized(.newTab))

        // Rebind → lookup reflects it and it counts as customized.
        store.rebind(.newTab, to: Shortcut(key: "y", command: true))
        #expect(store.shortcut(for: .newTab).displayString == "⌘Y")
        #expect(store.isCustomized(.newTab))

        // Two commands on the same chord are flagged as conflicting.
        store.rebind(.closeTab, to: Shortcut(key: "y", command: true))
        let conflictIDs = Set(store.conflicts().map(\.id))
        #expect(conflictIDs.contains("newTab"))
        #expect(conflictIDs.contains("closeTab"))

        // Rebinding back to the default drops the customization entirely.
        store.rebind(.newTab, to: ShortcutCommand.newTab.defaultShortcut)
        #expect(!store.isCustomized(.newTab))

        // Per-command reset and reset-all.
        store.reset(.closeTab)
        #expect(store.shortcut(for: .closeTab).displayString == "⌘W")
        store.resetAll()
        #expect(store.custom.isEmpty)
        #expect(store.conflicts().isEmpty)
    }

    @Test func presetsAndSystemConflicts() {
        let store = ShortcutStore.shared
        store.resetAll()

        // A preset changes the bindings it specifies, leaving the rest at default.
        store.apply(preset: .firefox)
        #expect(store.shortcut(for: .fullScreen).displayString == "⌃⌘F")
        #expect(store.shortcut(for: .showBookmarks).displayString == "⇧⌘O")
        #expect(store.shortcut(for: .newTab).displayString == "⌘T")

        // Applying another preset replaces the previous one wholesale.
        store.apply(preset: .arc)
        #expect(store.shortcut(for: .toggleTabBar).displayString == "⌘S")
        #expect(store.shortcut(for: .showBookmarks).displayString == "⇧⌘B")

        store.resetAll()
        #expect(store.custom.isEmpty)

        // Well-known system chords are recognized; ordinary ones aren't.
        #expect(store.systemConflict(Shortcut(key: " ", command: true)) == "Spotlight")
        #expect(store.systemConflict(Shortcut(key: "q", command: true)) == "Quit")
        #expect(store.systemConflict(Shortcut(key: "t", command: true)) == nil)
    }

    @Test func liveHighlightState() {
        let live = LiveKeyState.shared
        live.deactivate()
        live.isActive = true

        // Holding ⌘ alone lights the ⌘ token but not the key, and the ⌘T chord
        // isn't fully held yet.
        live.command = true
        let cmdT = Shortcut(key: "t", command: true)
        #expect(live.isHeld("⌘", in: cmdT))
        #expect(!live.isHeld("T", in: cmdT))
        #expect(!live.fullyHeld(cmdT))

        // Pressing T completes the chord.
        live.pressedKey = "t"
        #expect(live.isHeld("T", in: cmdT))
        #expect(live.fullyHeld(cmdT))

        // ⌘T held is not ⇧⌘T.
        let shiftCmdT = Shortcut(key: "t", command: true, shift: true)
        #expect(!live.isHeld("⇧", in: shiftCmdT))
        #expect(!live.fullyHeld(shiftCmdT))

        live.deactivate()
        #expect(!live.isActive)
    }
}

// Split view is window view state on TabManager (docs/adr/0001): ordered member
// ids + focused id, no SwiftData entity. Serialized: splitTabIds persists to
// shared UserDefaults on every mutation.
@Suite(.serialized)
struct SplitViewTests {

    private func makeTabs(_ n: Int) -> [Browser.Tab] {
        (0..<n).map { i in
            let tab = Browser.Tab()
            tab.orderIndex = i
            return tab
        }
    }

    private func cleanup(_ manager: TabManager) {
        manager.splitTabIds = []
        UserDefaults.standard.removeObject(forKey: "splitTabIds")
    }

    @Test func toggleAddsRemovesAndCapsAtFour() {
        let manager = TabManager()
        let tabs = makeTabs(6)
        manager.selectedTabId = tabs[0].id

        // First shift-click: split of [selected, clicked], focus moves to clicked
        manager.toggleSplitMembership(tabs[3], tabs: tabs)
        #expect(manager.splitTabIds == [tabs[0].id, tabs[3].id])
        #expect(manager.selectedTabId == tabs[3].id)

        // Members append in add order; the fifth is a no-op (cap = 2x2 grid)
        manager.toggleSplitMembership(tabs[1], tabs: tabs)
        manager.toggleSplitMembership(tabs[4], tabs: tabs)
        manager.toggleSplitMembership(tabs[5], tabs: tabs)
        #expect(manager.splitTabIds == [tabs[0].id, tabs[3].id, tabs[1].id, tabs[4].id])

        // Shift-click on a member removes its pane
        manager.toggleSplitMembership(tabs[1], tabs: tabs)
        #expect(manager.splitTabIds == [tabs[0].id, tabs[3].id, tabs[4].id])

        // Removing down to one pane dissolves the split; focus stays on a survivor
        manager.toggleSplitMembership(tabs[0], tabs: tabs)
        manager.toggleSplitMembership(tabs[3], tabs: tabs)
        #expect(manager.splitTabIds.isEmpty)
        #expect(manager.selectedTabId == tabs[4].id)
        cleanup(manager)
    }

    @Test func removingFocusedMemberMovesFocusToFirstRemaining() {
        let manager = TabManager()
        let tabs = makeTabs(3)
        manager.selectedTabId = tabs[0].id
        manager.toggleSplitMembership(tabs[1], tabs: tabs)
        manager.toggleSplitMembership(tabs[2], tabs: tabs)

        // tabs[2] is focused; removing it hands focus to the first remaining member
        manager.toggleSplitMembership(tabs[2], tabs: tabs)
        #expect(manager.splitTabIds == [tabs[0].id, tabs[1].id])
        #expect(manager.selectedTabId == tabs[0].id)
        cleanup(manager)
    }

    @Test func selectingNonMemberDissolvesSplit() {
        let manager = TabManager()
        let tabs = makeTabs(3)
        manager.selectedTabId = tabs[0].id
        manager.toggleSplitMembership(tabs[1], tabs: tabs)
        #expect(!manager.splitTabIds.isEmpty)

        // Any outside selection (click, Cmd+T, popup, tab cycling) returns to single view
        manager.selectedTabId = tabs[2].id
        #expect(manager.splitTabIds.isEmpty)
        cleanup(manager)
    }

    @Test func gatheringReordersMembersAfterAnchor() {
        let manager = TabManager()
        let tabs = makeTabs(6)
        manager.selectedTabId = tabs[1].id

        // Anchor (tabs[1]) keeps its position; the new member moves next to it
        manager.toggleSplitMembership(tabs[4], tabs: tabs)
        let ordered: [UUID] = tabs.sorted { $0.orderIndex < $1.orderIndex }.map(\.id)
        let expected: [UUID] = [0, 1, 4, 2, 3, 5].map { tabs[$0].id }
        #expect(ordered == expected)
        cleanup(manager)
    }

    @Test func closingMemberCollapsesOnlyItsPane() {
        let manager = TabManager()
        let tabs = makeTabs(3)
        manager.selectedTabId = tabs[0].id
        manager.toggleSplitMembership(tabs[1], tabs: tabs)
        manager.toggleSplitMembership(tabs[2], tabs: tabs)

        // Closing the focused member: its pane collapses, focus moves to a member,
        // and the rest of the split survives
        manager.closeTab(tabs[2], tabs: tabs)
        #expect(manager.splitTabIds == [tabs[0].id, tabs[1].id])
        #expect(manager.selectedTabId == tabs[0].id)

        // Closing another member leaves one pane: back to a normal single view
        let remaining = [tabs[0], tabs[1]]
        manager.closeTab(tabs[1], tabs: remaining)
        #expect(manager.splitTabIds.isEmpty)
        #expect(manager.selectedTabId == tabs[0].id)
        cleanup(manager)
    }

    @Test func restoreDropsUnresolvedIdsAndRealignsFocus() {
        let tabs = makeTabs(3)
        UserDefaults.standard.set(
            [tabs[1].id.uuidString, UUID().uuidString, tabs[2].id.uuidString],
            forKey: "splitTabIds")

        let manager = TabManager()
        manager.selectedTabId = tabs[0].id
        manager.restoreSplit(from: tabs)
        // The id closed on another device (or an incognito tab that died) is dropped
        #expect(manager.splitTabIds == [tabs[1].id, tabs[2].id])
        // The restored selection wasn't a member, so focus moves into the split
        #expect(manager.selectedTabId == tabs[1].id)
        cleanup(manager)

        // Fewer than 2 survivors: no split, and the stale persisted value is cleared
        UserDefaults.standard.set([UUID().uuidString, UUID().uuidString], forKey: "splitTabIds")
        let manager2 = TabManager()
        manager2.selectedTabId = tabs[0].id
        manager2.restoreSplit(from: tabs)
        #expect(manager2.splitTabIds.isEmpty)
        #expect(UserDefaults.standard.stringArray(forKey: "splitTabIds") == nil)
        cleanup(manager2)
    }
}

// setDisplayedTabs defers its work one runloop hop (to stay off SwiftUI's update
// pass), but WebView.updateNSView reads activeWebView back in that same pass to
// decide which web view to load the tab's URL into. If activeWebView reports the
// *old* focus, the newly selected tab's URL gets loaded into the previous tab's
// web view — pages jumping between tabs, duplicates, panes showing each other's
// content. So activeWebView must answer for the focus most recently requested,
// not the one last applied.
@Suite(.serialized)
@MainActor
struct PaneFocusTests {

    private func drainMainQueue() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test func activeWebViewFollowsRequestedFocusBeforeApply() async {
        let webViewManager = WebViewManager()
        let container = WebViewContainer(webViewManager: webViewManager, coordinator: nil)
        let tabA = UUID(), tabB = UUID()

        container.setDisplayedTabs([tabA], focusedTabId: tabA)
        await drainMainQueue()
        let viewA = webViewManager.existingWebView(for: tabA)
        #expect(viewA != nil)
        #expect(container.activeWebView === viewA)

        // Same runloop turn as the request — exactly where updateNSView reads it.
        container.setDisplayedTabs([tabB], focusedTabId: tabB)
        #expect(container.activeWebView !== viewA)
        #expect(container.activeWebView === webViewManager.existingWebView(for: tabB))

        // And still correct once the deferred apply lands.
        await drainMainQueue()
        #expect(container.activeWebView === webViewManager.existingWebView(for: tabB))
    }

    @Test func focusRequestIsNotLostWhenAnUpdateRepeatsTheAppliedState() async {
        let webViewManager = WebViewManager()
        let container = WebViewContainer(webViewManager: webViewManager, coordinator: nil)
        let tabA = UUID(), tabB = UUID()

        container.setDisplayedTabs([tabA], focusedTabId: tabA)
        await drainMainQueue()

        // Rapid clicking produces bursts of updates within one turn. A pass that
        // happens to restate the applied focus must not cancel the pending one.
        container.setDisplayedTabs([tabB], focusedTabId: tabB)
        container.setDisplayedTabs([tabA], focusedTabId: tabA)
        await drainMainQueue()
        #expect(container.activeWebView === webViewManager.existingWebView(for: tabA))
    }
}
