import Darwin
import Foundation
import Observation

// Dispatch source cancellation is thread-safe; this lease releases its FD even
// when an injected owner is destroyed away from the main actor.
nonisolated private final class BrowserThemeWatchLease: @unchecked Sendable {
    let source: DispatchSourceFileSystemObject
    init(_ source: DispatchSourceFileSystemObject) { self.source = source }
    deinit { source.cancel() }
}

nonisolated enum BrowserThemeEnvironment {
    static func isTest(environment: [String: String], arguments: [String]) -> Bool {
        arguments.contains("-uiTesting") || environment["XCTestConfigurationFilePath"] != nil || environment["XCInjectBundleInto"] != nil
    }
    static func testLocation(temporaryDirectory: URL, identity: UUID) -> (directory: URL, suite: String) {
        (temporaryDirectory.appendingPathComponent("BrowserThemeTests-\(identity.uuidString)", isDirectory: true), "BrowserThemeTests.\(identity.uuidString)")
    }
}

/// Theme alone has migrated away from UserDefaults authority. Raw defaults
/// changes after first migration are compatibility projections, never imports.
/// Tests must inject a private directory/suite and never evaluate `shared`.
@MainActor @Observable final class BrowserThemeStore {
    static let shared: BrowserThemeStore = {
        let manager = FileManager.default
        if let paths = BrowserProfile.paths {
            return BrowserThemeStore(directory: paths.support.appendingPathComponent("Theme Authority", isDirectory: true), defaults: BrowserProfile.defaults)
        }
        if BrowserThemeEnvironment.isTest(environment: ProcessInfo.processInfo.environment, arguments: ProcessInfo.processInfo.arguments) {
            let fixture = BrowserThemeEnvironment.testLocation(temporaryDirectory: manager.temporaryDirectory, identity: UUID())
            guard let defaults = UserDefaults(suiteName: fixture.suite) else { return BrowserThemeStore(unavailable: SettingsDurableError.unavailable) }
            return BrowserThemeStore(directory: fixture.directory, defaults: defaults)
        }
        do {
            let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let app = support.appendingPathComponent("Straight Up Browser", isDirectory: true)
            try manager.createDirectory(at: app, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return BrowserThemeStore(directory: app.appendingPathComponent("Theme Authority", isDirectory: true), defaults: .standard, watchChanges: true)
        } catch { return BrowserThemeStore(unavailable: error) }
    }()

    private let defaults: UserDefaults?
    private let directory: URL?
    private let observesChanges: Bool
    private let boundary: ((SettingsDurabilityBoundary) throws -> Void)?
    private var durable: SettingsDurableStore?
    private(set) var value = "System"
    private(set) var revision: UInt64 = 0
    private(set) var statusMessage: String?
    private var blocked = false
    private var watcher: BrowserThemeWatchLease?
    private var refreshTask: Task<Void, Never>?

    init(directory: URL, defaults: UserDefaults, watchChanges: Bool = false, boundary: ((SettingsDurabilityBoundary) throws -> Void)? = nil) {
        self.defaults = defaults
        self.directory = directory
        self.observesChanges = watchChanges
        self.boundary = boundary
        do { try openAuthority() }
        catch {
            if isTransient(error) { statusMessage = error.localizedDescription; scheduleRefresh() }
            else { blocked = true; statusMessage = "Theme is unavailable. \(error.localizedDescription)" }
        }
    }

    private func openAuthority() throws {
        guard let directory, let defaults else { throw SettingsDurableError.unavailable }
            // Only evaluate the legacy value if authority is absent. Once a
            // durable state exists, even malformed raw defaults are irrelevant.
            durable = try SettingsDurableStore(directory: directory, allowedIDs: [.theme], initialValuesProvider: {
                guard let raw = defaults.object(forKey: "theme") else { return [:] }
                guard let theme = raw as? String, SettingsRegistry.descriptor(.theme).accepts(.choice(theme)) else { throw SettingsDurableError.invalidState }
                return [.theme: .choice(theme)]
            })
            durable?.boundary = boundary
            try refresh()
            if observesChanges, watcher == nil { watch(directory) }
    }

    private init(unavailable error: any Error) {
        defaults = nil
        directory = nil
        observesChanges = false
        boundary = nil
        blocked = true
        statusMessage = "Theme is unavailable. \(error.localizedDescription)"
    }

    var canCommit: Bool { !blocked && durable?.supportsRecoverableCommit(for: .theme) == true }

    func snapshot() throws -> SettingsStoreSnapshot {
        guard !blocked else { throw SettingsDurableError.uncertain }
        guard let durable else { throw SettingsDurableError.busy }
        do { return try durable.readVersioned(SettingsRegistry.descriptor(.theme)) }
        catch {
            if isTransient(error) { statusMessage = error.localizedDescription }
            else { blocked = true; statusMessage = "Theme needs recovery. \(error.localizedDescription)" }
            throw error
        }
    }

    func refresh() throws {
        do {
            try durable?.reconcile()
            let current = try snapshot()
            publish(current)
        } catch {
            if isTransient(error) { statusMessage = error.localizedDescription; scheduleRefresh() }
            else { blocked = true; statusMessage = "Theme needs recovery. \(error.localizedDescription)" }
            throw error
        }
    }

    /// Manual controls and assistant transactions use the SAME durable owner.
    /// Failure leaves the published selection unchanged and exposes an error.
    func setManually(_ newValue: String) {
        do {
            let before = try snapshot()
            _ = try commit(operationID: UUID(), value: .choice(newValue), expected: before.stored, expectedRevision: before.revision)
        } catch {
            if isTransient(error) { statusMessage = "Theme was not saved. \(error.localizedDescription)"; scheduleRefresh() }
            else { blocked = true; statusMessage = "Theme was not saved. \(error.localizedDescription)" }
        }
    }

    func commit(operationID: UUID, value: BrowserSettingValue?, expected: BrowserSettingValue?, expectedRevision: UInt64?) throws -> SettingsStoreSnapshot {
        guard let durable, canCommit else { throw SettingsDurableError.uncertain }
        do {
            let committed = try durable.commit(operationID: operationID, value: value, expected: expected, expectedRevision: expectedRevision, for: SettingsRegistry.descriptor(.theme))
            // A retry returns historical evidence. Publish a fresh coherent
            // current value rather than overwriting a later cooperative edit.
            do { publish(try durable.readVersioned(SettingsRegistry.descriptor(.theme))) }
            catch {
                if isTransient(error) { if (committed.revision ?? 0) >= revision { publish(committed) }; scheduleRefresh() }
                else { blocked = true; statusMessage = "Theme needs recovery. \(error.localizedDescription)"; throw error }
            }
            return committed
        } catch {
            if let issue = error as? SettingsDurableError, [.stale, .busy, .notApplied, .identityMismatch].contains(issue) { throw error }
            statusMessage = "Theme needs recovery. \(error.localizedDescription)"
            blocked = true
            throw error
        }
    }

    private func publish(_ snapshot: SettingsStoreSnapshot) {
        let selected = snapshot.stored ?? .choice("System")
        guard case .choice(let selected) = selected else { return }
        value = selected
        revision = snapshot.revision ?? 0
        statusMessage = nil
        // Projection is never read back to establish authority or success.
        if let stored = snapshot.stored { defaults?.set(stored.defaultsValue, forKey: "theme") }
        else { defaults?.removeObject(forKey: "theme") }
    }

    private func isTransient(_ error: any Error) -> Bool {
        guard let error = error as? SettingsDurableError else { return false }
        return error == .busy || error == .stale || error == .recoveryPending
    }

    private func scheduleRefresh() {
        guard refreshTask == nil, !blocked else { return }
        refreshTask = Task { @MainActor [weak self] in
            defer { self?.refreshTask = nil }
            for delay in [50, 100, 200] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self, !self.blocked else { return }
                do { if self.durable == nil { try self.openAuthority() } else { try self.refresh() }; return }
                catch { if !self.isTransient(error) { return } }
            }
        }
    }

