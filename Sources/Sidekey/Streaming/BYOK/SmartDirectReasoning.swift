import Foundation

/// Drop Smart cleanup is an exact editing task, so on the direct Anthropic and
/// OpenAI routes it asks for the least reasoning the chosen model accepts and
/// turns thinking off where the model allows that. A model outside these
/// tables gets no field (its own default), and a request the provider refuses
/// with the field goes again without it. OpenRouter keeps its catalog policy
/// (`OpenRouterReasoningPolicy`); custom servers, translation and meetings get
/// nothing from here. The model and provider are never changed.
/// The built-in Agent reads the same tables (`NativeAgentEffort`).
// WHY: .project-docs/decisions/2026-11-24-smart-minimal-reasoning.md
// WHY: .project-docs/decisions/2026-11-24-agent-minimal-reasoning.md
enum SmartDirectReasoning {
    /// `reasoning_effort` for direct OpenAI Chat Completions, or `nil` to send
    /// none. Values are what each model accepted on 2026-11-24:
    /// - `none`: GPT-5.1, 5.2, 5.4 (also mini and nano), 5.5, 5.6 (Luna, Sol,
    ///   Terra), GPT-6 Luna, GPT-6 Sol, GPT-6.1 Terra;
    /// - `minimal`: GPT-5, GPT-5 mini, GPT-5 nano (they refuse `none`);
    /// - `low`: every other reasoning model (GPT-6 Astra, GPT-6.1 Sol, GPT-6.2
    ///   Astra and Sol, o3 refuse `none` and `minimal`; a GPT-5, GPT-6 or
    ///   o-series model not listed here is asked for `low`, which all of them
    ///   take).
    /// GPT-4.1 and GPT-4o refuse the argument; chat snapshots, pro models and
    /// any other generation get none, as for the Agent. Families match by
    /// prefix: a variant (`gpt-5.1-codex`) gets its family's level.
    static func openAIEffort(model: String) -> String? {
        guard NativeAgentEffort.openAIReasoning(model) else { return nil }
        let id = openAIBase(model)
        let off = ["gpt-5.1", "gpt-5.2", "gpt-5.4", "gpt-5.5", "gpt-5.6", "gpt-6-luna", "gpt-6-sol", "gpt-6.1-terra"]
        if off.contains(where: { id == $0 || id.hasPrefix($0 + "-") }) { return "none" }
        if id == "gpt-5" || id.hasPrefix("gpt-5-") { return "minimal" }
        return "low"
    }

    struct Anthropic: Equatable {
        /// `output_config.effort`, or `nil` to send none.
        var effort: String?
        /// `thinking.type`, or `nil` to send no `thinking` field.
        var thinking: String?

        var diagnosticLabel: String {
            [effort, thinking].compactMap { $0 }.joined(separator: "+")
        }
    }

    /// Fields for direct Anthropic Messages, or `nil` to send none.
    /// - `output_config.effort: low` on the models of Anthropic's effort page
    ///   (the list the Agent uses).
    /// - Thinking off where the model has a setting for it: Claude Sonnet 5.5
    ///   takes `between_tools` (it refuses `disabled`); Claude Haiku 5.5 and
    ///   Claude Sonnet 5 take `disabled`.
    /// - Fable, Mythos and Claude Opus 5.5 cannot turn thinking off: low
    ///   effort only. Claude Opus 5 could, but Anthropic warns that it then
    ///   may write thinking tags into its visible text, which Smart would
    ///   paste: low effort only. Opus 4.5 to 4.8 and Sonnet 4.6 do not think
    ///   unless asked, so they get effort only. Older models get nothing.
    static func anthropic(model: String) -> Anthropic? {
        let id = model.lowercased()
        var fields = Anthropic(effort: NativeAgentEffort.anthropicSupports(model) ? "low" : nil, thinking: nil)
        if isFamily(id, "claude-sonnet-5-5") {
            fields.thinking = "between_tools"
        } else if isFamily(id, "claude-haiku-5-5") || isRelease(id, "claude-sonnet-5") {
            fields.thinking = "disabled"
        }
        return fields.effort == nil && fields.thinking == nil ? nil : fields
    }

    /// The model itself, an alias or a dated ID of it.
    private static func isFamily(_ id: String, _ family: String) -> Bool {
        id == family || id.hasPrefix(family + "-")
    }

