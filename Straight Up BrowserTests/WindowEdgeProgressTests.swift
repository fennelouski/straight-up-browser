import SwiftUI
import Testing
@testable import Browser

struct WindowEdgeProgressTests {
    private let rect = CGRect(x: 0, y: 0, width: 600, height: 400)

    private func path(_ edge: WindowEdgeProgressShape.Edge, shared: Bool,
                      radius: CGFloat = 10) -> Path {
        WindowEdgeProgressShape(edge: edge, cornerRadius: radius, lineWidth: 1,
                                startShared: shared, endShared: shared).path(in: rect)
    }

    private func endpoints(_ path: Path) -> (start: CGPoint, end: CGPoint) {
        var start: CGPoint?
        var end = CGPoint.zero
        path.forEach { element in
            switch element {
            case .move(to: let point):
                if start == nil { start = point }
                end = point
            case .line(to: let point), .quadCurve(to: let point, control: _),
                 .curve(to: let point, control1: _, control2: _):
                end = point
            case .closeSubpath:
                break
            }
        }
        return (start ?? .zero, end)
    }

    private func matches(_ first: CGPoint, _ second: CGPoint) -> Bool {
        abs(first.x - second.x) < 0.01 && abs(first.y - second.y) < 0.01
    }

    @Test func adjacentEdgesMeetAtCornerMidpoints() {
        let top = endpoints(path(.top, shared: true))
        let bottom = endpoints(path(.bottom, shared: true))
        let left = endpoints(path(.left, shared: true))
        let right = endpoints(path(.right, shared: true))
        #expect(matches(top.start, left.start))
        #expect(matches(top.end, right.start))
        #expect(matches(bottom.start, left.end))
        #expect(matches(bottom.end, right.end))
        #expect(top.start.x > 0.5 && top.start.y > 0.5)
    }

    @Test func isolatedHorizontalEdgesWrapToTheSides() {
        let top = endpoints(path(.top, shared: false))
        let bottom = endpoints(path(.bottom, shared: false))
        #expect(top.start.x == 0.5)
        #expect(top.end.x == 599.5)
        #expect(top.start.y > 10)
        #expect(bottom.start.x == 0.5)
        #expect(bottom.end.x == 599.5)
        #expect(bottom.start.y < 390)
    }

    @Test func squareCornersUseTheFullEdge() {
        let top = endpoints(path(.top, shared: true, radius: 0))
        #expect(top.start == CGPoint(x: 0.5, y: 0.5))
        #expect(top.end == CGPoint(x: 599.5, y: 0.5))
        let left = endpoints(path(.left, shared: true, radius: 0))
        #expect(left.end == CGPoint(x: 0.5, y: 399.5))
    }

    @Test func partialProgressStartsOnTheCurveAndStaysInsideTheWindow() {
        for edge: WindowEdgeProgressShape.Edge in [.top, .bottom, .left, .right] {
            let full = path(edge, shared: false)
            let partial = full.trimmedPath(from: 0, to: 0.005)
            #expect(!partial.isEmpty)
            #expect(matches(endpoints(partial).start, endpoints(full).start))
            #expect(rect.contains(partial.boundingRect))
        }
    }
}
