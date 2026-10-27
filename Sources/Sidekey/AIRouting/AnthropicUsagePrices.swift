import Foundation

/// The Anthropic API reports tokens, never a charge. Estimate USD from the
/// response's `usage` with the published per-token prices. An unknown model,
/// fast mode or missing usage stays unavailable: never a guessed or zero price.
/// Prices verified 2026-10-27: https://platform.claude.com/docs/en/about-claude/pricing
/// WHY: .project-docs/decisions/2026-10-27-anthropic-token-costs.md
enum AnthropicUsagePrices {
    /// USD per million tokens.
    struct Rates: Equatable {
        let input, write5m, write1h, read, output: Double
    }

    private static func rates(_ input: Double, _ read: Double, _ output: Double) -> Rates {
        Rates(input: input, write5m: input * 1.25, write1h: input * 2, read: read, output: output)
    }

    /// Model ID prefixes; the longest matching prefix wins, so dated snapshots
    /// (`claude-sonnet-4-5-20250929`) resolve to their family.
    private static let table: [String: Rates] = [
        "claude-fable-5-1": rates(10, 0.25, 50), "claude-mythos-5-1": rates(10, 0.25, 50),
        "claude-fable-5": rates(10, 1, 50), "claude-mythos-5": rates(10, 1, 50),
        "claude-opus-5-5": rates(4, 0.20, 20), "claude-opus-5": rates(5, 0.50, 25),
        "claude-opus-4-8": rates(5, 0.50, 25), "claude-opus-4-7": rates(5, 0.50, 25),
        "claude-opus-4-6": rates(5, 0.50, 25), "claude-opus-4-5": rates(5, 0.50, 25),
        "claude-opus-4-1": rates(15, 1.50, 75), "claude-opus-4": rates(15, 1.50, 75),
        "claude-sonnet-5-5": rates(2, 0.10, 10), "claude-sonnet-5": rates(2, 0.20, 10),
        "claude-sonnet-4-6": rates(3, 0.30, 15), "claude-sonnet-4-5": rates(3, 0.30, 15),
        "claude-sonnet-4": rates(3, 0.30, 15),
        "claude-haiku-5-5": rates(0.10, 0.01, 0.50), "claude-haiku-4-5": rates(1, 0.10, 5),
        "claude-3-5-haiku": rates(0.80, 0.08, 4),
    ]
    /// Claude Haiku 5.5 prompts over 100,000 tokens (cache reads/writes included).
    private static let haiku55LongPrompt = rates(0.50, 0.05, 2.50)

    static func rates(model: String, promptTokens: Int) -> Rates? {
        let id = model.lowercased()
        guard let family = table.keys.filter({ id == $0 || id.hasPrefix($0 + "-") })
            .max(by: { $0.count < $1.count }) else { return nil }
        if family == "claude-haiku-5-5", promptTokens > 100_000 { return haiku55LongPrompt }
        return table[family]
    }

    static func cost(model: String, usage: [String: Any]?) -> Double? {
        guard let usage, let output = tokens(usage["output_tokens"]),
              let input = tokens(usage["input_tokens"]) else { return nil }
        // Fast mode has its own model-specific premium; do not guess it.
        if let speed = usage["speed"] as? String, speed != "standard" { return nil }
        let read = tokens(usage["cache_read_input_tokens"]) ?? 0
        let written = tokens(usage["cache_creation_input_tokens"]) ?? 0
        let creation = usage["cache_creation"] as? [String: Any]
        let write1h = min(written, tokens(creation?["ephemeral_1h_input_tokens"]) ?? 0)
        let write5m = written - write1h
        guard let rates = rates(model: model, promptTokens: input + read + written) else { return nil }
        let micro = Double(input) * rates.input + Double(write5m) * rates.write5m
            + Double(write1h) * rates.write1h + Double(read) * rates.read + Double(output) * rates.output
        // US-only inference costs 1.1x on every token category.
        let geo = (usage["inference_geo"] as? String) == "us" ? 1.1 : 1
        return micro / 1_000_000 * geo
    }

    private static func tokens(_ value: Any?) -> Int? {
        guard let number = AIUsageNumber.nonnegative(value), number < 1e12 else { return nil }
        return Int(number)
    }
}
