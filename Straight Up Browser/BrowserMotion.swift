import SwiftUI

/// Zero duration disables omnibar motion; system Reduce Motion takes precedence.
struct OmnibarMotionPreferences {
    static let durationKey = "omnibarAnimationDuration"
    static let springKey = "omnibarAnimationSpring"
    static let defaultDuration: TimeInterval = 0.22
    static let maximumDuration: TimeInterval = 1
    let duration: TimeInterval
    let usesSpring: Bool

    init(duration: TimeInterval, usesSpring: Bool) {
        self.duration = duration.isFinite
            ? min(Self.maximumDuration, max(0, duration)) : Self.defaultDuration
        self.usesSpring = usesSpring
    }

    func animation(reducedMotion: Bool) -> Animation? {
        guard !reducedMotion, duration > 0 else { return nil }
        return usesSpring ? .spring(duration: duration, bounce: 0.16)
                          : BrowserMotion.ease(duration: duration)
    }
}

/// Keep the presentation container alive so the field itself transitions in.
/// The field mounts and takes focus at insertion, never after an animation timer.
struct OmnibarPresentation<Content: View>: View {
    let isPresented: Bool
    let topFraction: Double
    let onDismiss: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            if isPresented {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onDismiss)
                    .transition(.opacity)
            }
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    Spacer().frame(height: geometry.size.height * topFraction)
                    if isPresented {
                        content()
                            .transition(BrowserMotion.omnibar)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .omnibarMotion(isPresented)
        .allowsHitTesting(isPresented)
        .accessibilityHidden(!isPresented)
    }
}

private struct OmnibarValueMotion<Value: Equatable>: ViewModifier {
    let value: Value
    @AppStorage(OmnibarMotionPreferences.durationKey)
    private var duration = OmnibarMotionPreferences.defaultDuration
    @AppStorage(OmnibarMotionPreferences.springKey) private var usesSpring = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(OmnibarMotionPreferences(duration: duration, usesSpring: usesSpring)
            .animation(reducedMotion: reduceMotion), value: value)
    }
}

/// A small vocabulary: slides ease, displaced content settles, feedback is quick.
enum BrowserMotion {
    static let windowDuration: TimeInterval = 0.35
    static func ease(duration: TimeInterval) -> Animation {
        .timingCurve(0.3, 0.05, 0.15, 1, duration: duration)
    }
    static func slide(_ reduced: Bool) -> Animation? {
        reduced ? nil : ease(duration: 0.22)
    }
    static func settle(_ reduced: Bool) -> Animation? {
        reduced ? nil : .spring(response: 0.28, dampingFraction: 0.76)
    }
    static func feedback(_ reduced: Bool) -> Animation? {
        reduced ? nil : ease(duration: 0.12)
    }
    static var tabArrival: AnyTransition {
        reveal(width: 0.06, height: 0.03, lift: -6, drift: 3, anchor: .topLeading)
    }
    static var panel: AnyTransition {
        reveal(width: 0.04, height: 0.02, lift: -6, drift: 2)
    }
    static var omnibar: AnyTransition {
        reveal(width: 0.07, height: 0.035, lift: -6, drift: 3)
    }
    static func panel(from edge: Edge) -> AnyTransition {
        .move(edge: edge).combined(with: panel)
    }
    private static func reveal(width: CGFloat, height: CGFloat, lift: CGFloat,
                               drift: CGFloat, anchor: UnitPoint = .center) -> AnyTransition {
        .opacity.combined(with: .modifier(
            active: BrowserOrganicReveal(progress: 1, width: width, height: height,
                                         lift: lift, drift: drift, anchor: anchor),
            identity: BrowserOrganicReveal(progress: 0, width: width, height: height,
                                           lift: lift, drift: drift, anchor: anchor)))
    }
}

/// A little cross-axis arc and unequal compression, with no clipping or layout
/// changes. Spring overshoot can settle naturally; the final transform is identity.
private struct BrowserOrganicReveal: AnimatableModifier {
    var progress: CGFloat
    let width: CGFloat
    let height: CGFloat
    let lift: CGFloat
    let drift: CGFloat
    let anchor: UnitPoint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let amount = reduceMotion ? 0 : progress
        content
            .scaleEffect(x: 1 - width * amount, y: 1 - height * amount, anchor: anchor)
            .offset(x: drift * sin(.pi * amount), y: lift * amount)
    }
}

/// Retain plain-button semantics with a small, consistent press response.
struct BrowserPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(x: configuration.isPressed && !reduceMotion ? 0.965 : 1,
                         y: configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(BrowserMotion.feedback(reduceMotion), value: configuration.isPressed)
    }
}

private struct BrowserValueMotion<Value: Equatable>: ViewModifier {
    enum Kind { case slide, settle, feedback }
    let value: Value
    let kind: Kind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let animation: Animation? = switch kind {
        case .slide: BrowserMotion.slide(reduceMotion)
        case .settle: BrowserMotion.settle(reduceMotion)
        case .feedback: BrowserMotion.feedback(reduceMotion)
        }
        content.animation(animation, value: value)
    }
}

extension View {
    func omnibarMotion<Value: Equatable>(_ value: Value) -> some View {
        modifier(OmnibarValueMotion(value: value))
    }
    func browserSlideMotion<Value: Equatable>(_ value: Value) -> some View {
        modifier(BrowserValueMotion(value: value, kind: .slide))
    }
    func browserSettleMotion<Value: Equatable>(_ value: Value) -> some View {
        modifier(BrowserValueMotion(value: value, kind: .settle))
    }
    func browserFeedbackMotion<Value: Equatable>(_ value: Value) -> some View {
        modifier(BrowserValueMotion(value: value, kind: .feedback))
    }
}
