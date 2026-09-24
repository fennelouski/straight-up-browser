//
//  WindowManager.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import SwiftUI
import AppKit

// The browser scene creates a native plain window. This bridge configures its
// dragging, corners, and saved launch placement without replacing AppKit's frame.
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
        // Read only from deinit (nonisolated by default even on a MainActor
        // class), so Swift 6 needs the escape hatch to hand it a non-Sendable
        // NSObjectProtocol token there — otherwise every write stays MainActor.
        nonisolated(unsafe) private var defaultsObserver: NSObjectProtocol?
        nonisolated(unsafe) private var resizeObserver: NSObjectProtocol?
        nonisolated(unsafe) private var moveObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }

            // AppKit's plain window cannot receive text input by default.
            // Keep SwiftUI's window and frame, but allow it to become key/main.
            if !window.canBecomeKey, let cls = object_getClass(window) {
                let canActivate: @convention(block) (AnyObject) -> Bool = { _ in true }
                let implementation = imp_implementationWithBlock(canActivate)
                class_replaceMethod(cls, #selector(getter: NSWindow.canBecomeKey), implementation, "B@:")
                class_replaceMethod(cls, #selector(getter: NSWindow.canBecomeMain), implementation, "B@:")
            }
            window.isMovableByWindowBackground = true
            window.styleMask.formUnion([.resizable, .fullSizeContentView])
            window.setAccessibilitySubrole(.standardWindow)
            WindowLayout.applyCornerMask(to: window)

            // Square Corners takes effect immediately while the window is open,
            // so keep the real silhouette in sync with the setting, not just
            // whatever it was at launch.
            if defaultsObserver == nil {
                defaultsObserver = NotificationCenter.default.addMainActorObserver(
                    forName: UserDefaults.didChangeNotification, object: nil, queue: .main
                ) { [weak window] _ in
                    guard let window else { return }
                    WindowLayout.applyCornerMask(to: window)
                }
            }
            // A non-opaque window's shadow is traced from its actually-drawn
            // pixels, and AppKit doesn't always re-trace it on its own mid-drag.
            // Doubles as the frame-save hook — see WindowLayout.restoreFrame.
            if resizeObserver == nil {
                resizeObserver = NotificationCenter.default.addMainActorObserver(
                    forName: NSWindow.didResizeNotification, object: window, queue: .main
                ) { [weak window] _ in
                    window?.invalidateShadow()
                    if let window { WindowLayout.saveFrame(window) }
                }
            }
            if moveObserver == nil {
                moveObserver = NotificationCenter.default.addMainActorObserver(
                    forName: NSWindow.didMoveNotification, object: window, queue: .main
                ) { [weak window] _ in
                    if let window { WindowLayout.saveFrame(window) }
                }
            }

            // SwiftUI restores the saved frame after this runs, so claim the
            // launch position on the next turn of the run loop or it's lost.
            //
            // Do NOT touch window.frameAutosaveName here. SwiftUI's WindowGroup
            // owns the frame: it saves under "NSWindow Frame browser-AppWindow-1"
            // and its restore only lands if the window still carries that
            // autosave name. Renaming it to a custom name left saving intact but
            // silently killed restoring, so every launch fell back to
            // .defaultSize — measured 2026-09-24: saved 960x1050, restored
            // 1200x800.
            DispatchQueue.main.async {
                // SwiftUI's plain style also clears resizing during setup.
                window.styleMask.insert(.resizable)
                WindowLayout.restoreFrame(window)
                WindowLayout.applyOnLaunch(to: window)
                window.makeKeyAndOrderFront(nil)
            }
        }

        deinit {
            if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
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

    // Remembering where the user left the window.
    //
    // This is done by hand rather than with NSWindow's frame autosave because
    // neither mechanism available here actually works on this window:
    // setFrameAutosaveName("…") reports success and then persists nothing (no
    // such key is ever written), and SwiftUI's own WindowGroup persistence
    // saves the frame correctly but restores only the origin — .defaultSize
    // wins over the saved size on every launch. Measured 2026-09-24: saved
    // 960x1050, restored 1200x800. Saving explicitly on move/resize and
    // re-applying after SwiftUI has finished laying out is the one path that
    // survives both.
    private static let frameKey = "browserWindowFrame"

    static func saveFrame(_ window: NSWindow) {
        // Full screen / miniaturised frames aren't where the user "left" it.
        guard !window.isMiniaturized, !window.styleMask.contains(.fullScreen) else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: frameKey)
    }

    static func restoreFrame(_ window: NSWindow) {
        guard let saved = UserDefaults.standard.string(forKey: frameKey) else { return }
        let rect = NSRectFromString(saved)
        guard rect.width > 0, rect.height > 0 else { return }
        // The frame may come from a machine or display that no longer exists
        // (this store syncs across Macs), so clamp it back onto a real screen
        // instead of opening a window that is offscreen or larger than the
        // display. ponytail: clamps to whichever screen it most overlaps.
        let screen = NSScreen.screens.max { a, b in
            a.visibleFrame.intersection(rect).area < b.visibleFrame.intersection(rect).area
        } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        window.setFrame(clamped(rect, into: visible), display: true)
    }

    /// Shrinks `rect` to fit `visible` and slides it back inside that screen,
    /// keeping the size the user chose wherever it still fits.
    static func clamped(_ rect: NSRect, into visible: NSRect) -> NSRect {
        var target = rect
        target.size.width = min(target.width, visible.width)
        target.size.height = min(target.height, visible.height)
        target.origin.x = min(max(target.minX, visible.minX), visible.maxX - target.width)
        target.origin.y = min(max(target.minY, visible.minY), visible.maxY - target.height)
        return target
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

    /// ⇧⌘F: snap to the configured size/position, or back to where it was —
    /// "where it was" meaning before *any* snap command (this or an arrow
    /// key below) touched the window, not just the last one. Only captures
    /// restoreFrames when it's empty, so a run of arrow-key snaps followed by
    /// ⇧⌘F still remembers the original freeform frame.
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
            snapState.removeValue(forKey: id)
            window.setFrame(previous, display: true, animate: true)
        } else {
            if restoreFrames[id] == nil { restoreFrames[id] = window.frame }
            snapState.removeValue(forKey: id)
            window.setFrame(target, display: true, animate: true)
        }
    }

    // ⌘⌥⌃←/→/↑/↓: snap to a half of the screen at that edge. Left/right keep
    // the full height, top/bottom keep the full width. Pressing the same
    // arrow again cycles to the next ratio below at the same edge, so the
    // four keys reach a dozen spots without touching the mouse.
    enum SnapDirection: Equatable { case left, right, top, bottom }

    static let snapRatios: [CGFloat] = [0.5, 1.0 / 3, 2.0 / 3]

    static func snapFrame(in visible: NSRect, direction: SnapDirection, ratio: CGFloat) -> NSRect {
        switch direction {
        case .left:
            let w = visible.width * ratio
            return NSRect(x: visible.minX, y: visible.minY, width: w, height: visible.height)
        case .right:
            let w = visible.width * ratio
            return NSRect(x: visible.maxX - w, y: visible.minY, width: w, height: visible.height)
        case .top:
            let h = visible.height * ratio
            return NSRect(x: visible.minX, y: visible.maxY - h, width: visible.width, height: h)
        case .bottom:
            let h = visible.height * ratio
            return NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: h)
        }
    }

    private static var snapState: [ObjectIdentifier: (direction: SnapDirection, step: Int)] = [:]

    static func snap(_ window: NSWindow, direction: SnapDirection) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let id = ObjectIdentifier(window)
        // Advance to the next ratio only if the window is still exactly where
        // the last press of this same arrow put it — moved or resized by hand
        // since, or a different edge, restarts the cycle at half.
        var step = 0
        if let state = snapState[id], state.direction == direction,
           window.frame.equalTo(snapFrame(in: visible, direction: direction, ratio: snapRatios[state.step]), tolerance: 2) {
            step = (state.step + 1) % snapRatios.count
        }
        if restoreFrames[id] == nil { restoreFrames[id] = window.frame }
        snapState[id] = (direction, step)
        window.setFrame(snapFrame(in: visible, direction: direction, ratio: snapRatios[step]), display: true, animate: true)
    }

    /// Plain windows need an explicit corner mask and a transparent background
    /// so AppKit traces the shadow around the drawn content. Never replace a
    /// titled window's theme frame during layout: AppKit still holds its views.
    static func applyCornerMask(to window: NSWindow) {
        let square = isSquareCorners
        window.isOpaque = square
        window.backgroundColor = square ? .windowBackgroundColor : .clear
        let contentView = window.contentView
        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = square ? 0 : windowCornerRadius
        contentView?.layer?.masksToBounds = !square
        contentView?.layer?.cornerCurve = .continuous
        window.invalidateShadow()
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }

    func equalTo(_ other: NSRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) < tolerance && abs(minY - other.minY) < tolerance
            && abs(width - other.width) < tolerance && abs(height - other.height) < tolerance
    }
}
