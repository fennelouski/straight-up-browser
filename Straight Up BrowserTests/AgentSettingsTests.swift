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
            "browserAgentAdjustsPageLayout",
            "browserAgentLoadsMorePageContent",
            "browserAgentPanelSide",
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
        #expect(AgentSettingsRuntimeKey.allDefaultsKeys.count == 37)
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

    @Test func cataloguedOpenAIModelsAutocompleteAndCarryPublishedPricing() throws {
        let models = AgentProviderModelCatalog.modelIDs(for: .openAI)
        #expect(!models.contains("gpt-5-mini"))
        #expect(models.contains("gpt-5.6-luna"))
        #expect(BrowserAgentProvider.openAI.defaultModel == "gpt-5.6-luna")
        #expect(BrowserAgentProvider.openAI.resolvedModel("gpt-5-mini") == "gpt-5.6-luna")
        #expect(BrowserAgentProvider.openRouter.defaultModel == "openai/gpt-latest")
        #expect(BrowserAgentProvider.ollama.defaultModel.isEmpty)
        #expect(BrowserAgentProvider.lmStudio.defaultModel.isEmpty)

        let suiteName = "AgentSettingsTests.Catalog.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        let pricing = try #require(AgentProviderPricingSettings.metadata(
            providerID: BrowserAgentProvider.openAI.rawValue,
            model: "gpt-5.6-luna",
            defaults: defaults
        ))
        #expect(pricing.source == .providerPublished)
        #expect(pricing.currencyCode == "USD")
        #expect(pricing.inputMicrounitsPerMillionTokens == 200_000)
        #expect(pricing.cachedInputMicrounitsPerMillionTokens == 20_000)
        #expect(pricing.outputMicrounitsPerMillionTokens == 1_200_000)

        defaults.set(BrowserAgentProvider.openAI.rawValue, forKey: AgentProviderPricingSettings.Key.providerID)
        defaults.set("gpt-5.6-luna", forKey: AgentProviderPricingSettings.Key.model)
        defaults.set("USD", forKey: AgentProviderPricingSettings.Key.currencyCode)
        defaults.set("999", forKey: AgentProviderPricingSettings.Key.inputMicrounitsPerMillionTokens)
        let override = try #require(AgentProviderPricingSettings.metadata(
            providerID: BrowserAgentProvider.openAI.rawValue,
            model: "gpt-5.6-luna",
            defaults: defaults
        ))
        #expect(override.source == .userConfigured)
        #expect(override.inputMicrounitsPerMillionTokens == 999)
    }

    @Test func providerModelDiscoveryParsesEverySupportedCatalogShape() throws {
        let openAIData = Data(#"{"data":[{"id":"gpt-5.6-luna"},{"id":"gpt-5.6-luna"},{"id":"gpt-5.6-sol"}]}"#.utf8)
        #expect(try AgentProviderModelDiscovery.modelIDs(
            provider: .openAI,
            data: openAIData
        ) == ["gpt-5.6-luna", "gpt-5.6-sol"])
        #expect(try AgentProviderModelDiscovery.modelIDs(
            provider: .anthropicMessages,
            data: Data(#"{"data":[{"id":"claude-sonnet-5"}]}"#.utf8)
        ) == ["claude-sonnet-5"])
        #expect(try AgentProviderModelDiscovery.modelIDs(
            provider: .gemini,
            data: Data(#"{"models":[{"name":"models/gemini-3.6-flash"}]}"#.utf8)
        ) == ["gemini-3.6-flash"])
        #expect(try AgentProviderModelDiscovery.modelIDs(
            provider: .openRouter,
            data: Data(#"{"data":[{"id":"openai/gpt-5.6-luna"}]}"#.utf8)
        ) == ["openai/gpt-5.6-luna"])
        #expect(try AgentProviderModelDiscovery.modelIDs(
            provider: .ollama,
            data: Data(#"{"models":[{"name":"qwen3:8b"}]}"#.utf8)
        ) == ["qwen3:8b"])
        #expect(try AgentProviderModelDiscovery.modelIDs(
            provider: .lmStudio,
            data: Data(#"{"data":[{"id":"local/current"}]}"#.utf8)
        ) == ["local/current"])
        #expect(try AgentProviderModelDiscovery.modelIDs(
            provider: .compatible,
            data: Data(#"{"data":[{"id":"provider/current"}]}"#.utf8)
        ) == ["provider/current"])
    }
}
