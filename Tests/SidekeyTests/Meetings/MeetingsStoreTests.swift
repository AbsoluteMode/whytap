import XCTest
@testable import Sidekey

/// Stage 7 tests for `MeetingsStore`. The store persists meeting
/// metadata to a raw SQLite database and the markdown body to a sibling
/// `<id>.md` file under
/// `~/Library/Application Support/Sidekey/Meetings/` (the production
/// path; tests inject an isolated temp directory).
///
/// Contract pinned by these tests:
/// 1. `insert(meta, markdown)` writes one SQLite row AND one markdown
///    file. The row is `sync_status = 'new'` by default; the markdown
///    file is written atomically via tmp+rename.
/// 2. The atomic write pattern leaves no `.tmp` file behind once the
///    insert returns (rename succeeded).
/// 3. Schema creation is idempotent — opening the same DB twice is a
///    no-op once tables exist (`CREATE TABLE IF NOT EXISTS`).
/// 4. `list()` returns rows sorted by `started_at` descending.
/// 5. `markRead(id)` flips `sync_status` from `new` to `read`.
/// 6. `hasMeetings` returns `false` for an empty store, `true` once a
///    row exists. Used by `AppDelegate` to gate the menu bar entry.
final class MeetingsStoreTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetings-store-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tempRoot, withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - 1. insert meta + markdown

    func test_insert_meta_and_markdown() async throws {
        let store = try MeetingsStore(rootDirectory: tempRoot)

        let id = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let endedAt = Date(timeIntervalSince1970: 1_700_000_900)
        let meta = MeetingMetaWithLocalState(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: 900,
            title: nil,
            syncStatus: .new,
            serverVersion: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_905)
        )
        let markdown = "# Notes\n\nDecisions: ship it."

        try await store.insert(meta: meta, markdown: markdown)

        let listed = try await store.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].id, id)
        XCTAssertEqual(listed[0].startedAt, startedAt)
        XCTAssertEqual(listed[0].endedAt, endedAt)
        XCTAssertEqual(listed[0].durationSeconds, 900)
        XCTAssertEqual(listed[0].syncStatus, .new)

        // Markdown was written to the sibling file
        let markdownPath = tempRoot.appendingPathComponent("\(id.uuidString).md")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: markdownPath.path),
            "Markdown file must exist at <root>/<id>.md"
        )
        let content = try String(contentsOf: markdownPath, encoding: .utf8)
        XCTAssertEqual(content, markdown)

        let viaApi = try await store.markdown(id: id)
        XCTAssertEqual(viaApi, markdown)
    }

    // MARK: - 2. atomic write via rename

    func test_atomic_markdown_write_via_rename() async throws {
        let store = try MeetingsStore(rootDirectory: tempRoot)

        let id = UUID()
        let meta = MeetingMetaWithLocalState(
            id: id,
            startedAt: Date(),
            endedAt: Date(),
            durationSeconds: 0,
            title: nil,
            syncStatus: .new,
            serverVersion: 1,
            createdAt: Date()
        )
        try await store.insert(meta: meta, markdown: "body")

        let markdownPath = tempRoot.appendingPathComponent("\(id.uuidString).md")
        let tmpPath = tempRoot.appendingPathComponent("\(id.uuidString).md.tmp")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: markdownPath.path),
            "Final markdown file must exist"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tmpPath.path),
            "Tmp file must not remain after successful insert (rename consumed it)"
        )
    }

    // MARK: - 3. schema creation idempotent

    func test_schema_v1_creation_idempotent() async throws {
        // Open twice in succession. Second open must not error and must
        // see the row written by the first.
        let store1 = try MeetingsStore(rootDirectory: tempRoot)
        let id = UUID()
        try await store1.insert(
            meta: MeetingMetaWithLocalState(
                id: id,
                startedAt: Date(),
                endedAt: Date(),
                durationSeconds: 0,
                title: nil,
                syncStatus: .new,
                serverVersion: 1,
                createdAt: Date()
            ),
            markdown: "x"
        )
        await store1.close()

        // Re-open — CREATE TABLE IF NOT EXISTS must be a no-op.
        let store2 = try MeetingsStore(rootDirectory: tempRoot)
        let listed = try await store2.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].id, id)
    }

    // MARK: - 4. list order

    func test_list_returns_descending_started_at() async throws {
        let store = try MeetingsStore(rootDirectory: tempRoot)

        // Insert three meetings with started_at out of natural insertion
        // order so a naive `ORDER BY rowid` would visibly differ from a
        // proper `ORDER BY started_at DESC`.
        let earliest = MeetingMetaWithLocalState(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_100),
            durationSeconds: 100,
            title: nil,
            syncStatus: .new,
            serverVersion: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_110)
        )
        let latest = MeetingMetaWithLocalState(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_100_000),
            endedAt: Date(timeIntervalSince1970: 1_700_100_100),
            durationSeconds: 100,
            title: nil,
            syncStatus: .new,
            serverVersion: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_100_110)
        )
        let middle = MeetingMetaWithLocalState(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_050_000),
            endedAt: Date(timeIntervalSince1970: 1_700_050_100),
            durationSeconds: 100,
            title: nil,
            syncStatus: .new,
            serverVersion: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_050_110)
        )

        try await store.insert(meta: earliest, markdown: "e")
        try await store.insert(meta: latest, markdown: "l")
        try await store.insert(meta: middle, markdown: "m")

        let listed = try await store.list()
        XCTAssertEqual(listed.map { $0.id }, [latest.id, middle.id, earliest.id])
    }

    // MARK: - 5. markRead

    func test_mark_read_updates_sync_status() async throws {
        let store = try MeetingsStore(rootDirectory: tempRoot)

        let id = UUID()
        let meta = MeetingMetaWithLocalState(
            id: id,
            startedAt: Date(),
            endedAt: Date(),
            durationSeconds: 0,
            title: nil,
            syncStatus: .new,
            serverVersion: 1,
            createdAt: Date()
        )
        try await store.insert(meta: meta, markdown: "y")

        let beforeList = try await store.list()
        XCTAssertEqual(beforeList.first?.syncStatus, .new)

        try await store.markRead(id: id)

        let afterList = try await store.list()
        XCTAssertEqual(afterList.first?.syncStatus, .read)
    }

    // MARK: - 6. hasMeetings

    func test_has_meetings_returns_false_when_empty_true_when_populated() async throws {
        let store = try MeetingsStore(rootDirectory: tempRoot)

        let emptyState = await store.hasMeetings
        XCTAssertFalse(emptyState, "Empty store must report hasMeetings = false")

        let meta = MeetingMetaWithLocalState(
            id: UUID(),
            startedAt: Date(),
            endedAt: Date(),
            durationSeconds: 0,
            title: nil,
            syncStatus: .new,
            serverVersion: 1,
            createdAt: Date()
        )
        try await store.insert(meta: meta, markdown: "z")

        let populated = await store.hasMeetings
        XCTAssertTrue(populated, "Store with at least one row must report hasMeetings = true")
    }

    func test_progress_status_persists_and_transitions_to_failed_with_reason() async throws {
        let store = try MeetingsStore(rootDirectory: tempRoot)
        let id = UUID()
        let meta = MeetingMetaWithLocalState(
            id: id,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_120),
            durationSeconds: 120,
            title: nil,
            syncStatus: .new,
            serverVersion: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_120),
            progressStatus: .waitingToReconnect
        )

        try await store.upsertProgress(meta: meta, status: .waitingToReconnect)
        let waiting = try await store.list().first
        XCTAssertEqual(waiting?.progressStatus, .waitingToReconnect)

        try await store.updateProgress(
            id: id,
            status: .failed,
            failureReason: "provider unavailable"
        )
        let failed = try await store.list().first
        XCTAssertEqual(failed?.progressStatus, .failed)
        XCTAssertEqual(failed?.failureReason, "provider unavailable")
    }

    func test_ready_progress_is_terminal_against_late_failure() async throws {
        let store = try MeetingsStore(rootDirectory: tempRoot)
        let id = UUID()
        let meta = MeetingMetaWithLocalState(
            id: id,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_120),
            durationSeconds: 120,
            title: "Already ready",
            syncStatus: .new,
            serverVersion: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_120),
            progressStatus: .ready
        )
        try await store.insert(meta: meta, markdown: "# Already ready")

        let changed = try await store.updateProgress(
            id: id,
            status: .failed,
            failureReason: "Processing timed out"
        )

        XCTAssertFalse(changed, "A late poller must not regress a ready meeting")
        let finalStatus = try await store.progressStatus(id: id)
        XCTAssertEqual(finalStatus, .ready)
        let persisted = try await store.list().first
        XCTAssertNil(persisted?.failureReason)
    }
}
