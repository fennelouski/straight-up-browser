#if os(macOS)
import Foundation

enum GlobalHotkeyRegistrationState: Equatable {
    case disabled
    case registered(chord: String)
    case failed(chord: String, code: Int32)
}

/// The small injectable ownership transaction can be tested without claiming
/// any real system shortcut. It retains the previous registration on failure.
final class GlobalHotkeyRegistration<Handle> {
    private let register: (String, UInt32) -> (Int32, Handle?)
    private let unregister: (Handle) -> Int32
    private var handle: Handle?
    private var pendingCleanup: [Handle] = []
    private var serial: UInt32 = 1
    private(set) var currentChord: String?
    private(set) var state: GlobalHotkeyRegistrationState = .disabled
    private(set) var revision = 0
    var recoveryRequired: Bool { !pendingCleanup.isEmpty }

    init(register: @escaping (String, UInt32) -> (Int32, Handle?), unregister: @escaping (Handle) -> Int32) {
        self.register = register; self.unregister = unregister
    }

    @discardableResult func select(_ chord: String) -> Bool {
        if !pendingCleanup.isEmpty {
            var remaining: [Handle] = []
            var failure: Int32 = 0
            for candidate in pendingCleanup {
                let code = unregister(candidate)
                if code != 0 { remaining.append(candidate); failure = code }
            }
            pendingCleanup = remaining
            guard remaining.isEmpty else { state = .failed(chord: chord, code: failure); return false }
        }
        guard ["off", "optSpace", "ctrlOptSpace"].contains(chord) else {
            state = .failed(chord: chord, code: -50)
            return false
        }
        if chord == currentChord {
            state = chord == "off" ? .disabled : .registered(chord: chord)
            return true
        }
        if chord == "off" {
            if let handle {
                let code = unregister(handle)
                guard code == 0 else { state = .failed(chord: chord, code: code); return false }
            }
            handle = nil; currentChord = chord; revision += 1; state = .disabled
            return true
        }
        serial &+= 1
        let (code, candidate) = register(chord, serial)
        guard code == 0, let candidate else {
            state = .failed(chord: chord, code: code == 0 ? -1 : code)
            return false
        }
        if let handle {
            let releaseCode = unregister(handle)
            guard releaseCode == 0 else {
                let rollbackCode = unregister(candidate)
                if rollbackCode != 0 { pendingCleanup.append(candidate) }
                state = .failed(chord: chord, code: rollbackCode == 0 ? releaseCode : rollbackCode)
                return false
            }
        }
        handle = candidate; currentChord = chord; revision += 1; state = .registered(chord: chord)
        return true
    }
}

#endif
