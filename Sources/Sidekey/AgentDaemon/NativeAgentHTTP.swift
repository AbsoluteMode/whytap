import Foundation

enum NativeAgentError: Error, LocalizedError {
    case message(String)
    case service(message: String, status: Int, diagnostics: NativeAgentDiagnostics.ErrorShape)
    var errorDescription: String? {
        switch self { case .message(let text), .service(let text, _, _): return text }
    }
}

/// No retries of a model/tool request: a retry could repeat a paid call or an action.
struct NativeAgentHTTP {
    var session: URLSession = .shared

    struct Response {
        let object: [String: Any]
        let status: Int
        let bytes: Int
    }

    func json(_ request: URLRequest, limit: Int = 4_000_000) async throws -> [String: Any] {
        try await response(request, limit: limit).object
    }

    func response(_ request: URLRequest, limit: Int = 4_000_000) async throws -> Response {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw NativeAgentError.message("The service returned an invalid response.") }
        guard (200..<300).contains(http.statusCode) else {
            if [401, 402, 403, 429].contains(http.statusCode) {
                throw Self.serviceError(status: http.statusCode, object: nil)
            }
            var data = Data()
            var truncated = false
            // Only OpenRouter's documented, allowlisted categories are useful
            // here. Error messages/raw metadata can contain keys or user text.
            // Bound the transient read; never log, store or echo its contents.
            if request.url?.host == "openrouter.ai" {
                do {
                    for try await byte in bytes {
                        if data.count >= 16_384 { truncated = true; break }
                        data.append(byte)
                        if data.count % 4096 == 0 { try Task.checkCancellation() }
                    }
                } catch {
                    try Task.checkCancellation()
                    data.removeAll() // Keep the known HTTP failure if its body cannot be read.
                }
            }
            try Task.checkCancellation()
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw Self.serviceError(status: http.statusCode, object: object, truncated: truncated)
        }
        if response.expectedContentLength > limit { throw NativeAgentError.message("The service response is too large.") }
        var data = Data()
        for try await byte in bytes {
            if data.count >= limit { throw NativeAgentError.message("The service response is too large.") }
            data.append(byte)
            if data.count % 4096 == 0 { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeAgentError.message("The service returned invalid JSON.")
        }
        return Response(object: object, status: http.statusCode, bytes: data.count)
    }

    /// A non-streaming completion can fail after HTTP 200 was committed.
    /// Inspect both documented locations after recording any reported usage.
    static func openRouterError(in object: [String: Any]) -> NativeAgentError? {
        if object["error"] is [String: Any] { return serviceError(status: 200, object: object, envelope: .root200) }
        if let choice = (object["choices"] as? [[String: Any]])?.first,
           choice["error"] is [String: Any] { return serviceError(status: 200, object: choice, envelope: .choice200) }
        return nil
    }

    // The only external strings accepted here are fixed protocol identifiers.
    // Do not relax this to a regex: a syntactically valid code can be a secret.
    // WHY: .project-docs/decisions/2026-10-22-native-agent.md (Provider continuations)
    private static func serviceError(status: Int, object: [String: Any]?, truncated: Bool = false,
                                     envelope: NativeAgentDiagnostics.Envelope = .http) -> NativeAgentError {
        func failure(_ message: String) -> NativeAgentError {
            .service(message: message, status: status,
                     diagnostics: .init(object: object, truncated: truncated, envelope: envelope))
        }
        let error = object?["error"] as? [String: Any]
        let metadata = error?["metadata"] as? [String: Any]
        let category = metadata?["error_type"] as? String
        let message: String?
        switch category {
        case "context_length_exceeded":
            message = "The selected provider’s context limit was exceeded. Try a shorter request."
        case "string_too_long":
            message = "The provider rejected an oversized text field. Try a shorter request."
        case "invalid_prompt", "invalid_request":
            let tag = category == "invalid_prompt" ? "invalid_prompt" : "invalid_request"
            message = "The provider rejected the conversation format (\(tag))."
        case "max_tokens_exceeded":
            message = "The provider could not finish within its response limit."
        case "token_limit_exceeded":
            message = "The provider’s request limit was reached. Try a smaller request."
        case "provider_overloaded", "provider_unavailable", "rate_limit_exceeded":
            message = "The selected provider is unavailable or busy. Try again later."
        default:
            message = nil
        }
        if let message { return failure(message) }
        switch status {
        case 401, 403: return failure("The service refused this API key. Check Settings.")
        case 402: return failure("The provider has insufficient credit.")
        case 429: return failure("The service is busy or its usage limit was reached. Try again later.")
        case 200: return failure("The selected provider returned an error. Try again.")
        default: return failure("The service returned HTTP \(status). Try again.")
        }
    }

    static func request(url: URL, key: String, body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }
}
