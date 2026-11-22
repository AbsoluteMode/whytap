import Foundation
import os.log

/// Local structural evidence only. Never pass arbitrary strings to the sink.
/// WHY: .project-docs/decisions/2026-10-22-native-agent.md (Local diagnostics)
enum NativeAgentDiagnostics {
    enum Stage: String, Codable { case request, failed, accepted }
    enum Failure: String, Codable { case cancelled, timeout, network, response }
    enum Provider: String, Codable { case openRouter, openAI, anthropic }
    enum Scope: String, Codable { case agent }
    enum Finish: String, Codable { case stop, tool_calls, length, error, end_turn, tool_use, completed, other }
    enum Envelope: String, Codable { case http, root200, choice200 }
    enum Field: String, Codable, CaseIterable {
        case messages, tool_calls, tool_call_id, arguments, reasoning, reasoning_content, reasoning_details, max_tokens, max_completion_tokens
    }
    enum Tool: String, Codable {
        case web_search, capture_screen, show_actions, finish_answer, run_command, write_file, read_file, list_directory, search_files, fetch_url, case_list_keys, whytap, unknown
    }
    struct ErrorShape: Codable {
        // Protocol names chosen from a closed set; unknown values never leave memory.
        let category: Category
        let parameter: Field?
        let mentions: [Field]
        let truncated: Bool
        let parsed: Bool
        let envelope: Envelope
        /// The provider refused the web search tool itself: positive evidence
        /// that the model or account has no built-in search. Not a keyword
        /// match; no provider text is kept.
        /// WHY: .project-docs/decisions/2026-11-22-agent-provider-web-search.md
        let rejectsWebSearch: Bool?

        /// Affirmative, tool-specific evidence only; an ambiguous error stays
        /// on the selected route. Only the provider's own `message` counts
        /// (OpenRouter's `metadata.raw` quotes upstream text), and:
        /// - the request carried a search tool (`searchToolIndex`);
        /// - the error is untyped: an OpenRouter category or an OpenAI `code`
        ///   outside the refusal codes is about something else;
        /// - a location (`param`, or a leading `messages[0]:`-style path)
        ///   must be the search tool itself or its `type`, never one of its
        ///   options (`max_uses`, `search_context_size`) or any other place,
        ///   and the error must still refuse it (a refusal code or word);
        /// - otherwise, with quoted text removed (a quoted tool identifier is
        ///   kept) and no size or context wording, the refusal must name the
        ///   tool's identifier in one clause ("Tool 'web_search' is not
        ///   supported", "does not support tool types: web_search_20250305"),
        ///   or the message must open with an account or model policy ("Web
        ///   search is disabled for this organization").
        static func refusesWebSearch(error: [String: Any]?, category: Category, searchToolIndex: Int?) -> Bool {
            guard let searchToolIndex, category == .unknown,
                  let message = (error?["message"] as? String).map({ String($0.prefix(16_384)).lowercased() }) else { return false }
            if let code = error?["code"] as? String,
               !["unsupported_value", "invalid_value", "unsupported_parameter", "tool_not_supported"].contains(code) {
                return false
            }
            let plain = unquoted(message)
            let size = ["context", "too long", "too large", "maximum", "exceeds", "exceeded", "token", "length"]
            guard !size.contains(where: plain.contains) else { return false }
            if let path = (error?["param"] as? String)?.lowercased() ?? leadingPath(message) {
                if let (index, field) = toolsLocation(path) {
                    guard index == searchToolIndex, ["", ".type", "[type]"].contains(field) else { return false }
                    let code = error?["code"] as? String
                    return code == "unsupported_value" || code == "tool_not_supported"
                        || plain.range(of: #"\b(?:not supported|unsupported|disabled|not enabled|not available|unavailable|not allowed|not permitted|turned off|unknown|does not support|doesn't support)\b"#,
                                       options: .regularExpression) != nil
                }
                if path != "tools" { return false }
            }
            return refusalPatterns.contains { plain.range(of: $0, options: .regularExpression) != nil }
        }

