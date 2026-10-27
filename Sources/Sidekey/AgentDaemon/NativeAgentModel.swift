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
}

/// Keeps provider-native assistant items intact within a turn, including
/// OpenAI reasoning items and Anthropic thinking signatures.
struct NativeAgentModel {
    let options: AgentRunOptions
    let key: String
    let system: String
    var messages: [[String: Any]]
    var http = NativeAgentHTTP()
    var usageSink: (AIUsageEvent) -> Void = AIUsageRecorder.record
    var usageFeature: AIFeature = .agent

    init(options: AgentRunOptions, key: String, system: String, history: [NativeAgentConversation.Pair], prompt: String,
         http: NativeAgentHTTP = NativeAgentHTTP(), usageSink: @escaping (AIUsageEvent) -> Void = AIUsageRecorder.record) {
        self.options = options; self.key = key; self.system = system; self.http = http; self.usageSink = usageSink
        messages = history.flatMap { [["role": "user", "content": $0.user], ["role": "assistant", "content": $0.assistant]] }
        messages.append(["role": "user", "content": prompt])
    }

    mutating func next(tools: [[String: Any]]) async throws -> (String, [NativeAgentToolCall]) {
        guard let model = options.model, !model.isEmpty else { throw NativeAgentError.message("Choose an Agent model in Settings → API & Models.") }
        // Bound accumulated text before a provider request; image data has its own cap.
        let textBudget = min(180_000, max(8000, ((options.openCodeModelSpec?.contextLimit ?? 32_768) - 4096) * 2))
        var textSize = system.count
        func count(_ value: Any) {
            if let string = value as? String { if !string.hasPrefix("data:image/") { textSize += string.count } }
            else if let object = value as? [String: Any] { for (k, v) in object where k != "data" { count(v) } }
            else if let array = value as? [Any] { array.forEach(count) }
        }
        count(messages)
        guard textSize < textBudget else { throw NativeAgentError.message("This task filled the agent’s context. Start a shorter request.") }
        let outputLimit = min(8192, options.openCodeModelSpec?.outputLimit ?? 8192)
        var request: URLRequest
        switch options.openCodeProvider {
        case .openAI:
            request = try NativeAgentHTTP.request(url: URL(string: "https://api.openai.com/v1/responses")!, key: key, body: [
                "model": model, "instructions": system, "input": messages, "store": false,
                "include": ["reasoning.encrypted_content"], "max_output_tokens": outputLimit,
                "tools": tools.map { ["type": "function", "name": $0["name"]!, "description": $0["description"]!,
                                       "parameters": $0["parameters"]!, "strict": false] }
            ])
        case .anthropic:
            request = try NativeAgentHTTP.request(url: URL(string: "https://api.anthropic.com/v1/messages")!, key: key, body: [
                "model": model, "system": system, "messages": messages, "max_tokens": outputLimit,
                "tools": tools.map { ["name": $0["name"]!, "description": $0["description"]!, "input_schema": $0["parameters"]!] }
            ])
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openRouter:
            var body: [String: Any] = ["model": model, "messages": [["role": "system", "content": system]] + messages,
                                      "max_tokens": outputLimit, "tools": tools.map { ["type": "function", "function": $0] }]
            if let provider = options.openRouterProvider {
                body["provider"] = ["only": [provider], "allow_fallbacks": false]
            }
            request = try NativeAgentHTTP.request(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!, key: key, body: body)
            request.setValue("Whytap", forHTTPHeaderField: "X-Title")
        }
        if tools.isEmpty, let data = request.httpBody,
           var body = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            body.removeValue(forKey: "tools")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let response: [String: Any]
        do { response = try await http.json(request) }
        catch {
            usageSink(.init(context: .init(feature: usageFeature, account: options.openCodeProvider.account, model: model),
                                        currency: .usd, amount: nil, basis: .unavailable))
            throw error
        }
        let usage = response["usage"] as? [String: Any]
        let cost = options.openCodeProvider == .openRouter ? AIUsageNumber.nonnegative(usage?["cost"]) : nil
        usageSink(.init(context: .init(feature: usageFeature, account: options.openCodeProvider.account, model: model),
                                    currency: .usd, amount: cost, basis: cost == nil ? .unavailable : .reported))
        if options.openCodeProvider == .openRouter,
           let error = NativeAgentHTTP.openRouterError(in: response) { throw error }
        return try accept(response)
    }

    private mutating func accept(_ response: [String: Any]) throws -> (String, [NativeAgentToolCall]) {
        var text = ""
        var calls: [NativeAgentToolCall] = []
        switch options.openCodeProvider {
        case .openAI:
            guard response["status"] as? String == "completed", let output = response["output"] as? [[String: Any]] else {
                throw NativeAgentError.message("The model did not finish its response. Try a shorter request.")
            }
            messages += output
            for item in output {
                if item["type"] as? String == "function_call" {
                    calls.append(try call(id: item["call_id"], name: item["name"], arguments: item["arguments"]))
                } else if item["type"] as? String == "message" {
                    for block in item["content"] as? [[String: Any]] ?? [] {
                        text += block["text"] as? String ?? block["refusal"] as? String ?? ""
                    }
                }
            }
        case .anthropic:
            guard let content = response["content"] as? [[String: Any]],
                  ["end_turn", "tool_use"].contains(response["stop_reason"] as? String ?? "") else {
                throw NativeAgentError.message("The model did not finish its response. Try a shorter request.")
            }
            messages.append(["role": "assistant", "content": content])
            for block in content {
                if block["type"] as? String == "tool_use" {
                    calls.append(try call(id: block["id"], name: block["name"], arguments: block["input"]))
                } else { text += block["text"] as? String ?? "" }
            }
        case .openRouter:
            guard let choice = (response["choices"] as? [[String: Any]])?.first,
                  ["stop", "tool_calls"].contains(choice["finish_reason"] as? String ?? ""),
                  let message = choice["message"] as? [String: Any] else {
                throw NativeAgentError.message("The model did not finish its response. Try a shorter request.")
            }
            text = message["content"] as? String ?? message["refusal"] as? String ?? ""
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
            messages.append(replay)
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
