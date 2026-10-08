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
                          : .easeInOut(duration: duration)
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
                            .transition(.opacity.combined(with: .scale(scale: 0.9))
                                .combined(with: .offset(y: -6)))
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
    static func slide(_ reduced: Bool) -> Animation? {
        reduced ? nil : .easeInOut(duration: 0.22)
    }
    static func settle(_ reduced: Bool) -> Animation? {
        reduced ? nil : .spring(response: 0.28, dampingFraction: 0.76)
    }
    static func feedback(_ reduced: Bool) -> Animation? {
        reduced ? nil : .easeInOut(duration: 0.12)
    }
    static var tabArrival: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading))
            .combined(with: .offset(y: -6))
    }
    static var panel: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.985))
            .combined(with: .offset(y: -6))
    }
}

/// Retain plain-button semantics with a small, consistent press response.
struct BrowserPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
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
