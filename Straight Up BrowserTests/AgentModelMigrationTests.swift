import Foundation
import Testing
@testable import Browser

@MainActor
struct AgentModelMigrationTests {
    @Test func reviewedAliasesUpgradeWithinTheirWorkloadRoles() {
        for provider in [BrowserAgentProvider.openAI, .openAIResponses] {
            #expect(provider.resolvedModel("gpt-5.6-luna") == "gpt-6-luna")
            #expect(provider.resolvedModel("gpt-5.6-terra") == "gpt-6.1-sol")
            #expect(provider.resolvedModel("gpt-5.6-sol") == "gpt-6.1-sol")
            #expect(provider.resolvedModel("gpt-6-sol") == "gpt-6.1-sol")
            #expect(provider.resolvedModel("gpt-5.6") == "gpt-6-astra")
            #expect(provider.resolvedModel("gpt-5.6-luna-2026-06-01") == "gpt-5.6-luna-2026-06-01")
        }
        #expect(BrowserAgentProvider.openRouter.resolvedModel("openai/gpt-5.6-luna") == "openai/gpt-6-luna")
        #expect(BrowserAgentProvider.openRouter.resolvedModel("openai/gpt-latest") == "openai/gpt-6-luna")
        #expect(BrowserAgentProvider.anthropicMessages.resolvedModel("claude-sonnet-5") == "claude-sonnet-5-5")
        #expect(BrowserAgentProvider.gemini.resolvedModel("gemini-3.6-flash") == "gemini-3.8-flash")
        #expect(BrowserAgentProvider.gemini.resolvedModel("gemini-3.7-flash") == "gemini-3.8-flash")
        #expect(BrowserAgentProvider.gemini.resolvedModel("gemini-3.6-flash-2026-04-01") == "gemini-3.6-flash-2026-04-01")
        #expect(BrowserAgentProvider.compatible.resolvedModel("gemini-3.6-flash") == "gemini-3.6-flash")
        #expect(BrowserAgentProvider.openRouter.resolvedModel("google/gemini-3.6-flash") == "google/gemini-3.6-flash")
        for provider in [BrowserAgentProvider.ollama, .lmStudio, .compatible] {
            #expect(provider.resolvedModel("gpt-5.6-luna") == "gpt-5.6-luna")
        }
    }

    @Test func persistedSelectionUpgradesOnceAndOldPricingCannotFollowIt() throws {
        let suite = "AgentModelMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(BrowserAgentProvider.openAI.rawValue, forKey: "browserAgentProvider")
        defaults.set("gpt-5.6-luna", forKey: "browserAgentModel")
        defaults.set(BrowserAgentProvider.openAI.rawValue, forKey: AgentProviderPricingSettings.Key.providerID)
        defaults.set("gpt-5.6-luna", forKey: AgentProviderPricingSettings.Key.model)
        defaults.set("USD", forKey: AgentProviderPricingSettings.Key.currencyCode)
        defaults.set(999, forKey: AgentProviderPricingSettings.Key.inputMicrounitsPerMillionTokens)
        #expect(AgentModelMigration.migrateSavedSelection(defaults: defaults))
        #expect(defaults.string(forKey: "browserAgentModel") == "gpt-6-luna")
        #expect(!AgentModelMigration.migrateSavedSelection(defaults: defaults))
        let pricing = try #require(AgentProviderPricingSettings.metadata(
            providerID: BrowserAgentProvider.openAI.rawValue, model: "gpt-6-luna", defaults: defaults))
        #expect(pricing.inputMicrounitsPerMillionTokens == 100_000)
        #expect(pricing.source == .providerPublished)
    }

    @Test func futureTaskConfigurationsResolveModelsWithoutReusingOldPrices() throws {
        let oldPricing = try AgentProviderPricingMetadata(source: .userConfigured,
            currencyCode: "USD", inputMicrounitsPerMillionTokens: 999,
            outputMicrounitsPerMillionTokens: 999)
        let config = BrowserAgentConfiguration(provider: .openAI,
            endpoint: BrowserAgentProvider.openAI.defaultEndpoint,
            model: "gpt-5.6-luna", apiKey: "fixture", pricing: oldPricing)
        #expect(config.model == "gpt-6-luna")
        #expect(config.pricing?.inputMicrounitsPerMillionTokens == 100_000)
        let profile = AgentProviderCapabilityProfile.resolve(dialect: .openAIResponses,
            endpoint: URL(string: config.endpoint)!, model: config.model)
        #expect(profile.reasoningSchema == .responsesObject)
    }
}
