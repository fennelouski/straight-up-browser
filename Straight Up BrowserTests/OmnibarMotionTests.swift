import AppKit
import SwiftUI
import Testing
@testable import Browser

@MainActor
@Suite(.serialized)
struct OmnibarMotionTests {
    @Test func disablingMotionAndAccessibilityOverrideEitherCurve() {
        for spring in [false, true] {
            let off = OmnibarMotionPreferences(duration: 0, usesSpring: spring)
            #expect(off.animation(reducedMotion: false) == nil)
            let enabled = OmnibarMotionPreferences(duration: 0.22, usesSpring: spring)
            #expect(enabled.animation(reducedMotion: false) != nil)
            #expect(enabled.animation(reducedMotion: true) == nil)
        }
    }

    @Test func invalidSavedDurationsStayWithinTheSupportedRange() {
        #expect(OmnibarMotionPreferences(duration: -1, usesSpring: true).duration == 0)
        #expect(OmnibarMotionPreferences(duration: 100, usesSpring: false).duration == 1)
        for invalid in [Double.nan, .infinity, -.infinity] {
            #expect(OmnibarMotionPreferences(duration: invalid, usesSpring: true).duration
                    == OmnibarMotionPreferences.defaultDuration)
        }
    }

    @Test func openingAndRepeatedSummonsAcceptTypingDuringAnimation() async throws {
        let suite = "OmnibarMotionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let keys = [OmnibarMotionPreferences.durationKey, OmnibarMotionPreferences.springKey]
        defaults.set(1.0, forKey: keys[0])
        defaults.set(true, forKey: keys[1])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
            defaults.removePersistentDomain(forName: suite)
        }
        var text = ""
        let binding = Binding(get: { text }, set: { text = $0 })
        func presentation(_ shown: Bool) -> some View {
            OmnibarPresentation(isPresented: shown, topFraction: 0.25, onDismiss: {}) {
                OmnibarTextField(text: binding, placeholder: "Search", autoSelectAll: true,
                                shouldFocus: true)
                    .frame(width: 400, height: 40)
            }
            .defaultAppStorage(defaults)
        }
        let hosting = NSHostingView(rootView: presentation(false))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        hosting.rootView = presentation(true)
        // Give AppKit its mounting/focus turn, well before the one-second entrance ends.
        try await Task.sleep(for: .milliseconds(150))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("instant", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(text == "instant")
        // A rapid second summon reuses the native field, but must select its old entry.
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .browserFocusOmnibar, object: window)
        let refocused = try #require(window.firstResponder as? NSTextView)
        #expect(refocused.selectedRange() == NSRange(location: 0, length: 7))
        refocused.insertText("new", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(text == "new")
    }
}
