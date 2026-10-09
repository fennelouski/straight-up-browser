#if os(macOS)
import SwiftUI

enum OnboardingAstronautPose: String {
    case welcome = "OnboardingAstronautWelcome"
    case pointing = "OnboardingAstronautPoint"
    case celebrating = "OnboardingAstronautCelebrate"
    case curious = "OnboardingAstronautCurious"
    case explaining = "OnboardingAstronautExplain"
    case floating = "OnboardingAstronautFloat"

    static func forLesson(_ step: OnboardingStep?) -> Self {
        switch step {
        case nil: .welcome
        case .finished: .celebrating
        case .interests, .memory, .ai, .automation: .curious
        case .workspaces, .sources, .documents, .translation, .newspaper: .explaining
        case .navigation, .windows, .splits: .floating
        default: .pointing
        }
    }
}

/// Idle motion stays in this small subtree; it never invalidates the browser.
struct OnboardingAstronaut: View {
    var pose: OnboardingAstronautPose = .welcome
    var moves: Bool
    var spring: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var portrait: some View {
        Image(pose.rawValue).resizable().scaledToFit().accessibilityHidden(true)
            .id(pose).transition(.opacity)
    }
    var body: some View {
        Group {
            if moves && !reduceMotion {
                portrait.phaseAnimator([false, true]) { image, up in
                    image.offset(x: up ? 1.5 : -1.5, y: up ? -4 : 2).rotationEffect(.degrees(up ? 2 : -2))
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
    @State private var enginesOn = false
    private var motionEnabled: Bool { moves && !reduceMotion }
    private struct Flight: Equatable {
        let destination: CGPoint
        let angle: Double
        let enabled: Bool
    }
    private var ship: some View {
        ZStack {
            Image("OnboardingShuttleOff").resizable().scaledToFit()
            Image("OnboardingShuttle").resizable().scaledToFit()
                .opacity(enginesOn && motionEnabled ? 1 : 0)
        }
        .frame(width: 70, height: 86)
        .background(alignment: .top) {
            if enginesOn && motionEnabled {
                OnboardingExhaust().frame(width: 70, height: 110)
                    .transition(.opacity)
            }
        }
        .animation(motionEnabled ? .easeInOut(duration: 0.12) : nil, value: enginesOn)
    }
    var body: some View {
        Group {
            if motionEnabled {
                ship.phaseAnimator([false, true]) { image, up in
                    image.offset(x: up ? 2 : -2, y: up ? -5 : 3).rotationEffect(.degrees(up ? 3 : -3))
                        .scaleEffect(x: up ? 1.02 : 0.99, y: up ? 0.99 : 1.015)
                } animation: { _ in
                    spring ? .spring(duration: 2.4, bounce: 0.1) : .easeInOut(duration: 2.4)
                }
            } else { ship }
        }
        .rotationEffect(.degrees(angle))
        .animation(moves && !reduceMotion ? .easeInOut(duration: 0.5) : nil, value: angle)
        .position(destination)
        .animation(moves && !reduceMotion ? .easeInOut(duration: 0.7) : nil, value: destination)
        .task(id: Flight(destination: destination, angle: angle, enabled: motionEnabled)) {
            enginesOn = motionEnabled
            guard motionEnabled else { return }
            // Matches the flight animation. A new target cancels the old shutdown.
            do { try await Task.sleep(for: .milliseconds(700)) }
            catch { return }
            guard !Task.isCancelled else { return }
            enginesOn = false
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Only exists during a flight: twelve dots at 30 fps in a 70 × 110 canvas.
/// No particle objects, browser state changes, or full-window drawing.
private struct OnboardingExhaust: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, _ in
                let time = timeline.date.timeIntervalSinceReferenceDate
                for engine in 0..<2 {
                    let nozzleX: CGFloat = engine == 0 ? 27 : 44
                    for dot in 0..<6 {
                        let age = (time / 0.48 + Double(dot) / 6).truncatingRemainder(dividingBy: 1)
                        let spread = sin(Double(dot) * 2.4 + Double(engine)) * age * 3
                        let radius = CGFloat(1.5 - age)
                        let center = CGPoint(x: nozzleX + spread, y: 75 + age * 19)
                        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                                          width: radius * 2, height: radius * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(.cyan.opacity((1 - age) * 0.55)))
                    }
                }
            }
        }
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
