import Foundation

/// The built-in Agent asks direct Anthropic and OpenAI models for low effort,
/// so a simple question is answered without long thinking. Sent only to models
/// documented to take it; any other model gets no parameter (its own
/// default), never an error. OpenRouter is not changed here.
// WHY: .project-docs/decisions/2026-11-23-agent-low-effort.md
enum NativeAgentEffort {
    static let level = "low"

    /// The request fields to add, or `nil` to send none.
    /// - Anthropic: `output_config.effort`. The Models API flag
    ///   (`capabilities.effort.low.supported`) wins when the catalog states
    ///   it; otherwise the model families the effort page lists.
    /// - OpenAI Responses: `reasoning.effort` on reasoning models (GPT-5 and
    ///   later, o1, o3, o4); chat snapshots and pre-reasoning models reject
    ///   the parameter.
    static func fields(provider: OpenCodeModelProvider, model: String, catalogFlag: Bool?) -> [String: Any]? {
        switch provider {
        case .anthropic:
            guard catalogFlag ?? anthropicSupports(model) else { return nil }
            return ["output_config": ["effort": level]]
        case .openAI:
            guard openAIReasoning(model) else { return nil }
            return ["reasoning": ["effort": level]]
        case .openRouter:
            return nil
        }
    }

    /// Families on Anthropic's effort page (checked 2026-11-23): Fable 5.x,
    /// Mythos 5.x and Preview, Opus 5.x and 4.5–4.8, Sonnet 5.x and 4.6,
    /// Haiku 5.5. Aliases and dated IDs share the prefix.
    static func anthropicSupports(_ model: String) -> Bool {
        let id = model.lowercased()
        let families = ["claude-fable-5", "claude-mythos-5", "claude-mythos-preview", "claude-opus-5",
                        "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5",
                        "claude-sonnet-5", "claude-sonnet-4-6", "claude-haiku-5-5"]
        return families.contains { id == $0 || id.hasPrefix($0 + "-") }
    }

    /// OpenAI reasoning models take `reasoning.effort`; current ones accept
    /// `low` (some refuse only `none` or `minimal`). Pro models may take only
    /// `high`, so they get no parameter. A fine-tuned `ft:` ID is judged by
    /// its base model.
    static func openAIReasoning(_ model: String) -> Bool {
        var id = model.lowercased()
        if id.hasPrefix("ft:") { id = String(id.dropFirst(3).split(separator: ":").first ?? "") }
        let family = ["gpt-5", "gpt-6", "o1", "o3", "o4"].contains { id == $0 || id.hasPrefix($0 + "-") || id.hasPrefix($0 + ".") }
        let excluded = ["-chat", "-pro", "o1-mini", "o1-preview"].contains { id.contains($0) }
        return family && !excluded
    }
}
