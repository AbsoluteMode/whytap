import Combine
import Foundation
import os.log

/// MainActor-isolated facade over `SQLiteHistoryStore` for the chat-stack
/// UI. Owns an in-memory cache of recent `ChatRow`s (`rows`), keeps it in
/// sync with the DB, and bundles chat lifecycle into ergonomic calls:
/// `startChat` / `updateTitle` / `finalizeChat` / `markChatError` /
/// `recordTool` / `historyMessages` / `wipeAll`.
///
/// All disk I/O happens through `SQLiteHistoryStore`, which is itself
/// internally serialised — `ChatStackStore` is the only thing using these
/// rows from the UI thread.
@MainActor
final class ChatStackStore: ObservableObject {
    /// Maximum number of chats kept in `agent_entries`. Older ones are
    /// FIFO-evicted on every insert.
    nonisolated static let maxRows: Int = 200

    /// Maximum number of completed turns handed to the agent CLI as
    /// conversation history. Pending and error rows are filtered out. Capped
    /// at 20 entries (10 user/assistant pairs) so the resume context stays
    /// small.
    nonisolated static let defaultHistoryLimit: Int = 10

    /// Fallback markdown stored when an error message comes in empty.
    /// `response_markdown` is the only field a downgraded client can
    /// surface for an error row, so it must never be empty.
    nonisolated static let errorPlaceholderMarkdown: String = "Request failed."

    private static let log = OSLog(
        subsystem: "com.rootwise.sidekey",
        category: "agent.chat-stack"
    )

    @Published private(set) var rows: [ChatRow] = []

    private let store: SQLiteHistoryStore
    private let clock: () -> Date

    init(store: SQLiteHistoryStore, clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.clock = clock
        refreshRows()
    }

    /// Convenience initialiser that opens the default on-disk history DB.
    static func shared() throws -> ChatStackStore {
        let store = try SQLiteHistoryStore.shared()
        return ChatStackStore(store: store)
    }

    // MARK: - Lifecycle

    /// Inserts a fresh `pending` row and returns its id. FIFO-evicts the
    /// oldest rows if the table is now past `maxRows`.
    @discardableResult
    func startChat(queryText: String, mode: HistoryQueryMode) -> Int64 {
        let createdAt = clock()
        let rowId: Int64
        do {
            rowId = try store.insertAgentEntry(
                createdAt: createdAt,
                queryText: queryText,
                queryMode: mode,
                responseMarkdown: "",
                toolNames: []
            )
            try store.updateAgentEntry(
                id: rowId,
                title: nil,
                blocksJSON: nil,
                status: .pending,
                responseMarkdown: "",
                toolNames: []
            )
            try enforceCap()
        } catch {
            // History persistence is best-effort. Return 0 — callers that
            // care can check the value, but the user-visible pipeline
            // must not break on disk errors.
            return 0
        }
        refreshRows()
        return rowId
    }

    /// Updates the title shown in the chat list for a row. No-op if the
    /// row no longer exists.
    func updateTitle(rowId: Int64, text: String) {
        guard let row = findRow(rowId: rowId) else { return }
        do {
            try store.updateAgentEntry(
                id: rowId,
                title: text,
                blocksJSON: row.blocksJSON,
                status: row.status,
                responseMarkdown: row.responseMarkdown,
                toolNames: row.toolNames
            )
        } catch {
            return
        }
        refreshRows()
    }

    /// Updates the query text for a row whose canonical text arrived after
    /// insertion. No-op if the row no longer exists.
    func updateQueryText(rowId: Int64, text: String) {
        guard let row = findRow(rowId: rowId) else { return }
        do {
            try store.updateAgentEntry(
                id: rowId,
                queryText: text,
                title: row.title,
                blocksJSON: row.blocksJSON,
                status: row.status,
                responseMarkdown: row.responseMarkdown,
                toolNames: row.toolNames
            )
        } catch {
            return
        }
        refreshRows()
    }

    /// Marks the chat as `done`, persisting the rendered blocks (as JSON)
    /// and the markdown rollup used by old clients on downgrade.
    func finalizeChat(rowId: Int64, blocks: [UIBlock], markdown: String) {
        guard let row = findRow(rowId: rowId) else { return }
        let blocksJSON = encodeBlocks(blocks)
        do {
            try store.updateAgentEntry(
                id: rowId,
                title: row.title,
                blocksJSON: blocksJSON,
                status: .done,
                responseMarkdown: markdown,
                toolNames: row.toolNames
            )
        } catch {
            return
        }
        refreshRows()
    }

