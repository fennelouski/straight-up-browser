//
//  DefaultBrowser.swift
//  Straight Up Browser
//
//  Detecting and requesting default-browser status. Registration lives in
//  Info.plist (CFBundleURLTypes for http/https); incoming links arrive at
//  AppDelegate.application(_:open:).
//

#if os(macOS)
import AppKit
import SwiftUI

enum DefaultBrowser {
    private static let dismissedKey = "defaultBrowserPromptDismissed"
    // Any http URL resolves through the same LaunchServices handler.
    private static let probe = URL(string: "https://example.com")!

    static var isDefault: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: probe)?.standardizedFileURL
            == Bundle.main.bundleURL.standardizedFileURL
    }

    // Show the prompt only until the user acts on it once, either way — and
    // never when they've switched it off in Settings → General.
    static var shouldOffer: Bool {
        let enabled = UserDefaults.standard.object(forKey: promptEnabledKey) as? Bool ?? true
        return enabled && !UserDefaults.standard.bool(forKey: dismissedKey) && !isDefault
    }

    // Settings → General. Turning it back on re-arms a prompt already dismissed,
    // otherwise the switch would look broken for anyone who'd clicked the ✕.
    static let promptEnabledKey = "defaultBrowserPromptEnabled"

    static func setPromptEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: promptEnabledKey)
        if enabled { UserDefaults.standard.removeObject(forKey: dismissedKey) }
    }

    static func dismiss() {
        UserDefaults.standard.set(true, forKey: dismissedKey)
    }

    // macOS puts up its own confirmation sheet; we only ask.
    static func makeDefault() async {
        for scheme in ["http", "https"] {
            try? await NSWorkspace.shared.setDefaultApplication(
                at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
        }
        dismiss()
    }
}

// Bottom-corner nudge shown after a new tab, until the user picks either button.
struct DefaultBrowserPrompt: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Make Browser your default?")
                    .font(.subheadline.weight(.semibold))
                Text("Links from other apps will open here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Set Default") {
                Task {
                    await DefaultBrowser.makeDefault()
                    onDismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            Button {
                DefaultBrowser.dismiss()
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 10)
        .padding(20)
    }
}
#endif
