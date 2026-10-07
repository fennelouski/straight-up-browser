import SwiftUI

/// Each enabled edge owns half of a shared corner, or the whole corner when
/// its neighbouring edge is disabled. Horizontal edges fill left to right;
/// vertical edges fill top to bottom.
struct WindowEdgeProgress: View {
    var progress: Double
    var color: Color
    var cornerRadius: CGFloat
    var top: Bool
    var bottom: Bool
    var left: Bool
    var right: Bool
    var lineWidth: CGFloat = 1

    var body: some View {
        ZStack {
            if top { indicator(.top, startShared: left, endShared: right) }
            if bottom { indicator(.bottom, startShared: left, endShared: right) }
            if left { indicator(.left, startShared: top, endShared: bottom) }
            if right { indicator(.right, startShared: top, endShared: bottom) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func indicator(_ edge: WindowEdgeProgressShape.Edge,
                           startShared: Bool, endShared: Bool) -> some View {
        let shape = WindowEdgeProgressShape(edge: edge, cornerRadius: cornerRadius,
                                           lineWidth: lineWidth,
                                           startShared: startShared, endShared: endShared)
        return ZStack {
            shape.stroke(Color.gray.opacity(0.2), lineWidth: lineWidth)
            shape.trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .animation(.linear(duration: 0.1), value: progress)
        }
    }
}

struct WindowEdgeProgressShape: Shape {
    enum Edge { case top, bottom, left, right }

    var edge: Edge
    var cornerRadius: CGFloat
    var lineWidth: CGFloat
    var startShared: Bool
    var endShared: Bool

    func path(in rect: CGRect) -> Path {
        let inset = lineWidth / 2
        guard rect.width > lineWidth, rect.height > lineWidth else { return Path() }
        let bounds = rect.insetBy(dx: inset, dy: inset)
        let horizontal = edge == .top || edge == .bottom
        let length = horizontal ? bounds.width : bounds.height
        let radius = max(0, min(cornerRadius - inset, min(bounds.width, bounds.height) / 2))
        let path = topPath(length: length, radius: radius)
        let transform: CGAffineTransform
        switch edge {
        case .top:
            transform = CGAffineTransform(translationX: bounds.minX, y: bounds.minY)
        case .bottom:
            transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: bounds.minX, ty: bounds.maxY)
        case .left:
            transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: bounds.minX, ty: bounds.minY)
        case .right:
            transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: bounds.maxX, ty: bounds.minY)
        }
        return path.applying(transform)
    }

    private func topPath(length: CGFloat, radius: CGFloat) -> Path {
        guard radius > 0 else {
            var path = Path()
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: length, y: 0))
            return path
        }

        // Ask SwiftUI for the same continuous curve used by the window clip.
        // A circular arc would be clipped near the middle of this corner.
        let height = max(length, radius * 4)
        let outline = RoundedRectangle(cornerRadius: radius, style: .continuous)
            .path(in: CGRect(x: 0, y: 0, width: length, height: height))
        var leadingCorner = Path()
        var trailingCorner = Path()
        var straight = Path()
        var current = CGPoint.zero
        outline.cgPath.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                current = element.points[0]
            case .addLineToPoint:
                let end = element.points[0]
                if current.y == 0 && end.y == 0 {
                    straight.move(to: current)
                    straight.addLine(to: end)
                }
                current = end
            case .addCurveToPoint:
                let end = element.points[2]
                if current.y < height / 2 && end.y < height / 2 {
                    if current.x < length / 2 {
                        if leadingCorner.isEmpty { leadingCorner.move(to: current) }
                        leadingCorner.addCurve(to: end, control1: element.points[0], control2: element.points[1])
                    } else {
                        if trailingCorner.isEmpty { trailingCorner.move(to: current) }
                        trailingCorner.addCurve(to: end, control1: element.points[0], control2: element.points[1])
                    }
                }
                current = end
            default:
                break
            }
        }
        var path = Path()
        path.addPath(leadingCorner.trimmedPath(from: startShared ? 0.5 : 0, to: 1))
        path.addPath(straight)
        path.addPath(trailingCorner.trimmedPath(from: 0, to: endShared ? 0.5 : 1))
        return path
    }
}
