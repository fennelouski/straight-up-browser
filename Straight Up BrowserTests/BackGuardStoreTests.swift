import Foundation
import Testing
@testable import Browser

struct BackGuardStoreTests {
    private func scratch() -> (BackGuardStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "back-guard-tests-\(UUID().uuidString)")!
        return (BackGuardStore(defaults: defaults), defaults)
    }

    @Test func triggersDecideWhenNoSiteOverride() {
        let (store, _) = scratch()
        #expect(store.shouldConfirm(host: "meet.google.com", active: [.microphone]))
        #expect(!store.shouldConfirm(host: "youtube.com", active: [.fullscreen]))
        store.set(.fullscreen, enabled: true)
        #expect(store.shouldConfirm(host: "youtube.com", active: [.fullscreen]))
        #expect(!store.shouldConfirm(host: "example.com", active: []))
    }

    @Test func siteOverrideWinsAndPersists() {
        let (store, defaults) = scratch()
        store.set(false, host: "www.Meet.Google.com")
        store.set(true, host: "youtube.com")
        #expect(!store.shouldConfirm(host: "meet.google.com", active: [.camera, .microphone]))
        #expect(store.shouldConfirm(host: "youtube.com", active: []))

        let reloaded = BackGuardStore(defaults: defaults)
        #expect(reloaded.customizedHosts == ["meet.google.com", "youtube.com"])
        reloaded.set(nil, host: "meet.google.com")
        #expect(reloaded.shouldConfirm(host: "meet.google.com", active: [.camera]))
    }
}
