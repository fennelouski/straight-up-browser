#if os(macOS)
import Foundation
import Testing
@testable import Browser

@MainActor
struct PageFadeLifecycleTests {
    @Test func defaultsChangesFromBackgroundSyncDoNotEnterTheUIActorSynchronously() async {
        let manager = WebViewManager()
        await Task.detached {
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        }.value
        await Task.yield()
        #expect(manager.webViews.isEmpty)
    }
}
#endif
