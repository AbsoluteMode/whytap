import Foundation

/// One model the key steps offer after a key is accepted: its ID, a short
/// price when the catalogs know it, and its catalog date.
struct OnboardingModelChoice: Equatable, Identifiable {
    let id: String
    var price: String?
    var date: Date?
    /// Output price per million tokens, for telling a provider's tiers apart.
    var outputPerMillion: Double?
}

/// Which models a key step lists and which one it starts on: the provider's
/// current catalog, never a fixed list. The default is the newest flagship:
/// the newest generation (models within 30 days of the newest) and in it the
/// highest output price when prices are known, otherwise the newest model.
/// Small tiers (mini, nano, haiku, flash...) are listed but never the default.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
enum OnboardingModelPick {
    /// How many models a step lists; the rest stay in Settings -> Models.
    static let listLimit = 8
    static let generation: TimeInterval = 30 * 86_400

    /// Dated snapshots duplicate their model; voice, search and media models
    /// are not text models for these features.
    static func isListed(_ id: String, speech: Bool) -> Bool {
        let id = id.lowercased()
        if id.range(of: #"-\d{4}-\d{2}-\d{2}$|-\d{8}$"#, options: .regularExpression) != nil { return false }
        if id.hasSuffix("-latest") { return false }
        guard !speech else { return true }
        let other = ["live", "realtime", "audio", "transcribe", "whisper", "search", "tts", "embed", "image", "moderation"]
        return !other.contains { id.contains($0) }
    }

    static func isSmallTier(_ id: String) -> Bool {
        let id = id.lowercased()
        return ["mini", "nano", "lite", "small", "tiny", "haiku", "flash"].contains { id.contains($0) }
    }

    /// The model a key step recommends and sets first: the newest of the
    /// provider's balanced family in its current catalog (Anthropic Sonnet,
    /// OpenAI Sol, OpenRouter's Anthropic Sonnet). The owner asked for
    /// "Sonnet / Sol, the current one" on 2026-11-22. A family is a name, not
    /// a fixed ID, so a newer Sonnet or Sol takes over by itself; without
    /// one the newest flagship stands in. The person can pick any other.
    // WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
    static func recommended(_ choices: [OnboardingModelChoice], provider: AIProviderKind) -> OnboardingModelChoice? {
        let family: (String) -> Bool
        switch provider {
        case .anthropic: family = { $0.hasPrefix("claude-sonnet-") }
        case .openAI: family = { $0.hasPrefix("gpt-") && $0.hasSuffix("-sol") }
        case .openRouter: family = { $0.hasPrefix("anthropic/claude-sonnet-") }
        default: family = { _ in false }
        }
        let members = choices.filter { family($0.id.lowercased()) && isListed($0.id, speech: false) }
        return members.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) } ?? flagship(choices)
    }

    /// The newest flagship among `choices`, or nil when there is none.
    static func flagship(_ choices: [OnboardingModelChoice]) -> OnboardingModelChoice? {
        let candidates = choices.filter { !isSmallTier($0.id) }
        let pool = candidates.isEmpty ? choices : candidates
        guard let newest = pool.compactMap(\.date).max() else { return pool.first }
        let latest = pool.filter { ($0.date ?? .distantPast) >= newest.addingTimeInterval(-generation) }
        if latest.contains(where: { $0.outputPerMillion != nil }) {
            return latest.max { ($0.outputPerMillion ?? -1, $0.date ?? .distantPast) < ($1.outputPerMillion ?? -1, $1.date ?? .distantPast) }
        }
        return latest.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    /// A provider's list, newest first. OpenRouter carries every author's
    /// models, so it lists each major author's flagship instead.
    static func listed(_ choices: [OnboardingModelChoice], speech: Bool, router: Bool) -> [OnboardingModelChoice] {
        let shown = choices.filter { isListed($0.id, speech: speech) }
        guard router else {
            return Array(shown.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(listLimit))
        }
        let authors = ["anthropic", "openai", "google", "x-ai", "deepseek", "qwen", "moonshotai", "mistralai"]
        return authors.compactMap { author in
            flagship(shown.filter { $0.id.hasPrefix(author + "/") })
        }
    }

    /// "0.017", "0.0045": a per-minute speech price without trailing zeros.
    static func minutePrice(_ value: Double) -> String {
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// "$8 in / $40 out per 1M tokens" becomes "$8 / $40 per 1M".
    static func shortPrice(_ label: String?) -> String? {
        guard let label else { return nil }
        return label.replacingOccurrences(of: " in / ", with: " / ")
            .replacingOccurrences(of: " out per 1M tokens", with: " per 1M")
    }

    /// The output side of a catalog price label, for ranking tiers.
    static func outputPrice(_ label: String?) -> Double? {
        guard let label, let range = label.range(of: #"\$([0-9][0-9.,]*) out"#, options: .regularExpression) else { return nil }
        let number = label[range].dropFirst().dropLast(4).replacingOccurrences(of: ",", with: "")
        return Double(number)
    }
}
