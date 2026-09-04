import Foundation

enum ClaudeEventMapper {
    static func map(_ event: ClaudeStreamEvent, registry: ClaudeTaskRegistry? = nil) -> [AgentSSEEvent] {
        switch event {
        case .initSession:
            return []   // session_id captured separately by ClaudeCodeProvider
        case .textDelta(let t):
            // Intermediate narration -> hidden fallback buffer, not the live
            // pill. The clean answer comes from the `result` event below.
            return [.narrationDelta(text: t)]
        case .assistantText:
            // Model-authored pre-tool narration is not app chrome. It often
            // mirrors the final answer and can drift to a language unrelated
            // to the user's latest request.
            return []
        case .toolUse(_, let name, let input):
            if name == "TaskUpdate" {
                // in_progress with a known task -> rich plan label; everything
                // else about task bookkeeping stays silent (no pill churn).
                if input.status == "in_progress",
                   let label = registry?.progressLabel(forTaskId: input.taskId) {
                    return [.toolExecuting(tool: name, label: label)]
                }
                return []
            }
            return [.toolExecuting(tool: name, label: AgentStepName.forClaudeTool(name, input: input))]
        case .toolResult:
            return []   // consumed by ClaudeTaskRegistry, nothing to render
        case .errorCategory(let c):
            return [.error(code: c, message: friendly(c), retryable: c == "rate_limit" || c == "server_error")]
        case .result(_, let isError, _, let text):
            if isError {
                return [.error(code: "agent_error", message: "Claude reported an error", retryable: false)]
            }
            if let text, !text.isEmpty {
                if let extraction = AgentUsefulLinksExtractor.extract(from: text) {
                    var events: [AgentSSEEvent] = []
                    if !extraction.answer.isEmpty {
                        events.append(.finalAnswer(text: extraction.answer))
                    }
                    events.append(.blockComplete(.usefulActions(extraction.block)))
                    events.append(.done(sources: []))
                    return events
                }
                return [.finalAnswer(text: text), .done(sources: [])]
            }
            return [.done(sources: [])]
        case .permissionRequest(let rid, let tool, let summary, let inputJSON):
            return [.permissionRequest(id: rid, toolName: tool, summary: summary, inputJSON: inputJSON)]
        }
    }

    static func friendly(_ c: String) -> String {
        switch c {
        case "authentication_failed":
            return "Claude Code isn't logged in. Open a terminal, run claude, log in, then try again."
        case "billing_error":
            return "Your Claude Agent SDK credit is exhausted. Top up or connect your own API key."
        case "oauth_org_not_allowed":
            return "This Claude account can't use the organization. Reconnect with org access."
        default:
            return c.replacingOccurrences(of: "_", with: " ")
        }
    }
}
