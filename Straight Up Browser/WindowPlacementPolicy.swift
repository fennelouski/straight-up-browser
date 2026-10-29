#if os(macOS)
import AppKit

/// Geometry is derived on each invocation. Actual geometry is the cycle state;
/// there is no stale index or timer to survive a manual resize/display change.
@MainActor
enum WindowPlacementPolicy {
    enum Preset: Equatable {
        case edge(WindowLayout.SnapDirection, Int)
        case centered(Int)
    }

    struct Constraints {
        var minimum = CGSize.zero
        var maximum = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        var aspectRatio = CGSize.zero
        var resizeIncrements = CGSize(width: 1, height: 1)
        var contentInset = CGSize.zero
    }

    static let centeredRatios: [CGFloat] = [0.5, 1.0 / 3, 0.25]

    static func cycle(for direction: WindowLayout.SnapDirection) -> [Preset] {
        let edges = WindowLayout.snapRatios.indices.map { Preset.edge(direction, $0) }
        return direction == .top || direction == .bottom
            ? edges + centeredRatios.indices.map(Preset.centered) : edges
    }

    static func frame(for preset: Preset, in visible: CGRect, scale: CGFloat) -> CGRect {
        let factor = max(1, scale)
        func aligned(_ value: CGFloat) -> CGFloat { (value * factor).rounded() / factor }
        let left = ceil(visible.minX * factor) / factor
        let right = floor(visible.maxX * factor) / factor
        let bottom = ceil(visible.minY * factor) / factor
        let top = floor(visible.maxY * factor) / factor
        switch preset {
        case .centered(let index):
            let width = visible.width * centeredRatios[index]
            let minX = max(left, aligned(visible.midX - width / 2))
            let maxX = min(right, aligned(visible.midX + width / 2))
            return CGRect(x: minX, y: bottom, width: maxX - minX, height: top - bottom)
        case .edge(let direction, let index):
            let ratio = WindowLayout.snapRatios[index]
            switch direction {
            case .left:
                return CGRect(x: left, y: bottom, width: aligned(visible.minX + visible.width * ratio) - left, height: top - bottom)
            case .right:
                let edge = aligned(visible.maxX - visible.width * ratio)
                return CGRect(x: edge, y: bottom, width: right - edge, height: top - bottom)
            case .top:
                // Both halves use the same aligned dividing edge on odd sizes.
                let edge = aligned(visible.minY + visible.height * (1 - ratio))
                return CGRect(x: left, y: edge, width: right - left, height: top - edge)
            case .bottom:
                return CGRect(x: left, y: bottom, width: right - left, height: aligned(visible.minY + visible.height * ratio) - bottom)
            }
        }
    }

    static func matches(_ first: CGRect, _ second: CGRect, scale: CGFloat) -> Bool {
        let tolerance = 1 / max(1, scale) + 0.000_001
        return abs(first.minX - second.minX) <= tolerance && abs(first.maxX - second.maxX) <= tolerance
            && abs(first.minY - second.minY) <= tolerance && abs(first.maxY - second.maxY) <= tolerance
    }

    static func isFeasible(_ frame: CGRect, constraints: Constraints, scale: CGFloat) -> Bool {
        let epsilon: CGFloat = 0.000_001
        guard frame.width + epsilon >= constraints.minimum.width,
              frame.height + epsilon >= constraints.minimum.height,
              frame.width <= constraints.maximum.width + epsilon,
              frame.height <= constraints.maximum.height + epsilon else { return false }
        let content = CGSize(width: frame.width - constraints.contentInset.width,
                             height: frame.height - constraints.contentInset.height)
        let tolerance = 1 / max(1, scale) + epsilon
        if constraints.aspectRatio.width > 0 && constraints.aspectRatio.height > 0 {
            let expected = content.height * constraints.aspectRatio.width / constraints.aspectRatio.height
            guard abs(expected - content.width) <= tolerance else { return false }
        }
        for (value, increment) in [(content.width, constraints.resizeIncrements.width),
                                   (content.height, constraints.resizeIncrements.height)] where increment > 0 {
            guard abs(value - (value / increment).rounded() * increment) <= tolerance else { return false }
        }
        return true
    }

    static func nextFrame(from current: CGRect, direction: WindowLayout.SnapDirection,
                          in visible: CGRect, scale: CGFloat, constraints: Constraints = Constraints()) -> CGRect? {
        let cycle = cycle(for: direction)
        var feasible: [(index: Int, frame: CGRect)] = []
        for (index, preset) in cycle.enumerated() {
            let candidate = frame(for: preset, in: visible, scale: scale)
            guard isFeasible(candidate, constraints: constraints, scale: scale),
                  !feasible.contains(where: { matches($0.frame, candidate, scale: scale) }) else { continue }
            feasible.append((index, candidate))
        }
        guard !feasible.isEmpty else { return nil }
        // Recognize current geometry even when it is now infeasible, then skip
        // only the unavailable subsequent presets in canonical cycle order.
        let currentIndex = cycle.firstIndex { matches(current, frame(for: $0, in: visible, scale: scale), scale: scale) }
        guard let currentIndex else { return feasible[0].frame }
        return (feasible.first { $0.index > currentIndex } ?? feasible[0]).frame
    }

    /// Used only if NSWindow.screen is absent. Ties retain screen-list order.
    static func fallbackScreenIndex(window: CGRect, screens: [CGRect], visibleScreens: [CGRect]? = nil) -> Int? {
        guard !screens.isEmpty else { return nil }
        var best = 0
        var bestArea: CGFloat = 0
        for (index, screen) in screens.enumerated() {
            let intersection = window.intersection(screen)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > bestArea { best = index; bestArea = area }
        }
        if bestArea > 0 { return best }
        var nearest = CGFloat.greatestFiniteMagnitude
        let usable: [CGRect]
        if let visibleScreens, visibleScreens.count == screens.count { usable = visibleScreens }
        else { usable = screens }
        for (index, screen) in usable.enumerated() {
            let dx = screen.midX - window.midX, dy = screen.midY - window.midY
            let distance = dx * dx + dy * dy
            if distance < nearest { best = index; nearest = distance }
        }
        return best
    }
}
#endif
