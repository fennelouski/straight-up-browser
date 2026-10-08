import Foundation

/// Exact, reviewed aliases only. Custom endpoints, installed local models, and
/// dated snapshots retain their IDs. Runs already recorded are never rewritten.
enum AgentModelMigration {
    private static let openAIReplacements = [
        "gpt-5-mini": "gpt-6-luna",
        "gpt-5.6-luna": "gpt-6-luna",
        "gpt-5.6-terra": "gpt-6.1-sol",
        "gpt-5.6-sol": "gpt-6.1-sol",
        "gpt-6-sol": "gpt-6.1-sol",
        "gpt-5.6": "gpt-6-astra",
    ]

    static func currentModel(_ model: String, provider: BrowserAgentProvider) -> String {
        switch provider {
        case .openAI, .openAIResponses:
            return openAIReplacements[model] ?? model
        case .anthropicMessages:
            return ["claude-sonnet-4-6", "claude-sonnet-5"].contains(model)
                ? "claude-sonnet-5-5" : model
        case .openRouter:
            if model == "openai/gpt-latest" { return provider.defaultModel }
            if model.hasPrefix("openai/"),
               let replacement = openAIReplacements[String(model.dropFirst(7))] {
                return "openai/" + replacement
            }
            return model == "anthropic/claude-sonnet-5" ? "anthropic/claude-sonnet-5.5" : model
        case .appleIntelligence, .gemini, .ollama, .lmStudio, .compatible:
            return model
        }
    }

    @discardableResult
    static func migrateSavedSelection(defaults: UserDefaults = .standard) -> Bool {
        guard let rawProvider = defaults.string(forKey: "browserAgentProvider"),
              let provider = BrowserAgentProvider(rawValue: rawProvider),
              let saved = defaults.string(forKey: "browserAgentModel") else { return false }
        let current = provider.resolvedModel(saved)
        guard current != saved else { return false }
        defaults.set(current, forKey: "browserAgentModel")
        // Old pricing stays bound to the old model. The runtime uses reviewed
        // current rates (or unknown pricing), never transfers an old cost cap rate.
        return true
    }
}
