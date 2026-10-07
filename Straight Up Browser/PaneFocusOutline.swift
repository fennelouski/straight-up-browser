#if os(macOS)
import AppKit
import SwiftUI

/// Only a corner at the intersection of two outer window edges is rounded.
/// Frames are in AppKit window coordinates (origin at the bottom left).
struct PaneBorderCorners: Equatable {
    var topLeft: CGFloat = 0
    var topRight: CGFloat = 0
    var bottomLeft: CGFloat = 0
    var bottomRight: CGFloat = 0

    static func matching(pane: CGRect, window: CGRect, radius: CGFloat) -> Self {
        guard radius > 0, !pane.isEmpty, !window.isEmpty else { return Self() }
        // Allow subpixel rounding when SwiftUI and AppKit convert coordinates.
        let tolerance: CGFloat = 0.5
        let left = abs(pane.minX - window.minX) <= tolerance
        let right = abs(pane.maxX - window.maxX) <= tolerance
        let top = abs(pane.maxY - window.maxY) <= tolerance
        let bottom = abs(pane.minY - window.minY) <= tolerance
        return Self(topLeft: top && left ? radius : 0,
                    topRight: top && right ? radius : 0,
                    bottomLeft: bottom && left ? radius : 0,
                    bottomRight: bottom && right ? radius : 0)
    }

    func path(in bounds: CGRect, lineWidth: CGFloat) -> Path {
        let inset = lineWidth / 2
        guard bounds.width > lineWidth, bounds.height > lineWidth else { return Path() }
        let path = UnevenRoundedRectangle(
            topLeadingRadius: max(0, topLeft - inset),
            bottomLeadingRadius: max(0, bottomLeft - inset),
            bottomTrailingRadius: max(0, bottomRight - inset),
            topTrailingRadius: max(0, topRight - inset),
            style: .continuous
        ).path(in: bounds.insetBy(dx: inset, dy: inset))
        // SwiftUI names corners in top-down coordinates; AppKit draws bottom-up.
        return path.applying(CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                              tx: 0, ty: bounds.minY + bounds.maxY))
    }
}

/// The existing focus overlay stays inside the pane and passes clicks through.
/// Resolve its real window position when drawing, so divider layouts, developer
/// tools, and other chrome don't need their own lists of rounded corners.
final class PaneFocusOutline: NSView {
    private var defaultsObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        defaultsObserver = NotificationCenter.default.addMainActorObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }

    var borderCorners: PaneBorderCorners {
        guard let contentView = window?.contentView else { return PaneBorderCorners() }
        return PaneBorderCorners.matching(
            pane: convert(bounds, to: nil),
            window: contentView.convert(contentView.bounds, to: nil),
            radius: WindowLayout.isSquareCorners ? 0 : WindowLayout.windowCornerRadius
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(borderCorners.path(in: bounds, lineWidth: 2).cgPath)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(2)
        context.strokePath()
    }
}
#endif
