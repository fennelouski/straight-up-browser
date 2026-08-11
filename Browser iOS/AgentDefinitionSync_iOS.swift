import Combine
import Foundation
import UIKit

nonisolated enum MobileTestConfiguration {
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTesting")
    }
}

/// Mobile owns review and retention of safe synced definitions, but never owns
/// an agent executor. In particular, this type has no scheduler installer or
/// materialization API: schedules remain inert on iPhone and iPad even after a
/// successful CloudKit refresh.
@MainActor
final class AgentDefinitionSyncViewModel_iOS: ObservableObject {
    private enum Key {
        static let reviewedSensitiveMemoryRevisions =
            "agentDefinitionSync.mobileReviewedSensitiveMemoryRevisions"
    }

    @Published private(set) var definitions: [AgentDefinitionSyncEnvelope] = []
    @Published private(set) var unavailableSchedules: [UUID: AgentDefinitionAvailability] = [:]
    @Published private(set) var sensitiveMemoryAwaitingReview: Set<UUID> = []
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isSyncing = false

    private let defaults: UserDefaults
    private let runtime: AgentDefinitionSyncRuntime

    init(
        defaults: UserDefaults = .standard,
        runtime: AgentDefinitionSyncRuntime? = nil
    ) {
        self.defaults = defaults
        if let runtime {
            self.runtime = runtime
        } else if MobileTestConfiguration.isUITesting {
            let backend = try! AgentDefinitionInMemorySyncBackend()
            self.runtime = AgentDefinitionSyncRuntime(
                baseDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "straight-up-browser-ui-tests",
                        isDirectory: true
                    ),
                backend: backend
            )
        } else {
            self.runtime = .shared
        }
    }

    func synchronize() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        // Project the durable cache first so offline users can still inspect
        // everything retained on this device.
        await project(await runtime.snapshot())
        do {
            _ = try await runtime.refresh()
            await project(await runtime.snapshot())
            lastSyncAt = Date()
            lastError = nil
        } catch {
            await project(await runtime.snapshot())
            lastError = String(
                localized: "iCloud sync couldn’t finish. Your retained definitions are still available for review."
            )
        }
    }

    @discardableResult
    func enable(_ category: AgentDefinitionSyncCategory) async -> Bool {
        guard !isSyncing else { return false }
        isSyncing = true
        defer { isSyncing = false }
        do {
            _ = try await runtime.setEnabled(true, category: category)
            await project(await runtime.snapshot())
            lastSyncAt = Date()
            lastError = nil
            return true
        } catch {
            await project(await runtime.snapshot())
            lastError = String(localized: "This sync category couldn’t be enabled. Check iCloud and try again.")
            return false
        }
    }

    @discardableResult
    func disable(
        _ category: AgentDefinitionSyncCategory,
        disposition: AgentDefinitionSyncDisableDisposition
    ) async -> Bool {
        guard !isSyncing else { return false }
        isSyncing = true
        defer { isSyncing = false }
        do {
            _ = try await runtime.disable(category, disposition: disposition)
            await project(await runtime.snapshot())
            lastSyncAt = Date()
            lastError = nil
            return true
        } catch {
            await project(await runtime.snapshot())
            lastError = String(localized: "The sync change couldn’t finish. Nothing was removed; you can safely try again.")
            return false
        }
    }

    func markSensitiveMemoryReviewed(_ id: UUID) {
        guard let memory = memory(id), memory.sensitivity == .sensitive else {
            return
        }
        var revisions = reviewedSensitiveMemoryRevisions
        revisions[memory.id] = memory.revision
        reviewedSensitiveMemoryRevisions = revisions
        sensitiveMemoryAwaitingReview.remove(memory.id)
    }

    func scheduleName(_ id: UUID) -> String {
        guard let envelope = definitions.first(where: { $0.definitionID == id }),
              case .schedule(let schedule)? = envelope.payload
        else { return String(localized: "Imported schedule") }
        return schedule.name
    }

    func scheduleReasonText(_ id: UUID) -> String {
        guard let availability = unavailableSchedules[id] else {
            return String(localized: "Unavailable on this device")
        }
        return availability.reasons.map(Self.reasonLabel)
            .uniqued()
            .joined(separator: " · ")
    }

    func providerPresets() -> [AgentSyncedProviderPreset] {
        definitions.compactMap { envelope in
            guard case .providerPreset(let preset)? = envelope.payload else {
                return nil
            }
            return preset
        }
    }

    func memories() -> [AgentSyncedUserMemory] {
        definitions.compactMap { envelope in
            guard case .userAuthoredMemory(let memory)? = envelope.payload else {
                return nil
            }
            return memory
        }
    }

    private func memory(_ id: UUID) -> AgentSyncedUserMemory? {
        memories().first { $0.id == id }
    }

    private func project(_ snapshot: AgentDefinitionSyncRuntimeSnapshot) async {
        let visible = snapshot.definitionsByRecordName.values
            .filter { !$0.isTombstone && $0.payload != nil }
            .sorted { $0.recordName < $1.recordName }
        definitions = visible

        let presets = Dictionary(uniqueKeysWithValues: visible.compactMap {
            envelope -> (UUID, AgentSyncedProviderPreset)? in
            guard case .providerPreset(let preset)? = envelope.payload else {
                return nil
            }
            return (preset.id, preset)
        })
        let platform: AgentDefinitionDevicePlatform =
            UIDevice.current.userInterfaceIdiom == .pad ? .iPadOS : .iOS
        let device = AgentDefinitionDeviceCapabilities(
            deviceID: snapshot.deviceID,
            platform: platform,
            installedProviderPresetIDs: Set(presets.keys)
        )

        var unavailable: [UUID: AgentDefinitionAvailability] = [:]
        for envelope in visible where envelope.category == .schedules {
            guard case .schedule(let schedule)? = envelope.payload else {
                continue
            }
            switch try? AgentDefinitionActivationGate.evaluate(
                envelope,
                providerPresets: presets,
                preferences: snapshot.preferences,
                device: device
            ) {
            case .unavailable(let availability):
                unavailable[schedule.id] = availability
            case .runnable:
                // The shared gate should never produce a mobile permit. Keep a
                // second fail-closed boundary in the presentation projection.
                unavailable[schedule.id] = AgentDefinitionAvailability(
                    retainOnDevice: true,
                    mayRun: false,
                    reasons: [.unsupportedPlatform(platform)]
                )
            case nil:
                unavailable[schedule.id] = AgentDefinitionAvailability(
                    retainOnDevice: true,
                    mayRun: false,
                    reasons: [.unsupportedPlatform(platform)]
                )
            }
        }
        unavailableSchedules = unavailable

        let reviewed = reviewedSensitiveMemoryRevisions
        sensitiveMemoryAwaitingReview = Set(memories().compactMap { memory in
            guard memory.sensitivity == .sensitive,
                  reviewed[memory.id] != memory.revision
            else { return nil }
            return memory.id
        })
    }

    private var reviewedSensitiveMemoryRevisions: [UUID: Int] {
        get {
            guard let values = defaults.dictionary(
                forKey: Key.reviewedSensitiveMemoryRevisions
            ) else { return [:] }
            return Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
                guard let id = UUID(uuidString: key),
                      let revision = value as? Int,
                      revision > 0
                else { return nil }
                return (id, revision)
            })
        }
        set {
            defaults.set(
                Dictionary(uniqueKeysWithValues: newValue.map {
                    ($0.key.uuidString, $0.value)
                }),
                forKey: Key.reviewedSensitiveMemoryRevisions
            )
        }
    }

    private static func reasonLabel(
        _ reason: AgentDefinitionUnavailabilityReason
    ) -> String {
        switch reason {
        case .categorySyncDisabled:
            String(localized: "Sync is off")
        case .tombstone:
            String(localized: "Deleted on another device")
        case .definitionDisabled:
            String(localized: "Disabled by its author")
        case .unsupportedSchema:
            String(localized: "Needs a newer Browser version")
        case .unsupportedPlatform:
            String(localized: "Runs only on macOS")
        case .missingProviderPreset:
            String(localized: "Provider preset unavailable")
        case .missingLocalProviderAccess:
            String(localized: "Provider access is local to the Mac")
        case .missingMCPConnection:
            String(localized: "MCP connection is local to the Mac")
        case .missingCoworkScope:
            String(localized: "Cowork folder access is local to the Mac")
        case .missingBrowserSession:
            String(localized: "Browser session is unavailable")
        case .unsupportedCapability:
            String(localized: "Required capability is unavailable")
        case .capabilityNotGranted:
            String(localized: "Local authorization is required")
        case .scheduledPolicyNotSatisfied:
            String(localized: "Scheduled execution is unavailable")
        }
    }
}

private extension Sequence where Element == String {
    func uniqued() -> [String] {
        var seen: Set<String> = []
        return filter { seen.insert($0).inserted }
    }
}
