import Foundation

struct CodexTodoItem: Equatable {
    let text: String
    let completed: Bool
}

enum CodexStreamEvent: Equatable {
    case threadStarted(threadID: String)
    case agentMessage(text: String)
    case commandStarted(command: String)
    /// Live plan state (item.started / item.updated) — full item list.
    case todoListUpdated(items: [CodexTodoItem])
    /// item.started of a file_change — paths + kind of the first change (add/update/delete); multi-file labels are count-based so first kind wins.
    case fileChangeStarted(paths: [String], kind: String)
    case turnCompleted
    case streamError(String)
}

enum CodexStreamJSONParser {
    static func parse(line: String) -> CodexStreamEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return nil }

        switch type {
        case "thread.started":
            if let id = obj["thread_id"] as? String { return .threadStarted(threadID: id) }
            return nil
        case "turn.completed":
            return .turnCompleted
        case "item.started", "item.updated", "item.completed":
            guard let item = obj["item"] as? [String: Any],
                  let itemType = item["type"] as? String else { return nil }
            switch itemType {
            case "agent_message":
                // Only the completed item carries final text; ignore started.
                if type == "item.completed", let text = item["text"] as? String, !text.isEmpty {
                    return .agentMessage(text: text)
                }
                return nil
            case "command_execution":
                if type == "item.started", let cmd = item["command"] as? String {
                    return .commandStarted(command: cmd)
                }
                return nil
            case "todo_list":
                // item.completed carries no new info; only started/updated are useful.
                guard type != "item.completed",
                      let raw = item["items"] as? [[String: Any]] else { return nil }
                let items = raw.compactMap { entry -> CodexTodoItem? in
                    guard let text = entry["text"] as? String else { return nil }
                    return CodexTodoItem(text: text, completed: entry["completed"] as? Bool ?? false)
                }
                return items.isEmpty ? nil : .todoListUpdated(items: items)
            case "file_change":
                guard type == "item.started",
                      let changes = item["changes"] as? [[String: Any]] else { return nil }
                let paths = changes.compactMap { $0["path"] as? String }
                let kind = (changes.first?["kind"] as? String) ?? "update"
                return paths.isEmpty ? nil : .fileChangeStarted(paths: paths, kind: kind)
            case "error":
                // Codex emits benign config/deprecation/under-development
                // warnings on the SAME type:error channel as real failures,
                // but the turn still completes — surfacing them tears the turn
                // down on the client for nothing. Drop them; real errors pass.
                let msg = (item["message"] as? String) ?? ""
                if isBenignWarning(msg) { return nil }
                return msg.isEmpty ? nil : .streamError(msg)
            default:
                return nil
            }
        case "error":
            // Top-level stream error (e.g. an upstream 400 like model-not-supported).
            return streamError(fromWrapped: obj["message"] as? String)
        case "turn.failed":
            let raw = (obj["error"] as? [String: Any])?["message"] as? String
            return streamError(fromWrapped: raw) ?? .streamError("Codex turn failed")
        default:
            return nil
        }
    }

    /// Codex wraps upstream errors as a JSON string inside `message`; pull the
    /// innermost human-readable text and drop benign deprecation noise.
    private static func streamError(fromWrapped raw: String?) -> CodexStreamEvent? {
        guard let raw, !raw.isEmpty else { return nil }
        let msg = unwrapMessage(raw)
        if isBenignWarning(msg) { return nil }
        return msg.isEmpty ? nil : .streamError(msg)
    }

    /// If `raw` is itself a JSON envelope (`{"error":{"message":…}}` or
    /// `{"message":…}`), return the inner text; otherwise return `raw` as-is.
    private static func unwrapMessage(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return raw }
        if let err = obj["error"] as? [String: Any], let m = err["message"] as? String { return m }
        if let m = obj["message"] as? String { return m }
        return raw
    }

    /// Codex emits non-fatal config/feature notices (deprecations, under-
    /// development feature warnings) on the SAME `type:"error"` channel as real
    /// failures. They do NOT abort the turn — the agent still answers and
    /// `turn.completed` arrives — so treating them as stream errors wrongly
    /// tears the turn down on the client. Recognise and drop them. Real
    /// failures (model-not-supported, turn.failed, top-level error) carry none
    /// of these markers and still surface. New Codex versions keep adding such
    /// notices (e.g. `child_agents_md`), so match the stable phrasing Codex
    /// attaches to every suppressible warning, not one feature name.
    private static func isBenignWarning(_ msg: String) -> Bool {
        let lower = msg.lowercased()
        return lower.contains("deprecated")
            || msg.contains("codex_hooks")
            || msg.contains("suppress_unstable_features_warning")
            || lower.contains("under-development features")
    }
}
