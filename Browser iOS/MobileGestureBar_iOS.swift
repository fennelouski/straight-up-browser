import SwiftUI

struct MobileGestureBar: View {
    @Binding var x: Double
    @Binding var y: Double
    @Binding var width: Double
    @Binding var editing: Bool
    let snapping: Bool
    let pageEdges: [Double]
    let activate: () -> Void
    let newTab: () -> Void
    let showTabs: () -> Void
    let showWorkspaces: () -> Void
    let nextTab: () -> Void
    let previousTab: () -> Void
    let swipe: (DragGesture.Value) -> Void
    @State private var dragOrigin: CGPoint?
    @State private var snapX: Double?
    @State private var snapY: Double?

    var body: some View {
        GeometryReader { geometry in
            let safe = geometry.safeAreaInsets
            let viewport = CGRect(x: safe.leading + 8, y: max(48, safe.top),
                                  width: max(1, geometry.size.width - safe.leading - safe.trailing - 16),
                                  height: max(1, geometry.size.height - max(48, safe.top) - safe.bottom - 8))
            let frame = MobileChromeLayout.frame(viewport: viewport, containerWidth: geometry.size.width, x: x, y: y, width: width)
            Capsule().fill(editing ? Color.accentColor : Color.secondary.opacity(0.6))
                .frame(width: frame.width, height: 5)
                .frame(width: frame.width, height: max(44, frame.height))
                .contentShape(Rectangle())
                .onTapGesture { if !editing { activate() } }
                .onLongPressGesture(minimumDuration: 0.4) { if !editing { newTab() } }
                .highPriorityGesture(DragGesture(minimumDistance: editing ? 0 : 20, coordinateSpace: .named("mobileGestureBarViewport"))
                    .onChanged { value in
                        guard editing else { return }
                        if dragOrigin == nil { dragOrigin = CGPoint(x: frame.midX, y: frame.midY) }
                        guard let origin = dragOrigin else { return }
                        var center = CGPoint(x: origin.x + value.translation.width, y: origin.y + value.translation.height)
                        if snapping {
                            snapX = MobileChromeLayout.snap(center.x, targets: [viewport.minX + frame.width / 2, viewport.midX, viewport.maxX - frame.width / 2], held: snapX)
                            snapY = MobileChromeLayout.snap(center.y, targets: [viewport.minY + 22, viewport.maxY - 22] + pageEdges.map { $0 - geometry.frame(in: .global).minY }, held: snapY)
                            center.x = snapX ?? center.x; center.y = snapY ?? center.y
                        }
                        let normalized = MobileChromeLayout.normalized(center: center, frame: frame, viewport: viewport)
                        x = normalized.x; y = normalized.y
                    }
                    .onEnded { value in
                        if !editing { swipe(value) }
                        dragOrigin = nil; snapX = nil; snapY = nil
                    })
                .accessibilityElement()
                .accessibilityLabel(editing ? "Move Gesture Bar" : "Browser Controls")
                .accessibilityHint("Activate for the address bar. Position and width controls are also in Settings.")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { activate() }
                .accessibilityAction(named: "New Tab", newTab)
                .accessibilityAction(named: "Show Tabs", showTabs)
                .accessibilityAction(named: "Workspaces", showWorkspaces)
                .accessibilityAction(named: "Next Tab", nextTab)
                .accessibilityAction(named: "Previous Tab", previousTab)
                .accessibilityAction(named: "Move Gesture Bar") { editing.toggle() }
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: if editing { y = min(1, y + 0.05) } else { nextTab() }
                    case .decrement: if editing { y = max(0, y - 0.05) } else { previousTab() }
                    @unknown default: break
                    }
                }
                .accessibilityIdentifier("browser.controls")
                .position(x: frame.midX, y: frame.midY)
            if editing {
                Button("Done Moving") { editing = false }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 52)
            }
        }
        .coordinateSpace(name: "mobileGestureBarViewport")
    }
}
