import Foundation
import Testing
@testable import Browser

@MainActor
struct RecentTabCyclingTests {
    /// ⌘Tab semantics: the order freezes for the length of one hold, and only
    /// what you landed on moves to the front when the hold ends.
    @Test func cyclingWalksMostRecentlyUsedOrderAndCommitsOnRelease() {
        let manager = TabManager()
        let a = manager.createIncognitoTab()
        let b = manager.createIncognitoTab()
        let c = manager.createIncognitoTab()
        let tabs = [a, b, c]

        // Visited a, then b, then c — c is where we are.
        for tab in tabs { manager.selectedTabId = tab.id }
        #expect(manager.recentTabIds == [c.id, b.id, a.id])

        // One press lands on the tab you came from, whatever the sidebar order.
        manager.cycleRecentTab(forward: true, tabs: tabs)
        #expect(manager.selectedTabId == b.id)
        // The order is frozen, so a second press keeps going rather than
        // bouncing back to c.
        manager.cycleRecentTab(forward: true, tabs: tabs)
        #expect(manager.selectedTabId == a.id)
        // Back up the same list.
        manager.cycleRecentTab(forward: false, tabs: tabs)
        #expect(manager.selectedTabId == b.id)

        // Control released: only the tab we landed on is promoted; passing
        // through a did not count as using it.
        manager.endRecentTabCycle()
        #expect(manager.recentTabIds == [b.id, c.id, a.id])

        // So the next single press goes back to c.
        manager.cycleRecentTab(forward: true, tabs: tabs)
        #expect(manager.selectedTabId == c.id)
    }

    @Test func selectingATabOutsideTheCycleEndsIt() {
        let manager = TabManager()
        let a = manager.createIncognitoTab()
        let b = manager.createIncognitoTab()
        let c = manager.createIncognitoTab()
        let tabs = [a, b, c]
        for tab in tabs { manager.selectedTabId = tab.id }

        manager.cycleRecentTab(forward: true, tabs: tabs)
        #expect(manager.selectedTabId == b.id)

        // A click (or ⌘1, or a close) commits immediately — the frozen order
        // can never outlive the hold that created it.
        manager.selectedTabId = a.id
        #expect(manager.recentTabIds.first == a.id)
        manager.cycleRecentTab(forward: true, tabs: tabs)
        #expect(manager.selectedTabId == b.id)
    }
}

struct NewTabButtonVisibilityTests {
    private func defaults(_ name: String = #function) -> UserDefaults {
        let suite = "new-tab-button-\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    @Test func buttonRetiresOnlyAfterBothAWeekAndTenLaunches() {
        let store = defaults()
        let day1 = Date(timeIntervalSince1970: 1_000_000)
        let day9 = day1.addingTimeInterval(9 * 24 * 60 * 60)

        NewTabButtonVisibility.noteLaunch(now: day1, defaults: store)
        #expect(NewTabButtonVisibility.isVisible(store))

        // A week of neglect is not enough on its own: only two launches.
        NewTabButtonVisibility.noteLaunch(now: day9, defaults: store)
        #expect(NewTabButtonVisibility.isVisible(store))

        // Ten launches without a click, still on day 9 — now it retires.
        for _ in 0..<9 { NewTabButtonVisibility.noteLaunch(now: day9, defaults: store) }
        #expect(!NewTabButtonVisibility.isVisible(store))
    }

    @Test func clickingResetsTheClockAndAnExplicitChoiceSticks() {
        let store = defaults()
        let day1 = Date(timeIntervalSince1970: 1_000_000)
        let day9 = day1.addingTimeInterval(9 * 24 * 60 * 60)

        NewTabButtonVisibility.noteLaunch(now: day1, defaults: store)
        for _ in 0..<12 { NewTabButtonVisibility.noteLaunch(now: day1, defaults: store) }
        NewTabButtonVisibility.noteUsed(now: day1, defaults: store)

        // Used on day 1, so the launch count restarts from there.
        for _ in 0..<12 { NewTabButtonVisibility.noteLaunch(now: day1, defaults: store) }
        #expect(NewTabButtonVisibility.isVisible(store))

        // Nine days later with those launches behind it, it retires…
        NewTabButtonVisibility.noteLaunch(now: day9, defaults: store)
        #expect(!NewTabButtonVisibility.isVisible(store))

        // …and turning it back on in Settings is final.
        store.set(true, forKey: NewTabButtonVisibility.visibleKey)
        for _ in 0..<30 { NewTabButtonVisibility.noteLaunch(now: day9, defaults: store) }
        #expect(NewTabButtonVisibility.isVisible(store))
    }
}
