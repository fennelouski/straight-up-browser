import Testing
import WebKit
@testable import Browser

@MainActor
struct WebViewContainerKVOTests {
    // WebKit's element-fullscreen controller pulls the web view out of our
    // container and puts it back on exit, bypassing attach(). Before the fix the
    // second exit removed a KVO observer that was never re-registered, which
    // raised an NSException and killed the app (youtube -> fullscreen -> Escape
    // -> fullscreen).
    @Test func survivesRepeatedReparenting() {
        let container = WebViewContainer(webViewManager: nil, coordinator: nil)
        let webView = WKWebView()
        for _ in 0..<3 {
            container.addSubview(webView)      // WebKit hands it back
            webView.removeFromSuperview()      // WebKit takes it for fullscreen
        }
        #expect(webView.superview == nil)
    }

    // Entering element full screen moves the pane into WebKit's own full-screen
    // window. The container must not size a pane it no longer holds, and must
    // re-lay it out when WebKit hands it back.
    @Test func aPaneBorrowedForFullScreenIsLeftAloneAndReLaidOutOnReturn() async {
        let manager = WebViewManager()
        let container = WebViewContainer(webViewManager: manager, coordinator: nil)
        container.setFrameSize(NSSize(width: 800, height: 600))
        let tab = UUID()
        container.setDisplayedTabs([tab], focusedTabId: tab)
        try? await Task.sleep(for: .milliseconds(50))
        let webView = try! #require(manager.existingWebView(for: tab))
        #expect(webView.frame == container.bounds)

        // WebKit's full-screen window takes the pane.
        let borrower = NSView(frame: NSRect(x: 0, y: 0, width: 1710, height: 1112))
        borrower.addSubview(webView)
        let fullScreenFrame = NSRect(x: 0, y: 0, width: 1710, height: 1112)
        webView.frame = fullScreenFrame
        container.setFrameSize(NSSize(width: 480, height: 400))
        #expect(webView.frame == fullScreenFrame)

        // And back on exit, sized to the pane again.
        container.addSubview(webView)
        #expect(webView.frame == container.bounds)
    }

    // NSView's dealloc removes the still-attached panes itself, so teardown must
    // not unregister them a second time on the way out.
    @Test func teardownWithPanesStillAttachedIsBalanced() async {
        let webView = WKWebView()
        do {
            let container = WebViewContainer(webViewManager: nil, coordinator: nil)
            container.addSubview(webView)
        }
        // isolated deinit hops to the executor, so dealloc lands a turn later —
        // and the double unregistration it used to do threw from in there.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(webView.superview == nil)
    }
}
