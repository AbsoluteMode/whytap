import Foundation

/// `opencode run --format json` emits complete text/tool parts, one JSON line
/// at a time. step_finish can mean "tool-calls", so only process exit finalizes
/// a turn. This prevents losing the answer after a tool execution.
// WHY: .project-docs/decisions/2026-10-22-agent-answers-and-screen.md
struct OpenCodeEventMapper {
    private(set) var sessionID: String?
    private(set) var answer = ""
    private(set) var failed = false
    private var seenParts: Set<String> = []
    /// The Agent route's provider, named in the messages that send the user
    /// to their key.
    private let provider: OpenCodeModelProvider

    init(provider: OpenCodeModelProvider = .openRouter) {
        self.provider = provider
    }

    mutating func map(line: String) -> [AgentSSEEvent] {
        guard let data = line.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = event["type"] as? String else { return [] }
        if let id = event["sessionID"] as? String, !id.isEmpty { sessionID = id }
        let part = event["part"] as? [String: Any] ?? [:]
        switch type {
        case "text":
            guard let text = part["text"] as? String, !text.isEmpty else { return [] }
            if let id = part["id"] as? String, !seenParts.insert(id).inserted { return [] }
            if !answer.isEmpty { answer += "\n\n" }
            answer += text
            // Keep complete parts here until successful exit. Feeding raw
            // action JSON into the store's narration fallback would leak it
            // back into an actions-only answer with no prose.
            return []
        case "tool_use":
            answer = ""
            let tool = part["tool"] as? String ?? "tool"
            let label: String
            switch tool {
            case "bash", "shell": label = "Running a command"
            case "read": label = "Reading"
            case "edit", "write", "apply_patch": label = "Editing"
            case "glob", "grep": label = "Searching"
            case "webfetch", "websearch": label = "Looking up information"
            default: label = "Using a tool"
            }
            return [.toolExecuting(tool: tool, label: label)]
        case "step_finish":
            if part["reason"] as? String == "tool-calls" { answer = "" }
            return []
        case "step_start":
            answer = ""
            return [.statusNarration(text: "Working…")]
        case "error":
            failed = true
            // Provider error objects can echo API keys, input text or URLs.
            // Show an actionable local message rather than raw provider data.
            let error = event["error"] as? [String: Any] ?? [:]
            let name = (error["name"] as? String ?? error["type"] as? String ?? "").lowercased()
            if name.contains("auth") {
                return [.error(code: "opencode_auth", message: "Check your \(provider.displayName) key in Settings → Keys & models.", retryable: false)]
            }
            return [.error(code: "opencode_error", message: "OpenCode couldn’t complete the request. Check the selected model and your \(provider.displayName) balance, then retry.", retryable: true)]
        default:
            return []
        }
    }

    func finalEvents() -> [AgentSSEEvent] {
        guard let extraction = AgentUsefulLinksExtractor.extract(from: answer) else {
            return [.finalAnswer(text: answer), .done(sources: [])]
        }
        return [.finalAnswer(text: extraction.answer),
                .blockComplete(.usefulActions(extraction.block)), .done(sources: [])]
    }
}
