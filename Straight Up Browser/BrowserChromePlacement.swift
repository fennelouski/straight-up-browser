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

    static func resizedTabWidth(
        currentWidth: CGFloat,
        translationX: CGFloat,
        side: BrowserChromeSide
    ) -> CGFloat {
        let signedTranslation = side == .left ? translationX : -translationX
        return max(0, min(400, currentWidth + signedTranslation))
    }
}
