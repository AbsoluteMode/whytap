import Foundation
import os.log

/// Local structural evidence only. Never pass arbitrary strings to the sink.
/// WHY: .project-docs/decisions/2026-10-22-native-agent.md (Local diagnostics)
enum NativeAgentDiagnostics {
    enum Stage: String, Codable { case request, failed, accepted }
    enum Failure: String, Codable { case cancelled, timeout, network, response }
    enum Provider: String, Codable { case openRouter, openAI, anthropic }
    enum Scope: String, Codable { case agent, meetingAssistant }
    enum Finish: String, Codable { case stop, tool_calls, length, error, end_turn, tool_use, completed, other }
    enum Envelope: String, Codable { case http, root200, choice200 }
    enum Field: String, Codable, CaseIterable {
        case messages, tool_calls, tool_call_id, arguments, reasoning, reasoning_content, reasoning_details, max_tokens, max_completion_tokens
    }
    enum Tool: String, Codable {
        case web_search, capture_screen, show_actions, finish_answer, run_command, write_file, read_file, list_directory, search_files, fetch_url, case_list_keys, unknown
    }
    struct ErrorShape: Codable {
        // Protocol names chosen from a closed set; unknown values never leave memory.
        let category: Category
        let parameter: Field?
        let mentions: [Field]
        let truncated: Bool
        let parsed: Bool
        let envelope: Envelope

        enum Category: String, Codable {
            case context_length_exceeded, string_too_long, invalid_prompt, invalid_request
            case max_tokens_exceeded, token_limit_exceeded, provider_overloaded, provider_unavailable, rate_limit_exceeded, unknown
        }
        init(object: [String: Any]?, truncated: Bool = false, envelope: Envelope = .http) {
            let error = object?["error"] as? [String: Any]
            let metadata = error?["metadata"] as? [String: Any]
            category = Category(rawValue: metadata?["error_type"] as? String ?? "") ?? .unknown
            parameter = Field(rawValue: error?["param"] as? String ?? "")
            // These are keyword-presence hints, not a diagnosis. Providers may
            // quote input; no fragment of their text is retained or echoed.
            let text = [error?["message"] as? String, metadata?["raw"] as? String]
                .compactMap { $0 }.map { String($0.prefix(16_384)).lowercased() }.joined(separator: " ")
            mentions = Field.allCases.filter { text.contains($0.rawValue) }
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
        let feature: AIFeature
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
                scope: feature == .meetingAssistant ? .meetingAssistant : .agent,
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
