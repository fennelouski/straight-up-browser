import Foundation
import Testing
@testable import Browser

struct BrowserChromePlacementTests {
    @Test func agentAndTabSidesDefaultLeftAndPersistIndependently() throws {
        let suiteName = "BrowserChromePlacementTests.Settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        #expect(BrowserChromePlacementSettings.agentPanelSide(in: defaults) == .left)
        #expect(BrowserChromePlacementSettings.tabSidebarSide(in: defaults) == .left)

        defaults.set(
            BrowserChromeSide.right.rawValue,
            forKey: BrowserChromePlacementSettings.Key.agentPanelSide
        )
        #expect(BrowserChromePlacementSettings.agentPanelSide(in: defaults) == .right)
        #expect(BrowserChromePlacementSettings.tabSidebarSide(in: defaults) == .left)
    }

    @Test func agentCoversSameSideTabsWithoutDoubleReservingSpace() {
        let leftWidth = BrowserChromeLayout.reservedWidth(
            on: .left,
            tabWidth: 200,
            tabSide: .left,
            agentVisible: true,
            agentResizesPage: true,
            agentWidth: 380,
            agentSide: .left
        )
        let rightWidth = BrowserChromeLayout.reservedWidth(
            on: .right,
            tabWidth: 200,
            tabSide: .left,
            agentVisible: true,
            agentResizesPage: true,
            agentWidth: 380,
            agentSide: .left
        )

        #expect(leftWidth == 380)
        #expect(rightWidth == 0)
    }

    @Test func oppositeSidesReserveTheirOwnEdges() {
        let leftWidth = BrowserChromeLayout.reservedWidth(
            on: .left,
            tabWidth: 200,
            tabSide: .left,
            agentVisible: true,
            agentResizesPage: true,
            agentWidth: 380,
            agentSide: .right
        )
        let rightWidth = BrowserChromeLayout.reservedWidth(
            on: .right,
            tabWidth: 200,
            tabSide: .left,
            agentVisible: true,
            agentResizesPage: true,
            agentWidth: 380,
            agentSide: .right
        )

        #expect(leftWidth == 200)
        #expect(rightWidth == 380)
    }

    @Test func hiddenTabPeekFollowsTheVisibleAgentEdge() {
        #expect(BrowserChromeLayout.faviconPeekSide(
            tabSide: .right,
            agentVisible: false,
            agentSide: .left
        ) == .right)
        #expect(BrowserChromeLayout.faviconPeekSide(
            tabSide: .right,
            agentVisible: true,
            agentSide: .left
        ) == .left)
        #expect(BrowserChromeLayout.faviconPeekInset(
            agentVisible: true,
            agentWidth: 380
        ) == 380)
    }

    @Test func resizeDragDirectionMirrorsWithTheSidebarSide() {
        #expect(BrowserChromeLayout.resizedTabWidth(
            currentWidth: 200,
            translationX: 30,
            side: .left
        ) == 230)
        #expect(BrowserChromeLayout.resizedTabWidth(
            currentWidth: 200,
            translationX: -30,
            side: .right
        ) == 230)
    }

    @Test func theSidebarStopsAtNineTenthsOfTheWindow() {
        // Visual tab cards want most of the window, so the ceiling follows the
        // window instead of the old fixed 400pt.
        #expect(BrowserChromeLayout.maximumTabWidth(windowWidth: 1600) == 1440)
        // No window to measure: the fixed ceiling is all we can honestly do.
        #expect(BrowserChromeLayout.maximumTabWidth(windowWidth: nil) == 400)
        #expect(BrowserChromeLayout.maximumTabWidth(windowWidth: 0) == 400)

        // Dragging wider stops at the ceiling…
        #expect(BrowserChromeLayout.resizedTabWidth(
            currentWidth: 1400,
            translationX: 400,
            side: .left,
            maximumWidth: 1440
        ) == 1440)
        // …but a sidebar already past it (the window shrank under it) can still
        // be dragged back in.
        #expect(BrowserChromeLayout.resizedTabWidth(
            currentWidth: 1400,
            translationX: -200,
            side: .left,
            maximumWidth: 900
        ) == 1200)
    }
}
