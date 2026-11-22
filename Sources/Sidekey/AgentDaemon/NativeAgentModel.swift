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
        guard let model = options.model, !model.isEmpty else { throw NativeAgentError.message("Choose an Agent model in Settings → API & Models.") }
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
        let outputLimit = min(8192, options.openCodeModelSpec?.outputLimit ?? 8192)
        var request: URLRequest
        // Searches still allowed: Anthropic enforces max_uses across its own
        // turn, so its tool stays unchanged within that turn; OpenAI and
        // OpenRouter cap per request, so they get what is left of the turn.
        let remaining = NativeAgentWebSearch.maxSearches
            - (options.openCodeProvider == .anthropic ? providerTurnBase : searchesUsed)
        let search = builtInSearch && !tools.isEmpty && remaining > 0
        let searchTool = NativeAgentWebSearch.providerTool(for: options.openCodeProvider, limit: remaining)
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
            request = try NativeAgentHTTP.request(url: URL(string: "https://api.openai.com/v1/responses")!, key: key, body: body)
        case .anthropic:
            request = try NativeAgentHTTP.request(url: URL(string: "https://api.anthropic.com/v1/messages")!, key: key, body: [
                "model": model, "system": system, "messages": messages, "max_tokens": outputLimit,
                "tools": tools.map { tool -> [String: Any] in
                    var result: [String: Any] = ["name": tool["name"]!, "description": tool["description"]!, "input_schema": tool["parameters"]!]
                    if let strict = tool["strict"] as? Bool { result["strict"] = strict }
                    return result
                } + (search ? [searchTool] : [])
            ])
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
        diagnosticRequest += 1
        let trace = NativeAgentDiagnostics.Trace(turn: diagnosticTurn, request: diagnosticRequest,
            provider: options.openCodeProvider,
            pinned: options.openCodeProvider == .openRouter && options.openRouterProvider != nil,
            toolsCount: tools.count, outputLimit: outputLimit, sink: diagnosticsSink)
        let wireMessages = options.openCodeProvider == .openRouter ? [["role": "system", "content": system]] + messages : messages
        trace.emit(.request, bytes: request.httpBody?.count, shape: .init(messages: wireMessages))
        var responseStatus: Int?, responseBytes: Int?
        do {
            let response: [String: Any]
            do {
                let result = try await http.response(request)
                response = result.object; responseStatus = result.status; responseBytes = result.bytes
            } catch {
                usageSink(.init(context: .init(feature: .agent, account: options.openCodeProvider.account, model: model),
                                            currency: .usd, amount: nil, basis: .unavailable))
                throw error
            }
            let usage = response["usage"] as? [String: Any]
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
                       finish: .init(rawValue: finish) ?? .other)
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
            trace.emit(.failed, status: responseStatus, bytes: responseBytes, error: detail, failure: failure)
            throw error
        }
    }

    private mutating func accept(_ response: [String: Any]) throws -> (String, [NativeAgentToolCall]) {
        var text = ""
        var calls: [NativeAgentToolCall] = []
        // `searches`: billable or budgeted web calls; `webWork`: any provider
        // web activity (an OpenAI open_page, an OpenRouter search without
        // citations), which also needs the turn to continue to an answer.
        var searches = 0, paused = false, webWork = false
        pendingSearch = false
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
                throw NativeAgentError.message("The model did not finish its response. Try a shorter request.")
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
                throw NativeAgentError.message("The model did not finish its response. Try a shorter request.")
            }
            paused = response["stop_reason"] as? String == "pause_turn"
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
                    if let id = block["tool_use_id"] as? String { answered.insert(id) }
                    // An error result is an object, not a list: no pages.
                    for result in block["content"] as? [[String: Any]] ?? [] {
                        if let page = NativeAgentWebSearch.Source(title: result["title"] as? String, url: result["url"] as? String) {
                            resultSources.append(page)
                        }
                    }
                default:
                    text += block["text"] as? String ?? ""
                    for citation in block["citations"] as? [[String: Any]] ?? []
                        where citation["type"] as? String == "web_search_result_location" {
                        if let page = NativeAgentWebSearch.Source(title: citation["title"] as? String, url: citation["url"] as? String) {
                            citedSources.append(page)
                        }
                    }
                }
            }
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
            let reported = AIUsageNumber.nonnegative(details?["web_search_requests"]).map { Int(min($0, 1_000)) }
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
