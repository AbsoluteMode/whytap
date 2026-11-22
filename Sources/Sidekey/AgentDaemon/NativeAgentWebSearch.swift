import Foundation

/// How the native Agent searches the web in one turn. By default the Agent
/// model's provider searches (built-in); Tavily serves a model without it, or
/// when the user picks Tavily in API & Models → Models → Search. A Tavily key
/// alone never replaces built-in search.
/// WHY: .project-docs/decisions/2026-11-22-agent-provider-web-search.md
enum NativeAgentWebSearch: Equatable {
    /// The route provider's server-side search tool, billed by that provider.
    case builtIn(OpenCodeModelProvider)
    /// The `web_search` function tool backed by the user's Tavily key.
    case tavily
    /// Neither is available: the model says so instead of guessing.
    case none

    var isBuiltIn: Bool { if case .builtIn = self { return true }; return false }

    /// The turn's search: Tavily when the user picked it and its key exists;
    /// else built-in unless the model is known not to support it; then Tavily
    /// with a key; else none.
    static func resolve(options: AgentRunOptions, tavilyConnected: Bool) -> Self {
        if options.preferTavilySearch, tavilyConnected { return .tavily }
        if let model = options.model, supportsBuiltIn(provider: options.openCodeProvider, model: model,
                                                      catalogFlag: options.webSearchSupport) {
            return .builtIn(options.openCodeProvider)
        }
        return tavilyConnected ? .tavily : .none
    }

    /// The catalog's flag wins when it states one (Anthropic's Models API
    /// `capabilities.server_tools.web_search.supported`). OpenAI publishes no
    /// flag: a few families documented without web search are excluded and a
    /// rejected first request falls back (NativeAgentProvider). OpenRouter's
    /// server tool works on every model (native search or Exa).
    static func supportsBuiltIn(provider: OpenCodeModelProvider, model: String, catalogFlag: Bool?) -> Bool {
        if let catalogFlag { return catalogFlag }
        switch provider {
        case .anthropic, .openRouter: return true
        case .openAI:
            let id = model.lowercased()
            let unsupported = ["gpt-4.1-nano", "gpt-3.5", "o1-mini", "o1-preview", "gpt-4-", "chatgpt-", "gpt-4o-search", "gpt-4o-mini-search",
                               "gpt-audio", "gpt-realtime", "gpt-4o-audio", "gpt-4o-realtime", "codex-mini"]
            return id != "gpt-4" && !unsupported.contains(where: { id.hasPrefix($0) })
        }
    }

    /// At most two searches per request, as the prompt asks; providers that
    /// accept a cap enforce it server-side.
    static let maxSearches = 2

    /// The provider tool added to the request's `tools`. The Anthropic basic
    /// version stays ZDR-eligible and needs no newer API version header.
    /// `limit`: searches still allowed (Anthropic: in its provider turn;
    /// OpenRouter: in this request). OpenRouter forwards `max_uses` only to
    /// Anthropic's native search; other native engines ignore it. So an
    /// `anthropic/` model keeps the default engine (Anthropic's own search,
    /// capped by max_uses) and every other model asks for Exa, which
    /// OpenRouter runs itself and caps before a search runs. A workspace whose
    /// locked Server Tools policy leaves Exa out refuses that with 403; no
    /// other engine is capped before it runs, so the turn then drops this
    /// tool (NativeAgentProvider).
    static func providerTool(for provider: OpenCodeModelProvider, limit: Int = maxSearches, model: String = "") -> [String: Any] {
        let limit = max(1, min(limit, maxSearches))
        switch provider {
        case .anthropic: return ["type": "web_search_20250305", "name": "web_search", "max_uses": limit]
        case .openAI: return ["type": "web_search"]
        case .openRouter:
            var parameters: [String: Any] = ["max_results": 5, "max_uses": limit]
            if pinsEngine(model: model) { parameters["engine"] = "exa" }
            return ["type": "openrouter:web_search", "parameters": parameters]
        }
    }

    /// OpenRouter models other than Claude get the Exa engine pinned.
    static func pinsEngine(model: String) -> Bool { !model.lowercased().hasPrefix("anthropic/") }

