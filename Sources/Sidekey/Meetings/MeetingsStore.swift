import Foundation
import SQLite3
import os.log

/// Local sync-status flag mirrored into the SQLite `sync_status` column.
/// Mirrors the spec's CHECK constraint exactly so adding a new state on
/// either side immediately surfaces as a compile error here.
enum MeetingSyncStatus: String, Sendable {
    case new
    case read
    case pendingSync = "pending_sync"
    case failed
}

/// Persisted processing lifecycle shown independently from edit sync state.
/// `uploading` is kept only so rows written by older builds still decode;
/// nothing writes it anymore.
enum MeetingProgressStatus: String, Sendable, Codable, Equatable {
    case waitingToReconnect = "waiting_to_reconnect"
    case uploading
    case transcribing
    case generatingProtocol = "generating_protocol"
    case ready
    case failed

    var displayLabel: String {
        switch self {
        case .waitingToReconnect: return "Waiting to reconnect"
        case .uploading: return "Processing"
        case .transcribing: return "Transcribing"
        case .generatingProtocol: return "Preparing protocol"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }
}

/// Flat row type for the meetings list: the recording timestamps plus the
/// local-only state — a `syncStatus` flag (new/read/pending_sync/failed), a
/// user-editable `title` override and the processing status.
struct MeetingMetaWithLocalState: Sendable, Equatable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date?
    let durationSeconds: Int
    let title: String?
    let syncStatus: MeetingSyncStatus
    let serverVersion: Int
    let createdAt: Date
    let progressStatus: MeetingProgressStatus
    let statusUpdatedAt: Date
    let failureReason: String?

    init(
        id: UUID,
        startedAt: Date,
        endedAt: Date?,
        durationSeconds: Int,
        title: String?,
        syncStatus: MeetingSyncStatus,
        serverVersion: Int,
        createdAt: Date,
        progressStatus: MeetingProgressStatus = .ready,
        statusUpdatedAt: Date = Date(),
        failureReason: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.title = title
        self.syncStatus = syncStatus
        self.serverVersion = serverVersion
        self.createdAt = createdAt
        self.progressStatus = progressStatus
        self.statusUpdatedAt = statusUpdatedAt
        self.failureReason = failureReason
    }
}

/// Errors thrown by `MeetingsStore`. Kept distinct from the meetings
/// processing errors (which describe provider / model failures)
/// because the store's surface is filesystem + SQLite, and the caller
/// should not have to unify the two.
enum MeetingsStoreError: Error, CustomStringConvertible {
    case sqliteOpenFailed(code: Int32, message: String)
    case sqliteStepFailed(code: Int32, message: String)
    case sqlitePrepareFailed(code: Int32, message: String)
    case sqliteBindFailed(code: Int32, message: String)
    case filesystem(String)
    case invalidRow(String)

    var description: String {
        switch self {
        case .sqliteOpenFailed(let code, let msg):
            return "SQLite open failed (\(code)): \(msg)"
        case .sqliteStepFailed(let code, let msg):
            return "SQLite step failed (\(code)): \(msg)"
        case .sqlitePrepareFailed(let code, let msg):
            return "SQLite prepare failed (\(code)): \(msg)"
        case .sqliteBindFailed(let code, let msg):
            return "SQLite bind failed (\(code)): \(msg)"
        case .filesystem(let msg):
            return "Filesystem error: \(msg)"
        case .invalidRow(let msg):
            return "Invalid row: \(msg)"
        }
    }
}

