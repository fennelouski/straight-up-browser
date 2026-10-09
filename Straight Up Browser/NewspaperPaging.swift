import SwiftUI
#if os(macOS)
import AppKit
#endif

nonisolated enum NewspaperPageProjection {
    static func articlesPerPage(_ layout: NewspaperLayout) -> Int { layout.isEditorial ? 4 : 1 }
    static func pageCount(articleCount: Int, layout: NewspaperLayout) -> Int {
        let size = articlesPerPage(layout)
        return max(1, (max(0, articleCount) + size - 1) / size)
    }
}

struct NewspaperEdgeChevron: View {
    let direction: Int
    let nearby: Bool
    let disabled: Bool
    let action: () -> Void
    @State private var hovered = false
    @AccessibilityFocusState private var focused: Bool
    var body: some View {
        Button(action: action) {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 38, weight: .ultraLight))
                .frame(width: 48, height: 120).contentShape(Rectangle())
        }
        .buttonStyle(BrowserPressStyle()).disabled(disabled)
        .accessibilityLabel(direction < 0 ? "Previous" : "Next")
        .accessibilityFocused($focused)
        .help(direction < 0 ? "Previous newspaper page" : "Next newspaper page")
        .onHover { hovered = $0 }
        #if os(macOS)
        .opacity(disabled ? 0.05 : nearby || hovered || focused ? 0.85 : 0.12)
        #else
        .opacity(disabled ? 0.08 : 0.55)
        #endif
        .newspaperMotion(nearby || hovered || focused)
    }
}

/// Loose sheets bow, lift and rotate unevenly rather than hinging like a book.
struct NewspaperPageTurn: AnimatableModifier {
    var progress: CGFloat
    let direction: Int
    let variation: Int
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        let amount = min(1, max(0, progress))
        let sign = CGFloat(direction)
        content
            .clipShape(NewspaperSheetEdge(bend: amount * (0.045 + CGFloat(variation) * 0.012), direction: direction))
            .rotation3DEffect(.degrees(Double(sign * amount * (38 + CGFloat(variation) * 5))),
                axis: (x: 0.12, y: 1, z: 0.03), anchor: direction > 0 ? .leading : .trailing, perspective: 0.22)
            .rotationEffect(.degrees(Double(sign * amount * (2.5 + CGFloat(variation)))))
            .scaleEffect(x: 1 - amount * 0.08, y: 1 - amount * 0.025)
            .offset(x: -sign * amount * 110, y: -sin(amount * .pi) * (18 + CGFloat(variation) * 4))
            .opacity(1 - amount * 0.7)
    }
    static func transition(direction: Int, variation: Int) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Self(progress: 1, direction: -direction, variation: variation), identity: Self(progress: 0, direction: -direction, variation: variation)),
            removal: .modifier(active: Self(progress: 1, direction: direction, variation: variation), identity: Self(progress: 0, direction: direction, variation: variation)))
    }
}

private struct NewspaperSheetEdge: Shape {
    var bend: CGFloat
    let direction: Int
    var animatableData: CGFloat { get { bend } set { bend = newValue } }
    func path(in rect: CGRect) -> Path {
        let inset = rect.width * bend
        var path = Path()
        path.move(to: CGPoint(x: direction > 0 ? 0 : inset, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX - (direction > 0 ? inset : 0), y: rect.minY + inset * 0.15))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - inset * 0.35, y: rect.maxY),
            control: CGPoint(x: rect.maxX - inset * 1.8, y: rect.midY))
        path.addLine(to: CGPoint(x: inset * 0.25, y: rect.maxY - inset * 0.12))
        path.addQuadCurve(to: CGPoint(x: direction > 0 ? 0 : inset, y: 0),
            control: CGPoint(x: direction > 0 ? 0 : inset * 1.6, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

nonisolated struct NewspaperSwipeAccumulator {
    private var distance: CGFloat = 0
    private var turned = false
    mutating func reset() { distance = 0; turned = false }
    mutating func consume(x: CGFloat, y: CGFloat) -> Int? {
        guard !turned, abs(x) > abs(y) * 1.5 else { return nil }
        distance += x
        guard abs(distance) >= 70 else { return nil }
        turned = true
        return distance < 0 ? 1 : -1
    }
}

#if os(macOS)
struct NewspaperHorizontalPaging: NSViewRepresentable {
    let onTurn: (Int) -> Void
    func makeNSView(context: Context) -> PagingView { let view = PagingView(); view.onTurn = onTurn; return view }
    func updateNSView(_ view: PagingView, context: Context) { view.onTurn = onTurn }
    static func dismantleNSView(_ view: PagingView, coordinator: ()) { view.stopMonitoring() }
    final class PagingView: NSView {
        var onTurn: ((Int) -> Void)?
        private var monitor: Any?
        private var swipe = NewspaperSwipeAccumulator()
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, !self.isHiddenOrHasHiddenAncestor, let window = self.window, event.window === window,
                          self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return false }
                    if event.phase.contains(.began) { self.swipe.reset() }
                    guard event.momentumPhase.isEmpty else { return abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) }
                    if let direction = self.swipe.consume(x: event.scrollingDeltaX, y: event.scrollingDeltaY) { self.onTurn?(direction) }
                    if event.phase.contains(.ended) || event.phase.contains(.cancelled) { self.swipe.reset() }
                    return abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5
                }
                return consumed ? nil : event
            }
        }
        func stopMonitoring() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; swipe.reset() }
    }
}
#else
struct NewspaperHorizontalPaging: View {
    let onTurn: (Int) -> Void
    var body: some View { Color.clear.allowsHitTesting(false) }
}
#endif
