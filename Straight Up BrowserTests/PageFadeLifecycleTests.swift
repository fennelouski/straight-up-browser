#if os(macOS)
import AppKit
import Testing
import WebKit
@testable import Browser

@Suite(.serialized)
@MainActor
struct PageFadeLifecycleTests {
    private final class Delegate: NSObject, WKNavigationDelegate, WKUIDelegate {}

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    // Invoke the real Objective-C callback without broadcasting fake system
    // sleep events to unrelated observers in the running test host.
    nonisolated private static func suspend(_ manager: WebViewManager, _ name: Notification.Name) {
        _ = manager.perform(NSSelectorFromString("pageFadeWillSuspend:"), with: NSNotification(name: name, object: nil))
    }

    nonisolated private static func resume(_ manager: WebViewManager, _ name: Notification.Name) {
        _ = manager.perform(NSSelectorFromString("pageFadeDidResume:"), with: NSNotification(name: name, object: nil))
    }

    @Test func backgroundDefaultsNotificationCompletesItsVisibilityUpdate() async {
        let manager = WebViewManager(), delegate = Delegate()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let id = UUID()
        manager.adoptWebView(webView, for: id, navigationDelegate: delegate, uiDelegate: delegate)
        manager.preparePageFade(webView, targetURL: URL(string: "https://example.test/call"))
        webView.alphaValue = 0
        await Task.detached {
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        }.value
        await drainMainQueue()
        // The offscreen view is revealed by the actual queued selector handler.
        #expect(webView.alphaValue == 1)
        #expect(manager.existingWebView(for: id) === webView)
        manager.cleanup()
    }

    @Test func mainThreadSleepAndWakeAreAppliedBeforePostingReturns() {
        let manager = WebViewManager()
        Self.suspend(manager, NSWorkspace.willSleepNotification)
        #expect(manager.pageFadeSuspensionReasons.contains("system"))
        Self.resume(manager, NSWorkspace.didWakeNotification)
        #expect(!manager.pageFadeSuspensionReasons.contains("system"))
    }

    @Test func backgroundSleepWakeBurstsLeaveNoStaleSuspension() async {
        let manager = WebViewManager()
        await Task.detached {
            for _ in 0..<50 {
                Self.suspend(manager, NSWorkspace.willSleepNotification)
                Self.suspend(manager, NSWorkspace.screensDidSleepNotification)
                Self.resume(manager, NSWorkspace.didWakeNotification)
                Self.resume(manager, NSWorkspace.screensDidWakeNotification)
            }
        }.value
        await drainMainQueue()
        #expect(manager.pageFadeSuspensionReasons.isEmpty)
    }

    @Test func synchronousResumeConsumesAnEarlierQueuedBackgroundSuspend() async {
        let manager = WebViewManager()
        // Keep the main actor occupied until the background post has returned:
        // the queued main block cannot run before the synchronous resume below.
        DispatchQueue.global().sync {
            Self.suspend(manager, NSWorkspace.willSleepNotification)
            Self.suspend(manager, NSWorkspace.screensDidSleepNotification)
        }
        Self.resume(manager, NSWorkspace.didWakeNotification)
        #expect(manager.pageFadeSuspensionReasons == ["display"])
        Self.resume(manager, NSWorkspace.screensDidWakeNotification)
        await drainMainQueue()
        #expect(manager.pageFadeSuspensionReasons.isEmpty)
    }

    @Test func pendingBackgroundDeliveryDoesNotRetainTheManager() async {
        weak var released: WebViewManager?
        autoreleasepool {
            var manager: WebViewManager? = WebViewManager()
            released = manager
            DispatchQueue.global().sync {
                NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
            }
            manager = nil
        }
        #expect(released == nil)
        await drainMainQueue()
        #expect(released == nil)
    }
}
#endif
