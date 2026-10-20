import Foundation
import CoreGraphics

/// Viewport-relative preferences; page scroll offsets are deliberately absent.
nonisolated enum MobileChromeSettings {
    static let customPosition = "mobileChrome.customPosition"
    static let x = "mobileChrome.x"
    static let y = "mobileChrome.y"
    static let width = "mobileChrome.width"
    static let snapping = "mobileChrome.snapping"
    static let hidden = "mobileChrome.hidden"
    static let hideGesture = "mobileChrome.hideGesture"
    static let visualTabsGesture = "mobileChrome.visualTabsGesture"
    static let rotationRules = "mobileChrome.rotationRules"
}

nonisolated enum MobileChromeLayout {
    static let minimumWidth = 0.30
    static let hitHeight = 44.0
    static func unit(_ value: Double, fallback: Double = 0.5) -> Double {
        value.isFinite ? min(1, max(0, value)) : fallback
    }
    static func widthFraction(_ value: Double) -> Double { max(minimumWidth, unit(value)) }

    static func frame(viewport: CGRect, containerWidth: CGFloat, x: Double, y: Double, width: Double) -> CGRect {
        // Width percentages refer to the local containing view, before safe-area
        // insets. Containment wins only if that view has insufficient usable space.
        let containingWidth = containerWidth.isFinite ? max(0, containerWidth) : viewport.width
        let length = min(viewport.width, max(44, containingWidth * widthFraction(width)))
        let height = min(hitHeight, viewport.height)
        return CGRect(x: viewport.minX + (viewport.width - length) * unit(x),
                      y: viewport.minY + (viewport.height - height) * unit(y),
                      width: length, height: height)
    }

    static func normalized(center: CGPoint, frame: CGRect, viewport: CGRect) -> CGPoint {
        CGPoint(x: unit((center.x - viewport.minX - frame.width / 2) / max(1, viewport.width - frame.width)),
                y: unit((center.y - viewport.minY - frame.height / 2) / max(1, viewport.height - frame.height)))
    }

    /// Acquire at 8pt, retain until 16pt away. Targets are fixed viewport edges
    /// verified by the sampler; callers only snap during deliberate placement.
    static func snap(_ value: Double, targets: [Double], held: Double?) -> Double? {
        if let held, targets.contains(where: { abs($0 - held) < 1 }), abs(value - held) <= 16 { return held }
        return targets.filter(\.isFinite).filter { abs($0 - value) <= 8 }
            .min { abs($0 - value) < abs($1 - value) }
    }

    static func canonicalURL(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        if parts.path.isEmpty { parts.path = "/" }
        return parts.string ?? url.absoluteString
    }
}

/// Exact host only: no suffix matches, implicit www aliases, or URL paths.
nonisolated enum MobileDomainRotation {
    static let allowedValues: Set<String> = ["allow", "locked"]
    static func host(_ url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }
    static func rules(_ data: Data) -> [String: String] {
        let decoded = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        return decoded.filter { allowedValues.contains($0.value) && !$0.key.isEmpty }
    }
    static func setting(_ value: String?, for url: URL?, in data: Data) -> Data {
        guard let host = host(url), value == nil || allowedValues.contains(value!) else { return data }
        var result = rules(data)
        result[host] = value
        return (try? JSONEncoder().encode(result)) ?? data
    }
}
