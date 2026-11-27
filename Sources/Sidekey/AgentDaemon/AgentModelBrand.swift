import Foundation

/// The model's author, not the OpenRouter host selected to serve it.
enum AgentModelBrand: String, CaseIterable, Sendable {
    case openai, anthropic, google, deepseek, qwen, mistral, cohere, perplexity

    /// The bundled mark for this author (`Resources/ProviderBrandIcons`).
    var assetName: String { "model-\(rawValue)" }

    /// An OpenRouter model ID without a leading `openrouter/` host prefix.
    static func normalizedOpenRouterModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("openrouter/") && trimmed.split(separator: "/").count >= 3
            ? String(trimmed.dropFirst("openrouter/".count)) : trimmed
    }
}
