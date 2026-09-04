import Foundation

/// Lifecycle status of a single chat turn persisted in `agent_entries`.
/// Stored as a raw string so a downgraded client (pre-Stage-3) can still
/// read the row via the legacy SELECT — the column is ignored there.
enum ChatStatus: String, Codable, Equatable {
    case pending
    case streaming
    case done
    case error
}

/// A row from `agent_entries` after the Stage 3 migration. Carries the
/// legacy fields plus the new `title` / `blocksJSON` / `status` columns.
/// Pure value type — Equatable so SwiftUI/Combine diffing is easy.
struct ChatRow: Equatable, Identifiable {
    let id: Int64
    let createdAt: Date
    let queryText: String
    let queryMode: HistoryQueryMode
    let title: String?
    let blocksJSON: String?
    let responseMarkdown: String
    let toolNames: [String]
    let status: ChatStatus

    init(
        id: Int64,
        createdAt: Date,
        queryText: String,
        queryMode: HistoryQueryMode,
        title: String?,
        blocksJSON: String?,
        responseMarkdown: String,
        toolNames: [String],
        status: ChatStatus
    ) {
        self.id = id
        self.createdAt = createdAt
        self.queryText = queryText
        self.queryMode = queryMode
        self.title = title
        self.blocksJSON = blocksJSON
        self.responseMarkdown = responseMarkdown
        self.toolNames = toolNames
        self.status = status
    }
}

