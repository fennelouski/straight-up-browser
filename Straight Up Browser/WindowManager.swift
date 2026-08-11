//
//  WindowManager.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import AppKit

// The single place window chrome is configured. Keeps .titled (removing it
// breaks dragging, focus routing, and fullscreen) and hides everything else.
//
// This resolves the window from the view hierarchy rather than guessing at
// NSApplication.keyWindow / .windows.first, which is what made the traffic
// lights show up on some installs and not others: at onAppear the browser
// window frequently isn't key yet, so the guess either configured a different
// scene's window (Settings, Downloads) or found nothing and bailed — and since
// it only ran once, the buttons stayed visible for the rest of the session.
// viewDidMoveToWindow fires exactly when this view has a real window, per
// window, so it can't race and it works for a second browser window too.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }

            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
            window.isMovableByWindowBackground = true
            window.backgroundColor = .windowBackgroundColor

            // SwiftUI restores the saved frame after this runs, so claim the
            // launch position on the next turn of the run loop or it's lost.
            DispatchQueue.main.async { WindowLayout.applyOnLaunch(to: window) }
        }
    }
}

// Where the browser window sits: full screen height, a width that's either the
// whole screen or a multiple of that height, slid anywhere from flush-left to
// flush-right. Everything is derived from the screen's visibleFrame, so the
// window never lands under the menu bar or off the edge.
enum WindowLayout {
    enum Key {
        static let launchEnabled = "launchLayoutEnabled"
        static let width = "launchLayoutWidth"
        static let position = "launchLayoutPosition"
        static let squareCorners = "squareWindowCorners"
    }

    // AppKit rounds every titled window's corners itself and exposes no API to
    // read the radius back, so this is the best available match for it — used
    // by any SwiftUI content that draws flush against the window edge (progress
    // bars, the tab sidebar) so it can curve/inset itself instead of being cut
    // off square by the real corner. ponytail: measured against macOS 15
    // Sequoia; if a future macOS changes the system radius, nudge this to match.
    static let windowCornerRadius: CGFloat = 10

    static var isSquareCorners: Bool {
        UserDefaults.standard.bool(forKey: Key.squareCorners)
    }

    // nil ratio = span the full screen width; otherwise width = height * ratio.
    static let widths: [(id: String, label: String, ratio: CGFloat?)] = [
        ("full", "Full width", nil),
        ("threeQuarters", "3/4 of the height", 0.75),
        ("twoThirds", "2/3 of the height", 2.0 / 3),
        ("half", "1/2 of the height", 0.5),
        ("third", "1/3 of the height", 1.0 / 3),
        ("quarter", "1/4 of the height", 0.25),
    ]

    // Fraction of the leftover space that goes to the window's left: 0 pins the
    // left edge, 1 pins the right edge, 0.5 centres it.
    static let positions: [(id: String, label: String, t: CGFloat)] = [
        ("left", "Left edge", 0),
        ("quarter", "1/4 across", 0.25),
        ("third", "1/3 across", 1.0 / 3),
        ("center", "Centered", 0.5),
        ("twoThirds", "2/3 across", 2.0 / 3),
        ("threeQuarters", "3/4 across", 0.75),
        ("right", "Right edge", 1),
    ]

    static func frame(in visible: NSRect, width widthID: String, position positionID: String) -> NSRect {
        let ratio = widths.first { $0.id == widthID }?.ratio ?? nil
        let w = ratio.map { min(visible.height * $0, visible.width) } ?? visible.width
        let t = positions.first { $0.id == positionID }?.t ?? 0.5
        return NSRect(x: visible.minX + (visible.width - w) * t,
                      y: visible.minY, width: w, height: visible.height)
    }

    private static func frame(for window: NSWindow) -> NSRect? {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return nil }
        let d = UserDefaults.standard
        return frame(in: visible,
                     width: d.string(forKey: Key.width) ?? "full",
                     position: d.string(forKey: Key.position) ?? "center")
    }

    // ponytail: once per app launch, not per window — a second ⌘N window
    // stacking exactly on the first is worse than letting it land normally.
    private static var didApplyOnLaunch = false

    static func applyOnLaunch(to window: NSWindow) {
        guard !didApplyOnLaunch,
              UserDefaults.standard.bool(forKey: Key.launchEnabled),
              let target = frame(for: window) else { return }
        didApplyOnLaunch = true
        window.setFrame(target, display: true)
    }

    private static var restoreFrames: [ObjectIdentifier: NSRect] = [:]

    /// ⇧⌘F: snap to the configured size/position, or back to where it was.
    static func toggle(_ window: NSWindow) {
        guard let target = frame(for: window) else { return }
        let id = ObjectIdentifier(window)
        if window.frame.equalTo(target, tolerance: 2) {
            // Launched straight into the layout, so there may be nothing to go
            // back to — a roomy centred window gives the keystroke an "off".
            let previous = restoreFrames.removeValue(forKey: id) ?? target.insetBy(
                dx: (target.width - min(target.width, 1200)) / 2,
                dy: target.height * 0.1
            )
            window.setFrame(previous, display: true, animate: true)
        } else {
            restoreFrames[id] = window.frame
            window.setFrame(target, display: true, animate: true)
        }
    }

    /// macOS rounds the corners of every titled window and offers no knob for
    /// it, so square corners mean dropping `.titled`. Two consequences, both
    /// load-bearing:
    ///
    /// * It has to happen before the window's first layout pass. Removing
    ///   `.titled` later swaps the theme frame out from under a laid-out
    ///   SwiftUI window and AppKit crashes in `_layoutSubtreeWithOldSize:` on
    ///   the next display cycle — hence "takes effect on the next launch"
    ///   rather than a live toggle.
    /// * A window without a title bar won't become key, so clicking away would
    ///   leave the page permanently untypable. `canBecomeKey` can only be
    ///   answered by the class, and this is SwiftUI's own window class, so
    ///   patch the method on it. Every other window of that class is titled and
    ///   already answers true, so nothing else changes.
    ///
    /// Full screen goes with the title bar too, which is why ⇧⌘F snaps the
    /// window to a size instead of going full screen.
    static func applyCornersAtLaunch(to window: NSWindow) {
        guard UserDefaults.standard.bool(forKey: Key.squareCorners),
              window.styleMask.contains(.titled) else { return }

        if let cls: AnyClass = object_getClass(window) {
            let alwaysTrue: @convention(block) (AnyObject) -> Bool = { _ in true }
            let imp = imp_implementationWithBlock(alwaysTrue)
            class_replaceMethod(cls, #selector(getter: NSWindow.canBecomeKey), imp, "B@:")
            class_replaceMethod(cls, #selector(getter: NSWindow.canBecomeMain), imp, "B@:")
        }
        window.styleMask.remove(.titled)
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
    }
}

private extension NSRect {
    func equalTo(_ other: NSRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) < tolerance && abs(minY - other.minY) < tolerance
            && abs(width - other.width) < tolerance && abs(height - other.height) < tolerance
    }
}
