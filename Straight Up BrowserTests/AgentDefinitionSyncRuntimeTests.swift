import Combine
import Foundation
import Testing
@testable import Browser

@Suite("Agent definition sync runtime")
struct AgentDefinitionSyncRuntimeTests {
    @Test("Opt-in definitions use the backend and a durable secret-free local cache")
    func publishPullAndReload() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let defaults = try fixture.makeDefaults()
        defaults.set(
            true,
            forKey: AgentDefinitionSyncSettings.Key.providerPresets
        )
        let backend = try AgentDefinitionInMemorySyncBackend()
        let runtime = AgentDefinitionSyncRuntime(
            baseDirectory: fixture.baseURL,
            defaultsSuiteName: fixture.suiteName,
            backend: backend
        )
        let deviceID = (await runtime.snapshot()).deviceID
        let preset = try AgentSyncedProviderPreset(
            name: "Local provider",
            providerID: "OpenAI",
            model: "test-model",
            endpointIdentity: "https://api.example.test/v1/chat/completions"
        )
        let envelope = try AgentDefinitionSyncEnvelope(
            payload: .providerPreset(preset),
            modifiedByDeviceID: deviceID
        )

        #expect(try await runtime.publish(envelope) == .uploaded(
            recordName: envelope.recordName
        ))
        #expect(await backend.saveCallCount() == 1)
        _ = try await runtime.refresh()

        let reopened = AgentDefinitionSyncRuntime(
            baseDirectory: fixture.baseURL,
            defaultsSuiteName: fixture.suiteName,
            backend: backend
        )
        let snapshot = await reopened.snapshot()
        #expect(snapshot.definitionsByRecordName[envelope.recordName] == envelope)
        #expect(snapshot.preferences.providerPresets)

        let cacheURL = fixture.baseURL
            .appendingPathComponent("agent/definition-sync/definitions-v1.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let cacheText = try String(contentsOf: cacheURL, encoding: .utf8)
        #expect(!cacheText.localizedCaseInsensitiveContains("authorization"))
        #expect(!cacheText.localizedCaseInsensitiveContains("bearer"))
        #expect(!cacheText.localizedCaseInsensitiveContains("apiKey"))
    }

    @Test("Disabled categories retain local definitions without uploading")
    func disabledCategorySuppressesWrite() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let backend = try AgentDefinitionInMemorySyncBackend()
        let runtime = AgentDefinitionSyncRuntime(
            baseDirectory: fixture.baseURL,
            defaultsSuiteName: fixture.suiteName,
            backend: backend
        )
        let preset = try AgentSyncedProviderPreset(
            name: "Offline preset",
            providerID: "LM Studio",
            model: "local-model",
            endpointIdentity: "http://127.0.0.1:1234/v1/chat/completions",
            requiresLocalProviderAccess: false
        )
        let envelope = try AgentDefinitionSyncEnvelope(
            payload: .providerPreset(preset),
            modifiedByDeviceID: (await runtime.snapshot()).deviceID
        )
        #expect(try await runtime.publish(envelope) == .suppressed(
            .categoryDisabled(.providerPresets)
        ))
        #expect(await backend.saveCallCount() == 0)
        #expect((await runtime.snapshot()).definitionsByRecordName[envelope.recordName] == envelope)
    }

    @Test("Delete-cloud keeps a durable local payload and re-enable republishes above the tombstone")
    func deleteCloudRetainsAndRecreatesLocalPayload() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let defaults = try fixture.makeDefaults()
        defaults.set(true, forKey: AgentDefinitionSyncSettings.Key.providerPresets)
        let backend = try AgentDefinitionInMemorySyncBackend()
        let runtime = AgentDefinitionSyncRuntime(
            baseDirectory: fixture.baseURL,
            defaultsSuiteName: fixture.suiteName,
            backend: backend
        )
        let preset = try AgentSyncedProviderPreset(
            id: UUID(uuidString: "AAAAAAAA-1111-4111-8111-AAAAAAAAAAAA")!,
            revision: 1,
            name: "Retained provider",
            providerID: "compatible",
            model: "model-a",
            endpointIdentity: "https://models.example/v1",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        _ = try await runtime.publishLocalPayload(
            .providerPreset(preset),
            at: Date(timeIntervalSince1970: 1_000)
        )

        let receipt = try await runtime.disable(
            .providerPresets,
            disposition: .deleteCloudCopies
        )
        #expect(receipt.cloudTombstones.first?.revision == 2)
        let disabled = await runtime.snapshot()
        #expect(disabled.preferences.providerPresets == false)
        #expect(disabled.definitionsByRecordName.values.first?.payload == .providerPreset(preset))
        #expect(disabled.localOnlyDefinitionsByRecordName.values.first?.payload == .providerPreset(preset))
        let cloudTombstone = try #require(await backend.storedRecords().first)
        #expect(try AgentDefinitionCloudRecordCodec.decode(cloudTombstone).isTombstone)

        let reopened = AgentDefinitionSyncRuntime(
            baseDirectory: fixture.baseURL,
            defaultsSuiteName: fixture.suiteName,
            backend: backend
        )
        #expect((await reopened.snapshot()).localOnlyDefinitionsByRecordName.count == 1)
        _ = try await reopened.setEnabled(true, category: .providerPresets)
        let enabled = await reopened.snapshot()
        let recreated = try #require(enabled.definitionsByRecordName.values.first)
        #expect(enabled.preferences.providerPresets)
        #expect(enabled.localOnlyDefinitionsByRecordName.isEmpty)
        #expect(!recreated.isTombstone)
        #expect(recreated.revision == 3)
        guard case .providerPreset(let recreatedPreset)? = recreated.payload else {
            Issue.record("Expected the retained provider payload to be recreated")
            return
        }
        #expect(recreatedPreset.model == "model-a")
    }

    @Test("Local provider and memory edits increase revisions without repeated unchanged writes")
    func localProjectionRevisionPlanning() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let defaults = try fixture.makeDefaults()
        defaults.set(true, forKey: AgentDefinitionSyncSettings.Key.providerPresets)
        defaults.set(true, forKey: AgentDefinitionSyncSettings.Key.userAuthoredMemory)
        let backend = try AgentDefinitionInMemorySyncBackend()
        let runtime = AgentDefinitionSyncRuntime(
            baseDirectory: fixture.baseURL,
            defaultsSuiteName: fixture.suiteName,
            backend: backend
        )
        let providerID = UUID(uuidString: "BBBBBBBB-1111-4111-8111-BBBBBBBBBBBB")!
        let first = try AgentSyncedProviderPreset(
            id: providerID,
            name: "Provider",
            providerID: "compatible",
            model: "model-a",
            endpointIdentity: "https://models.example/v1"
        )
        _ = try await runtime.publishLocalPayload(.providerPreset(first))
        #expect(try await runtime.publishLocalPayload(.providerPreset(first)) == nil)
        let changed = try AgentSyncedProviderPreset(
            id: providerID,
            name: "Provider",
            providerID: "compatible",
            model: "model-b",
            endpointIdentity: "https://models.example/v1"
        )
        _ = try await runtime.publishLocalPayload(.providerPreset(changed))

        let memoryID = UUID(uuidString: "CCCCCCCC-1111-4111-8111-CCCCCCCCCCCC")!
        let memory = try AgentSyncedUserMemory(
            id: memoryID,
            text: "Prefer concise answers",
            scope: .global,
            sensitivity: .preference
        )
        _ = try await runtime.publishLocalPayload(.userAuthoredMemory(memory))
        let editedMemory = try AgentSyncedUserMemory(
            id: memoryID,
            text: "Prefer detailed answers",
            scope: .global,
            sensitivity: .sensitive,
            expiresAt: Date().addingTimeInterval(3_600)
        )
        _ = try await runtime.publishLocalPayload(.userAuthoredMemory(editedMemory))

        let records = try await backend.storedRecords().map(
            AgentDefinitionCloudRecordCodec.decode
        )
        let providerEnvelope = try #require(records.first {
            $0.definitionID == providerID
        })
        let memoryEnvelope = try #require(records.first {
            $0.definitionID == memoryID
        })
        #expect(providerEnvelope.revision == 2)
        #expect(memoryEnvelope.revision == 2)
        #expect(await backend.saveCallCount() == 4)
    }

    @Test("Re-enable retains a newer non-deleted cloud edit")
    func reenableDoesNotOverwriteNewerCloudEdit() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let defaults = try fixture.makeDefaults()
        defaults.set(true, forKey: AgentDefinitionSyncSettings.Key.providerPresets)
        let backend = try AgentDefinitionInMemorySyncBackend()
        let runtime = AgentDefinitionSyncRuntime(
            baseDirectory: fixture.baseURL,
            defaultsSuiteName: fixture.suiteName,
            backend: backend
        )
        let providerID = UUID(uuidString: "EEEEEEEE-1111-4111-8111-EEEEEEEEEEEE")!
        let local = try AgentSyncedProviderPreset(
            id: providerID,
            revision: 1,
            name: "Provider",
            providerID: "compatible",
            model: "model-local",
            endpointIdentity: "https://models.example/v1",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        _ = try await runtime.publishLocalPayload(
            .providerPreset(local),
            at: Date(timeIntervalSince1970: 1_000)
        )
        _ = try await runtime.disable(
            .providerPresets,
            disposition: .keepLocalCopies
        )

        let remote = try AgentSyncedProviderPreset(
            id: providerID,
            revision: 2,
            name: "Provider",
            providerID: "compatible",
            model: "model-remote",
            endpointIdentity: "https://models.example/v1",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let remoteEnvelope = try AgentDefinitionSyncEnvelope(
            payload: .providerPreset(remote),
            modifiedAt: Date(timeIntervalSince1970: 2_000),
            modifiedByDeviceID: "remote-mac"
        )
        try await backend.save([
            AgentDefinitionCloudRecordCodec.encode(remoteEnvelope)
        ])

        _ = try await runtime.setEnabled(true, category: .providerPresets)
        let enabled = await runtime.snapshot()
        let winner = try #require(
            enabled.definitionsByRecordName[remoteEnvelope.recordName]
        )
        #expect(winner == remoteEnvelope)
        #expect(enabled.localOnlyDefinitionsByRecordName.isEmpty)
        #expect(await backend.saveCallCount() == 2)
    }

    @Test("Synced task uninstall preserves history and same-revision reinstall")
    func syncedTaskUninstallPreservesHistory() async throws {
        let task = try makeTask()
        let engine = try AgentScheduledTaskEngine()
        try await engine.register(task)
        let before = await engine.snapshot()
        let state = try #require(before.runtimeStates.first)

        await engine.uninstallSyncedTaskRetainingHistory(task.id)
        let uninstalled = await engine.snapshot()
        #expect(uninstalled.definitions.isEmpty)
        #expect(uninstalled.deletionTombstones.isEmpty)
        #expect(uninstalled.runtimeStates.first == state)

        let reopened = try AgentScheduledTaskEngine(snapshot: uninstalled)
        #expect((await reopened.snapshot()).runtimeStates.first == state)
        try await reopened.register(task)
        let reinstalled = await reopened.snapshot()
        #expect(reinstalled.definitions == [task])
        #expect(reinstalled.runtimeStates.first == state)
    }

    @Test("A higher-revision memory tombstone disables retrieval but retains the local payload")
    @MainActor
    func memoryTombstoneDisablesRetainedPayload() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let defaults = try fixture.makeDefaults()
        defaults.set(true, forKey: AgentMemorySettings.Key.enabled)
        defaults.set(
            true,
            forKey: AgentDefinitionSyncSettings.Key.userAuthoredMemory
        )
        let runtime = AgentDefinitionSyncRuntime(
            baseDirectory: fixture.baseURL,
            defaultsSuiteName: fixture.suiteName,
            backend: try AgentDefinitionInMemorySyncBackend()
        )
        let memoryController = AgentMemoryController(
            baseDirectory: fixture.baseURL,
            defaults: defaults
        )
        let service = AgentDefinitionSyncService(
            defaults: defaults,
            runtime: runtime,
            dependencyResolver: StubDependencyResolver(),
            memoryController: memoryController
        )
        let memoryID = UUID(
            uuidString: "ABABABAB-1111-4111-8111-ABABABABABAB"
        )!
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let memory = try AgentSyncedUserMemory(
            id: memoryID,
            revision: 1,
            text: "Prefer concise deployment reports",
            scope: .global,
            sensitivity: .preference,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let liveEnvelope = try AgentDefinitionSyncEnvelope(
            payload: .userAuthoredMemory(memory),
            modifiedAt: createdAt,
            modifiedByDeviceID: "remote-mac"
        )
        let preferences = AgentDefinitionSyncPreferences(
            userAuthoredMemory: true
        )

        try await service.activate(AgentDefinitionSyncRuntimeSnapshot(
            definitionsByRecordName: [liveEnvelope.recordName: liveEnvelope],
            localOnlyDefinitionsByRecordName: [:],
            preferences: preferences,
            deviceID: "receiving-mac"
        ))
        let enabled = try #require(memoryController.entries.first {
            $0.id == memoryID
        })
        #expect(enabled.isEnabled)
        #expect(await memoryController.retrieve(
            runID: UUID(),
            stepID: nil,
            conversationID: nil,
            taskID: nil,
            pageURL: "https://example.com/",
            browserSession: .normal,
            query: "deployment reports"
        )?.entries.map(\.id) == [memoryID])

        let tombstone = try AgentDefinitionSyncEnvelope.tombstone(
            category: .userAuthoredMemory,
            definitionID: memoryID,
            revision: 2,
            modifiedAt: createdAt.addingTimeInterval(1),
            modifiedByDeviceID: "remote-mac"
        )
        try await service.activate(AgentDefinitionSyncRuntimeSnapshot(
            definitionsByRecordName: [tombstone.recordName: tombstone],
            localOnlyDefinitionsByRecordName: [:],
            preferences: preferences,
            deviceID: "receiving-mac"
        ))

        let retained = try #require(memoryController.entries.first {
            $0.id == memoryID
        })
        #expect(retained.text == memory.text)
        #expect(!retained.isEnabled)
        #expect(await memoryController.retrieve(
            runID: UUID(),
            stepID: nil,
            conversationID: nil,
            taskID: nil,
            pageURL: "https://example.com/",
            browserSession: .normal,
            query: "deployment reports"
        )?.entries.isEmpty == true)
    }

    @Test("Synced schedules install only with live dependencies and uninstall on dependency or authorization revocation")
    @MainActor
    func scheduleActivationTracksLocalDependenciesAndAuthorization() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let defaults = try fixture.makeDefaults()
        defaults.set(true, forKey: AgentDefinitionSyncSettings.Key.schedules)
        defaults.set(true, forKey: AgentDefinitionSyncSettings.Key.providerPresets)
        let backend = try AgentDefinitionInMemorySyncBackend()
        let runtime = AgentDefinitionSyncRuntime(
            baseDirectory: fixture.baseURL,
            defaultsSuiteName: fixture.suiteName,
            backend: backend
        )
        let providerID = UUID(
            uuidString: "ACACACAC-1111-4111-8111-ACACACACACAC"
        )!
        let scheduleID = UUID(
            uuidString: "ADADADAD-1111-4111-8111-ADADADADADAD"
        )!
        let mcpID = UUID(
            uuidString: "AEAEAEAE-1111-4111-8111-AEAEAEAEAEAE"
        )!
        let coworkID = UUID(
            uuidString: "AFAFAFAF-1111-4111-8111-AFAFAFAFAFAF"
        )!
        let browserSessionID = UUID(
            uuidString: "B0B0B0B0-1111-4111-8111-B0B0B0B0B0B0"
        )!
        let provider = try AgentSyncedProviderPreset(
            id: providerID,
            name: "Local provider",
            providerID: BrowserAgentProvider.ollama.rawValue,
            model: "fixture-model",
            endpointIdentity: BrowserAgentProvider.ollama.defaultEndpoint,
            requiresLocalProviderAccess: false
        )
        let task = try AgentTaskDefinition(
            id: scheduleID,
            name: "Dependency-gated schedule",
            prompt: "Summarize the selected workspace",
            schedule: .daily(hour: 9, minute: 30),
            timeZoneIdentifier: "Europe/Amsterdam",
            daylightSavingPolicy: AgentTaskDaylightSavingPolicy(
                nonexistentTime: .nextValidTime,
                repeatedTime: .firstOccurrence
            ),
            execution: AgentTaskExecutionSnapshot(
                provider: provider.providerSnapshot,
                browserScope: AgentTaskBrowserScope(
                    origins: ["https://example.com"],
                    session: .container(browserSessionID)
                ),
                capabilities: [.pageRead, .coworkRead, .externalMCP],
                mcpConnectionIDs: [mcpID],
                coworkRootID: coworkID
            ),
            budgets: AgentTaskBudgets(
                maximumModelTurns: 8,
                maximumToolCalls: 24,
                maximumOutputBytes: 1_000_000,
                maximumOpenBackgroundPages: 2,
                maximumArtifactBytes: 4_000_000
            ),
            timeoutSeconds: 300,
            concurrencyPolicy: .serialize,
            retentionPolicy: .days7,
            catchUpPolicy: .skip,
            notificationPolicy: AgentTaskNotificationPolicy()
        )
        let schedule = try AgentSyncedScheduleDefinition(
            definition: task,
            providerPresetID: providerID
        )
        let deviceID = (await runtime.snapshot()).deviceID
        let providerEnvelope = try AgentDefinitionSyncEnvelope(
            payload: .providerPreset(provider),
            modifiedByDeviceID: deviceID
        )
        let scheduleEnvelope = try AgentDefinitionSyncEnvelope(
            payload: .schedule(schedule),
            modifiedByDeviceID: deviceID
        )
        _ = try await runtime.publish(providerEnvelope)
        _ = try await runtime.publish(scheduleEnvelope)
        defaults.set(
            [scheduleID.uuidString],
            forKey: AgentDefinitionSyncService.Key.authorizedScheduleIDs
        )
        let resolver = StubDependencyResolver(
            dependencies: AgentDefinitionResolvedLocalDependencies(
                trustedMCPConnectionIDs: [mcpID],
                authorizedCoworkRootIDs: [coworkID],
                availableBrowserSessionIDs: [browserSessionID]
            )
        )
        let memoryController = AgentMemoryController(
            baseDirectory: fixture.baseURL,
            defaults: defaults
        )
        let service = AgentDefinitionSyncService(
            defaults: defaults,
            runtime: runtime,
            dependencyResolver: resolver,
            memoryController: memoryController
        )
        var installed: [UUID] = []
        var uninstalled: [UUID] = []
        service.registerScheduleInstaller(
            { installed.append($0.id) },
            uninstaller: { uninstalled.append($0) }
        )

        await service.localDependenciesChanged()
        #expect(installed == [scheduleID])
        #expect(uninstalled.isEmpty)
        #expect(service.unavailableSchedules[scheduleID] == nil)

        resolver.dependencies.trustedMCPConnectionIDs.remove(mcpID)
        await service.localDependenciesChanged()
        #expect(uninstalled == [scheduleID])
        #expect(service.unavailableSchedules[scheduleID]?.reasons.contains(
            .missingMCPConnection(mcpID)
        ) == true)

        resolver.dependencies.trustedMCPConnectionIDs.insert(mcpID)
        await service.localDependenciesChanged()
        #expect(installed == [scheduleID, scheduleID])

        await service.revokeCoworkRootAuthorization(for: scheduleID)
        #expect(uninstalled == [scheduleID, scheduleID])
        #expect(service.unavailableSchedules[scheduleID]?.reasons.contains(
            .missingCoworkScope(coworkID)
        ) == true)
        #expect(await service.authorizeCurrentCoworkRoot(for: scheduleID))
        #expect(installed == [scheduleID, scheduleID, scheduleID])

        resolver.dependencies.availableBrowserSessionIDs.remove(browserSessionID)
        await service.localDependenciesChanged()
        #expect(uninstalled == [scheduleID, scheduleID, scheduleID])
        #expect(service.unavailableSchedules[scheduleID]?.reasons.contains(
            .missingBrowserSession(browserSessionID)
        ) == true)
        resolver.dependencies.availableBrowserSessionIDs.insert(browserSessionID)
        await service.localDependenciesChanged()
        #expect(installed == [scheduleID, scheduleID, scheduleID, scheduleID])

        await service.revokeScheduleAuthorization(scheduleID)
        #expect(uninstalled == [scheduleID, scheduleID, scheduleID, scheduleID])
        #expect(service.unavailableSchedules[scheduleID]?.reasons.contains(
            .scheduledPolicyNotSatisfied
        ) == true)
    }

    private func makeTask() throws -> AgentTaskDefinition {
        try AgentTaskDefinition(
            id: UUID(uuidString: "DDDDDDDD-1111-4111-8111-DDDDDDDDDDDD")!,
            revision: 4,
            name: "Imported schedule",
            prompt: "Summarize updates",
            enabled: true,
            schedule: .daily(hour: 9, minute: 0),
            timeZoneIdentifier: "Europe/Amsterdam",
            daylightSavingPolicy: AgentTaskDaylightSavingPolicy(
                nonexistentTime: .nextValidTime,
                repeatedTime: .firstOccurrence
            ),
            execution: AgentTaskExecutionSnapshot(
                provider: AgentProviderSnapshot(
                    providerID: "compatible",
                    model: "model-a",
                    endpointIdentity: "https://models.example/v1"
                ),
                browserScope: AgentTaskBrowserScope(origins: ["https://example.com"]),
                capabilities: [.pageRead]
            ),
            budgets: AgentTaskBudgets(
                maximumModelTurns: 8,
                maximumToolCalls: 24,
                maximumOutputBytes: 1_000_000,
                maximumOpenBackgroundPages: 2,
                maximumArtifactBytes: 4_000_000
            ),
            timeoutSeconds: 300,
            concurrencyPolicy: .serialize,
            retentionPolicy: .days7,
            catchUpPolicy: .skip,
            notificationPolicy: AgentTaskNotificationPolicy(),
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
    }

    @MainActor
    private final class StubDependencyResolver:
        AgentDefinitionLocalDependencyResolving
    {
        var dependencies: AgentDefinitionResolvedLocalDependencies
        private let changesSubject = PassthroughSubject<Void, Never>()

        var changes: AnyPublisher<Void, Never> {
            changesSubject.eraseToAnyPublisher()
        }

        init(
            dependencies: AgentDefinitionResolvedLocalDependencies = .unavailable
        ) {
            self.dependencies = dependencies
        }

        func resolve() async -> AgentDefinitionResolvedLocalDependencies {
            dependencies
        }

        func authorizeCurrentCoworkRoot(for dependencyID: UUID) -> Bool {
            dependencies.authorizedCoworkRootIDs.insert(dependencyID)
            return true
        }

        func revokeCoworkRootAuthorization(for dependencyID: UUID) {
            dependencies.authorizedCoworkRootIDs.remove(dependencyID)
        }
    }

    private struct Fixture {
        let baseURL: URL
        let suiteName: String

        init() throws {
            baseURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("agent-definition-runtime-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
            suiteName = "AgentDefinitionSyncRuntimeTests.\(UUID().uuidString)"
            try #require(UserDefaults(suiteName: suiteName))
                .removePersistentDomain(forName: suiteName)
        }

        func makeDefaults() throws -> UserDefaults {
            try #require(UserDefaults(suiteName: suiteName))
        }

        func cleanup() {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: baseURL)
        }
    }
}
