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
}
