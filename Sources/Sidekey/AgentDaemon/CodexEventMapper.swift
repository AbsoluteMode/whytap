import Foundation

enum CodexEventMapper {
    static func map(_ event: CodexStreamEvent) -> [AgentSSEEvent] {
        switch event {
        case .threadStarted:
            return []   // thread_id captured separately by CodexProvider
        case .agentMessage(let text):
            // Each Codex agent_message is a complete message; the last one
            // before turn.completed is the final answer (finalAnswer replaces
            // any prior). Do not also paint model-authored prose into the
            // status line; only app-owned tool labels belong in app chrome.
            var events: [AgentSSEEvent] = []
            if let extraction = AgentUsefulLinksExtractor.extract(from: text) {
                if !extraction.answer.isEmpty {
                    events.append(.finalAnswer(text: extraction.answer))
                }
                events.append(.blockComplete(.usefulActions(extraction.block)))
                return events
            }
            events.append(.finalAnswer(text: text))
            return events
        case .commandStarted(let command):
            return [.toolExecuting(tool: "Shell", label: AgentStepName.forShellCommand(command))]
        case .todoListUpdated(let items):
            return [.toolExecuting(tool: "Plan", label: AgentStepName.forTodoList(items))]
        case .fileChangeStarted(let paths, let kind):
            return [.toolExecuting(tool: "Files", label: AgentStepName.forFileChange(paths: paths, kind: kind))]
        case .turnCompleted:
            return [.done(sources: [])]
        case .streamError(let message):
            return [.error(code: "codex_error", message: message, retryable: false)]
        }
    }
}