        private static let toolID = #"(?:openrouter:web_search|web_search(?:_preview|_\d{8})?)"#
        private static let refusal = #"(?:not supported|unsupported|disabled|not enabled|not available|unavailable|not allowed|not permitted|turned off)"#
        static let refusalPatterns = [
            toolID + #"(?:\s+(?:server\s+|hosted\s+)?tools?)?(?:\s+types?)?\s+(?:is|are)\s+(?:currently\s+)?"# + refusal,
            #"(?:does not|doesn't|do not|don't|cannot|can't)\s+(?:support|use|allow)\s+(?:the\s+)?(?:(?:server\s+|hosted\s+)?tool(?:\s+type)?s?:?\s+)?"# + toolID,
            #"(?:unsupported|unknown|disallowed|disabled)\s+(?:server\s+|hosted\s+)?tool(?:\s+type)?s?:?\s+"# + toolID,
            #"^(?:the\s+)?web[\s_]?search(?:\s+tool)?\s+(?:is|has been)\s+(?:not enabled|disabled|turned off|not available|unavailable)\s+(?:for|on|in)\s+(?:this|your)\s+(?:organization|organisation|org|workspace|account|model|project|api key)\b"#,
        ]

        /// `messages[0]: ...`, `tools.3.type: ...`: where a validation error points.
        static func leadingPath(_ message: String) -> String? {
            let pattern = #"^\s*((?:messages|input|tools|system|instructions|tool_choice|model|max_tokens|max_output_tokens|include|metadata|text|reasoning)(?:\.[a-z0-9_]+|\[\d+\])*)\s*:"#
            guard let range = message.range(of: pattern, options: .regularExpression) else { return nil }
            return message[range].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ":")))
        }

        /// `tools[3]` → (3, ""), `tools.3.max_uses` → (3, ".max_uses").
        static func toolsLocation(_ path: String) -> (index: Int, field: String)? {
            guard let range = path.range(of: #"^tools(?:\[\d+\]|\.\d+)"#, options: .regularExpression),
                  let index = Int(path[range].filter(\.isNumber)) else { return nil }
            return (index, String(path[range.upperBound...]))
        }

        /// Removes quoted text (often the user's own words) and keeps a quoted
        /// tool identifier such as 'web_search' as a bare word.
        static func unquoted(_ text: String) -> String {
            let pattern = #"(?<![\p{L}\p{N}])['"`‘“]([^'"`’”]*)['"`’”](?![\p{L}\p{N}])"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
            var result = text
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let whole = Range(match.range, in: text), let inner = Range(match.range(at: 1), in: text) else { continue }
                let content = String(text[inner])
                let keep = content.range(of: "^" + toolID + "$", options: .regularExpression) != nil
                result.replaceSubrange(whole, with: keep ? content : " ")
            }
            return result
        }

        enum Category: String, Codable {
            case context_length_exceeded, string_too_long, invalid_prompt, invalid_request
            case max_tokens_exceeded, token_limit_exceeded, provider_overloaded, provider_unavailable, rate_limit_exceeded, unknown
        }
        init(object: [String: Any]?, truncated: Bool = false, envelope: Envelope = .http, searchToolIndex: Int? = nil) {
            let error = object?["error"] as? [String: Any]
            let metadata = error?["metadata"] as? [String: Any]
            category = Category(rawValue: metadata?["error_type"] as? String ?? "") ?? .unknown
            parameter = Field(rawValue: error?["param"] as? String ?? "")
            // These are keyword-presence hints, not a diagnosis. Providers may
            // quote input; no fragment of their text is retained or echoed.
            let text = [error?["message"] as? String, metadata?["raw"] as? String]
                .compactMap { $0 }.map { String($0.prefix(16_384)).lowercased() }.joined(separator: " ")
            mentions = Field.allCases.filter { text.contains($0.rawValue) }
            rejectsWebSearch = Self.refusesWebSearch(error: error, category: category, searchToolIndex: searchToolIndex)
            self.truncated = truncated
            parsed = object != nil
            self.envelope = envelope
        }
    }
    struct Shape: Codable {
        var messages = 0, toolCalls = 0, toolResults = 0, unmatchedResults = 0, missingResults = 0
        var stringArguments = 0, objectArguments = 0, otherArguments = 0, nullContent = 0, emptyContent = 0
        var reasoningDetails = 0, plaintextReasoning = 0, reasoningAlias = 0, nativeThinking = 0
        var system = 0, user = 0, assistant = 0, otherRoles = 0
        var tools: [Tool] = []

        init(messages: [[String: Any]]) {
            self.messages = messages.count
            var callIDs = Set<String>(), resultIDs = Set<String>()
            for message in messages {
                switch message["role"] as? String {
                case "system": system += 1
                case "user": user += 1
                case "assistant": assistant += 1
                case "tool": break
                default: otherRoles += 1
                }
                if message["content"] is NSNull { nullContent += 1 }
                if let content = message["content"] as? String, content.isEmpty { emptyContent += 1 }
                if let details = message["reasoning_details"] as? [Any] { reasoningDetails += details.count }
                if message["reasoning"] is String { plaintextReasoning += 1 }
                if message["reasoning_content"] is String { reasoningAlias += 1 }
                var calls = message["tool_calls"] as? [[String: Any]] ?? []
                if message["type"] as? String == "reasoning" { nativeThinking += 1 }
                for block in message["content"] as? [[String: Any]] ?? [] {
                    switch block["type"] as? String {
                    case "tool_use":
                        calls.append(["id": block["id"] ?? NSNull(), "function": [
                            "name": block["name"] ?? NSNull(), "arguments": block["input"] ?? NSNull()]])
                    case "tool_result":
                        toolResults += 1
                        if let id = block["tool_use_id"] as? String { resultIDs.insert(id) }
                    case "thinking", "redacted_thinking": nativeThinking += 1
                    default: break
                    }
                }
                if message["type"] as? String == "function_call" {
                    calls.append(["id": message["call_id"] ?? NSNull(), "function": message])
                }
                for call in calls {
                    toolCalls += 1
                    if let id = call["id"] as? String { callIDs.insert(id) }
                    let function = call["function"] as? [String: Any] ?? [:]
                    let tool = Tool(rawValue: function["name"] as? String ?? "") ?? .unknown
                    if !tools.contains(tool) { tools.append(tool) }
                    if function["arguments"] is String { stringArguments += 1 }
                    else if function["arguments"] is [String: Any] { objectArguments += 1 }
                    else { otherArguments += 1 }
                }
                if message["role"] as? String == "tool" || message["type"] as? String == "function_call_output" {
                    toolResults += 1
                    if let id = message["tool_call_id"] as? String ?? message["call_id"] as? String { resultIDs.insert(id) }
                }
            }
            unmatchedResults = resultIDs.subtracting(callIDs).count
            missingResults = callIDs.subtracting(resultIDs).count
        }
    }
    struct Event: Encodable {
        let version = 1
        let turn: UUID
        let request: Int
        let provider: Provider
        let scope: Scope
        let pinned: Bool
        let toolsCount: Int
        let outputLimit: Int
        let stage: Stage
        let status: Int?
        let bytes: Int?
        let elapsedMS: Int
        let shape: Shape?
        let error: ErrorShape?
        let failure: Failure?
        let finish: Finish?

        var json: String? {
            guard let data = try? JSONEncoder().encode(self) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
    struct Trace {
        let turn: UUID
        let request: Int
        let provider: OpenCodeModelProvider
        let pinned: Bool
        let toolsCount: Int
        let outputLimit: Int
        let sink: (Event) -> Void
        private let started = ContinuousClock.now

        func emit(_ stage: Stage, status: Int? = nil, bytes: Int? = nil, shape: Shape? = nil,
                  error: ErrorShape? = nil, failure: Failure? = nil, finish: Finish? = nil) {
            let elapsed = started.duration(to: .now).components
            let service: Provider
            switch provider { case .openRouter: service = .openRouter; case .openAI: service = .openAI; case .anthropic: service = .anthropic }
            sink(Event(turn: turn, request: request, provider: service,
                scope: .agent,
                pinned: pinned, toolsCount: toolsCount, outputLimit: outputLimit, stage: stage,
                status: status, bytes: bytes, elapsedMS: Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000),
                shape: shape, error: error, failure: failure, finish: finish))
        }
    }
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "native-agent")
    static func record(_ event: Event) {
        guard let json = event.json else { return }
        os_log("%{public}@", log: log, type: event.stage == .failed ? .error : .default, json)
    }
}
