import SQLite3
import XCTest
@testable import Sidekey

/// The History database no longer keeps deleted copies readable: a one-time
/// VACUUM scrubs what older versions left in free pages, and every delete
/// after opening zeroes its bytes. History itself is never wiped. All stores
/// are temporary files with synthetic markers.
/// WHY: .project-docs/decisions/2026-10-22-history-free-page-scrub.md
final class HistoryFreePageScrubTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs = []
        super.tearDown()
    }

    // MARK: - Scrubbing what older versions left

    /// Break caught: rows that earlier versions evicted or trimmed (without
    /// secure_delete) stay readable in free pages or in the spare space of
    /// live pages after the scrub.
    func testScrubRemovesCopiesThatOlderVersionsDeleted() throws {
        let dbURL = makeTempDir().appendingPathComponent("history.sqlite")
        let markers = try makeLegacyDatabase(at: dbURL)
        let before = try databaseFiles(at: dbURL)
        for marker in markers {
            XCTAssertTrue(before.contains(Data(marker.utf8)),
                          "precondition: \(marker) must be readable before the scrub")
        }

        let store = try SQLiteHistoryStore(path: dbURL.path)
        guard case .scrubbed(let freedBytes) = try store.scrubFreePagesIfNeeded() else {
            return XCTFail("expected a completed scrub")
        }

        XCTAssertGreaterThan(freedBytes, 0)
        let after = try databaseFiles(at: dbURL)
        for marker in markers {
            XCTAssertFalse(after.contains(Data(marker.utf8)), "\(marker) survived the scrub")
        }
        XCTAssertEqual(try store.latestClipboardEntries(limit: 50).map(\.payload),
                       (0..<5).reversed().map { .text("kept clipboard \($0)") })
        XCTAssertEqual(try store.latestDropEntries(limit: 50).map(\.formattedText), ["kept drop"])
        XCTAssertEqual(try store.latestAgentEntries(limit: 50).map(\.queryText), ["kept agent"])
    }

    /// Break caught: the scrub loses rows, image sidecars or ids (the UI
    /// keeps row ids), or an id is handed out again after it.
    func testScrubKeepsEveryRowAndId() throws {
        let root = makeTempDir()
        let assets = root.appendingPathComponent("history-assets", isDirectory: true)
        let store = try SQLiteHistoryStore(path: root.appendingPathComponent("history.sqlite").path)
        let imageUUID = UUID()
        try store.insertClipboardTextEntry(createdAt: date(1), text: "text copy")
        try store.insertClipboardImageEntry(
            createdAt: date(2), uuid: imageUUID, imageData: Data(repeating: 0xAB, count: 4_096),
            imageExtension: "png", thumbnailData: Data(repeating: 0xCD, count: 64), assetsDirectory: assets)
        try store.insertClipboardFileURLsEntry(createdAt: date(3), urls: [root.appendingPathComponent("a.txt")])
        let newest = try store.insertClipboardTextEntry(createdAt: date(4), text: "newest")
        try store.insertDropEntry(createdAt: date(5), rawTranscript: "raw", formattedText: "formatted", targetApp: "Notes")
        let chat = try store.insertAgentEntry(
            createdAt: date(6), queryText: "question", queryMode: .voice, responseMarkdown: "answer", toolNames: ["read"])
        try store.updateAgentEntry(id: chat, title: "Title", blocksJSON: "[]", status: .done,
                                   responseMarkdown: "answer", toolNames: ["read"])
        let clipboard = try store.latestClipboardEntries(limit: 50)
        let drops = try store.latestDropEntries(limit: 50)
        let chats = try store.latestChatRows(limit: 50)

        guard case .scrubbed = try store.scrubFreePagesIfNeeded() else {
            return XCTFail("expected a completed scrub")
        }

        XCTAssertEqual(try store.latestClipboardEntries(limit: 50), clipboard)
        XCTAssertEqual(try store.latestDropEntries(limit: 50), drops)
        XCTAssertEqual(try store.latestChatRows(limit: 50), chats)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: assets.appendingPathComponent("\(imageUUID.uuidString).png").path))
        XCTAssertGreaterThan(try store.insertClipboardTextEntry(createdAt: date(7), text: "next"), newest)
    }

    // MARK: - Once per database file

    /// Break caught: the VACUUM repeats on every launch, or a scrubbed
    /// record from one file suppresses the scrub of an older copy (a
    /// restored archive) that never had it.
    func testScrubRunsOncePerDatabaseFile() throws {
        let root = makeTempDir()
        let dbURL = root.appendingPathComponent("history.sqlite")
        let olderCopy = root.appendingPathComponent("older-copy.sqlite")
        _ = try makeLegacyDatabase(at: dbURL)
        try FileManager.default.copyItem(at: dbURL, to: olderCopy)

        do {
            let store = try SQLiteHistoryStore(path: dbURL.path)
            guard case .scrubbed = try store.scrubFreePagesIfNeeded() else {
                return XCTFail("expected a completed scrub")
            }
            XCTAssertEqual(try store.scrubFreePagesIfNeeded(), .alreadyScrubbed)
        }
        // Next launch: a new connection to the same file.
        XCTAssertEqual(try SQLiteHistoryStore(path: dbURL.path).scrubFreePagesIfNeeded(), .alreadyScrubbed)

        guard case .scrubbed = try SQLiteHistoryStore(path: olderCopy.path).scrubFreePagesIfNeeded() else {
            return XCTFail("an older copy without the record must be scrubbed")
        }
    }

    /// Break caught: the scrub fills a nearly full disk, or a skipped pass
    /// is recorded as done and never retried.
    func testTooLittleDiskSpaceSkipsWithoutChangesAndRetriesLater() throws {
        let dbURL = makeTempDir().appendingPathComponent("history.sqlite")
        let markers = try makeLegacyDatabase(at: dbURL)
        let store = try SQLiteHistoryStore(path: dbURL.path)
        var checkedDirectory: URL?

        let skipped = try store.scrubFreePagesIfNeeded(availableCapacity: { directory in
            checkedDirectory = directory
            return 1_024
        })

        XCTAssertEqual(skipped, .skippedLowDiskSpace)
        XCTAssertEqual(checkedDirectory?.standardizedFileURL, dbURL.deletingLastPathComponent().standardizedFileURL)
        XCTAssertTrue(try databaseFiles(at: dbURL).contains(Data(markers[0].utf8)))
        XCTAssertEqual(try store.latestClipboardEntries(limit: 50).count, 5)

        guard case .scrubbed = try store.scrubFreePagesIfNeeded(availableCapacity: { _ in .max }) else {
            return XCTFail("the next pass with enough space must scrub")
        }
        XCTAssertFalse(try databaseFiles(at: dbURL).contains(Data(markers[0].utf8)))
    }

    /// Break caught: the space check uses the file size, so 100 MB of free
    /// pages block a scrub that only needs room for the live rows.
    func testRequiredSpaceFollowsLiveRowsNotFileSize() {
        let mib: Int64 = 1_024 * 1_024
        XCTAssertEqual(SQLiteHistoryStore.freePageScrubRequiredBytes(liveBytes: 48 * mib), 160 * mib)
        XCTAssertEqual(SQLiteHistoryStore.freePageScrubRequiredBytes(liveBytes: 0), 64 * mib)
    }

    // MARK: - Deletes after opening

    /// Break caught: the connection keeps the system default (FAST), so a
    /// long copy evicted by the cap, a trimmed Drop entry or agent chat
    /// leaves its overflow pages readable as free pages.
    func testCapEvictionsAndTrimmingZeroTheDeletedBytes() throws {
        let root = makeTempDir()
        let dbURL = root.appendingPathComponent("history.sqlite")
        // The marker sits at the end of a long value, in its overflow pages.
        let padding = String(repeating: "p", count: 20_000)
        let clipboardMarker = "whytap-scrub-evicted-\(UUID().uuidString)"
        let dropMarker = "whytap-scrub-drop-\(UUID().uuidString)"
        let agentMarker = "whytap-scrub-agent-\(UUID().uuidString)"
        do {
            let store = try SQLiteHistoryStore(path: dbURL.path)
            try store.insertClipboardTextEntry(createdAt: date(1), text: padding + clipboardMarker)
            try store.insertDropEntry(createdAt: date(1), rawTranscript: padding + dropMarker,
                                      formattedText: "short", targetApp: nil)
            let chat = try store.insertAgentEntry(createdAt: date(1), queryText: "question", queryMode: .text,
                                                  responseMarkdown: padding + agentMarker, toolNames: [])
            for index in 0..<3 {
                try store.insertClipboardTextEntry(createdAt: date(Double(10 + index)), text: "newer \(index)")
                try store.insertDropEntry(createdAt: date(Double(10 + index)), rawTranscript: "newer \(index)",
                                          formattedText: "newer \(index)", targetApp: nil)
            }

            try store.enforceClipboardCap(maxRows: 3, assetsDirectory: root)
            try store.enforceDropCap(maxRows: 3)
            try store.deleteAgentEntries(ids: [chat])

            XCTAssertEqual(try store.latestClipboardEntries(limit: 50).count, 3)
            XCTAssertEqual(try store.latestDropEntries(limit: 50).count, 3)
        }
        // Closing the last connection checkpoints the WAL into the file.
        let bytes = try databaseFiles(at: dbURL)
        XCTAssertGreaterThan(bytes.count, 0)
        for marker in [clipboardMarker, dropMarker, agentMarker] {
            XCTAssertFalse(bytes.contains(Data(marker.utf8)), "\(marker) is still readable")
        }
    }

    // MARK: - Running it at launch

    /// Break caught: the launch path runs the VACUUM on the main thread.
    func testBackgroundScrubRunsOffTheMainThread() throws {
        let dbURL = makeTempDir().appendingPathComponent("history.sqlite")
        _ = try makeLegacyDatabase(at: dbURL)
        let store = try SQLiteHistoryStore(path: dbURL.path)
        let finished = expectation(description: "scrub finished")
        let report = Report()

        store.scrubFreePagesInBackground { result in
            report.set(Thread.isMainThread, try? result.get())
            finished.fulfill()
        }

        wait(for: [finished], timeout: 10)
        let (ranOnMain, outcome) = report.get()
        XCTAssertEqual(ranOnMain, false)
        guard case .scrubbed = outcome else { return XCTFail("expected a completed scrub, got \(String(describing: outcome))") }
    }

    /// Break caught: copies recorded while the scrub runs fail with
    /// SQLITE_BUSY or disappear, instead of waiting for the store queue.
    func testCopiesRecordedDuringTheScrubAreKept() throws {
        let dbURL = makeTempDir().appendingPathComponent("history.sqlite")
        _ = try makeLegacyDatabase(at: dbURL)
        let store = try SQLiteHistoryStore(path: dbURL.path)
        let finished = expectation(description: "scrub finished")
        let report = Report()

        store.scrubFreePagesInBackground { result in
            report.set(false, try? result.get())
            finished.fulfill()
        }
        for index in 0..<20 {
            try store.insertClipboardTextEntry(createdAt: date(Double(100 + index)), text: "during \(index)")
        }

        wait(for: [finished], timeout: 10)
        guard case .scrubbed = report.get().1 else { return XCTFail("expected a completed scrub") }
        let texts = try store.latestClipboardEntries(limit: 50).compactMap { entry -> String? in
            if case .text(let text) = entry.payload { return text }
            return nil
        }
        XCTAssertEqual(texts.count, 25)
        XCTAssertEqual(Set(texts.prefix(20)), Set((0..<20).map { "during \($0)" }))
    }

    // MARK: - Helpers

    private final class Report: @unchecked Sendable {
        private let lock = NSLock()
        private var ranOnMain: Bool?
        private var outcome: SQLiteHistoryStore.FreePageScrubOutcome?

        func set(_ ranOnMain: Bool, _ outcome: SQLiteHistoryStore.FreePageScrubOutcome?) {
            lock.lock(); defer { lock.unlock() }
            self.ranOnMain = ranOnMain
            self.outcome = outcome
        }

        func get() -> (Bool?, SQLiteHistoryStore.FreePageScrubOutcome?) {
            lock.lock(); defer { lock.unlock() }
            return (ranOnMain, outcome)
        }
    }

    /// Builds a closed database as an older version left it: the current
    /// schema, kept rows, and evicted/trimmed rows deleted with
    /// `secure_delete` off. Returns the deleted rows' markers: a short one
    /// inside a page and a long one reaching overflow pages.
    private func makeLegacyDatabase(at dbURL: URL) throws -> [String] {
        do { _ = try SQLiteHistoryStore(path: dbURL.path) }
        let padding = String(repeating: "q", count: 20_000)
        let shortMarker = "whytap-scrub-short-\(UUID().uuidString)"
        let longMarker = "whytap-scrub-long-\(UUID().uuidString)"
        let dropMarker = "whytap-scrub-legacy-drop-\(UUID().uuidString)"
        let agentMarker = "whytap-scrub-legacy-agent-\(UUID().uuidString)"

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "legacy", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
        }
        try exec("PRAGMA secure_delete = OFF;")
        try exec("""
            INSERT INTO clipboard_entries (created_at, kind, text_content) VALUES
                (1, 'text', '\(shortMarker)'),
                (2, 'text', '\(padding)\(longMarker)');
            INSERT INTO drop_entries (created_at, raw_transcript, formatted_text) VALUES
                (1, '\(padding)\(dropMarker)', 'evicted'), (9, 'kept', 'kept drop');
            INSERT INTO agent_entries (created_at, query_text, query_mode, response_markdown) VALUES
                (1, 'trimmed', 'text', '\(padding)\(agentMarker)'), (9, 'kept agent', 'text', 'answer');
        """)
        for index in 0..<5 {
            try exec("INSERT INTO clipboard_entries (created_at, kind, text_content) VALUES (\(10 + index), 'text', 'kept clipboard \(index)');")
        }
        try exec("""
            DELETE FROM clipboard_entries WHERE created_at < 10;
            DELETE FROM drop_entries WHERE created_at = 1;
            DELETE FROM agent_entries WHERE created_at = 1;
        """)
        return [shortMarker, longMarker, dropMarker, agentMarker]
    }

    private func databaseFiles(at dbURL: URL) throws -> Data {
        var bytes = try Data(contentsOf: dbURL)
        let wal = URL(fileURLWithPath: dbURL.path + "-wal")
        if let walBytes = try? Data(contentsOf: wal) { bytes.append(walBytes) }
        return bytes
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_000 + seconds)
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whytap-history-scrub-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }
}
