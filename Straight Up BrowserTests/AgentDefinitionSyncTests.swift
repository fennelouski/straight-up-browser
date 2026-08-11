import Foundation
import Testing
#if canImport(CloudKit)
import CloudKit
#endif
@testable import Browser

struct AgentDefinitionSyncTests {
    #if canImport(CloudKit)
    @Test func cloudKitBackendConstructionDoesNotResolveTheContainer() {
        _ = CloudKitAgentDefinitionSyncBackend()
    }

    @Test func cloudKitAvailabilityFailsClosedBeforeContainerResolution() async {
        let unavailable = await TabSync.iCloudAvailable(
            effectiveContainerIdentifiers: [],
            accountStatus: {
                Issue.record("CloudKit must not resolve without its entitlement")
                return .available
            }
        )
        #expect(!unavailable)

        let available = await TabSync.iCloudAvailable(
            effectiveContainerIdentifiers: [TabSync.containerID],
            accountStatus: { .available }
        )
        #expect(available)
    }
    #endif

    @Test func providerPresetCloudRecordHasAnAllowlistedSecretFreeShape() throws {
        let presetID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let preset = try AgentSyncedProviderPreset(
            id: presetID,
            revision: 1,
            name: "Private model",
            providerID: "openai-compatible",
            model: "fixture-model",
            endpointIdentity: "https://models.example/v1",
            reportsUsage: true,
            supportsStreaming: true,
            requiresLocalProviderAccess: true,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let envelope = try AgentDefinitionSyncEnvelope(
            payload: .providerPreset(preset),
            modifiedByDeviceID: "mac-a"
        )

        let record = try AgentDefinitionCloudRecordCodec.encode(envelope)
        let encoded = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
            .lowercased()

        #expect(record.recordName == "agent-definition.provider-preset.\(presetID.uuidString.lowercased())")
        #expect(Set(record.fields.keys) == AgentDefinitionCloudRecordCodec.allowedFieldNames)
        #expect(!encoded.contains("apikey"))
        #expect(!encoded.contains("api_key"))
        #expect(!encoded.contains("bearer"))
        #expect(!encoded.contains("oauthtoken"))
        #expect(!encoded.contains("refreshtoken"))
        #expect(!encoded.contains("password"))
        #expect(!encoded.contains("bookmarkdata"))
        #expect(!encoded.contains("runid"))
        #expect(!encoded.contains("transcript"))
        #expect(try AgentDefinitionCloudRecordCodec.decode(record) == envelope)
    }

    @Test func scheduleProjectionRejectsPageHandlesAndKeepsOccurrenceIdentityStable() throws {
        let presetID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let pageBound = try makeTask(pageIDs: ["window-id:tab-id"])
        #expect(throws: AgentDefinitionSyncError.prohibitedField("pageHandles")) {
            _ = try AgentSyncedScheduleDefinition(
                definition: pageBound,
                providerPresetID: presetID
            )
        }

        let local = try makeTask()
        let synced = try AgentSyncedScheduleDefinition(
            definition: local,
            providerPresetID: presetID
        )
        let envelope = try AgentDefinitionSyncEnvelope(
            payload: .schedule(synced),
            modifiedByDeviceID: "mac-a"
        )
        let record = try AgentDefinitionCloudRecordCodec.encode(envelope)
        let encoded = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
            .lowercased()
        let scheduledAt = Date(timeIntervalSince1970: 5_000)

        #expect(!encoded.contains("pagehandles"))
        #expect(!encoded.contains("pageids"))
        #expect(!encoded.contains("incognito"))
        #expect(!encoded.contains("bookmarkdata"))
        #expect(synced.occurrenceID(scheduledAt: scheduledAt) ==
            AgentTaskOccurrenceID(
                taskID: local.id,
                definitionRevision: local.revision,
                scheduledAt: scheduledAt
            ))
    }

    @Test func receivingDeviceRetainsUnsupportedScheduleButCannotRunWithoutEveryLocalGate() throws {
        let presetID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let mcpID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let coworkID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let schedule = try AgentSyncedScheduleDefinition(
            definition: makeTask(),
            providerPresetID: presetID
        )
        let envelope = try AgentDefinitionSyncEnvelope(
            payload: .schedule(schedule),
            modifiedByDeviceID: "mac-a"
        )
        let preset = try AgentSyncedProviderPreset(
            id: presetID,
            name: "Private model",
            providerID: "openai-compatible",
            model: "fixture-model",
            endpointIdentity: "https://models.example/v1"
        )
        let preferences = AgentDefinitionSyncPreferences(schedules: true)

        let ipad = AgentDefinitionDeviceCapabilities(
            deviceID: "ipad-a",
            platform: .iPadOS,
            installedProviderPresetIDs: [presetID],
            providerPresetIDsWithLocalAccess: [presetID],
            trustedMCPConnectionIDs: [mcpID],
            authorizedCoworkRootIDs: [coworkID],
            supportedCapabilities: [.pageRead],
            policyGrantedScheduledCapabilities: [.pageRead],
            scheduledExecutionPolicySatisfied: true
        )
        let ipadDecision = try AgentDefinitionActivationGate.evaluate(
            envelope,
            providerPresets: [presetID: preset],
            preferences: preferences,
            device: ipad
        )
        guard case .unavailable(let ipadAvailability) = ipadDecision else {
            Issue.record("iPadOS must not execute macOS-only automation")
            return
        }
        #expect(ipadAvailability.retainOnDevice)
        #expect(!ipadAvailability.mayRun)
        #expect(ipadAvailability.reasons.contains(.unsupportedPlatform(.iPadOS)))

        let unpreparedMac = AgentDefinitionDeviceCapabilities(
            deviceID: "mac-b",
            platform: .macOS,
            supportedCapabilities: [.pageRead]
        )
        let blocked = try AgentDefinitionActivationGate.evaluate(
            envelope,
            providerPresets: [presetID: preset],
            preferences: preferences,
            device: unpreparedMac
        )
        guard case .unavailable(let blockedAvailability) = blocked else {
            Issue.record("A receiving Mac must satisfy local dependencies and policy")
            return
        }
        #expect(blockedAvailability.reasons.contains(.missingProviderPreset(presetID)))
        #expect(blockedAvailability.reasons.contains(.missingLocalProviderAccess(presetID)))
        #expect(blockedAvailability.reasons.contains(.missingMCPConnection(mcpID)))
        #expect(blockedAvailability.reasons.contains(.missingCoworkScope(coworkID)))
        #expect(blockedAvailability.reasons.contains(.capabilityNotGranted(.pageRead)))
        #expect(blockedAvailability.reasons.contains(.scheduledPolicyNotSatisfied))

        let preparedMac = AgentDefinitionDeviceCapabilities(
            deviceID: "mac-c",
            platform: .macOS,
            installedProviderPresetIDs: [presetID],
            providerPresetIDsWithLocalAccess: [presetID],
            trustedMCPConnectionIDs: [mcpID],
            authorizedCoworkRootIDs: [coworkID],
            supportedCapabilities: [.pageRead],
            policyGrantedScheduledCapabilities: [.pageRead],
            scheduledExecutionPolicySatisfied: true
        )
        let ready = try AgentDefinitionActivationGate.evaluate(
            envelope,
            providerPresets: [presetID: preset],
            preferences: preferences,
            device: preparedMac
        )
        guard case .runnable(let permit) = ready else {
            Issue.record("All local gates should issue a narrowly bound permit")
            return
        }
        let materialized = try AgentDefinitionActivationGate.materialize(
            envelope,
            providerPreset: preset,
            permit: permit
        )
        #expect(materialized.id == schedule.id)
        #expect(materialized.execution.browserScope.pageIDs.isEmpty)
        #expect(materialized.execution.provider == preset.providerSnapshot)
    }

    @Test func categoryTogglesGateBackendWritesAndDisableOffersBothDataChoices() async throws {
        let provider = try AgentSyncedProviderPreset(
            id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!,
            name: "Private model",
            providerID: "openai-compatible",
            model: "fixture-model",
            endpointIdentity: "https://models.example/v1"
        )
        let envelope = try AgentDefinitionSyncEnvelope(
            payload: .providerPreset(provider),
            modifiedByDeviceID: "mac-a"
        )
        let backend = try AgentDefinitionInMemorySyncBackend()
        let controller = AgentDefinitionSyncController(
            preferences: AgentDefinitionSyncPreferences(schedules: true),
            deviceID: "mac-a",
            backend: backend
        )

        #expect(try await controller.publish(envelope) ==
            .suppressed(.categoryDisabled(.providerPresets)))
        #expect(await backend.saveCallCount() == 0)

        await controller.setEnabled(true, for: .providerPresets)
        #expect(try await controller.publish(envelope) ==
            .uploaded(recordName: envelope.recordName))
        #expect(await backend.saveCallCount() == 1)

        let keepLocal = try await controller.disable(
            .providerPresets,
            disposition: .keepLocalCopies,
            knownLocalDefinitions: [envelope]
        )
        #expect(keepLocal.localAction == .retainAsLocalOnly)
        #expect(keepLocal.cloudTombstones.isEmpty)
        #expect(try await controller.publish(envelope) ==
            .suppressed(.categoryDisabled(.providerPresets)))
        #expect(await backend.saveCallCount() == 1)

        await controller.setEnabled(true, for: .providerPresets)
        let deleteCloud = try await controller.disable(
            .providerPresets,
            disposition: .deleteCloudCopies,
            knownLocalDefinitions: [envelope],
            at: Date(timeIntervalSince1970: 9_000)
        )
        let tombstone = try #require(deleteCloud.cloudTombstones.first)
        #expect(deleteCloud.localAction == .retainAsLocalOnly)
        #expect(tombstone.isTombstone)
        #expect(tombstone.definitionID == provider.id)
        #expect(tombstone.revision == envelope.revision + 1)
        #expect(await backend.saveCallCount() == 2)
        #expect(try await controller.publish(envelope) ==
            .suppressed(.categoryDisabled(.providerPresets)))
        #expect(await backend.saveCallCount() == 2)
    }

    @Test func conflictsAndTombstonesResolveDeterministicallyWithoutDuplicateDefinitions() throws {
        let id = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
        let at = Date(timeIntervalSince1970: 4_000)
        let left = try AgentSyncedProviderPreset(
            id: id,
            revision: 7,
            name: "Left edit",
            providerID: "compatible",
            model: "fixture-model",
            endpointIdentity: "https://models.example/v1",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: at
        )
        let right = try AgentSyncedProviderPreset(
            id: id,
            revision: 7,
            name: "Right edit",
            providerID: "compatible",
            model: "fixture-model",
            endpointIdentity: "https://models.example/v1",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: at
        )
        let a = try AgentDefinitionSyncEnvelope(
            payload: .providerPreset(left),
            modifiedAt: at,
            modifiedByDeviceID: "device-a"
        )
        let b = try AgentDefinitionSyncEnvelope(
            payload: .providerPreset(right),
            modifiedAt: at,
            modifiedByDeviceID: "device-b"
        )

        let ab = try AgentDefinitionConflictResolver.resolve(a, b)
        let ba = try AgentDefinitionConflictResolver.resolve(b, a)
        #expect(ab.winner == b)
        #expect(ba.winner == b)
        #expect(ab.reason == .deviceTieBreak)

        let tombstone = try AgentDefinitionSyncEnvelope.tombstone(
            category: .providerPresets,
            definitionID: id,
            revision: 7,
            modifiedAt: at.addingTimeInterval(-100),
            modifiedByDeviceID: "device-a"
        )
        #expect(try AgentDefinitionConflictResolver.resolve(b, tombstone).winner
            == tombstone)

        let newer = try AgentSyncedProviderPreset(
            id: id,
            revision: 8,
            name: "Explicitly recreated",
            providerID: "compatible",
            model: "fixture-model",
            endpointIdentity: "https://models.example/v1",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: at.addingTimeInterval(1)
        )
        let recreated = try AgentDefinitionSyncEnvelope(
            payload: .providerPreset(newer),
            modifiedByDeviceID: "device-c"
        )
        #expect(try AgentDefinitionConflictResolver.resolve(tombstone, recreated)
            .winner == recreated)

        let merged = try AgentDefinitionConflictResolver.merge(
            local: [a.recordName: a],
            remote: [b, tombstone, recreated]
        )
        #expect(merged.count == 1)
        #expect(merged[a.recordName] == recreated)
    }

    @Test func onlyUserAuthoredMemoryGetsAContentMinimalSyncProjection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-definition-memory-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentMemoryStore(directoryURL: directory)
        let userEntry = try await store.apply(
            proposal: AgentMemoryProposal(
                id: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!,
                text: "Prefer concise research summaries",
                scope: .global,
                sensitivity: .preference,
                provenance: .user(reason: "Saved in Memory settings"),
                proposedAt: Date(timeIntervalSince1970: 1_000)
            ),
            decision: .allow(reason: "Explicit user write"),
            at: Date(timeIntervalSince1970: 1_000)
        ).storedEntry
        let synced = try AgentSyncedUserMemory(entry: userEntry, revision: 3)
        let record = try AgentDefinitionCloudRecordCodec.encode(
            AgentDefinitionSyncEnvelope(
                payload: .userAuthoredMemory(synced),
                modifiedByDeviceID: "mac-a"
            )
        )
        let encoded = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
            .lowercased()

        #expect(!encoded.contains("provenance"))
        #expect(!encoded.contains("runid"))
        #expect(!encoded.contains("stepid"))
        #expect(!encoded.contains("conversationid"))
        #expect(!encoded.contains("consumption"))
        #expect(!encoded.contains("editrecord"))
        #expect(synced.proposal.provenance.kind == .user)

        let expiry = Date(timeIntervalSince1970: 9_000)
        _ = try await store.updateSyncedUserProjection(
            id: userEntry.id,
            text: "Prefer detailed research summaries",
            scope: .task(UUID(uuidString: "99999999-9999-4999-8999-999999999999")!),
            sessionScope: .allPersistentSessions,
            sensitivity: .sensitive,
            expiresAt: expiry,
            isEnabled: false,
            at: Date(timeIntervalSince1970: 2_000)
        )
        let updated = try await store.entry(id: userEntry.id)
        #expect(updated.text == "Prefer detailed research summaries")
        #expect(updated.sensitivity == .sensitive)
        #expect(updated.expiresAt == expiry)
        #expect(!updated.isEnabled)
        #expect(updated.scope == .task(
            UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
        ))

        let modelEntry = try await store.apply(
            proposal: AgentMemoryProposal(
                text: "The model inferred this preference",
                scope: .global,
                sensitivity: .preference,
                provenance: .modelProposal(
                    runID: UUID(),
                    reason: "Inferred by the model"
                ),
                proposedAt: Date(timeIntervalSince1970: 1_001)
            ),
            decision: .allow(reason: "Policy allowed local memory"),
            at: Date(timeIntervalSince1970: 1_001)
        ).storedEntry
        #expect(throws: AgentDefinitionSyncError.memoryWasNotUserAuthored) {
            _ = try AgentSyncedUserMemory(entry: modelEntry, revision: 1)
        }

        #expect(throws: AgentDefinitionSyncError.suspectedSecret(
            field: "userMemory.text"
        )) {
            _ = try AgentSyncedUserMemory(
                text: "api_key=do-not-sync-this",
                scope: .global,
                sensitivity: .sensitive
            )
        }
    }

    @Test func malformedCloudFieldsAndCredentialLikeDefinitionTextFailClosed() async throws {
        #expect(throws: AgentDefinitionSyncError.invalidEndpointIdentity) {
            _ = try AgentSyncedProviderPreset(
                name: "Unsafe",
                providerID: "compatible",
                model: "fixture-model",
                endpointIdentity: "https://user:password@models.example/v1"
            )
        }
        #expect(throws: AgentDefinitionSyncError.suspectedSecret(
            field: "schedule.prompt"
        )) {
            var task = try makeTask()
            task.prompt = "Call the service with authorization: bearer eyJ-secret"
            _ = try AgentSyncedScheduleDefinition(
                definition: task,
                providerPresetID: UUID()
            )
        }

        let provider = try AgentSyncedProviderPreset(
            name: "A private display name that logs must omit",
            providerID: "compatible",
            model: "private-model-name",
            endpointIdentity: "https://private-host.example/v1"
        )
        let envelope = try AgentDefinitionSyncEnvelope(
            payload: .providerPreset(provider),
            modifiedByDeviceID: "mac-a"
        )
        let validRecord = try AgentDefinitionCloudRecordCodec.encode(envelope)
        var maliciousFields = validRecord.fields
        maliciousFields["refreshToken"] = .string("must-not-enter-the-codec")
        let malicious = AgentDefinitionCloudRecord(
            recordType: validRecord.recordType,
            recordName: validRecord.recordName,
            fields: maliciousFields
        )
        #expect(throws: AgentDefinitionSyncError.unexpectedCloudFields([
            "refreshToken",
        ])) {
            _ = try AgentDefinitionCloudRecordCodec.decode(malicious)
        }

        let backend = try AgentDefinitionInMemorySyncBackend()
        let controller = AgentDefinitionSyncController(
            preferences: AgentDefinitionSyncPreferences(providerPresets: true),
            deviceID: "mac-a",
            backend: backend
        )
        _ = try await controller.publish(envelope)
        let logData = try JSONEncoder().encode(await controller.privacySafeLog())
        let log = String(decoding: logData, as: UTF8.self).lowercased()
        #expect(!log.contains(provider.name.lowercased()))
        #expect(!log.contains(provider.model.lowercased()))
        #expect(!log.contains(provider.endpointIdentity.lowercased()))
        #expect(!log.contains("payload"))
        #expect(!log.contains("secret"))
        #expect(!log.contains("prompt"))
        #expect(!log.contains("memory"))
    }

    private func makeTask(
        pageIDs: Set<String> = [],
        session: AgentBrowserSession = .normal,
        id: UUID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
        revision: Int = 4,
        updatedAt: Date = Date(timeIntervalSince1970: 2_000)
    ) throws -> AgentTaskDefinition {
        try AgentTaskDefinition(
            id: id,
            revision: revision,
            name: "Morning research",
            prompt: "Summarize the product updates",
            schedule: .daily(hour: 9, minute: 30),
            timeZoneIdentifier: "Europe/Amsterdam",
            daylightSavingPolicy: AgentTaskDaylightSavingPolicy(
                nonexistentTime: .nextValidTime,
                repeatedTime: .firstOccurrence
            ),
            execution: AgentTaskExecutionSnapshot(
                provider: AgentProviderSnapshot(
                    providerID: "openai-compatible",
                    model: "fixture-model",
                    endpointIdentity: "https://models.example/v1",
                    reportsUsage: true,
                    supportsStreaming: true
                ),
                browserScope: AgentTaskBrowserScope(
                    pageIDs: pageIDs,
                    origins: ["https://example.com"],
                    session: session
                ),
                capabilities: [.pageRead],
                mcpConnectionIDs: [
                    UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
                ],
                coworkRootID: UUID(
                    uuidString: "55555555-5555-4555-8555-555555555555"
                )!
            ),
            budgets: AgentTaskBudgets(
                maximumModelTurns: 10,
                maximumToolCalls: 20,
                maximumOutputBytes: 100_000,
                maximumOpenBackgroundPages: 2,
                maximumArtifactBytes: 1_000_000,
                maximumProviderCostMicrounits: 50_000
            ),
            timeoutSeconds: 300,
            concurrencyPolicy: .serialize,
            retentionPolicy: .days7,
            catchUpPolicy: .runLatest,
            notificationPolicy: AgentTaskNotificationPolicy(),
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: updatedAt
        )
    }
}