    /// A family named without a minor version (`claude-opus-5`): its dated IDs
    /// and aliases match, a later minor (`claude-opus-5-5`) does not.
    private static func isRelease(_ id: String, _ family: String) -> Bool {
        if id == family { return true }
        guard id.hasPrefix(family + "-") else { return false }
        let next = id.dropFirst(family.count + 1).split(separator: "-").first.map(String.init) ?? ""
        return !(next.count <= 2 && next.allSatisfy(\.isNumber))
    }

    /// A fine-tuned `ft:` ID is judged by its base model.
    private static func openAIBase(_ model: String) -> String {
        let id = model.lowercased()
        guard id.hasPrefix("ft:") else { return id }
        return String(id.dropFirst(3).split(separator: ":").first ?? "")
    }
}

/// The model name a stored timing line may carry. Model names are saved text:
/// a user can type any name, and a fine-tuned or self-hosted one can hold an
/// organization or a private label. The line therefore never carries the
/// saved string itself: for Anthropic and OpenAI it carries one of the fixed
/// names below (the family the saved name belongs to), for OpenRouter an ID
/// its own catalog lists, and otherwise the fixed word `other`.
enum CleanupDiagnosticModel {
    static let other = "other"

    static let anthropicFamilies = [
        "claude-fable-5-2", "claude-fable-5-1", "claude-fable-5",
        "claude-mythos-5-2", "claude-mythos-5-1", "claude-mythos-5", "claude-mythos-preview",
        "claude-opus-5-5", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6",
        "claude-opus-4-5", "claude-opus-4-1",
        "claude-sonnet-5-5", "claude-sonnet-5", "claude-sonnet-4-6", "claude-sonnet-4-5",
        "claude-haiku-5-5", "claude-haiku-4-5",
    ]

    static let openAIFamilies = [
        "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o", "gpt-4o-mini",
        "gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5.1", "gpt-5.2",
        "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.5",
        "gpt-5.6-luna", "gpt-5.6-sol", "gpt-5.6-terra",
        "gpt-6-astra", "gpt-6-luna", "gpt-6-sol", "gpt-6.1-sol", "gpt-6.1-terra",
        "gpt-6.2-astra", "gpt-6.2-sol", "o3", "o4-mini",
    ]

    /// Direct Anthropic: the published family this name is, as an alias or a
    /// dated ID.
    static func anthropic(_ model: String) -> String { family(of: model, in: anthropicFamilies) }

    /// Direct OpenAI: the published model this name is, as an alias or a dated
    /// snapshot. A fine-tuned `ft:` ID is `other`.
    static func openAI(_ model: String) -> String { family(of: model, in: openAIFamilies) }

    /// OpenRouter: the ID itself, when its own catalog listed it at the last
    /// read; that catalog is public, so a listed ID is not private text.
    static func openRouter(_ model: String, listed: Bool) -> String {
        listed && model.count <= 150 ? model : other
    }

    /// The fixed family name, never the saved string: the name must equal a
    /// family or be that family followed by `-latest` or a date
    /// (`-20251001`, `-2026-03-17`).
    private static func family(of model: String, in families: [String]) -> String {
        let id = model.lowercased()
        for family in families {
            if id == family { return family }
            guard id.hasPrefix(family + "-") else { continue }
            let rest = id.dropFirst(family.count + 1)
            let digits = rest.filter { $0 != "-" }
            let isDate = digits.count == 8 && digits.allSatisfy { $0.isASCII && $0.isNumber }
                && (rest.count == 8 || (rest.count == 10 && rest.split(separator: "-").map(\.count) == [4, 2, 2]))
            if rest == "latest" || isDate { return family }
        }
        return other
    }
}

/// Models whose provider refused a Smart reasoning field and then accepted
/// the same request without it, while this app runs: they get no field again
/// until relaunch, so one refusal costs one extra
/// request, not one per dictation. Nothing is stored on disk.
final class SmartReasoningRefusals: @unchecked Sendable {
    static let shared = SmartReasoningRefusals()
    private let lock = NSLock()
    private var refused: Set<String> = []

    func contains(_ api: OpenAICompatibleLLMEndpoint.TextAPI, model: String) -> Bool {
        lock.withLock { refused.contains(Self.key(api, model)) }
    }

    func record(_ api: OpenAICompatibleLLMEndpoint.TextAPI, model: String) {
        lock.withLock { _ = refused.insert(Self.key(api, model)) }
    }

    private static func key(_ api: OpenAICompatibleLLMEndpoint.TextAPI, _ model: String) -> String {
        "\(api):\(model.lowercased())"
    }
}
