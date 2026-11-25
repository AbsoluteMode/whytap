import Foundation

struct NativeAgentToolCall {
    let id: String
    let name: String
    let arguments: [String: Any]
}

struct NativeAgentToolResult {
    var text: String
    var image: String? = nil
    var mimeType: String = "image/jpeg"
    var actions: UsefulActionsBlock? = nil
    /// App-owned line for a confirmed Whytap change ("Drop Smart → model").
    var change: String? = nil
}

/// Keeps provider-native assistant items intact within a turn, including
/// OpenAI reasoning items and Anthropic thinking signatures.
struct NativeAgentModel {
    let options: AgentRunOptions
    let key: String
    var system: String
    var messages: [[String: Any]]
    /// Adds the route provider's server-side web search to tool requests.
    /// WHY: .project-docs/decisions/2026-11-22-agent-provider-web-search.md
    var builtInSearch = false
    /// Built-in searches the provider ran in the last response.
    private(set) var searchesInLastResponse = 0
    /// Built-in web tool calls spent in this turn, across requests. The app's
    /// limit (`NativeAgentWebSearch.maxSearches`) holds for the whole turn.
    private(set) var searchesUsed = 0
    /// Anthropic counts `max_uses` per provider turn (pause_turn and
    /// tool_result continuations included); a plain user message starts a new
    /// one. Searches spent before the current provider turn began.
    private var providerTurnBase = 0
    /// The last response stopped to be continued with no tool results:
    /// Anthropic `pause_turn`, or provider web work with no function call.
    private(set) var awaitingContinuation = false
    /// Anthropic: a search was requested in the last response and its result
    /// arrives only in the next request (search beside a function call).
    private(set) var pendingSearch = false
    private var citedSources: [NativeAgentWebSearch.Source] = []
    private var resultSources: [NativeAgentWebSearch.Source] = []
    /// Pages the provider's search cited or returned this turn, citations first.
    var searchSources: [NativeAgentWebSearch.Source] { citedSources + resultSources }
    var http = NativeAgentHTTP()
    var usageSink: (AIUsageEvent) -> Void = AIUsageRecorder.record
    var diagnosticsSink: (NativeAgentDiagnostics.Event) -> Void
    private let diagnosticTurn = UUID()
    private var diagnosticRequest = 0
    /// Models that refused the reasoning fields while this app runs.
    var reasoningRefusals = NativeAgentEffort.refusals
    /// Whether the turn's first accepted exchange had the provider's own web
    /// search; until then each request follows the search it actually sends.
    private var reasoningSearch: Bool?
    /// Whether this turn sends the fields for a model that refused them; set
    /// at the turn's first request and by an accepted refusal repeat.
    private var reasoningRefused: Bool?
    /// A request of this turn was sent: only the turn's very first request
    /// may repeat on a refusal, once, also when the provider search fallback
    /// sends the turn's next request.
    private var requestSentInTurn = false

    init(options: AgentRunOptions, key: String, system: String, history: [NativeAgentConversation.Pair], prompt: String,
         http: NativeAgentHTTP = NativeAgentHTTP(), usageSink: @escaping (AIUsageEvent) -> Void = AIUsageRecorder.record,
         diagnosticsSink: @escaping (NativeAgentDiagnostics.Event) -> Void = NativeAgentDiagnostics.record) {
        self.options = options; self.key = key; self.system = system; self.http = http; self.usageSink = usageSink
        self.diagnosticsSink = diagnosticsSink
        messages = history.flatMap { [["role": "user", "content": $0.user], ["role": "assistant", "content": $0.assistant]] }
        messages.append(["role": "user", "content": prompt])
    }

