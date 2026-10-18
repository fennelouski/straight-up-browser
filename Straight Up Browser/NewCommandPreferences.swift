import Foundation

/// Destination and presentation are independent, so every combination stays available.
enum NewCommandDestination: String, CaseIterable {
    case window, currentContext, tab, splitPane
    static let key = "newCommandDestination"
    var label: String {
        switch self {
        case .window: "New window"
        case .currentContext: "Current context"
        case .tab: "New tab"
        case .splitPane: "New tab in a split pane"
        }
    }
}

enum NewCommandPresentation: String, CaseIterable {
    case omnibar, visualTabs, weather
    static let key = "newCommandPresentation"
    var label: String {
        switch self {
        case .omnibar: "Omnibar"
        case .visualTabs: "Omnibar over visual tabs"
        case .weather: "Omnibar showing weather"
        }
    }
}

@MainActor
enum NewCommandPreferences {
    static var pendingWindows: [UUID: NewCommandPresentation] = [:]
    static func destination(defaults: UserDefaults = .standard) -> NewCommandDestination {
        NewCommandDestination(rawValue: defaults.string(forKey: NewCommandDestination.key) ?? "") ?? .window
    }
    static func presentation(defaults: UserDefaults = .standard) -> NewCommandPresentation {
        NewCommandPresentation(rawValue: defaults.string(forKey: NewCommandPresentation.key) ?? "") ?? .omnibar
    }
}
