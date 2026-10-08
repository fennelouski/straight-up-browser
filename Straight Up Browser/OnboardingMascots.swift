#if os(macOS)
import SwiftUI

/// Idle motion stays in this small subtree; it never invalidates the browser.
struct OnboardingAstronaut: View {
    var pose: String = "OnboardingAstronautWelcome"
    var moves: Bool
    var spring: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var portrait: some View {
        Image(pose).resizable().scaledToFit().accessibilityHidden(true)
            .id(pose).transition(.opacity)
    }
    var body: some View {
        Group {
            if moves && !reduceMotion {
                portrait.phaseAnimator([false, true]) { image, up in
                    image.offset(y: up ? -4 : 2).rotationEffect(.degrees(up ? 2 : -2))
                } animation: { _ in
                    spring ? .spring(duration: 2.6, bounce: 0.08) : .easeInOut(duration: 2.6)
                }
            } else { portrait }
        }
        .animation(moves && !reduceMotion ? .easeInOut(duration: 0.25) : nil, value: pose)
    }
}

struct OnboardingShuttle: View {
    let destination: CGPoint
    let angle: Double
    let moves: Bool
    let spring: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var ship: some View {
        Image("OnboardingShuttle").resizable().scaledToFit().frame(width: 70, height: 86)
    }
    var body: some View {
        Group {
            if moves && !reduceMotion {
                ship.phaseAnimator([false, true]) { image, up in
                    image.offset(y: up ? -5 : 3).rotationEffect(.degrees(up ? 3 : -3))
                        .scaleEffect(up && spring ? 1.025 : 1)
                } animation: { _ in
                    spring ? .spring(duration: 2.4, bounce: 0.1) : .easeInOut(duration: 2.4)
                }
            } else { ship }
        }
        .rotationEffect(.degrees(angle))
        .animation(moves && !reduceMotion ? .easeInOut(duration: 0.5) : nil, value: angle)
        .position(destination)
        .animation(moves && !reduceMotion ? .easeInOut(duration: 0.7) : nil, value: destination)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SpotlightShape: Shape {
    var focus: CGRect
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(focus.origin.x, focus.origin.y), .init(focus.width, focus.height)) }
        set { focus = CGRect(x: newValue.first.first, y: newValue.first.second,
                             width: newValue.second.first, height: newValue.second.second) }
    }
    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        p.addRoundedRect(in: focus.insetBy(dx: -7, dy: -7), cornerSize: CGSize(width: 12, height: 12))
        return p
    }
}

struct OnboardingSpotlight: View {
    let focus: CGRect
    let moves: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            SpotlightShape(focus: focus).fill(.black.opacity(0.22), style: FillStyle(eoFill: true))
            RoundedRectangle(cornerRadius: 12)
                .stroke(.cyan.opacity(0.7), lineWidth: 2)
                .frame(width: focus.width + 14, height: focus.height + 14)
                .position(x: focus.midX, y: focus.midY)
        }
        .animation(moves && !reduceMotion ? .easeInOut(duration: 0.55) : nil, value: focus)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
