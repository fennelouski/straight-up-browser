import CryptoKit
import Darwin
import Foundation

nonisolated enum SettingsDurableError: String, Error, LocalizedError {
    case unavailable, busy, recoveryPending, invalidState, unsupportedSchema, stale, identityMismatch, notApplied, uncertain
    var errorDescription: String? {
        switch self {
        case .busy: "Another Settings writer is active. Try a fresh preview."
        case .stale: "The setting changed since the preview. Prepare a fresh preview."
        case .notApplied: "The interrupted change was not applied. Prepare a new preview; the old action will not be replayed."
        case .recoveryPending: "An interrupted Settings operation needs reconciliation. Open the native theme control and retry loading; the old action will not be replayed."
        case .unsupportedSchema: "This version cannot read the saved Settings format. Its files have been preserved."
        default: "The saved Settings state needs recovery. No further change was made; its files have been preserved."
        }
    }
}

/// Test injection occurs after real filesystem operations; it never substitutes
/// a storage implementation. Throwing simulates process loss at that boundary.
nonisolated enum SettingsDurabilityBoundary: String, CaseIterable, Sendable {
    case intentFileSynced, intentRenamed, intentDirectorySynced
    case stateFileSynced, stateRenamed, stateDirectorySynced
    case outcomeFileSynced, outcomeRenamed, outcomeDirectorySynced
}

/// A small app-owned authority, not a UserDefaults journal. Only callers which
/// migrate ALL readers/writers of an ID may expose its recoverable capability.
/// flock protects cooperating owners, not an attacker rewriting arbitrary files.
@MainActor final class SettingsDurableStore: SettingsPreferenceStore {
    nonisolated static let stateName = "settings-state-v1.json"
    nonisolated static let journalName = "settings-intent-v1.json"
    nonisolated static let lockName = "settings-authority.lock"
    nonisolated static let markerName = "settings-authority-v1.json"
    let directory: URL
    let allowedIDs: Set<BrowserSettingID>
    var boundary: ((SettingsDurabilityBoundary) throws -> Void)?
    private(set) var failure: (any Error)?
    private var observedAuthority: UUID?
    private var observedGeneration: UInt64 = 0

    nonisolated private struct Entry: Codable, Equatable { var stored: BrowserSettingValue?; var revision: UInt64 }
    nonisolated private struct Request: Codable, Equatable {
        let id: UUID
        let authority: UUID
        let settingID: BrowserSettingID
        let expected: BrowserSettingValue?
        let expectedRevision: UInt64
        let desired: BrowserSettingValue?
    }
    nonisolated private enum Status: String, Codable { case committed, notApplied }
    nonisolated private struct Outcome: Codable, Equatable {
        let request: Request
        let fingerprint: String
        let status: Status
        let postRevision: UInt64
        var snapshot: SettingsStoreSnapshot { .init(stored: status == .committed ? request.desired : request.expected, revision: postRevision) }
    }
    nonisolated private struct State: Codable, Equatable {
        let authority: UUID
        var generation: UInt64
        var entries: [String: Entry]
        var outcomes: [Outcome]
    }
    nonisolated private struct Journal: Codable {
        let request: Request
        let fingerprint: String
        let beforeHash: String
        let afterHash: String
        let beforeGeneration: UInt64
        var outcome: Outcome?
    }
    nonisolated private struct Envelope<Payload: Codable>: Codable {
        let schemaVersion: Int
        let payload: Payload
        let digest: String
    }
    nonisolated private struct Marker: Codable { let authority: UUID }

