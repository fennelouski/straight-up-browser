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
}
