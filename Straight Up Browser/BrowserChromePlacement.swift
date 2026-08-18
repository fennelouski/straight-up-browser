import Foundation
import SwiftUI

enum BrowserChromeSide: String, CaseIterable, Identifiable, Sendable {
    case left
    case right

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var systemImage: String { self == .left ? "sidebar.left" : "sidebar.right" }
    var alignment: Alignment { self == .left ? .leading : .trailing }
    var edge: Edge { self == .left ? .leading : .trailing }
}

enum BrowserChromePlacementSettings {
    enum Key {
        static let agentPanelSide = "browserAgentPanelSide"
        static let tabSidebarSide = "tabSidebarSide"
    }

    static func agentPanelSide(in defaults: UserDefaults = .standard) -> BrowserChromeSide {
        BrowserChromeSide(rawValue: defaults.string(forKey: Key.agentPanelSide) ?? "") ?? .left
    }

    static func tabSidebarSide(in defaults: UserDefaults = .standard) -> BrowserChromeSide {
        BrowserChromeSide(rawValue: defaults.string(forKey: Key.tabSidebarSide) ?? "") ?? .left
    }
}

enum BrowserChromeLayout {
    static func reservedWidth(
        on side: BrowserChromeSide,
        tabWidth: CGFloat,
        tabSide: BrowserChromeSide,
        agentVisible: Bool,
        agentResizesPage: Bool,
        agentWidth: CGFloat,
        agentSide: BrowserChromeSide
    ) -> CGFloat {
        let tabReservation = tabWidth > 0 && tabSide == side ? tabWidth : 0
        let agentReservation = agentVisible && agentResizesPage && agentSide == side
            ? agentWidth
            : 0
        return max(tabReservation, agentReservation)
    }

    static func faviconPeekSide(
        tabSide: BrowserChromeSide,
        agentVisible: Bool,
        agentSide: BrowserChromeSide
    ) -> BrowserChromeSide {
        agentVisible ? agentSide : tabSide
    }

    static func faviconPeekInset(agentVisible: Bool, agentWidth: CGFloat) -> CGFloat {
        agentVisible ? agentWidth : 0
    }

    /// How much of the window the tab sidebar may cover. Visual tab cards are
    /// the reason it goes this far: browsing them wants close to the whole
    /// window, and the page is one drag away from coming back.
    static let maximumTabWidthFraction: CGFloat = 0.9

    /// The widest the sidebar may be dragged. Passing no window width keeps the
    /// old fixed ceiling, which is all a caller without a window can honestly do.
    static func maximumTabWidth(windowWidth: CGFloat?) -> CGFloat {
        guard let windowWidth, windowWidth > 0 else { return 400 }
        return windowWidth * maximumTabWidthFraction
    }

    static func resizedTabWidth(
        currentWidth: CGFloat,
        translationX: CGFloat,
        side: BrowserChromeSide,
        maximumWidth: CGFloat = 400
    ) -> CGFloat {
        let signedTranslation = side == .left ? translationX : -translationX
        // A sidebar already wider than the ceiling (a smaller display, or a
        // window that shrank under it) may still be dragged narrower.
        let ceiling = max(maximumWidth, currentWidth)
        return max(0, min(ceiling, currentWidth + signedTranslation))
    }
}
