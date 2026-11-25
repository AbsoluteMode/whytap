import Foundation

/// The OpenCode provider an app-owned run goes to: the provider of the
/// `Agent` route. There is no fallback from one to the other.
enum OpenCodeModelProvider: String, Equatable, Sendable {
    case openRouter = "openrouter"
    case openAI = "openai"
    case anthropic

    /// OpenCode's provider id, the prefix of `--model <id>/<model>`.
    var openCodeID: String { rawValue }

    var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    /// The variable OpenCode reads the key from (`{env:…}` in its config).
    var keyEnvironmentName: String {
        switch self {
        case .openRouter: return "OPENROUTER_API_KEY"
        case .openAI: return "OPENAI_API_KEY"
        case .anthropic: return "ANTHROPIC_API_KEY"
        }
    }

    var account: ProviderAccount {
        switch self {
        case .openRouter: return .openRouter
        case .openAI: return .openAI
        case .anthropic: return .anthropic
        }
    }

    /// The provider of an Agent route, or `nil` for one OpenCode cannot run.
    init?(account: ProviderAccount) {
        switch account {
        case .openRouter: self = .openRouter
        case .openAI: self = .openAI
        case .anthropic: self = .anthropic
        case .soniox, .deepgram, .elevenLabs, .server, .thisMac: return nil
        }
    }
}

/// What OpenCode needs to know about a model its own snapshot lacks, taken from
/// the route's catalog (OpenRouter or Anthropic). Without it OpenCode treats the context as 0.
struct OpenCodeModelSpec: Equatable, Sendable {
    let toolCall: Bool
    let reasoning: Bool
    let contextLimit: Int
    let outputLimit: Int
}

/// Per-turn agent overrides chosen in Settings. A `nil` field means "send no
/// flag" (the CLI uses its own default). Codex controls are validated against
/// its model registry; absent capabilities leave controls to Codex.
/// Provider neutral: Claude ignores `serviceTier`.
struct AgentRunOptions: Equatable {
    var model: String?
    var effort: String?
    var serviceTier: String?
    var workingDirectory: URL?
    var allowActions: Bool
    var openCodeModelSpec: OpenCodeModelSpec?
    var openCodeProvider: OpenCodeModelProvider
    /// `<helper> case mcp` when the built-in agent is registered in Case.
    var caseMCPCommand: [String]?
    /// App-owned screen capture; independent of Case registration.
    var screenMCPCommand: [String]?
    /// OpenRouter endpoint tag the agent's model is pinned to; `nil` is Auto.
    var openRouterProvider: String?
    /// The user picked Tavily in Keys & models → Models → Search.
    var preferTavilySearch: Bool
    /// The catalog's statement of built-in web search support (Anthropic's
    /// Models API), read even when the catalog gives no token limits; `nil`
    /// when it does not say.
    var webSearchSupport: Bool?
    /// The catalog's statement that the Agent model takes `effort: low`
    /// (Anthropic's Models API); `nil` when it does not say.
    var lowEffortSupport: Bool?
    /// The catalog's output token limit for the Agent model, read even when
    /// the catalog gives no context length; `nil` when it does not say.
    var outputTokenLimit: Int?

    init(model: String? = nil, effort: String? = nil, serviceTier: String? = nil,
         workingDirectory: URL? = nil, allowActions: Bool = true,
         openCodeModelSpec: OpenCodeModelSpec? = nil,
         openCodeProvider: OpenCodeModelProvider = .openRouter,
         caseMCPCommand: [String]? = nil,
         screenMCPCommand: [String]? = nil,
         openRouterProvider: String? = nil,
         preferTavilySearch: Bool = false,
         webSearchSupport: Bool? = nil,
         lowEffortSupport: Bool? = nil,
         outputTokenLimit: Int? = nil) {
        self.model = model
        self.effort = effort
        self.serviceTier = serviceTier
        self.workingDirectory = workingDirectory
        self.allowActions = allowActions
        self.openCodeModelSpec = openCodeModelSpec
        self.openCodeProvider = openCodeProvider
        self.caseMCPCommand = caseMCPCommand
        self.screenMCPCommand = screenMCPCommand
        self.openRouterProvider = openRouterProvider
        self.preferTavilySearch = preferTavilySearch
        self.webSearchSupport = webSearchSupport
        self.lowEffortSupport = lowEffortSupport
        self.outputTokenLimit = outputTokenLimit
    }
}
