import AppKit
import QuartzCore
import Testing
@testable import Browser

@MainActor
@Suite(.serialized)
struct BrowserMotionTests {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.orderFront(nil)
        return window
    }

    @Test func interruptedOpeningCannotEraseTheQuitCollapse() async throws {
        let window = makeWindow()
        defer { window.close() }
        let originalFrame = window.frame
        let motion = try #require(BrowserWindowMotion.install(on: window))
        motion.open(reducedMotion: false)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        motion.close(at: deadline, reducedMotion: false)
        try await Task.sleep(for: .seconds(0.6))
        let mask = try #require(window.contentView?.layer?.mask as? CAShapeLayer)
        #expect(try #require(mask.path).boundingBoxOfPath.width < 10)
        #expect(window.frame == originalFrame)
        #expect(window.isVisible)
        // A hold already completed must never start a second closing delay.
        #expect(motion.close(at: deadline + 2, reducedMotion: false) == 0)
        motion.restore(animated: false)
        #expect(window.contentView?.layer?.mask == nil)
        #expect(window.frame == originalFrame)
    }

    @Test func cancellationRestoresAnExistingMaskAndTheWindowFrame() throws {
        let window = makeWindow()
        defer { window.close() }
        let frame = window.frame
        let originalOpacity = window.isOpaque
        let originalBackground = window.backgroundColor
        let view = try #require(window.contentView)
        view.wantsLayer = true
        let originalMask = CAShapeLayer()
        originalMask.path = CGPath(rect: view.bounds, transform: nil)
        view.layer?.mask = originalMask
        let motion = try #require(BrowserWindowMotion.install(on: window))
        motion.close(at: ProcessInfo.processInfo.systemUptime + 1, reducedMotion: false)
        #expect(view.layer?.mask !== originalMask)
        #expect(!window.isOpaque)
        #expect(window.backgroundColor == .clear)
        motion.restore(animated: false)
        #expect(view.layer?.mask === originalMask)
        #expect(window.frame == frame)
        #expect(window.isOpaque == originalOpacity)
        #expect(window.backgroundColor == originalBackground)
    }

    @Test func reducedMotionDoesNotCollapseOrDelayTheWindow() throws {
        let window = makeWindow()
        defer { window.close() }
        let motion = try #require(BrowserWindowMotion.install(on: window))
        motion.open(reducedMotion: true)
        #expect(motion.close(at: ProcessInfo.processInfo.systemUptime + 2, reducedMotion: true) == 0)
        #expect(window.contentView?.layer?.mask == nil)
    }
}
