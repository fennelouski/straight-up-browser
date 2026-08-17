import Foundation

enum MobileBrowserControlPlacement_iOS: String, CaseIterable, Identifiable, Sendable {
    case bottom
    case top
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottom: "Bottom"
        case .top: "Top"
        case .left: "Left"
        case .right: "Right"
        }
    }

    var systemImage: String {
        switch self {
        case .bottom: "rectangle.bottomthird.inset.filled"
        case .top: "rectangle.topthird.inset.filled"
        case .left: "rectangle.leftthird.inset.filled"
        case .right: "rectangle.rightthird.inset.filled"
        }
    }
}

enum MobileBrowserControlPlacementSettings_iOS {
    enum Key {
        static let global = "mobileBrowserControlPlacement"
        static let siteOverrides = "mobileBrowserControlPlacement.siteOverrides"
    }

    static func global(in defaults: UserDefaults = .standard) -> MobileBrowserControlPlacement_iOS {
        MobileBrowserControlPlacement_iOS(
            rawValue: defaults.string(forKey: Key.global) ?? ""
        ) ?? .bottom
    }

    static func placement(
        for url: URL?,
        siteOverridesData: Data,
        global: MobileBrowserControlPlacement_iOS
    ) -> MobileBrowserControlPlacement_iOS {
        guard let host = normalizedHost(url?.host),
              let rawValue = overrides(from: siteOverridesData)[host],
              let placement = MobileBrowserControlPlacement_iOS(rawValue: rawValue)
        else { return global }
        return placement
    }

    static func override(
        for url: URL?,
        siteOverridesData: Data
    ) -> MobileBrowserControlPlacement_iOS? {
        guard let host = normalizedHost(url?.host),
              let rawValue = overrides(from: siteOverridesData)[host]
        else { return nil }
        return MobileBrowserControlPlacement_iOS(rawValue: rawValue)
    }

    static func settingOverride(
        _ placement: MobileBrowserControlPlacement_iOS?,
        for url: URL?,
        in siteOverridesData: Data
    ) -> Data {
        guard let host = normalizedHost(url?.host) else { return siteOverridesData }
        var values = overrides(from: siteOverridesData)
        values[host] = placement?.rawValue
        return (try? JSONEncoder().encode(values)) ?? siteOverridesData
    }

    private static func overrides(from data: Data) -> [String: String] {
        guard !data.isEmpty else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func normalizedHost(_ host: String?) -> String? {
        guard let host else { return nil }
        let normalized = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
