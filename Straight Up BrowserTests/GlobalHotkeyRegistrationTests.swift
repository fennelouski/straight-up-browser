import Foundation
import Testing
@testable import Browser

@MainActor struct GlobalHotkeyRegistrationTests {
    @Test func failedGlobalReplacementRetainsOldHandleAndRevision() {
        var released: [Int] = []
        var fail = false
        let registration = GlobalHotkeyRegistration<Int>(register: { _, serial in
            fail ? (-9878, nil) : (0, Int(serial))
        }, unregister: { released.append($0); return 0 })
        #expect(registration.select("optSpace"))
        let revision = registration.revision
        fail = true
        #expect(!registration.select("ctrlOptSpace"))
        #expect(registration.currentChord == "optSpace")
        #expect(registration.revision == revision)
        #expect(released.isEmpty)
        #expect(registration.state == .failed(chord: "ctrlOptSpace", code: -9878))
        fail = false
        #expect(registration.select("ctrlOptSpace"))
        #expect(released.count == 1)
        #expect(registration.select("off"))
        #expect(released.count == 2)
        #expect(registration.state == .disabled)
    }

    @Test func failedReleaseRollsBackCandidateAndRejectsUnknownPreset() {
        var released: [Int] = []
        let registration = GlobalHotkeyRegistration<Int>(register: { _, serial in (0, Int(serial)) }, unregister: {
            released.append($0)
            return $0 == 2 ? -50 : 0
        })
        #expect(registration.select("optSpace"))
        #expect(!registration.select("ctrlOptSpace"))
        #expect(released == [2, 3])
        #expect(registration.currentChord == "optSpace")
        #expect(!registration.select("unknown"))
        #expect(registration.state == .failed(chord: "unknown", code: -50))
    }

    @Test func failedRollbackRetainsExtraHandleUntilCleanupSucceeds() {
        var failing = true
        var registrations = 0
        let registration = GlobalHotkeyRegistration<Int>(register: { _, serial in
            registrations += 1; return (0, Int(serial))
        }, unregister: { _ in failing ? -50 : 0 })
        #expect(registration.select("optSpace"))
        #expect(!registration.select("ctrlOptSpace"))
        #expect(registration.recoveryRequired)
        #expect(!registration.select("ctrlOptSpace"))
        #expect(registrations == 2)
        failing = false
        #expect(registration.select("off"))
        #expect(!registration.recoveryRequired)
        #expect(registration.currentChord == "off")
    }
}
