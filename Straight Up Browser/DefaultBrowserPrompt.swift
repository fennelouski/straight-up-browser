#if os(macOS)
import AppKit
import SwiftUI

struct DefaultBrowserPrompt: View {
    private static let appIcon = NSImage(named: "AppIcon")
        ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    let onDismiss: () -> Void
    var offersNever = DefaultBrowserEngagement.shared.offersNever
    var isDemo = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var pointer: CGPoint?
    @State private var closeHovered = false
    @State private var settingDefault = false
    @State private var failed = false
    @State private var cardSize = CGSize(width: 390, height: 200)
    @FocusState private var closeFocused: Bool

    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.82) }
    private var ink: Color { colorScheme == .dark ? Color(red: 0.91, green: 0.94, blue: 1) : Color(red: 0.12, green: 0.18, blue: 0.29) }

    private var closeProximity: Double {
        if closeHovered || closeFocused || reduceMotion { return 1 }
        guard let pointer else { return 0 }
        let center = CGPoint(x: cardSize.width - 30, y: 30)
        let distance = hypot(pointer.x - center.x, pointer.y - center.y)
        let progress = min(1, max(0, (100 - distance) / 64))
        return progress * progress * (3 - 2 * progress)
    }

    private var headerLayout: AnyLayout {
        cardSize.width < 330
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            headerLayout {
                Image(nsImage: Self.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 62, height: 62)
                    .rotationEffect(.degrees(reduceMotion ? 0 : (pointer == nil ? 0 : -3)))
                    .offset(y: reduceMotion || pointer == nil ? 0 : -2)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 5)
                    .animation(motion, value: pointer != nil)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Make Browser\nyour default?")
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                        .tracking(-0.5)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Links from other apps will open here.")
                        .font(.system(size: 13))
                        .foregroundStyle(ink.opacity(0.76))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.trailing, cardSize.width < 330 ? 0 : 22)
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                if offersNever {
                    Button("Never") {
                        if !isDemo { DefaultBrowserEngagement.shared.never() }
                        onDismiss()
                    }
                    .buttonStyle(DefaultBrowserSecondaryStyle(ink: ink, reduceMotion: reduceMotion))
                    .disabled(settingDefault)
                    .help("Never show this prompt again")
                }
                Spacer(minLength: 0)
                Button {
                    guard !settingDefault else { return }
                    if isDemo { onDismiss(); return }
                    settingDefault = true
                    Task { @MainActor in
                        let result = await DefaultBrowser.makeDefault()
                        settingDefault = false
                        switch result {
                        case .succeeded, .notChanged: onDismiss()
                        case .failed: failed = true
                        }
                    }
                } label: {
                    HStack(spacing: 9) {
                        Text(settingDefault ? "Setting default…" : "Set Default")
                        if settingDefault {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 18)
                    .frame(height: 38)
                }
                .buttonStyle(DefaultBrowserActionStyle(reduceMotion: reduceMotion))
                .disabled(settingDefault)
            }
            if failed {
                VStack(alignment: .leading, spacing: 8) {
                    Text("macOS couldn’t change your default browser.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") {
                        guard let settings = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else { return }
                        NSWorkspace.shared.open(settings)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ink)
                    .underline()
                    .help("Choose Browser as your default web browser in System Settings")
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .foregroundStyle(ink)
        .padding(24)
        .frame(maxWidth: 390)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geometry in
                let restingPoint = CGPoint(x: geometry.size.width * 0.15, y: 0)
                let location = reduceMotion ? restingPoint : pointer ?? restingPoint
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(colorScheme == .dark ? Color(red: 0.13, green: 0.17, blue: 0.23) : Color(red: 0.95, green: 0.97, blue: 1))
                    .overlay {
                        RadialGradient(colors: [Color.accentColor.opacity(pointer == nil ? 0.08 : 0.17), .clear],
                                       center: UnitPoint(x: location.x / geometry.size.width, y: location.y / geometry.size.height),
                                       startRadius: 0, endRadius: 250)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: pointer)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
        .overlay(alignment: .topTrailing) {
            closeButton
                .padding(8)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.16), radius: 22, y: 10)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: failed)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): pointer = point
            case .ended: pointer = nil
            }
        }
        .onExitCommand {
            if !settingDefault { dismissForNow() }
        }
        .padding(20)
    }

    private func dismissForNow() {
        if !isDemo { DefaultBrowserEngagement.shared.dismiss() }
        onDismiss()
    }

    private var closeButton: some View {
        // Stable 44-point target, even while the visible control rests small.
        // The surrounding approach zone begins growing before the pointer hits X.
        let proximity = closeProximity
        return Button(action: dismissForNow) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ink.opacity(0.65 + 0.25 * proximity))
                .frame(width: 30, height: 30)
                .background(ink.opacity(0.09 * proximity), in: Circle())
                .scaleEffect(0.65 + 0.35 * proximity)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($closeFocused)
        .onHover { closeHovered = $0 }
        .animation(motion, value: proximity)
        .accessibilityLabel("Dismiss Default Browser Prompt")
        .accessibilityHint("Remind me on a later launch")
        .help("Dismiss for now")
        .disabled(settingDefault)
    }
}

private struct DefaultBrowserActionStyle: ButtonStyle {
    let reduceMotion: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: 0.12, green: 0.34, blue: 0.86).gradient)
                    .brightness(hovered && isEnabled ? 0.045 : 0)
            }
            .shadow(color: .black.opacity(hovered ? 0.18 : 0.1), radius: hovered ? 8 : 4, y: hovered ? 4 : 2)
            .scaleEffect(reduceMotion || !isEnabled ? 1 : configuration.isPressed ? 0.97 : hovered ? 1.025 : 1)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.8), value: hovered)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.8), value: configuration.isPressed)
    }
}
private struct DefaultBrowserSecondaryStyle: ButtonStyle {
    let ink: Color
    let reduceMotion: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(ink.opacity(isEnabled ? 0.85 : 0.4))
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(ink.opacity(hovered && isEnabled ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
    }
}

#Preview("First invitation") {
    DefaultBrowserPrompt(onDismiss: {}, offersNever: false, isDemo: true)
        .padding(30)
}

#Preview("With Never") {
    DefaultBrowserPrompt(onDismiss: {}, offersNever: true, isDemo: true)
        .preferredColorScheme(.dark)
        .padding(30)
}
#endif
