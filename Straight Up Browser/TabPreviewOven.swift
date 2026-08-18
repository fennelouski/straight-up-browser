//
//  TabPreviewOven.swift
//  Straight Up Browser
//
//  A tab you haven't opened has no web view, and a web view outside a window
//  has nothing to paint — which is why visual tabs used to launch as a wall of
//  favicons. The oven is an off-screen window that borrows one tab at a time,
//  lets it render, takes its card, and hands the web view back.
//

import WebKit

#if canImport(AppKit)
import AppKit

// macOS pulls stray windows back onto a screen unless the window says no.
final class OffscreenOvenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

extension WebViewManager {
    private static let ovenSize = NSSize(width: 1280, height: 800)
    // Launch shouldn't spin up fifty content processes. Tabs past the limit get
    // their card when you hover them (ContentView.hoverPreview).
    static let ovenLaunchLimit = 12

    /// Queue tabs for an off-screen capture, newest request first served last.
    /// Already-displayed tabs are snapshotted where they are instead.
    func warmThumbnails(for targets: [(id: UUID, url: URL?)]) {
        let fresh = targets.filter { target in
            target.id != ovenBaking && !ovenQueue.contains { $0.id == target.id }
        }
        guard !fresh.isEmpty else { return }
        ovenQueue.append(contentsOf: fresh)
        runOven()
    }

    private func runOven() {
        guard ovenBaking == nil, !ovenQueue.isEmpty else { return }
        let next = ovenQueue.removeFirst()
        ovenBaking = next.id
        Task { @MainActor [weak self] in
            await self?.bake(next.id, url: next.url)
            self?.ovenBaking = nil
            if self?.ovenQueue.isEmpty == false {
                self?.runOven()
            } else {
                self?.closeOven()
            }
        }
    }

    private func bake(_ tabId: UUID, url: URL?) async {
        let existing = existingWebView(for: tabId)

        // On screen already: nothing to borrow, just take the picture.
        if let existing, existing.window != nil, !existing.isHidden {
            captureThumbnail(for: tabId)
            return
        }
        // Nothing to show and nowhere to get it.
        guard existing != nil || url != nil else { return }

        let webView = existing ?? getWebView(for: tabId)
        // A web view the container is holding (a tab you visited earlier this
        // session) can be borrowed: WebViewContainer balances its delegates and
        // KVO in willRemoveSubview and re-attaches on the next selection.
        webView.removeFromSuperview()

        let host = ovenHost()
        webView.frame = NSRect(origin: .zero, size: Self.ovenSize)
        webView.isHidden = false
        host.addSubview(webView)

        if existing == nil, let url {
            webView.loadURL(url)
            try? await Task.sleep(for: .milliseconds(300))
            // Polled rather than delegated: the container owns the navigation
            // delegate, and a background bake must not write history or fire
            // agent signals. Ten seconds, then take whatever has painted.
            var waited = 0
            while webView.isLoading && waited < 40 {
                try? await Task.sleep(for: .milliseconds(250))
                waited += 1
            }
        }
        try? await Task.sleep(for: .milliseconds(500))   // first paint

        // The user may have selected this tab mid-bake, which moves the web view
        // back into the container. Leave it there if so.
        guard webView.superview === host else { return }
        captureThumbnail(for: tabId, afterScreenUpdates: false)
        try? await Task.sleep(for: .milliseconds(300))   // let the snapshot land
        guard webView.superview === host else { return }
        webView.isHidden = true
        webView.removeFromSuperview()
    }

    private func ovenHost() -> NSView {
        if let contentView = ovenWindow?.contentView { return contentView }
        let window = OffscreenOvenWindow(
            contentRect: NSRect(x: -30_000, y: -30_000,
                                width: Self.ovenSize.width, height: Self.ovenSize.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.orderFront(nil)   // it renders; it just isn't on any screen
        ovenWindow = window
        return window.contentView!
    }

    private func closeOven() {
        ovenWindow?.orderOut(nil)
        ovenWindow = nil
    }
}
#endif
