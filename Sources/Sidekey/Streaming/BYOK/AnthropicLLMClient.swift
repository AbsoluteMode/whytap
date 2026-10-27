import Foundation

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
        request.httpBody = try JSONEncoder().encode(Body(model: model, max_tokens: 8192,
                                                        system: system.isEmpty ? nil : system,
                                                        messages: conversation))
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterLLMError.unexpectedStatus(-1, nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            // Keep response bodies, prompts and keys out of diagnostic errors.
            // An input/context error says nothing about the model's usability.
            if http.statusCode == 400 || http.statusCode == 422 { throw OpenRouterLLMError.inputRejected }
            throw OpenRouterLLMError.unexpectedStatus(http.statusCode, nil)
        }
        if let context = AIUsageTaskScope.context {
            // The API reports tokens rather than an actual dollar charge: estimate it.
            let usage = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["usage"] as? [String: Any]
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