    /// Marks the chat as `error`. `response_markdown` is guaranteed
    /// non-empty (downgrade-safety) — a blank message gets replaced with
    /// `errorPlaceholderMarkdown`.
    func markChatError(rowId: Int64, message: String) {
        guard let row = findRow(rowId: rowId) else { return }
        let safeMarkdown = message.isEmpty ? Self.errorPlaceholderMarkdown : message
        do {
            try store.updateAgentEntry(
                id: rowId,
                title: row.title,
                blocksJSON: row.blocksJSON,
                status: .error,
                responseMarkdown: safeMarkdown,
                toolNames: row.toolNames
            )
        } catch {
            return
        }
        refreshRows()
    }

    /// Appends a tool name to the row's `tool_names` list with the same
    /// set-like dedupe behaviour as the legacy `AgentController` did.
    func recordTool(rowId: Int64, tool: String) {
        guard let row = findRow(rowId: rowId) else { return }
        guard !row.toolNames.contains(tool) else { return }
        let updated = row.toolNames + [tool]
        do {
            try store.updateAgentEntry(
                id: rowId,
                title: row.title,
                blocksJSON: row.blocksJSON,
                status: row.status,
                responseMarkdown: row.responseMarkdown,
                toolNames: updated
            )
        } catch {
            return
        }
        refreshRows()
    }

    // MARK: - History payload

    /// Returns the last `limit` completed (`status == .done`) chats as a
    /// flat `[user, assistant, user, assistant, ...]` list in
    /// chronological order (oldest first) — the shape the agent resume
    /// context expects for its history.
    ///
    /// Rows whose `queryText` or `responseMarkdown` is empty (or
    /// whitespace-only) after trimming are skipped entirely — every
    /// `HistoryMessage.content` handed to the agent must be non-empty,
    /// so a single empty `.done` row (tool-only turn, SchemaGuard
    /// filtered every block, ...) would otherwise poison every resume
    /// context until it falls out of the window.
    func historyMessages(limit: Int = ChatStackStore.defaultHistoryLimit) -> [HistoryMessage] {
        let doneRowsNewestFirst = rows
            .filter { $0.status == .done }
            .prefix(limit)
        let chronological = Array(doneRowsNewestFirst).reversed()
        var messages: [HistoryMessage] = []
        messages.reserveCapacity(chronological.count * 2)
        for row in chronological {
            let trimmedQuery = row.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedResponse = row.responseMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedQuery.isEmpty, !trimmedResponse.isEmpty else { continue }
            messages.append(HistoryMessage(role: .user, content: trimmedQuery))
            messages.append(HistoryMessage(role: .assistant, content: trimmedResponse))
        }
        return messages
    }

    // MARK: - Wipe

    /// Wipes every row in both the in-memory cache and the SQLite table.
    func wipeAll() {
        do {
            try store.wipeAllAgentEntries()
        } catch {
            return
        }
        rows = []
        os_log("agent.chat-stack: wipeAll", log: Self.log, type: .debug)
    }

    // MARK: - Private

    private func findRow(rowId: Int64) -> ChatRow? {
        rows.first { $0.id == rowId }
    }

    private func refreshRows() {
        do {
            rows = try store.latestChatRows(limit: Self.maxRows)
        } catch {
            // Leave the cache unchanged on disk read errors — the next
            // successful write will refresh it.
        }
    }

    private func enforceCap() throws {
        let total = try store.agentEntriesCount()
        guard total > Self.maxRows else { return }
        let toDelete = try store.agentEntryIdsOlderThan(keep: Self.maxRows)
        guard !toDelete.isEmpty else { return }
        try store.deleteAgentEntries(ids: toDelete)
        os_log(
            "agent.chat-stack: evicted %{public}d rows (cap=%{public}d)",
            log: Self.log,
            type: .debug,
            toDelete.count,
            Self.maxRows
        )
    }

    private func encodeBlocks(_ blocks: [UIBlock]) -> String {
        guard let data = try? JSONEncoder().encode(blocks),
              let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }
}