    mutating func next(tools: [[String: Any]], structuredCompletion: Bool = false) async throws -> (String, [NativeAgentToolCall]) {
        guard !structuredCompletion || !tools.isEmpty else { throw NativeAgentFinalAnswer.invalid() }
        guard let model = options.model, !model.isEmpty else { throw NativeAgentError.message("Choose an Agent model in Settings → Keys & models.") }
        // Bound accumulated text before a provider request; image data has its own cap.
        let textBudget = min(180_000, max(8000, ((options.openCodeModelSpec?.contextLimit ?? 32_768) - 4096) * 2))
        var textSize = system.count
        func count(_ value: Any) {
            if let string = value as? String { if !string.hasPrefix("data:image/") { textSize += string.count } }
            // Opaque search state is replayed verbatim but is not model text.
            else if let object = value as? [String: Any] {
                for (k, v) in object where !["data", "encrypted_content", "encrypted_index"].contains(k) { count(v) }
            }
            else if let array = value as? [Any] { array.forEach(count) }
        }
        count(messages)
        guard textSize < textBudget else { throw NativeAgentError.message("This task filled the agent’s context. Start a shorter request.") }
        // Direct Anthropic and OpenAI: thinking and answer share this limit,
        // and a request may wait up to the turn's own time limit, as a
        // non-streamed answer sends nothing until it is complete.
        // WHY: .project-docs/decisions/2026-11-23-agent-low-effort.md
        let direct = options.openCodeProvider != .openRouter
        let outputCap = direct ? Self.directOutputCap : 8192
        // The catalog's own output limit wins even when it gives no context
        // length (no spec); the spec's limit defaults to 16,384 when unknown.
        let modelLimit = direct ? options.outputTokenLimit ?? options.openCodeModelSpec?.outputLimit
            : options.openCodeModelSpec?.outputLimit
        let outputLimit = min(outputCap, modelLimit ?? outputCap)
        // The least reasoning the model accepts. The setting follows the
        // request that can start the turn (a first request whose search tool
        // was refused goes again without it) and is kept after the turn's
        // first accepted exchange: a thinking setting must not change inside
        // a tool loop. WHY: .project-docs/decisions/2026-11-24-agent-minimal-reasoning.md
        let turnSearch = reasoningSearch ?? builtInSearch
        let refusalAPI = NativeAgentEffort.refusalAPI(options.openCodeProvider)
        let refusalKey = NativeAgentEffort.refusalKey(model: model, provider: options.openCodeProvider,
                                                      openRouterPin: options.openRouterProvider)
        let turnRefused = reasoningRefused ?? reasoningRefusals.contains(refusalAPI, model: refusalKey)
        func reasoningFields(refused: Bool) -> NativeAgentEffort.Request? {
            NativeAgentEffort.request(provider: options.openCodeProvider, model: model, catalogFlag: options.lowEffortSupport,
                                      openRouter: options.openRouterReasoning, providerSearch: turnSearch, refused: refused)
        }
        let reasoning = reasoningFields(refused: turnRefused)
        // Only the turn's very first request may repeat, once: a thinking
        // setting must not change after the model answered within the turn,
        // and the search fallback's request (or one after an earlier repeat)
        // gets no second repeat.
        let fallback = reasoningFields(refused: true)
        // A repeat must change what was sent.
        let mayRepeat = reasoning != nil && !turnRefused && !requestSentInTurn
            && !NSDictionary(dictionary: reasoning?.fields ?? [:]).isEqual(to: fallback?.fields ?? [:])
        requestSentInTurn = true
        // Searches still allowed: Anthropic enforces max_uses across its own
        // turn, so its tool stays unchanged within that turn; OpenAI and
        // OpenRouter cap per request, so they get what is left of the turn.
        let remaining = NativeAgentWebSearch.maxSearches
            - (options.openCodeProvider == .anthropic ? providerTurnBase : searchesUsed)
        let search = builtInSearch && !tools.isEmpty && remaining > 0
        let searchTool = NativeAgentWebSearch.providerTool(for: options.openCodeProvider, limit: remaining, model: model)
        func makeRequest(_ effort: [String: Any]?) throws -> URLRequest {
            var request: URLRequest
            switch options.openCodeProvider {
            case .openAI:
                var body: [String: Any] = [
                    "model": model, "instructions": system, "input": messages, "store": false,
                    "include": ["reasoning.encrypted_content"] + (search ? ["web_search_call.action.sources"] : []),
                    "max_output_tokens": outputLimit,
                    "tools": tools.map { ["type": "function", "name": $0["name"]!, "description": $0["description"]!,
                                           "parameters": $0["parameters"]!, "strict": $0["strict"] as? Bool ?? false] }
                        + (search ? [searchTool] : [])
                ]
                // Caps built-in tool calls (searches) per response, not functions.
                if search { body["max_tool_calls"] = remaining }
                body.merge(effort ?? [:]) { $1 }
                request = try NativeAgentHTTP.request(url: URL(string: "https://api.openai.com/v1/responses")!, key: key, body: body,
                                                      timeout: Self.directTimeout)
            case .anthropic:
                var body: [String: Any] = [
                    "model": model, "system": system, "messages": messages, "max_tokens": outputLimit,
                    "tools": tools.map { tool -> [String: Any] in
                        var result: [String: Any] = ["name": tool["name"]!, "description": tool["description"]!, "input_schema": tool["parameters"]!]
                        if let strict = tool["strict"] as? Bool { result["strict"] = strict }
                        return result
                    } + (search ? [searchTool] : [])
                ]
                body.merge(effort ?? [:]) { $1 }
                request = try NativeAgentHTTP.request(url: URL(string: "https://api.anthropic.com/v1/messages")!, key: key, body: body,
                                                      timeout: Self.directTimeout)
                request.setValue(nil, forHTTPHeaderField: "Authorization")
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            case .openRouter:
                var body: [String: Any] = ["model": model, "messages": [["role": "system", "content": system]] + messages,
                                          "max_tokens": outputLimit,
                                          "tools": tools.map { ["type": "function", "function": $0] } + (search ? [searchTool] : [])]
                if let provider = options.openRouterProvider {
                    body["provider"] = ["only": [provider], "allow_fallbacks": false]
                }
                body.merge(effort ?? [:]) { $1 }
                request = try NativeAgentHTTP.request(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!, key: key, body: body)
                request.setValue("Whytap", forHTTPHeaderField: "X-Title")
            }
            if (tools.isEmpty || structuredCompletion), let data = request.httpBody,
               var body = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if tools.isEmpty { body.removeValue(forKey: "tools") }
                if structuredCompletion {
                    // Current Claude models reject forced any/tool choice, even
                    // without explicit thinking. Strict schemas + local terminal
                    // validation also work with auto, directly and via OpenRouter.
                    // WHY: .project-docs/decisions/2026-10-22-native-agent.md (Structured completion)
                    let claude = options.openCodeProvider == .anthropic
                        || (options.openCodeProvider == .openRouter && model.lowercased().hasPrefix("anthropic/"))
                    body["tool_choice"] = options.openCodeProvider == .anthropic ? ["type": "auto"] as Any
                        : (claude ? "auto" : "required") as Any
                    if options.openCodeProvider == .openRouter {
                        var provider = body["provider"] as? [String: Any] ?? [:]
                        provider["require_parameters"] = true
                        body["provider"] = provider
                    }
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            return request
        }
        do {
            let result = try await send(makeRequest(reasoning?.fields), model: model, toolsCount: tools.count, outputLimit: outputLimit,
                                        reasoning: reasoning, repeatsOnRefusal: mayRepeat)
            reasoningSearch = turnSearch
            reasoningRefused = turnRefused
            return result
        } catch where mayRepeat && NativeAgentEffort.refused(error, provider: options.openCodeProvider) && !Task.isCancelled {
            // The provider refused a reasoning setting: the same request goes
            // once more with what a refusing model gets (OpenAI `low`, else
            // no field). Only an accepted answer to that repeat shows the
            // fields were the cause; the model then gets that until relaunch.
            // The rest of this turn (a search fallback included) sends the
            // fallback too, without a further repeat.
            reasoningRefused = true
            let result = try await send(makeRequest(fallback?.fields), model: model, toolsCount: tools.count, outputLimit: outputLimit,
                                        reasoning: fallback, effortRetry: true)
            reasoningRefusals.record(refusalAPI, model: refusalKey)
            reasoningSearch = turnSearch
            return result
        } catch {
            // A refused request that was not repeated after all (cancelled
            // in between) still reports its usage.
            if mayRepeat, NativeAgentEffort.refused(error, provider: options.openCodeProvider) {
                usageSink(.init(context: .init(feature: .agent, account: options.openCodeProvider.account, model: model),
                                currency: .usd, amount: nil, basis: .unavailable))
            }
            throw error
        }
    }

    /// One provider request with its diagnostics and usage.
    private mutating func send(_ request: URLRequest, model: String, toolsCount: Int, outputLimit: Int,
                               reasoning: NativeAgentEffort.Request?, repeatsOnRefusal: Bool = false,
                               effortRetry: Bool = false) async throws -> (String, [NativeAgentToolCall]) {
        diagnosticRequest += 1
        let trace = NativeAgentDiagnostics.Trace(turn: diagnosticTurn, request: diagnosticRequest,
            provider: options.openCodeProvider,
            pinned: options.openCodeProvider == .openRouter && options.openRouterProvider != nil,
            toolsCount: toolsCount, outputLimit: outputLimit, effort: reasoning?.effort, thinking: reasoning?.thinking,
            effortRetry: effortRetry ? true : nil, sink: diagnosticsSink)
        let wireMessages = options.openCodeProvider == .openRouter ? [["role": "system", "content": system]] + messages : messages
        trace.emit(.request, bytes: request.httpBody?.count, shape: .init(messages: wireMessages))
        var responseStatus: Int?, responseBytes: Int?
        // Counts of a response that is then rejected (an HTTP-200 error, a
        // cut or malformed answer) still reach the failed event.
        var responseUsage: [String: Any]?
        do {
            let response: [String: Any]
            do {
                let result = try await http.response(request)
                response = result.object; responseStatus = result.status; responseBytes = result.bytes
            } catch {
                // A refused request that goes again without its reasoning
                // fields did not run the model: the repeat reports the usage.
                if !(repeatsOnRefusal && NativeAgentEffort.refused(error, provider: options.openCodeProvider)) {
                    usageSink(.init(context: .init(feature: .agent, account: options.openCodeProvider.account, model: model),
                                    currency: .usd, amount: nil, basis: .unavailable))
                }
                throw error
            }
            let usage = response["usage"] as? [String: Any]
            responseUsage = usage
            // OpenRouter reports its charge; Anthropic reports tokens, priced as an estimate.
            let cost: Double?, basis: AIUsageBasis
            switch options.openCodeProvider {
            case .openRouter: cost = AIUsageNumber.nonnegative(usage?["cost"]); basis = .reported
            case .anthropic: cost = AnthropicUsagePrices.cost(model: model, usage: usage); basis = .estimated
            case .openAI: cost = nil; basis = .unavailable
            }
            usageSink(.init(context: .init(feature: .agent, account: options.openCodeProvider.account, model: model),
                                        currency: .usd, amount: cost, basis: cost == nil ? .unavailable : basis))
            if options.openCodeProvider == .openRouter,
               let error = NativeAgentHTTP.openRouterError(in: response) { throw error }
            let result = try accept(response)
            let finish = (response["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String
                ?? response["stop_reason"] as? String ?? response["status"] as? String ?? ""
            trace.emit(.accepted, status: responseStatus, bytes: responseBytes, shape: .init(messages: messages),
                       finish: .init(rawValue: finish) ?? .other, usage: .init(usage))
            return result
        } catch {
            var detail: NativeAgentDiagnostics.ErrorShape?
            if case NativeAgentError.service(_, let status, let diagnostics) = error {
                responseStatus = status; detail = diagnostics
            }
            let failure: NativeAgentDiagnostics.Failure
            if error is CancellationError || Task.isCancelled { failure = .cancelled }
            else if let network = error as? URLError {
                failure = network.code == .cancelled ? .cancelled : network.code == .timedOut ? .timeout : .network
            }
            else { failure = .response }
            trace.emit(.failed, status: responseStatus, bytes: responseBytes, error: detail, failure: failure,
                       usage: .init(responseUsage))
            throw error
        }
    }

    /// Output cap for direct Anthropic and OpenAI requests (thinking plus
    /// answer); a lower catalog limit wins. OpenRouter keeps 8192.
    static let directOutputCap = 16_384
    /// A direct request may wait as long as the whole turn may run
    /// (`NativeAgentProvider`); OpenRouter keeps the 60-second idle limit.
    static let directTimeout: TimeInterval = 180
    static let outputLimitMessage = "The answer reached the model’s output limit. Ask for a shorter answer or split the task."

    /// The last response was a finished plain-text reply: Anthropic
    /// `end_turn` with only text and thinking blocks and no tool call. Any
    /// other stop reason or block (a server tool, an unknown type) is not.
    private(set) var plainTextReply = false

    private mutating func accept(_ response: [String: Any]) throws -> (String, [NativeAgentToolCall]) {
        var text = ""
        var calls: [NativeAgentToolCall] = []
        // `searches`: billable or budgeted web calls; `webWork`: any provider
        // web activity (an OpenAI open_page, an OpenRouter search without
        // citations), which also needs the turn to continue to an answer.
        var searches = 0, paused = false, webWork = false
        pendingSearch = false
        plainTextReply = false
        func cite(_ annotations: Any?) {
            for annotation in annotations as? [[String: Any]] ?? [] where annotation["type"] as? String == "url_citation" {
                // OpenAI puts url/title on the annotation; OpenRouter nests them.
                let fields = annotation["url_citation"] as? [String: Any] ?? annotation
                if let source = NativeAgentWebSearch.Source(title: fields["title"] as? String, url: fields["url"] as? String) {
                    citedSources.append(source)
                }
            }
        }
        switch options.openCodeProvider {
        case .openAI:
            guard response["status"] as? String == "completed", let output = response["output"] as? [[String: Any]] else {
                let reason = (response["incomplete_details"] as? [String: Any])?["reason"] as? String
                throw NativeAgentError.message(reason == "max_output_tokens" ? Self.outputLimitMessage
                    : "The model did not finish its response. Try a shorter request.")
            }
            messages += output
            for item in output {
                if item["type"] as? String == "function_call" {
                    calls.append(try call(id: item["call_id"], name: item["name"], arguments: item["arguments"]))
                } else if item["type"] as? String == "web_search_call" {
                    // Every built-in call (search, open_page, find_in_page)
                    // counts against max_tool_calls and the turn's budget.
                    let action = item["action"] as? [String: Any]
                    searches += 1; webWork = true
                    for source in action?["sources"] as? [[String: Any]] ?? [] {
                        if let page = NativeAgentWebSearch.Source(title: source["title"] as? String, url: source["url"] as? String) {
                            resultSources.append(page)
                        }
                    }
                } else if item["type"] as? String == "message" {
                    for block in item["content"] as? [[String: Any]] ?? [] {
                        text += block["text"] as? String ?? block["refusal"] as? String ?? ""
                        cite(block["annotations"])
                    }
                }
            }
        case .anthropic:
            // pause_turn: a server tool (search) stopped a long turn; the
            // paused content is sent back as-is to let the model continue.
            guard let content = response["content"] as? [[String: Any]],
                  ["end_turn", "tool_use", "pause_turn"].contains(response["stop_reason"] as? String ?? "") else {
                throw NativeAgentError.message(response["stop_reason"] as? String == "max_tokens" ? Self.outputLimitMessage
                    : "The model did not finish its response. Try a shorter request.")
            }
            paused = response["stop_reason"] as? String == "pause_turn"
            var onlyText = response["stop_reason"] as? String == "end_turn"
            // Server tool blocks (with encrypted_content) stay verbatim: the
            // provider rejects a continuation that changes them.
            messages.append(["role": "assistant", "content": content])
            var requested = Set<String>(), answered = Set<String>()
            for block in content {
                switch block["type"] as? String {
                case "tool_use":
                    calls.append(try call(id: block["id"], name: block["name"], arguments: block["input"]))
                case "server_tool_use":
                    if block["name"] as? String == "web_search" {
                        searches += 1; webWork = true
                        if let id = block["id"] as? String { requested.insert(id) }
                    }
                case "web_search_tool_result":
                    // A result can arrive in a later response than its
                    // server_tool_use (search beside a function call): web work
                    // that needs an answer, counted once with its request.
                    webWork = true
                    if let id = block["tool_use_id"] as? String { answered.insert(id) }
                    // An error result is an object, not a list: no pages.
                    for result in block["content"] as? [[String: Any]] ?? [] {
                        if let page = NativeAgentWebSearch.Source(title: result["title"] as? String, url: result["url"] as? String) {
                            resultSources.append(page)
                        }
                    }
                case "text":
                    text += block["text"] as? String ?? ""
                    for citation in block["citations"] as? [[String: Any]] ?? []
                        where citation["type"] as? String == "web_search_result_location" {
                        if let page = NativeAgentWebSearch.Source(title: citation["title"] as? String, url: citation["url"] as? String) {
                            citedSources.append(page)
                        }
                    }
                case "thinking", "redacted_thinking":
                    break
                default:
                    // An unknown block is never read as answer text.
                    onlyText = false
                }
                if ["server_tool_use", "web_search_tool_result", "tool_use"].contains(block["type"] as? String ?? "") {
                    onlyText = false
                }
            }
            plainTextReply = onlyText && calls.isEmpty
            pendingSearch = !requested.subtracting(answered).isEmpty
        case .openRouter:
            guard let choice = (response["choices"] as? [[String: Any]])?.first,
                  ["stop", "tool_calls"].contains(choice["finish_reason"] as? String ?? ""),
                  let message = choice["message"] as? [String: Any] else {
                throw NativeAgentError.message("The model did not finish its response. Try a shorter request.")
            }
            text = message["content"] as? String ?? message["refusal"] as? String ?? ""
            let annotations = (message["annotations"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "url_citation" }
            cite(annotations)
            // OpenRouter runs its server tool inside the request. Its usage
            // reports the count; citations alone still show a search ran.
            let details = (response["usage"] as? [String: Any])?["server_tool_use_details"] as? [String: Any]
            // web_search_requests when reported; otherwise the executed
            // server-tool steps (web search is the only server tool sent).
            let reported = (AIUsageNumber.nonnegative(details?["web_search_requests"])
                ?? AIUsageNumber.nonnegative(details?["tool_calls_executed"])).map { Int(min($0, 1_000)) }
            searches = reported ?? (annotations.isEmpty ? 0 : 1)
            webWork = searches > 0 || !annotations.isEmpty
            let rawCalls = message["tool_calls"] as? [[String: Any]] ?? []
            for item in rawCalls {
                let function = item["function"] as? [String: Any] ?? [:]
                calls.append(try call(id: item["id"], name: function["name"], arguments: function["arguments"]))
            }
            // Replay the request contract, not arbitrary response extensions.
            // In particular call() tolerates object arguments, but the next
            // request must encode them as a JSON string. Keep opaque reasoning
            // details intact and avoid also echoing their plaintext duplicate.
            // WHY: .project-docs/decisions/2026-10-22-native-agent.md (Provider continuations)
            var replay: [String: Any] = ["role": "assistant", "content": message["content"] ?? NSNull()]
            if !calls.isEmpty {
                replay["tool_calls"] = try zip(rawCalls, calls).map { original, call -> [String: Any] in
                    let function = original["function"] as? [String: Any]
                    let arguments: String
                    if let original = function?["arguments"] as? String { arguments = original }
                    else { arguments = String(decoding: try JSONSerialization.data(withJSONObject: call.arguments), as: UTF8.self) }
                    return ["id": call.id, "type": "function", "function": ["name": call.name,
                        "arguments": arguments]]
                }
            }
            if let details = message["reasoning_details"] as? [[String: Any]], !details.isEmpty {
                replay["reasoning_details"] = details
            } else if let reasoning = message["reasoning"] as? String ?? message["reasoning_content"] as? String {
                replay["reasoning"] = reasoning
            }
            // The search results reach a continuation only through these.
            if !annotations.isEmpty { replay["annotations"] = annotations }
            messages.append(replay)
        }
        searchesInLastResponse = searches
        searchesUsed += searches
        awaitingContinuation = calls.isEmpty && (paused || (builtInSearch && webWork))
        if awaitingContinuation, !paused {
            // Only pause_turn is resumed verbatim. After a finished response a
            // request must not end on the assistant's message (current Claude
            // models reject prefill), so ask for the answer; for Anthropic
            // this starts a new provider turn and its max_uses count.
            messages.append(["role": "user", "content": "Continue: complete the turn with finish_answer using the search results."])
            providerTurnBase = searchesUsed
        }
        guard calls.count <= 12, Set(calls.map(\.id)).count == calls.count else {
            throw NativeAgentError.message("The model requested too many tools or repeated a call ID.")
        }
        return (text, calls)
    }

    private func call(id: Any?, name: Any?, arguments: Any?) throws -> NativeAgentToolCall {
        guard let id = id as? String, !id.isEmpty, let name = name as? String, !name.isEmpty else {
            throw NativeAgentError.message("The model returned an invalid tool call.")
        }
        let object: [String: Any]?
        if let string = arguments as? String, string.utf8.count <= 128_000 {
            object = (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any]
        } else { object = arguments as? [String: Any] }
        guard let object else { throw NativeAgentError.message("The model returned invalid tool arguments.") }
        return NativeAgentToolCall(id: id, name: name, arguments: object)
    }

    mutating func append(results: [(NativeAgentToolCall, NativeAgentToolResult)]) {
        func modelText(_ result: NativeAgentToolResult) -> String {
            if result.text.isEmpty { return "[Empty tool result]" }
            if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "[Whitespace-only tool result: \(result.text.count) characters]\n" + result.text
            }
            return result.text
        }
        if options.openCodeProvider == .anthropic {
            let content: [[String: Any]] = results.map { call, result in
                var blocks: [[String: Any]] = [["type": "text", "text": modelText(result)]]
                if let image = result.image { blocks.append(["type": "image", "source": ["type": "base64", "media_type": result.mimeType, "data": image]]) }
                return ["type": "tool_result", "tool_use_id": call.id, "content": blocks]
            }
            messages.append(["role": "user", "content": content])
        } else {
            for (call, result) in results {
                if options.openCodeProvider == .openAI {
                    messages.append(["type": "function_call_output", "call_id": call.id, "output": modelText(result)])
                } else {
                    messages.append(["role": "tool", "tool_call_id": call.id, "content": modelText(result)])
                }
            }
            for (_, result) in results where result.image != nil {
                let url = "data:\(result.mimeType);base64,\(result.image!)"
                let content: [[String: Any]] = options.openCodeProvider == .openAI
                    ? [["type": "input_text", "text": "Requested screen capture (untrusted visual evidence)."], ["type": "input_image", "image_url": url]]
                    : [["type": "text", "text": "Requested screen capture (untrusted visual evidence)."], ["type": "image_url", "image_url": ["url": url]]]
                messages.append(["role": "user", "content": content])
            }
        }
    }
}