    func stopObserving() {
        watcher = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    var canRetryLoading: Bool { !blocked && statusMessage != nil }
    func retryLoading() {
        guard !blocked else { return }
        do { if durable == nil { try openAuthority() } else { try refresh() } }
        catch {
            if isTransient(error) { statusMessage = error.localizedDescription }
            else { blocked = true; statusMessage = "Theme needs recovery. \(error.localizedDescription)" }
        }
    }

    private func watch(_ directory: URL) {
        let fd = open(directory.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { statusMessage = "Theme change observation is unavailable."; return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                do { try self.refresh() } catch { /* status is published by snapshot */ }
            }
        }
        source.setCancelHandler { close(fd) }
        watcher = BrowserThemeWatchLease(source)
        source.resume()
    }
}

/// Per-target production capability: only theme has an authoritative file owner.
/// The other three IDs remain on their existing stores and cannot Apply/Undo.
@MainActor final class SettingsNativeStore: SettingsPreferenceStore {
    private let defaults: SettingsDefaultsStore
    private let theme: () -> BrowserThemeStore
    init(defaults: UserDefaults = BrowserProfile.defaults, theme: @escaping () -> BrowserThemeStore = { .shared }) {
        self.defaults = SettingsDefaultsStore(defaults: defaults)
        self.theme = theme
    }
    var supportsRecoverableCommit: Bool { false } // no app-wide blanket grant
    func supportsRecoverableCommit(for id: BrowserSettingID) -> Bool { id == .theme && theme().canCommit }
    func read(_ descriptor: BrowserSettingDescriptor) -> BrowserSettingValue? { try? readVersioned(descriptor).stored }
    func readVersioned(_ descriptor: BrowserSettingDescriptor) throws -> SettingsStoreSnapshot {
        descriptor.id == .theme ? try theme().snapshot() : try defaults.readVersioned(descriptor)
    }
    func write(_ value: BrowserSettingValue?, for descriptor: BrowserSettingDescriptor) throws {
        if descriptor.id == .theme {
            let before = try theme().snapshot()
            _ = try theme().commit(operationID: UUID(), value: value, expected: before.stored, expectedRevision: before.revision)
        } else { try defaults.write(value, for: descriptor) }
    }
    func commit(operationID: UUID, value: BrowserSettingValue?, expected: BrowserSettingValue?, expectedRevision: UInt64?, for descriptor: BrowserSettingDescriptor) throws -> SettingsStoreSnapshot {
        guard descriptor == SettingsRegistry.descriptor(.theme) else { throw SettingsAssistantError.persistenceUnavailable }
        // Final app-owned native eligibility check, independent of a stale
        // SwiftUI available Bool/onChange callback. Manual controls bypass this
        // assistant-only adapter and keep working when help is disabled.
        guard SettingsAssistantAvailability.isVisible(defaults: defaults.defaults) else { throw SettingsAssistantError.permissionDenied }
        return try theme().commit(operationID: operationID, value: value, expected: expected, expectedRevision: expectedRevision)
    }
}
