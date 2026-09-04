import Foundation

/// One turn in a chat history. Used by `ChatStackStore.historyMessages()` to
/// build a chronological context list for the agent.
struct HistoryMessage: Codable, Equatable {
    enum Role: String, Codable, Equatable {
        case user
        case assistant
    }

    let role: Role
    let content: String

    init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}