    /// One line added to the system prompt for this turn.
    var promptLine: String {
        switch self {
        case .builtIn:
            return "Web search: use the built-in web_search tool for current external facts; the provider runs it. "
                + "Put the URLs that support the answer into finish_answer.sources."
        case .tavily:
            return "Web search: call the web_search function (Tavily) for current external facts, then put the URLs "
                + "that support the answer into finish_answer.sources."
        case .none:
            return "Web search is off: this model has no built-in search and Tavily is not connected. When the request "
                + "asks to search or needs current or recent facts, answer in one line that web search is off for this model "
                + "and is turned on by adding a Tavily key in Settings → API & Models → API keys (status unverified); "
                + "never present recent facts as checked."
        }
    }

    /// What the Search row in API & Models → Models shows: "Anthropic ·
    /// built-in", "OpenRouter · web", "Tavily", "Off — add a Tavily key".
    var label: String {
        switch self {
        case .builtIn(.openRouter): return "OpenRouter · web"
        case .builtIn(let provider): return "\(provider.displayName) · built-in"
        case .tavily: return "Tavily"
        case .none: return "Off — add a Tavily key"
        }
    }

    /// What it costs and who bills it, checked 2026-11-22.
    var priceNote: String {
        switch self {
        case .builtIn(.openRouter):
            return "Exa search, about $7 per 1,000 searches; Claude models use Anthropic’s search at about $10 per 1,000. Billed by OpenRouter."
        case .builtIn(let provider):
            return "About $10 per 1,000 searches plus result tokens. Billed by \(provider.displayName)."
        case .tavily:
            return "One Tavily credit per search; 1,000 free credits a month."
        case .none:
            return "This Agent model has no web search of its own. Add a Tavily key in API keys."
        }
    }

    /// A cited page from built-in search; the fallback source cards when the
    /// model's finish_answer leaves `sources` empty.
    struct Source: Equatable {
        let title: String
        let url: URL

        init?(title: String?, url raw: String?) {
            guard let raw, raw.count <= 4096, !raw.contains(where: \.isWhitespace), let url = URL(string: raw),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false,
                  url.user == nil, url.password == nil else { return nil }
            let text = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.title = String((text.isEmpty ? url.host ?? raw : text).prefix(UsefulLink.maxDescriptionLength))
            self.url = url
        }
    }

    /// Source cards added when the model cited nothing itself: up to five,
    /// citations first, never duplicating a link the answer already has.
    static func fallbackLinks(_ sources: [Source], existing: UsefulActionsBlock) -> [ActionItem] {
        guard !existing.items.contains(where: { if case .link = $0 { return true }; return false }) else { return [] }
        var seen = Set<String>(), links: [ActionItem] = []
        for source in sources where links.count < 5 && seen.insert(source.url.absoluteString).inserted {
            links.append(.link(url: source.url, description: source.title, provider: nil))
        }
        return links
    }
}

/// The Search row of API & Models → Models, beside Speech and LLM: what the
/// Agent searches with now and what its menu offers.
/// WHY: .project-docs/decisions/2026-11-22-agent-provider-web-search.md
struct AgentSearchRow: Equatable {
    /// What the next Agent turn uses.
    let current: NativeAgentWebSearch
    /// The Agent model's built-in search, `nil` when its route has none.
    let builtIn: NativeAgentWebSearch?
    let tavilyConnected: Bool
    let choice: AgentWebSearchChoice

    /// The same options and resolution as the next Agent turn
    /// (`AgentSettingsStore.options(for: .native)`, `NativeAgentWebSearch.resolve`).
    init(options: AgentRunOptions, tavilyConnected: Bool) {
        current = NativeAgentWebSearch.resolve(options: options, tavilyConnected: tavilyConnected)
        var own = options
        own.preferTavilySearch = false
        let builtIn = NativeAgentWebSearch.resolve(options: own, tavilyConnected: false)
        self.builtIn = builtIn.isBuiltIn ? builtIn : nil
        self.tavilyConnected = tavilyConnected
        choice = options.preferTavilySearch ? .tavily : .auto
    }

    /// The orange setup contour: the Agent cannot search at all.
    var needsSetup: Bool { current == .none }
}

extension Notification.Name {
    /// The Tavily key was saved or removed (it writes no preference).
    static let whytapTavilyKeyChanged = Notification.Name("whytap.tavilyKeyChanged")
}
