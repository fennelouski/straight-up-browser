import Foundation
import CloudKit
import Testing
@testable import Browser

@Suite("Universal iOS contracts")
struct BrowserIOSContractTests {
    @Test("The omnibar distinguishes addresses from searches")
    func omnibarResolutionIsDeterministic() {
        #expect(OmnibarInput.resolve("  ", searchEngine: nil) == nil)
        #expect(
            OmnibarInput.resolve("example.com/path", searchEngine: nil)
                == "https://example.com/path"
        )
        #expect(
            OmnibarInput.resolve("https://example.com/path", searchEngine: nil)
                == "https://example.com/path"
        )
        #expect(
            OmnibarInput.resolve("straight up browser", searchEngine: "DuckDuckGo")
                == "https://duckduckgo.com/?q=straight%20up%20browser"
        )
    }

    @MainActor
    @Test("Incognito visits never enter mobile browsing history")
    func incognitoHistoryStaysOutOfMemoryAndDisk() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-private-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = BrowsingHistoryStore(storeURL: storeURL)

        store.record(
            url: URL(string: "https://private.example/never-store")!,
            title: "Private",
            sessionKind: .incognito
        )

        #expect(store.visits.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: storeURL.path))
    }

    @Test("Agent definition categories remain independently opt in")
    func definitionSyncPreferencesRoundTripIndependently() throws {
        let suiteName = "BrowserIOSContractTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AgentDefinitionSyncPreferences(
            schedules: true,
            providerPresets: false,
            userAuthoredMemory: true
        )

        AgentDefinitionSyncSettings.save(preferences, to: defaults)
        let restored = AgentDefinitionSyncSettings.preferences(from: defaults)

        #expect(restored == preferences)
        #expect(restored.isEnabled(.schedules))
        #expect(!restored.isEnabled(.providerPresets))
        #expect(restored.isEnabled(.userAuthoredMemory))
    }

    @Test("CloudKit availability fails closed before resolving a container")
    func cloudKitAvailabilityRequiresTheExactEntitlement() async {
        let unavailable = await TabSync.iCloudAvailable(
            effectiveContainerIdentifiers: [],
            accountStatus: {
                Issue.record("The CloudKit resolver must stay lazy without an entitlement")
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

    @Test("Provider sync records use the secret-free allowlist")
    func providerPresetWireShapeContainsNoCredentialFields() throws {
        let preset = try AgentSyncedProviderPreset(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            name: "Mobile review fixture",
            providerID: "openai-compatible",
            model: "fixture-model",
            endpointIdentity: "https://models.example/v1",
            requiresLocalProviderAccess: true,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let envelope = try AgentDefinitionSyncEnvelope(
            payload: .providerPreset(preset),
            modifiedByDeviceID: "ios-fixture"
        )

        let record = try AgentDefinitionCloudRecordCodec.encode(envelope)
        let encoded = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
            .lowercased()

        #expect(Set(record.fields.keys) == AgentDefinitionCloudRecordCodec.allowedFieldNames)
        #expect(!encoded.contains("apikey"))
        #expect(!encoded.contains("api_key"))
        #expect(!encoded.contains("bearer"))
        #expect(!encoded.contains("password"))
        #expect(!encoded.contains("refreshtoken"))
        #expect(try AgentDefinitionCloudRecordCodec.decode(record) == envelope)
    }

    @Test("iPhone and iPad retain imported schedules but never execute them")
    func importedScheduleFailsClosedOnMobile() throws {
        let presetID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let preset = try AgentSyncedProviderPreset(
            id: presetID,
            name: "Mobile review fixture",
            providerID: "openai-compatible",
            model: "fixture-model",
            endpointIdentity: "https://models.example/v1",
            requiresLocalProviderAccess: false,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let task = try makeTask()
        let schedule = try AgentSyncedScheduleDefinition(
            definition: task,
            providerPresetID: presetID
        )
        let envelope = try AgentDefinitionSyncEnvelope(
            payload: .schedule(schedule),
            modifiedByDeviceID: "ios-fixture"
        )
        for platform in [
            AgentDefinitionDevicePlatform.iOS,
            AgentDefinitionDevicePlatform.iPadOS,
        ] {
            let device = AgentDefinitionDeviceCapabilities(
                deviceID: "mobile-fixture",
                platform: platform,
                installedProviderPresetIDs: [presetID],
                providerPresetIDsWithLocalAccess: [presetID],
                supportedCapabilities: [.pageRead],
                policyGrantedScheduledCapabilities: [.pageRead],
                scheduledExecutionPolicySatisfied: true
            )

            let decision = try AgentDefinitionActivationGate.evaluate(
                envelope,
                providerPresets: [presetID: preset],
                preferences: AgentDefinitionSyncPreferences(schedules: true),
                device: device
            )

            guard case .unavailable(let availability) = decision else {
                Issue.record("\(platform.rawValue) must not receive an execution permit")
                continue
            }
            #expect(availability.retainOnDevice)
            #expect(!availability.mayRun)
            #expect(availability.reasons.contains(.unsupportedPlatform(platform)))
        }
    }

    private func makeTask() throws -> AgentTaskDefinition {
        try AgentTaskDefinition(
            id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            revision: 1,
            name: "Mobile retained schedule",
            prompt: "Summarize product updates",
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
                    endpointIdentity: "https://models.example/v1"
                ),
                browserScope: AgentTaskBrowserScope(
                    origins: ["https://example.com"],
                    session: .normal
                ),
                capabilities: [.pageRead]
            ),
            budgets: AgentTaskBudgets(
                maximumModelTurns: 5,
                maximumToolCalls: 10,
                maximumOutputBytes: 100_000,
                maximumOpenBackgroundPages: 1,
                maximumArtifactBytes: 1_000_000
            ),
            timeoutSeconds: 300,
            concurrencyPolicy: .serialize,
            retentionPolicy: .days7,
            catchUpPolicy: .runLatest,
            notificationPolicy: AgentTaskNotificationPolicy(),
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}
