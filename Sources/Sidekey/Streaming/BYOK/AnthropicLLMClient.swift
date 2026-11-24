import Foundation
import OSLog

extension OpenRouterLLMClient {
    /// Direct Anthropic text requests use Messages, whose system prompt is a
    /// top-level field. OpenRouter-specific parameters never enter this call.
    func completeAnthropic(endpoint: OpenAICompatibleLLMEndpoint, model: String,
                           messages: [OpenRouterChatMessage]) async throws -> String {
        guard let key = endpoint.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw OpenRouterLLMError.missingKey
        }
        struct Body: Encodable {
            let model: String
            let max_tokens: Int
            let system: String?
            let messages: [OpenRouterChatMessage]
            let output_config: OutputConfig?
            let thinking: Thinking?
            struct OutputConfig: Encodable { let effort: String }
            struct Thinking: Encodable { let type: String }
        }
        let system = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        let conversation = messages.filter { $0.role != "system" }
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in ModelCatalogFetcher.anthropicHeaders(apiKey: key) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // Drop Smart asks for the least thinking this model accepts.
        // WHY: .project-docs/decisions/2026-11-24-smart-minimal-reasoning.md
        var reasoning: SmartDirectReasoning.Anthropic? = nil
        if profile == .smart, !reasoningRefusals.contains(.anthropic, model: model) {
            reasoning = SmartDirectReasoning.anthropic(model: model)
        }
        func body(_ fields: SmartDirectReasoning.Anthropic?) throws -> Data {
            try JSONEncoder().encode(Body(model: model, max_tokens: 8192,
                                          system: system.isEmpty ? nil : system,
                                          messages: conversation,
                                          output_config: fields?.effort.map(Body.OutputConfig.init),
                                          thinking: fields?.thinking.map(Body.Thinking.init)))
        }
        request.httpBody = try body(reasoning)
        try Task.checkCancellation()
        let requestStarted = ProcessInfo.processInfo.systemUptime
        var (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        var refused = false
        if reasoning != nil, let status = (response as? HTTPURLResponse)?.statusCode, status == 400 || status == 422 {
            // The model refused the request with these fields: it goes once
            // more exactly as before this policy, and gets no field again.
            reasoningRefusals.record(.anthropic, model: model)
            refused = true
            reasoning = nil
            request.httpBody = try body(nil)
            (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
        }
        let requestMs = Int((ProcessInfo.processInfo.systemUptime - requestStarted) * 1000)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterLLMError.unexpectedStatus(-1, nil)
        }
        let usage = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["usage"] as? [String: Any]
        if profile != .standard {
            // Catalog model ID and numbers only, at the default level so the
            // system log keeps them; no prompt, reply, key or error body.
            let details = usage?["output_tokens_details"] as? [String: Any]
            os_log("cleanup model=%{public}@ provider=anthropic effort=%{public}@ status=%{public}d llm_ms=%{public}d output_tokens=%{public}d thinking_tokens=%{public}d effort_refused=%{public}d",
                   log: Self.log, type: .default,
                   Self.safeDiagnosticID(model), reasoning.map(\.diagnosticLabel) ?? "default",
                   http.statusCode, requestMs,
                   (usage?["output_tokens"] as? Int) ?? -1, (details?["thinking_tokens"] as? Int) ?? -1,
                   refused ? 1 : 0)
        }
        guard (200..<300).contains(http.statusCode) else {
            // Keep response bodies, prompts and keys out of diagnostic errors.
            // An input/context error says nothing about the model's usability.
            if http.statusCode == 400 || http.statusCode == 422 { throw OpenRouterLLMError.inputRejected }
            throw OpenRouterLLMError.unexpectedStatus(http.statusCode, nil)
        }
        if let context = AIUsageTaskScope.context {
            // The API reports tokens rather than an actual dollar charge: estimate it.
            let amount = AnthropicUsagePrices.cost(model: model, usage: usage)
            usageSink(AIUsageEvent(context: context, currency: .usd, amount: amount,
                                   basis: amount == nil ? .unavailable : .estimated))
        }
        struct Reply: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
            let stop_reason: String?
        }
        let reply: Reply
        do { reply = try JSONDecoder().decode(Reply.self, from: data) }
        catch { throw OpenRouterLLMError.decoding("Invalid Anthropic response") }
        guard reply.stop_reason != "max_tokens" else { throw OpenRouterLLMError.outputLimitReached }
        let text = reply.content.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenRouterLLMError.emptyContent
        }
        return text
    }
}
