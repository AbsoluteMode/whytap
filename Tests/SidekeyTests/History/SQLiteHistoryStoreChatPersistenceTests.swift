import XCTest
import SQLite3
@testable import Sidekey

/// Tests for Stage 3 chat persistence additions to `agent_entries`:
/// idempotent migration (title/blocks_json/status columns) plus
/// updateAgentEntry / deleteAgentEntries / wipeAllAgentEntries /
/// agentEntriesCount methods. Backwards-compat with the existing
/// `latestAgentEntries` SELECT is also exercised here.
final class SQLiteHistoryStoreChatPersistenceTests: XCTestCase {
    private var tempPaths: [URL] = []

    override func tearDownWithError() throws {
        for url in tempPaths {
            try? FileManager.default.removeItem(at: url)
        }
        tempPaths = []
    }

    private func makeTempPath() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sidekey-stage3-\(UUID().uuidString).sqlite"
        )
        tempPaths.append(url)
        return url
    }

    private func makeFileStore() throws -> (SQLiteHistoryStore, URL) {
        let url = makeTempPath()
        let store = try SQLiteHistoryStore(path: url.path)
        return (store, url)
    }

    private func columnNames(for path: String, table: String) throws -> [String] {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            XCTFail("Failed to open SQLite for inspection: \(rc)")
            return []
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(\(table));"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            XCTFail("Failed to prepare PRAGMA: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 1) {
                names.append(String(cString: cString))
            }
        }
        return names
    }

    // MARK: - Migration

    func test_migration_adds_title_blocks_json_status_columns_idempotently() throws {
        let (store, url) = try makeFileStore()
        _ = store // keep alive long enough for migrate()

        let initialNames = try columnNames(for: url.path, table: "agent_entries")
        XCTAssertTrue(initialNames.contains("title"))
        XCTAssertTrue(initialNames.contains("blocks_json"))
        XCTAssertTrue(initialNames.contains("status"))

        // Re-open the same DB — migrate() must run a second time without
        // failing and must not duplicate columns.
        let reopened = try SQLiteHistoryStore(path: url.path)
        _ = reopened

        let secondNames = try columnNames(for: url.path, table: "agent_entries")
        XCTAssertEqual(initialNames.sorted(), secondNames.sorted())
    }

    func test_migration_existing_rows_get_null_title_null_blocks_status_done() throws {
        // Pre-populate a DB by-hand with only the old columns (simulating
        // a pre-Stage-3 database file the user already has on disk).
        let url = makeTempPath()
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, flags, nil), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        let oldSchema = """
            CREATE TABLE agent_entries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at REAL NOT NULL,
                query_text TEXT NOT NULL,
                query_mode TEXT NOT NULL,
                response_markdown TEXT NOT NULL,
                tool_names TEXT NOT NULL DEFAULT '[]'
            );
        """
        XCTAssertEqual(sqlite3_exec(db, oldSchema, nil, nil, nil), SQLITE_OK)
        let insertSQL = """
            INSERT INTO agent_entries (created_at, query_text, query_mode, response_markdown, tool_names)
            VALUES (123.0, 'q', 'text', 'a', '[]');
        """
        XCTAssertEqual(sqlite3_exec(db, insertSQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        // Open through SQLiteHistoryStore — migration should add the new
        // columns with defaults that preserve existing data.
        let store = try SQLiteHistoryStore(path: url.path)
        _ = store

        // Read raw values for the legacy row.
        var rd: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &rd, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let db2 = try XCTUnwrap(rd)
        defer { sqlite3_close(db2) }

        var stmt: OpaquePointer?
        let query = "SELECT title, blocks_json, status FROM agent_entries WHERE query_text = 'q';"
        XCTAssertEqual(sqlite3_prepare_v2(db2, query, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }

        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_type(stmt, 0), SQLITE_NULL)
        XCTAssertEqual(sqlite3_column_type(stmt, 1), SQLITE_NULL)
        let statusPtr = try XCTUnwrap(sqlite3_column_text(stmt, 2))
        XCTAssertEqual(String(cString: statusPtr), "done")
    }

    // MARK: - updateAgentEntry / queries

    func test_update_agent_entry_writes_title_blocks_status() throws {
        let (store, url) = try makeFileStore()
        let rowId = try store.insertAgentEntry(
            createdAt: Date(timeIntervalSince1970: 1),
            queryText: "q",
            queryMode: .text,
            responseMarkdown: "",
            toolNames: []
        )

        try store.updateAgentEntry(
            id: rowId,
            title: "Renamed Title",
            blocksJSON: "[]",
            status: .done,
            responseMarkdown: "final body",
            toolNames: ["search.web"]
        )

        // Read raw row to verify all three Stage-3 columns landed.
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = """
            SELECT title, blocks_json, status, response_markdown, tool_names
            FROM agent_entries WHERE id = ?;
        """
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, rowId)

        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 0)), "Renamed Title")
        XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 1)), "[]")
        XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 2)), "done")
        XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 3)), "final body")
        XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 4)), "[\"search.web\"]")
    }

    func test_update_agent_entry_is_idempotent_for_unknown_id() throws {
        let (store, _) = try makeFileStore()
        // UPDATE WHERE id = 9_999 is a no-op rather than a failure.
        try store.updateAgentEntry(
            id: 9_999,
            title: nil,
            blocksJSON: nil,
            status: .done,
            responseMarkdown: "ignored",
            toolNames: []
        )
        XCTAssertTrue(try store.latestAgentEntries(limit: 10).isEmpty)
    }

    func test_delete_agent_entries_older_than_ids() throws {
        let (store, _) = try makeFileStore()
        let id1 = try store.insertAgentEntry(
            createdAt: Date(timeIntervalSince1970: 1),
            queryText: "a",
            queryMode: .text,
            responseMarkdown: "",
            toolNames: []
        )
        let id2 = try store.insertAgentEntry(
            createdAt: Date(timeIntervalSince1970: 2),
            queryText: "b",
            queryMode: .text,
            responseMarkdown: "",
            toolNames: []
        )
        _ = try store.insertAgentEntry(
            createdAt: Date(timeIntervalSince1970: 3),
            queryText: "c",
            queryMode: .text,
            responseMarkdown: "",
            toolNames: []
        )

        try store.deleteAgentEntries(ids: [id1, id2])

        let remaining = try store.latestAgentEntries(limit: 10)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.queryText, "c")
    }

    func test_delete_agent_entries_with_empty_list_is_noop() throws {
        let (store, _) = try makeFileStore()
        _ = try store.insertAgentEntry(
            createdAt: Date(timeIntervalSince1970: 1),
            queryText: "a",
            queryMode: .text,
            responseMarkdown: "",
            toolNames: []
        )
        try store.deleteAgentEntries(ids: [])
        XCTAssertEqual(try store.latestAgentEntries(limit: 10).count, 1)
    }

    func test_wipe_all_agent_entries_removes_all() throws {
        let (store, _) = try makeFileStore()
        for index in 0..<5 {
            _ = try store.insertAgentEntry(
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                queryText: "q\(index)",
                queryMode: .text,
                responseMarkdown: "",
                toolNames: []
            )
        }

        try store.wipeAllAgentEntries()

        XCTAssertTrue(try store.latestAgentEntries(limit: 10).isEmpty)
        XCTAssertEqual(try store.agentEntriesCount(), 0)
    }

    func test_agent_entries_count_returns_total_rows() throws {
        let (store, _) = try makeFileStore()
        XCTAssertEqual(try store.agentEntriesCount(), 0)
        for index in 0..<3 {
            _ = try store.insertAgentEntry(
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                queryText: "q\(index)",
                queryMode: .text,
                responseMarkdown: "",
                toolNames: []
            )
        }
        XCTAssertEqual(try store.agentEntriesCount(), 3)
    }

    // MARK: - Downgrade-safety: the existing SELECT must keep working.

    func test_old_select_statement_works_after_migration() throws {
        let (store, url) = try makeFileStore()

        // Three rows representing pending / done / error statuses written
        // by a new-version client. After this, an old-version SELECT must
        // still return every row with all legacy columns intact.
        let pendingId = try store.insertAgentEntry(
            createdAt: Date(timeIntervalSince1970: 1),
            queryText: "pending q",
            queryMode: .text,
            responseMarkdown: "",
            toolNames: []
        )
        try store.updateAgentEntry(
            id: pendingId,
            title: nil,
            blocksJSON: nil,
            status: .pending,
            responseMarkdown: "",
            toolNames: []
        )

        let doneId = try store.insertAgentEntry(
            createdAt: Date(timeIntervalSince1970: 2),
            queryText: "done q",
            queryMode: .text,
            responseMarkdown: "done body",
            toolNames: ["search.web"]
        )
        try store.updateAgentEntry(
            id: doneId,
            title: "Done Title",
            blocksJSON: "[]",
            status: .done,
            responseMarkdown: "done body",
            toolNames: ["search.web"]
        )

        let errorId = try store.insertAgentEntry(
            createdAt: Date(timeIntervalSince1970: 3),
            queryText: "error q",
            queryMode: .text,
            responseMarkdown: "boom",
            toolNames: []
        )
        try store.updateAgentEntry(
            id: errorId,
            title: nil,
            blocksJSON: nil,
            status: .error,
            responseMarkdown: "boom",
            toolNames: []
        )

        // Run the same SQL the old client used, by hand, against the
        // post-migration DB.
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let legacy = """
            SELECT id, created_at, query_text, query_mode, response_markdown, tool_names
            FROM agent_entries
            ORDER BY created_at DESC, id DESC
            LIMIT ?;
        """
        XCTAssertEqual(sqlite3_prepare_v2(db, legacy, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, 100)

        var rows: [(String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let q = String(cString: sqlite3_column_text(stmt, 2))
            let body = String(cString: sqlite3_column_text(stmt, 4))
            rows.append((q, body))
        }

        XCTAssertEqual(rows.map { $0.0 }, ["error q", "done q", "pending q"])
        XCTAssertEqual(rows[0].1, "boom")
        XCTAssertEqual(rows[1].1, "done body")
        XCTAssertEqual(rows[2].1, "")
    }
}
