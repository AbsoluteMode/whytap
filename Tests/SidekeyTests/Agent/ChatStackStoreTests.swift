import Combine
import XCTest
@testable import Sidekey

@MainActor
final class ChatStackStoreTests: XCTestCase {
    private var tempPaths: [URL] = []
    private var cancellables: Set<AnyCancellable> = []

    override func tearDownWithError() throws {
        cancellables = []
        for url in tempPaths {
            try? FileManager.default.removeItem(at: url)
        }
        tempPaths = []
    }

    private func makeStore(
        clock: @escaping () -> Date = Date.init
    ) throws -> (ChatStackStore, SQLiteHistoryStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sidekey-stage3-chatstack-\(UUID().uuidString).sqlite"
        )
        tempPaths.append(url)
        let history = try SQLiteHistoryStore(path: url.path)
        let store = ChatStackStore(store: history, clock: clock)
        return (store, history, url)
    }

    // MARK: - lifecycle

    func test_start_chat_inserts_pending_row() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let (store, _, _) = try makeStore(clock: { now })

        let rowId = store.startChat(queryText: "q", mode: .text)

        XCTAssertGreaterThan(rowId, 0)
        XCTAssertEqual(store.rows.count, 1)
        let first = try XCTUnwrap(store.rows.first)
        XCTAssertEqual(first.id, rowId)
        XCTAssertEqual(first.queryText, "q")
        XCTAssertEqual(first.queryMode, .text)
        XCTAssertEqual(first.status, .pending)
        XCTAssertEqual(first.createdAt, now)
        XCTAssertNil(first.title)
        XCTAssertNil(first.blocksJSON)
        XCTAssertEqual(first.responseMarkdown, "")
        XCTAssertEqual(first.toolNames, [])
    }

    func test_update_title_sets_title_on_active_row() throws {
        let (store, _, _) = try makeStore()
        let rowId = store.startChat(queryText: "q", mode: .text)

        store.updateTitle(rowId: rowId, text: "T")

        XCTAssertEqual(store.rows.first?.title, "T")
    }

    func test_update_query_text_updates_memory_and_sqlite_row() throws {
        let (store, history, _) = try makeStore()
        let rowId = store.startChat(queryText: "", mode: .voice)

        store.updateQueryText(
            rowId: rowId,
            text: "Можешь скинуть ссылку на Anthropic?"
        )

        XCTAssertEqual(
            store.rows.first?.queryText,
            "Можешь скинуть ссылку на Anthropic?"
        )
        XCTAssertEqual(
            try history.latestAgentEntries(limit: 1).first?.queryText,
            "Можешь скинуть ссылку на Anthropic?"
        )
    }

    func test_finalize_chat_writes_blocks_json_and_status_done() throws {
        let (store, _, _) = try makeStore()
        let rowId = store.startChat(queryText: "q", mode: .text)
        let blocks: [UIBlock] = [
            .textAnswer(TextAnswerBlock(body: "hello world"))
        ]

        store.finalizeChat(rowId: rowId, blocks: blocks, markdown: "body")

        let row = try XCTUnwrap(store.rows.first)
        XCTAssertEqual(row.status, .done)
        XCTAssertEqual(row.responseMarkdown, "body")
        let json = try XCTUnwrap(row.blocksJSON)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode([UIBlock].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.kind, .textAnswer)
    }

    func test_mark_chat_error_sets_status_error_with_non_empty_markdown() throws {
        let (store, _, _) = try makeStore()
        let rowId = store.startChat(queryText: "q", mode: .text)

        store.markChatError(rowId: rowId, message: "boom")

        let row = try XCTUnwrap(store.rows.first)
        XCTAssertEqual(row.status, .error)
        XCTAssertEqual(row.responseMarkdown, "boom")
        XCTAssertFalse(row.responseMarkdown.isEmpty)
    }

    func test_mark_chat_error_substitutes_placeholder_for_empty_message() throws {
        // Downgrade-safety: response_markdown is the only column an old
        // client can read for an error row, so it must never be empty.
        let (store, _, _) = try makeStore()
        let rowId = store.startChat(queryText: "q", mode: .text)

        store.markChatError(rowId: rowId, message: "")

        let row = try XCTUnwrap(store.rows.first)
        XCTAssertEqual(row.status, .error)
        XCTAssertFalse(row.responseMarkdown.isEmpty)
    }

    // MARK: - historyMessages

    private func seedChat(
        _ store: ChatStackStore,
        queryText: String,
        markdown: String,
        status: ChatStatus
    ) {
        let rowId = store.startChat(queryText: queryText, mode: .text)
        switch status {
        case .pending:
            break
        case .streaming:
            // Stage 3 has no public `markStreaming` — seed via raw row id
            // via updateTitle would still leave status=pending; we don't
            // use this branch in tests yet.
            break
        case .done:
            store.finalizeChat(rowId: rowId, blocks: [], markdown: markdown)
        case .error:
            store.markChatError(rowId: rowId, message: markdown)
        }
    }

    func test_history_messages_returns_last_10_done_pairs_only() throws {
        var seconds: TimeInterval = 0
        let clock: () -> Date = {
            seconds += 1
            return Date(timeIntervalSince1970: seconds)
        }
        let (store, _, _) = try makeStore(clock: clock)

        // Seed more than the cap so the suffix-trim path runs. Pending
        // and error rows are filtered out before the limit applies and
        // must not consume slots.
        for index in 0..<20 {
            seedChat(store, queryText: "q\(index)", markdown: "a\(index)", status: .done)
        }
        seedChat(store, queryText: "err1", markdown: "boom1", status: .error)
        seedChat(store, queryText: "err2", markdown: "boom2", status: .error)
        _ = store.startChat(queryText: "pending", mode: .text) // pending

        let messages = store.historyMessages()
        XCTAssertEqual(messages.count, 20) // 10 pairs == 20 entries
        // Pairs: user / assistant repeated.
        for index in stride(from: 0, to: messages.count, by: 2) {
            XCTAssertEqual(messages[index].role, .user)
            XCTAssertEqual(messages[index + 1].role, .assistant)
        }
        // Last 10 done = q10..q19. Chronological order means q10 first.
        let userQueries = messages.filter { $0.role == .user }.map(\.content)
        XCTAssertEqual(userQueries, (10..<20).map { "q\($0)" })
        let assistantBodies = messages.filter { $0.role == .assistant }.map(\.content)
        XCTAssertEqual(assistantBodies, (10..<20).map { "a\($0)" })
    }

    func test_history_messages_defaults_to_constant_cap() {
        // Backend caps `history` at 20 entries (10 pairs). Pin the
        // client-side constant here so a future drift away from the
        // backend ceiling fails loudly instead of silently sending
        // requests the server rejects with 422.
        XCTAssertEqual(ChatStackStore.defaultHistoryLimit, 10)
    }

    func test_history_messages_returns_in_chronological_order() throws {
        var seconds: TimeInterval = 0
        let clock: () -> Date = {
            seconds += 1
            return Date(timeIntervalSince1970: seconds)
        }
        let (store, _, _) = try makeStore(clock: clock)

        seedChat(store, queryText: "first", markdown: "r1", status: .done)
        seedChat(store, queryText: "second", markdown: "r2", status: .done)
        seedChat(store, queryText: "third", markdown: "r3", status: .done)

        let messages = store.historyMessages()
        let queries = messages.filter { $0.role == .user }.map(\.content)
        XCTAssertEqual(queries, ["first", "second", "third"])
    }

    func test_history_messages_skips_pending_and_error_chats() throws {
        var seconds: TimeInterval = 0
        let clock: () -> Date = {
            seconds += 1
            return Date(timeIntervalSince1970: seconds)
        }
        let (store, _, _) = try makeStore(clock: clock)

        seedChat(store, queryText: "d1", markdown: "a1", status: .done)
        _ = store.startChat(queryText: "p1", mode: .text)
        seedChat(store, queryText: "e1", markdown: "boom", status: .error)
        seedChat(store, queryText: "d2", markdown: "a2", status: .done)
        seedChat(store, queryText: "d3", markdown: "a3", status: .done)

        let messages = store.historyMessages()
        XCTAssertEqual(messages.count, 6)
        let queries = messages.filter { $0.role == .user }.map(\.content)
        XCTAssertEqual(queries, ["d1", "d2", "d3"])
    }

    // MARK: - historyMessages empty-content filtering
    //
    // Backend `/api/agent` enforces `Field(min_length=1, max_length=64_000)`
    // on every `history[].content` via Pydantic. A single `.done` row with
    // an empty `responseMarkdown` (e.g. tool-only turn, SchemaGuard
    // filtered every block) therefore causes 422 on every subsequent
    // request until that row falls out of the history window. Filter
    // empty/whitespace-only rows on the client so the chat-stack can't
    // poison the next request.

    func test_historyMessages_skips_row_with_empty_responseMarkdown() throws {
        var seconds: TimeInterval = 0
        let clock: () -> Date = {
            seconds += 1
            return Date(timeIntervalSince1970: seconds)
        }
        let (store, _, _) = try makeStore(clock: clock)

        seedChat(store, queryText: "d1", markdown: "a1", status: .done)
        seedChat(store, queryText: "d2", markdown: "", status: .done)
        seedChat(store, queryText: "d3", markdown: "a3", status: .done)

        let messages = store.historyMessages()
        XCTAssertEqual(messages.count, 4)
        let queries = messages.filter { $0.role == .user }.map(\.content)
        XCTAssertEqual(queries, ["d1", "d3"])
        let bodies = messages.filter { $0.role == .assistant }.map(\.content)
        XCTAssertEqual(bodies, ["a1", "a3"])
    }

    func test_historyMessages_skips_row_with_empty_queryText() throws {
        var seconds: TimeInterval = 0
        let clock: () -> Date = {
            seconds += 1
            return Date(timeIntervalSince1970: seconds)
        }
        let (store, _, _) = try makeStore(clock: clock)

        seedChat(store, queryText: "d1", markdown: "a1", status: .done)
        seedChat(store, queryText: "", markdown: "a2", status: .done)
        seedChat(store, queryText: "d3", markdown: "a3", status: .done)

        let messages = store.historyMessages()
        XCTAssertEqual(messages.count, 4)
        let queries = messages.filter { $0.role == .user }.map(\.content)
        XCTAssertEqual(queries, ["d1", "d3"])
        let bodies = messages.filter { $0.role == .assistant }.map(\.content)
        XCTAssertEqual(bodies, ["a1", "a3"])
    }

    func test_historyMessages_skips_row_with_whitespace_only_content() throws {
        var seconds: TimeInterval = 0
        let clock: () -> Date = {
            seconds += 1
            return Date(timeIntervalSince1970: seconds)
        }
        let (store, _, _) = try makeStore(clock: clock)

        seedChat(store, queryText: "d1", markdown: "a1", status: .done)
        seedChat(store, queryText: "   \n  ", markdown: "a2", status: .done)
        seedChat(store, queryText: "d3", markdown: "\t\n  ", status: .done)
        seedChat(store, queryText: "d4", markdown: "a4", status: .done)

        let messages = store.historyMessages()
        XCTAssertEqual(messages.count, 4)
        let queries = messages.filter { $0.role == .user }.map(\.content)
        XCTAssertEqual(queries, ["d1", "d4"])
        let bodies = messages.filter { $0.role == .assistant }.map(\.content)
        XCTAssertEqual(bodies, ["a1", "a4"])
    }

    func test_historyMessages_returns_full_pairs_when_content_is_present() throws {
        var seconds: TimeInterval = 0
        let clock: () -> Date = {
            seconds += 1
            return Date(timeIntervalSince1970: seconds)
        }
        let (store, _, _) = try makeStore(clock: clock)

        seedChat(store, queryText: "d1", markdown: "a1", status: .done)
        seedChat(store, queryText: "d2", markdown: "a2", status: .done)
        seedChat(store, queryText: "d3", markdown: "a3", status: .done)

        let messages = store.historyMessages()
        XCTAssertEqual(messages.count, 6)
        let queries = messages.filter { $0.role == .user }.map(\.content)
        XCTAssertEqual(queries, ["d1", "d2", "d3"])
        let bodies = messages.filter { $0.role == .assistant }.map(\.content)
        XCTAssertEqual(bodies, ["a1", "a2", "a3"])
        for index in stride(from: 0, to: messages.count, by: 2) {
            XCTAssertEqual(messages[index].role, .user)
            XCTAssertEqual(messages[index + 1].role, .assistant)
        }
    }

    func test_historyMessages_preserves_order_when_some_rows_are_skipped() throws {
        var seconds: TimeInterval = 0
        let clock: () -> Date = {
            seconds += 1
            return Date(timeIntervalSince1970: seconds)
        }
        let (store, _, _) = try makeStore(clock: clock)

        seedChat(store, queryText: "first", markdown: "r1", status: .done)
        seedChat(store, queryText: "second", markdown: "", status: .done)
        seedChat(store, queryText: "third", markdown: "r3", status: .done)
        seedChat(store, queryText: "", markdown: "r4", status: .done)
        seedChat(store, queryText: "fifth", markdown: "r5", status: .done)

        let messages = store.historyMessages()
        XCTAssertEqual(messages.count, 6)
        let queries = messages.filter { $0.role == .user }.map(\.content)
        XCTAssertEqual(queries, ["first", "third", "fifth"])
        let bodies = messages.filter { $0.role == .assistant }.map(\.content)
        XCTAssertEqual(bodies, ["r1", "r3", "r5"])
    }

    // MARK: - cap eviction

    func test_chat_stack_store_evicts_oldest_above_cap() throws {
        var seconds: TimeInterval = 0
        let clock: () -> Date = {
            seconds += 1
            return Date(timeIntervalSince1970: seconds)
        }
        let (store, history, _) = try makeStore(clock: clock)

        for index in 0..<201 {
            _ = store.startChat(queryText: "q\(index)", mode: .text)
        }

        XCTAssertEqual(try history.agentEntriesCount(), 200)
        // The oldest (q0) must be the one that was evicted.
        let rows = try history.latestChatRows(limit: 1_000)
        let oldest = rows.last
        XCTAssertEqual(oldest?.queryText, "q1")
        XCTAssertFalse(rows.contains { $0.queryText == "q0" })
    }

    // MARK: - wipeAll delegation

    func test_chat_stack_store_wipe_all_clears_both_layers() throws {
        let (store, history, _) = try makeStore()
        _ = store.startChat(queryText: "q1", mode: .text)
        _ = store.startChat(queryText: "q2", mode: .text)
        XCTAssertEqual(store.rows.count, 2)

        store.wipeAll()

        XCTAssertTrue(store.rows.isEmpty)
        // Delegation: both layers wiped.
        XCTAssertTrue(try history.latestAgentEntries(limit: 100).isEmpty)
        XCTAssertEqual(try history.agentEntriesCount(), 0)
    }

    // MARK: - Combine binding

    func test_rows_published_emits_on_insert() throws {
        let (store, _, _) = try makeStore()
        var captured: [[ChatRow]] = []

        store.$rows
            .sink { captured.append($0) }
            .store(in: &cancellables)

        _ = store.startChat(queryText: "q", mode: .text)

        // Initial value + one publish after startChat.
        XCTAssertGreaterThanOrEqual(captured.count, 2)
        XCTAssertEqual(captured.last?.first?.queryText, "q")
    }

    // MARK: - recordTool

    func test_record_tool_appends_tool_name() throws {
        let (store, _, _) = try makeStore()
        let rowId = store.startChat(queryText: "q", mode: .text)

        store.recordTool(rowId: rowId, tool: "linear.search_issues")
        store.recordTool(rowId: rowId, tool: "linear.search_issues")
        store.recordTool(rowId: rowId, tool: "notion.search")

        let row = try XCTUnwrap(store.rows.first)
        XCTAssertEqual(row.toolNames, ["linear.search_issues", "notion.search"])
    }
}