/// Persistent local cache for meeting metadata + markdown notes.
///
/// `actor` isolation serialises every DB / filesystem call without the
/// caller having to think about thread safety — the underlying SQLite
/// connection is single-writer (we still pass `SQLITE_OPEN_FULLMUTEX`
/// for defence-in-depth in case a future caller forgets the actor
/// boundary).
///
/// Storage layout (under `rootDirectory`):
///
/// ```
/// meetings.sqlite               — single-table DB with metadata
/// <uuid-lowercased>.md          — markdown body for each meeting,
///                                 written atomically via tmp+rename
/// ```
///
/// The markdown body deliberately lives in a sibling `.md` file (not a
/// BLOB column) so users can inspect / diff notes with regular CLI
/// tools, and so the BlockNote viewer (Stage 8b) can `loadFileURL` the
/// markdown directly without a round-trip through the actor.
actor MeetingsStore: MeetingsStoring {
    private static let log = OSLog(subsystem: "com.sidekey.meetings", category: "store")

    /// Database file name inside `rootDirectory`. Spec-fixed.
    private static let databaseFileName = "meetings.sqlite"

    private let rootDirectory: URL
    private var db: OpaquePointer?
    private var isOpen = false

    /// Production initialiser uses
    /// `~/Library/Application Support/Sidekey/Meetings/`. Tests inject a
    /// temp directory so each run sees a fresh DB and parallel test
    /// shards cannot collide.
    ///
    /// The DB handle + schema bootstrap happens synchronously via a
    /// `nonisolated` helper because an actor's `init` cannot call
    /// actor-isolated methods (the actor's serial executor is only
    /// available after `init` returns). All subsequent mutation goes
    /// through actor-isolated methods.
    init(rootDirectory: URL = MeetingsStore.defaultRootDirectory()) throws {
        self.rootDirectory = rootDirectory
        self.db = try Self.openAndBootstrap(rootDirectory: rootDirectory)
        self.isOpen = true
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    /// Returns `~/Library/Application Support/Sidekey/Meetings/`. The
    /// directory is created lazily on first `init`; we do not pre-touch
    /// it here so callers building a path for an unrelated reason do
    /// not accidentally create the dir as a side effect.
    nonisolated static func defaultRootDirectory() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("Sidekey", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
    }

    /// Releases the SQLite connection. Tests call this between two
    /// `MeetingsStore` instantiations on the same directory to assert
    /// that re-opening (and the idempotent `CREATE TABLE IF NOT EXISTS`)
    /// works cleanly. Production code does not need to call this — the
    /// `deinit` closes the connection at app teardown.
    func close() {
        if let db {
            sqlite3_close(db)
        }
        db = nil
        isOpen = false
    }

    // MARK: - Public API

    /// Inserts one meeting + writes its markdown body. Idempotent on
    /// primary-key collision (existing row remains; the caller should
    /// use `update` instead). The markdown body is written atomically
    /// via `Data.write(options: [.atomic])` (POSIX `write tmp → rename`)
    /// so a crash mid-write either leaves the previous file intact or
    /// installs the new one in full.
    ///
    /// When `transcript` is non-nil its JSON encoding is persisted to a
    /// sidecar `<uuid>-transcript.json` so the meetings detail window's
    /// Transcribe tab can render the diarized segments produced at
    /// finalize time without re-processing. Meetings finalized before this
    /// field existed simply have no sidecar — the Transcribe tab shows
    /// a placeholder in that case (see `MeetingsWindowController`).
    func insert(
        meta: MeetingMetaWithLocalState,
        markdown: String,
        transcript: [TranscriptSegment]? = nil
    ) throws {
        try writeMarkdown(meta.id, markdown: markdown)
        if let transcript {
            try writeTranscript(meta.id, transcript: transcript)
        }
        try insertOrIgnoreRow(meta: meta)
        os_log(
            "store inserted (meetingId: %{public}@, transcript: %{public}d)",
            log: Self.log, type: .info,
            meta.id.uuidString,
            transcript == nil ? 0 : 1
        )
    }

    /// Makes an in-flight meeting visible before its final note exists.
    func upsertProgress(
        meta: MeetingMetaWithLocalState,
        status: MeetingProgressStatus,
        failureReason: String? = nil
    ) throws {
        let current = MeetingMetaWithLocalState(
            id: meta.id,
            startedAt: meta.startedAt,
            endedAt: meta.endedAt,
            durationSeconds: meta.durationSeconds,
            title: meta.title,
            syncStatus: meta.syncStatus,
            serverVersion: meta.serverVersion,
            createdAt: meta.createdAt,
            progressStatus: status,
            statusUpdatedAt: Date(),
            failureReason: failureReason
        )
        try insertOrUpdateRow(meta: current)
    }

    @discardableResult
    func updateProgress(
        id: UUID,
        status: MeetingProgressStatus,
        failureReason: String? = nil
    ) throws -> Bool {
        let sql = """
            UPDATE meetings
            SET progress_status = ?, status_updated_at = ?, failure_reason = ?
            WHERE id = ?
              AND (progress_status <> ? OR ? = ?)
            """
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard prepareResult == SQLITE_OK else {
            throw MeetingsStoreError.sqlitePrepareFailed(code: prepareResult, message: lastErrorMessage())
        }
        try bindText(stmt: stmt, position: 1, value: status.rawValue)
        try bindInt(stmt: stmt, position: 2, value: Int(Date().timeIntervalSince1970))
        try bindNullableText(stmt: stmt, position: 3, value: failureReason)
        try bindText(stmt: stmt, position: 4, value: id.uuidString)
        // A note that has already reached `.ready` is durable local data.
        // Late/duplicate pollers (especially launch recovery for an old
        // finalized queue) must not regress it to an in-flight or failed
        // status. Writing `.ready` again is still allowed so callers can
        // clear a stale failure reason idempotently.
        try bindText(stmt: stmt, position: 5, value: MeetingProgressStatus.ready.rawValue)
        try bindText(stmt: stmt, position: 6, value: status.rawValue)
        try bindText(stmt: stmt, position: 7, value: MeetingProgressStatus.ready.rawValue)
        let step = sqlite3_step(stmt)
        guard step == SQLITE_DONE else {
            throw MeetingsStoreError.sqliteStepFailed(code: step, message: lastErrorMessage())
        }
        return sqlite3_changes(db) > 0
    }

    /// Returns the persisted processing state for one meeting without
    /// loading the full sidebar list. Launch recovery uses this to tell a
    /// genuinely unfinished finalized upload from a stale queue whose note
    /// is already safely present in the local cache.
    func progressStatus(id: UUID) throws -> MeetingProgressStatus? {
        let sql = "SELECT progress_status FROM meetings WHERE id = ? LIMIT 1"
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard prepareResult == SQLITE_OK else {
            throw MeetingsStoreError.sqlitePrepareFailed(
                code: prepareResult,
                message: lastErrorMessage()
            )
        }
        try bindText(stmt: stmt, position: 1, value: id.uuidString)
        let step = sqlite3_step(stmt)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else {
            throw MeetingsStoreError.sqliteStepFailed(
                code: step,
                message: lastErrorMessage()
            )
        }
        guard let raw = sqlite3_column_text(stmt, 0) else {
            throw MeetingsStoreError.invalidRow("progress_status is NULL")
        }
        return MeetingProgressStatus(rawValue: String(cString: raw)) ?? .ready
    }

    func delete(id: UUID) throws {
        let sql = "DELETE FROM meetings WHERE id = ?"
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard prepareResult == SQLITE_OK else {
            throw MeetingsStoreError.sqlitePrepareFailed(code: prepareResult, message: lastErrorMessage())
        }
        try bindText(stmt: stmt, position: 1, value: id.uuidString)
        let step = sqlite3_step(stmt)
        guard step == SQLITE_DONE else {
            throw MeetingsStoreError.sqliteStepFailed(code: step, message: lastErrorMessage())
        }
    }

    /// Replaces an existing meeting's markdown body and bumps its
    /// `server_version`. Used by Stage 8c's edit sync path.
    func update(id: UUID, markdown: String, version: Int) throws {
        try writeMarkdown(id, markdown: markdown)
        try updateRow(id: id, version: version)
    }

    /// Persists `title` for the matching row. Called by the manual
    /// refresh path so the sidebar reflects the latest H1 after the
    /// stored markdown changes. Idempotent on identical input.
    func updateTitle(id: UUID, title: String?) throws {
        let sql = "UPDATE meetings SET title = ? WHERE id = ?"
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard prepareResult == SQLITE_OK else {
            throw MeetingsStoreError.sqlitePrepareFailed(
                code: prepareResult,
                message: lastErrorMessage()
            )
        }
        try bindNullableText(stmt: stmt, position: 1, value: title)
        try bindText(stmt: stmt, position: 2, value: id.uuidString)
        let step = sqlite3_step(stmt)
        guard step == SQLITE_DONE else {
            throw MeetingsStoreError.sqliteStepFailed(
                code: step,
                message: lastErrorMessage()
            )
        }
    }

    /// Returns rows sorted by `started_at` DESC so the menu bar
    /// submenu and Stage 8b sidebar render newest-first without any
    /// additional sort.
    func list() throws -> [MeetingMetaWithLocalState] {
        let sql = """
            SELECT id, started_at, ended_at, duration_s, title,
                   sync_status, server_version, created_at,
                   progress_status, status_updated_at, failure_reason
            FROM meetings
            ORDER BY started_at DESC
            """
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard prepareResult == SQLITE_OK else {
            throw MeetingsStoreError.sqlitePrepareFailed(
                code: prepareResult,
                message: lastErrorMessage()
            )
        }

        var rows: [MeetingMetaWithLocalState] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw MeetingsStoreError.sqliteStepFailed(
                    code: step,
                    message: lastErrorMessage()
                )
            }
            let row = try Self.decodeRow(stmt: stmt)
            rows.append(row)
        }

        os_log(
            "store list returned (count: %{public}d)",
            log: Self.log, type: .info,
            rows.count
        )
        return rows
    }

    /// Flips `sync_status` from `new` to `read` for a specific meeting.
    /// Used by `AppDelegate` when the user clicks a submenu item — once
    /// Stage 8b opens the viewer window the badge / unread state will
    /// reflect the change.
    func markRead(id: UUID) throws {
        let sql = "UPDATE meetings SET sync_status = ? WHERE id = ?"
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard prepareResult == SQLITE_OK else {
            throw MeetingsStoreError.sqlitePrepareFailed(
                code: prepareResult,
                message: lastErrorMessage()
            )
        }
        try bindText(stmt: stmt, position: 1, value: MeetingSyncStatus.read.rawValue)
        try bindText(stmt: stmt, position: 2, value: id.uuidString)

        let step = sqlite3_step(stmt)
        guard step == SQLITE_DONE else {
            throw MeetingsStoreError.sqliteStepFailed(
                code: step,
                message: lastErrorMessage()
            )
        }
    }

    /// Returns the markdown body for a meeting, or `nil` if the file
    /// is missing. Disk errors are swallowed and logged so a corrupt
    /// install does not crash the menu rebuild.
    func markdown(id: UUID) throws -> String? {
        let path = markdownURL(for: id)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try String(contentsOf: path, encoding: .utf8)
    }

    /// Returns the persisted diarized transcript for a meeting, or
    /// `nil` when no sidecar exists (meetings finalized before the
    /// transcript-persistence change ship without one). Decoding
    /// failure is surfaced — a corrupt sidecar is a bug worth seeing.
    func transcript(id: UUID) throws -> [TranscriptSegment]? {
        let path = transcriptURL(for: id)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode([TranscriptSegment].self, from: data)
    }

    func updateTranscript(id: UUID, transcript: [TranscriptSegment]) throws {
        try writeTranscript(id, transcript: transcript)
    }

    /// `true` once the store contains at least one row. Used by
    /// `AppDelegate` to enable the menu bar "Meetings" item.
    /// Implemented as a `COUNT(*) > 0` query so a 10k-row DB stays
    /// O(1) under SQLite's btree.
    var hasMeetings: Bool {
        let sql = "SELECT 1 FROM meetings LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // MARK: - SQLite plumbing

    /// Opens the SQLite database at `rootDirectory/<dbFileName>`,
    /// creating the parent directory + tables + indexes if they don't
    /// exist yet. Returns the opaque handle the actor stores in `db`.
    ///
    /// `nonisolated` so the actor's `init` can call it before the
    /// serial executor exists.
    nonisolated private static func openAndBootstrap(
        rootDirectory: URL
    ) throws -> OpaquePointer {
        // Ensure root dir exists. Filesystem errors here are fatal —
        // the caller (AppDelegate) should not retry, the install is
        // broken in some way the user must resolve.
        if !FileManager.default.fileExists(atPath: rootDirectory.path) {
            do {
                try FileManager.default.createDirectory(
                    at: rootDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                throw MeetingsStoreError.filesystem(
                    "Could not create \(rootDirectory.path): \(error)"
                )
            }
        }

        let dbURL = rootDirectory.appendingPathComponent(databaseFileName)
        let flags = SQLITE_OPEN_READWRITE
            | SQLITE_OPEN_CREATE
            | SQLITE_OPEN_FULLMUTEX
        var dbHandle: OpaquePointer?
        let openResult = sqlite3_open_v2(dbURL.path, &dbHandle, flags, nil)
        guard openResult == SQLITE_OK, let dbHandle else {
            let msg: String
            if let dbHandle, let raw = sqlite3_errmsg(dbHandle) {
                msg = String(cString: raw)
            } else {
                msg = "open_v2 returned \(openResult)"
            }
            sqlite3_close(dbHandle)
            throw MeetingsStoreError.sqliteOpenFailed(code: openResult, message: msg)
        }

        try executeRaw(db: dbHandle, sql: """
            CREATE TABLE IF NOT EXISTS meetings (
                id TEXT PRIMARY KEY,
                started_at INTEGER NOT NULL,
                ended_at INTEGER NOT NULL,
                duration_s INTEGER NOT NULL,
                title TEXT,
                sync_status TEXT NOT NULL CHECK (sync_status IN ('new', 'read', 'pending_sync', 'failed')),
                server_version INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
                progress_status TEXT NOT NULL DEFAULT 'ready',
                status_updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
                failure_reason TEXT
            )
            """)
        try ensureColumn(
            db: dbHandle,
            name: "progress_status",
            declaration: "TEXT NOT NULL DEFAULT 'ready'"
        )
        try ensureColumn(
            db: dbHandle,
            name: "status_updated_at",
            declaration: "INTEGER NOT NULL DEFAULT 0"
        )
        try ensureColumn(db: dbHandle, name: "failure_reason", declaration: "TEXT")
        try executeRaw(db: dbHandle, sql: """
            CREATE INDEX IF NOT EXISTS idx_meetings_created_at
            ON meetings(created_at DESC)
            """)

        return dbHandle
    }

    nonisolated private static func executeRaw(
        db: OpaquePointer,
        sql: String
    ) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        if result != SQLITE_OK {
            let message: String
            if let errorPointer {
                message = String(cString: errorPointer)
                sqlite3_free(errorPointer)
            } else if let raw = sqlite3_errmsg(db) {
                message = String(cString: raw)
            } else {
                message = "unknown sqlite error"
            }
            throw MeetingsStoreError.sqliteStepFailed(code: result, message: message)
        }
    }

    nonisolated private static func ensureColumn(
        db: OpaquePointer,
        name: String,
        declaration: String
    ) throws {
        var stmt: OpaquePointer?
        let result = sqlite3_prepare_v2(db, "PRAGMA table_info(meetings)", -1, &stmt, nil)
        guard result == SQLITE_OK else {
            throw MeetingsStoreError.sqlitePrepareFailed(
                code: result,
                message: String(cString: sqlite3_errmsg(db))
            )
        }
        defer { sqlite3_finalize(stmt) }
        var exists = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let raw = sqlite3_column_text(stmt, 1), String(cString: raw) == name {
                exists = true
                break
            }
        }
        if !exists {
            try executeRaw(db: db, sql: "ALTER TABLE meetings ADD COLUMN \(name) \(declaration)")
        }
    }

    private func insertOrIgnoreRow(meta: MeetingMetaWithLocalState) throws {
        try insertOrUpdateRow(meta: meta)
    }

    private func insertOrUpdateRow(meta: MeetingMetaWithLocalState) throws {
        let sql = """
            INSERT INTO meetings
            (id, started_at, ended_at, duration_s, title, sync_status, server_version, created_at,
             progress_status, status_updated_at, failure_reason)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                started_at = excluded.started_at,
                ended_at = excluded.ended_at,
                duration_s = excluded.duration_s,
                title = COALESCE(excluded.title, meetings.title),
                server_version = excluded.server_version,
                progress_status = excluded.progress_status,
                status_updated_at = excluded.status_updated_at,
                failure_reason = excluded.failure_reason
            """
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard prepareResult == SQLITE_OK else {
            throw MeetingsStoreError.sqlitePrepareFailed(
                code: prepareResult,
                message: lastErrorMessage()
            )
        }

        try bindText(stmt: stmt, position: 1, value: meta.id.uuidString)
        try bindInt(stmt: stmt, position: 2, value: Int(meta.startedAt.timeIntervalSince1970))
        // ended_at NOT NULL in the schema — when the finalize result
        // does not carry one (still in progress) we fall back to
        // started_at so the row stays valid. Finalize always sets
        // ended_at by the time a row is written, so in practice this
        // fallback should never fire.
        let endedSeconds = Int((meta.endedAt ?? meta.startedAt).timeIntervalSince1970)
        try bindInt(stmt: stmt, position: 3, value: endedSeconds)
        try bindInt(stmt: stmt, position: 4, value: meta.durationSeconds)
        try bindNullableText(stmt: stmt, position: 5, value: meta.title)
        try bindText(stmt: stmt, position: 6, value: meta.syncStatus.rawValue)
        try bindInt(stmt: stmt, position: 7, value: meta.serverVersion)
        try bindInt(stmt: stmt, position: 8, value: Int(meta.createdAt.timeIntervalSince1970))
        try bindText(stmt: stmt, position: 9, value: meta.progressStatus.rawValue)
        try bindInt(stmt: stmt, position: 10, value: Int(meta.statusUpdatedAt.timeIntervalSince1970))
        try bindNullableText(stmt: stmt, position: 11, value: meta.failureReason)

        let step = sqlite3_step(stmt)
        guard step == SQLITE_DONE else {
            throw MeetingsStoreError.sqliteStepFailed(
                code: step,
                message: lastErrorMessage()
            )
        }
    }

    private func updateRow(id: UUID, version: Int) throws {
        let sql = "UPDATE meetings SET server_version = ? WHERE id = ?"
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard prepareResult == SQLITE_OK else {
            throw MeetingsStoreError.sqlitePrepareFailed(
                code: prepareResult,
                message: lastErrorMessage()
            )
        }
        try bindInt(stmt: stmt, position: 1, value: version)
        try bindText(stmt: stmt, position: 2, value: id.uuidString)
        let step = sqlite3_step(stmt)
        guard step == SQLITE_DONE else {
            throw MeetingsStoreError.sqliteStepFailed(
                code: step,
                message: lastErrorMessage()
            )
        }
    }

    private static func decodeRow(stmt: OpaquePointer?) throws -> MeetingMetaWithLocalState {
        guard let stmt else {
            throw MeetingsStoreError.invalidRow("nil stmt")
        }
        guard let idRaw = sqlite3_column_text(stmt, 0) else {
            throw MeetingsStoreError.invalidRow("id column null")
        }
        let idString = String(cString: idRaw)
        guard let id = UUID(uuidString: idString) else {
            throw MeetingsStoreError.invalidRow("id column not a UUID: \(idString)")
        }

        let startedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1)))
        let endedAtRaw = sqlite3_column_int64(stmt, 2)
        // Schema requires NOT NULL on ended_at — we always have one in
        // practice. Keep the column nullable on the Swift side so a
        // future schema migration can drop the NOT NULL without
        // breaking call sites.
        let endedAt: Date? = endedAtRaw == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(endedAtRaw))
        let durationSeconds = Int(sqlite3_column_int64(stmt, 3))
        let title: String?
        if let titleRaw = sqlite3_column_text(stmt, 4) {
            title = String(cString: titleRaw)
        } else {
            title = nil
        }

        guard let statusRaw = sqlite3_column_text(stmt, 5) else {
            throw MeetingsStoreError.invalidRow("sync_status column null")
        }
        let statusString = String(cString: statusRaw)
        guard let syncStatus = MeetingSyncStatus(rawValue: statusString) else {
            throw MeetingsStoreError.invalidRow("sync_status not in CHECK set: \(statusString)")
        }
        let serverVersion = Int(sqlite3_column_int64(stmt, 6))
        let createdAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 7)))
        let progressRaw = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            ?? MeetingProgressStatus.ready.rawValue
        let progressStatus = MeetingProgressStatus(rawValue: progressRaw) ?? .ready
        let statusUpdatedAt = Date(
            timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 9))
        )
        let failureReason = sqlite3_column_text(stmt, 10).map { String(cString: $0) }

        return MeetingMetaWithLocalState(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: durationSeconds,
            title: title,
            syncStatus: syncStatus,
            serverVersion: serverVersion,
            createdAt: createdAt,
            progressStatus: progressStatus,
            statusUpdatedAt: statusUpdatedAt,
            failureReason: failureReason
        )
    }

    private func bindText(stmt: OpaquePointer?, position: Int32, value: String) throws {
        // SQLITE_TRANSIENT (`-1`) tells SQLite to copy the buffer; the
        // Swift String backing memory may be released before the
        // statement steps.
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = sqlite3_bind_text(stmt, position, value, -1, SQLITE_TRANSIENT)
        if result != SQLITE_OK {
            throw MeetingsStoreError.sqliteBindFailed(
                code: result,
                message: lastErrorMessage()
            )
        }
    }

    private func bindNullableText(stmt: OpaquePointer?, position: Int32, value: String?) throws {
        if let value {
            try bindText(stmt: stmt, position: position, value: value)
        } else {
            let result = sqlite3_bind_null(stmt, position)
            if result != SQLITE_OK {
                throw MeetingsStoreError.sqliteBindFailed(
                    code: result,
                    message: lastErrorMessage()
                )
            }
        }
    }

    private func bindInt(stmt: OpaquePointer?, position: Int32, value: Int) throws {
        let result = sqlite3_bind_int64(stmt, position, Int64(value))
        if result != SQLITE_OK {
            throw MeetingsStoreError.sqliteBindFailed(
                code: result,
                message: lastErrorMessage()
            )
        }
    }

    private func lastErrorMessage() -> String {
        guard let db else { return "no db handle" }
        if let raw = sqlite3_errmsg(db) {
            return String(cString: raw)
        }
        return "unknown sqlite error"
    }

    // MARK: - Markdown filesystem

    private func markdownURL(for id: UUID) -> URL {
        rootDirectory.appendingPathComponent("\(id.uuidString).md")
    }

    private func transcriptURL(for id: UUID) -> URL {
        rootDirectory.appendingPathComponent("\(id.uuidString)-transcript.json")
    }

    private func writeMarkdown(_ id: UUID, markdown: String) throws {
        let target = markdownURL(for: id)
        let data = Data(markdown.utf8)
        do {
            try data.write(to: target, options: [.atomic])
        } catch {
            throw MeetingsStoreError.filesystem(
                "Could not write markdown for \(id.uuidString): \(error)"
            )
        }
    }

    private func writeTranscript(
        _ id: UUID,
        transcript: [TranscriptSegment]
    ) throws {
        let target = transcriptURL(for: id)
        do {
            let data = try JSONEncoder().encode(transcript)
            try data.write(to: target, options: [.atomic])
        } catch {
            throw MeetingsStoreError.filesystem(
                "Could not write transcript for \(id.uuidString): \(error)"
            )
        }
    }
}
