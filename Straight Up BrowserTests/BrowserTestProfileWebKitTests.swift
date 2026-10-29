import Foundation
import Testing
import WebKit
@testable import Browser

@MainActor struct BrowserTestProfileWebKitTests {
    @Test func profileNormalAndContainerJarsAreNonpersistentAndSeparate() {
        let stores = BrowserTestWebKitStores()
        let firstID = UUID(), secondID = UUID()
        let normal = stores.store()
        let first = stores.store(container: firstID)
        let second = stores.store(container: secondID)
        #expect(!normal.isPersistent && !first.isPersistent && !second.isPersistent)
        #expect(normal === stores.store())
        #expect(first === stores.store(container: firstID))
        #expect(normal !== first && first !== second && normal !== second)
    }

    @Test func separateProfileOwnersCannotShareAnEphemeralJar() {
        let first = BrowserTestWebKitStores()
        let second = BrowserTestWebKitStores()
        let identifier = UUID()
        #expect(first.store() !== second.store())
        #expect(first.store(container: identifier) !== second.store(container: identifier))
    }
}
