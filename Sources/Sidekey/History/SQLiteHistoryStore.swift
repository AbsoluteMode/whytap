import Foundation
import SQLite3

/// SQLite-backed `HistoryStore`. Uses the system `libsqlite3` (no extra
/// dependency). All access is serialised on a private `DispatchQueue` —
/// callers can be on any thread; the queue plus SQLite's own locking keep
/// the database consistent.
final class SQLiteHistoryStore: HistoryStore, @unchecked Sendable {
    enum Error: Swift.Error, CustomStringConvertible {
        case openFailed(String)
        case prepareFailed(String)
        case stepFailed(String)
        case execFailed(String)

        var description: String {
            switch self {
            case .openFailed(let msg):
                return "SQLite open failed: \(msg)"
            case .prepareFailed(let msg):
                return "SQLite prepare failed: \(msg)"
            case .stepFailed(let msg):
                return "SQLite step failed: \(msg)"
            case .execFailed(let msg):
                return "SQLite exec failed: \(msg)"
            }
        }
    }

    private static let sqliteTransientDestructor = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "com.rootwise.sidekey.history")

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &db, flags, nil)
        guard result == SQLITE_OK, let db else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code \(result)"
            if let db { sqlite3_close(db) }
            throw Error.openFailed(message)
        }
        self.handle = db
        try exec("PRAGMA journal_mode=WAL;")
        try migrate()
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    /// Convenience accessor that opens the default location at
    /// `~/Library/Application Support/com.rootwise.sidekey/history.sqlite`.
    static func shared() throws -> SQLiteHistoryStore {
        let path = try HistoryStoreLocation.prepareDefaultPath()
        return try SQLiteHistoryStore(path: path)
    }

    private func migrate() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS agent_entries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at REAL NOT NULL,
                query_text TEXT NOT NULL,
                query_mode TEXT NOT NULL,
                response_markdown TEXT NOT NULL,
                tool_names TEXT NOT NULL DEFAULT '[]'
            );
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_agent_entries_created_at
                ON agent_entries(created_at DESC);
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS drop_entries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at REAL NOT NULL,
                raw_transcript TEXT NOT NULL,
                formatted_text TEXT NOT NULL,
                target_app TEXT
            );
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_drop_entries_created_at
                ON drop_entries(created_at DESC);
        """)

        // Stage 3: idempotent additive migration. PRAGMA table_info(...)
        // tells us which columns already exist on the on-disk DB, so we
        // only run ALTER TABLE for ones that are missing.
        let existing = try existingColumnNames(table: "agent_entries")
        if !existing.contains("title") {
            try exec("ALTER TABLE agent_entries ADD COLUMN title TEXT;")
        }
        if !existing.contains("blocks_json") {
            try exec("ALTER TABLE agent_entries ADD COLUMN blocks_json TEXT;")
        }
        if !existing.contains("status") {
            try exec("ALTER TABLE agent_entries ADD COLUMN status TEXT NOT NULL DEFAULT 'done';")
        }

        // History strip: clipboard table. Polymorphic — kind drives which
        // payload columns are populated. Text payloads use `text_content`;
        // file URL payloads use `file_urls_json`; image payloads use
        // `image_uuid` + `image_extension` + `image_thumbnail_data`
        // (BLOB-encoded as base64 TEXT for parity with the JSON tool
        // names column). Full-size image bytes never land in the DB —
        // they live in `<app support>/history/assets/<uuid>.<ext>`.
        try exec("""
            CREATE TABLE IF NOT EXISTS clipboard_entries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at REAL NOT NULL,
                kind TEXT NOT NULL,
                text_content TEXT,
                file_urls_json TEXT,
                image_uuid TEXT,
                image_extension TEXT,
                image_thumbnail_b64 TEXT
            );
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_clipboard_entries_created_at
                ON clipboard_entries(created_at DESC);
        """)

    }

    private func existingColumnNames(table: String) throws -> Set<String> {
        let stmt = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(stmt) }
        var names: Set<String> = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw Error.stepFailed(lastErrorMessage())
            }
            if let name = readText(stmt, column: 1) {
                names.insert(name)
            }
        }
        return names
    }

    // MARK: - Writes

    @discardableResult
    func insertAgentEntry(
        createdAt: Date,
        queryText: String,
        queryMode: HistoryQueryMode,
        responseMarkdown: String,
        toolNames: [String]
    ) throws -> Int64 {
        try queue.sync {
            let toolJSON = Self.encodeToolNames(toolNames)
            let stmt = try prepare("""
                INSERT INTO agent_entries
                    (created_at, query_text, query_mode, response_markdown, tool_names)
                VALUES (?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, createdAt.timeIntervalSince1970)
            try bindText(stmt, index: 2, value: queryText)
            try bindText(stmt, index: 3, value: queryMode.rawValue)
            try bindText(stmt, index: 4, value: responseMarkdown)
            try bindText(stmt, index: 5, value: toolJSON)

            try step(stmt)
            return sqlite3_last_insert_rowid(handle)
        }
    }

    @discardableResult
    func insertDropEntry(
        createdAt: Date,
        rawTranscript: String,
        formattedText: String,
        targetApp: String?
    ) throws -> Int64 {
        try queue.sync {
            let stmt = try prepare("""
                INSERT INTO drop_entries
                    (created_at, raw_transcript, formatted_text, target_app)
                VALUES (?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, createdAt.timeIntervalSince1970)
            try bindText(stmt, index: 2, value: rawTranscript)
            try bindText(stmt, index: 3, value: formattedText)
            if let targetApp {
                try bindText(stmt, index: 4, value: targetApp)
            } else {
                sqlite3_bind_null(stmt, 4)
            }

            try step(stmt)
            return sqlite3_last_insert_rowid(handle)
        }
    }

    // MARK: - Reads

    func latestAgentEntries(limit: Int) throws -> [AgentHistoryEntry] {
        try queue.sync {
            let stmt = try prepare("""
                SELECT id, created_at, query_text, query_mode, response_markdown, tool_names
                FROM agent_entries
                ORDER BY created_at DESC, id DESC
                LIMIT ?;
            """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))

            var rows: [AgentHistoryEntry] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else {
                    throw Error.stepFailed(lastErrorMessage())
                }
                let id = sqlite3_column_int64(stmt, 0)
                let ts = sqlite3_column_double(stmt, 1)
                let queryText = readText(stmt, column: 2) ?? ""
                let queryModeRaw = readText(stmt, column: 3) ?? "text"
                let body = readText(stmt, column: 4) ?? ""
                let toolJSON = readText(stmt, column: 5) ?? "[]"
                rows.append(
                    AgentHistoryEntry(
                        id: id,
                        createdAt: Date(timeIntervalSince1970: ts),
                        queryText: queryText,
                        queryMode: HistoryQueryMode(rawValue: queryModeRaw) ?? .text,
                        responseMarkdown: body,
                        toolNames: Self.decodeToolNames(toolJSON)
                    )
                )
            }
            return rows
        }
    }

    // MARK: - Stage 3: chat persistence

    /// Updates the Stage-3 columns plus `response_markdown` and `tool_names`
    /// of a single row. UPDATE WHERE id = ? — a no-op if the row is gone
    /// (so callers don't need to check existence beforehand).
    func updateAgentEntry(
        id: Int64,
        queryText: String? = nil,
        title: String?,
        blocksJSON: String?,
        status: ChatStatus,
        responseMarkdown: String,
        toolNames: [String]
    ) throws {
        try queue.sync {
            let toolJSON = Self.encodeToolNames(toolNames)
            let stmt = try prepare("""
                UPDATE agent_entries
                SET query_text = COALESCE(?, query_text),
                    title = ?,
                    blocks_json = ?,
                    status = ?,
                    response_markdown = ?,
                    tool_names = ?
                WHERE id = ?;
            """)
            defer { sqlite3_finalize(stmt) }

            if let queryText {
                try bindText(stmt, index: 1, value: queryText)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            if let title {
                try bindText(stmt, index: 2, value: title)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            if let blocksJSON {
                try bindText(stmt, index: 3, value: blocksJSON)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            try bindText(stmt, index: 4, value: status.rawValue)
            try bindText(stmt, index: 5, value: responseMarkdown)
            try bindText(stmt, index: 6, value: toolJSON)
            sqlite3_bind_int64(stmt, 7, id)

            try step(stmt)
        }
    }

    /// Bulk delete by primary-key list. No-op when the list is empty.
    func deleteAgentEntries(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let stmt = try prepare("DELETE FROM agent_entries WHERE id IN (\(placeholders));")
            defer { sqlite3_finalize(stmt) }
            for (offset, value) in ids.enumerated() {
                sqlite3_bind_int64(stmt, Int32(offset + 1), value)
            }
            try step(stmt)
        }
    }

    /// Wipes every row in `agent_entries`.
    func wipeAllAgentEntries() throws {
        try queue.sync {
            try exec("DELETE FROM agent_entries;")
        }
    }

    /// Total row count — used by `ChatStackStore` to enforce the FIFO cap.
    func agentEntriesCount() throws -> Int {
        try queue.sync {
            let stmt = try prepare("SELECT COUNT(*) FROM agent_entries;")
            defer { sqlite3_finalize(stmt) }
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_ROW else {
                throw Error.stepFailed(lastErrorMessage())
            }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    /// Returns the most recent `limit` rows, including Stage-3 columns.
    /// Sorted newest first (DESC). Stage 4a will consume this in the
    /// `ChatStackStore.rows` cache.
    func latestChatRows(limit: Int) throws -> [ChatRow] {
        try queue.sync {
            let stmt = try prepare("""
                SELECT id, created_at, query_text, query_mode, response_markdown,
                       tool_names, title, blocks_json, status
                FROM agent_entries
                ORDER BY created_at DESC, id DESC
                LIMIT ?;
            """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))

            var rows: [ChatRow] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else {
                    throw Error.stepFailed(lastErrorMessage())
                }
                let id = sqlite3_column_int64(stmt, 0)
                let ts = sqlite3_column_double(stmt, 1)
                let queryText = readText(stmt, column: 2) ?? ""
                let queryModeRaw = readText(stmt, column: 3) ?? "text"
                let body = readText(stmt, column: 4) ?? ""
                let toolJSON = readText(stmt, column: 5) ?? "[]"
                let title = readText(stmt, column: 6)
                let blocksJSON = readText(stmt, column: 7)
                let statusRaw = readText(stmt, column: 8) ?? "done"

                rows.append(
                    ChatRow(
                        id: id,
                        createdAt: Date(timeIntervalSince1970: ts),
                        queryText: queryText,
                        queryMode: HistoryQueryMode(rawValue: queryModeRaw) ?? .text,
                        title: title,
                        blocksJSON: blocksJSON,
                        responseMarkdown: body,
                        toolNames: Self.decodeToolNames(toolJSON),
                        status: ChatStatus(rawValue: statusRaw) ?? .done
                    )
                )
            }
            return rows
        }
    }

    /// Returns the row ids of every chat older than the newest `keep`
    /// rows, ordered oldest-first. Used by `ChatStackStore` to FIFO-evict
    /// when the table grows past the cap.
    func agentEntryIdsOlderThan(keep: Int) throws -> [Int64] {
        try queue.sync {
            let stmt = try prepare("""
                SELECT id FROM agent_entries
                WHERE id NOT IN (
                    SELECT id FROM agent_entries
                    ORDER BY created_at DESC, id DESC
                    LIMIT ?
                )
                ORDER BY created_at ASC, id ASC;
            """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(keep))

            var ids: [Int64] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else {
                    throw Error.stepFailed(lastErrorMessage())
                }
                ids.append(sqlite3_column_int64(stmt, 0))
            }
            return ids
        }
    }

    func latestDropEntries(limit: Int) throws -> [DropHistoryEntry] {
        try queue.sync {
            let stmt = try prepare("""
                SELECT id, created_at, raw_transcript, formatted_text, target_app
                FROM drop_entries
                ORDER BY created_at DESC, id DESC
                LIMIT ?;
            """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))

            var rows: [DropHistoryEntry] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else {
                    throw Error.stepFailed(lastErrorMessage())
                }
                let id = sqlite3_column_int64(stmt, 0)
                let ts = sqlite3_column_double(stmt, 1)
                let raw = readText(stmt, column: 2) ?? ""
                let formatted = readText(stmt, column: 3) ?? ""
                let targetApp = readText(stmt, column: 4)
                rows.append(
                    DropHistoryEntry(
                        id: id,
                        createdAt: Date(timeIntervalSince1970: ts),
                        rawTranscript: raw,
                        formattedText: formatted,
                        targetApp: targetApp
                    )
                )
            }
            return rows
        }
    }

    // MARK: - Clipboard history

    /// Inserts a `.text` clipboard entry. Returns the new row id.
    @discardableResult
    func insertClipboardTextEntry(createdAt: Date, text: String) throws -> Int64 {
        try queue.sync {
            let stmt = try prepare("""
                INSERT INTO clipboard_entries
                    (created_at, kind, text_content)
                VALUES (?, ?, ?);
            """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, createdAt.timeIntervalSince1970)
            try bindText(stmt, index: 2, value: ClipboardEntryKind.text.rawValue)
            try bindText(stmt, index: 3, value: text)
            try step(stmt)
            return sqlite3_last_insert_rowid(handle)
        }
    }

    /// Inserts a `.fileURLs` clipboard entry. Throws if `urls` is empty
    /// (a no-URL clipboard event should not become a history row).
    @discardableResult
    func insertClipboardFileURLsEntry(createdAt: Date, urls: [URL]) throws -> Int64 {
        guard !urls.isEmpty else {
            throw Error.execFailed("clipboard fileURLs entry requires at least one URL")
        }
        let payload = Self.encodeFileURLs(urls)
        return try queue.sync {
            let stmt = try prepare("""
                INSERT INTO clipboard_entries
                    (created_at, kind, file_urls_json)
                VALUES (?, ?, ?);
            """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, createdAt.timeIntervalSince1970)
            try bindText(stmt, index: 2, value: ClipboardEntryKind.fileURLs.rawValue)
            try bindText(stmt, index: 3, value: payload)
            try step(stmt)
            return sqlite3_last_insert_rowid(handle)
        }
    }

    /// Inserts an `.image` clipboard entry. Writes the full image bytes
    /// to `<assetsDirectory>/<uuid>.<extension>` (creating the directory
    /// if missing) and stores the thumbnail bytes (base64) plus uuid +
    /// extension in the DB. Sidecar write failures throw; the DB row is
    /// not created when the sidecar can't be persisted.
    @discardableResult
    func insertClipboardImageEntry(
        createdAt: Date,
        uuid: UUID,
        imageData: Data,
        imageExtension: String,
        thumbnailData: Data,
        assetsDirectory: URL
    ) throws -> Int64 {
        try FileManager.default.createDirectory(
            at: assetsDirectory,
            withIntermediateDirectories: true
        )
        let sidecar = assetsDirectory.appendingPathComponent("\(uuid.uuidString).\(imageExtension)")
        try imageData.write(to: sidecar, options: .atomic)

        let thumb64 = thumbnailData.base64EncodedString()

        return try queue.sync {
            let stmt = try prepare("""
                INSERT INTO clipboard_entries
                    (created_at, kind, image_uuid, image_extension, image_thumbnail_b64)
                VALUES (?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, createdAt.timeIntervalSince1970)
            try bindText(stmt, index: 2, value: ClipboardEntryKind.image.rawValue)
            try bindText(stmt, index: 3, value: uuid.uuidString)
            try bindText(stmt, index: 4, value: imageExtension)
            try bindText(stmt, index: 5, value: thumb64)
            try step(stmt)
            return sqlite3_last_insert_rowid(handle)
        }
    }

    /// Returns the most recent clipboard entries, newest first.
    func latestClipboardEntries(limit: Int) throws -> [ClipboardHistoryEntry] {
        try queue.sync {
            let stmt = try prepare("""
                SELECT id, created_at, kind,
                       text_content, file_urls_json,
                       image_uuid, image_extension, image_thumbnail_b64
                FROM clipboard_entries
                ORDER BY created_at DESC, id DESC
                LIMIT ?;
            """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))

            var rows: [ClipboardHistoryEntry] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else {
                    throw Error.stepFailed(lastErrorMessage())
                }
                let id = sqlite3_column_int64(stmt, 0)
                let ts = sqlite3_column_double(stmt, 1)
                let kindRaw = readText(stmt, column: 2) ?? ""
                guard let kind = ClipboardEntryKind(rawValue: kindRaw) else {
                    // Unknown kind from a future schema — skip rather than
                    // crash so a downgraded client tolerates new rows.
                    continue
                }
                let payload: ClipboardHistoryEntryPayload
                switch kind {
                case .text:
                    payload = .text(readText(stmt, column: 3) ?? "")
                case .fileURLs:
                    let json = readText(stmt, column: 4) ?? "[]"
                    payload = .fileURLs(Self.decodeFileURLs(json))
                case .image:
                    let uuidString = readText(stmt, column: 5) ?? ""
                    let ext = readText(stmt, column: 6) ?? ""
                    let thumb64 = readText(stmt, column: 7) ?? ""
                    guard
                        let uuid = UUID(uuidString: uuidString),
                        let thumb = Data(base64Encoded: thumb64)
                    else { continue }
                    payload = .image(ClipboardImagePayload(
                        uuid: uuid,
                        fileExtension: ext,
                        thumbnailData: thumb
                    ))
                }
                rows.append(ClipboardHistoryEntry(
                    id: id,
                    createdAt: Date(timeIntervalSince1970: ts),
                    payload: payload
                ))
            }
            return rows
        }
    }

    /// FIFO-evict the oldest clipboard rows until the table is at or
    /// below `maxRows`. Deletes the sidecar file for any evicted image
    /// entry. No-op when under the cap.
    func enforceClipboardCap(maxRows: Int, assetsDirectory: URL) throws {
        let entriesToEvict: [(id: Int64, payload: ClipboardHistoryEntryPayload)] = try queue.sync {
            let countStmt = try prepare("SELECT COUNT(*) FROM clipboard_entries;")
            defer { sqlite3_finalize(countStmt) }
            guard sqlite3_step(countStmt) == SQLITE_ROW else {
                throw Error.stepFailed(lastErrorMessage())
            }
            let total = Int(sqlite3_column_int64(countStmt, 0))
            guard total > maxRows else { return [] }

            let selectStmt = try prepare("""
                SELECT id, kind, image_uuid, image_extension
                FROM clipboard_entries
                WHERE id NOT IN (
                    SELECT id FROM clipboard_entries
                    ORDER BY created_at DESC, id DESC
                    LIMIT ?
                )
                ORDER BY created_at ASC, id ASC;
            """)
            defer { sqlite3_finalize(selectStmt) }
            sqlite3_bind_int(selectStmt, 1, Int32(maxRows))

            var rows: [(Int64, ClipboardHistoryEntryPayload)] = []
            while true {
                let rc = sqlite3_step(selectStmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else {
                    throw Error.stepFailed(lastErrorMessage())
                }
                let id = sqlite3_column_int64(selectStmt, 0)
                let kindRaw = readText(selectStmt, column: 1) ?? ""
                if kindRaw == ClipboardEntryKind.image.rawValue {
                    let uuidString = readText(selectStmt, column: 2) ?? ""
                    let ext = readText(selectStmt, column: 3) ?? ""
                    if let uuid = UUID(uuidString: uuidString) {
                        rows.append((id, .image(ClipboardImagePayload(
                            uuid: uuid,
                            fileExtension: ext,
                            thumbnailData: Data()
                        ))))
                        continue
                    }
                }
                // Non-image kinds don't need sidecar cleanup — payload
                // contents aren't read by the eviction path.
                rows.append((id, .text("")))
            }
            return rows
        }

        guard !entriesToEvict.isEmpty else { return }

        // Best-effort delete sidecars BEFORE the DB delete so partial
        // failures leave the table consistent (orphan sidecars are
        // harmless, dangling DB row pointing at a missing sidecar is
        // less so).
        for (_, payload) in entriesToEvict {
            if case .image(let img) = payload {
                let url = img.sidecarURL(in: assetsDirectory)
                try? FileManager.default.removeItem(at: url)
            }
        }

        try queue.sync {
            let ids = entriesToEvict.map(\.id)
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let stmt = try prepare("DELETE FROM clipboard_entries WHERE id IN (\(placeholders));")
            defer { sqlite3_finalize(stmt) }
            for (offset, value) in ids.enumerated() {
                sqlite3_bind_int64(stmt, Int32(offset + 1), value)
            }
            try step(stmt)
        }
    }

    /// Wipes all clipboard rows + every file under `assetsDirectory`.
    /// Used by `ClipboardHistoryLaunchPurge`.
    func wipeAllClipboardEntries(assetsDirectory: URL) throws {
        try queue.sync {
            try exec("DELETE FROM clipboard_entries;")
        }
        if FileManager.default.fileExists(atPath: assetsDirectory.path) {
            let contents = (try? FileManager.default.contentsOfDirectory(at: assetsDirectory, includingPropertiesForKeys: nil)) ?? []
            for url in contents {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Drop / agent cap enforcement (Strip feature)

    /// Strip-feature cap for `drop_entries`: keep the newest `maxRows`,
    /// FIFO-evict the rest. Symmetric with `enforceClipboardCap` but
    /// without sidecars — drop rows are all text.
    func enforceDropCap(maxRows: Int) throws {
        try queue.sync {
            let countStmt = try prepare("SELECT COUNT(*) FROM drop_entries;")
            defer { sqlite3_finalize(countStmt) }
            guard sqlite3_step(countStmt) == SQLITE_ROW else {
                throw Error.stepFailed(lastErrorMessage())
            }
            let total = Int(sqlite3_column_int64(countStmt, 0))
            guard total > maxRows else { return }

            let stmt = try prepare("""
                DELETE FROM drop_entries
                WHERE id NOT IN (
                    SELECT id FROM drop_entries
                    ORDER BY created_at DESC, id DESC
                    LIMIT ?
                );
            """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(maxRows))
            try step(stmt)
        }
    }

    // MARK: - File URL JSON encoding

    static func encodeFileURLs(_ urls: [URL]) -> String {
        let paths = urls.map { $0.path }
        guard let data = try? JSONEncoder().encode(paths),
              let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }

    static func decodeFileURLs(_ json: String) -> [URL] {
        guard let data = json.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Low level helpers

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &error)
        defer { if let error { sqlite3_free(error) } }
        guard rc == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "code \(rc)"
            throw Error.execFailed(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK else {
            throw Error.prepareFailed(lastErrorMessage())
        }
        return stmt
    }

    private func step(_ stmt: OpaquePointer?) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw Error.stepFailed(lastErrorMessage())
        }
    }

    private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String) throws {
        let rc = sqlite3_bind_text(
            stmt,
            index,
            value,
            -1,
            Self.sqliteTransientDestructor
        )
        guard rc == SQLITE_OK else {
            throw Error.prepareFailed(lastErrorMessage())
        }
    }

    private func readText(_ stmt: OpaquePointer?, column: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: cString)
    }

    private func lastErrorMessage() -> String {
        guard let handle else { return "no db handle" }
        return String(cString: sqlite3_errmsg(handle))
    }

    // MARK: - tool_names JSON encoding

    static func encodeToolNames(_ names: [String]) -> String {
        guard let data = try? JSONEncoder().encode(names),
              let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }

    static func decodeToolNames(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return arr
    }
}
