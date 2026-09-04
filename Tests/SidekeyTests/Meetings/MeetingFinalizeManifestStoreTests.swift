import XCTest
@testable import Sidekey

/// Task 5a tests for `MeetingFinalizeManifestStore`. The manifest is the
/// pre-processing durability record that lets a fully recorded meeting
/// survive a processing failure (or an app quit) at Stop time. These tests
/// pin the IO contract: atomic write, idempotent delete, and a
/// decode-tolerant scan that skips (never crashes on, never deletes the
/// chunks of) a corrupt manifest.
final class MeetingFinalizeManifestStoreTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tempRoot, withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        super.tearDown()
    }

    private func makeManifest(recorderId: UUID = UUID()) -> MeetingFinalizeManifest {
        MeetingFinalizeManifest(
            recorderMeetingId: recorderId,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_120),
            durationSeconds: 120,
            language: "ru",
            chunkFileNames: ["chunk-000.wav", "chunk-001.wav"],
            isFinal: true
        )
    }

    func test_write_then_scan_round_trips_manifest() throws {
        let store = MeetingFinalizeManifestStore()
        let recorderId = UUID()
        let dir = tempRoot.appendingPathComponent(recorderId.uuidString)
        let manifest = makeManifest(recorderId: recorderId)

        try store.write(manifest, to: dir)

        XCTAssertTrue(store.manifestExists(in: dir))

        let entries = store.scan(stagingRoot: tempRoot)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.manifest, manifest)
        XCTAssertEqual(entries.first?.dir.lastPathComponent, recorderId.uuidString)
    }

    func test_rewrite_is_atomic_and_last_write_wins() throws {
        let store = MeetingFinalizeManifestStore()
        let recorderId = UUID()
        let dir = tempRoot.appendingPathComponent(recorderId.uuidString)
        var manifest = makeManifest(recorderId: recorderId)
        try store.write(manifest, to: dir)

        // Atomic rewrite with the reconnect markers a later Reconnect adds.
        manifest.reconnectMarkers = [
            MeetingReconnectMarker(afterAudioSeconds: 42, gapSeconds: 7)
        ]
        try store.write(manifest, to: dir)

        let entries = store.scan(stagingRoot: tempRoot)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.manifest, manifest)
    }

    func test_delete_is_idempotent() throws {
        let store = MeetingFinalizeManifestStore()
        let dir = tempRoot.appendingPathComponent(UUID().uuidString)
        try store.write(makeManifest(), to: dir)
        XCTAssertTrue(store.manifestExists(in: dir))

        store.delete(in: dir)
        XCTAssertFalse(store.manifestExists(in: dir))
        // Second delete must not throw / crash.
        store.delete(in: dir)
        XCTAssertFalse(store.manifestExists(in: dir))
    }

    func test_scan_skips_corrupt_manifest_without_deleting_dir() throws {
        let store = MeetingFinalizeManifestStore()

        // Good manifest in dir A.
        let goodDir = tempRoot.appendingPathComponent(UUID().uuidString)
        try store.write(makeManifest(), to: goodDir)

        // Garbage manifest in dir B — must be skipped, not crash, and the
        // dir + its (pretend) chunk must survive.
        let badDir = tempRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(
            to: badDir.appendingPathComponent(MeetingFinalizeManifest.fileName)
        )
        let chunkURL = badDir.appendingPathComponent("chunk-000.wav")
        try Data([0xAB]).write(to: chunkURL)

        let entries = store.scan(stagingRoot: tempRoot)
        XCTAssertEqual(entries.count, 1, "Only the well-formed manifest must surface")
        XCTAssertEqual(entries.first?.dir.lastPathComponent, goodDir.lastPathComponent)

        // The corrupt dir + chunk must still be on disk (recovery must
        // never delete the chunks of a manifest it could not decode).
        XCTAssertTrue(FileManager.default.fileExists(atPath: badDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunkURL.path))
    }

    func test_scan_returns_empty_when_root_missing() {
        let store = MeetingFinalizeManifestStore()
        let missing = tempRoot.appendingPathComponent("does-not-exist")
        XCTAssertEqual(store.scan(stagingRoot: missing).count, 0)
    }

    // MARK: - Reconnect markers on the manifest

    /// Manifests written by clients that predate reconnect never had a
    /// `reconnectMarkers` key. Decoding one must succeed with
    /// `reconnectMarkers == nil` rather than failing the whole decode: an
    /// app update must not strand a pre-existing manifest on disk.
    func test_decode_manifest_without_reconnect_markers_key_defaults_to_nil() throws {
        let recorderId = UUID()
        let json = """
        {
            "recorderMeetingId": "\(recorderId.uuidString)",
            "startedAt": 743000000,
            "endedAt": 743000120,
            "durationSeconds": 120,
            "language": "ru",
            "chunkFileNames": ["chunk-000.wav"],
            "isFinal": true
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let manifest = try decoder.decode(
            MeetingFinalizeManifest.self, from: Data(json.utf8)
        )

        XCTAssertNil(manifest.reconnectMarkers)
        XCTAssertEqual(manifest.recorderMeetingId, recorderId)
        XCTAssertEqual(manifest.chunkFileNames, ["chunk-000.wav"])
    }

    /// A manifest carrying reconnect markers must round-trip through the
    /// store's write/scan unchanged, so launch recovery re-inserts the
    /// same "Reconnected after N s" boundaries the in-session path would.
    func test_manifest_with_reconnect_markers_round_trips_through_store() throws {
        let store = MeetingFinalizeManifestStore()
        let recorderId = UUID()
        let dir = tempRoot.appendingPathComponent(recorderId.uuidString)
        var manifest = makeManifest(recorderId: recorderId)
        manifest.reconnectMarkers = [
            MeetingReconnectMarker(afterAudioSeconds: 30, gapSeconds: 12),
            MeetingReconnectMarker(afterAudioSeconds: 95.5, gapSeconds: 61),
        ]

        try store.write(manifest, to: dir)

        let entries = store.scan(stagingRoot: tempRoot)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.manifest.reconnectMarkers, manifest.reconnectMarkers)
        XCTAssertEqual(entries.first?.manifest, manifest)
    }
}
