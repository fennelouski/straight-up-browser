import SwiftUI

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
