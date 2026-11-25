import Foundation

/// The built-in Agent asks its model for the least reasoning the model
/// accepts and turns thinking off where the model allows that, so a simple
/// question is answered without long thinking. The per-model tables are the
/// ones Drop Smart uses (`SmartDirectReasoning`, `OpenRouterReasoningPolicy`).
/// A model outside them gets no field (its own default), and a turn's first
/// request that the provider refuses for these fields goes again with OpenAI
/// `low` or without them (`NativeAgentModel`).
// WHY: .project-docs/decisions/2026-11-24-agent-minimal-reasoning.md
enum NativeAgentEffort {
    /// What one request asks for: the body fields and their diagnostic names.
    struct Request {
        let fields: [String: Any]
        let effort: NativeAgentDiagnostics.Effort?
        let thinking: NativeAgentDiagnostics.Thinking?
    }

    /// The request fields to add, or `nil` to send none.
    /// - Anthropic: `output_config.effort: low` (the Models API flag
    ///   `capabilities.effort.low.supported` wins when the catalog states it;
    ///   otherwise the families of the effort page) and `thinking.type` from
    ///   the shared table: `disabled` on Claude Haiku 5.5 and Claude Sonnet 5,
    ///   `between_tools` on Claude Sonnet 5.5.
    /// - OpenAI Responses: `reasoning.effort` from the shared table (`none`,
    ///   `minimal` or `low`).
    /// - OpenRouter: `reasoning` from its catalog entry: off where reasoning
    ///   is optional, else the lowest level the entry lists.
    ///
    /// `providerSearch`: the turn uses the provider's own web search. Two
    /// settings do not work with it and step up one level: OpenAI refuses
    /// `minimal` beside its search tool (`low` is sent), and Claude Sonnet 5.5
    /// with `between_tools` repeats `finish_answer` after a search (no
    /// `thinking` field is sent, low effort stays).
    ///
    /// `refused`: the provider refused these fields for this model before.
    /// Direct OpenAI then gets `low`, which every reasoning model takes (the
    /// Agent's level before 2026-11-24), when the level that would be sent is
    /// lower; otherwise nothing is sent.
    static func request(provider: OpenCodeModelProvider, model: String, catalogFlag: Bool?,
                        openRouter: OpenRouterReasoningCapabilities? = nil, providerSearch: Bool = false,
                        refused: Bool = false) -> Request? {
        guard refused else {
            return least(provider: provider, model: model, catalogFlag: catalogFlag, openRouter: openRouter,
                         providerSearch: providerSearch)
        }
        let sent = least(provider: provider, model: model, catalogFlag: catalogFlag, openRouter: openRouter,
                         providerSearch: providerSearch)
        guard provider == .openAI, sent?.effort == .noReasoning || sent?.effort == .minimal else { return nil }
        return Request(fields: ["reasoning": ["effort": "low"]], effort: .low, thinking: nil)
    }

    /// The least reasoning the tables give this model.
    private static func least(provider: OpenCodeModelProvider, model: String, catalogFlag: Bool?,
                              openRouter: OpenRouterReasoningCapabilities?, providerSearch: Bool) -> Request? {
        typealias Effort = NativeAgentDiagnostics.Effort
        switch provider {
        case .anthropic:
            // The Models API saying the model takes no effort setting: nothing
            // is sent, the thinking field included.
            guard catalogFlag != false else { return nil }
            let effort = catalogFlag ?? anthropicSupports(model) ? "low" : nil
            var thinking = SmartDirectReasoning.anthropic(model: model)?.thinking
            if providerSearch, thinking == "between_tools" { thinking = nil }
            var fields: [String: Any] = [:]
            if let effort { fields["output_config"] = ["effort": effort] }
            if let thinking { fields["thinking"] = ["type": thinking] }
            guard !fields.isEmpty else { return nil }
            return Request(fields: fields, effort: effort.flatMap(Effort.init(rawValue:)),
                           thinking: thinking.flatMap(NativeAgentDiagnostics.Thinking.init(rawValue:)))
        case .openAI:
            guard var effort = SmartDirectReasoning.openAIEffort(model: model) else { return nil }
            if providerSearch, effort == "minimal" { effort = "low" }
            return Request(fields: ["reasoning": ["effort": effort]], effort: Effort(rawValue: effort), thinking: nil)
        case .openRouter:
            guard let setting = openRouter?.dictationSetting else { return nil }
            if setting.enabled == false {
                return Request(fields: ["reasoning": ["enabled": false]], effort: .off, thinking: nil)
            }
            guard var effort = setting.effort else { return nil }
            if providerSearch, effort == "minimal", openRouter?.supportedEfforts?.contains("low") == true { effort = "low" }
            return Request(fields: ["reasoning": ["effort": effort]], effort: Effort(rawValue: effort), thinking: nil)
        }
    }

    /// Whether a failed request may go again with the `refused` fields. Any
    /// HTTP 400, as in Drop Smart: the error text is not read, because no
    /// reading of free provider text told a refused setting from another
    /// error reliably (four builder reviews). An unrelated 400 therefore goes
    /// once more and fails the same way: a 400 is not billed and runs no
    /// tool, and the caller allows it only on the turn's first request, once.
    /// Also OpenRouter's 404 "no endpoints ... requested parameters". Not a
    /// refusal of the provider's own web search, which has its own fallback.
    static func refused(_ error: Error, provider: OpenCodeModelProvider) -> Bool {
        guard case NativeAgentError.service(_, let status, let shape) = error, shape.rejectsWebSearch != true else { return false }
        if status == 400 { return true }
        return provider == .openRouter && status == 404 && shape.noEndpointForParameters == true
    }

    /// Models whose provider refused the Agent's reasoning fields and then
    /// answered the same request without them, while this app runs.
    static let refusals = SmartReasoningRefusals()

    /// The name a refusal is remembered under: the model, and on OpenRouter
    /// also the endpoint it is pinned to (or Auto), because another endpoint
    /// of the same model may take the setting.
    static func refusalKey(model: String, provider: OpenCodeModelProvider, openRouterPin: String?) -> String {
        provider == .openRouter ? model + "@" + (openRouterPin ?? "auto") : model
    }

    static func refusalAPI(_ provider: OpenCodeModelProvider) -> OpenAICompatibleLLMEndpoint.TextAPI {
        switch provider {
        case .anthropic: return .anthropic
        case .openAI: return .openAI
        case .openRouter: return .chatCompletions
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
