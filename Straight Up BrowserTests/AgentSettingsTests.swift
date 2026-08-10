import Foundation
import Testing
@testable import Browser

@MainActor
struct AgentSettingsTests {
    @Test func agentPaneIsAFirstClassSettingsDestination() {
        #expect(SettingsPane.allCases.contains(.agent))
        #expect(SettingsPane.agent.rawValue == "agent")
        #expect(SettingsPane.agent.title == "Agent")
        #expect(SettingsPane.agent.systemImage == "sparkles")
        #expect(SettingsPane.agent.subtitle.contains("Models"))
        #expect(SettingsPane.agent.subtitle.contains("privacy"))
    }

    @Test func agentSettingsWriteOnlyKeysConsumedByProductionRuntimes() {
        let expected: Set<String> = [
            "browserAgentProvider",
            "browserAgentEndpoint",
            "browserAgentModel",
            "agentWebKitConsoleCaptureEnabled",
            "agentWebKitDiagnosticContentEnabled",
            "agent.memory.enabled",
            "agent.memory.allowSensitiveProposals",
            "agent.memory.maximumRetrievedEntries",
            "agent.memory.maximumRetrievedTokens",
            "agent.memory.retention",
            "agent.budget.maximumTurns",
            "agent.budget.maximumToolCalls",
            "agent.budget.maximumWallMinutes",
            "agent.budget.maximumProviderTokens",
            "agent.budget.maximumProviderCostMicrounits",
            "agent.budget.maximumOpenPages",
            "agent.budget.maximumModelResultMiB",
            "agent.budget.maximumDownloads",
            "agent.budget.maximumDownloadMiB",
            "agent.budget.maximumArtifacts",
            "agent.budget.maximumArtifactMiB",
            "agent.observability.localMetricsEnabled",
            "agent.observability.metricRetentionDays",
            "agent.history.retention",
            "agentDefinitionSync.schedules.enabled",
            "agentDefinitionSync.providerPresets.enabled",
            "agentDefinitionSync.userAuthoredMemory.enabled",
            "agent.pricing.providerID",
            "agent.pricing.model",
            "agent.pricing.currencyCode",
            "agent.pricing.inputMicrounitsPerMillionTokens",
            "agent.pricing.cachedInputMicrounitsPerMillionTokens",
            "agent.pricing.outputMicrounitsPerMillionTokens",
            "agent.pricing.blendedMicrounitsPerMillionTokens",
        ]

        #expect(AgentSettingsRuntimeKey.allDefaultsKeys == expected)
        #expect(AgentSettingsRuntimeKey.allDefaultsKeys.count == 34)
        #expect(AgentProviderPricingSettings.Key.all.isSubset(
            of: AgentSettingsRuntimeKey.allDefaultsKeys
        ))
    }

    @Test func runHistoryRetentionKeyUsesTheRuntimePolicyAndSafeDefault() throws {
        let suiteName = "AgentSettingsTests.Retention.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        #expect(AgentHistoryRetentionSettings.Key.policy == "agent.history.retention")
        #expect(AgentHistoryRetentionSettings.policy(in: defaults) == .days30)

        for policy in AgentRetentionPolicy.allCases {
            defaults.set(
                policy.rawValue,
                forKey: AgentHistoryRetentionSettings.Key.policy
            )
            #expect(AgentHistoryRetentionSettings.policy(in: defaults) == policy)
        }

        defaults.set("invalid", forKey: AgentHistoryRetentionSettings.Key.policy)
        #expect(AgentHistoryRetentionSettings.policy(in: defaults) == .days30)
    }

    @Test func providerPricingIsValidatedAndBoundToAnExactProviderModelPair() throws {
        let suiteName = "AgentSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("OpenAI-compatible", forKey: AgentProviderPricingSettings.Key.providerID)
        defaults.set("fixture-model", forKey: AgentProviderPricingSettings.Key.model)
        defaults.set("usd", forKey: AgentProviderPricingSettings.Key.currencyCode)
        defaults.set("125000", forKey: AgentProviderPricingSettings.Key.inputMicrounitsPerMillionTokens)
        defaults.set("250000", forKey: AgentProviderPricingSettings.Key.outputMicrounitsPerMillionTokens)

        let pricing = try #require(AgentProviderPricingSettings.metadata(
            providerID: "OpenAI-compatible",
            model: "fixture-model",
            defaults: defaults
        ))
        #expect(pricing.source == .userConfigured)
        #expect(pricing.currencyCode == "USD")
        #expect(pricing.inputMicrounitsPerMillionTokens == 125_000)
        #expect(pricing.outputMicrounitsPerMillionTokens == 250_000)
        #expect(AgentProviderPricingSettings.metadata(
            providerID: "OpenAI-compatible",
            model: "another-model",
            defaults: defaults
        ) == nil)

        for key in AgentProviderPricingSettings.Key.all {
            defaults.removeObject(forKey: key)
        }
        defaults.set("OpenAI-compatible", forKey: AgentProviderPricingSettings.Key.providerID)
        defaults.set("fixture-model", forKey: AgentProviderPricingSettings.Key.model)
        defaults.set("USD", forKey: AgentProviderPricingSettings.Key.currencyCode)
        defaults.set("-1", forKey: AgentProviderPricingSettings.Key.blendedMicrounitsPerMillionTokens)
        #expect(AgentProviderPricingSettings.metadata(
            providerID: "OpenAI-compatible",
            model: "fixture-model",
            defaults: defaults
        ) == nil)
    }
}
