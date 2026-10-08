import Foundation

/// The small, provider-published price list Browser can safely apply without
/// asking a user to transcribe rates. A provider's model-list endpoint tells us
/// what an account can access, but does not include pricing.
nonisolated enum AgentProviderModelCatalog {
    private struct Preset: Sendable {
        let model: String
        let inputMicrounitsPerMillionTokens: Int64
        let cachedInputMicrounitsPerMillionTokens: Int64
        let outputMicrounitsPerMillionTokens: Int64

        func pricing() -> AgentProviderPricingMetadata? {
            try? AgentProviderPricingMetadata(
                source: .providerPublished,
                currencyCode: "USD",
                inputMicrounitsPerMillionTokens: inputMicrounitsPerMillionTokens,
                cachedInputMicrounitsPerMillionTokens: cachedInputMicrounitsPerMillionTokens,
                outputMicrounitsPerMillionTokens: outputMicrounitsPerMillionTokens
            )
        }
    }

    // Reviewed current OpenAI models; see docs/agent-model-review.json. Account-specific availability comes
    // from the live model list; these are only useful offline fallbacks.
    private static let openAIPresets = [
        Preset(model: "gpt-6-astra", inputMicrounitsPerMillionTokens: 10_000_000,
               cachedInputMicrounitsPerMillionTokens: 1_000_000, outputMicrounitsPerMillionTokens: 50_000_000),
        Preset(model: "gpt-6.1-sol", inputMicrounitsPerMillionTokens: 2_000_000,
               cachedInputMicrounitsPerMillionTokens: 100_000, outputMicrounitsPerMillionTokens: 10_000_000),
        Preset(model: "gpt-6-luna", inputMicrounitsPerMillionTokens: 100_000,
               cachedInputMicrounitsPerMillionTokens: 10_000, outputMicrounitsPerMillionTokens: 500_000),
    ]

    @MainActor static func modelIDs(for provider: BrowserAgentProvider) -> [String] {
        switch provider {
        case .appleIntelligence:
            [provider.defaultModel]
        case .openAI, .openAIResponses:
            openAIPresets.map(\.model)
        case .anthropicMessages, .gemini, .openRouter:
            provider.defaultModel.isEmpty ? [] : [provider.defaultModel]
        case .ollama, .lmStudio, .compatible:
            []
        }
    }

    static func pricing(
        providerID: String,
        model: String
    ) -> AgentProviderPricingMetadata? {
        guard let provider = BrowserAgentProvider(rawValue: providerID) else { return nil }
        return pricing(provider: provider, model: model)
    }

    static func pricing(
        provider: BrowserAgentProvider,
        model: String
    ) -> AgentProviderPricingMetadata? {
        guard provider == .openAI || provider == .openAIResponses else { return nil }
        return openAIPresets.first(where: { $0.model == model })?.pricing()
    }

    static func isPublishedPricing(
        providerID: String,
        model: String,
        currencyCode: String,
        inputMicrounitsPerMillionTokens: Int64?,
        cachedInputMicrounitsPerMillionTokens: Int64?,
        outputMicrounitsPerMillionTokens: Int64?,
        estimatedBlendedMicrounitsPerMillionTokens: Int64?
    ) -> Bool {
        guard let published = pricing(providerID: providerID, model: model) else { return false }
        return published.currencyCode == currencyCode.uppercased()
            && published.inputMicrounitsPerMillionTokens == inputMicrounitsPerMillionTokens
            && published.cachedInputMicrounitsPerMillionTokens == cachedInputMicrounitsPerMillionTokens
            && published.outputMicrounitsPerMillionTokens == outputMicrounitsPerMillionTokens
            && published.estimatedBlendedMicrounitsPerMillionTokens == estimatedBlendedMicrounitsPerMillionTokens
    }
}

