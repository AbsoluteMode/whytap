import Foundation

/// Small presentation descriptor for a recording-source brand mark. Despite
/// the name (kept for source compatibility) it now covers any source the
/// Dynamic Island breathing ticker can show during a voice turn: transcription
/// providers (drop dictation), the user's agent CLI (Codex / Claude Code), and
/// Google search. The same value can render in Settings rows or in the island.
struct TranscriptionProviderBrand: Equatable, Sendable {
    let assetName: String?
    let systemName: String?
    let label: String
    var modelBrand: AgentModelBrand? = nil

    init(assetName: String, label: String) {
        self.assetName = assetName
        self.systemName = nil
        self.label = label
    }

    init(systemName: String, label: String) {
        self.assetName = nil
        self.systemName = systemName
        self.label = label
    }

    static func byok(_ provider: BYOKProvider) -> TranscriptionProviderBrand {
        switch provider {
        case .openAI:
            return TranscriptionProviderBrand(assetName: "openai", label: "OpenAI")
        case .selfHosted:
            return TranscriptionProviderBrand(systemName: "server.rack", label: "Self-hosted")
        case .deepgram:
            return TranscriptionProviderBrand(assetName: "deepgram", label: "Deepgram")
        case .soniox:
            return TranscriptionProviderBrand(assetName: "soniox", label: "Soniox")
        case .elevenLabs:
            return TranscriptionProviderBrand(assetName: "elevenlabs", label: "ElevenLabs")
        }
    }

    /// Compatibility fallback when no model route is supplied.
    static func agent(_ provider: CLIProviderID) -> TranscriptionProviderBrand {
        agent(provider, route: nil)
    }

    static func agent(_ provider: CLIProviderID, route: FeatureRoute?) -> TranscriptionProviderBrand {
        switch provider {
        case .codex:
            return TranscriptionProviderBrand(assetName: "codex", label: "Codex")
        case .claude:
            return TranscriptionProviderBrand(assetName: "claude-code", label: "Claude Code")
        case .native:
            if let route, let model = AgentModelBrand.resolve(route) {
                var brand = TranscriptionProviderBrand(assetName: model.assetName, label: model.label)
                brand.modelBrand = model
                return brand
            }
            if route?.account == .openRouter { return .openRouter }
            return TranscriptionProviderBrand(systemName: "sparkle", label: "Whytap Agent")
        case .opencode:
            return TranscriptionProviderBrand(systemName: "terminal", label: "OpenCode")
        }
    }

    /// Brand shown in the island breathing ticker during Google voice search
    /// (Right Option hold).
    static let google = TranscriptionProviderBrand(assetName: "google", label: "Google")

    /// Brand shown while Drop's LLM cleanup runs directly through OpenRouter.
    static let openRouter = TranscriptionProviderBrand(assetName: "openrouter", label: "OpenRouter")

    /// The SF Symbol for Anthropic, which has no brand asset in the bundle.
    static let anthropicSystemName = "asterisk"

    /// Brand of an Agent route on Anthropic's own API.
    static let anthropic = TranscriptionProviderBrand(systemName: anthropicSystemName, label: "Anthropic")

    /// Brand shown while Drop's LLM cleanup runs through a custom
    /// OpenAI-compatible endpoint.
    static let customLLM = TranscriptionProviderBrand(systemName: "server.rack", label: "Custom LLM")

    /// Brand for the provider account a route runs on: the built-in
    /// providers keep their own mark, a server shows the rack symbol with the
    /// name the user gave it.
    @MainActor
    static func brand(for account: ProviderAccount, in routing: AIRoutingStore) -> TranscriptionProviderBrand {
        switch account {
        case .soniox:
            return TranscriptionProviderBrand(assetName: "soniox", label: "Soniox")
        case .deepgram:
            return TranscriptionProviderBrand(assetName: "deepgram", label: "Deepgram")
        case .elevenLabs:
            return TranscriptionProviderBrand(assetName: "elevenlabs", label: "ElevenLabs")
        case .openRouter:
            return .openRouter
        case .openAI:
            return TranscriptionProviderBrand(assetName: "openai", label: "OpenAI")
        case .anthropic:
            return .anthropic
        case .groq:
            return TranscriptionProviderBrand(systemName: "bolt", label: "Groq")
        case .thisMac:
            return TranscriptionProviderBrand(systemName: "laptopcomputer", label: "On this Mac")
        case .server(let id):
            return TranscriptionProviderBrand(systemName: "server.rack", label: routing.server(id)?.name ?? "Server")
        }
    }

    /// Brand of the provider the current Drop take runs on: the route the take
    /// latched when it began, so a mode switch mid-take does not change it.
    /// `nil` when the take had no route (Not set).
    @MainActor
    static func currentDrop(take: DropTake? = nil, routing: AIRoutingStore? = nil) -> TranscriptionProviderBrand? {
        let routing = routing ?? .shared
        guard let route = (take ?? .shared).route else { return nil }
        return brand(for: route.account, in: routing)
    }

    /// Brand of the provider Drop Smart's LLM cleanup runs on; `nil` when the
    /// feature is Not set.
    @MainActor
    static func currentDropCleanup(routing: AIRoutingStore? = nil) -> TranscriptionProviderBrand? {
        let routing = routing ?? .shared
        guard let route = routing.route(for: .dropSmartCleanup) else { return nil }
        return brand(for: route.account, in: routing)
    }
}
