import SwiftUI

/// A compact macOS help bubble that waits long enough to avoid flashing while
/// the pointer is merely crossing chrome. Use this in place of `.help` for
/// buttons and controls whose purpose is not already written beside them.
private struct DelayedHelpModifier: ViewModifier {
    let text: String
    let delay: Duration

    @State private var isHovering = false
    @State private var isPresented = false
    @State private var presentationTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onHover { hovering in
                isHovering = hovering
                presentationTask?.cancel()
                if hovering {
                    presentationTask = Task { @MainActor in
                        try? await Task.sleep(for: delay)
                        guard !Task.isCancelled, isHovering else { return }
                        isPresented = true
                    }
                } else {
                    isPresented = false
                }
            }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .fixedSize()
                    .allowsHitTesting(false)
            }
            .onDisappear {
                presentationTask?.cancel()
                presentationTask = nil
                isPresented = false
            }
        #else
        content.help(text)
        #endif
    }
}

extension View {
    func delayedHelp(_ text: String, delay: Duration = .seconds(2)) -> some View {
        modifier(DelayedHelpModifier(text: text, delay: delay))
    }
}
