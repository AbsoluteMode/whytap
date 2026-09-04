import Foundation

/// The subset of a Claude tool_use `input` we surface in progress labels.
/// Memberwise init with all-nil defaults keeps test fixtures terse.
struct ClaudeToolInput: Equatable {
    var description: String?
    var command: String?
    var filePath: String?
    var pattern: String?
    var subject: String?
    var activeForm: String?
    var taskId: String?
    var status: String?

    init(description: String? = nil, command: String? = nil,
         filePath: String? = nil, pattern: String? = nil,
         subject: String? = nil, activeForm: String? = nil,
         taskId: String? = nil, status: String? = nil) {
        self.description = description
        self.command = command
        self.filePath = filePath
        self.pattern = pattern
        self.subject = subject
        self.activeForm = activeForm
        self.taskId = taskId
        self.status = status
    }

    init(json: [String: Any]) {
        description = json["description"] as? String
        command = json["command"] as? String
        filePath = json["file_path"] as? String
        pattern = json["pattern"] as? String
        subject = json["subject"] as? String
        activeForm = json["activeForm"] as? String
        // taskId arrives as a string today; tolerate a number.
        taskId = (json["taskId"] as? String) ?? (json["taskId"] as? Int).map(String.init)
        status = json["status"] as? String
    }
}

enum ClaudeStreamEvent: Equatable {
    case initSession(sessionID: String)
    case textDelta(String)
    /// A complete assistant text block — the narrative preamble the model
    /// writes before tool calls. Source for statusNarration.
    case assistantText(String)
    case toolUse(id: String, name: String, input: ClaudeToolInput)
    /// Text part of a user/tool_result event. Needed by ClaudeTaskRegistry to
    /// match "Task #N created" back to the TaskCreate that produced it.
    case toolResult(toolUseId: String, text: String)
    case errorCategory(String)            // from system/api_retry
    case result(sessionID: String?, isError: Bool, costUSD: Double?, text: String?)
    case permissionRequest(requestId: String, toolName: String, summary: String, inputJSON: String)
}

enum StreamJSONParser {
    /// One stdout line can carry several content blocks (text + tool_use in a
    /// single assistant message) — hence an array, in block order.
    static func parse(line: String) -> [ClaudeStreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return [] }

        switch type {
        case "stream_event":
            if let event = obj["event"] as? [String: Any],
               let delta = event["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                return [.textDelta(text)]
            }
            return []
        case "system":
            switch obj["subtype"] as? String {
            case "init":
                if let id = obj["session_id"] as? String { return [.initSession(sessionID: id)] }
            case "api_retry":
                if let err = obj["error"] as? String { return [.errorCategory(err)] }
            default:
                break
            }
            return []
        case "assistant":
            guard let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { return [] }
            var events: [ClaudeStreamEvent] = []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        events.append(.assistantText(text))
                    }
                case "tool_use":
                    if let name = block["name"] as? String {
                        events.append(.toolUse(
                            id: block["id"] as? String ?? "",
                            name: name,
                            input: ClaudeToolInput(json: block["input"] as? [String: Any] ?? [:])
                        ))
                    }
                default:
                    break   // thinking blocks arrive empty in headless — skip
                }
            }
            return events
        case "user":
            guard let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { return [] }
            var events: [ClaudeStreamEvent] = []
            for block in content where block["type"] as? String == "tool_result" {
                guard let toolUseId = block["tool_use_id"] as? String else { continue }
                events.append(.toolResult(toolUseId: toolUseId,
                                          text: Self.textContent(of: block["content"])))
            }
            return events
        case "result":
            return [.result(
                sessionID: obj["session_id"] as? String,
                isError: obj["is_error"] as? Bool ?? false,
                costUSD: obj["total_cost_usd"] as? Double,
                // Claude Code's final answer text. We surface this as the clean
                // `finalAnswer` rather than the accumulated token narration.
                text: obj["result"] as? String
            )]
        case "control_request":
            guard let req = obj["request"] as? [String: Any],
                  req["subtype"] as? String == "can_use_tool",
                  let requestId = obj["request_id"] as? String,
                  let toolName = req["tool_name"] as? String else { return [] }
            let input = req["input"] as? [String: Any] ?? [:]
            let inputData = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
                ?? Data("{}".utf8)
            let summary = (req["description"] as? String)
                ?? (req["display_name"] as? String) ?? toolName
            return [.permissionRequest(requestId: requestId, toolName: toolName,
                                       summary: summary,
                                       inputJSON: String(decoding: inputData, as: UTF8.self))]
        default:
            return []
        }
    }

    /// tool_result `content` is either a plain string or an array of
    /// `{type:"text", text:...}` blocks; normalise to one string.
    private static func textContent(of value: Any?) -> String {
        if let s = value as? String { return s }
        if let blocks = value as? [[String: Any]] {
            return blocks
                .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        }
        return ""
    }
}
