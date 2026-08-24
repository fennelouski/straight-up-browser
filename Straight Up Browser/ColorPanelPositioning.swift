//
//  ColorPanelPositioning.swift
//  Straight Up Browser
//
//  SwiftUI's ColorPicker opens the shared NSColorPanel wherever it last was on
//  screen, which can be far from the well the user just clicked. This snaps it
//  to sit right next to the mouse (i.e. the well) instead, trying right, below,
//  left, then above until one fits on screen.
//

import AppKit

enum ColorPanelPositioning {
    static func install() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            guard note.object is NSColorPanel else { return }
            let mouseLocation = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                position(NSColorPanel.shared, near: mouseLocation)
            }
        }
    }

    static func position(_ panel: NSColorPanel, near point: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        let gap: CGFloat = 4

        let candidates = [
            NSPoint(x: point.x + gap, y: point.y - size.height / 2),              // right
            NSPoint(x: point.x - size.width / 2, y: point.y - gap - size.height), // below
            NSPoint(x: point.x - gap - size.width, y: point.y - size.height / 2), // left
            NSPoint(x: point.x - size.width / 2, y: point.y + gap),               // above
        ]

        let origin = candidates.first { NSRect(origin: $0, size: size).within(visible) }
            ?? candidates[0].clamped(size: size, in: visible)
        panel.setFrameOrigin(origin)
    }
}

private extension NSRect {
    func within(_ frame: NSRect) -> Bool { frame.contains(self) }
}

private extension NSPoint {
    func clamped(size: NSSize, in frame: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(x, frame.minX), frame.maxX - size.width),
            y: min(max(y, frame.minY), frame.maxY - size.height)
        )
    }
}