    init(directory: URL, allowedIDs: Set<BrowserSettingID>, initialValues: [BrowserSettingID: BrowserSettingValue] = [:], initialValuesProvider: (() throws -> [BrowserSettingID: BrowserSettingValue])? = nil) throws {
        guard directory.isFileURL, !allowedIDs.isEmpty, Set(initialValues.keys).isSubset(of: allowedIDs) else { throw SettingsDurableError.invalidState }
        self.directory = directory
        self.allowedIDs = allowedIDs
        for (id, value) in initialValues where !SettingsRegistry.descriptor(id).accepts(value) { throw SettingsDurableError.invalidState }
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            // Persist the new directory entry in its already existing parent.
            let parent = open(directory.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard parent >= 0 else { throw SettingsDurableError.unavailable }
            defer { close(parent) }
            guard fsync(parent) == 0 else { throw SettingsDurableError.uncertain }
        }
        let previousLock = FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.lockName).path)
        try locked { fd in
            if try readFile(Self.stateName, fd: fd) == nil {
                guard !previousLock, try readFile(Self.markerName, fd: fd) == nil, try readFile(Self.journalName, fd: fd) == nil else { throw SettingsDurableError.invalidState }
                let seed = try initialValuesProvider?() ?? initialValues
                guard Set(seed.keys).isSubset(of: allowedIDs), seed.allSatisfy({ SettingsRegistry.descriptor($0.key).accepts($0.value) }) else { throw SettingsDurableError.invalidState }
                let entries = Dictionary(uniqueKeysWithValues: allowedIDs.map { ($0.rawValue, Entry(stored: seed[$0], revision: 0)) })
                let state = State(authority: UUID(), generation: 0, entries: entries, outcomes: [])
                try atomicWrite(try encoded(state), name: Self.stateName, fd: fd, boundaries: nil)
            }
            if try readFile(Self.markerName, fd: fd) == nil {
                guard let data = try readFile(Self.stateName, fd: fd) else { throw SettingsDurableError.invalidState }
                let state: State = try decoded(data)
                try atomicWrite(try encoded(Marker(authority: state.authority)), name: Self.markerName, fd: fd, boundaries: nil)
            }
            _ = try loadRecovering(fd: fd)
        }
    }

    var supportsRecoverableCommit: Bool { failure == nil }
    func supportsRecoverableCommit(for id: BrowserSettingID) -> Bool { failure == nil && allowedIDs.contains(id) }

    func read(_ descriptor: BrowserSettingDescriptor) -> BrowserSettingValue? { try? readVersioned(descriptor).stored }
    func readVersioned(_ descriptor: BrowserSettingDescriptor) throws -> SettingsStoreSnapshot {
        try guarded {
            try validate(descriptor)
            return try locked { fd in
                let state = try loadRecovering(fd: fd, recover: false)
                let entry = state.entries[descriptor.id.rawValue]!
                return .init(stored: entry.stored, revision: entry.revision)
            }
        }
    }

    func write(_ value: BrowserSettingValue?, for descriptor: BrowserSettingDescriptor) throws {
        let before = try readVersioned(descriptor)
        _ = try commit(operationID: UUID(), value: value, expected: before.stored, expectedRevision: before.revision, for: descriptor)
    }

    func commit(operationID: UUID, value: BrowserSettingValue?, expected: BrowserSettingValue?, expectedRevision: UInt64?, for descriptor: BrowserSettingDescriptor) throws -> SettingsStoreSnapshot {
        try guarded {
            try validate(descriptor)
            guard let expectedRevision, value.map(descriptor.accepts) ?? true else { throw SettingsDurableError.invalidState }
            return try locked { fd in
                var state = try loadRecovering(fd: fd)
                let request = Request(id: operationID, authority: state.authority, settingID: descriptor.id, expected: expected, expectedRevision: expectedRevision, desired: value)
                let fingerprint = try hash(request)
                if let outcome = state.outcomes.first(where: { $0.request.id == operationID }) {
                    guard outcome.fingerprint == fingerprint else { throw SettingsDurableError.identityMismatch }
                    guard outcome.status == .committed else { throw SettingsDurableError.notApplied }
                    return outcome.snapshot
                }
                let before = state.entries[descriptor.id.rawValue]!
                guard before.stored == expected, before.revision == expectedRevision else { throw SettingsDurableError.stale }
                guard before.revision < UInt64.max, state.generation < UInt64.max else { throw SettingsDurableError.invalidState }
                let beforeHash = try hash(state)
                let outcome = Outcome(request: request, fingerprint: fingerprint, status: .committed, postRevision: before.revision + 1)
                state.generation += 1
                state.entries[descriptor.id.rawValue] = .init(stored: value, revision: outcome.postRevision)
                append(outcome, to: &state)
                var journal = Journal(request: request, fingerprint: fingerprint, beforeHash: beforeHash, afterHash: try hash(state), beforeGeneration: state.generation - 1, outcome: nil)
                try atomicWrite(try encoded(journal), name: Self.journalName, fd: fd, boundaries: [.intentFileSynced, .intentRenamed, .intentDirectorySynced])
                try atomicWrite(try encoded(state), name: Self.stateName, fd: fd, boundaries: [.stateFileSynced, .stateRenamed, .stateDirectorySynced])
                journal.outcome = outcome
                try atomicWrite(try encoded(journal), name: Self.journalName, fd: fd, boundaries: [.outcomeFileSynced, .outcomeRenamed, .outcomeDirectorySynced])
                observedGeneration = state.generation
                return outcome.snapshot
            }
        }
    }

    /// Minimal operation status is read-only. Recovery may record a terminal
    /// notApplied outcome, but never reissues the requested preference write.
    func operationWasApplied(_ id: UUID) throws -> Bool? {
        try guarded { try locked { fd in try loadRecovering(fd: fd, recover: false).outcomes.first { $0.request.id == id }.map { $0.status == .committed } } }
    }

    /// Only owner startup, explicit native refresh, and filesystem observation
    /// reconcile an orphan. Assistant snapshots/status never perform writes.
    func reconcile() throws { try guarded { try locked { fd in _ = try loadRecovering(fd: fd) } } }

    private func validate(_ descriptor: BrowserSettingDescriptor) throws {
        guard allowedIDs.contains(descriptor.id), descriptor == SettingsRegistry.descriptor(descriptor.id) else { throw SettingsDurableError.invalidState }
    }

    private func guarded<T>(_ action: () throws -> T) throws -> T {
        guard failure == nil else { throw SettingsDurableError.uncertain }
        do { return try action() }
        catch {
            if let error = error as? SettingsDurableError, [.busy, .recoveryPending, .stale, .notApplied, .identityMismatch].contains(error) { throw error }
            failure = error
            throw error
        }
    }

    private func append(_ outcome: Outcome, to state: inout State) {
        state.outcomes.append(outcome)
        if state.outcomes.count > 100 { state.outcomes.removeFirst(state.outcomes.count - 100) }
        // Even an evicted notApplied identity cannot execute later: recovery
        // advances that target's revision without changing its stored value.
    }

    private func loadRecovering(fd: Int32, recover: Bool = true) throws -> State {
        guard let bytes = try readFile(Self.stateName, fd: fd) else { throw SettingsDurableError.invalidState }
        var state: State = try decoded(bytes)
        guard let markerBytes = try readFile(Self.markerName, fd: fd) else { throw SettingsDurableError.invalidState }
        let marker: Marker = try decoded(markerBytes)
        guard marker.authority == state.authority else { throw SettingsDurableError.invalidState }
        guard Set(state.entries.keys) == Set(allowedIDs.map(\.rawValue)), state.outcomes.count <= 100,
              state.entries.allSatisfy({ key, entry in entry.revision <= state.generation && (BrowserSettingID(rawValue: key).map { id in entry.stored.map(SettingsRegistry.descriptor(id).accepts) ?? true } ?? false) }),
              Set(state.outcomes.map { $0.request.id }).count == state.outcomes.count else { throw SettingsDurableError.invalidState }
        var total: UInt64 = 0
        for entry in state.entries.values {
            let sum = total.addingReportingOverflow(entry.revision)
            guard !sum.overflow else { throw SettingsDurableError.invalidState }
            total = sum.partialValue
        }
        guard total == state.generation else { throw SettingsDurableError.invalidState }
        if let authority = observedAuthority, authority != state.authority { throw SettingsDurableError.invalidState }
        guard state.generation >= observedGeneration else { throw SettingsDurableError.invalidState }
        for outcome in state.outcomes {
            guard outcome.request.authority == state.authority, allowedIDs.contains(outcome.request.settingID),
                  outcome.fingerprint == (try hash(outcome.request)), outcome.request.expectedRevision < UInt64.max,
                  outcome.postRevision == outcome.request.expectedRevision + 1,
                  outcome.postRevision <= state.generation, valid(outcome.request),
                  state.entries[outcome.request.settingID.rawValue]!.revision >= outcome.postRevision else { throw SettingsDurableError.invalidState }
        }
        if let journalBytes = try readFile(Self.journalName, fd: fd) {
            var journal: Journal = try decoded(journalBytes)
            guard journal.request.authority == state.authority, allowedIDs.contains(journal.request.settingID), journal.fingerprint == (try hash(journal.request)), valid(journal.request),
                  journal.request.expectedRevision < UInt64.max, journal.request.expectedRevision <= journal.beforeGeneration, journal.beforeGeneration < UInt64.max else { throw SettingsDurableError.invalidState }
            if let recorded = state.outcomes.first(where: { $0.request.id == journal.request.id }) {
                guard recorded.fingerprint == journal.fingerprint, journal.outcome.map({ $0 == recorded }) ?? true else { throw SettingsDurableError.invalidState }
                guard journal.beforeGeneration < UInt64.max, state.generation == journal.beforeGeneration + 1 else { throw SettingsDurableError.invalidState }
                if recorded.status == .committed { guard try hash(state) == journal.afterHash else { throw SettingsDurableError.invalidState } }
                if journal.outcome == nil {
                    guard recover else { throw SettingsDurableError.recoveryPending }
                    // Re-establish a persistence barrier before resolving an
                    // interrupted rename/directory-sync as committed.
                    try syncExisting(Self.stateName, fd: fd)
                    guard fsync(fd) == 0 else { throw SettingsDurableError.uncertain }
                    journal.outcome = recorded
                    try atomicWrite(try encoded(journal), name: Self.journalName, fd: fd, boundaries: nil)
                }
            } else {
                guard recover else { throw SettingsDurableError.recoveryPending }
                guard journal.outcome == nil, state.generation == journal.beforeGeneration, try hash(state) == journal.beforeHash,
                      let before = state.entries[journal.request.settingID.rawValue], before.stored == journal.request.expected,
                      before.revision == journal.request.expectedRevision, before.revision < UInt64.max, state.generation < UInt64.max else { throw SettingsDurableError.invalidState }
                var intended = state
                intended.generation += 1
                intended.entries[journal.request.settingID.rawValue] = .init(stored: journal.request.desired, revision: before.revision + 1)
                append(.init(request: journal.request, fingerprint: journal.fingerprint, status: .committed, postRevision: before.revision + 1), to: &intended)
                guard try hash(intended) == journal.afterHash else { throw SettingsDurableError.invalidState }
                // No requested value is replayed. Burn its expected revision so
                // this identity stays ineligible even after outcome compaction.
                let outcome = Outcome(request: journal.request, fingerprint: journal.fingerprint, status: .notApplied, postRevision: before.revision + 1)
                state.entries[journal.request.settingID.rawValue] = .init(stored: before.stored, revision: outcome.postRevision)
                state.generation += 1
                append(outcome, to: &state)
                try atomicWrite(try encoded(state), name: Self.stateName, fd: fd, boundaries: nil)
                journal.outcome = outcome
                try atomicWrite(try encoded(journal), name: Self.journalName, fd: fd, boundaries: nil)
            }
        }
        observedAuthority = state.authority
        observedGeneration = state.generation
        return state
    }

    private func valid(_ request: Request) -> Bool {
        let descriptor = SettingsRegistry.descriptor(request.settingID)
        return (request.expected.map(descriptor.accepts) ?? true) && (request.desired.map(descriptor.accepts) ?? true)
    }

    private func encoded<T: Codable>(_ payload: T) throws -> Data {
        try encode(Envelope(schemaVersion: 1, payload: payload, digest: hash(payload)))
    }
    private func decoded<T: Codable>(_ data: Data) throws -> T {
        guard data.count <= 1_048_576 else { throw SettingsDurableError.invalidState }
        var parser = SettingsStrictJSON(data: data)
        try parser.validate()
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["schemaVersion"] as? Int == 1 else { throw SettingsDurableError.unsupportedSchema }
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        guard envelope.digest == (try hash(envelope.payload)), try canonical(data) == canonical(encode(envelope)) else { throw SettingsDurableError.invalidState }
        return envelope.payload
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private func canonical(_ bytes: Data) throws -> Data { try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: bytes), options: [.sortedKeys, .withoutEscapingSlashes]) }
    private func hash<T: Encodable>(_ value: T) throws -> String { SHA256.hash(data: try encode(value)).map { String(format: "%02x", $0) }.joined() }

    private func locked<T>(_ action: (Int32) throws -> T) throws -> T {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw SettingsDurableError.unavailable }
        defer { close(fd) }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_uid == getuid(), attributes.st_mode & 0o077 == 0 else { throw SettingsDurableError.invalidState }
        let lockFD = openat(fd, Self.lockName, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw SettingsDurableError.unavailable }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw SettingsDurableError.busy }
        defer { _ = flock(lockFD, LOCK_UN) }
        // The stable lock inode is never unlinked or replaced. Reject a moved
        // authority directory rather than writing into an orphaned location.
        var current = stat()
        guard lstat(directory.path, &current) == 0, current.st_dev == attributes.st_dev, current.st_ino == attributes.st_ino else { throw SettingsDurableError.invalidState }
        return try action(fd)
    }

    private func readFile(_ name: String, fd: Int32) throws -> Data? {
        let file = openat(fd, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if file < 0, errno == ENOENT { return nil }
        guard file >= 0 else { throw SettingsDurableError.unavailable }
        defer { close(file) }
        var attributes = stat()
        guard fstat(file, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG, attributes.st_uid == getuid(), attributes.st_nlink == 1, attributes.st_size <= 1_048_576 else { throw SettingsDurableError.invalidState }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count == 0 { return result }
            guard count > 0, result.count + count <= 1_048_576 else { throw SettingsDurableError.unavailable }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    private func syncExisting(_ name: String, fd: Int32) throws {
        let file = openat(fd, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard file >= 0 else { throw SettingsDurableError.unavailable }
        defer { close(file) }
        try syncFile(file)
    }
    private func syncFile(_ fd: Int32) throws {
        guard fsync(fd) == 0 else { throw SettingsDurableError.uncertain }
        // macOS fsync alone may leave data in a disk's volatile write cache.
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw SettingsDurableError.uncertain }
    }
    private func atomicWrite(_ data: Data, name: String, fd: Int32, boundaries: [SettingsDurabilityBoundary]?) throws {
        let temporary = ".\(name).\(UUID().uuidString).tmp"
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw SettingsDurableError.unavailable }
        defer { close(file) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard written > 0 else { throw SettingsDurableError.uncertain }
                offset += written
            }
        }
        try syncFile(file)
        if let boundaries { try boundary?(boundaries[0]) }
        guard renameat(fd, temporary, fd, name) == 0 else { throw SettingsDurableError.uncertain }
        if let boundaries { try boundary?(boundaries[1]) }
        guard fsync(fd) == 0 else { throw SettingsDurableError.uncertain }
        if let boundaries { try boundary?(boundaries[2]) }
        // Interrupted temp files and the last journal are preserved as evidence.
    }
}
