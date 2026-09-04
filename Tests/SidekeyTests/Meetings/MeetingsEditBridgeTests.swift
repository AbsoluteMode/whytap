import Combine
import XCTest
@testable import Sidekey

/// Stage 8c tests for `MeetingsEditBridge`: the WKScriptMessageHandler
/// adapter that receives BlockNote `noteEdit` postMessage calls,
/// validates the payload schema, debounces a burst of keystroke-driven
/// edits down to one Combine emission, and forwards the final value to
/// the coordinator's `saveNoteEdit`.
///
/// Plan-pinned tests:
///
/// 1. `test_js_edit_message_invokes_save_after_debounce`: a valid
///    payload posted to the bridge eventually surfaces on the
///    `editEvents` publisher (after the debounce window).
/// 2. `test_invalid_payload_schema_rejected`: malformed messages
///    (missing keys, wrong types) are dropped without ever emitting.
/// 3. `test_save_persists_to_local_store_with_bumped_version`: the
///    coordinator's `saveNoteEdit` writes the markdown into the local
///    store with `clientVersion + 1` and re-derives the sidebar title.
@MainActor
final class MeetingsEditBridgeTests: XCTestCase {

    // MARK: - Helpers

    /// In-process `UserDefaults` so flipping `MeetingsConfig.isEnabled`
    /// here does not leak into the user's real defaults. Mirrors the
    /// pattern already used by `MeetingsCoordinatorTests`.
    private var testDefaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "com.sidekey.meetings.editbridge.tests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: defaultsSuiteName)!
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: defaultsSuiteName)
        testDefaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    // MARK: - Test 1: valid payload reaches subscribers after debounce

    func test_js_edit_message_invokes_save_after_debounce() async throws {
        // Tiny debounce so the test runs in milliseconds, not 500 ms per
        // assertion. The production wiring uses 500 ms; the bridge takes
        // it as a parameter so this seam exists.
        let bridge = MeetingsEditBridge(debounceMilliseconds: 50)
        let meetingId = UUID()
        bridge.attachMeeting(id: meetingId)

        var received: [MeetingsEditBridge.EditEvent] = []
        let cancellable = bridge.editEvents.sink { event in
            received.append(event)
        }

        bridge.handleScriptMessage(name: "noteEdit", body: [
            "markdown": "# Edit one",
            "clientVersion": 3
        ])

        // Wait long enough for the debounce window to elapse.
        try await Task.sleep(nanoseconds: 200_000_000)

        cancellable.cancel()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.markdown, "# Edit one")
        XCTAssertEqual(received.first?.clientVersion, 3)
        XCTAssertEqual(received.first?.meetingId, meetingId)
    }

    // MARK: - Native editor entry point

    /// The native markdown editor's `submitEdit` reaches the same publisher
    /// the webview path used — debounced, tagged with the attached meeting.
    func test_native_submitEdit_invokes_save_after_debounce() async throws {
        let bridge = MeetingsEditBridge(debounceMilliseconds: 50)
        let meetingId = UUID()
        bridge.attachMeeting(id: meetingId)

        var received: [MeetingsEditBridge.EditEvent] = []
        let cancellable = bridge.editEvents.sink { received.append($0) }

        bridge.submitEdit(markdown: "# Native edit", clientVersion: 7)
        try await Task.sleep(nanoseconds: 200_000_000)
        cancellable.cancel()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.markdown, "# Native edit")
        XCTAssertEqual(received.first?.clientVersion, 7)
        XCTAssertEqual(received.first?.meetingId, meetingId)
    }

    /// Without an attached meeting the edit is dropped — same guard as the
    /// webview path, so a stray save can't land on the wrong note.
    func test_native_submitEdit_dropped_without_attached_meeting() async throws {
        let bridge = MeetingsEditBridge(debounceMilliseconds: 50)

        var received: [MeetingsEditBridge.EditEvent] = []
        let cancellable = bridge.editEvents.sink { received.append($0) }

        bridge.submitEdit(markdown: "orphan", clientVersion: 1)
        try await Task.sleep(nanoseconds: 150_000_000)
        cancellable.cancel()

        XCTAssertTrue(received.isEmpty)
    }

    /// Debounce coalesces a burst of edits into a single trailing emit,
    /// matching the BlockNote "every keystroke" rate without rewriting the
    /// note file on every keystroke.
    func test_burst_of_edits_coalesces_to_single_emission() async throws {
        let bridge = MeetingsEditBridge(debounceMilliseconds: 80)
        let meetingId = UUID()
        bridge.attachMeeting(id: meetingId)

        var received: [MeetingsEditBridge.EditEvent] = []
        let cancellable = bridge.editEvents.sink { event in
            received.append(event)
        }

        for i in 0..<5 {
            bridge.handleScriptMessage(name: "noteEdit", body: [
                "markdown": "# Edit \(i)",
                "clientVersion": 1
            ])
            try await Task.sleep(nanoseconds: 10_000_000) // 10 ms between bursts
        }
        try await Task.sleep(nanoseconds: 250_000_000) // pad past the debounce

        cancellable.cancel()
        XCTAssertEqual(
            received.count, 1,
            "Debounce must coalesce a 5-message burst into one emission."
        )
        XCTAssertEqual(received.first?.markdown, "# Edit 4")
    }

    // MARK: - Test 2: invalid payloads are rejected

    func test_invalid_payload_schema_rejected() async throws {
        let bridge = MeetingsEditBridge(debounceMilliseconds: 30)
        let meetingId = UUID()
        bridge.attachMeeting(id: meetingId)

        var received: [MeetingsEditBridge.EditEvent] = []
        let cancellable = bridge.editEvents.sink { event in
            received.append(event)
        }

        // Wrong message name — bridge must not even see this.
        bridge.handleScriptMessage(name: "somethingElse", body: [
            "markdown": "x", "clientVersion": 1
        ])
        // Missing `markdown` key.
        bridge.handleScriptMessage(name: "noteEdit", body: [
            "clientVersion": 1
        ])
        // `markdown` is the wrong type (Int instead of String).
        bridge.handleScriptMessage(name: "noteEdit", body: [
            "markdown": 42, "clientVersion": 1
        ])
        // `clientVersion` missing.
        bridge.handleScriptMessage(name: "noteEdit", body: [
            "markdown": "x"
        ])
        // `clientVersion` is a string (not coercible).
        bridge.handleScriptMessage(name: "noteEdit", body: [
            "markdown": "x", "clientVersion": "abc"
        ])
        // body is not a dict at all.
        bridge.handleScriptMessage(name: "noteEdit", body: "not a dict")

        try await Task.sleep(nanoseconds: 150_000_000)

        cancellable.cancel()
        XCTAssertTrue(
            received.isEmpty,
            "No invalid payload should ever surface on editEvents. Got: \(received)"
        )
    }

    /// Bridge with no attached meeting drops every message — defends
    /// against a race where the WKWebView fires a `noteEdit` event
    /// before the viewer has loaded a meeting.
    func test_edit_dropped_when_no_meeting_attached() async throws {
        let bridge = MeetingsEditBridge(debounceMilliseconds: 30)

        var received: [MeetingsEditBridge.EditEvent] = []
        let cancellable = bridge.editEvents.sink { event in
            received.append(event)
        }

        bridge.handleScriptMessage(name: "noteEdit", body: [
            "markdown": "# Stray", "clientVersion": 1
        ])
        try await Task.sleep(nanoseconds: 100_000_000)

        cancellable.cancel()
        XCTAssertTrue(
            received.isEmpty,
            "Edits before attachMeeting(id:) must be dropped."
        )
    }

    // MARK: - Test 3: coordinator save persists to the local store

    func test_save_persists_to_local_store_with_bumped_version() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let detector = StubDetector()
        let meetingId = UUID()

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("edit-bridge-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let store = try MeetingsStore(rootDirectory: tempRoot)
        try await store.insert(
            meta: MeetingMetaWithLocalState(
                id: meetingId,
                startedAt: Date(timeIntervalSince1970: 1_700_500_000),
                endedAt: Date(timeIntervalSince1970: 1_700_500_120),
                durationSeconds: 120,
                title: "Original",
                syncStatus: .new,
                serverVersion: 4,
                createdAt: Date(timeIntervalSince1970: 1_700_500_130)
            ),
            markdown: "# Original"
        )

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            meetingsStore: store
        )

        await coordinator.saveNoteEdit(
            id: meetingId,
            markdown: "# Edited body\n\nnew text",
            clientVersion: 4
        )

        // The local store carries the new markdown, the version bumped past
        // the base the editor saved against, and the sidebar title re-derived
        // from the new H1.
        let storedMarkdown = try await store.markdown(id: meetingId)
        XCTAssertEqual(storedMarkdown, "# Edited body\n\nnew text")
        let rows = try await store.list()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.serverVersion, 5)
        XCTAssertEqual(rows.first?.title, "Edited body")
    }

    /// A save for a meeting the store has never seen must not create a
    /// phantom row: the markdown write is harmless, but the row update
    /// matches nothing and the list stays empty.
    func test_save_for_unknown_meeting_does_not_create_row() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("edit-bridge-unknown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let store = try MeetingsStore(rootDirectory: tempRoot)

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: StubDetector(),
            meetingsStore: store
        )

        await coordinator.saveNoteEdit(id: UUID(), markdown: "# Orphan", clientVersion: 1)

        let rows = try await store.list()
        XCTAssertTrue(rows.isEmpty, "saveNoteEdit must not insert rows for unknown meetings")
    }
}

// MARK: - Test fixtures

@MainActor
private final class StubDetector: MeetingDetectorProtocol {
    func subscribe() {}
}
